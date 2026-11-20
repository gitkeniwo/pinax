import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing

@MainActor
@Suite struct GalleryModelTests {
  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-thumbs-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  @Test("makeQuery is the single funnel from UI state to AssetQuery")
  func queryConstruction() async throws {
    try await withTempDatabase { database in
      let model = makeModel(database)

      model.sidebarSelection = .project("blog")
      let query = model.makeQuery()
      #expect(query.project == "blog")
      #expect(query.tag == nil)
      #expect(query.limit == 120)

      model.sidebarSelection = .tag("hero")
      #expect(model.makeQuery().tag == "hero")

      model.searchText = "  截图  "
      #expect(model.makeQuery().search == "  截图  ")

      model.timeFilter = .month("2026-08")
      let monthQuery = model.makeQuery()
      #expect(monthQuery.since == "2026-08-01T00:00:00Z")
      #expect(monthQuery.until == "2026-09-01T00:00:00Z")

      #expect(model.makeQuery(stripTimeBounds: true).since == nil)
      #expect(model.makeQuery(stripTimeBounds: true).until == nil)

      model.sidebarSelection = .recent
      model.searchText = ""
      let stripped = model.makeQuery(stripTimeBounds: true)
      #expect(stripped.since != nil)
      #expect(stripped.until == nil)
      let full = model.makeQuery()
      #expect(full.since == "2026-08-01T00:00:00Z")
      #expect(full.until == "2026-09-01T00:00:00Z")
    }
  }

  @Test("Month filter end boundary rolls over to the next year")
  func endOfMonth() {
    #expect(GalleryModel.endOfMonthExclusive("2026-08") == "2026-09-01T00:00:00Z")
    #expect(GalleryModel.endOfMonthExclusive("2026-12") == "2027-01-01T00:00:00Z")
  }

  @Test("Recent selection bounds the query from below")
  func recentSelection() async throws {
    try await withTempDatabase { database in
      let model = makeModel(database)
      model.sidebarSelection = .recent
      let since = try #require(model.makeQuery().since)
      #expect(since.hasSuffix("T00:00:00Z") || since.contains("T"))
    }
  }

  @Test("Scrolling past the bottom loads every page without duplicates or gaps")
  func pagingAccumulation() async throws {
    try await withTempDatabase { database in
      for index in 0..<250 {
        let day = String(format: "%02d", 1 + index % 5)
        try seedAsset(database, index: index, uploadedAt: "2026-08-\(day)T12:00:00Z")
      }
      let model = makeModel(database)
      await model.reload()

      #expect(model.rows.count == 120)
      #expect(model.canLoadMore)

      var guardCounter = 0
      while model.canLoadMore && guardCounter < 10 {
        await model.loadNextPage()
        guardCounter += 1
      }

      #expect(!model.canLoadMore)
      #expect(model.rows.count == 250)
      #expect(Set(model.rows.map(\.id)).count == 250)

      let unpaginated = try CatalogAssets.list(in: database, limit: 250).map(\.asset.key)
      #expect(model.rows.map(\.item.asset.key) == unpaginated)
    }
  }

  @Test("Sidebar aggregates and catalog-wide months load alongside the grid")
  func sidebarData() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-07-05T12:00:00Z", tag: "hero")
      try seedAsset(database, index: 1, uploadedAt: "2026-08-15T12:00:00Z")
      try seedAsset(
        database, index: 2, uploadedAt: "2026-08-16T12:00:00Z",
        origFilename: "截图 2026年8月.png", projectSlug: "notes"
      )
      let model = makeModel(database)
      await model.loadInitialData()

      #expect(model.projects.map(\.slug) == ["blog", "notes"])
      #expect(model.tags.count == 1 && model.tags[0].name == "hero" && model.tags[0].assetCount == 1)
      #expect(model.availableMonths.map(\.month) == ["2026-08", "2026-07"])

      model.sidebarSelection = .project("notes")
      await model.reload()
      #expect(model.rows.map(\.item.asset.key) == ["notes/asset-2.png"])
      // The months are the time navigator's tree, so they cover the whole
      // catalog whatever is selected — not scoped.
      #expect(model.availableMonths.map(\.month) == ["2026-08", "2026-07"])

      model.searchText = "截图"
      await model.reload()
      #expect(model.rows.count == 1)
      #expect(model.rows.first?.item.asset.originalFilename == "截图 2026年8月.png")

      model.searchText = ""
      model.sidebarSelection = .all
      model.timeFilter = .month("2026-07")
      await model.reload()
      #expect(model.rows.count == 1)
      #expect(model.rows.first?.item.asset.uploadedAt.hasPrefix("2026-07") == true)
    }
  }

  @Test("Selecting a row loads inspector details through the read-only facade")
  func detailsSelection() async throws {
    await MainActor.run {}
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", tag: "hero")
      let model = makeModel(database)
      await model.loadInitialData()
      guard let row = model.rows.first else {
        Issue.record("no rows")
        return
      }
      model.select(row)
      for _ in 0..<20 where model.selectedDetails == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      let details = try #require(model.selectedDetails)
      #expect(details.item.asset.key == "blog/asset-0.png")
      #expect(details.tags == ["hero"])
      #expect(details.projects.map(\.slug) == ["blog"])
    }
  }

  private func withTempDatabase(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(database)
  }
}
