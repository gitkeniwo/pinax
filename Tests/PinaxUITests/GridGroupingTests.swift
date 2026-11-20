import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// The grid's month sections are a client-side cut of the rows the query
/// already returned, shown only in upload-date order on groupable views.
@MainActor
@Suite struct GridGroupingTests {
  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grouping-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  @Test("Month sections are the query's rows cut at each month, in order, none lost")
  func groupedRowsCutTheRowsByMonth() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stamps = [
      "2026-08-20T13:00:00Z", "2026-08-01T00:00:00Z", "2026-07-31T23:59:59Z",
      "2026-03-02T00:00:00Z", "2025-12-31T23:59:59Z", "2025-12-01T00:00:00Z",
    ]
    for (index, stamp) in stamps.enumerated() {
      try seedAsset(database, index: index, uploadedAt: stamp)
    }
    let model = makeModel(database)
    await model.loadInitialData()
    await model.reload()

    let groups = model.groupedRows
    #expect(groups.map(\.month) == ["2026-08", "2026-07", "2026-03", "2025-12"])
    #expect(groups.map(\.rows.count) == [2, 1, 1, 2])
    // The cut neither drops nor reorders: concatenated, it is `rows`.
    #expect(groups.flatMap(\.rows).map(\.id) == model.rows.map(\.id))
    // Every row sits under its own month.
    for group in groups {
      #expect(group.rows.allSatisfy { $0.item.asset.uploadedAt.hasPrefix(group.month) })
    }
  }

  /// A month header counts the whole month: the page (120 rows) ends 20 rows into July, so the
  /// rows paged in so far say 20 while July holds 30. The header says 30
  /// before the next page and after it.
  @Test("A month header counts the whole month, before and after the page that finishes it")
  func monthHeaderCountIsTheMonthsTotal() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let august = 100
    let july = 30
    for index in 0..<(august + july) {
      let (month, day) = index < august ? ("08", 1 + index % 28) : ("07", 1 + index % 28)
      let second = String(format: "%02d", index % 60)
      let minute = String(format: "%02d", index / 60)
      try seedAsset(
        database, index: index,
        uploadedAt: "2026-\(month)-\(String(format: "%02d", day))T00:\(minute):\(second)Z")
    }
    let model = makeModel(database)
    await model.loadInitialData()
    #expect(model.groupsRowsByMonth)

    func headers() -> [String] {
      model.groupedRows.map {
        "\($0.month):\(model.monthHeaderCount($0.month, loaded: $0.rows.count))"
      }
    }
    #expect(model.rows.count == 120 && model.canLoadMore, "the page cuts July")
    #expect(model.groupedRows.last?.rows.count == 20)
    #expect(headers() == ["2026-08:\(august)", "2026-07:\(july)"], "before paging")
    await model.loadNextPage()
    #expect(model.rows.count == august + july)
    #expect(headers() == ["2026-08:\(august)", "2026-07:\(july)"], "after paging")
  }

  /// The "under the current query" half of the header count:
  /// with a search that keeps 10 of July's 30, the header says 10, not the
  /// month's catalog-wide 30.
  @Test("A month header counts the month under the current query, not the whole catalog")
  func monthHeaderCountFollowsTheQuery() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<30 {
      let name = index < 10 ? "needle-\(index).png" : "asset-\(index).png"
      try seedAsset(
        database, index: index,
        uploadedAt: "2026-07-\(String(format: "%02d", 1 + index % 28))T00:00:\(String(format: "%02d", index))Z",
        origFilename: name, key: "blog/\(name)")
    }
    let model = makeModel(database)
    await model.loadInitialData()
    model.searchText = "needle"
    await model.reload()
    #expect(model.groupsRowsByMonth)
    #expect(model.rows.count == 10)
    let headers = model.groupedRows.map {
      "\($0.month):\(model.monthHeaderCount($0.month, loaded: $0.rows.count))"
    }
    #expect(headers == ["2026-07:10"])
  }

  @Test("Library All and Recent and a Time year group; a month, Collections and Reports do not")
  func groupingFollowsTheSelection() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(database)

    let cases: [(SidebarNavigator, SidebarSelection, Bool)] = [
      (.library, .all, true),
      (.library, .recent, true),
      (.time, .year("2026"), true),
      (.time, .month("2026-03"), false),
      (.collections, .all, false),
      (.collections, .project("notes"), false),
      (.collections, .tag("hero"), false),
      (.reports, .orphans, false),
    ]
    for (navigator, selection, grouped) in cases {
      model.select(selection, in: navigator)
      #expect(model.groupsRowsByMonth == grouped, "\(navigator) \(selection)")
    }
  }

  @Test("The month switch off ungroups every groupable view; on, grouping follows the order and the view")
  func monthSwitchGatesGrouping() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(database)
    #expect(model.groupsByMonth, "on by default")

    let groupable: [(SidebarNavigator, SidebarSelection)] = [
      (.library, .all), (.library, .recent), (.time, .year("2026")),
    ]
    let flat: [(SidebarNavigator, SidebarSelection)] = [
      (.time, .month("2026-03")), (.collections, .project("notes")), (.reports, .orphans),
    ]
    for groups in [false, true, false] {
      model.groupsByMonth = groups
      for (navigator, selection) in groupable {
        model.select(selection, in: navigator)
        #expect(model.groupsRowsByMonth == groups, "\(groups) \(navigator) \(selection)")
      }
      for (navigator, selection) in flat {
        model.select(selection, in: navigator)
        #expect(!model.groupsRowsByMonth, "\(groups) \(navigator) \(selection)")
      }
    }
  }
}
