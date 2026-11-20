import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// The time navigator's year and
/// month rows are query inputs, and the year › month tree is built from the
/// whole catalog, not from whatever is selected.
@MainActor
@Suite struct TimeNavigatorTests {
  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-time-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  // MARK: - Year and month rows are query inputs

  @Test("A year's query ends at the next New Year, and December does not overflow")
  func yearAndMonthBounds() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(database)

    model.select(.year("2026"), in: .time)
    var query = model.makeQuery()
    #expect(query.since == "2026-01-01T00:00:00Z")
    #expect(query.until == "2027-01-01T00:00:00Z")

    model.select(.month("2026-12"), in: .time)
    query = model.makeQuery()
    #expect(query.since == "2026-12-01T00:00:00Z")
    #expect(query.until == "2027-01-01T00:00:00Z")

    model.select(.month("2026-03"), in: .time)
    query = model.makeQuery()
    #expect(query.since == "2026-03-01T00:00:00Z")
    #expect(query.until == "2026-04-01T00:00:00Z")

    // The bounds are the selection's own, so the "N of M" count query —
    // which strips only the time filter's contribution — keeps them.
    let stripped = model.makeQuery(stripTimeBounds: true)
    #expect(stripped.since == "2026-03-01T00:00:00Z")
    #expect(stripped.until == "2026-04-01T00:00:00Z")
  }

  /// The same property through the database: rows one second either side of
  /// each New Year land in exactly the year they belong to.
  @Test("Selecting a year or a month loads exactly the assets inside it")
  func yearAndMonthSelectExactlyTheirAssets() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2025-12-31T23:59:59Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-01-01T00:00:00Z")
    try seedAsset(database, index: 2, uploadedAt: "2026-12-31T23:59:59Z")
    try seedAsset(database, index: 3, uploadedAt: "2027-01-01T00:00:00Z")
    let model = makeModel(database)
    await model.loadInitialData()

    model.select(.year("2026"), in: .time)
    await model.reload()
    #expect(Set(model.rows.map(\.item.asset.uploadedAt))
      == ["2026-01-01T00:00:00Z", "2026-12-31T23:59:59Z"])

    model.select(.month("2026-12"), in: .time)
    await model.reload()
    #expect(model.rows.map(\.item.asset.uploadedAt) == ["2026-12-31T23:59:59Z"])
  }

  // MARK: - The new rows are selectable in both directions

  /// A year row is a `DisclosureGroup`, so its `.tag` is not on a plain row
  /// the way every other row's is. What this pins is that the year is a
  /// selectable row at all: dropping that tag leaves it unselectable with
  /// nothing else failing (measured: the row→model and model→row checks on
  /// the year both go red) — a silently unselectable row. It does
  /// not pin where on the group the tag sits: on the group or on its label,
  /// both select (measured).
  @Test("Year and month rows select in the native outline, both ways")
  func yearAndMonthRowsAreNativelySelectable() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-07-02T00:00:00Z")
    try seedAsset(database, index: 2, uploadedAt: "2025-12-02T00:00:00Z")
    let model = makeModel(database)
    await model.loadInitialData()
    model.navigator = .time
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(0.8)
    let outline = try #require(sidebarOutline(in: window.contentView), "no sidebar outline")

    // Row 0 is the "Time" header; the years start collapsed.
    #expect(outline.numberOfRows == 3)
    outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    await spin(until: { model.sidebarSelection == .year("2026") })
    #expect(model.sidebarSelection == .year("2026"))

    // The year opens by its square, and its months
    // sit flat in the outline (no native level below the year's).
    await clickSidebarSquare(row: 1, depth: 0, in: outline, window: window)
    await spin(until: { outline.numberOfRows == 5 })
    // 2026 › August, July, then 2025.
    #expect(outline.numberOfRows == 5)
    outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
    await spin(until: { model.sidebarSelection == .month("2026-07") })
    #expect(model.sidebarSelection == .month("2026-07"))

    model.sidebarSelection = .month("2026-08")
    await spin(until: { outline.selectedRow == 2 })
    #expect(outline.selectedRow == 2)
    model.sidebarSelection = .year("2025")
    await spin(until: { outline.selectedRow == 4 })
    #expect(outline.selectedRow == 4)
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  /// `LayoutStabilityTests.spin`: pump the run loop so the offscreen host
  /// lays out, and yield so the model's async loads can run.
  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// Pumps until `condition` holds, for at most two seconds. A fixed 0.2 s
  /// spin failed once in three full runs (the model→row write at
  /// `.month("2026-08")` read -1): other suites host windows in parallel
  /// and slow the layout pass. A wait that ends on the condition is not a
  /// weaker check — the `#expect` after it still fails if it never holds.
  private func spin(until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
  }

  private func sidebarOutline(in view: NSView?) -> NSOutlineView? {
    guard let view else { return nil }
    var stack: [NSView] = [view]
    while let next = stack.popLast() {
      if let outline = next as? NSOutlineView { return outline }
      stack.append(contentsOf: next.subviews)
    }
    return nil
  }

  // MARK: - The tree does not prune itself

  /// Scoped to the selection, `availableMonths` would leave only the
  /// selected month in the tree the month was picked from.
  @Test("Selecting a month leaves every other month in the tree")
  func selectingAMonthKeepsTheTree() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z")
    try seedAsset(database, index: 2, uploadedAt: "2026-03-02T00:00:00Z", projectSlug: "notes")
    try seedAsset(database, index: 3, uploadedAt: "2025-12-02T00:00:00Z")
    let model = makeModel(database)
    await model.loadInitialData()

    let before = model.sidebarSections(for: .time)
    #expect(before.flatMap(\.entries).map(\.selection) == [.year("2026"), .year("2025")])
    #expect(before.flatMap(\.entries).map(\.count) == [3, 1])

    for selection: SidebarSelection in [.month("2026-03"), .year("2025")] {
      model.select(selection, in: .time)
      await model.reload()
      #expect(model.sidebarSections(for: .time).flatMap(\.entries).flatMap(\.flattened).map(\.id)
        == before.flatMap(\.entries).flatMap(\.flattened).map(\.id), "\(selection)")
    }
    // A selection in another navigator does not prune it either.
    model.select(.project("notes"), in: .collections)
    await model.reload()
    #expect(model.availableMonths.map(\.month) == ["2026-08", "2026-03", "2025-12"])
  }
}

extension GalleryModel {
  /// The tree a navigator would show right now, whichever one is current.
  fileprivate func sidebarSections(for navigator: SidebarNavigator) -> [SidebarSection] {
    SidebarModel.sections(
      navigator: navigator, projects: projects, tags: tags, months: availableMonths,
      folderChildren: folderChildren)
  }
}
