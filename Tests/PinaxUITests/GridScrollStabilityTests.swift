import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// The scroller style a hosted grid is pinned to. The system picks
/// legacy for a Mac with a mouse attached or "Always show scroll bars", and
/// overlay otherwise, so a grid test must not take whichever the machine
/// has: each grid property runs under both, the style set through the grid's
/// own `scrollerStyle` pin (the system preference is never touched).
enum GridScrollerCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case overlay, legacy

  var style: NSScroller.Style { self == .overlay ? .overlay : .legacy }
  var testDescription: String { rawValue }
}

/// The grid's geometry is known before it is built,
/// so the scroller cannot grow or shrink while the user scrolls.
///
/// 1. Every cell is the same square: one row height, whatever the images'
///    shapes, in both thumbnail modes.
/// 2. Original aspect draws the image Photos-style, fitted and centred in
///    the square; the Quick Look anchor and the selection ring follow the
///    image's own bounds. Fill's footprint is the square.
/// 3. The document height does not change while scrolling top to bottom
///    and back, grouped or not.
/// 4. The grid is still lazy: cells built at any position are bounded by
///    the viewport, not by the catalog.
/// 5. The pinned month header names the month under the top edge and is
///    pushed out by the next one.
@MainActor
@Suite(.serialized) struct GridScrollStabilityTests {
  private final class FrameSink {
    var frames: [GalleryModel.Row.ID: CGRect] = [:]
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

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-h41-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  /// The hosted grid in a 900×700 window and its scroll view.
  @MainActor private struct Hosted {
    let window: NSWindow
    let host: NSView
    let scrollView: NSScrollView
    var clip: NSClipView { scrollView.contentView }

    /// A view's frame in the grid's scroll space (the scroll view's frame,
    /// top-left origin), where `RowFramesKey` reports.
    func inScrollSpace(_ view: NSView) -> CGRect {
      let origin = scrollView.convert(scrollView.bounds, to: host).origin
      return view.convert(view.bounds, to: host).offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// Every hosted view, depth first.
    func allViews() -> [NSView] {
      [host] + Self.descendants(of: host)
    }

    static func descendants(of root: NSView) -> [NSView] {
      var result: [NSView] = []
      var stack = root.subviews
      while let view = stack.popLast() {
        result.append(view)
        stack.append(contentsOf: view.subviews)
      }
      return result
    }

    /// The Quick Look anchors alive in the hierarchy — one per built cell.
    func anchors() -> [String: NSView] {
      var result: [String: NSView] = [:]
      for view in allViews() {
        guard let id = view.identifier?.rawValue,
          id.hasPrefix("PinaxAssetGridCellThumbnail-")
        else { continue }
        result[String(id.dropFirst("PinaxAssetGridCellThumbnail-".count))] = view
      }
      return result
    }
  }

  private func host(
    _ model: GalleryModel, sink: FrameSink, scroller: GridScrollerCase = .overlay
  ) async throws -> Hosted {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(
      rootView: AssetGridView(model: model, scrollerStyle: scroller.style)
        .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 })
    window.contentView = host
    window.orderFront(nil)
    await spin(1.0)
    var stack: [NSView] = [host]
    var found: NSScrollView?
    while let view = stack.popLast() {
      if let scroll = view as? NSScrollView {
        found = scroll
        break
      }
      stack.append(contentsOf: view.subviews)
    }
    let scrollView = try #require(found, "no hosted scroll view")
    // The pin is the grid's own, set a turn after the scroll view exists:
    // wait for it by its effect, and refuse to measure under another style.
    let deadline = Date().addingTimeInterval(3)
    while scrollView.scrollerStyle != scroller.style, Date() < deadline {
      await spin(0.05)
    }
    #expect(scrollView.scrollerStyle == scroller.style, "the grid never took the \(scroller) scroller")
    // The pin narrows (legacy) or widens (overlay) the content by the
    // scroller's width, and the grid lays out again at the new width: measure
    // only after the clip and the document have taken it.
    let thickness =
      scroller.style == .legacy
      ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    let contentWidth = scrollView.frame.width - thickness
    let settleDeadline = Date().addingTimeInterval(3)
    while abs(scrollView.contentView.bounds.width - contentWidth) > 0.5
      || abs((scrollView.documentView?.frame.width ?? 0) - contentWidth) > 0.5,
      Date() < settleDeadline
    {
      await spin(0.05)
    }
    #expect(
      abs(scrollView.contentView.bounds.width - contentWidth) <= 0.5,
      "the \(scroller) scroller's content never settled at \(contentWidth)")
    return Hosted(window: window, host: host, scrollView: scrollView)
  }

