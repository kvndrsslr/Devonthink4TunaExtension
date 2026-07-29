import AppKit
import Foundation
import Quartz
import TunaKit

enum QuickLookActionIDs {
  static let quickLook = "quick-look"
}

public final class QuickLookActionsCatalog: NSObject, ActionCatalog {
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
      quickLookAction()
    ]
  }

  // MARK: - Quick Look

  /// "Quick Look" — opens the native macOS Quick Look preview panel for the
  /// file using `QLPreviewPanel`. This is the same panel Finder shows when
  /// pressing Space on a file.
  private static func quickLookAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: QuickLookActionIDs.quickLook,
      title: "Quick Look",
      type: .action
    ) { subject, _ in
      guard let entity = subject as? CatalogEntity, let path = entity.path else {
        return .failure("Cannot Quick Look: no file path")
      }
      QuickLookHelper.preview(fileAt: path)
      return .subjects([subject])
    }
    action.systemSymbolName = "eye"
    action.supportedSubjectTypes = [.file]
    action.subjectPredicate = { ($0 as? CatalogEntity)?.path != nil }
    return action
  }
}

// MARK: - Quick Look Helper

/// Manages the native macOS Quick Look preview panel (`QLPreviewPanel`).
/// The action callback runs on @MainActor, so QLPreviewPanel.shared()
/// returns the shared panel. Helper retains itself until the panel closes.
///
/// REVIEW(mikker): Is there a better way to show Quick Look from an action
/// while keeping Tuna open / preserving the current context?
/// Currently we return `.subjects([subject])` which keeps Tuna open but
/// re-shows the file as a subject. Ideally the action would show the
/// QLPreviewPanel without dismissing Tuna's search context.
private final class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

  private let url: URL

  private init(url: URL) {
    self.url = url
    super.init()
  }

  /// Open the native Quick Look panel for the file at `path`.
  /// Must be called from the main actor.
  static func preview(fileAt path: String) {
    let url = URL(fileURLWithPath: path)
    let helper = QuickLookHelper(url: url)

    guard let panel = QLPreviewPanel.shared() else { return }
    helper.retainUntilPanelCloses()
    panel.dataSource = helper
    panel.delegate = helper
    panel.currentPreviewItemIndex = 0
    panel.makeKeyAndOrderFront(nil)
  }

  /// Keep self alive until the preview panel is closed.
  private func retainUntilPanelCloses() {
    guard let panel = QLPreviewPanel.shared() else { return }
    let token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: panel,
      queue: .main
    ) { [self] _ in
      _ = self
    }
    objc_setAssociatedObject(self, &QuickLookHelper.retainKey, token, .OBJC_ASSOCIATION_RETAIN)
  }

  private static var retainKey: UInt8 = 0

  // MARK: - QLPreviewPanelDataSource

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    url as NSURL
  }

  // MARK: - QLPreviewPanelDelegate

  func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    false
  }
}
