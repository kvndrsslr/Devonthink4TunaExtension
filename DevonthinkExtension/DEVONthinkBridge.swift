import AppKit
import Foundation

/// Liveness + readiness checks for DEVONthink 4.
///
/// Two levels of checking:
/// - **Liveness** (`isRunning`): pure process-table check via
///   `NSRunningApplication` — no Apple Event, no allocation. Used for the
///   immediate "show Unavailable ASAP" decision in `hierarchyChildren`.
/// - **Readiness** (`isReady` / `ensureReady`): a cheap Apple Event heartbeat
///   via a disposable `/usr/bin/osascript` subprocess. A DEVONthink process can
///   be *running* but still loading its databases / scripting system, in which
///   case Apple Events fail until it is fully initialized. `ensureReady` polls
///   until the heartbeat succeeds (or a timeout elapses) so the first real
///   search after auto-launch hits a responsive app.
///
/// ScriptingBridge's in-process optional-method dispatch
/// (`app.search?(...)`) crashes with `EXC_BAD_ACCESS` inside
/// `-[SBAppContext descriptorForObject:]` — a raw null-deref Swift cannot catch.
/// Every Apple Event therefore runs in a **disposable child process**
/// (`/usr/bin/osascript`), so a scripting failure can never take Tuna down.
enum DEVONthinkBridge {
  static let bundleID = "com.devon-technologies.think"

  /// True when a DEVONthink process is running and not terminated.
  /// Pure process-table check — no Apple Event, no ScriptingBridge.
  static func isRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .filter { !$0.isTerminated }.isEmpty
  }

  // MARK: - Readiness (Apple Event heartbeat)

  /// Heartbeat AppleScript — the cheapest possible Apple Event that proves
  /// DEVONthink's scripting system is alive and responding. Fetching the app
  /// name requires the AppleScript component to be initialized and the app to
  /// be far enough along in startup to answer Apple Events.
  private static let heartbeatScript = """
    tell application id "com.devon-technologies.think"
      return name
    end tell
    """

  /// True when DEVONthink is not only running but also responding to Apple
  /// Events. Runs a disposable `osascript` subprocess; if DT is still loading,
  /// the heartbeat fails (non-zero exit / empty output) and we report false.
  /// Never throws — safe to call from anywhere.
  static func isReady() -> Bool {
    guard isRunning() else { return false }
    return runHeartbeat()
  }

  /// Poll until DEVONthink responds to the Apple Event heartbeat, launching it
  /// in the background first when `autoLaunch` is true and it is not running.
  /// Returns `true` once the app is ready, `false` on timeout.
  ///
  /// - Parameter autoLaunch: When `true` and DT is not running, launch it in the
  ///   background (no focus steal) and wait for readiness. When `false`, only
  ///   wait if DT is already running (e.g. it was launched manually); if it is
  ///   not running at all, return immediately with `false`.
  /// - Parameter timeout: Maximum wall-clock seconds to wait. Defaults to 15s.
  @discardableResult
  static func ensureReady(autoLaunch: Bool, timeout: TimeInterval = 15) async -> Bool {
    // Fast path: already ready.
    if isReady() { return true }

    // Not running — launch in the background if auto-launch is enabled.
    if !isRunning() {
      guard autoLaunch else { return false }
      launchInBackground()
    }

    // Poll the Apple Event heartbeat until DT responds or we time out.
    let deadline = DispatchTime.now() + .milliseconds(Int(timeout * 1000))
    while DispatchTime.now() < deadline {
      if isReady() { return true }
      try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
    }
    return isReady()
  }

  /// Launch DEVONthink in the background without stealing focus.
  private static func launchInBackground() {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: "/Applications/DEVONthink.app"),
      configuration: config)
  }

  /// Run the heartbeat script in a disposable osascript subprocess.
  /// Returns `true` only when the script exits 0 with non-empty output.
  private static func runHeartbeat() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", heartbeatScript]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return false
    }

    // Hard-cap the heartbeat so a wedged app can't stall us.
    let timeout = DispatchTime.now() + .seconds(5)
    while process.isRunning {
      if DispatchTime.now() >= timeout {
        process.terminate()
        return false
      }
      Thread.sleep(forTimeInterval: 0.01)
    }

    guard process.terminationStatus == 0 else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