  /// 2.35:1, 3:4, 1:1, no recorded size and 2.35:1 again, in turn: a
  /// cycle of five over four columns, so the rows hold different shapes
  /// (some no 3:4 at all) and a row as tall as its tallest image differs.
  private static let shapes: [(width: Int, height: Int)?] = [
    (2350, 1000), (600, 800), (800, 800), nil, (2350, 1000),
  ]

  private func seedShapes(
    _ database: DatabasePool, count: Int, from first: Int = 0,
    uploadedAt: (Int) -> String
  ) throws {
    for index in first..<(first + count) {
      let shape = Self.shapes[index % Self.shapes.count]
      try seedAsset(
        database, index: index, uploadedAt: uploadedAt(index),
        width: shape?.width ?? 1, height: shape?.height ?? 1)
      if shape == nil {
        try database.write { db in
          try db.execute(
            sql: "UPDATE asset SET width = NULL, height = NULL WHERE sha256 = ?",
            arguments: [String(format: "%064x", index + 1)])
        }
      }
    }
  }

  // MARK: - 1 and 2. Square cells; the footprint and its ring

  @Test(
    "Every cell is the same square; Original aspect fits the image in it, ring and anchor on the image",
    arguments: [GridThumbnailSizing.originalAspect, .fillGrid])
  func squareCellsAndFootprint(sizing: GridThumbnailSizing) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedShapes(database, count: 20) { String(format: "2026-03-%02dT12:00:00Z", $0 + 1) }
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(.project("blog"), in: .collections)
    await model.reload()
    model.gridThumbnailSizing = sizing
    #expect(!model.groupsRowsByMonth)
    // Select the 2.35:1 and the 3:4 so their rings are drawn.
    let wide = try #require(model.rows.first { $0.item.asset.width == 2350 })
    let tall = try #require(model.rows.first { $0.item.asset.width == 600 })
    model.select(wide, mode: .replace)
    model.select(tall, mode: .toggle)
    #expect(model.selectedIDs == [wide.id, tall.id])

    let sink = FrameSink()
    let hosted = try await host(model, sink: sink)
    defer { hosted.window.orderOut(nil) }

    // 1. One height for every cell, in a grid that mixes four shapes.
    // Three of the five rows fit the 700 pt viewport; the lazy grid builds
    // those, and each holds a different mix of shapes.
    let built = model.rows.filter { sink.frames[$0.id] != nil }
    let frames = built.compactMap { sink.frames[$0.id] }
    #expect(frames.count >= 12, "built \(frames.count) of \(model.rows.count)")
    let heights = Set(frames.map { ($0.height * 2).rounded() / 2 })
    #expect(heights.count == 1, "\(sizing): cell heights \(heights.sorted())")

