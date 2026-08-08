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
