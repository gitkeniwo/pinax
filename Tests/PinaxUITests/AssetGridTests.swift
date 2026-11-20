import AppKit
import CatalogCore
import Combine
import CoreGraphics
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// The fixed-column asset grid. Properties, not outcomes:
///
/// 1. **The slope property** — for every ladder count `n` and every pane
///    width in 400…1200 at 1 pt steps,
///    `|cellWidth(W+1) − cellWidth(W)| == 1/n`. This is the exact negation
///    of the adaptive-count defect: a count that flipped at thresholds in
///    `W` made the rendered width discontinuous; a fixed count cannot —
///    there are no thresholds.
/// 2. **The stale-count states are unreachable.** 341.5 (a 2-column layout rendered
///    at pane 719 while the adaptive count lagged behind the hide's arrival
///    width) and 123⅓ (3 columns at 418, the same lag on show) were
///    stale-count-at-fresh-width pairs. With the count constant the model's
///    only input is the live width, so along both measured pane trajectories
///    every renderable width lies inside the trajectory's own endpoint
///    interval — and the lagging-count values that produced the overshoot
///    stay OUTSIDE it, so the interval can never quietly re-admit them.
/// 3. **The framework agrees with the arithmetic** — a hosted `LazyVGrid`
///    at ladder counts and measured pane widths renders first-row cell
///    frames equal to `cellWidth(columns:paneWidth:)`; the smoothness is in
///    the container's own math, not in anything we animate.
/// 4. The sentinel still pages lazily — the `LazyVGrid` container must not
///    bring back a mount cascade that loads every page at once.
@MainActor
@Suite(.serialized) struct AssetGridTests {
  private struct OverlayCellFramesKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
      value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
  }

  private struct CaptionLineKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      value = max(value, nextValue())
    }
  }

  private final class OverlayHarnessState: ObservableObject {
    @Published var options = GridOverlayOptions()
    @Published var thumbnailSizing: GridThumbnailSizing = .fillGrid
    @Published var selected: Set<Int64> = []
    var frames: [Int64: CGRect] = [:]
    var captionLine: CGFloat = 0
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

  /// Pumps until `condition` holds, for at most three seconds — the
  /// restore loop's own budget is under one, so the cap only matters when
  /// parallel suites starve the main thread. The `#expect` after it still
  /// fails if the condition never holds.
  private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
  }

  // MARK: - Overlay switches never participate in cell layout

  @Test("Every default-overlay choice preserves every hosted grid cell frame")
  func overlayFieldsDoNotMoveCells() async throws {
    struct Harness: View {
      let rows: [GalleryModel.Row]
      let cache: ThumbnailCache
      @ObservedObject var state: OverlayHarnessState

      var body: some View {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(), spacing: AssetGridView.cellSpacing),
            count: 3),
          spacing: AssetGridView.rowSpacing
        ) {
          ForEach(rows) { row in
            AssetGridCell(
              row: row,
              cache: cache,
              overlays: state.options,
              thumbnailSizing: state.thumbnailSizing,
              isSelected: state.selected.contains(row.id))
              .background(
                GeometryReader { geo in
                  Color.clear.preference(
                    key: OverlayCellFramesKey.self,
                    value: [row.id: geo.frame(in: .global)])
                })
          }
        }
        .padding(AssetGridView.gridInset / 2)
        .onPreferenceChange(OverlayCellFramesKey.self) { state.frames = $0 }
        // One caption line in the caption role, measured, not assumed.
        .background(alignment: .topLeading) {
          Text("Aug 20, 2026").pinaxCaption().lineLimit(1).hidden()
            .background(
              GeometryReader { geo in
                Color.clear.preference(key: CaptionLineKey.self, value: geo.size.height)
              })
        }
        .onPreferenceChange(CaptionLineKey.self) { state.captionLine = $0 }
      }
    }

    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<6 {
      try seedAsset(
        database, index: index, uploadedAt: "2026-08-20T13:00:0\(index)Z",
        tag: "tag-\(index)")
    }
    try await database.write { db in
      try db.execute(sql: "UPDATE asset SET note = 'grid note'")
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-overlay-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    #expect(model.rows.allSatisfy { !$0.tags.isEmpty }, "page rows must carry their real tags")

    let state = OverlayHarnessState()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: Harness(rows: model.rows, cache: model.thumbnails, state: state))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(0.5)

    let baseline = state.frames
    #expect(baseline.count == model.rows.count)
    var variants: [GridOverlayOptions] = []
    var metadataDisabled = GridOverlayOptions()
    metadataDisabled.metadataVisibility = .off
    variants.append(metadataDisabled)
    var withoutDate = GridOverlayOptions()
    withoutDate.showsUploadDateBelowImage = false
    variants.append(withoutDate)
    for field in GridOverlayOptions.CornerField.allCases {
      variants.append(GridOverlayOptions(leadingCorner: field))
      variants.append(GridOverlayOptions(trailingCorner: field))
    }
    for variant in variants {
      state.options = variant
      await spin(0.2)
      #expect(
        state.frames == baseline,
        "switching to \(variant) moved cells: \(state.frames) != \(baseline)")
    }
    // The selection ring is an overlay: selecting never moves a cell.
    state.options = GridOverlayOptions()
    state.selected = Set(model.rows.map(\.id).prefix(3))
    await spin(0.2)
    #expect(state.frames == baseline, "selecting moved cells")
    state.selected = []

    // The filename line is laid out, so turning it off
    // takes exactly one caption line (and its gap) out of every cell; each
    // cell keeps its column and width, and a row moves up only by the lines
    // taken out of the rows above it — nothing else moves.
    let line = state.captionLine + DesignMetrics.grid.captionSpacing
    #expect(state.captionLine > 0, "caption line never measured")
    let rowTops = Set(baseline.values.map(\.minY)).sorted()
    for toggled in [false, true] {
      var options = GridOverlayOptions()
      options.showsFilename = false
      options.metadataVisibility = toggled ? .hoverOrSelected : .off
      options.showsUploadDateBelowImage = toggled
      state.options = options
      await spin(0.2)
      #expect(state.frames.count == baseline.count)
      for (id, before) in baseline {
        let after = try #require(state.frames[id])
        let rowIndex = CGFloat(try #require(rowTops.firstIndex(of: before.minY)))
        #expect(after.minX == before.minX && after.width == before.width, "cell \(id) moved sideways")
        #expect(
          abs((before.height - after.height) - line) < 0.5,
          "cell \(id): height \(before.height) → \(after.height), one line is \(line)")
        #expect(
          abs((before.minY - after.minY) - rowIndex * line) < 0.5,
          "cell \(id) in row \(rowIndex): y \(before.minY) → \(after.minY)")
      }
    }
    state.options = GridOverlayOptions()
    await spin(0.2)
    #expect(state.frames == baseline, "turning the filename back on restores every frame")

    state.thumbnailSizing = .originalAspect
    await spin(0.2)
    #expect(state.frames == baseline, "switching thumbnail fit mode moved cells")
  }

  // MARK: - 1. The slope property

  @Test("Cell width slope is exactly 1/n across the domain, every ladder count")
  func cellWidthSlopeIsExactlyOneOverN() {
    for n in GridZoom.columns {
      var previous = AssetGridView.cellWidth(columns: n, paneWidth: 400)
      var width: CGFloat = 401
      while width <= 1200 {
        let current = AssetGridView.cellWidth(columns: n, paneWidth: width)
        #expect(
          abs((current - previous) - 1 / CGFloat(n)) < 1e-9,
          "n=\(n) at W=\(width): step \(current - previous) is not 1/\(n)")
        previous = current
        width += 1
      }
    }
  }

  @Test("The slope holds for large deltas too, not just 1 pt steps")
  func cellWidthSlopeHoldsAcrossJumps() {
    let deltas: [CGFloat] = [40, 100, 301, 500]
    for n in GridZoom.columns {
      for delta in deltas {
        for start in [CGFloat(400), 418, 719, 900] where start + delta <= 1200 {
          let moved = AssetGridView.cellWidth(columns: n, paneWidth: start + delta)
            - AssetGridView.cellWidth(columns: n, paneWidth: start)
          #expect(
            abs(moved - delta / CGFloat(n)) < 1e-9,
            "n=\(n) start=\(start) delta=\(delta): moved \(moved), expected \(delta / CGFloat(n))")
        }
      }
    }
  }

  // MARK: - 2. The stale-count falsifier

  /// The measured rides at the 900 pt window minimum (detail holds 719
  /// with the inspector hidden, steps to 418 when it shows): the hide grows the pane 418 → 719, the show shrinks it back,
  /// and the split divider walks in ~40 ms steps, so both directions pass
  /// through intermediate widths. Under the adaptive model those rides
  /// flipped the count (2 ↔ 3) and rendered the lagging count against the
  /// arriving width; under a fixed count the render is a function of the
  /// live width alone.
  @Test("Mismatched count/width states are unreachable: the render tracks the live width alone")
  func h11MismatchedStatesUnreachable() {
    let hide: [CGFloat] = [418, 470, 530, 590, 650, 719]
    let show: [CGFloat] = [719, 650, 590, 530, 470, 418]
    // The counts the adaptive model held on each ride, and the fixed count
    // that reproduces its steady states at both ends.
    let cases: [(name: String, samples: [CGFloat], fixed: Int, lagging: Int)] = [
      ("hide 418→719, adaptive 2→3", hide, 3, 2),
      ("show 719→418, adaptive 3→2", show, 2, 3),
    ]
    for c in cases {
      let endA = AssetGridView.cellWidth(columns: c.fixed, paneWidth: c.samples.last!)
      let endB = AssetGridView.cellWidth(columns: c.fixed, paneWidth: c.samples.first!)
      let lower = min(endA, endB)
      let upper = max(endA, endB)
      for width in c.samples {
        let rendered = AssetGridView.cellWidth(columns: c.fixed, paneWidth: width)
        #expect(
          rendered >= lower - 0.5 && rendered <= upper + 0.5,
          "\(c.name): rendered \(rendered) at W=\(width) outside [\(lower), \(upper)]")
      }
      // Falsifier: the overshoot — the lagging count applied to the
      // arrival width — must stay outside the fixed-count interval, so no
      // tolerance can re-admit it.
      let overshoot = AssetGridView.cellWidth(columns: c.lagging, paneWidth: c.samples.last!)
      #expect(
        overshoot > upper + 0.5 || overshoot < lower - 0.5,
        "\(c.name): interval would already admit the overshoot (\(overshoot) vs [\(lower), \(upper)])")
    }
    // The two measured defect states, pinned by number. They were measured
    // as 341.5 = 2 columns at 719 and 123⅓ = 3 columns at 418 with inset 24
    // and gap 12; with `DesignMetrics.grid` (inset 16, gap 8) and the same
    // formula they are 347.5 and 128⅔. Under a fixed count these pairs are steady
    // states only when n owns them; they can never appear as the OTHER
    // count's transient on these rides — asserted above.
    #expect(abs(AssetGridView.cellWidth(columns: 2, paneWidth: 719) - 347.5) < 0.01)
    #expect(abs(AssetGridView.cellWidth(columns: 3, paneWidth: 418) - 386.0 / 3.0) < 0.01)
  }

  // MARK: - 3. The container renders the arithmetic

  private struct CellWidthsKey: PreferenceKey {
    static var defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
      value += nextValue()
    }
  }

  /// Hosted in a real window (the repo's LayoutStabilityTests hosting
  /// pattern): the LazyVGrid reports each realized cell's width through a
  /// preference; the harness reports the pane width the same way. This
  /// anchors the framework's own `GridItem(.flexible(), spacing:)`
  /// arithmetic to the formula above — the live 40 ms curve in the running
  /// app (commit message) is the end-to-end version of the same statement.
  @Test("A hosted LazyVGrid renders the formula's cell width exactly")
  func hostedLazyGridRendersTheFormula() async throws {
    final class SampleLog {
      var cellWidths: [CGFloat] = []
      var pane: CGFloat = 0
    }

    struct Harness: View {
      let columns: Int
      let log: SampleLog

      var body: some View {
        GeometryReader { geo in
          LazyVGrid(
            columns: Array(
              repeating: GridItem(.flexible(), spacing: AssetGridView.cellSpacing),
              count: columns),
            spacing: AssetGridView.rowSpacing
          ) {
            ForEach(0..<8, id: \.self) { _ in
              Color.blue
                .frame(height: 100)
                .background(
                  GeometryReader { cell in
                    Color.clear.preference(key: CellWidthsKey.self, value: [cell.size.width])
                  })
            }
          }
          .padding(AssetGridView.gridInset / 2)
          .background(
            GeometryReader { outer in
              Color.clear.preference(key: PaneProxyKey.self, value: outer.size.width)
            })
          .onPreferenceChange(CellWidthsKey.self) { log.cellWidths = $0 }
          .onPreferenceChange(PaneProxyKey.self) { log.pane = $0 }
        }
      }
    }

    for n in GridZoom.columns {
      for pane: CGFloat in [418, 719, 900, 1100] {
        let log = SampleLog()
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: pane, height: 400),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(
          rootView: Harness(columns: n, log: log))
        window.orderFront(nil)
        await spin(0.5)
        window.orderOut(nil)

        #expect(log.pane > 0, "n=\(n): pane never measured (hosting produced no layout)")
        #expect(!log.cellWidths.isEmpty, "n=\(n): no cells realized")
        for measured in log.cellWidths {
          let expected = AssetGridView.cellWidth(columns: n, paneWidth: log.pane)
          #expect(
            abs(measured - expected) < 1,
            "n=\(n) pane=\(log.pane): rendered \(measured), formula \(expected)")
        }
      }
    }
  }

  private struct PaneProxyKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      value = max(value, nextValue())
    }
  }

  // MARK: - 4. The sentinel (carried from ReflowGridTests verbatim)

  @Test("The sentinel pages one page at a time, never a cascade")
  func sentinelPagesWithoutCascade() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<130 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-20T13:00:00Z")
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    // The first page lands first (slow under full-suite load), then 1.2 s to
    // see that no second page cascades after it.
    await spin(until: { !model.rows.isEmpty }, timeout: 15)
    await spin(1.2)
    window.orderOut(nil)

    #expect(model.rows.count == 120, "exactly one page materialises; got \(model.rows.count)")
    #expect(model.canLoadMore)
  }

  // MARK: - 5. Zoom is pure view state

  @Test("The ladder walks rung by rung, saturates at both ends, and only ever holds rungs")
  func ladderWalkAndSaturation() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    var observed: [Int] = []
    model.onGridColumnsChange = { observed.append($0) }

    #expect(model.gridColumns == GridZoom.defaultColumns)
    #expect(model.canZoomIn && model.canZoomOut)

    // Up: 4 → 3 → 2, then the third call saturates without notifying.
    model.zoomIn()
    model.zoomIn()
    model.zoomIn()
    #expect(model.gridColumns == 2)
    #expect(observed == [3, 2])
    #expect(!model.canZoomIn && model.canZoomOut)

    // Down: 2 → 8 is five rungs; a sixth saturates.
    for _ in 0..<6 { model.zoomOut() }
    #expect(model.gridColumns == 8)
    #expect(observed == [3, 2, 3, 4, 5, 6, 8])
    #expect(model.canZoomIn && !model.canZoomOut)

    // An off-ladder init value sanitizes to the default rung, so a stale
    // preference from a future ladder edit can never reach the grid.
    let sanitized = GalleryModel(
      catalog: model.catalog,
      thumbnails: model.thumbnails,
      gridColumns: 7
    )
    #expect(sanitized.gridColumns == GridZoom.defaultColumns)
  }

  /// Counts false→true transitions of `isLoadingPage` by subscription, not
  /// polling — the LayoutStabilityTests instrument, restated locally; a
  /// polling probe can miss fast reloads.
  private final class ReloadProbe {
    private(set) var count = 0
    private var cancellable: AnyCancellable?
    private var wasLoading = false

    @MainActor
    func track(_ model: GalleryModel) {
      cancellable = model.$isLoadingPage.sink { loading in
        if loading && !self.wasLoading { self.count += 1 }
        self.wasLoading = loading
      }
    }
  }

  /// The zoom property, by name: changing zoom never triggers a query and
  /// never changes the selection. Not "pinch works" — hosted in a real
  /// `GalleryView`, so the reload token's `.task(id:)` would fire on a zoom
  /// step if the rung ever leaked into it; the counting probe would see the
  /// `isLoadingPage` transition. The trailing search keystroke is the
  /// positive control: the instrument still counts reloads when one is due.
  @Test("Zooming the whole ladder fires no query and keeps the selection")
  func zoomStepsTriggerNoQueriesAndKeepSelection() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<6 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-20T13:00:0\(index)Z")
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    await spin(until: { !model.rows.isEmpty }, timeout: 15)

    let selection = try #require(model.rows.first, "the first page never loaded into the model")
    model.select(selection)
    await spin(0.4)
    let rowsBefore = model.rows.map(\.id)

    let probe = ReloadProbe()
    probe.track(model)
    let baseline = probe.count

    // Every rung, both directions, plus saturation at both ends.
    for _ in 0..<6 { model.zoomOut() }
    for _ in 0..<7 { model.zoomIn() }
    // The status-bar slider reaches the same rungs through the model's
    // validated direct setter; finish at slider position 5 = 2 columns.
    for position in 0...5 {
      model.setGridColumns(GridZoom.columns(atSliderPosition: Double(position)))
    }
    model.toggleGridThumbnailSizing()
    model.toggleGridThumbnailSizing()
    await spin(1.0)

    #expect(probe.count == baseline, "a zoom step fired a query (\(probe.count - baseline) reloads)")
    #expect(model.selectedID == selection.id)
    #expect(model.rows.map(\.id) == rowsBefore)
    #expect(model.gridColumns == 2, "walk ended at the top rung: 8 → 2")

    // Positive control while the view is still hosted: a real query input
    // still reloads under an identical probe, so "zero" above measures the
    // zoom, not a broken instrument.
    let control = ReloadProbe()
    control.track(model)
    model.searchText = "asset-0"
    await spin(0.8)
    #expect(control.count > 0, "the probe missed a genuine reload — it proves nothing")
    window.orderOut(nil)
  }

  @Test("A full open pinch crosses four rungs; an aborted pinch crosses none")
  func pinchAccumulatorCrossesRungs() {
    var accumulator = PinchZoomAccumulator()
    var rungs = 0
    // Open to +1.0 of scale in trackpad-sized deltas: four crossings at
    // 0.25 each, excess back to zero — a full pinch is the whole ladder.
    for _ in 0..<20 { rungs += accumulator.advance(by: 0.05) }
    #expect(rungs == 4)
    // Reverse travel short of a rung: nothing crosses.
    for _ in 0..<4 { rungs += accumulator.advance(by: -0.05) }
    #expect(rungs == 4)
    // Gesture ends; leftover travel dies with it.
    accumulator.reset()
    rungs = 0
    // A new closing gesture crosses exactly one rung at −0.25 of travel.
    for _ in 0..<9 { rungs += accumulator.advance(by: -0.05) }
    #expect(rungs == -1)
  }

  // MARK: - 6. Fade + scroll anchoring

  /// The anchoring property's selector half, by name: the anchor is the row
  /// under the viewport's centre line — never a row lying entirely outside
  /// the viewport, no matter how the lazy realisation buffer sits. This
  /// pins the selection arithmetic.
  @Test("The anchor selector names the row under the centre line, never an off-screen one")
  func anchorSelectionPicksNearestVisibleRow() {
    // Viewport 400 → centre line at 200.
    let frames: [GalleryModel.Row.ID: CGRect] = [
      1: CGRect(x: 0, y: -140, width: 100, height: 120),  // entirely above
      2: CGRect(x: 0, y: 40, width: 100, height: 120),
      3: CGRect(x: 0, y: 140, width: 100, height: 120),  // midY 200: winner
      4: CGRect(x: 0, y: 300, width: 100, height: 120),
      5: CGRect(x: 0, y: 420, width: 100, height: 120),  // entirely below
    ]
    #expect(AssetGridView.anchorRowID(frames: frames, viewportHeight: 400) == 3)

    // A row realised just off-screen cannot steal the anchor from a visible
    // one even when the buffer reports it closer to the line than some
    // visible rows.
    var extended = frames
    extended[6] = CGRect(x: 0, y: 185, width: 100, height: 30)  // midY 200: visible, ties 3
    #expect(AssetGridView.anchorRowID(frames: extended, viewportHeight: 400) == 3)

    // Ties break deterministically to the smaller id.
    extended[0] = CGRect(x: 0, y: 140, width: 100, height: 120)  // midY 200
    #expect(AssetGridView.anchorRowID(frames: extended, viewportHeight: 400) == 0)

    // Degenerate inputs: nothing realised, or the viewport not yet measured.
    #expect(AssetGridView.anchorRowID(frames: [:], viewportHeight: 400) == nil)
    #expect(AssetGridView.anchorRowID(frames: frames, viewportHeight: 0) == nil)
  }

  /// The zoom property re-proven with the crossfade and restore loop live:
  /// each rung now stages a fading copy of the departing layout, animates
  /// two opacities, and runs an async restore loop against the hosted
  /// scroll view — and none of that may touch the reload token (a query
  /// would show in the counting probe), the selection, or the row array.
  /// Rung steps are paced a fade-length apart so whole fades, not just
  /// their first transaction, fall inside the measured window.
  @Test("The crossfade rung walk fires no query, keeps the selection, keeps the rows")
  func fadeRungWalkKeepsQueriesSelectionAndRows() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<6 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-20T13:00:0\(index)Z")
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    await spin(until: { !model.rows.isEmpty }, timeout: 15)

    let selection = try #require(model.rows.first, "the first page never loaded into the model")
    model.select(selection)
    await spin(0.4)
    let rowsBefore = model.rows.map(\.id)

    let probe = ReloadProbe()
    probe.track(model)
    let baseline = probe.count

    // The whole ladder, both directions, one fade duration per rung.
    for _ in 0..<5 {
      model.zoomOut()
      await spin(0.3)
    }
    for _ in 0..<6 {
      model.zoomIn()
      await spin(0.3)
    }
    await spin(1.0)

    #expect(probe.count == baseline, "a crossfade rung step fired a query (\(probe.count - baseline) reloads)")
    #expect(model.selectedID == selection.id)
    #expect(model.rows.map(\.id) == rowsBefore)
    #expect(model.gridColumns == 2, "walk ended at the top rung: 8 → 2")

    // Positive control while the view is still hosted: a real query input
    // still reloads under an identical probe.
    let control = ReloadProbe()
    control.track(model)
    model.searchText = "asset-0"
    await spin(0.8)
    #expect(control.count > 0, "the probe missed a genuine reload — it proves nothing")
    window.orderOut(nil)
  }


  private final class RowFrameSink {
    var frames: [GalleryModel.Row.ID: CGRect] = [:]
    var settledRestores = 0
  }

  /// The anchoring property's restore half, for both layouts (grouping by
  /// month must keep it): after a rung change the row under the centre line
  /// is back at the viewport y it had. 120 assets, parked mid-content, then
  /// the rung walk that exposed both grouped losses: ten per month over
  /// twelve months lost the anchor on 2→3 before the walk (left unrealised
  /// 1000 pt away), and three per month over forty lost it on 3→2 until the
  /// walk's in-band kick. Ungrouped, the month spread does not change the
  /// layout, so one ungrouped case covers both.
  ///
  /// The grid picks its anchor on a frame report while idle, and a restore
  /// leaves it frozen on the previous one — which shares its midY with its
  /// grid-row neighbours, so a fresh pick by this test could name a
  /// neighbour the grid never tracked. A 1 pt scroll before each rung makes
  /// the grid re-pick through the same selector this test calls.
  @Test(
    "A rung change puts the centre row back where it was, grouped or not",
    arguments: [
      (false, 12, .overlay), (true, 12, .overlay), (true, 40, .overlay),
      // The shape the system scroller style was measured on.
      (true, 12, .legacy),
    ] as [(Bool, Int, GridScrollerCase)])
  func rungChangeRestoresTheAnchor(
    _ grouped: Bool, _ months: Int, _ scroller: GridScrollerCase
  ) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    var index = 0
    for month in 0..<months {
      for day in 1...(120 / months) {
        try seedAsset(
          database, index: index,
          uploadedAt: String(
            format: "%04d-%02d-%02dT12:00:00Z", 2022 + month / 12, month % 12 + 1, day))
        index += 1
      }
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    if grouped {
      model.select(.all, in: .library)
    } else {
      model.select(.project("blog"), in: .collections)
    }
    await model.reload()
    #expect(model.groupsRowsByMonth == grouped)
    #expect(model.gridColumns == 4)

    let sink = RowFrameSink()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: AssetGridView(model: model, scrollerStyle: scroller.style)
        .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 }
        .onPreferenceChange(GridRestoresSettledKey.self) { sink.settledRestores = $0 })
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(1.0)

    var stack: [NSView] = [try #require(window.contentView)]
    var found: NSScrollView?
    while let view = stack.popLast() {
      if let scroll = view as? NSScrollView {
        found = scroll
        break
      }
      stack.append(contentsOf: view.subviews)
    }
    let scrollView = try #require(found, "no hosted scroll view")
    await spin(until: { scrollView.scrollerStyle == scroller.style })
    #expect(scrollView.scrollerStyle == scroller.style, "the grid never took the \(scroller) scroller")
    let clip = scrollView.contentView
    let viewport = clip.bounds.height
    let content = try #require(scrollView.documentView).frame.height
    clip.scroll(to: NSPoint(x: 0, y: (content - viewport) * 0.55))
    scrollView.reflectScrolledClipView(clip)
    await spin(0.6)

    let walk: [(step: String, columns: Int)] = [
      ("out", 5), ("out", 6), ("in", 5), ("in", 4), ("in", 3), ("in", 2), ("out", 3),
    ]
    var previous: GalleryModel.Row.ID?
    for (step, columns) in walk {
      clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 1))
      scrollView.reflectScrolledClipView(clip)
      await spin(0.3)
      let fresh = try #require(
        AssetGridView.anchorRowID(frames: sink.frames, viewportHeight: viewport))
      let before = try #require(sink.frames[fresh]).midY
      // The nudge re-picks only if the previous restore has finished; with
      // parallel suites starving the main thread it sometimes has not
      // (measured: 1 full run in 3, ungrouped, "row 49 … now 556" — row 49
      // tied row 51, the grid's held anchor, at the centre line). The grid
      // then still holds the previous anchor, which is just as right when
      // it ties the fresh pick at the same y. Without a tie there is one
      // candidate, as before.
      var candidates = [fresh]
      if let previous, previous != fresh,
        let frame = sink.frames[previous], abs(frame.midY - before) <= 0.5
      {
        candidates.append(previous)
      }
      let settledBefore = sink.settledRestores
      if step == "out" { model.zoomOut() } else { model.zoomIn() }
      // Wait for the grid to say its restore is over, last clamp included:
      // the next nudge only re-picks once the tracker is live again, and a
      // clamp still pending can move the row after it was seen in place
      // (an intermittent failure, about 1 run in 40, before this wait).
      await spin(until: { sink.settledRestores > settledBefore })
      #expect(sink.settledRestores > settledBefore, "\(step) to \(columns): the restore never settled")
      // Right after the rung the old layout's frame still reports the
      // anchor where it was, so "back in place" also needs the new width.
      let width = AssetGridView.cellWidth(columns: columns, paneWidth: clip.bounds.width)
      func landed() -> GalleryModel.Row.ID? {
        candidates.first { id in
          sink.frames[id].map { abs($0.width - width) <= 0.5 && abs($0.midY - before) <= 1 }
            == true
        }
      }
      await spin(until: { landed() != nil })
      await spin(0.3)
      #expect(model.gridColumns == columns)
      let home = landed()
      #expect(
        home != nil,
        "\(scroller) scroller, \(months) months, \(step) to \(columns) columns: rows \(candidates) were at y \(before), now \(candidates.map { sink.frames[$0].map { "\($0.midY)" } ?? "not realised" }) (offset \(clip.bounds.origin.y))")
      previous = home ?? fresh
    }
  }

  private final class FadeSink {
    var frames: [GalleryModel.Row.ID: CGRect] = [:]
    var settledRestores = 0
    var fade = GridFadeState()
    var copyAnchorMidY: CGFloat?
  }

  /// Anchor hold and one-way knob, sampled on every turn from the rung
  /// change until the departing copy has left: the user sees one
  /// crossfade, so every layer that can be on screen — the copy while it is
  /// in the tree, the active grid while its opacity is above zero — holds
  /// the anchor at the viewport y it had (1 pt), and the scroller's knob
  /// (`documentVisibleRect.minY / documentHeight`, starting from its
  /// position before the change) only ever moves one way. The regression
  /// this guards was the knob leaving and coming back, up on zoom in and down on zoom
  /// out, with the picture jumping mid-fade, and smooth at the top. With
  /// reduce motion there is no crossfade: no sample has both layers up.
  @Test(
    "Across a rung change the visible anchor stays put and the knob moves one way",
    arguments: [
      (true, .legacy, false), (true, .overlay, false), (false, .overlay, false),
      (true, .legacy, true), (false, .overlay, true),
    ] as [(Bool, GridScrollerCase, Bool)])
  func rungChangeFadeHoldsTheAnchor(
    _ grouped: Bool, _ scroller: GridScrollerCase, _ reducesMotion: Bool
  ) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    var index = 0
    for month in 0..<12 {
      for day in 1...10 {
        try seedAsset(
          database, index: index,
          uploadedAt: String(format: "2022-%02d-%02dT12:00:00Z", month + 1, day))
        index += 1
      }
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    if grouped {
      model.select(.all, in: .library)
    } else {
      model.select(.project("blog"), in: .collections)
    }
    await model.reload()
    #expect(model.groupsRowsByMonth == grouped)
    #expect(model.gridColumns == 4)

    let sink = FadeSink()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: AssetGridView(
        model: model, scrollerStyle: scroller.style, reducesMotion: reducesMotion
      )
        .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 }
        .onPreferenceChange(GridRestoresSettledKey.self) { sink.settledRestores = $0 }
        .onPreferenceChange(GridFadeStateKey.self) { sink.fade = $0 }
        .onPreferenceChange(GridFadeCopyAnchorKey.self) { sink.copyAnchorMidY = $0 })
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(1.0)

    var stack: [NSView] = [try #require(window.contentView)]
    var found: NSScrollView?
    while let view = stack.popLast() {
      if let scroll = view as? NSScrollView {
        found = scroll
        break
      }
      stack.append(contentsOf: view.subviews)
    }
    let scrollView = try #require(found, "no hosted scroll view")
    await spin(until: { scrollView.scrollerStyle == scroller.style })
    #expect(scrollView.scrollerStyle == scroller.style, "the grid never took the \(scroller) scroller")
    let clip = scrollView.contentView
    let document = try #require(scrollView.documentView)
    let content = document.frame.height
    clip.scroll(to: NSPoint(x: 0, y: (content - clip.bounds.height) * 0.55))
    scrollView.reflectScrolledClipView(clip)
    await spin(0.6)
    func knob() -> CGFloat { scrollView.documentVisibleRect.minY / document.frame.height }

    for (step, columns) in [("in", 3), ("out", 4)] {
      // A 1 pt nudge makes the idle tracker pick the row under the centre
      // line afresh (see rungChangeRestoresTheAnchor).
      clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 1))
      scrollView.reflectScrolledClipView(clip)
      await spin(0.3)
      let framesBefore = sink.frames
      let settledBefore = sink.settledRestores
      var knobs = [knob()]
      var misses: [String] = []
      if step == "out" { model.zoomOut() } else { model.zoomIn() }
      let start = Date()
      let width = AssetGridView.cellWidth(columns: columns, paneWidth: clip.bounds.width)
      // Until the restore has settled and the copy has left the tree, at
      // most five seconds.
      while !(sink.settledRestores > settledBefore && !sink.fade.copyPresent),
        Date().timeIntervalSince(start) < 5
      {
        try? await Task.sleep(nanoseconds: 4_000_000)
        pumpRunLoop(until: Date().addingTimeInterval(0.008))
        knobs.append(knob())
        guard let anchor = sink.fade.anchorID, let target = framesBefore[anchor]?.midY else {
          misses.append("no anchor held (\(String(describing: sink.fade.anchorID)))")
          continue
        }
        let at = String(format: "%.3f s", Date().timeIntervalSince(start))
        if reducesMotion, sink.fade.copyPresent, sink.fade.activeOpacity > 0 {
          misses.append("\(at) both layers up under reduce motion")
        }
        if sink.fade.copyPresent {
          if let y = sink.copyAnchorMidY {
            if abs(y - target) > 1 { misses.append("\(at) copy at \(y), not \(target)") }
          } else {
            misses.append("\(at) copy without its anchor cell")
          }
        }
        if sink.fade.activeOpacity > 0 {
          if let frame = sink.frames[anchor], abs(frame.width - width) <= 0.5 {
            if abs(frame.midY - target) > 1 {
              misses.append("\(at) grid at \(frame.midY), not \(target)")
            }
          } else {
            misses.append("\(at) grid without its anchor row")
          }
        }
      }
      let label =
        "\(grouped ? "grouped" : "ungrouped") \(scroller)\(reducesMotion ? " reduce motion" : ""), \(step) to \(columns)"
      #expect(sink.settledRestores > settledBefore, "\(label): the restore never settled")
      #expect(!sink.fade.copyPresent, "\(label): the copy never left")
      #expect(model.gridColumns == columns)
      #expect(misses.isEmpty, "\(label): \(misses.count) of \(knobs.count - 1) samples off, first \(misses.prefix(4))")
      var moves: [CGFloat] = []
      for (a, b) in zip(knobs, knobs.dropFirst()) where b != a { moves.append(b - a) }
      #expect(
        !(moves.contains { $0 > 0 } && moves.contains { $0 < 0 }),
        "\(label): the knob went \(([knobs[0]] + zip(knobs, knobs.dropFirst()).filter { $0 != $1 }.map(\.1)).map { String(format: "%.4f", $0) })")
    }
  }

  /// Anchor hold and one-way knob as a user hits them in the real app:
  /// rungs chained with no scroll in between, on a catalog whose
  /// months differ in size, from several positions. Each layer that can be
  /// on screen holds the anchor (1 pt) and the knob moves one way, unless
  /// the anchor's old y is out of reach at the top or bottom of the
  /// document; after the last rung a fresh report (a 1 pt scroll) puts the
  /// anchor where it was.
  @Test(
    "Chained rungs on unequal months keep the anchor from any position",
    arguments: [(true, 0.15), (true, 0.4), (true, 0.7), (false, 0.15), (false, 0.7)])
  func chainedRungsHoldTheAnchor(_ grouped: Bool, _ fraction: Double) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    var index = 0
    for month in 0..<30 {
      for day in 0..<((month * 37) % 45 + 1) {
        try seedAsset(
          database, index: index,
          uploadedAt: String(
            format: "%04d-%02d-%02dT%02d:00:00Z",
            2020 + month / 12, month % 12 + 1, day % 28 + 1, day % 24))
        index += 1
      }
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    if grouped {
      model.select(.all, in: .library)
    } else {
      model.select(.project("blog"), in: .collections)
    }
    await model.reload()
    #expect(model.groupsRowsByMonth == grouped)
    #expect(model.gridColumns == 4)

    let sink = FadeSink()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: AssetGridView(model: model, scrollerStyle: .overlay, reducesMotion: false)
        .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 }
        .onPreferenceChange(GridRestoresSettledKey.self) { sink.settledRestores = $0 }
        .onPreferenceChange(GridFadeStateKey.self) { sink.fade = $0 }
        .onPreferenceChange(GridFadeCopyAnchorKey.self) { sink.copyAnchorMidY = $0 })
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(1.0)

    var stack: [NSView] = [try #require(window.contentView)]
    var found: NSScrollView?
    while let view = stack.popLast() {
      if let scroll = view as? NSScrollView {
        found = scroll
        break
      }
      stack.append(contentsOf: view.subviews)
    }
    let scrollView = try #require(found, "no hosted scroll view")
    let clip = scrollView.contentView
    let document = try #require(scrollView.documentView)
    func maximum() -> CGFloat { max(0, document.frame.height - clip.bounds.height) }
    func atEdge() -> Bool { clip.bounds.origin.y <= 0.5 || clip.bounds.origin.y >= maximum() - 0.5 }
    func knob() -> CGFloat { scrollView.documentVisibleRect.minY / document.frame.height }
    clip.scroll(to: NSPoint(x: 0, y: maximum() * fraction))
    scrollView.reflectScrolledClipView(clip)
    await spin(0.6)

    var anchor: GalleryModel.Row.ID?
    var target: CGFloat = 0
    for (step, columns) in [("in", 3), ("in", 2), ("out", 3), ("out", 4), ("out", 5), ("out", 6)] {
      let framesBefore = sink.frames
      let settledBefore = sink.settledRestores
      var knobs = [knob()]
      var misses: [String] = []
      if step == "out" { model.zoomOut() } else { model.zoomIn() }
      let start = Date()
      let width = AssetGridView.cellWidth(columns: columns, paneWidth: clip.bounds.width)
      // Straight on to the next rung once the copy has left: ⌘= ⌘= with
      // no scroll between, at most five seconds each.
      while !(sink.settledRestores > settledBefore && !sink.fade.copyPresent),
        Date().timeIntervalSince(start) < 5
      {
        try? await Task.sleep(nanoseconds: 4_000_000)
        pumpRunLoop(until: Date().addingTimeInterval(0.008))
        knobs.append(knob())
        guard let held = sink.fade.anchorID, let y = framesBefore[held]?.midY else { continue }
        anchor = held
        target = y
        let at = String(format: "%.3f s", Date().timeIntervalSince(start))
        if sink.fade.copyPresent, let copy = sink.copyAnchorMidY, abs(copy - y) > 1 {
          misses.append("\(at) copy at \(copy), not \(y)")
        }
        if sink.fade.activeOpacity > 0, !atEdge() {
          if let frame = sink.frames[held], abs(frame.width - width) <= 0.5 {
            if abs(frame.midY - y) > 1 { misses.append("\(at) grid at \(frame.midY), not \(y)") }
          } else {
            misses.append("\(at) grid without its anchor row")
          }
        }
      }
      let label = "\(grouped ? "grouped" : "ungrouped") from \(fraction), \(step) to \(columns)"
      #expect(sink.settledRestores > settledBefore, "\(label): the restore never settled")
      #expect(!sink.fade.copyPresent, "\(label): the copy never left")
      #expect(model.gridColumns == columns)
      #expect(misses.isEmpty, "\(label): \(misses.count) of \(knobs.count - 1) samples off, first \(misses.prefix(4))")
      var moves: [CGFloat] = []
      for (a, b) in zip(knobs, knobs.dropFirst()) where b != a { moves.append(b - a) }
      #expect(
        !(moves.contains { $0 > 0 } && moves.contains { $0 < 0 }),
        "\(label): the knob went \(([knobs[0]] + zip(knobs, knobs.dropFirst()).filter { $0 != $1 }.map(\.1)).map { String(format: "%.4f", $0) })")
    }

    // Where the last rung really left the anchor: a 1 pt scroll brings a
    // report laid out at the offset the view has now.
    let held = try #require(anchor)
    let edge = atEdge()
    let reported = sink.frames[held]
    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 1))
    scrollView.reflectScrolledClipView(clip)
    await spin(until: { sink.frames[held] != reported })
    let landed = try #require(sink.frames[held], "the anchor row is not realised")
    if !edge {
      #expect(
        abs(landed.midY + 1 - target) <= 1,
        "\(grouped ? "grouped" : "ungrouped") from \(fraction): the anchor ended at \(landed.midY + 1), not \(target)")
    }
  }

  // MARK: - The offset hold ends: the user's scroll and clicks

  /// The 30 unequal months of `chainedRungsHoldTheAnchor`, hosted at
  /// 1200×800 and scrolled to `fraction` of the way down.
  private struct UnequalMonthsGrid {
    let model: GalleryModel
    let window: NSWindow
    let sink: FadeSink
    let scrollView: NSScrollView
    let directory: URL
    var clip: NSClipView { scrollView.contentView }
    var offset: CGFloat { scrollView.contentView.bounds.origin.y }

    /// The copy is up and the grid hidden: a restore in flight, not shown yet.
    var hidden: Bool { sink.fade.copyPresent && sink.fade.activeOpacity == 0 }
    /// The grid shown, no copy left, no restore running.
    var shown: Bool { !sink.fade.copyPresent && sink.fade.activeOpacity == 1 }

    func scroll(to y: CGFloat) {
      clip.scroll(to: NSPoint(x: 0, y: y))
      scrollView.reflectScrolledClipView(clip)
    }

    func close() {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func hostUnequalMonths(
    grouped: Bool, fraction: Double, clickProbe: GridClickProbe? = nil
  ) async throws -> UnequalMonthsGrid {
    let (database, directory) = try makeUITestDatabase()
    var index = 0
    for month in 0..<30 {
      for day in 0..<((month * 37) % 45 + 1) {
        try seedAsset(
          database, index: index,
          uploadedAt: String(
            format: "%04d-%02d-%02dT%02d:00:00Z",
            2020 + month / 12, month % 12 + 1, day % 28 + 1, day % 24))
        index += 1
      }
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    if grouped {
      model.select(.all, in: .library)
    } else {
      model.select(.project("blog"), in: .collections)
    }
    await model.reload()
    #expect(model.groupsRowsByMonth == grouped)

    let sink = FadeSink()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: AssetGridView(
        model: model, scrollerStyle: .overlay, reducesMotion: false, clickProbe: clickProbe
      )
      .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 }
      .onPreferenceChange(GridRestoresSettledKey.self) { sink.settledRestores = $0 }
      .onPreferenceChange(GridFadeStateKey.self) { sink.fade = $0 })
    window.orderFront(nil)
    await spin(1.0)

    var stack: [NSView] = [try #require(window.contentView)]
    var found: NSScrollView?
    while let view = stack.popLast() {
      if let scroll = view as? NSScrollView {
        found = scroll
        break
      }
      stack.append(contentsOf: view.subviews)
    }
    let grid = UnequalMonthsGrid(
      model: model, window: window, sink: sink,
      scrollView: try #require(found, "no hosted scroll view"), directory: directory)
    let document = try #require(grid.scrollView.documentView)
    grid.scroll(to: max(0, document.frame.height - grid.clip.bounds.height) * fraction)
    await spin(0.6)
    return grid
  }

  /// Pumps in 1 ms slices until `condition` holds, at most three seconds:
  /// a restore keeps the grid hidden for ~25–375 ms, and a test
  /// that acts inside that window must not sleep through it.
  private func pumpFinely(until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.001))
    }
  }

  /// Once a rung change has ended, the offset is the
  /// user's again. A scroll that does not go through the grid's own scroll
  /// host — here `clip.scroll(to:)`, standing in for the user — stays where
  /// it was put (the hold that put SwiftUI's write-back right must be gone).
  @Test(
    "After a rung change the offset hold is released: an outside scroll stays",
    arguments: [true, false])
  func rungChangeReleasesTheOffsetHold(_ grouped: Bool) async throws {
    let grid = try await hostUnequalMonths(grouped: grouped, fraction: 0.4)
    defer { grid.close() }
    let label = grouped ? "grouped" : "ungrouped"
    for (step, columns) in [("in", 3), ("out", 4)] {
      let settledBefore = grid.sink.settledRestores
      if step == "in" { grid.model.zoomIn() } else { grid.model.zoomOut() }
      await spin(until: { grid.sink.settledRestores > settledBefore && grid.shown })
      #expect(grid.model.gridColumns == columns)
      #expect(grid.sink.settledRestores > settledBefore, "\(label) \(step): the restore never settled")
      let reported = grid.sink.frames
      let target = grid.offset + 200
      grid.scroll(to: target)
      await spin(until: { grid.sink.frames != reported || abs(grid.offset - target) > 0.5 })
      #expect(
        abs(grid.offset - target) <= 0.5,
        "\(label), \(step) to \(columns): scrolled to \(target), the offset went back to \(grid.offset)")
    }
  }

  /// The user's scroll during a restore ends it. The entry
  /// is the scroll view's live-scroll notification (what AppKit posts when
  /// a gesture or the scroller starts a scroll; a mouse wheel reaches the
  /// same handler through an event monitor, which a test cannot drive
  /// without synthesising events). After it: the grid is shown at once with
  /// no copy and no fade, the restore is over, and the offset is left alone.
  @Test(
    "The user's scroll during a rung change ends the restore and shows the grid",
    arguments: [(true, 0.4), (false, 0.7)])
  func userScrollEndsTheRestore(_ grouped: Bool, _ fraction: Double) async throws {
    let grid = try await hostUnequalMonths(grouped: grouped, fraction: fraction)
    defer { grid.close() }
    let label = grouped ? "grouped" : "ungrouped"
    let settledBefore = grid.sink.settledRestores
    let before = grid.offset
    grid.model.zoomIn()
    // Inside the restore, after the jump: the hold is on.
    pumpFinely(until: { grid.hidden && abs(grid.offset - before) > 0.5 })
    try #require(grid.hidden, "\(label): never caught the restore with the grid hidden")
    // The fade states from here on, the hidden one included: the next
    // one must be the grid shown — no fade over the copy in between.
    var states = [grid.sink.fade]

    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: grid.scrollView)
    let target = grid.offset + 200
    grid.scroll(to: target)
    #expect(abs(grid.offset - target) <= 0.5, "\(label): the user's scroll to \(target) was put back to \(grid.offset)")

    if states.last != grid.sink.fade { states.append(grid.sink.fade) }
    let start = Date()
    while !grid.shown, Date().timeIntervalSince(start) < 3 {
      pumpRunLoop(until: Date().addingTimeInterval(0.004))
      if states.last != grid.sink.fade { states.append(grid.sink.fade) }
    }
    #expect(
      states.count == 2 && grid.shown,
      "\(label): after the user's scroll the grid went \(states.map { "copy \($0.copyPresent) opacity \($0.activeOpacity)" })")
    await spin(until: { grid.sink.settledRestores > settledBefore })
    #expect(grid.sink.settledRestores > settledBefore, "\(label): the restore never ended")

    let reported = grid.sink.frames
    let again = grid.offset + 100
    grid.scroll(to: again)
    await spin(until: { grid.sink.frames != reported || abs(grid.offset - again) > 0.5 })
    #expect(abs(grid.offset - again) <= 0.5, "\(label): scrolled to \(again), the offset went to \(grid.offset)")
  }

  /// A click while the new grid is hidden (the copy up,
  /// ~25–375 ms after a rung) changes nothing — not on the blank, not on a
  /// cell. Shown again, the same handlers act as usual.
  @Test("A click before the new grid shows leaves the selection alone", arguments: [true, false])
  func clickBeforeRevealKeepsTheSelection(_ grouped: Bool) async throws {
    let probe = GridClickProbe()
    let grid = try await hostUnequalMonths(grouped: grouped, fraction: 0.4, clickProbe: probe)
    defer { grid.close() }
    let label = grouped ? "grouped" : "ungrouped"
    let blank = try #require(probe.blank, "the grid registered no blank-click handler")
    let cell = try #require(probe.cell, "the grid registered no cell-click handler")
    let rows = grid.model.rows
    try #require(rows.count > 10)
    cell(rows[3])
    #expect(grid.model.selectedIDs == [rows[3].id])

    let settledBefore = grid.sink.settledRestores
    grid.model.zoomIn()
    pumpFinely(until: { grid.hidden })
    try #require(grid.hidden, "\(label): never caught the grid hidden")
    blank()
    #expect(grid.model.selectedIDs == [rows[3].id], "\(label): a blank click while hidden changed the selection to \(grid.model.selectedIDs)")
    cell(rows[7])
    #expect(grid.model.selectedIDs == [rows[3].id], "\(label): a cell click while hidden changed the selection to \(grid.model.selectedIDs)")

    await spin(until: { grid.sink.settledRestores > settledBefore && grid.shown })
    #expect(grid.shown)
    #expect(grid.model.selectedIDs == [rows[3].id], "\(label): the selection changed by the time the grid showed")
    cell(rows[7])
    #expect(grid.model.selectedIDs == [rows[7].id], "\(label): a cell click on the shown grid did not select")
    blank()
    #expect(grid.model.selectedIDs.isEmpty, "\(label): a blank click on the shown grid did not clear")
  }

  /// Month headers pin at the top and rest between sections, measured on
  /// the hosted grid's own view tree: SwiftUI renders the header's plate and each text run as their
  /// own leaf views, so no hook is needed. One scroll position holds both
  /// states — the first month pinned at the top, the second one resting
  /// mid-viewport — and a header's views are the leaves no cell frame
  /// contains, split between the two by the gap between the sections. A
  /// second position, deeper, checks the plate with cells under it (the
  /// text is then over cells and no longer separable, so only the plate).
  /// A plate is a leaf at least half the scroll area wide (text runs are
  /// words); the title is the header's leftmost leaf.
  @Test(
    "A month header is bare text at rest and a full-width plate when pinned",
    arguments: GridScrollerCase.allCases)
  func monthHeaderTwoStates(scroller: GridScrollerCase) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Six per month, four columns: two grid rows per section, short enough
    // that the next month's header rests inside the viewport. May pins over
    // March resting. Both titles open on the same glyph, so it cannot matter
    // whether a text leaf reports ink bounds or its layout box (runs have
    // measured "April" 1 pt left of "March" and both at 12.0).
    var index = 0
    for month in [1, 3, 5] {
      for day in 1...6 {
        try seedAsset(
          database, index: index,
          uploadedAt: String(format: "2026-%02d-%02dT12:00:00Z", month, day))
        index += 1
      }
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    #expect(model.groupsRowsByMonth)
    let sections = model.groupedRows.map { $0.rows.map(\.id) }
    try #require(sections.count >= 2)

    let sink = RowFrameSink()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(
      rootView: AssetGridView(model: model, scrollerStyle: scroller.style)
        .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 })
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
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
    await spin(until: { scrollView.scrollerStyle == scroller.style })
    #expect(scrollView.scrollerStyle == scroller.style, "the grid never took the \(scroller) scroller")
    let clip = scrollView.contentView
    let firstTops = sections[0].compactMap { sink.frames[$0]?.minY }
    let topCell = try #require(firstTops.min())
    // Everything in the grid's scroll space (the ScrollView's frame).
    let origin = scrollView.convert(scrollView.bounds, to: host).origin
    func inScrollSpace(_ view: NSView) -> CGRect {
      view.convert(view.bounds, to: host).offsetBy(dx: -origin.x, dy: -origin.y)
    }
    let area = inScrollSpace(clip)
    let height = DesignMetrics.sectionHeader.height
    func scroll(to y: CGFloat) async {
      clip.scroll(to: NSPoint(x: 0, y: y))
      scrollView.reflectScrolledClipView(clip)
      await spin(0.6)
    }
    /// The visible leaves no cell frame contains.
    func headerLeaves() throws -> [CGRect] {
      let cells = Array(sink.frames.values)
      var leaves: [CGRect] = []
      // The pinned header is an overlay over the
      // scroll view, hosted outside its document — search the whole host.
      var stack: [NSView] = [host]
      while let view = stack.popLast() {
        guard view.subviews.isEmpty else {
          stack.append(contentsOf: view.subviews)
          continue
        }
        let frame = inScrollSpace(view)
        guard !view.isHidden, frame.width > 0, frame.height > 0,
          frame.maxY > area.minY, frame.minY < area.maxY,
          !cells.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(frame) })
        else { continue }
        leaves.append(frame)
      }
      return leaves
    }
    func plates(_ band: [CGRect]) -> [CGRect] { band.filter { $0.width >= area.width / 2 } }
    func title(_ band: [CGRect]) -> CGRect? {
      band.filter { $0.width < area.width / 2 }.min { $0.minX < $1.minX }
    }

    // The first month pinned by half a row gap: its natural top is above
    // the viewport, but its pinned frame still ends above the first cell,
    // so no cell lies under its text. The second month rests further down.
    await scroll(to: topCell - AssetGridView.rowSpacing / 2 - height)
    let leaves = try headerLeaves()
    let firstFrames = sections[0].compactMap { sink.frames[$0] }
    let secondTops = sections[1].compactMap { sink.frames[$0]?.minY }
    let firstTop = try #require(firstFrames.map(\.minY).min())
    let firstBottom = try #require(firstFrames.map(\.maxY).max())
    let secondTop = try #require(secondTops.min())
    #expect(firstTop > area.minY + height && secondTop < area.maxY)
    let pinned = leaves.filter { $0.maxY <= firstTop }
    let resting = leaves.filter { $0.minY >= firstBottom - 1 && $0.maxY <= secondTop + 1 }
    let columns = sink.frames.values.map(\.minX)
    let column = try #require(columns.min())
    let restingTitle = try #require(title(resting), "no text in the resting header: \(resting)")
    let pinnedTitle = try #require(title(pinned), "no text in the pinned header: \(pinned)")

    // 1. At rest: no plate.
    #expect(plates(resting).isEmpty, "resting header plates \(plates(resting))")
    // 2. Pinned: the plate (and its separator) spans the scroll area exactly —
    // here, and again with cells scrolling under it.
    #expect(!plates(pinned).isEmpty, "pinned header has no plate: \(pinned)")
    // …with its separator: a hairline along the plate's bottom edge.
    let plate = plates(pinned).max { $0.height < $1.height }
    #expect(
      plates(pinned).contains { line in
        line.height <= 2 && plate.map { abs(line.maxY - $0.maxY) <= 0.5 } == true
      }, "pinned plate has no separator along its bottom: \(plates(pinned))")
    for plate in plates(pinned) {
      #expect(
        abs(plate.minX - area.minX) <= 0.5 && abs(plate.maxX - area.maxX) <= 0.5,
        "pinned plate x \(plate.minX)…\(plate.maxX), scroll area \(area.minX)…\(area.maxX)")
    }
    await scroll(to: clip.bounds.origin.y + 150)
    let deep = plates(try headerLeaves().filter { $0.maxY <= area.minY + height + 1 })
    #expect(!deep.isEmpty, "a header pinned over cells has no plate")
    for plate in deep {
      #expect(
        abs(plate.minX - area.minX) <= 0.5 && abs(plate.maxX - area.maxX) <= 0.5,
        "plate over cells x \(plate.minX)…\(plate.maxX), scroll area \(area.minX)…\(area.maxX)")
    }
    // 3. The text does not move between the states and sits on column one.
    #expect(
      abs(restingTitle.minX - pinnedTitle.minX) <= 0.5
        && abs(pinnedTitle.minX - column) <= 0.5,
      "title minX resting \(restingTitle.minX), pinned \(pinnedTitle.minX), first column \(column)")
  }

  // MARK: - 7. One hovered cell

  /// The bug this guards: many cells stuck in the hover overlay after a
  /// zoom step — a per-cell tracking area moved by layout never received
  /// its exit. The metadata scrim has a hover, but no per-cell tracking: each
  /// grid (the library's, Orphans') tracks the pointer once and names the
  /// cell under it from the cell frames it reports, into one hovered ID
  /// (`GridHoverState`), cleared when the pointer leaves and on every column
  /// change. (A per-cell `onHover` also broke the fade-hold test, 5 of 5
  /// cases, measured.) The property is a grep over the gallery sources,
  /// code lines only (every `//` line is excluded, so a comment naming an
  /// API cannot trip it): no `isHovering`, `onHover` or `NSTrackingArea`
  /// anywhere but the Externals page's group headers (one header per
  /// group, no asset cells); `onContinuousHover` once in each grid,
  /// reporting to its one state.
  @Test("Gallery sources carry no per-cell hover; each grid tracks the pointer once")
  func gallerySourcesHaveNoHoverState() throws {
    let gallery = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PinaxUITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // the package root
      .appendingPathComponent("Sources/PinaxUI/Gallery")
    let files = try FileManager.default
      .contentsOfDirectory(at: gallery, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
    #expect(!files.isEmpty, "no Swift files under \(gallery.path)")
    // The Externals page's group headers hover (no asset cells there).
    let groupHeaderFiles: Set = ["ExternalsView.swift", "ExternalsMigrationViews.swift"]
    var trackers: [String] = []
    var codeOf: [String: [Substring]] = [:]
    for file in files {
      let lines = try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
      codeOf[file.lastPathComponent] = lines.filter {
        !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
      }
      for (index, line) in lines.enumerated()
      where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
        for pattern in ["isHovering", "onHover ", "onHover(", "onHover{", "NSTrackingArea"]
        where !groupHeaderFiles.contains(file.lastPathComponent) {
          #expect(
            !line.contains(pattern),
            "\(file.lastPathComponent):\(index + 1) carries \(pattern): \(line)")
        }
        if line.contains("onContinuousHover") { trackers.append(file.lastPathComponent) }
      }
    }
    #expect(trackers.sorted() == ["AssetGridView.swift", "OrphanView.swift"], "\(trackers)")
    for name in ["AssetGridView.swift", "OrphanView.swift"] {
      let code = codeOf[name] ?? []
      #expect(code.contains { $0.contains("@State private var hover = GridHoverState()") }, "\(name)")
      #expect(code.filter { $0.contains("hover: hover") }.count == 1, "\(name)")
      #expect(code.contains { $0.contains("hover.pointer(at: point, in:") }, "\(name)")
      #expect(code.contains { $0.contains("case .ended: hover.clear()") }, "\(name)")
      #expect(code.contains { $0.contains("hover.clear()") && !$0.contains("case .ended") }, "\(name)")
    }
  }
}