    // 2. The footprint is the Quick Look anchor's frame; the square is the
    // cell's top `width × width`.
    let anchors = hosted.anchors()
    let ring = DesignMetrics.selection.ringGap + DesignMetrics.selection.ringWidth
    #expect(built.contains { $0.id == wide.id } && built.contains { $0.id == tall.id })
    for row in built {
      let cell = try #require(sink.frames[row.id])
      let square = CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: cell.width)
      let anchor = try #require(anchors[row.item.asset.sha256], "no anchor for \(row.id)")
      let footprint = hosted.inScrollSpace(anchor)
      var expected = square
      if sizing == .originalAspect, let w = row.item.asset.width, let h = row.item.asset.height {
        let ratio = CGFloat(w) / CGFloat(h)
        let size =
          ratio >= 1
          ? CGSize(width: square.width, height: square.width / ratio)
          : CGSize(width: square.height * ratio, height: square.height)
        expected = CGRect(
          x: square.midX - size.width / 2, y: square.midY - size.height / 2,
          width: size.width, height: size.height)
      }
      #expect(
        abs(footprint.minX - expected.minX) <= 0.5 && abs(footprint.minY - expected.minY) <= 0.5
          && abs(footprint.width - expected.width) <= 0.5
          && abs(footprint.height - expected.height) <= 0.5,
        "\(sizing) \(row.item.asset.width ?? 0)×\(row.item.asset.height ?? 0): footprint \(footprint), expected \(expected) in square \(square)")

      // The ring: the leaf drawn around the footprint, gap and stroke out.
      if model.selectedIDs.contains(row.id) {
        let around = expected.insetBy(dx: -ring, dy: -ring)
        let leaves = hosted.allViews().filter { $0.subviews.isEmpty && !$0.isHidden }
          .map { hosted.inScrollSpace($0) }
        // Edge by edge: a 1x display snaps each edge to a whole point, so
        // a size can be off by more than either edge is.
        let hit = leaves.contains {
          abs($0.minX - around.minX) <= 0.5 && abs($0.minY - around.minY) <= 0.5
            && abs($0.maxX - around.maxX) <= 0.5 && abs($0.maxY - around.maxY) <= 0.5
        }
        #expect(
          hit,
          "\(sizing) \(row.item.asset.width ?? 0)×\(row.item.asset.height ?? 0): no ring at \(around); leaves near: \(leaves.filter { $0.intersects(square) && $0.width > square.width / 2 })")
      }
    }
  }

  /// An image too narrow for both corner chips keeps the size.
  @Test("A footprint too narrow for both corner chips keeps the size one")
  func narrowFootprintKeepsTheSizeChip() {
    #expect(AssetGridCell.narrowCorner(leading: .fileSize, trailing: .format) == .leading)
    #expect(AssetGridCell.narrowCorner(leading: .format, trailing: .fileSize) == .trailing)
    #expect(AssetGridCell.narrowCorner(leading: .tags, trailing: .dimensions) == .trailing)
    #expect(AssetGridCell.narrowCorner(leading: .dimensions, trailing: .fileSize) == .trailing)
    #expect(AssetGridCell.narrowCorner(leading: .tags, trailing: .format) == .leading)
  }

  // MARK: - 3. The document height does not move

  /// Months of 2, 1, 7, 8, 2 and 1 grid rows (four columns, newest
  /// first): the spread that sized a one-row month for an eight-row one.
  /// 72 assets, one page, so no page load can change the height
  /// legitimately. Three step sizes: a quarter viewport (rows stay built
  /// from step to step), 0.6 (a month's top row is dropped while its next
  /// stays built) and 1.2 (whole months dropped between steps).
  ///
  /// Grouped at 0.6 the last step is a known issue, measured: arriving at
  /// the top from 420 pt — the first month's top row dropped, its second
  /// still built — the clip lands at 249 instead of 0 and the document is
  /// 12 pt taller (5774 → 5786) until the next scroll. Steps of 0.25 and
  /// 1.2 hold exactly.
  @Test(
    "The document height stays put from top to bottom and back, grouped or not",
    arguments: [
      (true, 0.25, .overlay), (true, 0.6, .overlay), (true, 1.2, .overlay),
      (false, 0.25, .overlay), (false, 0.6, .overlay), (false, 1.2, .overlay),
      // The legacy leg: the width the lazy estimate went stale at was the
      // legacy one. One ungrouped walk, the coarsest (fewest steps) so the
      // extra leg does not starve the suites running beside it.
      (false, 1.2, .legacy),
    ] as [(Bool, CGFloat, GridScrollerCase)])
  func documentHeightIsConstant(
    _ grouped: Bool, _ fraction: CGFloat, _ scroller: GridScrollerCase
  ) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    var index = 0
    for (month, count) in [(1, 3), (2, 6), (3, 30), (4, 26), (5, 2), (6, 5)] {
      try seedShapes(database, count: count, from: index) {
        String(format: "2025-%02d-%02dT12:00:00Z", month, $0 - index + 1)
      }
      index += count
    }
    let model = makeModel(database)
    await model.loadInitialData()
    if grouped {
      model.select(.all, in: .library)
    } else {
      model.select(.project("blog"), in: .collections)
    }
    await model.reload()
    model.gridThumbnailSizing = .originalAspect
    #expect(model.groupsRowsByMonth == grouped)
    #expect(model.rows.count == 72)
    #expect(model.gridColumns == 4)

    let sink = FrameSink()
    let hosted = try await host(model, sink: sink, scroller: scroller)
    defer { hosted.window.orderOut(nil) }
    let clip = hosted.clip
    let document = try #require(hosted.scrollView.documentView)
    let start = document.frame.height
    let step = clip.bounds.height * fraction
    var readings: [CGFloat] = [start]
    var y: CGFloat = 0
    func move(to target: CGFloat) async {
      clip.scroll(to: NSPoint(x: 0, y: target))
      hosted.scrollView.reflectScrolledClipView(clip)
      await spin(0.08)
      readings.append(document.frame.height)
    }
    while y < document.frame.height - clip.bounds.height {
      y += step
      await move(to: min(y, document.frame.height - clip.bounds.height))
    }
    while y > 0 {
      y -= step
      await move(to: max(y, 0))
    }
    let spread = (readings.max() ?? 0) - (readings.min() ?? 0)
    let message: Comment =
      "grouped \(grouped), step \(fraction), \(scroller) scroller: document height ranged \(readings.min() ?? 0)…\(readings.max() ?? 0) over \(readings.count) steps: \(readings.map { Int($0) })"
    if grouped, fraction == 0.6 {
      // Everything before the final return to the top holds exactly.
      let beforeTop = readings.dropLast()
      #expect((beforeTop.max() ?? 0) - (beforeTop.min() ?? 0) <= 0.5, message)
    }
    // The grouped 0.6 return to the top holds now that each month's grid
    // has its exact height, so this is a plain check.
    #expect(spread <= 0.5, message)
  }

  // MARK: - 4. Still lazy

  /// 1200 assets over 40 months, all pages loaded: at the top, the middle
  /// and the bottom the cells built stay a few rows' worth — the outer
  /// `VStack` builds every header, never every cell.
  @Test("The grouped grid builds the cells near the viewport, not the catalog")
  func groupedGridStaysLazy() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<1200 {
      let month = index / 30
      try seedAsset(
        database, index: index,
        uploadedAt: String(
          format: "%04d-%02d-%02dT12:00:00Z", 2020 + month / 12, month % 12 + 1, index % 30 + 1))
    }
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    while true {
      let before = model.rows.count
      await model.loadNextPage()
      if model.rows.count == before { break }
    }
    #expect(model.rows.count == 1200)
    #expect(model.groupedRows.count == 40)

    let sink = FrameSink()
    let hosted = try await host(model, sink: sink)
    defer { hosted.window.orderOut(nil) }
    let clip = hosted.clip
    let document = try #require(hosted.scrollView.documentView)
    let cell = AssetGridView.cellWidth(columns: model.gridColumns, paneWidth: clip.bounds.width)
    let visibleRows = (clip.bounds.height / cell).rounded(.up)
    // The viewport's rows plus four rows of buffer, in cells.
    let bound = Int((visibleRows + 4) * CGFloat(model.gridColumns))
    var built: [Int] = []
    for fraction in [0, 0.5, 1] as [CGFloat] {
      clip.scroll(to: NSPoint(x: 0, y: (document.frame.height - clip.bounds.height) * fraction))
      hosted.scrollView.reflectScrolledClipView(clip)
      await spin(0.5)
      built.append(hosted.anchors().count)
    }
    #expect(
      built.allSatisfy { $0 > 0 && $0 <= bound },
      "cells built at top / middle / bottom: \(built), bound \(bound) of \(model.rows.count)")
  }

  // MARK: - 5. The pinned month header

  @Test("The pinned header's state: the last header above the top, pushed by the next")
  func stickyHeaderState() {
    let height = DesignMetrics.sectionHeader.height
    let state = StickyMonthHeaderState()
    state.report(month: "2026-01", minY: 8)
    state.report(month: "2026-02", minY: 600)
    #expect(state.pinnedMonth == nil && state.push == 0, "nothing pinned at rest")
    state.report(month: "2026-01", minY: -400)
    state.report(month: "2026-02", minY: 200)
    #expect(state.pinnedMonth == "2026-01" && state.push == 0)
    state.report(month: "2026-02", minY: height - 10)
    #expect(state.pinnedMonth == "2026-01" && state.push == -10, "pushed by the next header")
    state.report(month: "2026-02", minY: 0)
    #expect(state.pinnedMonth == "2026-02" && state.push == 0, "the next one takes the top")
    state.forget(month: "2026-02")
    #expect(state.pinnedMonth == "2026-01", "a header that left no longer competes")
  }

  /// Three long months whose titles differ in width (shown newest first:
  /// September, May, January), so the pinned copy's title says which month
  /// it is: it is as wide as that month's in-flow title.
  @Test("The pinned header names the month under the top edge and is pushed out by the next")
  func pinnedHeaderOverlay() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    var index = 0
    for month in [1, 5, 9] {
      for day in 1...30 {
        try seedAsset(
          database, index: index,
          uploadedAt: String(format: "2025-%02d-%02dT12:00:00Z", month, day))
        index += 1
      }
    }
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    #expect(model.groupsRowsByMonth)
    let sections = model.groupedRows.map { $0.rows.map(\.id) }
    try #require(sections.count == 3)

    let sink = FrameSink()
    let hosted = try await host(model, sink: sink)
    defer { hosted.window.orderOut(nil) }
    let clip = hosted.clip
    let document = try #require(hosted.scrollView.documentView)
    let area = hosted.inScrollSpace(clip)
    let height = DesignMetrics.sectionHeader.height
    let documentViews = Set(
      ([document] + Hosted.descendants(of: document)).map(ObjectIdentifier.init))
    func scroll(to y: CGFloat) async {
      clip.scroll(to: NSPoint(x: 0, y: y))
      hosted.scrollView.reflectScrolledClipView(clip)
      await spin(0.3)
    }
    /// A section's header top in the document: its first cell's top, less
    /// the row gap and the header — walking down half a viewport at a time
    /// until the lazy grid has built that cell.
    func headerTop(_ section: Int) async throws -> CGFloat {
      await scroll(to: 0)
      while sink.frames[sections[section][0]] == nil,
        clip.bounds.origin.y < document.frame.height - clip.bounds.height
      {
        await scroll(to: clip.bounds.origin.y + clip.bounds.height / 2)
      }
      let first = try #require(sink.frames[sections[section][0]], "section \(section) never built")
      return first.minY + clip.bounds.origin.y - AssetGridView.rowSpacing - height
    }
    /// Leaves drawn in the top band, outside the document or in it.
    func leaves(inDocument: Bool, band: ClosedRange<CGFloat>) -> [CGRect] {
      hosted.allViews().filter {
        $0.subviews.isEmpty && !$0.isHidden
          && documentViews.contains(ObjectIdentifier($0)) == inDocument
      }
      .map { hosted.inScrollSpace($0) }
      .filter { $0.width > 0 && $0.height > 0 && $0.minY >= band.lowerBound && $0.maxY <= band.upperBound }
    }
    func title(_ band: [CGRect]) -> CGRect? {
      band.filter { $0.width < area.width / 2 }.min { $0.minX < $1.minX }
    }

    // The in-flow titles' widths, each header resting at the top.
    var widths: [CGFloat] = []
    for section in 0..<3 {
      let top = try await headerTop(section)
      await scroll(to: top - 100)
      let rest = try #require(
        title(leaves(inDocument: true, band: 99...(101 + height))), "no title for section \(section)")
      widths.append(rest.width)
    }
    #expect(Set(widths.map { $0.rounded() }).count == 3, "titles not distinguishable: \(widths)")

    // Mid-May: the overlay names May.
    let may = try await headerTop(1)
    await scroll(to: may + 300)
    let overlay = leaves(inDocument: false, band: (area.minY - 1)...(area.minY + height + 1))
    let pinned = try #require(title(overlay), "no pinned title in the overlay: \(overlay)")
    #expect(abs(pinned.width - widths[1]) <= 0.5, "pinned title \(pinned.width), May \(widths[1]), all \(widths)")
    #expect(overlay.contains { $0.width >= area.width / 2 }, "pinned overlay has no plate: \(overlay)")

    // January's header (the next one down) 20 pt below the top: May's copy
    // is pushed up by 16, its plate ending where January's header starts.
    let january = try await headerTop(2)
    await scroll(to: january - 20)
    let pushed = leaves(inDocument: false, band: (area.minY - height)...(area.minY + height))
    let plate = try #require(pushed.filter { $0.width >= area.width / 2 }.max { $0.height < $1.height })
    #expect(abs(plate.maxY - (area.minY + 20)) <= 0.5, "pushed plate ends at \(plate.maxY), expected \(area.minY + 20)")
    let pushedTitle = try #require(title(pushed))
    #expect(abs(pushedTitle.width - widths[1]) <= 0.5, "pushed title \(pushedTitle.width) is not May's \(widths[1])")
  }
}
