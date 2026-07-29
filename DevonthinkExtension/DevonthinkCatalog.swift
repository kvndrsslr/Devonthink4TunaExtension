import AppKit
import Foundation
import TunaKit

// MARK: - Scoped search (live query catalog)

/// Live DEVONthink search catalog. Exposes a single scoped-search entry:
/// typing a query inside Tuna searches every open DEVONthink database and
/// returns matching documents as `DevonthinkRecordItem`s.
///
/// This is the ONLY catalog — there is no full-enumeration catalog. The
/// recursive tree walk required for full enumeration sends thousands of
/// Apple Events and cannot be made crash-safe (Swift cannot catch ObjC
/// NSException from ScriptingBridge if DEVONthink quits mid-walk). Scoped
/// search sends ~16 Apple Events per page — a 99%+ reduction in crash
/// surface — and never runs on launch, so Tuna opening no longer launches
/// DEVONthink.
///
/// Follows the BrewExtension provider-backed search pattern: the catalog
/// emits one meta item that conforms to `ScopedCatalogSearchProviding`,
/// and Tuna asks it for results as the user types.
@MainActor
public final class DevonthinkCatalog: NSObject, Catalog,
  RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String

  private let searchEntry: DevonthinkSearchEntryItem

  public var objects: [CatalogItem] { [searchEntry] }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.searchEntry = DevonthinkSearchEntryItem(catalogIdentifier: definition.identifier)
    super.init()
  }

  public func releaseRetainedState() {
    // No retained state — scoped search is stateless between queries.
  }

  public func scan() async {
    // Nothing to scan — results are fetched live via scopedSearchPage.
    reportScanFinished()
  }
}

// MARK: - Settings

enum DevonthinkSettings {
  static let pageSizeKey = "PageSize"
  static let pageSizeDefault = "7"
  static let searchComparisonKey = "SearchComparison"
  static let searchComparisonDefault = "0"
  static let autoLaunchKey = "AutoLaunchDevonthink"
  static let autoLaunchDefault = true

  static var pageSize: Int {
    let store = CatalogSettingStore(catalogIdentifier: "devonthink.search")
    let raw = store.stringValue(for: pageSizeKey, defaultValue: pageSizeDefault)
    let value = Int(raw) ?? Int(pageSizeDefault) ?? 3
    return max(1, min(value, 50))
  }

  static var searchComparison: Int {
    let store = CatalogSettingStore(catalogIdentifier: "devonthink.search")
    let raw = store.stringValue(for: searchComparisonKey, defaultValue: searchComparisonDefault)
    let value = Int(raw) ?? Int(searchComparisonDefault) ?? 0
    return max(0, min(value, 6))
  }

  /// When enabled, DEVONthink is launched in the background (without stealing
  /// focus) the moment the user enters the DEVONthink search context, and the
  /// extension waits for it to be ready to answer Apple Events before running
  /// the first search. When disabled, DEVONthink must already be running for
  /// search to work; otherwise an actionable "not running" item is shown.
  static var autoLaunchDevonthink: Bool {
    let store = CatalogSettingStore(catalogIdentifier: "devonthink.search")
    return store.boolValue(for: autoLaunchSetting)
  }

  /// Lazily-constructed `CatalogSettingDefinition` so the catalog declaration
  /// and the typed accessor share one source of truth for key/default/label.
  private static let autoLaunchSetting = CatalogSettingDefinition(
    key: autoLaunchKey,
    type: .bool,
    label: "Auto-launch DEVONthink",
    defaultValue: autoLaunchDefault ? "1" : "0",
    description: "Launch DEVONthink in the background and wait for it to be ready when entering the search. Turn off to require DEVONthink to already be running.")

  /// The setting definition surfaced to Tuna for the auto-launch preference.
  static var autoLaunchSettingDefinition: CatalogSettingDefinition {
    autoLaunchSetting
  }
}
