import Foundation
import TunaKit

@objc(QuickLookExtension)
public final class QuickLookExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Quick Look",
        author: "Tuna",
        description: "Quick Look any file directly from Tuna.",
        iconName: "eye"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.83", minTunaKit: "1.17.0"),
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "quicklook.actions",
          type: QuickLookActionsCatalog.self,
          name: "Quick Look Actions")
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.file"),
          displayName: "Files",
          inheritsFrom: [])
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.file"),
          actions: [
            ActionReference(catalogIdentifier: "quicklook.actions", actionID: "quick-look")
          ])
      ]
    )
  }
}
