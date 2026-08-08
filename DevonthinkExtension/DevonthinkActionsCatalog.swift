import AppKit
import Foundation
import TunaKit

enum DevonthinkActionIDs {
  static let openInDEVONthink = "open-in-devonthink"
  static let revealInDEVONthink = "reveal-in-devonthink"
  static let copyItemLink = "copy-item-link"
  static let copyUUID = "copy-uuid"
  static let createNote = "create-note"
  static let createNoteFromApp = "create-note.from-app"
  static let searchInDEVONthink = "search-in-devonthink"
}

public final class DevonthinkActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.actions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  static func actions() -> [CatalogAction] {
    [
      openInDEVONthinkAction(),
      revealInDEVONthinkAction(),
      copyItemLinkAction(),
      copyUUIDAction(),
      createNoteAction(),
      createNoteFromAppAction(),
      searchInDEVONthinkAction()
    ]
  }

  // MARK: - Open in DEVONthink

  private static func openInDEVONthinkAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: DevonthinkActionIDs.openInDEVONthink,
      title: "Open in DEVONthink"
    ) { subject, _ in
      let uuid: String
      if let item = subject as? DevonthinkRecordItem {
        uuid = item.record.uuid
      } else if let group = subject as? DevonthinkGroupItem {
        uuid = group.record.uuid
      } else {
        return .failure("No DEVONthink item selected")
      }
      Task.detached(priority: .utility) { _ = await DevonthinkData.openInDEVONthink(uuid: uuid) }
      return .success
    }
    action.systemSymbolName = "books.vertical"
    action.supportedSubjectTypes = [.devonthinkRecord, .devonthinkGroup]
    action.subjectPredicate = { $0 is DevonthinkRecordItem || $0 is DevonthinkGroupItem }
    return action
  }

  // MARK: - Reveal in DEVONthink

  private static func revealInDEVONthinkAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: DevonthinkActionIDs.revealInDEVONthink,
      title: "Reveal in DEVONthink"
    ) { subject, _ in
      let uuid: String
      if let item = subject as? DevonthinkRecordItem {
        uuid = item.record.uuid
      } else if let group = subject as? DevonthinkGroupItem {
        uuid = group.record.uuid
      } else {
        return .failure("No DEVONthink item selected")
      }
      Task.detached(priority: .utility) {
        // Use x-devonthink-item:// URL to reveal the item in DEVONthink's browser
        if let url = URL(string: "x-devonthink-item://\(uuid)") {
          _ = NSWorkspace.shared.open(url)
        }
      }
      return .success
    }
    action.systemSymbolName = "magnifyingglass"
    action.supportedSubjectTypes = [.devonthinkRecord, .devonthinkGroup]
    action.subjectPredicate = { $0 is DevonthinkRecordItem || $0 is DevonthinkGroupItem }
    return action
  }

  // MARK: - Copy Item Link

  private static func copyItemLinkAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: DevonthinkActionIDs.copyItemLink,
      title: "Copy Item Link"
    ) { subject, _ in
      let uuid: String
      if let item = subject as? DevonthinkRecordItem {
        uuid = item.record.uuid
      } else if let group = subject as? DevonthinkGroupItem {
        uuid = group.record.uuid
      } else {
        return .failure("No DEVONthink item selected")
      }
      _ = DevonthinkData.copyItemLink(uuid: uuid)
      return .success
    }
    action.systemSymbolName = "link"
    action.supportedSubjectTypes = [.devonthinkRecord, .devonthinkGroup]
    action.subjectPredicate = { $0 is DevonthinkRecordItem || $0 is DevonthinkGroupItem }
    return action
  }

  // MARK: - Copy UUID

  private static func copyUUIDAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: DevonthinkActionIDs.copyUUID,
      title: "Copy UUID"
    ) { subject, _ in
      let uuid: String
      if let item = subject as? DevonthinkRecordItem {
        uuid = item.record.uuid
      } else if let group = subject as? DevonthinkGroupItem {
        uuid = group.record.uuid
      } else {
        return .failure("No DEVONthink item selected")
      }
      _ = DevonthinkData.copyUUID(uuid: uuid)
      return .success
    }
    action.systemSymbolName = "number"
    action.supportedSubjectTypes = [.devonthinkRecord, .devonthinkGroup]
    action.subjectPredicate = { $0 is DevonthinkRecordItem || $0 is DevonthinkGroupItem }
    return action
  }

  // MARK: - Capture to DEVONthink (verb on any text snippet)

  /// "Capture to DEVONthink" — works on any `.textSnippet` subject in Tuna.
  /// Select text, Tab to actions, pick this to create a new note in DEVONthink
  /// via the `x-devonthink://createText` URL scheme. Mirrors Notes'
  /// `create-note` action.
  private static func createNoteAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: DevonthinkActionIDs.createNote,
      title: "Capture to DEVONthink"
    ) { subject, _ in
      guard subject.typeID == .textSnippet else {
        return .failure("Select text first")
      }
      guard let body = subject.textValueFallback() else {
        return .failure("Missing note text")
      }
      Task.detached(priority: .utility) {
        DevonthinkData.createNote(from: body)
      }
      return .success
    }
    action.systemSymbolName = "plus.circle"
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = { subject in
      guard let subject else { return false }
      return subject.typeID == .textSnippet && subject.textValueFallback() != nil
    }
    return action
  }

  // MARK: - Capture to DEVONthink (from app with text target)

  /// When the DEVONthink app is the subject and a text snippet is the target,
  /// create a note from that text. Mirrors Notes' `create-note.from-app`.
  private static func createNoteFromAppAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: DevonthinkActionIDs.createNoteFromApp,
      title: "Capture to DEVONthink"
    ) { _, target in
      guard let body = target?.textValueFallback() else {
        return .failure("Missing note text")
      }
      Task.detached(priority: .utility) {
        DevonthinkData.createNote(from: body)
      }
      return .success
    }
    action.targetRequirement = .required
    action.systemSymbolName = "plus.circle"
    action.supportedSubjectTypes = [.application]
    action.allowedTargetTypes = [.textSnippet]
    action.subjectPredicate = { subject in
      DevonthinkActionsCatalog.isDevonthinkApplication(subject)
    }
    action.targetPredicate = { $0?.textValueFallback() != nil }
    return action
  }

  // MARK: - Search in DEVONthink (verb on a text input)

  /// "Search in DEVONthink" — opens the same scoped-search view used by the
  /// other search triggers, prefilling the query from the selected text. It
  /// does NOT shelf results and only applies to raw text input (not the
  /// DEVONthink app).
  ///
  /// The search view is opened by conforming the action to
  /// `SubjectScopedSearchActionProviding`; the callback is a no-op fallback so
  /// nothing is shelved.
  private static func searchInDEVONthinkAction() -> CatalogAction {
    let action = DevonthinkSearchAction(
      id: DevonthinkActionIDs.searchInDEVONthink,
      title: "Search in DEVONthink"
    )
    action.systemSymbolName = "magnifyingglass"
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = { subject in
      guard let subject, subject.typeID == .textSnippet else { return false }
      return subject.textValueFallback() != nil
    }
    return action
  }
}

