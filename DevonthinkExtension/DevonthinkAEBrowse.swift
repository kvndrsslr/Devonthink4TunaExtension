import Foundation

/// Browsing engine for DEVONthink databases and groups.
///
/// Each call runs ONE `osascript` child process (matching `DevonthinkAESearch`)
/// that lists loaded databases or enumerates a container's records, returning
/// tab-delimited rows plus a trailing `COUNT:<total>` line.
///
/// Enumeration uses DEVONthink's **`get record with uuid` + `children of`** form
/// — the same path for both databases and groups. This is the form that proves
/// reliable against live DEVONthink 4; the alternate `records of database`
/// iteration intermittently fails with `-10000` AppleEvent handler failed and is
/// avoided.
///
/// Crash-safety and flakiness handling: a subprocess can never take Tuna down,
/// and a failed or aborted `osascript` yields no records — callers render a
/// message item instead of hanging.
enum DevonthinkAEBrowse {

  /// List the currently loaded DEVONthink databases (name, uuid, path).
  static func loadedDatabases() -> Result<[DevonthinkDatabase], DevonthinkDataError> {
    guard let output = runScript(databasesScript()) else {
      return .failure(.devonthinkNotRunning)
    }
    return parseDatabasesOutput(output)
  }

  /// Return the immediate children of the record (a database or a group) with
  /// the given UUID.
  static func children(of uuid: String) -> Result<[DevonthinkRecord], DevonthinkDataError> {
    guard DEVONthinkBridge.isRunning() else { return .failure(.devonthinkNotRunning) }
    guard let output = runScript(childrenScript(uuid: uuid)) else {
      return .failure(.devonthinkNotRunning)
    }
    return parseRecordsOutput(output)
  }

  // MARK: - AppleScript builders

  private static func databasesScript() -> String {
    let lines = [
      "set out to \"\"",
      "tell application id \"com.devon-technologies.think\"",
      "    set theDBs to databases",
      "    set theCount to count of theDBs",
      "    repeat with d in theDBs",
      "        set out to out & (name of d) & \"\t\" & (uuid of d) & \"\t\" & (path of d) & \"\n\"",
      "    end repeat",
      "end tell",
      "return out & \"COUNT:\" & theCount",
    ]
    return lines.joined(separator: "\n")
  }

  private static func childrenScript(uuid: String) -> String {
    let escapedUUID = escapeLiteral(uuid)
    let lines = [
      "set out to \"\"",
      "tell application id \"com.devon-technologies.think\"",
      "    set theRec to get record with uuid \"\(escapedUUID)\"",
      "    set theChildren to children of theRec",
      "    set theCount to count of theChildren",
      "    repeat with c in theChildren",
      "        set p to properties of c",
      "        set out to out & (uuid of p) & \"\t\" & (name of p) & \"\t\" & (path of p) & \"\t\" & (kind of p) & \"\n\"",
      "    end repeat",
      "end tell",
      "return out & \"COUNT:\" & theCount",
    ]
    return lines.joined(separator: "\n")
  }

  // MARK: - Parsers

  private static func parseDatabasesOutput(_ output: String) -> Result<[DevonthinkDatabase], DevonthinkDataError> {
    var databases: [DevonthinkDatabase] = []
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(rawLine)
      if line.hasPrefix("COUNT:") { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 3 else { continue }
      let name = fields[0]
      let uuid = fields[1]
      let path = fields[2]
      guard !name.isEmpty, !uuid.isEmpty, !path.isEmpty else { continue }
      databases.append(DevonthinkDatabase(name: name, uuid: uuid, path: path))
    }
    return .success(databases)
  }

  private static func parseRecordsOutput(_ output: String) -> Result<[DevonthinkRecord], DevonthinkDataError> {
    var records: [DevonthinkRecord] = []
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(rawLine)
      if line.hasPrefix("COUNT:") { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 4 else { continue }
      let uuid = fields[0]
      guard !uuid.isEmpty else { continue }
      let name = fields[1]
      let path = cleanedOptional(fields[2])
      let kind = cleanedOptional(fields[3])
      records.append(
        DevonthinkRecord(
          uuid: uuid,
          name: name.isEmpty ? "Untitled" : name,
          path: path,
          location: nil,
          databaseName: nil,
          kind: kind))
    }
    if records.isEmpty {
      return .failure(.noResults)
    }
    return .success(records)
  }

  // MARK: - Subprocess runner

  /// Run an AppleScript in a disposable `/usr/bin/osascript` subprocess with an
  /// 8-second cap. Returns the stdout, or `nil` on non-zero exit, empty output,
  /// or timeout. Never throws.
  private static func runScript(_ script: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      return nil
    }

    let timeout = DispatchTime.now() + .seconds(8)
    while process.isRunning {
      if DispatchTime.now() >= timeout {
        process.terminate()
        return nil
      }
      Thread.sleep(forTimeInterval: 0.01)
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0, !output.isEmpty else {
      return nil
    }
    return output
  }

  // MARK: - Helpers

  /// Escape backslashes and double quotes for an AppleScript string literal,
  /// and strip tabs/newlines so record values can't break the delimited format.
  private static func escapeLiteral(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }

  private static func cleanedOptional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
