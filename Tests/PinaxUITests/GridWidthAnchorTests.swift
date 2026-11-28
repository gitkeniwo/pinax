import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import PinaxUI

/// When the grid's width changes with the
/// column count unchanged, the row on the viewport's top edge stays where
/// it was, and comes back to it when the width does. Widths are driven by
/// `window.setFrame`, scrolls by `clip.scroll(to:)` (no synthesised
/// clicks), and every check reads the grid's own reported row frames.
@MainActor
@Suite(.serialized) struct GridWidthAnchorTests {
  /// A hosted grid: 12 months of 30–52 assets, a window `width` wide.
  @MainActor private struct Hosted {
    let model: GalleryModel
    let window: NSWindow
    let scrollView: NSScrollView
    let sink: Sink
    let directory: URL
    var clip: NSClipView { scrollView.contentView }
    var offset: CGFloat { clip.bounds.origin.y }
    var maximum: CGFloat {
      max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
    }

    func scroll(to y: CGFloat) {
      clip.scroll(to: NSPoint(x: 0, y: y))
      scrollView.reflectScrolledClipView(clip)
    }

    func resize(to width: CGFloat) {
      var frame = window.frame
      frame.size.width = width
      window.setFrame(frame, display: true)
    }

    /// Frames are reported when SwiftUI next draws; an offscreen test
    /// window has no display link to ask for it.
    func settle() async {
      let y = offset
      scroll(to: y + 0.25)
      pump()
      scroll(to: y)
      try? await Task.sleep(nanoseconds: 30_000_000)
      pump()
    }

    func close() {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: directory)
    }

