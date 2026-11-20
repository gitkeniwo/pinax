import AppKit
import CatalogCore
import CoreGraphics
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// Properties of the centre column's status bar:
///
/// 1. The bar's height is invariant across content changes — the real bar
///    view is rendered (`ImageRenderer` commits layout synchronously) over
///    a loaded catalog, a filter, a selection, the orphan surface, and an
///    empty catalog; every bitmap must be exactly `barHeight` tall. A bar
///    whose height depends on its contents re-lays-out the grid above it
///    on every page load, and the grid flickers.
/// 2. On the orphan surface the bar makes no asset-filter claim —
///    asserted on `leadingText`, the single source the left side renders
///    from. A report's left side is empty.
/// 3. The count line comes from the query, not the page: a filter that
///    excludes rows yields "N of M", never the page length.
///
/// Serialized for the same reason as LayoutStabilityTests: hosted windows
/// and focus do not survive interleaving at suspension points.
@MainActor
@Suite(.serialized) struct GalleryStatusBarTests {
  private var iso8601: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-statusbar-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  @Test("The toolbar's grid and search controls use valid symbols and the exact zoom ladder")
  func gridControlContract() {
    for symbol in GridToolbarControls.aspectSymbols + ["minus", "plus", "magnifyingglass"] {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
    let positions = GridZoom.columns.map(GridZoom.sliderPosition(for:))
    #expect(positions == [5, 4, 3, 2, 1, 0])
    #expect(positions.map(GridZoom.columns(atSliderPosition:)) == GridZoom.columns)
  }

  /// The grid controls live in the toolbar; the bar holds text and a
  /// progress indicator only — and the activity panel's switch. Hosted so AppKit-backed controls exist.
  @Test("The status bar's one control is the panel switch, and its left side is the selection")
  func barHoldsNoControlsAndSummarisesSelection() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T13:00:00Z")
    let model = makeModel(database)
    Task { await model.loadInitialData() }
    await spin(until: { !model.rows.isEmpty })
    #expect(GalleryStatusBar(model: model).selectionSummary == nil)

    model.selectedIDs = Set(model.rows.first.map { [$0.id] } ?? [])
    await spin(until: { model.selectedDetails != nil })
    let summary = GalleryStatusBar(model: model).selectionSummary
    #expect(summary?.hasPrefix("1 selected · ") == true, "\(String(describing: summary))")
    // The count first, then the selection, one line.
    #expect(GalleryStatusBar(model: model).leadingText == "1 asset · \(summary ?? "")")

    let host = NSHostingView(rootView: GalleryStatusBar(model: model).frame(width: 700))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 24), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    await spin(0.4)
    var controls: [String] = []
    var stack: [NSView] = [host]
    while let view = stack.popLast() {
      if view is NSControl { controls.append(NSStringFromClass(type(of: view))) }
      stack.append(contentsOf: view.subviews)
    }
    #expect(controls.count == 1, "controls in the status bar: \(controls)")
    window.orderOut(nil)
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// A fixed 0.8 s was flaky under full-suite load (1 of 3 full runs:
  /// summary nil). Ends on the condition; the `#expect` after
  /// it still fails if the condition never holds.
  private func spin(until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
  }

  /// Renders the real bar view at a fixed width and returns the bitmap's
  /// pixel height (scale 1: points).
  private func renderedBarHeight(_ model: GalleryModel) -> Int? {
    let renderer = ImageRenderer(
      content: GalleryStatusBar(model: model).frame(width: 700))
    return renderer.cgImage?.height
  }

  @Test("The status bar's height is invariant across content changes")
  func heightIsInvariantAcrossContentChanges() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T13:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-21T13:00:00Z")
    let model = makeModel(database)
    await model.loadInitialData()

    var heights = [renderedBarHeight(model)]

    model.timeFilter = .last30Days
    await spin(0.8)
    heights.append(renderedBarHeight(model))

