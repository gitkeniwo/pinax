import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import PinaxUI

/// The source marker in the grid, its settings and
/// menu item, the Table column, the Inspector row and the find strip's
/// Source popup.
@MainActor
@Suite(.serialized) struct SourceTagTests {
  static let picgoMeta = #"{"imported_from":"picgo"}"#
  static let bucketMeta = #"{"imported_from":"externals"}"#
  static let migratedMeta = #"{"source_url":"https://old.pinax.invalid/a.png"}"#
  static let otherMeta = #"{"imported_from":"hexo"}"#

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-sourcetag-\(UUID().uuidString)"))
  }

  /// Six assets: 1 Pinax, 2 PicGo, 2 Bucket, 1 migrated. Names make the
  /// search leg: the PicGo ones and one Pinax one contain "cat".
  private func seed(_ database: DatabasePool) throws {
    let rows: [(String, String, String)] = [
      ("cat-pinax.png", "{}", "2026-08-01T10:00:00Z"),
      ("cat-picgo-1.png", Self.picgoMeta, "2026-08-02T10:00:00Z"),
      ("cat-picgo-2.png", Self.picgoMeta, "2026-08-03T10:00:00Z"),
      ("dog-bucket-1.png", Self.bucketMeta, "2026-08-04T10:00:00Z"),
      ("dog-bucket-2.png", Self.bucketMeta, "2026-08-05T10:00:00Z"),
      ("dog-migrated.png", Self.migratedMeta, "2026-08-06T10:00:00Z"),
    ]
    for (index, row) in rows.enumerated() {
      try seedAsset(
        database, index: index, uploadedAt: row.2, origFilename: row.0, meta: row.1)
    }
  }

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-sourcetag-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  // MARK: - 1. The caption function

  /// (style, source) → (placement, icon, text, help) at the large tier with
  /// the filename on; the tier and filename legs follow below.
  @Test("Every style × source: icon, text, colour role, placement")
  func captionMatrix() {
    let marked: [(AssetSource, String, String, SourceTint)] = [
      (.picgo, "photo.on.rectangle", "PicGo", .picgo),
      (.bucket, "cylinder", "Bucket", .bucket),
    ]
    for tier in SourceTier.allCases {
      for (source, icon, name, tint) in marked {
        // The Date line style draws only the 13 × 13 square at
        // every tier; the name is the hover text.
        #expect(
          SourceCaption.make(style: .dateLine, source: source, tier: tier, showsFilename: true)
            == SourceCaption(placement: .dateLine, icon: icon, tint: tint, text: nil, help: name),
          "date line \(source) \(tier)")
        #expect(
          SourceCaption.make(style: .pill, source: source, tier: tier, showsFilename: true)
            == SourceCaption(placement: .pill, icon: icon, tint: tint, text: name, help: nil),
          "pill \(source) \(tier)")
        #expect(
          SourceCaption.make(style: .dot, source: source, tier: tier, showsFilename: true)
            == SourceCaption(placement: .dot, icon: nil, tint: tint, text: name, help: nil),
          "dot \(source) \(tier)")
        #expect(
          SourceCaption.make(style: .beforeName, source: source, tier: tier, showsFilename: true)
            == SourceCaption(
              placement: .beforeFilename, icon: icon, tint: tint, text: nil, help: name),
          "before name, filename on: \(source) \(tier)")
        // With the filename off the icon starts the date line, no text.
        #expect(
          SourceCaption.make(style: .beforeName, source: source, tier: tier, showsFilename: false)
            == SourceCaption(
              placement: .beforeDate, icon: icon, tint: tint, text: nil, help: name),
          "before name, filename off: \(source) \(tier)")
        #expect(
          SourceCaption.make(style: .off, source: source, tier: tier, showsFilename: true) == nil)
      }
      // Pinax uploads, and other imports with no copy of their own, are
      // never marked, in any style (migrated reads "Migrated").
      for source in [AssetSource.pinax, .otherImport] {
        for style in SourceTagStyle.allCases {
          #expect(
            SourceCaption.make(style: style, source: source, tier: tier, showsFilename: true)
              == nil,
            "\(source) is unmarked under \(style)")
        }
      }
    }
    // Gruvbox (GridScrimTests.sourceTints).
    #expect(SourceTint.picgo.color == PinaxPalette.orange)
    #expect(SourceTint.bucket.color == PinaxPalette.aqua)
    #expect(SourceTagStyle.allCases.map(\.label) == [
      "Date line", "Pill", "Dot", "Before name", "Off",
    ])
    // Only Pill and Dot take the extra row.
    #expect(SourceTagStyle.allCases.filter(SourceCaption.reservesExtraRow) == [.pill, .dot])
  }

  @Test("The tier follows the column ladder")
  func tiers() {
    #expect(GridZoom.columns.map { SourceTier(columns: $0) } == [
      .large, .large, .medium, .medium, .small, .small,
    ])
  }

  // MARK: - 2. Row height

  private func fittingHeight(
    _ row: GalleryModel.Row, cache: ThumbnailCache, options: GridOverlayOptions,
    tier: SourceTier, width: CGFloat
  ) -> CGFloat {
    let host = NSHostingView(
      rootView: AssetGridCell(row: row, cache: cache, overlays: options, tier: tier)
        .frame(width: width))
    return host.fittingSize.height
  }

  @Test("A cell is as tall marked as unmarked, in every style and tier; Pill and Dot add one row")
  func rowHeightIgnoresTheMarker() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seed(database)
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    func row(_ name: String) throws -> GalleryModel.Row {
      try #require(model.rows.first { $0.item.asset.originalFilename == name })
    }
    let rows = [
      try row("cat-pinax.png"), try row("cat-picgo-1.png"), try row("dog-bucket-1.png"),
      try row("dog-migrated.png"),
    ]
    let widths: [SourceTier: CGFloat] = [.large: 200, .medium: 132, .small: 84]
    for tier in SourceTier.allCases {
      let width = try #require(widths[tier])
      var plain = GridOverlayOptions()
      plain.sourceTagStyle = .off
      let base = fittingHeight(rows[0], cache: model.thumbnails, options: plain, tier: tier, width: width)
      for style in SourceTagStyle.allCases {
        var options = GridOverlayOptions()
        options.sourceTagStyle = style
        let heights = rows.map {
          fittingHeight($0, cache: model.thumbnails, options: options, tier: tier, width: width)
        }
        #expect(Set(heights).count == 1, "\(style) \(tier): \(heights)")
        if SourceCaption.reservesExtraRow(style) {
          #expect(heights[0] > base, "\(style) \(tier) adds a row: \(heights[0]) vs \(base)")
        } else {
          #expect(heights[0] == base, "\(style) \(tier) adds nothing: \(heights[0]) vs \(base)")
        }
      }
      // The filename off, Before name: the date line carries the icon and
      // still does not grow the cell.
      var noName = GridOverlayOptions()
      noName.showsFilename = false
      noName.sourceTagStyle = .off
      let bareBase = fittingHeight(
        rows[0], cache: model.thumbnails, options: noName, tier: tier, width: width)
      noName.sourceTagStyle = .beforeName
      #expect(
        fittingHeight(rows[1], cache: model.thumbnails, options: noName, tier: tier, width: width)
          == bareBase)
    }
  }

  // MARK: - 3. Settings and the View menu

  @Test("The style persists; Show Source Tags off then on brings the prior style back")
  func settingsAndMenuToggle() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()
    let app = PinaxAppModel(
      dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let preferences = app.preferences
    #expect(preferences.gridOverlays.sourceTagStyle == .dateLine, "the default")
    #expect(preferences.showsSourceTags)

    // Settings writes the style; it persists across a relaunch.
    preferences.gridOverlays.sourceTagStyle = .pill
    #expect(defaults.string(forKey: "pinax.grid.sourceTags.style") == "pill")
    #expect(PreferencesStore(defaults: defaults).gridOverlays.sourceTagStyle == .pill)

    // The View menu item's binding, computed in the PinaxCommands body.
    let item = PinaxCommands(app: app).showSourceTagsBinding
    #expect(item.wrappedValue)
    item.wrappedValue = false
    #expect(preferences.gridOverlays.sourceTagStyle == .off)
    #expect(!PinaxCommands(app: app).showSourceTagsBinding.wrappedValue)
    #expect(PreferencesStore(defaults: defaults).gridOverlays.sourceTagStyle == .off)
    item.wrappedValue = true
    #expect(preferences.gridOverlays.sourceTagStyle == .pill, "back to the prior style")
    // The gallery model mirrors it.
    let gallery = try #require(app.gallery)
    #expect(gallery.gridOverlays.sourceTagStyle == .pill)

    // Off chosen in Settings, then the menu item on: the default, never Off.
    preferences.gridOverlays.sourceTagStyle = .off
    PinaxCommands(app: app).showSourceTagsBinding.wrappedValue = true
    #expect(preferences.gridOverlays.sourceTagStyle == .pill)
    // A relaunch while off still resumes the prior style.
    preferences.gridOverlays.sourceTagStyle = .off
    let relaunched = PreferencesStore(defaults: defaults)
    relaunched.toggleSourceTags()
    #expect(relaunched.gridOverlays.sourceTagStyle == .pill)

    // A stored value that is not a style reads as the default.
    defaults.set("future-style", forKey: "pinax.grid.sourceTags.style")
    #expect(PreferencesStore(defaults: defaults).gridOverlays.sourceTagStyle == .dateLine)
  }

  // MARK: - 4. Table

  @Test("The Table's Source column: words, sort key, and customization id")
  func tableSourceColumn() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seed(database)
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    func text(_ name: String) throws -> String {
      AssetTableView.source(try #require(model.rows.first { $0.item.asset.originalFilename == name }))
    }
    #expect(try text("cat-pinax.png") == "", "Pinax rows are blank")
    #expect(try text("cat-picgo-1.png") == "PicGo")
    #expect(try text("dog-bucket-1.png") == "Bucket")
    #expect(try text("dog-migrated.png") == "Migrated", "the short name")
    #expect(AssetTableView.sourceColumn == "source", "the column the user can hide")
    #expect(AssetTableView.comparator(.source).keyPath != AssetTableView.comparator(.kind).keyPath)

    // Sorting by Source orders by the classifier, ties by id, both ways.
    model.sort = AssetSort(field: .source, direction: .ascending)
    await model.reload()
    let names = model.rows.map { $0.item.asset.originalFilename ?? "" }
    #expect(names == [
      "dog-bucket-1.png", "dog-bucket-2.png", "dog-migrated.png", "cat-picgo-1.png",
      "cat-picgo-2.png", "cat-pinax.png",
    ])
    model.sort = AssetSort(field: .source, direction: .descending)
    await model.reload()
    #expect(model.rows.map { $0.item.asset.originalFilename ?? "" } == names.reversed())
  }

  // MARK: - 5. Inspector

  @Test("The Inspector's Source row says the source's sentence, with the entry date")
  func inspectorSourceText() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seed(database)
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    func text(_ name: String) throws -> String {
      let row = try #require(model.rows.first { $0.item.asset.originalFilename == name })
      return AssetInspectorView.sourceText(
        CatalogAssetDetails(item: row.item, tags: [], projects: []))
    }
    let added = PinaxFormat.date("2026-08-01T10:00:00Z", style: .day)
    #expect(try text("cat-pinax.png") == "Uploaded by Pinax · \(added)")
    #expect(
      try text("cat-picgo-1.png")
        == "Imported from PicGo · \(PinaxFormat.date("2026-08-02T10:00:00Z", style: .day))")
    #expect(
      try text("dog-bucket-1.png")
        == "Imported from your bucket · img.example.com · "
        + PinaxFormat.date("2026-08-04T10:00:00Z", style: .day))
  }

  // MARK: - 6. The find strip's Source filter

  @Test("Source counts, the PicGo result, N of M, and stacking with search and scope")
  func sourceFilter() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seed(database)
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    await model.refreshSourceCounts()
    #expect(model.sourceCounts == GalleryModel.SourceCounts(all: 6, pinax: 1, picgo: 2, bucket: 2, migrated: 1))
    #expect(FindStrip.sourceItemTitle("PicGo", 2) == "PicGo (2)")

    // PicGo: exactly the assets the importer classifies as PicGo.
    model.sourceFilter = .picgo
    await model.reload()
    let all = try await database.read { db in try Asset.fetchAll(db) }
    let picgoIDs = Set(all.filter { AssetSource.of(meta: $0.meta) == .picgo }.compactMap(\.id))
    #expect(Set(model.rows.map(\.item.asset.id)) == Set(picgoIDs.map(Optional.some)))
    #expect(
      WindowTitle.countSentence(
        totalCount: model.totalCount, unfilteredTotalCount: model.unfilteredTotalCount,
        rowsCount: model.rows.count) == "2 of 6 assets")

    // Stacks with search text …
    model.searchText = "picgo-2"
    await model.reload()
    #expect(model.rows.map { $0.item.asset.originalFilename } == ["cat-picgo-2.png"])
    #expect(
      WindowTitle.countSentence(
        totalCount: model.totalCount, unfilteredTotalCount: model.unfilteredTotalCount,
        rowsCount: model.rows.count) == "1 of 6 assets")
    // … and with Scope: the name is not in the key or the note.
    model.searchScope = .note
    await model.reload()
    #expect(model.rows.isEmpty)
    model.searchScope = .all
    model.searchText = ""

    // All Sources again: the plain count.
    model.sourceFilter = nil
    await model.reload()
    #expect(model.rows.count == 6)
    #expect(
      WindowTitle.countSentence(
        totalCount: model.totalCount, unfilteredTotalCount: model.unfilteredTotalCount,
        rowsCount: model.rows.count) == "6 assets")
  }

  @Test("A source filter keeps the strip up, restarts the query, and is not read on reports")
  func sourceFilterKeepsStripAndToken() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(database)
    await model.loadInitialData()
    let plain = GalleryView(model: model).reloadToken
    model.sourceFilter = .bucket
    #expect(GalleryView(model: model).reloadToken != plain)
    #expect(GalleryView(model: model).showsFilterBar)
    model.select(.orphans, in: .library)
    let report = GalleryView(model: model).reloadToken
    model.sourceFilter = .picgo
    #expect(GalleryView(model: model).reloadToken == report, "reports do not read it")
  }

  // MARK: - 7. Externals

  @Test("The Externals page draws no source tags")
  func externalsShowNoTags() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    let page = try String(
      contentsOf: url.appendingPathComponent("Sources/PinaxUI/Gallery/ExternalsView.swift"),
      encoding: .utf8)
    for forbidden in ["AssetGridCell", "SourceCaption", "SourceTag"] {
      #expect(!page.contains(forbidden), "Externals draws its own tiles; found \(forbidden)")
    }
  }
}