// MARK: - Search-view routing

/// The "Search in DEVONthink" action.
///
/// A dedicated `CatalogAction` subclass — NOT a retroactive conformance on the
/// shared `PredicateAwareAction` base class. Adding
/// `extension PredicateAwareAction: SubjectScopedSearchActionProviding` makes
/// **every** `PredicateAwareAction` in the process (Tuna's own common actions
/// and every other extension's actions) advertise itself as a scoped-search
/// provider, which breaks Tuna's Combo Mode action routing with
/// "Missing search query" errors. Confining the conformance to this one class
/// (mirroring BrewExtension's `SubjectTextSearchAction`) leaves other actions
/// untouched.
private final class DevonthinkSearchAction: CatalogAction, ActionPredicateProviding,
  SubjectScopedSearchActionProviding, @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate?
  var targetPredicate: CatalogActionTargetPredicate?
  var subjectScopedSearchRootCatalogIdentifier: String? { "devonthink.databases" }

  init(id: String, title: String) {
    super.init(id: id, title: title) { _, _ in .success }
  }

  func subjectScopedSearchQuery(from subject: CatalogItem) -> String? {
    subject.textValueFallback()?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func subjectScopedSearchRoot(for _: CatalogItem) -> CatalogItem? {
    DevonthinkSearchEntryItem(catalogIdentifier: "devonthink.databases")
  }
}

// MARK: - Helpers

private enum DevonthinkActions {
  static func isDevonthinkApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
      == DEVONthinkBridge.bundleID
  }
}

private extension DevonthinkActionsCatalog {
  static var isDevonthinkApplication: (CatalogItem?) -> Bool {
    DevonthinkActions.isDevonthinkApplication
  }
}

