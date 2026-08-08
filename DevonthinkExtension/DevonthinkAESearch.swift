import Foundation

/// Paged DEVONthink search engine.
///
/// Each call to `search(query:page:pageSize:)` runs ONE `osascript` child
/// process that searches DEVONthink and fetches just the requested page window
/// of results' properties, returning `(records, hasMore)` — the same progressive
/// paging contract as the osascript path, so the first page is fast and later
/// pages load on demand.
///
/// Why a single script per page (rather than an in-process raw-AE bulk fetch):
/// DEVONthink's `search` returns record references that are ONLY addressable
/// inside the executing AppleScript (as `item i of theResults`). They cannot be
/// re-addressed from a later Apple Event by content-id, index, name, or as a
/// property list ("Can't get content id …; Invalid index"), and DEVONthink
/// rejects every bulk property form over them. So properties must be fetched in
/// the SAME script that ran the search, while the references are live.
///
/// Crash-safety: a subprocess can never take Tuna down; a failed or aborted
/// `osascript` simply yields no records.
enum DevonthinkAESearch {

  /// Search DEVONthink and return one page of records.
  ///
  /// - Returns: `.success((records, hasMore))` or `.failure`.
  static func search(query: String, page: Int, pageSize: Int) -> Result<([DevonthinkRecord], Bool), DevonthinkDataError> {
    // Tuna passes 1-indexed pages (page 1 = first results).
    let start = ((page - 1) * pageSize) + 1
    let script = pageScript(query: query, start: start, pageSize: pageSize)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      return .failure(.scriptFailed("Could not start osascript: \(error.localizedDescription)"))
    }

    // Bound the wait so a hung osascript can't wedge the search forever.
    let timeout = DispatchTime.now() + .seconds(8)
    while process.isRunning {
      if DispatchTime.now() >= timeout {
        process.terminate()
        return .failure(.scriptFailed("DEVONthink search timed out"))
      }
      Thread.sleep(forTimeInterval: 0.01)
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0, !output.isEmpty else {
      return .failure(DevonthinkDataError.devonthinkNotRunning)
    }

    return parsePageOutput(output, page: page, pageSize: pageSize)
  }

  /// Build the AppleScript that searches DEVONthink and fetches just the
  /// requested page slice of results' properties (indices `start...end`), in
  /// the same script so the search references stay live. Emits one
  /// tab-delimited line per record plus a trailing `COUNT:<total>` line. Field
  /// values are sanitized (tabs/newlines stripped) so delimiters stay
  /// unambiguous.
  private static func pageScript(query: String, start: Int, pageSize: Int) -> String {
    let escapedQuery = query
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")

    let end = start + pageSize - 1
    let lines = [
      "on clean(s)",
      "    set s to s as string",
      "    set tid to AppleScript's text item delimiters",
      "    set AppleScript's text item delimiters to \"\\t\"",
      "    set s to text items of s",
      "    set AppleScript's text item delimiters to \" \"",
      "    set s to s as string",
      "    set AppleScript's text item delimiters to tid",
      "    return s",
      "end clean",
      "",
      "set theResults to {}",
      "set theCount to 0",
      "try",
      "    tell application id \"com.devon-technologies.think\"",
      "        set theResults to search \"\(escapedQuery)\"",
      "        set theCount to count of theResults",
      "    end tell",
      "end try",
      "",
      "set endIdx to \(end)",
      "if endIdx > theCount then set endIdx to theCount",
      "",
      "set out to \"\"",
      "if theCount > 0 and \(start) \u{2264} theCount then",
      "    repeat with i from \(start) to endIdx",
      "        set aRec to item i of theResults",
      "        tell application id \"com.devon-technologies.think\"",
      "            set recProps to properties of aRec",
      "            set recUUID to my clean(uuid of recProps)",
      "            set recName to my clean(name of recProps)",
      "            set recPath to my clean(path of recProps)",
      "            set recLoc to my clean(location of recProps)",
      "            set recKind to my clean(kind of recProps)",
      "        end tell",
      "        set out to out & recUUID & \"\\t\" & recName & \"\\t\" & recPath & \"\\t\" & recLoc & \"\\t\" & recKind & \"\\n\"",
      "    end repeat",
      "end if",
      "return out & \"COUNT:\" & theCount",
    ]
    return lines.joined(separator: "\n")
  }

  /// Parse the page script's tab-delimited output into records + `hasMore`.
  private static func parsePageOutput(_ output: String, page: Int, pageSize: Int) -> Result<([DevonthinkRecord], Bool), DevonthinkDataError> {
    var records: [DevonthinkRecord] = []
    var totalCount = 0

    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(rawLine)
      if line.hasPrefix("COUNT:") {
        totalCount = Int(line.dropFirst("COUNT:".count)) ?? 0
        continue
      }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 5 else { continue }
      let uuid = fields[0]
      guard !uuid.isEmpty else { continue }
      let name = fields[1]
      let path = cleanedOptional(fields[2])
      let location = cleanedOptional(fields[3])
      let kind = cleanedOptional(fields[4])
      records.append(
        DevonthinkRecord(
          uuid: uuid,
          name: name.isEmpty ? "Untitled" : name,
          path: path,
          location: location,
          databaseName: DevonthinkData.databaseName(from: path),
          kind: kind))
    }

    // 1-indexed pages: page N covers records [(N-1)*pageSize, N*pageSize).
    let sliceEnd = ((page - 1) * pageSize) + pageSize
    let hasMore = sliceEnd < totalCount
    return .success((records, hasMore))
  }

  private static func cleanedOptional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
