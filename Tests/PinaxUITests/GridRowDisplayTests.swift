import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// A row's display values and the grid's sections are worked out when the
/// rows change, not each time a cell or the grid draws:
///
/// 1. A row's source, day, month key, size, format and dimensions are what
///    the cell used to format itself, word for word, in any locale — on
///    every kind of row, Usage's reference and repeat rows included.
/// 2. `groupedRows` is the same cut the grid used to make on each read: by
///    month, by Usage file on Usage ▸ Images' grid, and after the view mode,
///    the Usage page or the place changes.
/// 3. A change the cut does not depend on — the selection, a favourite, a
///    label, the table — does not cut again, yet the sections carry the new
///    rows.
@MainActor
@Suite struct GridRowDisplayTests {
  // MARK: - What the cell and the grid computed before

  private static func legacyDay(_ row: GalleryModel.Row, locale: Locale) -> String {
    PinaxFormat.date(row.item.asset.uploadedAt, style: .day, locale: locale)
  }

  private static func legacySize(_ row: GalleryModel.Row, locale: Locale) -> String {
    row.item.asset.byteSize.formatted(.byteCount(style: .file).locale(locale))
  }

  private static func legacyDimensions(_ row: GalleryModel.Row) -> String? {
    guard let width = row.item.asset.width, let height = row.item.asset.height else { return nil }
    return "\(width) × \(height)"
  }

  /// The grid's former computed cut, verbatim.
  private static func legacyGroups(_ model: GalleryModel) -> [(month: String, ids: [Int64])] {
    var groups: [(month: String, ids: [Int64])] = []
    let byFile = model.showsUsageFileSections
    for row in model.rows {
      let month =
        byFile ? row.usageSection?.fileID ?? "" : String(row.item.asset.uploadedAt.prefix(7))
      if groups.last?.month == month {
        groups[groups.count - 1].ids.append(row.id)
      } else {
        groups.append((month, [row.id]))
      }
    }
    return groups
  }

