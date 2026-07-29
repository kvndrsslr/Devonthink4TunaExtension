import AppKit
import Foundation
import TunaKit

private enum DevonthinkTypeRegistrations {
  static let registered: Void = {
    TypeRegistry.shared.register(.devonthinkRecord, inheritsFrom: [.file])
    TypeRegistry.shared.register(.devonthinkSearch, inheritsFrom: [.searchCatalogEntry, .entity])
    TypeRegistry.shared.register(.devonthinkGroup, inheritsFrom: [.directory])
  }()
}

extension TypeID {
  static let devonthinkRecord = TypeID("com.tuna.type.devonthink-record")
  static let devonthinkSearch = TypeID("com.tuna.type.devonthink-search")
  static let devonthinkGroup = TypeID("com.tuna.type.devonthink-group")
}

/// The single search-entry item produced by `DevonthinkCatalog`. Mirrors
/// BrewExtension's `BrewMetaItem`: conforms to `CatalogHierarchyNode` so Tuna
/// can navigate into it (Tab → browse view with a search field), plus
/// `ScopedCatalogSearchProviding` so typing a query runs `scopedSearch()`.
final class DevonthinkSearchEntryItem: CatalogEntity, ActionFilteringProviding,
  CatalogHierarchyNode, ScopedCatalogSearchPagingProviding, @unchecked Sendable
{
  private let catalogIdentifier: String

  init(catalogIdentifier: String) {
    _ = DevonthinkTypeRegistrations.registered
    self.catalogIdentifier = catalogIdentifier
    super.init(id: "devonthink.search", title: "DEVONthink", path: nil)
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

    // Ensure DEVONthink is up and answering Apple Events before searching.
    // With auto-launch on, this launches DT in the background and waits for
    // readiness; with it off, it only waits if DT is already running and
    // returns the unavailable item immediately otherwise.
    let autoLaunch = DevonthinkSettings.autoLaunchDevonthink
    let ready = await DEVONthinkBridge.ensureReady(autoLaunch: autoLaunch)
    guard ready else {
      return ScopedSearchPage(items: [
        CatalogMessageItem(
          title: "DEVONthink Not Running",
          message: "DEVONthink must be running to search its databases.",
          symbolName: "exclamationmark.triangle",
          tintColor: .systemOrange)
      ], hasMore: false)
    }

    switch await DevonthinkData.searchPage(query: trimmed, page: page, pageSize: DevonthinkSettings.pageSize) {
    case .success(let (records, hasMore)):
      return ScopedSearchPage(
        items: records.map(DevonthinkRecordItem.init(record:)),
        hasMore: hasMore
      )
    case .failure:
      return ScopedSearchPage(items: [
        CatalogMessageItem(
          title: "DEVONthink Unavailable",
          message: "Could not search DEVONthink. It may have quit or be unresponsive.",
          symbolName: "exclamationmark.triangle",
          tintColor: .systemOrange)
      ], hasMore: false)
    }
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
    let ours = ["open-in-devonthink", "reveal-in-devonthink", "copy-item-link", "copy-uuid"]
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

/// A DEVONthink group (folder) surfaced as a searchable catalog item.
/// Uses a folder icon and inherits directory actions (Open, Reveal) for free
/// via the `devonthink-group` type registration inheriting from `.directory`.
final class DevonthinkGroupItem: CatalogEntity, @unchecked Sendable {
  let record: DevonthinkRecord

  init(record: DevonthinkRecord) {
    _ = DevonthinkTypeRegistrations.registered
    self.record = record
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
}

extension DevonthinkGroupItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    let ours = ["open-in-devonthink", "reveal-in-devonthink", "copy-item-link", "copy-uuid"]
    if ours.contains(action.id) { return true }
    return action.id == "open" || action.id == "reveal" || action.id == "copy"
  }
}

