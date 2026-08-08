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

  /// A copy with a new filesystem path. MCP record briefs carry no path, so it
  /// is attached afterwards by the batch `get_imported_record_path` enrichment.
  func withPath(_ newPath: String?) -> DevonthinkRecord {
    DevonthinkRecord(
      uuid: uuid, name: name, path: newPath,
      location: location, databaseName: databaseName, kind: kind)
  }
}

/// A loaded DEVONthink database (top-level container served by the browse
/// catalog). `name` matches DEVONthink's database name; `uuid` is the database's
/// stable record UUID (used to enumerate root contents via the same
/// `get_record_children` path used for groups). `path` is the `.dtBase2` bundle
/// path when known — the MCP `get_databases` brief does not include it, so it is
/// nil in practice (the database item identifies itself by UUID instead).
struct DevonthinkDatabase: Hashable, Sendable {
  let name: String
  let uuid: String
  let path: String?
}

enum DevonthinkDataError: Error, LocalizedError, Sendable {
  case devonthinkNotRunning
  case scriptFailed(String)
  case noResults

  var errorDescription: String? {
    switch self {
    case .devonthinkNotRunning:
      return "DEVONthink could not be reached. Open DEVONthink and try again."
    case .scriptFailed(let message):
      return "DEVONthink query failed: \(message)"
    case .noResults:
      return "No DEVONthink documents matched."
    }
  }
}

/// In-memory cache of DEVONthink thumbnails, keyed by record UUID.
///
/// Thumbnails are fetched in batch (`get_record_thumbnails`) during page and
/// container loads and decoded into `NSImage`s. Items read them synchronously
/// from `image(size:)`, which Tuna calls to render the result-list and
/// browse-grid icons. Keyed by the record's stable UUID so each record caches
/// its own thumbnail across loads.
enum DevonthinkThumbnails {
  private static let lock = NSLock()
  private static var cache: [String: NSImage] = [:]

  /// The cached thumbnail for a record UUID, if one has been fetched.
  static func image(for uuid: String) -> NSImage? {
    lock.lock(); defer { lock.unlock() }
    return cache[uuid]
  }

  static func store(_ image: NSImage, for uuid: String) {
    lock.lock(); defer { lock.unlock() }
    cache[uuid] = image
  }
}

/// Data access to DEVONthink 4 via its bundled MCP stdio server.
///
/// Every query runs through `DevonthinkMCP`, a persistent JSON-RPC client to
/// DEVONthink's own MCP server (spawned in a child process with `--stdio`).
/// The server talks to a running DEVONthink and auto-launches it on demand, so
/// the extension never has to launch or await DEVONthink itself. Running in a
/// child process keeps Tuna safe: a crashed or hung server — or DEVONthink
/// itself — affects only that child, never the extension host.
enum DevonthinkData {

  // MARK: - Search (paged)

  /// Page size for progressive search results.
  static let pageSize = 3

  /// Search and return one page of results. Page 0 is the first `pageSize`
  /// records. Searches run through the DEVONthink MCP server, which auto-launches
  /// DEVONthink on demand, so no liveness pre-check is needed — the call itself
  /// reports failure if DEVONthink can't be reached.
  static func searchPage(query: String, page: Int, pageSize: Int = DevonthinkData.pageSize) async -> Result<(records: [DevonthinkRecord], hasMore: Bool), DevonthinkDataError> {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return .success(([], false)) }

    // Tuna pages are 1-indexed; MCP offsets are 0-based.
    let offset = max(0, (page - 1) * pageSize)
    let result = await DevonthinkMCP.call(tool: "search_records", arguments: [
      "query": normalized,
      "limit": pageSize,
      "offset": offset,
    ])

    guard result.success, let payload = result.dict else {
      return .failure(selfFailureMessage(result))
    }

