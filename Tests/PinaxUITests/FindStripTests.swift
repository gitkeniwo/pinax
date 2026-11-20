import CatalogCore
import Foundation
import Testing
@testable import PinaxUI

/// The find strip's match controls are real query inputs, not chrome —
/// every control the strip draws must change what `AssetQuery` asks for
/// (a disabled or inert control copied for looks is a false guarantee). These assert the wiring end to end through the same
/// `reload()` the view layer triggers; the SQL-level differences are
/// asserted separately in `AssetQueryTests`.
@MainActor
@Suite struct FindStripTests {
  @Test("makeQuery carries the strip's match controls with the search text")
  func queryCarriesMatchControls() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-strip-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )

    var query = model.makeQuery()
    #expect(query.search == nil)
    #expect(query.searchMatch == .contains)
    #expect(query.searchCaseSensitive == false)

    model.searchText = "shot"
    model.searchMatch = .begins
    model.searchCaseSensitive = true
    query = model.makeQuery()
    #expect(query.search == "shot")
    #expect(query.searchMatch == .begins)
    #expect(query.searchCaseSensitive == true)
  }

  @Test("Case sensitivity and match mode change the loaded result set")
  func matchControlsChangeResults() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", origFilename: "Screen-Shot.png")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", origFilename: "screenshot.png")
    try seedAsset(database, index: 2, uploadedAt: "2026-08-03T00:00:00Z", origFilename: "notes.txt")
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-strip-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )

    model.searchText = "shot"
    await model.reload()
    #expect(model.rows.count == 2, "folded contains matches both PNG rows")

    model.searchCaseSensitive = true
    await model.reload()
    #expect(
      model.rows.count == 1,
      "case-sensitive contains drops the mixed-case row; got \(model.rows.map { $0.item.asset.originalFilename ?? "?" })")

    model.searchCaseSensitive = false
    model.searchMatch = .matches
    await model.reload()
    #expect(model.rows.isEmpty, "whole-value match on 'shot' matches neither row")

    model.searchMatch = .contains
    model.searchText = ""
    await model.reload()
    #expect(model.rows.count == 3, "clearing the text restores every row")
  }

  /// Search and time are independent predicates. The strip has no Clear
  /// Filters button; the method stays, and still leaves the search text
  /// alone.
  @Test("clearTimeFilter resets time without clearing search text")
  func clearTimeFilterKeepsSearchText() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-clear-filter-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    model.timeFilter = .last30Days
    model.searchText = "keep me"

    model.clearTimeFilter()

    #expect(model.timeFilter == .all)
    #expect(model.searchText == "keep me")
  }
}
