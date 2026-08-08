import AppKit
import Foundation
import os.log

/// Client for the DEVONthink MCP stdio server.
///
/// DEVONthink ships an MCP server (`DEVONthink MCP.app`) that exposes
/// DEVONthink's data model over JSON-RPC on a stdio transport. The extension
/// spawns it once with `--stdio`, holds the persistent connection, and sends
/// `tools/call` requests. The server both talks to a running DEVONthink and
/// **auto-launches it when needed** (config `devonthink.launchIfNeeded=true`),
/// so the extension never has to launch or await DEVONthink itself.
///
/// Isolation matches the old osascript design: DEVONthink interactions run in a
/// child process. If the server (or DEVONthink) crashes or hangs, only that
/// process is affected — Tuna and the extension host stay up. Requests are
/// serialized (one in flight at a time): DEVONthink answers quickly, and each
/// request is bounded by a local timeout so a wedged server can never stall a
/// search.
enum DevonthinkMCP {

  /// The decoded outcome of a `tools/call`. `payload` is the JSON value that
  /// MCP embeds as a string in `content[0].text` — a dictionary for most tools
  /// (e.g. `search_records` returns `{results, total, ...}`), but a bare array
  /// for `get_databases`. `isError`/`errorMessage` flag a tool-level or
  /// transport failure.
  struct CallResult {
    var payload: Any?
    var isError: Bool
    var errorMessage: String?

    var success: Bool { !isError }

    /// The payload as a dictionary, when the tool returned an object.
    var dict: [String: Any]? { payload as? [String: Any] }

    /// The payload as an array of dictionaries, when the tool returned a list.
    var array: [[String: Any]]? { payload as? [[String: Any]] }

    /// Pull a typed value out of a dictionary payload by key.
    func value<T>(_ key: String) -> T? {
      dict?[key] as? T
    }
  }

  /// Locate the DEVONthink MCP server executable. DEVONthink can live in non-
  /// standard install locations, so resolve the app by bundle ID first and fall
  /// back to the standard `/Applications` / `~/Applications` paths. If nothing
  /// resolves, `Process.run()` throws and `startServer()` reports the usual
  /// "DEVONthink MCP server could not be reached" failure.
  private static var executableURL: URL {
    let mcpPath = "Contents/Library/LoginItems/DEVONthink MCP.app/Contents/MacOS/DEVONthink MCP"
    let bundleID = DEVONthinkBridge.bundleID
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return appURL.appendingPathComponent(mcpPath)
    }
    let candidates = [
      URL(fileURLWithPath: "/Applications/DEVONthink.app").appendingPathComponent(mcpPath),
      URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Applications/DEVONthink.app")
        .appendingPathComponent(mcpPath),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
  }

  /// Locking model:
  /// - `requestLock` serializes callers so only one request is in flight.
  /// - `stateLock` guards the read buffer, `activeID` and `resultSlot`. The
  ///   reader needs it only to append frames / fill the one slot; callers
  ///   touch it briefly and NEVER block on the response semaphore while
  ///   holding it (that would deadlock the reader).
  private final class Connection: @unchecked Sendable {
    let requestLock = NSLock()
    let stateLock = NSLock()
    let responseSignal = DispatchSemaphore(value: 0)

    var process: Process?
    var stdinHandle: FileHandle?
    var stdoutHandle: FileHandle?
    var readBuffer = Data()
    var isReady = false

    var requestCounter = 0
    var activeID: Int?
    var resultSlot: CallResult?
  }

  private static let connection = Connection()

  /// Loose MCP lifecycle/error logging surfaced in `tuna-extension logs` (the
  /// Tuna extension-host predicate) for diagnosing slow or stalled browses.
  private static let log = Logger(
    subsystem: "com.brnbw.Tuna", category: "Plugins")

  /// Run one MCP tool call and return its parsed result. Connects lazily on
  /// first use and reconnects if the server has exited. Never throws — returns
  /// a failed `CallResult` on any error so callers render a message item.
  static func call(tool: String, arguments: [String: Any]) async -> CallResult {
    // Run off the main actor so a slow server can't stall the UI thread.
    return await Task.detached(priority: .userInitiated) {
      performCall(tool: tool, arguments: arguments)
    }.value
  }