    let parsed = parseSearchResults(payload)
    await attachThumbnails(to: parsed)
    let records = await attachFilePaths(to: parsed)
    let total = payload["total"] as? Int ?? records.count
    let sliceEnd = ((page - 1) * pageSize) + pageSize
    let hasMore = sliceEnd < total
    return .success((records, hasMore))
  }

  /// Attach filesystem paths to records so Tuna can preview, open-in-default-app,
  /// and reveal them. MCP record briefs carry no path, so it must be fetched
  /// separately via the batch `get_imported_record_path` tool (one extra warm
  /// round-trip). Records that don't resolve to a file (e.g. groups, indexed
  /// externals) keep a nil path and fall back to a kind-based icon.
  private static func attachFilePaths(to records: [DevonthinkRecord]) async -> [DevonthinkRecord] {
    guard !records.isEmpty else { return records }
    let uuids = records.map(\.uuid)
    let result = await DevonthinkMCP.call(tool: "get_imported_record_path", arguments: ["uuids": uuids])
    guard result.success, let payload = result.dict,
          let hits = payload["results"] as? [[String: Any]] else {
      return records
    }
    var pathByUUID: [String: String] = [:]
    for hit in hits {
      if let uuid = hit["uuid"] as? String,
         let path = hit["path"] as? String, !path.isEmpty {
        pathByUUID[uuid] = path
      }
    }
    guard !pathByUUID.isEmpty else { return records }
    return records.map { record in
      guard let path = pathByUUID[record.uuid] else { return record }
      return record.withPath(path)
    }
  }

  /// Fetch and cache DEVONthink thumbnails for records via the batch
  /// `get_record_thumbnails` tool. Each hit is `{uuid, data_uri}` where
  /// `data_uri` is `data:image/jpeg;base64,<base64>`; the decoded image is
  /// stored in `DevonthinkThumbnails` so `image(size:)` on items can render it
  /// synchronously (Tuna calls that to draw the result-list / browse icons).
  /// Records without a thumbnail (e.g. groups, indexed externals) are skipped.
  private static func attachThumbnails(to records: [DevonthinkRecord]) async {
    guard !records.isEmpty else { return }
    let uuids = records.map(\.uuid)
    let result = await DevonthinkMCP.call(tool: "get_record_thumbnails", arguments: [
      "uuids": uuids,
      "max_dim": 256,
    ])
    guard result.success, let payload = result.dict,
          let hits = payload["results"] as? [[String: Any]] else { return }
    for hit in hits {
      guard let uuid = hit["uuid"] as? String,
            let uri = hit["data_uri"] as? String,
            let comma = uri.firstIndex(of: ",") else { continue }
      let base64 = String(uri[uri.index(after: comma)...])
      guard let data = Data(base64Encoded: base64),
            let image = NSImage(data: data) else { continue }
      DevonthinkThumbnails.store(image, for: uuid)
    }
  }

  // MARK: - MCP search parsing

  /// Map an MCP `search_records` payload (`{results:[...], total, offset, limit}`)
  /// into `DevonthinkRecord`s. The brief hit shape is `{uuid, name, type, kind,
  /// location, databaseName, databaseUUID, tags, tagCount, additionDate,
  /// modificationDate, score, doi, isbn, indexed}` — there is no filesystem
  /// `path` in the brief, so `path` is nil and `location`/`databaseName` come
  /// straight from the brief.
  private static func parseSearchResults(_ payload: [String: Any]) -> [DevonthinkRecord] {
    guard let results = payload["results"] as? [[String: Any]] else { return [] }
    return results.compactMap { record(fromBrief: $0) }
  }

  /// Build a `DevonthinkRecord` from an MCP record brief dict.
  static func record(fromBrief brief: [String: Any]) -> DevonthinkRecord? {
    guard let uuid = brief["uuid"] as? String, !uuid.isEmpty else { return nil }
    let name = (brief["name"] as? String) ?? ""
    let location = cleanedOptional(brief["location"] as? String)
    let databaseName = cleanedOptional(brief["databaseName"] as? String)
    let kind = cleanedOptional(brief["kind"] as? String)
    return DevonthinkRecord(
      uuid: uuid,
      name: name.isEmpty ? "Untitled" : name,
      path: nil, // MCP briefs carry no filesystem path
      location: location,
      databaseName: databaseName,
      kind: kind)
  }

  /// Map an MCP failure `CallResult` onto a `DevonthinkDataError`.
  private static func selfFailureMessage(_ result: DevonthinkMCP.CallResult) -> DevonthinkDataError {
    if let message = result.errorMessage, !message.isEmpty {
      return .scriptFailed(message)
    }
    return .devonthinkNotRunning
  }

  // MARK: - Databases (browse root)

  /// List the currently loaded DEVONthink databases via `get_databases`. MCP
  /// returns `{name, uuid, rootUUID, ...}` — no filesystem path.
  static func loadedDatabases() async -> Result<[DevonthinkDatabase], DevonthinkDataError> {
    let result = await DevonthinkMCP.call(tool: "get_databases", arguments: [:])
    guard result.success else {
      return .failure(selfFailureMessage(result))
    }
    // get_databases returns a bare array of database dicts.
    var databases: [DevonthinkDatabase] = []
    if let array = result.array {
      for db in array {
        guard let name = db["name"] as? String, !name.isEmpty,
              let uuid = db["uuid"] as? String, !uuid.isEmpty else { continue }
        databases.append(DevonthinkDatabase(name: name, uuid: uuid, path: nil))
      }
    }
    return .success(databases)
  }

  // MARK: - Children (browse into database/group)

  /// Return the immediate children of a database or group (by UUID) via
  /// `get_record_children`. Brief hits map identically to search results.
  static func children(of uuid: String) async -> Result<[DevonthinkRecord], DevonthinkDataError> {
    let result = await DevonthinkMCP.call(tool: "get_record_children", arguments: [
      "uuid": uuid,
      "limit": 1000,
    ])
    guard result.success, let payload = result.dict else {
      return .failure(selfFailureMessage(result))
    }
    guard let items = payload["items"] as? [[String: Any]], !items.isEmpty else {
      return .failure(.noResults)
    }
    let parsed = items.compactMap { record(fromBrief: $0) }
    await attachThumbnails(to: parsed)
    let records = await attachFilePaths(to: parsed)
    return .success(records)
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

  // MARK: - Create records via MCP

  /// Create a new plain-text record in DEVONthink via the MCP `create_record`
  /// tool. Unlike the old `x-devonthink://createText` URL scheme, this goes
  /// through DEVONthink's own server, which guarantees the text lands in the
  /// correct field regardless of special characters.
  static func createText(title: String, text: String) -> Result<Void, DevonthinkDataError> {
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<Void, DevonthinkDataError> = .failure(.scriptFailed("Create did not complete"))
    Task.detached(priority: .userInitiated) {
      let result = await DevonthinkMCP.call(tool: "create_record", arguments: [
        "name": title,
        "type": "text",
        "content": text,
      ])
      if result.success {
        outcome = .success(())
      } else {
        outcome = .failure(selfFailureMessage(result))
      }
      semaphore.signal()
    }
    semaphore.wait()
    return outcome
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

  private static func cleanedOptional(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if trimmed.isEmpty { return nil }
    return trimmed
  }
}
