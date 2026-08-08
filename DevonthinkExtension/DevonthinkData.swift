import AppKit
import Foundation
import TunaKit

struct DevonthinkRecord: Hashable, Sendable {
  let uuid: String
  let name: String
  let path: String?
  let location: String?
  let databaseName: String?
  let kind: String?

  var stableID: String { uuid }
  var isGroup: Bool { (kind ?? "").lowercased().contains("group") }

  init(uuid: String, name: String, path: String?, location: String?,
       databaseName: String?, kind: String?) {
    self.uuid = uuid
    self.name = name
    self.path = path
    self.location = location
    self.databaseName = databaseName
    self.kind = kind
  }
}

/// A loaded DEVONthink database (top-level container served by the browse
/// catalog). `name` matches the database's AppleScript `name`; `uuid` is the
/// database's stable record UUID (used to enumerate root contents via the same
/// `children of` path as groups, which is the reliable enumeration form);
/// `path` is the `.dtBase2` bundle path (the item's stable identity for Tuna).
struct DevonthinkDatabase: Hashable, Sendable {
  let name: String
  let uuid: String
  let path: String
}

enum DevonthinkDataError: Error, LocalizedError, Sendable {
  case devonthinkNotRunning
  case scriptFailed(String)
  case noResults

  var errorDescription: String? {
    switch self {
    case .devonthinkNotRunning:
      return "DEVONthink is not running. Open DEVONthink to search its databases."
    case .scriptFailed(let message):
      return "DEVONthink query failed: \(message)"
    case .noResults:
      return "No DEVONthink documents matched."
    }
  }
}

/// Bridge to DEVONthink 4 — **no ScriptingBridge**.
///
/// Every Apple Event runs in a disposable `/usr/bin/osascript` child process.
/// ScriptingBridge crashes with `EXC_BAD_ACCESS` inside
/// `-[SBAppContext descriptorForObject:]` — a raw segfault Swift cannot catch.
/// A child process can crash without harming Tuna, so the extension can never
/// take the host down: a failed/aborted `osascript` simply yields no results.
///
/// The search AppleScript emits one tab-delimited line per record plus a
/// trailing `COUNT:<total>` line; the last page slice is requested in-process
/// by indexing into the full result set returned by DEVONthink's `search`.
enum DevonthinkData {

  // MARK: - Search (paged)

  /// Page size for progressive search results.
  static let pageSize = 3

  /// Search and return one page of results. Page 0 is the first `pageSize`
  /// records. If DEVONthink is not running, returns `.failure(.devonthinkNotRunning)`
  /// immediately — the caller shows an actionable item so the user can launch
  /// DEVONthink and re-run the search. We never auto-launch DT from the search
  /// path (only from the unavailable item's action).
  static func searchPage(query: String, page: Int, pageSize: Int = DevonthinkData.pageSize) async -> Result<(records: [DevonthinkRecord], hasMore: Bool), DevonthinkDataError> {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return .success(([], false)) }

    guard DEVONthinkBridge.isRunning() else {
      return .failure(.devonthinkNotRunning)
    }

    let result = await Task.detached(priority: .userInitiated) {
      switch DevonthinkSettings.searchTransport {
      case .osascript:
        return Self.searchViaOSA(query: normalized, page: page, pageSize: pageSize)
      case .rawAppleEvents:
        return Self.searchViaAE(query: normalized, page: page, pageSize: pageSize)
      }
    }.value

