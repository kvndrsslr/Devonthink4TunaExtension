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
      createNoteFromAppAction()
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