    /// The row on the viewport's visible top edge: a cell whose frame
    /// spans `top`; grouped, `top` sits below the pinned month header.
    var topRow: (id: Int64, y: CGFloat, height: CGFloat)? {
      let top = model.showsRowsByMonth ? DesignMetrics.sectionHeader.height : 0
      let spanning = sink.frames.filter { $0.value.minY <= top + 0.5 && $0.value.maxY > top + 0.5 }
      let visible = sink.frames.filter { $0.value.maxY > top + 0.5 }
      let pick =
        spanning.min(by: { $0.key < $1.key })
        ?? visible.min(by: { ($0.value.minY, $0.key) < ($1.value.minY, $1.key) })
      guard let pick else { return nil }
      return (pick.key, pick.value.minY, pick.value.height)
    }
  }

  private final class Sink {
    var frames: [Int64: CGRect] = [:]
  }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pump()
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private func seedMonths(_ database: DatabasePool) throws {
    var index = 0
    for month in 0..<12 {
      for day in 0..<(30 + (month * 7) % 23) {
        try seedAsset(
          database, index: index,
          uploadedAt: String(
            format: "2026-%02d-%02dT%02d:00:00Z", month + 1, day % 28 + 1, day % 24))
        index += 1
      }
    }
  }

  private func makeModel(grouped: Bool) async throws -> (GalleryModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    try seedMonths(database)
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
    return (model, directory)
  }

  private func findScrollView(in root: NSView) -> NSScrollView? {
    var stack: [NSView] = [root]
    var best: NSScrollView?
    while let view = stack.popLast() {
      if let scroll = view as? NSScrollView,
        scroll.frame.width > (best?.frame.width ?? 0)
      {
        best = scroll
      }
      stack.append(contentsOf: view.subviews)
    }
    return best
  }

  private func host(
    grouped: Bool, scroller: GridScrollerCase, width: CGFloat = 1400
  ) async throws -> Hosted {
    let (model, directory) = try await makeModel(grouped: grouped)
    let sink = Sink()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: AssetGridView(model: model, scrollerStyle: scroller.style, reducesMotion: false)
        .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 })
    window.orderFront(nil)
    await spin(1.0)
    let content = try #require(window.contentView)
    let scrollView = try #require(findScrollView(in: content))
    await spin(until: { scrollView.scrollerStyle == scroller.style })
    return Hosted(
      model: model, window: window, scrollView: scrollView, sink: sink, directory: directory)
  }

  private func spin(until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { await spin(0.05) }
  }

  /// The anchor's place against where it started: top edge y when it
  /// started visible, the hidden fraction of its height when it did not.
  private func drift(_ hosted: Hosted, from start: (id: Int64, y: CGFloat, height: CGFloat))
    -> (moved: Bool, error: CGFloat)
  {
    guard let frame = hosted.sink.frames[start.id] else { return (true, .infinity) }
    if start.y >= 0 { return (false, abs(frame.minY - start.y)) }
    return (false, abs(frame.minY / frame.height - start.y / start.height))
  }

  private static let steps: [CGFloat] = stride(from: 1400, through: 900, by: -50).map { $0 }

  // MARK: - 2. the round trip (core)

  @Test("The anchored offset keeps the row's y, holds a hidden fraction, and comes back exactly")
  func anchoredOffsetArithmetic() {
    func rowHeight(_ width: CGFloat, _ columns: Int, _ extra: CGFloat) -> CGFloat {
      (width - CGFloat(columns - 1) * AssetGridView.cellSpacing) / CGFloat(columns) + extra
    }
    for columns in [2, 4, 8] {
      for (oldWidth, newWidth) in [(1384, 884), (884, 1384), (900, 899), (600, 1200)] as [(CGFloat, CGFloat)] {
        for (above, offset, y) in [(0, 0, 0), (7, 3000, 12.5), (31, 9000, -40), (3, 700, 0)] as [(Int, CGFloat, CGFloat)] {
          let extra: CGFloat = 22
          let hOld = rowHeight(oldWidth, columns, extra)
          let hNew = rowHeight(newWidth, columns, extra)
          let result = AssetGridView.anchoredOffset(
            rowsAbove: above, columns: columns, oldWidth: oldWidth, newWidth: newWidth,
            captionExtra: extra, offset: offset, rowTopY: y)
          let newY = y >= 0 ? y : y * hNew / hOld
          #expect(abs(result - (offset + y + CGFloat(above) * (hNew - hOld) - newY)) <= 0.5)
          let back = AssetGridView.anchoredOffset(
            rowsAbove: above, columns: columns, oldWidth: newWidth, newWidth: oldWidth,
            captionExtra: extra, offset: result, rowTopY: newY)
          #expect(abs(back - offset) <= 0.5)
        }
      }
    }
  }

  @Test(
    "A width round trip 1400→900→1400 keeps the top row where it was",
    arguments: [(true, GridScrollerCase.overlay), (true, .legacy), (false, .overlay)]
      as [(Bool, GridScrollerCase)])
  func roundTripKeepsTheTopRow(_ grouped: Bool, _ scroller: GridScrollerCase) async throws {
    let hosted = try await host(grouped: grouped, scroller: scroller)
    defer { hosted.close() }
    // Not one jump: the absolute offset only comes back if the rows above
    // were laid out, so their heights are not estimates.
    await scrollDown(hosted, to: hosted.maximum * 0.45)
    let start = try #require(hosted.topRow, "no row on the top edge")
    let startOffset = hosted.offset

    var path = Self.steps
    path.append(contentsOf: Self.steps.reversed().dropFirst())
    for width in path {
      hosted.resize(to: width)
      await spin(0.12)
      await hosted.settle()
      let result = drift(hosted, from: start)
      let tolerance: CGFloat = start.y >= 0 ? 1 : 0.01
      #expect(
        !result.moved && result.error <= tolerance,
        "width \(width): the top row \(start.id) is \(result.error) off (y was \(start.y))")
    }
    #expect(
      abs(hosted.offset - startOffset) <= 1,
      "back at 1400 the offset is \(hosted.offset), it was \(startOffset)")
  }

  // MARK: - 2b. one wide step

  /// Every cell frame the grid reports, in document y, keyed by row id.
  private func documentYs(_ hosted: Hosted) -> [Int64: CGFloat] {
    var ys: [Int64: CGFloat] = [:]
    for (id, frame) in hosted.sink.frames where frame.height > 0 {
      ys[id] = hosted.offset + frame.minY
    }
    return ys
  }

  /// Scrolls up 3600 pt in 120 pt steps; the rows whose document y changed
  /// between two reports, as "id: from→to at offset".
  private func jumpsScrollingUp(_ hosted: Hosted) async -> [String] {
    var seen: [Int64: CGFloat] = [:]
    var jumps: [String] = []
    for _ in 0..<30 {
      for (id, y) in documentYs(hosted) {
        if let old = seen[id], abs(old - y) > 1 { jumps.append("\(id): \(Int(old))→\(Int(y)) at \(Int(hosted.offset))") }
        seen[id] = y
      }
      if hosted.offset <= 0 { break }
      hosted.scroll(to: max(0, hosted.offset - 120))
      await spin(0.05)
      await hosted.settle()
    }
    return jumps
  }

  @Test(
    "One wide width step puts the top row back and scrolling up moves no row",
    arguments: [
      (true, 0.45, 1100.0), (true, 0.45, 1050.0), (true, 0.45, 1000.0), (true, 0.45, 950.0),
      (true, 0.30, 1100.0), (true, 0.30, 1050.0), (true, 0.30, 1000.0), (true, 0.30, 950.0),
      (false, 0.45, 1100.0), (false, 0.45, 1050.0), (false, 0.45, 1000.0), (false, 0.45, 950.0),
      (false, 0.30, 1100.0), (false, 0.30, 1050.0), (false, 0.30, 1000.0), (false, 0.30, 950.0),
    ] as [(Bool, Double, Double)])
  func oneWideStep(_ grouped: Bool, _ fraction: Double, _ width: Double) async throws {
    let hosted = try await host(grouped: grouped, scroller: .overlay)
    defer { hosted.close() }
    await scrollDown(hosted, to: hosted.maximum * CGFloat(fraction))
    let start = try #require(hosted.topRow, "no row on the top edge")
    hosted.resize(to: CGFloat(width))
    await spin(0.3)
    await hosted.settle()
    await hosted.settle()
    let result = drift(hosted, from: start)
    let tolerance: CGFloat = start.y >= 0 ? 1 : 0.01
    #expect(
      !result.moved && result.error <= tolerance,
      "1400→\(width): the top row \(start.id) is \(result.error) off (y was \(start.y))")
    let jumps = await jumpsScrollingUp(hosted)
    #expect(jumps.isEmpty, "\(jumps.count) rows jumped scrolling up: \(jumps.prefix(4))")
  }

  /// Down to `target` the way a user gets there: 400 pt at a time, each step
  /// laid out, so the rows on the way are built and the lazy grid's
  /// estimate for the rows above is the real one.
  private func scrollDown(_ hosted: Hosted, to target: CGFloat) async {
    while hosted.offset < target - 0.5 {
      hosted.scroll(to: min(target, hosted.offset + 400))
      await spin(0.05)
      await hosted.settle()
    }
    await spin(0.3)
    hosted.scroll(to: hosted.offset + 1)
    await spin(0.3)
    await hosted.settle()
  }

  /// Nine widths between 1400 and 1100, the way a pane's slide squeezes
  /// the centre column frame by frame.
  private static let slideSteps: [CGFloat] = stride(from: 1365, through: 1085, by: -35).map { $0 }

  /// The wide steps `oneWideStep` leaves out: the legacy scroller, and one
  /// step wider rather than narrower.
  @Test(
    "One wide width step either way, either scroller, puts the top row back",
    arguments: [
      (true, GridScrollerCase.legacy, false), (true, .overlay, true), (false, .legacy, true),
    ] as [(Bool, GridScrollerCase, Bool)])
  func oneWideStepBothWays(
    _ grouped: Bool, _ scroller: GridScrollerCase, _ widens: Bool
  ) async throws {
    let hosted = try await host(grouped: grouped, scroller: scroller)
    defer { hosted.close() }
    await scrollDown(hosted, to: hosted.maximum * 0.45)
    if widens {
      for width in Self.slideSteps {
        hosted.resize(to: width)
        await spin(0.05)
      }
      await spin(0.3)
      await hosted.settle()
    }
    let start = try #require(hosted.topRow, "no row on the top edge")
    let target: CGFloat = widens ? 1400 : Self.slideSteps.last!
    hosted.resize(to: target)
    await spin(0.3)
    await hosted.settle()
    await hosted.settle()
    let result = drift(hosted, from: start)
    let tolerance: CGFloat = start.y >= 0 ? 1 : 0.01
    #expect(
      !result.moved && result.error <= tolerance,
      "one step to \(target): the top row \(start.id) is \(result.error) off (y was \(start.y))")
    let jumps = await jumpsScrollingUp(hosted)
    #expect(jumps.isEmpty, "\(jumps.count) rows jumped scrolling up: \(jumps.prefix(4))")
  }

  // MARK: - 2c. a pane's slide lays the grid out at every width

  /// The sidebar and the inspector toggle the way the app does, and the
  /// window walks through the widths a slide passes: at each one the grid
  /// takes that width (the cells are as wide as `gridWidth` makes them),
  /// and once a pane is back the top row is where it started.
  @Test("Opening and closing a pane lays the grid out at every width it passes and puts the top row back")
  func paneSlideLaysOutEveryWidth() async throws {
    let hosted = try await host(grouped: true, scroller: .overlay)
    defer { hosted.close() }
    await scrollDown(hosted, to: hosted.maximum * 0.45)
    let start = try #require(hosted.topRow, "no row on the top edge")
    let columns = hosted.model.gridColumns
    let toggles: [(String, () -> Void)] = [
      ("inspector", { hosted.model.toggleInspector() }),
      ("sidebar", { hosted.model.toggleSidebar() }),
    ]
    for (pane, toggle) in toggles {
      for (phase, path) in [("in", Self.slideSteps), ("out", Self.slideSteps.reversed().dropFirst() + [1400])] {
        toggle()
        for width in path {
          hosted.resize(to: width)
          await spin(0.03)
          await hosted.settle()
          #expect(hosted.model.gridColumns == columns, "\(pane) \(phase) \(width): the rung changed")
          let paneWidth = hosted.window.contentView?.bounds.width ?? 0
          let expected = AssetGridView.cellWidth(columns: columns, paneWidth: paneWidth)
          let cell = hosted.sink.frames[start.id]?.width ?? 0
          #expect(
            abs(cell - expected) <= 0.5,
            "\(pane) \(phase) \(width): the cells are \(cell) wide, the pane makes them \(expected)")
        }
        await spin(0.6)
        await hosted.settle()
      }
      let result = drift(hosted, from: start)
      let tolerance: CGFloat = start.y >= 0 ? 1 : 0.01
      #expect(
        !result.moved && result.error <= tolerance,
        "\(pane) back: the top row \(start.id) is \(result.error) off (y was \(start.y))")
    }
  }

  // MARK: - 3. the bottom

  @Test(
    "At the bottom a round trip puts the top row back",
    arguments: [(true, GridScrollerCase.overlay), (true, .legacy), (false, .overlay)]
      as [(Bool, GridScrollerCase)])
  func bottomRoundTrip(_ grouped: Bool, _ scroller: GridScrollerCase) async throws {
    let hosted = try await host(grouped: grouped, scroller: scroller)
    defer { hosted.close() }
    for _ in 0..<5 {
      hosted.scroll(to: hosted.maximum)
      await spin(0.4)
    }
    await hosted.settle()
    let start = try #require(hosted.topRow, "no row on the top edge")
    hosted.resize(to: 900)
    await spin(0.3)
    await hosted.settle()
    hosted.resize(to: 1400)
    await spin(0.4)
    await hosted.settle()
    await hosted.settle()
    let result = drift(hosted, from: start)
    let tolerance: CGFloat = start.y >= 0 ? 1 : 0.01
    #expect(
      !result.moved && result.error <= tolerance,
      "the bottom row \(start.id) came back \(result.error) off (y was \(start.y))")
  }

  // MARK: - 4. the top

  @Test("At the top the offset stays 0 through every step", arguments: [true, false])
  func topStaysAtTheTop(_ grouped: Bool) async throws {
    let hosted = try await host(grouped: grouped, scroller: .overlay)
    defer { hosted.close() }
    hosted.scroll(to: 0)
    await spin(0.4)
    for width in Self.steps + Self.steps.reversed() {
      hosted.resize(to: width)
      await spin(0.1)
      #expect(hosted.offset == 0, "width \(width): offset \(hosted.offset)")
    }
  }

  // MARK: - 5. the user takes over

  @Test("A scroll by the user anchors the next change on the new top row")
  func userScrollTakesTheAnchor() async throws {
    let hosted = try await host(grouped: true, scroller: .overlay)
    defer { hosted.close() }
    hosted.scroll(to: hosted.maximum * 0.3)
    await spin(0.5)
    hosted.resize(to: 1100)
    await spin(0.3)
    // The user scrolls: a live scroll, then the offset moves.
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: hosted.scrollView)
    hosted.scroll(to: hosted.offset + 900)
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification, object: hosted.scrollView)
    await spin(0.5)
    await hosted.settle()
    let start = try #require(hosted.topRow)
    hosted.resize(to: 900)
    await spin(0.3)
    await hosted.settle()
    let result = drift(hosted, from: start)
    #expect(
      !result.moved && result.error <= (start.y >= 0 ? 1 : 0.01),
      "the new top row \(start.id) is \(result.error) off after the next change")
    hosted.resize(to: 1100)
    await spin(0.3)
    await hosted.settle()
    let back = drift(hosted, from: start)
    #expect(!back.moved && back.error <= (start.y >= 0 ? 1 : 0.01))
  }

  // MARK: - 5b. the app's own scrolls take the anchor

  @Test(
    "A keyboard Home or End after a width change anchors the next change on the new top row",
    arguments: [GalleryModel.GridMove.end, .home])
  func programmaticScrollTakesTheAnchor(_ move: GalleryModel.GridMove) async throws {
    let hosted = try await host(grouped: true, scroller: .overlay)
    defer { hosted.close() }
    hosted.scroll(to: hosted.maximum * 0.4)
    await spin(0.5)
    // The width change locks the anchor on the mid-grid row.
    hosted.resize(to: 1100)
    await spin(0.3)
    await hosted.settle()
    let before = hosted.offset
    // The app's own entry for Home / End (installed by the grid view).
    let keyboardMove = try #require(hosted.model.gridKeyboardMove, "the grid installed no keyboard entry")
    // End on a lazy grid lands on an estimated end first; it takes a few.
    for _ in 0..<(move == .end ? 5 : 1) {
      keyboardMove(move)
      await spin(0.6)
    }
    await hosted.settle()
    #expect(abs(hosted.offset - before) > 100, "the \(move) did not scroll (\(before) → \(hosted.offset))")
    // The new anchor is the row the scroll left on the top edge: the end
    // of the document stays at its end (the bottom clamps, so the row's own
    // y cannot hold), Home stays at 0. The first anchor, mid-grid, would
    // pull the offset back to the middle.
    hosted.resize(to: 900)
    await spin(0.3)
    await hosted.settle()
    let expected: CGFloat = move == .end ? hosted.maximum : 0
    #expect(
      abs(hosted.offset - expected) <= 1,
      "after \(move) a width change put the offset at \(hosted.offset), not \(expected) (pulled back to the old anchor)")
  }

  // MARK: - 6. sidebar and inspector

  @Test("Closing and opening the sidebar and the inspector brings the top row back")
  func columnVisibilityRoundTrip() async throws {
    let (model, directory) = try await makeModel(grouped: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sink = Sink()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1500, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    model.isSidebarVisible = true
    model.showsInspector = false
    window.contentView = NSHostingView(
      rootView: GalleryView(model: model)
        .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 })
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(1.2)
    let content = try #require(window.contentView)
    let scrollView = try #require(findScrollView(in: content))
    let hosted = Hosted(
      model: model, window: window, scrollView: scrollView, sink: sink, directory: directory)
    hosted.scroll(to: hosted.maximum * 0.45)
    await spin(0.8)
    await hosted.settle()
    // The detail column is hosted on its own: its row frames do not reach
    // this root, so the anchor is read off the offset. Rows grow with the
    // width, the rows above the anchor grow with them, and the offset must
    // follow both ways and come back.
    let start = hosted.offset
    let steps: [(String, () -> Void, (CGFloat) -> Bool)] = [
      ("sidebar closed", { model.isSidebarVisible = false }, { $0 > start + 20 }),
      ("sidebar open", { model.isSidebarVisible = true }, { abs($0 - start) <= 1 }),
      ("inspector open", { model.showsInspector = true }, { $0 < start - 20 }),
      ("inspector closed", { model.showsInspector = false }, { abs($0 - start) <= 1 }),
    ]
    for (name, toggle, holds) in steps {
      toggle()
      await spin(1.0)
      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      await spin(0.5)
      #expect(holds(hosted.offset), "\(name): offset \(hosted.offset), it was \(start), document \(scrollView.documentView?.frame.width ?? 0) wide, columns \(model.gridColumns)")
    }
  }
}

nonisolated private func pump() {
  RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
