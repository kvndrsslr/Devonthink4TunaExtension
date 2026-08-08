import AppKit
import Foundation
import TunaKit

private enum DevonthinkTypeRegistrations {
  static let registered: Void = {
    TypeRegistry.shared.register(.devonthinkRecord, inheritsFrom: [.file])
    TypeRegistry.shared.register(.devonthinkSearch, inheritsFrom: [.searchCatalogEntry, .entity])
    TypeRegistry.shared.register(.devonthinkGroup, inheritsFrom: [.directory])
    TypeRegistry.shared.register(.devonthinkDatabase, inheritsFrom: [.directory])
  }()
}

extension TypeID {
  static let devonthinkRecord = TypeID("com.tuna.type.devonthink-record")
  static let devonthinkSearch = TypeID("com.tuna.type.devonthink-search")
  static let devonthinkGroup = TypeID("com.tuna.type.devonthink-group")
  static let devonthinkDatabase = TypeID("com.tuna.type.devonthink-database")
}

/// The search-entry item offered by the `devonthink.databases` browse catalog.
/// Mirrors BrewExtension's `BrewMetaItem`: conforms to `CatalogHierarchyNode`
/// so Tuna can navigate into it (Tab → browse view with a search field), plus
/// `ScopedCatalogSearchPagingProviding` so typing a query runs `scopedSearchPage()`.
final class DevonthinkSearchEntryItem: CatalogEntity, ActionFilteringProviding,
  CatalogHierarchyNode, ScopedCatalogSearchPagingProviding, @unchecked Sendable
{
  private let catalogIdentifier: String

  init(catalogIdentifier: String) {
    _ = DevonthinkTypeRegistrations.registered
    self.catalogIdentifier = catalogIdentifier
    super.init(id: "devonthink.databases.search", title: "Search DEVONthink", path: nil)
    typeID = .devonthinkSearch
  }

  override var detail: String? {
    "Search all DEVONthink documents"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.catalogIcon(
      symbolName: "doc.text.magnifyingglass", color: .blue, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] { [] }

  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    // "search" is the common scoped-search action from Tuna's common actions catalog;
    // our own open actions apply once a real record is selected, so they do not apply here.
    action.id == "search"
  }

  func scopedSearchPage(query: String, page: Int) async throws -> ScopedSearchPage {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ScopedSearchPage(items: [], hasMore: false) }

    switch await DevonthinkData.searchPage(query: trimmed, page: page) {
    case .success(let (records, hasMore)):
      // `searchPage` awaits thumbnail attachment, so every row here already has
      // its DEVONthink cover in the shared cache — no post-render repaint dance.
      return ScopedSearchPage(
        items: records.map(DevonthinkRecordItem.init(record:)),
        hasMore: hasMore
      )
    case .failure:
      return ScopedSearchPage(items: [
        CatalogMessageItem(
          title: "DEVONthink Unavailable",
          message: "Could not search DEVONthink. It may not be reachable.",
          symbolName: "exclamationmark.triangle",
          tintColor: .systemOrange)
      ], hasMore: false)
    }
  }
}

/// The static "Browse" entry offered by the `devonthink.databases` browse
/// catalog. A non-searchable, navigable root: Tab/right-arrow into it triggers
/// a live query of DEVONthink that lists its currently loaded databases as
/// children. DEVONthink is NOT contacted at catalog scan time — only when the
/// user navigates into this entry.
final class DevonthinkBrowseEntryItem: CatalogEntity, CatalogHierarchyNode, @unchecked Sendable {
  private let loader: DevonthinkHierarchyLoader

  init(catalogIdentifier: String) {
    _ = DevonthinkTypeRegistrations.registered
    self.loader = DevonthinkHierarchyLoader(
      catalogIdentifier: catalogIdentifier,
      emptyMessage: "No DEVONthink databases are loaded."
    ) {
      // MCP auto-launches DEVONthink on demand, so no readiness pre-check is
      // needed — the query itself reports failure if DEVONthink isn't reachable.
      switch await DevonthinkData.loadedDatabases() {
      case .success(let databases):
        return .loaded(databases.map {
          DevonthinkDatabaseItem(database: $0, catalogIdentifier: catalogIdentifier)
        })
      case .failure:
        return .retry(
          CatalogMessageItem(
            title: "DEVONthink Unavailable",
            message: "Could not reach DEVONthink to browse its databases.",
            symbolName: "exclamationmark.triangle",
            tintColor: .systemOrange))
      }
    }
    super.init(id: "devonthink.databases.browse", title: "Browse DEVONthink", path: nil)
    typeID = .searchCatalogEntry
  }

