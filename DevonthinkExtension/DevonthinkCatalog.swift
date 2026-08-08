import AppKit
import Foundation
import TunaKit

// MARK: - Browse (loaded databases hierarchy + search)

/// Browsable DEVONthink catalog. Lists every currently loaded database as the
/// root of a navigable hierarchy: Tab/right-arrow into a database reveals its
/// top-level groups and documents, and into a group reveals its deeper contents.
///
/// Surfaced through `appBrowseEnrichments` when DEVONthink is the active app;
/// also reachable directly by its catalog prefix.
@MainActor
public final class DevonthinkBrowseCatalog: NSObject, Catalog,
  RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String

  private let searchEntry: DevonthinkSearchEntryItem
  private let browseEntry: DevonthinkBrowseEntryItem

  /// The catalog is purely static: it always lists the Search entry and the
  /// Browse entry, and never queries DEVONthink at scan time. DEVONthink is
  /// only contacted when the user triggers one of them — typing in Search, or
  /// navigating into Browse.
  public var objects: [CatalogItem] {
    [searchEntry, browseEntry]
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.searchEntry = DevonthinkSearchEntryItem(catalogIdentifier: definition.identifier)
    self.browseEntry = DevonthinkBrowseEntryItem(catalogIdentifier: definition.identifier)
    super.init()
  }

  public func releaseRetainedState() {
    // Drop any cached browse results so the next navigation into Browse
    // re-queries DEVONthink for its currently loaded databases.
    browseEntry.invalidate()
  }

  public func scan() async {
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
    let store = CatalogSettingStore(catalogIdentifier: "devonthink.databases")
    let raw = store.stringValue(for: pageSizeKey, defaultValue: pageSizeDefault)
    let value = Int(raw) ?? Int(pageSizeDefault) ?? 3
    return max(1, min(value, 50))
  }

  static var searchComparison: Int {
    let store = CatalogSettingStore(catalogIdentifier: "devonthink.databases")
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
    let store = CatalogSettingStore(catalogIdentifier: "devonthink.databases")
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

  // MARK: - Search transport (osascript vs raw in-process Apple Events)

  enum SearchTransport {
    case osascript
    case rawAppleEvents
  }

  static let useRawAECKey = "UseRawAppleEvents"

  /// Which engine drives search. Defaults to `.osascript` (the production,
  /// subprocess-isolated path). `.rawAppleEvents` enables the in-process AE
  /// engine for A/B performance comparison; it is opt-in.
  static var searchTransport: SearchTransport {
    let store = CatalogSettingStore(catalogIdentifier: "devonthink.databases")
    return store.boolValue(for: rawAESetting) ? .rawAppleEvents : .osascript
  }

  private static let rawAESetting = CatalogSettingDefinition(
    key: useRawAECKey,
    type: .bool,
    label: "Use in-process Apple Events (A/B test)",
    defaultValue: "0",
    description: "Search DEVONthink with raw in-process Apple Events instead of an osascript subprocess. Faster (no spawn/compile, bulk record fetch) but an experimental alternative — flip this to compare.")

  static var rawAESettingDefinition: CatalogSettingDefinition {
    rawAESetting
  }
}