  private static func expectSameCut(
    _ model: GalleryModel, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let legacy = legacyGroups(model)
    #expect(model.groupedRows.map(\.month) == legacy.map(\.month), sourceLocation: sourceLocation)
    #expect(
      model.groupedRows.map { $0.rows.map(\.id) } == legacy.map(\.ids),
      sourceLocation: sourceLocation)
  }

  private static func expectSameDisplay(
    _ row: GalleryModel.Row, as parent: GalleryModel.Row,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(row.source == parent.source, sourceLocation: sourceLocation)
    #expect(row.dayText == parent.dayText, sourceLocation: sourceLocation)
    #expect(row.monthKey == parent.monthKey, sourceLocation: sourceLocation)
    #expect(row.sizeText == parent.sizeText, sourceLocation: sourceLocation)
    #expect(row.formatText == parent.formatText, sourceLocation: sourceLocation)
    #expect(row.dimensionsText == parent.dimensionsText, sourceLocation: sourceLocation)
  }

  private static func item(
    byteSize: Int64, width: Int?, height: Int?, mime: String, meta: String, uploadedAt: String
  ) -> CatalogAssetItem {
    CatalogAssetItem(
      asset: Asset(
        id: 7, sha256: "row-display", backendID: 0, key: "a/b.png",
        byteSize: byteSize, width: width, height: height, mime: mime,
        originalFilename: "b.png", meta: meta,
        uploadedAt: uploadedAt, createdAt: uploadedAt, updatedAt: uploadedAt),
      backend: Backend(
        id: 0, slug: "test", kind: "s3", endpoint: "", bucket: "",
        urlPrefix: "https://img.invalid", keychainRef: "",
        createdAt: uploadedAt, updatedAt: uploadedAt))
  }

  // MARK: - 1. Display values

  @Test(
    "A row's display values are the cell's former formatting, word for word, in any locale",
    arguments: ["en_US", "de_DE", "ja_JP", "fr_CH"])
  func displayValuesMatchTheCellsFormatting(identifier: String) {
    let locale = Locale(identifier: identifier)
    let items = [
      // Dimensions and a PicGo source.
      Self.item(
        byteSize: 1_234_567, width: 4000, height: 3000, mime: "image/png",
        meta: #"{"imported_from":"picgo"}"#, uploadedAt: "2026-06-03T10:00:00Z"),
      // No dimensions, no meta.
      Self.item(
        byteSize: 812, width: nil, height: nil, mime: "image/jpeg", meta: "{}",
        uploadedAt: "2025-12-31T23:59:59Z"),
      // A width without a height; a migrated image.
      Self.item(
        byteSize: 52_000_000, width: 640, height: nil, mime: "image/webp",
        meta: #"{"source_url":"https://old.invalid/x.webp"}"#,
        uploadedAt: "2024-02-29T00:00:00Z"),
      // Meta that is not JSON; an unknown kind.
      Self.item(
        byteSize: 0, width: 1, height: 1, mime: "application/octet-stream", meta: "not json",
        uploadedAt: "2026-01-01T00:00:00Z"),
    ]
    for item in items {
      let row = GalleryModel.Row(item, tags: [], locale: locale)
      #expect(row.source == AssetSource.of(meta: item.asset.meta))
      #expect(row.dayText == Self.legacyDay(row, locale: locale))
      #expect(row.monthKey == String(item.asset.uploadedAt.prefix(7)))
      #expect(row.sizeText == Self.legacySize(row, locale: locale))
      #expect(row.formatText == PinaxFormat.shortKind(mime: item.asset.mime))
      #expect(row.dimensionsText == Self.legacyDimensions(row))
    }
    // The locale is the injected one, not the machine's: German and US
    // English write the same day differently.
    let german = GalleryModel.Row(items[0], tags: [], locale: Locale(identifier: "de_DE"))
    let american = GalleryModel.Row(items[0], tags: [], locale: Locale(identifier: "en_US"))
    #expect(german.dayText != american.dayText)
  }

  @Test("Rows loaded from the catalog carry the display values the call sites' default locale gives")
  func loadedRowsCarryTheirDisplayValues() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T13:00:00Z")
    try seedAsset(
      database, index: 1, uploadedAt: "2026-07-01T00:00:00Z", meta: #"{"imported_from":"bucket"}"#)
    let model = Self.libraryModel(database, directory: directory)
    await model.loadInitialData()
    await model.reload()
    #expect(model.rows.count == 2)
    for row in model.rows {
      #expect(row.source == AssetSource.of(meta: row.item.asset.meta))
      #expect(row.dayText == Self.legacyDay(row, locale: .current))
      #expect(row.monthKey == String(row.item.asset.uploadedAt.prefix(7)))
      #expect(row.sizeText == Self.legacySize(row, locale: .current))
      #expect(row.formatText == PinaxFormat.shortKind(mime: row.item.asset.mime))
      #expect(row.dimensionsText == Self.legacyDimensions(row))
    }
    #expect(model.rows.map(\.source).contains(.bucket))
  }

  @Test("Usage's reference rows and repeat cells carry their image's display values")
  func usageRowsCarryTheirImagesDisplayValues() async throws {
    try await withUsageFixture { model in
      // The table: each image row opens to one child row per reference.
      model.usagePage = .images
      model.viewMode = .table
      await Self.until { model.rows.contains { $0.usageChildren?.isEmpty == false } }
      var children = 0
      for row in model.rows {
        for child in row.usageChildren ?? [] {
          Self.expectSameDisplay(child, as: row)
          children += 1
        }
      }
      #expect(children == 6)

      // Files: zeta.md uses a1 twice; the second cell is a repeat.
      model.viewMode = .grid
      model.usagePage = .files
      model.usageSelectedFileID = Self.zeta
      await Self.until { model.rows.contains(where: \.repeatsPreviousImage) }
      let repeats = model.rows.filter(\.repeatsPreviousImage)
      let repeatRow = try #require(repeats.first)
      let originals = model.rows.filter {
        !$0.repeatsPreviousImage && $0.item.asset.id == repeatRow.item.asset.id
      }
      let original = try #require(originals.first)
      Self.expectSameDisplay(repeatRow, as: original)
    }
  }

  // MARK: - 2. The same cut

  @Test("Month sections are the former cut, before and after a page arrives")
  func monthSectionsAreTheFormerCut() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    // 130 rows over three months: the first page (120) ends inside the last.
    for index in 0..<130 {
      let month = index < 50 ? "08" : index < 100 ? "07" : "05"
      let day = String(format: "%02d", 1 + index % 28)
      let minute = String(format: "%02d", index % 60)
      try seedAsset(database, index: index, uploadedAt: "2026-\(month)-\(day)T10:\(minute):00Z")
    }
    let model = Self.libraryModel(database, directory: directory)
    await model.loadInitialData()
    await model.reload()
    #expect(model.showsRowsByMonth)
    #expect(model.rows.count < 130)
    Self.expectSameCut(model)
    #expect(model.groupedRows.map(\.month) == ["2026-08", "2026-07", "2026-05"])

    let lastID = try #require(model.rows.last?.id)
    model.loadNextPageIfNearEnd(visibleRowID: lastID)
    await Self.until { model.rows.count == 130 }
    #expect(model.rows.count == 130)
    Self.expectSameCut(model)
    #expect(model.groupedRows.map(\.rows.count) == [50, 50, 30])
  }

  @Test("Usage sections are the former cut across the view mode, the Usage page and the place")
  func usageSectionsAreTheFormerCut() async throws {
    try await withUsageFixture { model in
      model.usageFileSort = .picking(.name)
      model.usagePage = .images
      await Self.until { model.rows.first?.usageSection != nil }
      #expect(model.showsUsageFileSections)
      Self.expectSameCut(model)
      #expect(model.groupedRows.map(\.month) == [Self.zeta, Self.alpha, Self.old])

      // The table: by image, no file sections, rows swapped in the same step.
      model.viewMode = .table
      #expect(!model.showsUsageFileSections)
      Self.expectSameCut(model)
      model.viewMode = .grid
      #expect(model.showsUsageFileSections)
      Self.expectSameCut(model)

      // The Files page: no file sections.
      model.usagePage = .files
      #expect(!model.showsUsageFileSections)
      Self.expectSameCut(model)
      model.usagePage = .images
      await Self.until { model.rows.first?.usageSection != nil }
      Self.expectSameCut(model)

      // Another place: back to months.
      let cuts = model.groupedRowsCutCount
      model.select(.all, in: .library)
      await Self.until { model.shownSelection == .all }
      #expect(model.groupedRowsCutCount > cuts)
      #expect(!model.showsUsageFileSections)
      Self.expectSameCut(model)
      #expect(model.groupedRows.map(\.month) == ["2026-08"])
    }
  }

  // MARK: - 3. No cut for changes the cut does not depend on

  @Test("Selecting, favouriting, labelling and the table leave the cut alone; the sections carry the new rows")
  func unrelatedChangesDoNotCutAgain() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (index, stamp) in [
      "2026-08-20T13:00:00Z", "2026-08-01T00:00:00Z", "2026-07-31T23:59:59Z",
      "2026-03-02T00:00:00Z",
    ].enumerated() {
      try seedAsset(database, index: index, uploadedAt: stamp)
    }
    let model = Self.libraryModel(database, directory: directory)
    await model.loadInitialData()
    await model.reload()
    let target = try #require(model.rows.dropFirst(2).first?.id)
    let cuts = model.groupedRowsCutCount

    model.selectedIDs = [target]
    await model.toggleFavorite(.selection([target]))
    await model.toggleLabel(.red, for: .selection([target]))
    model.viewMode = .table
    model.viewMode = .grid
    #expect(model.groupedRowsCutCount == cuts)

    // The sections hold the patched row, not the one before the change.
    let patched = model.groupedRows.flatMap(\.rows).filter { $0.id == target }
    let row = try #require(patched.first)
    #expect(row.isFavorite)
    #expect(row.labels == [.red])
    Self.expectSameCut(model)

    // A reload with the same rows patches; one with other rows cuts again.
    await model.reload()
    #expect(model.groupedRowsCutCount == cuts)
    model.select(.month("2026-08"), in: .time)
    await model.reload()
    await Self.until { model.shownSelection == .month("2026-08") }
    #expect(model.groupedRowsCutCount > cuts)
    #expect(model.rows.count == 2)
    Self.expectSameCut(model)
  }

  // MARK: - Fixtures

  private static func libraryModel(_ database: DatabasePool, directory: URL) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  private static func until(_ condition: () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private static let alpha = "blog\u{0}posts/alpha.md"
  private static let old = "blog\u{0}posts/2024/old.md"
  private static let zeta = "blog\u{0}drafts/zeta.md"

  /// blog, one completed scan:
  ///
  ///   a0  posts/alpha.md L3, posts/2024/old.md L1
  ///   a1  posts/alpha.md L7, drafts/zeta.md L2, drafts/zeta.md L8
  ///   a2  posts/2024/old.md L4
  private func withUsageFixture(_ body: (GalleryModel) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<3 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-20T12:0\(index):00Z")
    }
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO scan (id, project_id, started_at, finished_at, coverage, found_count)
          VALUES (9, 1, '2026-08-20T13:00:00Z', '2026-08-20T13:00:00Z', '[]', 0);
          UPDATE project SET last_scan_id = 9 WHERE slug = 'blog';
          """)
      let references: [(Int, String)] = [
        (0, "posts/alpha.md#L3"), (0, "posts/2024/old.md#L1"), (1, "posts/alpha.md#L7"),
        (1, "drafts/zeta.md#L2"), (1, "drafts/zeta.md#L8"), (2, "posts/2024/old.md#L4"),
      ]
      for (index, source) in references {
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            SELECT p.id, a.id, 'https://img.example.com/' || a.key, ?, 'markdown',
              '2026-08-20T13:00:00Z', '2026-08-20T13:00:00Z', 9
            FROM project p, asset a
            WHERE p.slug = 'blog' AND a.sha256 = ?
            """,
          arguments: [source, String(format: "%064x", index + 1)])
      }
    }
    let model = Self.libraryModel(database, directory: directory)
    await model.loadInitialData()
    model.select(.usage, in: .reports)
    await model.reload()
    #expect(model.usageBrowser != nil)
    try await body(model)
  }
}