  override var detail: String? {
    "Browse database contents"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.catalogIcon(
      symbolName: "folder", color: .orange, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    loader.currentChildren()
  }

  /// Drop any cached databases so the next navigation re-queries DEVONthink.
  func invalidate() {
    loader.invalidate()
  }
}

/// One DEVONthink search result, surfaced as a typed, stably identified entity.
/// `id` = the record UUID (permanent across rescans), `path` = the filesystem
/// path when the record has one (so Tuna attaches file icons/previews and the
/// built-in Open/Reveal actions apply automatically).
final class DevonthinkRecordItem: CatalogEntity, @unchecked Sendable {
  let record: DevonthinkRecord

  init(record: DevonthinkRecord) {
    _ = DevonthinkTypeRegistrations.registered
    self.record = record
    super.init(id: record.stableID, title: record.name, path: record.path)
    typeID = .devonthinkRecord
  }

  override var searchText: String {
    var parts = [record.name]
    if let location = record.location, !location.isEmpty {
      parts.append(location)
    }
    if let db = record.databaseName, !db.isEmpty {
      parts.append(db)
    }
    if let kind = record.kind, !kind.isEmpty {
      parts.append(kind)
    }
    return parts.joined(separator: " ")
  }

  override var detail: String? {
    var parts: [String] = []
    if let db = record.databaseName, !db.isEmpty {
      parts.append(db)
    }
    if let location = record.location, !location.isEmpty {
      parts.append(location)
    }
    if let kind = record.kind, !kind.isEmpty {
      parts.append(kind)
    }
    if parts.isEmpty { return nil }
    return parts.joined(separator: " • ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    // When a DEVONthink thumbnail is cached for this record, surface it as the
    // preview (and, in the result list, the icon) — a rendered cover rather
    // than a generic file icon. Tuna renders the result-list icon from
    // `preview(maxDimension:)`, so this is what puts the cover on each row.
    if let thumbnail = DevonthinkThumbnails.image(for: record.uuid) {
      return CatalogItemPreview(image: thumbnail)
    }
    if record.path != nil {
      return super.preview(maxDimension: maxDimension)
    }
    // Fall back to kind-based icon for records without a file path
    let (symbol, color) = DevonthinkRecordItem.icon(forKind: record.kind)
    return CatalogItemPreview.catalogIcon(symbolName: symbol, color: color, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

extension DevonthinkRecordItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    // Our own open actions plus any universal file actions (Open, Reveal, etc.).
    let ours = [
      DevonthinkActionIDs.openInDEVONthink,
      DevonthinkActionIDs.revealInDEVONthink,
      DevonthinkActionIDs.copyItemLink,
      DevonthinkActionIDs.copyUUID,
    ]
    if ours.contains(action.id) { return true }
    // Allow common built-in actions that apply to files.
    return action.id == "open" || action.id == "reveal" || action.id == "copy"
  }
}
private extension DevonthinkRecordItem {
  /// Pick an SF Symbol + Tuna color based on the DEVONthink record kind.
  /// Falls back to a generic text document icon when kind is unknown or empty.
  static func icon(forKind kind: String?) -> (symbol: String, color: CatalogIconColor) {
    let k = (kind ?? "").lowercased()
    if k.contains("pdf") { return ("doc.richtext", .red) }
    if k.contains("image") || k.contains("picture") { return ("photo", .green) }
    if k.contains("markdown") { return ("doc.text", .blue) }
    if k.contains("html") { return ("globe", .blue) }
    if k.contains("sheet") || k.contains("excel") { return ("tablecells", .green) }
    if k.contains("rtf") || k.contains("formatted") { return ("doc.richtext", .purple) }
    return ("doc.text", .blue)
  }
}

/// Shared lazy-loading state for DEVONthink hierarchy nodes (database access
/// root, database, and group). Mirrors Obsidian's `ObsidianVaultItem` load-state
/// machine: idle → loading → resolved, with a generation guard so a stale load
/// can't clobber a newer one. The async child fetch runs off the main actor; on
/// completion the resolved state is cached and a `CatalogDidFinishScan` is
/// posted (keyed by the catalog identifier) so Tuna re-fetches
/// `hierarchyChildren()`.
///
/// Resolving distinguishes two terminal states:
/// - `.loaded(items)` — DEVONthink answered and the contents are what they are.
///   Cached; an empty list renders the node's "Empty" message (genuinely empty).
/// - `.retry(message)` — a transient condition (DEVONthink not running/ready, or
///   a query failure). The message is rendered now, but the state is NOT cached
///   forever: the next access re-queries, so browsing self-heals the moment
///   DEVONthink is available again.
final class DevonthinkHierarchyLoader: @unchecked Sendable {
  /// The outcome of a child fetch, chosen by the caller.
  enum Outcome {
    /// Successfully fetched contents (possibly empty). Cached.
    case loaded([CatalogItem])
    /// Transient failure — show `message` but remain retriable.
    case retry(CatalogMessageItem)
  }

  private enum Phase {
    case idle
    case loading
    case loaded([CatalogItem])
    case retry(CatalogMessageItem)
  }

  private let catalogIdentifier: String?
  private let load: @Sendable () async -> Outcome
  private let emptyMessage: String

  private let phase = LockedValue<Phase>(.idle)
  private let generation = LockedValue(0)
  /// The generation value of the load currently driving progressive fills, so a
  /// `publishMore` from a stale load can't append to a newer one's results.
  private let activeGeneration = LockedValue(0)
  /// When the last retry was shown, so a retry isn't hot-looped by the
  /// `CatalogDidFinishScan` re-fetch that follows it while DEVONthink is down.
  private let lastRetryShown = LockedValue<Date>(.distantPast)
  private let retryCooldown: TimeInterval = 2

  init(
    catalogIdentifier: String?,
    emptyMessage: String,
    load: @escaping @Sendable () async -> Outcome
  ) {
    self.catalogIdentifier = catalogIdentifier
    self.emptyMessage = emptyMessage
    self.load = load
  }

  /// The rows to surface for this node right now. Triggers a load on first
  /// access; returns a loading row while loading and the resolved rows once
  /// known. A `.retry` state re-queries on a later access so the node heals
  /// once DEVONthink is available.
  func currentChildren() -> [CatalogItem] {
    requestLoadIfNeeded()
    switch phase.readValue { $0 } {
    case .idle, .loading:
      return [
        CatalogLoadingItem(
          title: "Loading…",
          message: "Fetching contents from DEVONthink.")
      ]
    case .loaded(let items):
      if items.isEmpty {
        return [
          CatalogMessageItem(
            title: "Empty",
            message: emptyMessage,
            symbolName: "tray",
            tintColor: .secondaryLabelColor)
        ]
      }
      return items
    case .retry(let message):
      return [message]
    }
  }

  /// Append more resolved children to an already-loaded node and tell Tuna to
  /// re-render. Powers the progressive fill of large containers: page 1 is
  /// published via the normal `.loaded` finalize, then deeper pages arrive here
  /// as they fetch. Safe from any thread; no-op if the node is no longer in the
  /// `.loaded` state or the generation has moved on (e.g. the node was
  /// invalidated and a fresh load started).
  func publishMore(_ items: [CatalogItem]) {
    guard !items.isEmpty else { return }
    // Belongs to the current load's generation; if a newer load took over,
    // this continuation is stale and must not clobber its results.
    guard generation.readValue { $0 } == activeGeneration.value else { return }

    let didAppend = phase.withValue { current -> Bool in
      guard case .loaded(let existing) = current else { return false }
      let known = Set(existing.map(\.id))
      let fresh = items.filter { !known.contains($0.id) }
      guard !fresh.isEmpty else { return false }
      current = .loaded(existing + fresh)
      return true
    }
    guard didAppend else { return }

    guard let catalogIdentifier = catalogIdentifier else { return }
    Task { @MainActor in
      NotificationCenter.default.post(
        name: CatalogDidFinishScan, object: catalogIdentifier)
    }
  }

  private func requestLoadIfNeeded() {
    let shouldStart = phase.withValue { current -> Bool in
      switch current {
      case .idle:
        return true
      case .retry:
        // Self-heal on a later access, but not on the immediate re-fetch that
        // the CatalogDidFinishScan notification triggers — that would hot-loop
        // spawning subprocesses while DEVONthink is down.
        return Date().timeIntervalSince(lastRetryShown.value) >= retryCooldown
      case .loading, .loaded:
        return false
      }
    }
    guard shouldStart else { return }

    phase.value = .loading
    let myGeneration = generation.readValue { $0 }
    activeGeneration.value = myGeneration
    Task.detached(priority: .utility) { [weak self] in
      let outcome = await (self?.load() ?? .loaded([]))
      await Task { @MainActor [weak self] in
        guard let self else { return }
        // Ignore stale loads: only apply if this generation hasn't been
        // invalidated while the fetch was in flight.
        let currentGeneration = self.generation.readValue { $0 }
        guard currentGeneration == myGeneration else { return }

        switch outcome {
        case .loaded(let items):
          self.phase.value = .loaded(items)
        case .retry(let message):
          self.phase.value = .retry(message)
          self.lastRetryShown.value = Date()
        }
        if let catalogIdentifier = self.catalogIdentifier {
          NotificationCenter.default.post(
            name: CatalogDidFinishScan, object: catalogIdentifier)
        }
      }.value
    }
  }

  /// Marks the cached rows stale so the next `hierarchyChildren()` re-fetches.
  func invalidate() {
    phase.value = .idle
    generation.withValue { $0 += 1 }
  }

  /// Wait for the initial `.loaded` finalize of the current load to land, so a
  /// progressive fill's first `publishMore` can't race it (if it ran first, the
  /// finalize would overwrite the freshly-appended rows). Returns false if the
  /// load became stale while waiting — the publish should abort.
  func awaitingInitialLoad() async -> Bool {
    let g = activeGeneration.value
    for _ in 0..<200 {  // up to ~2s; the finalize lands almost immediately after `load()` returns
      if generation.readValue { $0 } != g { return false }
      let isLoaded = phase.readValue { current -> Bool in
        if case .loaded = current { return true }
        return false
      }
      if isLoaded { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true // finalize didn't land in time; publish anyway
  }
}

/// Weak reference to a hierarchy loader, captured by an item's lazy-load closure
/// so it can reach its own loader during a progressive fill. Capturing `self`
/// directly in the closure would be disallowed (used before `super.init`), so a
/// weak box is filled after the loader is constructed instead.
private final class WeakLoaderRef: @unchecked Sendable {
  weak var loader: DevonthinkHierarchyLoader?
  init() {}
}

/// Maps raw browse records into display items: groups become navigable
/// `DevonthinkGroupItem`s, documents become `DevonthinkRecordItem`s.
private func devonthinkItems(
  from records: [DevonthinkRecord],
  catalogIdentifier: String?
) -> [CatalogItem] {
  records.compactMap { record -> CatalogItem? in
    if record.isGroup {
      return DevonthinkGroupItem(
        record: record, catalogIdentifier: catalogIdentifier)
    }
    return DevonthinkRecordItem(record: record)
  }
}

/// Fetch the immediate children of a database or group (by UUID) for a
/// hierarchy-loader `.Outcome`.
///
/// This is the single place that gates browsing on DEVONthink being alive and
/// ready: it waits (auto-launching if enabled) before querying, so a cold or
/// absent DEVONthink never surfaces as a misleading "empty" set. It also
/// distinguishes a genuinely empty container (`childrenPage` returns no
/// records, `.loaded([])`) from a transient failure (DEVONthink down/query
/// error, `.retry(message)`), so a stale failure is never cached — browsing
/// self-heals once DEVONthink is available again.
private func devonthinkChildren(
  of uuid: String,
  catalogIdentifier: String?,
  loader: DevonthinkHierarchyLoader?
) async -> DevonthinkHierarchyLoader.Outcome {
  // Progressive fill: `get_record_children` is superlinear in `offset` — the
  // deepest page of a large container alone can take seconds. So surface page 0
  // immediately as `.loaded`, and append the remaining pages in the background
  // via `loader.publishMore`, so the user sees content near-instantly and the
  // grid fills in progressively. Small batches (25) reveal the first content
  // fastest and give a smoother granular fill; the offset tail still dominates
  // total completion, but perceived latency is minimal.
  let pageSize = 25
  switch await DevonthinkData.childrenPage(of: uuid, offset: 0, limit: pageSize) {
  case .success(let (first, hasMore)):
    let firstItems = devonthinkItems(from: first, catalogIdentifier: catalogIdentifier)

    if hasMore {
      // Fetch the rest in the background, growing the rendered list page by page.
      Task.detached(priority: .utility) { [loader, catalogIdentifier] in
        // The initial `.loaded` finalize (page 0) must land before we append
        // deeper pages, else we'd race it and lose rows.
        guard await loader?.awaitingInitialLoad() ?? true else { return }
        var offset = first.count
        while true {
          let result = await DevonthinkData.childrenPage(
            of: uuid, offset: offset, limit: pageSize)
          guard case .success(let (records, stillMore)) = result, !records.isEmpty else {
            break
          }
          loader?.publishMore(
            devonthinkItems(from: records, catalogIdentifier: catalogIdentifier))
          guard stillMore else { break }
          offset += records.count
        }
      }
    }

    return .loaded(firstItems)

  case .failure:
    return .retry(
      CatalogMessageItem(
        title: "DEVONthink Unavailable",
        message: "Could not read DEVONthink contents. It may not be reachable.",
        symbolName: "exclamationmark.triangle",
        tintColor: .systemOrange))
  }
}

/// A DEVONthink group (folder) surfaced as a browsable catalog item.
/// Uses a folder icon, inherits directory actions (Open, Reveal) for free via
/// the `devonthink-group` type registration inheriting from `.directory`, and
/// lazily loads its children for deep browsing.
final class DevonthinkGroupItem: CatalogEntity, CatalogHierarchyNode, @unchecked Sendable {
  let record: DevonthinkRecord
  private let loader: DevonthinkHierarchyLoader

  init(record: DevonthinkRecord, catalogIdentifier: String? = nil) {
    _ = DevonthinkTypeRegistrations.registered
    self.record = record
    let loaderRef = WeakLoaderRef()
    self.loader = DevonthinkHierarchyLoader(
      catalogIdentifier: catalogIdentifier,
      emptyMessage: "This group contains no items."
    ) { [uuid = record.uuid, loaderRef] in
      await devonthinkChildren(
        of: uuid, catalogIdentifier: catalogIdentifier,
        loader: loaderRef.loader)
    }
    loaderRef.loader = self.loader
    super.init(id: record.stableID, title: record.name, path: record.path)
    typeID = .devonthinkGroup
  }

  override var searchText: String {
    var parts = [record.name]
    if let location = record.location, !location.isEmpty {
      parts.append(location)
    }
    if let db = record.databaseName, !db.isEmpty {
      parts.append(db)
    }
    return parts.joined(separator: " ")
  }

  override var detail: String? {
    var parts: [String] = []
    if let db = record.databaseName, !db.isEmpty {
      parts.append(db)
    }
    if let location = record.location, !location.isEmpty {
      parts.append(location)
    }
    if let kind = record.kind, !kind.isEmpty {
      parts.append(kind)
    }
    if parts.isEmpty { return nil }
    return parts.joined(separator: " • ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.catalogIcon(
      symbolName: "folder", color: .indigo, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    loader.currentChildren()
  }
}

extension DevonthinkGroupItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    let ours = [
      DevonthinkActionIDs.openInDEVONthink,
      DevonthinkActionIDs.revealInDEVONthink,
      DevonthinkActionIDs.copyItemLink,
      DevonthinkActionIDs.copyUUID,
    ]
    if ours.contains(action.id) { return true }
    return action.id == "open" || action.id == "reveal" || action.id == "copy"
  }
}

/// A loaded DEVONthink database, surfaced as the browsable root of the browse
/// catalog. Uses an archive/folder icon, inherits directory actions via the
/// `devonthink-database` type registration inheriting from `.directory`, and
/// lazily loads its top-level groups and documents for browsing.
final class DevonthinkDatabaseItem: CatalogEntity, CatalogHierarchyNode, @unchecked Sendable {
  let database: DevonthinkDatabase
  private let catalogIdentifier: String
  private let loader: DevonthinkHierarchyLoader

  init(database: DevonthinkDatabase, catalogIdentifier: String) {
    _ = DevonthinkTypeRegistrations.registered
    self.database = database
    self.catalogIdentifier = catalogIdentifier
    let loaderRef = WeakLoaderRef()
    self.loader = DevonthinkHierarchyLoader(
      catalogIdentifier: catalogIdentifier,
      emptyMessage: "This database contains no top-level items."
    ) { [uuid = database.uuid, loaderRef] in
      await devonthinkChildren(
        of: uuid, catalogIdentifier: catalogIdentifier,
        loader: loaderRef.loader)
    }
    loaderRef.loader = self.loader
    super.init(id: database.uuid, title: database.name, path: database.path)
    typeID = .devonthinkDatabase
  }

  override var detail: String? {
    database.path
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("archivebox", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    loader.currentChildren()
  }
}

extension DevonthinkDatabaseItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    // Databases are directories; only the built-in directory actions apply.
    action.id == "open" || action.id == "reveal" || action.id == "copy"
  }
}


