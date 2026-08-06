import Foundation
import TunaKit

@objc(DevonthinkExtension)
public final class DevonthinkExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "DEVONthink",
        author: "Tuna",
        description: "Search DEVONthink 4 documents, capture notes, and open them in DEVONthink or with the default app.",
        iconName: "books.vertical"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.83", minTunaKit: "1.17.0"),
      catalogs: [
        CatalogDeclaration(
          id: "devonthink.search",
          type: DevonthinkCatalog.self,
          name: "DEVONthink Search",
          enabledByDefault: true,
          settings: [
            CatalogSettingDefinition(
              key: "PageSize",
              type: .string,
              label: "Results per page",
              defaultValue: "7",
              description: "Number of results to load per page. Lower values show the first results faster."
            ),
            CatalogSettingDefinition(
              key: "SearchComparison",
              type: .string,
              label: "Search Comparison",
              defaultValue: "0",
              description: "Search comparison mode: 0=contains, 1=begins with, 2=ends with, 3=equals, 4=wildcard, 5=fuzzy, 6=boolean."
            ),
            DevonthinkSettings.autoLaunchSettingDefinition
          ])
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "devonthink.actions",
          type: DevonthinkActionsCatalog.self,
          name: "DEVONthink Actions")
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.devonthink-record"),
          displayName: "DEVONthink Documents",
          inheritsFrom: [TypeID("com.tuna.type.file")]),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.devonthink-group"),
          displayName: "DEVONthink Groups",
          inheritsFrom: [TypeID("com.tuna.type.directory")]),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.devonthink-search"),
          displayName: "DEVONthink Search",
          inheritsFrom: [TypeID("com.tuna.type.search-catalog-entry"), TypeID("com.tuna.type.entity")])
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.devonthink-record"),
          actions: [
            ActionReference(catalogIdentifier: "devonthink.actions", actionID: "open-in-devonthink")
          ]),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.devonthink-group"),
          actions: [
            ActionReference(catalogIdentifier: "devonthink.actions", actionID: "open-in-devonthink")
          ])
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: ["com.devon-technologies.think"],
          catalogIdentifiers: ["devonthink.actions"],
          preferredActions: [
            ActionReference(
              catalogIdentifier: "devonthink.actions",
              actionID: DevonthinkActionIDs.createNoteFromApp)
          ]
        )
      ]
    )
  }
}