    model.selectedIDs = Set(model.rows.first.map { [$0.id] } ?? [])
    await spin(0.8)
    heights.append(renderedBarHeight(model))

    model.sidebarSelection = .orphans
    await spin(0.8)
    heights.append(renderedBarHeight(model))

    let expected = Int(ChromeMetrics.barHeight)
    #expect(heights.allSatisfy { $0 == expected }, "heights: \(heights)")
    #expect(heights.compactMap { $0 }.count == heights.count, "every state produced a bitmap")
  }

  @Test("The bar renders over an empty catalog at the same height")
  func emptyCatalogKeepsTheSameHeight() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(database)
    await model.loadInitialData()

    #expect(renderedBarHeight(model) == Int(ChromeMetrics.barHeight))
    // A real COUNT over an empty catalog is 0 — the honest line is the
    // count itself, not a separate "empty" euphemism.
    #expect(GalleryStatusBar(model: model).leadingText == "0 assets")
  }

  @Test("The orphan surface's bar makes no asset-filter claim")
  func orphanBarMakesNoAssetFilterClaim() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T13:00:00Z")
    let model = makeModel(database)
    await model.loadInitialData()

    // Filters that would be described on an asset surface... The view's
    // reload task would fire on the token change; calling the same reload
    // directly keeps this test view-free but not behavior-free.
    model.searchText = "asset"
    model.timeFilter = .last7Days
    model.sidebarSelection = .orphans
    await model.reload()
    await spin(0.4)

    // The report's own numbers are in its header; the bar's left
    // side says nothing at all — no count, no filter, no N of M.
    #expect(model.orphanReport != nil, "the report loaded")
    #expect(model.totalCount == nil && model.unfilteredTotalCount == nil)
    #expect(GalleryStatusBar(model: model).leadingText == nil)
  }

  /// The four count assertions on the line the bar draws, plus the
  /// selection's place after it.
  @Test("The left side states the query's count, or only what is loaded")
  func leadingCountIsHonest() {
    func line(_ total: Int?, _ unfiltered: Int?, _ rows: Int, _ selection: String? = nil) -> String? {
      GalleryStatusBar.leadingText(
        count: WindowTitle.countSentence(
          totalCount: total, unfilteredTotalCount: unfiltered, rowsCount: rows),
        selection: selection)
    }
    #expect(line(1204, nil, 120) == "\(1204.formatted()) assets")
    #expect(line(38, 1204, 120) == "38 of \(1204.formatted()) assets")
    #expect(line(nil, nil, 120) == "120 loaded")
    #expect(line(nil, nil, 0) == nil)
    #expect(line(1204, nil, 120, "3 selected · 24.1 MB") == "\(1204.formatted()) assets · 3 selected · 24.1 MB")
    #expect(line(nil, nil, 0, "1 selected · 1 kB") == "1 selected · 1 kB")
  }

  @Test("The count line comes from the query, not the page")
  func countComesFromTheQueryNotThePage() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-01-01T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-01-02T00:00:00Z")
    try seedAsset(database, index: 2, uploadedAt: iso8601.string(from: Date()))
    let model = makeModel(database)
    Task { await model.loadInitialData() }
    // Until the load lands, not a fixed 0.8 s: under full-suite load the
    // fixed wait read the empty status ("No assets") in 3 of 4 runs.
    await spin(until: { model.totalCount != nil && model.unfilteredTotalCount != nil })

    #expect(
      GalleryStatusBar(model: model).leadingText == "3 assets",
      "the unfiltered total: \(String(describing: GalleryStatusBar(model: model).leadingText))")

    model.timeFilter = .last7Days
    await model.reload()
    await spin(0.4)
    #expect(
      GalleryStatusBar(model: model).leadingText == "1 of 3 assets",
      "filtered count of unfiltered total: \(String(describing: GalleryStatusBar(model: model).leadingText))")
  }
}