  // MARK: - Tool call

  private static func performCall(tool: String, arguments: [String: Any]) -> CallResult {
    connection.requestLock.lock()
    defer { connection.requestLock.unlock() }

    guard ensureConnected() else {
      return CallResult(payload: nil, isError: true, errorMessage: "DEVONthink MCP server could not be reached.")
    }
    guard let stdin = connection.stdinHandle else {
      return CallResult(payload: nil, isError: true, errorMessage: "DEVONthink MCP server is not connected.")
    }

    connection.stateLock.lock()
    connection.requestCounter += 1
    let id = connection.requestCounter
    connection.stateLock.unlock()

    guard let body = try? JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0",
      "id": id,
      "method": "tools/call",
      "params": ["name": tool, "arguments": arguments],
    ]) else {
      return CallResult(payload: nil, isError: true, errorMessage: "Could not encode MCP request.")
    }

    let started = ContinuousClock.now
    let result = submitAndWait(id: id) {
      stdin.write(body + "\n".data(using: .utf8)!)
    }
    let elapsed = ContinuousClock.now - started
    let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    if result.isError {
      log.error("mcp '\(tool)' failed in \(ms)ms: \(result.errorMessage ?? "unknown")")
    } else {
      log.notice("mcp '\(tool)' ok in \(ms)ms")
    }

    // A transport failure (not a tool-level error) makes the connection
    // unreliable — reconnect on the next call.
    if result.transportError {
      connection.stateLock.lock()
      connection.isReady = false
      connection.stateLock.unlock()
    }
    return result
  }

  /// Register the active request id, issue the write that triggers the response,
  /// then block until the reader fills the result slot or the timeout elapses.
  /// Never holds either lock while waiting.
  private static func submitAndWait(id: Int, issue: () -> Void) -> CallResult {
    connection.stateLock.lock()
    connection.activeID = id
    connection.resultSlot = nil
    connection.stateLock.unlock()

    issue()

    let deadline = DispatchTime.now() + .seconds(15)
    while true {
      connection.stateLock.lock()
      let result = connection.resultSlot
      connection.stateLock.unlock()
      if let result {
        connection.stateLock.lock()
        connection.activeID = nil
        connection.stateLock.unlock()
        return result
      }
      if DispatchTime.now() >= deadline {
        connection.stateLock.lock()
        connection.activeID = nil
        connection.stateLock.unlock()
        log.error("mcp request id \(id) timed out after 15s")
        return CallResult(payload: nil, isError: true, errorMessage: "DEVONthink MCP request timed out.")
      }
      _ = connection.responseSignal.wait(timeout: .now() + .milliseconds(50))
    }
  }

  // MARK: - Connection / handshake

  private static func ensureConnected() -> Bool {
    connection.stateLock.lock()
    let runningReady = connection.isReady && (connection.process?.isRunning ?? false)
    connection.stateLock.unlock()
    if runningReady { return true }
    return startServer()
  }

  private static func startServer() -> Bool {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["--stdio"]

    let inPipe = Pipe()
    let outPipe = Pipe()
    let discardPipe = Pipe() // stderr startup logs; drained so the server never blocks on a full buffer
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = discardPipe

    do {
      try process.run()
    } catch {
      return false
    }

    connection.stateLock.lock()
    connection.process = process
    connection.stdinHandle = inPipe.fileHandleForWriting
    connection.stdoutHandle = outPipe.fileHandleForReading
    connection.readBuffer.removeAll(keepingCapacity: true)
    connection.isReady = false
    connection.stateLock.unlock()

    // Drain stderr on a background thread.
    discardPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }

    // Reader that parses newline-delimited JSON-RPC frames and fills the slot.
    connection.stdoutHandle?.readabilityHandler = { [self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      connection.stateLock.lock()
      connection.readBuffer.append(data)
      drainFramesLocked()
      connection.stateLock.unlock()
    }

    // Handshake: initialize (+ initialized notification afterwards).
    connection.stateLock.lock()
    connection.requestCounter += 1
    let initID = connection.requestCounter
    connection.stateLock.unlock()

    guard let initBody = try? JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0",
      "id": initID,
      "method": "initialize",
      "params": [
        "protocolVersion": "2024-11-05",
        "capabilities": [:],
        "clientInfo": ["name": "Tuna DEVONthink Extension", "version": "1.0.0"],
      ],
    ]), let stdin = connection.stdinHandle else {
      return false
    }

    let initResult = submitAndWait(id: initID) {
      stdin.write(initBody + "\n".data(using: .utf8)!)
    }
    guard initResult.success else { return false }

    // Notify initialized (notification — no response expected).
    if let notify = try? JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0",
      "method": "notifications/initialized",
      "params": [:],
    ]) {
      stdin.write(notify + "\n".data(using: .utf8)!)
    }

    connection.stateLock.lock()
    connection.isReady = true
    connection.stateLock.unlock()
    return true
  }

  // MARK: - Frame parsing

  /// Pull complete newline-terminated JSON-RPC frames out of the buffer and
  /// resume the matching active request. Caller MUST hold `stateLock`.
  private static func drainFramesLocked() {
    while true {
      guard let newlineIndex = connection.readBuffer.firstIndex(of: 0x0A) else { break }
      let frameData = connection.readBuffer.subdata(in: connection.readBuffer.startIndex..<newlineIndex)
      connection.readBuffer.removeSubrange(connection.readBuffer.startIndex...newlineIndex)
      guard
        let obj = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any],
        let id = obj["id"] as? Int,
        id == connection.activeID,
        connection.resultSlot == nil
      else { continue }
      connection.resultSlot = parseCallResult(obj)
      connection.responseSignal.signal()
      break // one active request at a time
    }
  }

  private static func parseCallResult(_ obj: [String: Any]) -> CallResult {
    if let error = obj["error"] as? [String: Any] {
      return CallResult(
        payload: nil,
        isError: true,
        errorMessage: error["message"] as? String ?? "DEVONthink MCP error")
    }
    guard let result = obj["result"] as? [String: Any] else {
      return CallResult(payload: nil, isError: true, errorMessage: "Malformed MCP response.")
    }
    let isError = result["isError"] as? Bool ?? false
    var payload: Any?
    if let content = result["content"] as? [[String: Any]],
       let text = content.first?["text"] as? String,
       let textData = text.data(using: .utf8) {
      payload = try? JSONSerialization.jsonObject(with: textData)
    }
    return CallResult(payload: payload, isError: isError, errorMessage: nil)
  }

  // MARK: - Teardown

  /// Terminate the spawned MCP server, if any. Safe to call anytime: the next
  /// `call` (via `ensureConnected` → `startServer`) spawns a fresh server, so a
  /// shutdown mid-session merely forces a reconnect. Without this the child
  /// process outlives the extension host — macOS does not kill a parent's
  /// children on exit — so every extension reload leaks another `DEVONthink
  /// MCP --stdio` server. Each leaked server keeps a live connection into
  /// DEVONthink, so over several rebuild/restart cycles they accumulate and
  /// contend with the active query, which is what pushed the browse's
  /// superlinear tail chunks past the request timeout. Called on browse
  /// catalog teardown to keep the running Tuna session free of stale servers.
  static func shutdown() {
    connection.stateLock.lock()
    let process = connection.process
    connection.process = nil
    connection.stdinHandle = nil
    connection.stdoutHandle = nil
    connection.isReady = false
    connection.readBuffer.removeAll(keepingCapacity: true)
    connection.stateLock.unlock()

    // Send SIGTERM so the server can exit cleanly; fall back to SIGKILL if it
    // doesn't go promptly. Best effort — the child is a throwaway subprocess.
    // Deliberately does not take `requestLock`: this runs from the browse
    // catalog's main-actor release path, and waiting on an in-flight request
    // would stall teardown. Killing mid-request yields a failed `CallResult`
    // for that caller, which is the intended reconnect-after-shutdown outcome.
    if let process = process, process.isRunning {
      process.terminate() // SIGTERM
      DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
        if process.isRunning {
          Darwin.kill(process.processIdentifier, SIGKILL)
        }
      }
    }
  }
}

// MARK: - CallResult conveniences

private extension DevonthinkMCP.CallResult {
  /// A transport-level failure (server down / timeout) vs. a tool-level error.
  var transportError: Bool {
    isError && payload == nil
  }
}