    switch result {
    case .success(let (records, hasMore)):
      return .success((records, hasMore))
    case .failure(let error):
      return .failure(error)
    }
  }

  // MARK: - osascript search

  /// Run the DEVONthink `search` command in a child `osascript` process and
  /// parse the tab-delimited output. The AppleScript runs the search once,
  /// fetches `properties` for just the requested page slice (one Apple Event
  /// per record), and returns `COUNT:<total>` so we know whether more pages
  /// remain.
  ///
  /// Runs in a subprocess: if DEVONthink quits mid-query or its scripting
  /// system misbehaves, only `osascript` dies — Tuna is unaffected.
  private static func searchViaOSA(query: String, page: Int, pageSize: Int) -> Result<([DevonthinkRecord], Bool), DevonthinkDataError> {
    // Re-check liveness right before spawning — the process may have quit
    // between the caller's check and now.
    guard DEVONthinkBridge.isRunning() else {
      return .failure(.devonthinkNotRunning)
    }

    // TunaKit passes 1-indexed pages (page 1 = first results), matching the
    // original working commit's convention. Convert to AppleScript's 1-indexed
    // `repeat with i from start to end`: page 1 → indices 1..pageSize.
    let start = ((page - 1) * pageSize) + 1
    let script = Self.searchScript(query: query, start: start, pageSize: pageSize)

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

    // Non-zero exit or empty output = failure (DT quit, scripting error, etc.).
    // Never a crash — the subprocess absorbed it.
    guard process.terminationStatus == 0, !output.isEmpty else {
      return .failure(.devonthinkNotRunning)
    }

    return Self.parseSearchOutput(output, page: page, pageSize: pageSize)
  }

  /// Raw-AE search engine (see `DevonthinkAESearch`). Paged: returns one page of
  /// records with `hasMore`. Used when `DevonthinkSettings.searchTransport ==
  /// .rawAppleEvents` for A/B comparison against `searchViaOSA`.
  private static func searchViaAE(query: String, page: Int, pageSize: Int) -> Result<([DevonthinkRecord], Bool), DevonthinkDataError> {
    // Re-check liveness right before — the process may have quit between the
    // caller's check and now.
    guard DEVONthinkBridge.isRunning() else {
      return .failure(.devonthinkNotRunning)
    }
    return DevonthinkAESearch.search(query: query, page: page, pageSize: pageSize)
  }

  /// AppleScript source: search DT, emit one tab-delimited line per record in
  /// the requested page slice, then a `COUNT:<total>` line. Field values are
  /// sanitized (tabs/newlines stripped) so delimiters stay unambiguous.
  private static func searchScript(query: String, start: Int, pageSize: Int) -> String {
    // Escape backslashes and double quotes for AppleScript string literals,
    // and strip tabs/newlines so record values can't break the delimited format.
    let escapedQuery = query
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")

    let end = start + pageSize - 1
    // Build the AppleScript source as joined Swift lines. The literal newline
    // in the per-record line is expressed as "\n" (a Swift string escape), so
    // the source compiles and the emitted script contains a real newline char.
    let lines = [
      "on clean(s)",
      "    set s to s as string",
      "    set tid to AppleScript's text item delimiters",
      "    set AppleScript's text item delimiters to \"\t\"",
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
      "        set out to out & recUUID & \"\t\" & recName & \"\t\" & recPath & \"\t\" & recLoc & \"\t\" & recKind & \"\n\"",
      "    end repeat",
      "end if",
      "return out & \"COUNT:\" & theCount"
    ]
    return lines.joined(separator: "\n")
  }

  /// Parse tab-delimited osascript output into records + `hasMore`.
  private static func parseSearchOutput(_ output: String, page: Int, pageSize: Int) -> Result<([DevonthinkRecord], Bool), DevonthinkDataError> {
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
      let rawPath = fields[2]
      let rawLoc = fields[3]
      let kind = fields[4]

      records.append(
        DevonthinkRecord(
          uuid: uuid,
          name: name.isEmpty ? "Untitled" : name,
          path: cleanedOptional(rawPath),
          location: cleanedOptional(rawLoc),
          databaseName: databaseName(from: rawPath),
          kind: cleanedOptional(kind)))
    }

    // 1-indexed pages: page N covers records [(N-1)*pageSize, N*pageSize).
    let sliceEnd = ((page - 1) * pageSize) + pageSize
    let hasMore = sliceEnd < totalCount
    return .success((records, hasMore))
  }

  // MARK: - Open / Reveal in DEVONthink (URL scheme, fire-and-forget)

  /// Open a DEVONthink record by UUID inside DEVONthink itself, via the
  /// `x-devonthink-item://` URL scheme. No Apple Event, no ScriptingBridge —
  /// NSWorkspace handles it. Fire-and-forget.
  static func openInDEVONthink(uuid: String) async -> Result<Void, DevonthinkDataError> {
    let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(.scriptFailed("Cannot open: UUID is empty"))
    }
    guard let url = URL(string: "x-devonthink-item://\(trimmed)") else {
      return .failure(.scriptFailed("Cannot build item URL for UUID \(trimmed)"))
    }
    guard NSWorkspace.shared.open(url) else {
      return .failure(.scriptFailed("DEVONthink could not open item \(trimmed)"))
    }
    return .success(())
  }

  /// Reveal (select) a record in DEVONthink — `openInDEVONthink` and
  /// `revealInDEVONthink` both route through `x-devonthink-item://`, which
  /// opens/activates the item in DEVONthink's browser. Kept as a distinct
  /// entry point for action semantics.
  static func revealInDEVONthink(uuid: String) async -> Result<Void, DevonthinkDataError> {
    await openInDEVONthink(uuid: uuid)
  }

  // MARK: - Copy to pasteboard

  /// Copy an `x-devonthink-item://` link for the given UUID to the pasteboard.
  static func copyItemLink(uuid: String) -> Result<Void, DevonthinkDataError> {
    let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(.scriptFailed("Cannot copy: UUID is empty"))
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("x-devonthink-item://\(trimmed)", forType: .string)
    return .success(())
  }

  /// Copy the given UUID to the pasteboard.
  static func copyUUID(uuid: String) -> Result<Void, DevonthinkDataError> {
    let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(.scriptFailed("Cannot copy: UUID is empty"))
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(trimmed, forType: .string)
    return .success(())
  }

  // MARK: - Create records via URL scheme

  /// Create a new plain text document in DEVONthink via the
  /// `x-devonthink://createText` URL scheme. Fire-and-forget.
  static func createText(title: String, text: String) -> Result<Void, DevonthinkDataError> {
    guard let encTitle = title.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed),
          let encText = text.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "x-devonthink://createText?title=\(encTitle)&text=\(encText)&noselector=1") else {
      return .failure(.scriptFailed("Could not build createText URL"))
    }
    guard NSWorkspace.shared.open(url) else {
      return .failure(.scriptFailed("DEVONthink could not open the create-text URL"))
    }
    return .success(())
  }

  /// Create a new note in DEVONthink from arbitrary text. Derives the title
  /// from the first non-empty line, then delegates to `createText`. Fire-and-forget.
  static func createNote(from body: String) {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let title = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
      .first.map(String.init) ?? "Note"
    _ = createText(title: title, text: trimmed)
  }


  // MARK: - Helpers

  /// Derive the database name from a record's filesystem path.
  /// DT4 stores files under `~/Databases/<Database Name>.dtBase2/Files.noindex/...`
  static func databaseName(from path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty else { return nil }

    let components = path.split(separator: "/")
    for component in components {
      let str = String(component)
      if str.hasSuffix(".dtBase2") {
        let dbName = str.replacingOccurrences(of: ".dtBase2", with: "")
        return dbName.isEmpty ? nil : dbName
      }
    }
    return nil
  }

  private static func cleanedOptional(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if trimmed.isEmpty { return nil }
    return trimmed
  }

  private static let bundleID = DEVONthinkBridge.bundleID
}
