import AppKit
import CatalogCore
import SwiftUI

/// The zoom ladder: the discrete list of
/// column counts that pinch and ⌘+/⌘− move through. It is a list, not a
/// range — `5` is deliberately included, do not "optimise" it away. One constant, like `GalleryWidthBudget`, and
/// the tests read this same constant. Public because it appears in public
/// API (the gallery model's init default and the preference store's
/// sanitisation).
public enum GridZoom {
  public static let columns = [2, 3, 4, 5, 6, 8]
  public static let defaultColumns = 4

  public static func sliderPosition(for columns: Int) -> Double {
    guard let index = self.columns.firstIndex(of: columns) else {
      return sliderPosition(for: defaultColumns)
    }
    return Double(self.columns.count - 1 - index)
  }

  public static func columns(atSliderPosition position: Double) -> Int {
    let sliderIndex = min(max(Int(position.rounded()), 0), columns.count - 1)
    return columns[columns.count - 1 - sliderIndex]
  }
}

/// Maps a continuous pinch-scale stream onto whole ladder rungs.
/// The trackpad reports small scale deltas; every `rungInterval` of
/// accumulated travel crosses one rung, and sub-rung leftovers persist only
/// for the gesture's duration — a slow pinch snaps rung by rung, an aborted
/// pinch (fingers back to neutral) crosses none. Pure arithmetic, kept
/// separate so the recognizer plumbing above it stays trivial and this part
/// is unit-tested directly.
struct PinchZoomAccumulator {
  /// Pinch travel (scale units) that crosses one rung: a full open gesture
  /// (~+1.0 of scale) walks about four rungs.
  static let rungInterval: CGFloat = 0.25

  private var excess: CGFloat = 0

  /// Feeds one gesture delta; returns how many rungs to move — negative for
  /// pinch-close (zoom out, more columns).
  mutating func advance(by delta: CGFloat) -> Int {
    excess += delta
    var rungs = 0
    while excess >= Self.rungInterval {
      excess -= Self.rungInterval
      rungs += 1
    }
    while excess <= -Self.rungInterval {
      excess += Self.rungInterval
      rungs -= 1
    }
    return rungs
  }

  /// Gesture end: leftover travel dies with the gesture, so the next pinch
  /// starts clean instead of inheriting half a rung.
  mutating func reset() {
    excess = 0
  }
}

/// Frames of the rows the active grid has realised, in the scroll viewport's
/// coordinate space, refreshed by the preference pipeline in `body`. A row
/// that scrolls out of realisation stops contributing, so the dictionary is
/// exactly the rows at (or just off) the viewport — the only candidates for
/// the centre line. Read-only telemetry: preferences that feed back into
/// layout break SwiftUI's update chain; this never does. Internal, not private, so `AssetGridTests`
/// reads the very frames the restore loop reads.
struct RowFramesKey: PreferenceKey {
  static var defaultValue: [GalleryModel.Row.ID: CGRect] = [:]
  static func reduce(
    value: inout [GalleryModel.Row.ID: CGRect],
    nextValue: () -> [GalleryModel.Row.ID: CGRect]
  ) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// How many rung-change restores have run to their end, final clamp
/// included. Read-only: nothing in the grid reads it back; it exists so a
/// test can wait for the restore instead of guessing its duration.
struct GridRestoresSettledKey: PreferenceKey {
  static var defaultValue = 0
  static func reduce(value: inout Int, nextValue: () -> Int) {
    value = max(value, nextValue())
  }
}

/// The crossfade as the tests read it: the row the restore
/// holds, whether the departing copy is in the tree, and the active grid's
/// opacity (the value it is animating to — 0 means hidden).
struct GridFadeState: Equatable {
  var anchorID: GalleryModel.Row.ID?
  var copyPresent = false
  var activeOpacity: Double = 1
}

struct GridFadeStateKey: PreferenceKey {
  static let defaultValue = GridFadeState()
  static func reduce(value: inout GridFadeState, nextValue: () -> GridFadeState) {
    value = nextValue()
  }
}

/// The departing copy's anchor cell, its midY in the grid's scroll space.
struct GridFadeCopyAnchorKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = value ?? nextValue()
  }
}

/// The grid's click handlers, for a test: the
/// same functions the tap gestures call, registered when the grid
/// appears, since a test cannot click.
final class GridClickProbe {
  var blank: (() -> Void)?
  var cell: ((GalleryModel.Row) -> Void)?
}

private struct ViewportHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Grabs the `NSScrollView` SwiftUI hosts under this grid. The restore
/// needs two things `ScrollViewProxy` cannot give (both measured, see the
/// view header): the current offset as a plain number, and a scroll that
/// moves by an exact delta without consulting the lazy container's layout
/// estimates. The representable sits in SwiftUI's hosting layer, outside
/// the scroll view's own tree (an ancestor walk finds nothing — measured),
/// so the real search is rooted at the window and picks the scroll view
/// that geometrically contains this view.
private final class GridScrollHostBox {
  weak var anchorView: NSView?
  private weak var foundScrollView: NSScrollView? {
    didSet {
      observeDocument()
      pinStyle()
    }
  }
  /// The scroller style the grid pins (`GridScrollHost`).
  var style: NSScroller.Style?
  private var documentObserver: (any NSObjectProtocol)?
  /// An offset to jump to the moment the document next changes size.
  /// A rung change is handled before SwiftUI lays the new columns out, so
  /// the document still has its old height then: jumping at once would be
  /// clamped to the old height, and jumping a turn later lets one frame
  /// show the new height at the old offset — the knob leaving and coming
  /// back. The size change is posted inside that layout pass, before the
  /// frame is drawn, so the height and the offset change together.
  var pendingJump: CGFloat?

  // MARK: Width anchor

  /// The row on the viewport's top edge, kept while the grid's width
  /// changes. Set by the view from idle frame reports, locked once a width
  /// change has used it, dropped when the user scrolls (`dropWidthAnchor`).
  var widthAnchor: WidthAnchor?
  /// Called inside the document's frame-change notification — the layout
  /// pass that carries the new size, before the frame is drawn.
  var onDocumentResize: (() -> Void)?
  private var anchorBoundsObserver: NSObjectProtocol?
  private var anchorTarget: CGFloat?
  private var reasserting = false
  private var resizeObserver: (any NSObjectProtocol)?
  private var anchorLiveScrollObserver: (any NSObjectProtocol)?
  private var anchorWheelMonitor: Any?
  private weak var anchorObservedDocument: NSView?

  /// Idempotent; run from `updateNSView` once the scroll view exists. A
  /// second, separate observer of the document from `observeDocument`'s.
  func observeWidthAnchor() {
    guard let scrollView else { return }
    if let document = scrollView.documentView, anchorObservedDocument !== document {
      if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
      anchorObservedDocument = document
      document.postsFrameChangedNotifications = true
      resizeObserver = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: document, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.onDocumentResize?() }
      }
    }
    if anchorBoundsObserver == nil {
      anchorBoundsObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reassertAnchorTarget() }
      }
    }
    if anchorLiveScrollObserver == nil {
      anchorLiveScrollObserver = NotificationCenter.default.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.widthAnchor = nil }
      }
    }
    if anchorWheelMonitor == nil {
      anchorWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        MainActor.assumeIsolated {
          if event.scrollingDeltaY != 0, let scrollView = self?.scrollView,
            event.window === scrollView.window,
            scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
          {
            self?.widthAnchor = nil
          }
        }
        return event
      }
    }
  }

  /// Writes the anchor's offset: the document's size has already changed
  /// (this runs inside its notification), so the clamp is against the new
  /// height. Not `scroll(to:)`, which would drop the anchor as a user scroll.
  @discardableResult
  func scrollForWidthAnchor(to target: CGFloat) -> Bool {
    guard let scrollView, let maximumOffset else { return false }
    let clip = scrollView.contentView
    if anchorTarget == nil {
      DispatchQueue.main.async { [weak self] in self?.anchorTarget = nil }
    }
    anchorTarget = target
    let clamped = min(max(0, target), maximumOffset)
    guard abs(clamped - clip.bounds.origin.y) > 0.01 else { return false }
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
    scrollView.reflectScrolledClipView(clip)
    return true
  }

  /// `HostingScrollView` writes the offset it stored back after the
  /// document's size changes, possibly after our write. Inside the
  /// same run-loop turn only, a bounds change that is not the target is
  /// put back before the frame draws; input arrives in a later turn.
  private func reassertAnchorTarget() {
    guard let scrollView, let target = anchorTarget, !reasserting, let maximumOffset else {
      return
    }
    let clip = scrollView.contentView
    let clamped = min(max(0, target), maximumOffset)
    guard abs(clamped - clip.bounds.origin.y) > 0.01 else { return }
    reasserting = true
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
    scrollView.reflectScrolledClipView(clip)
    reasserting = false
  }

  deinit {
    if let anchorBoundsObserver { NotificationCenter.default.removeObserver(anchorBoundsObserver) }
    if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    if let anchorLiveScrollObserver {
      NotificationCenter.default.removeObserver(anchorLiveScrollObserver)
    }
    if let anchorWheelMonitor { NSEvent.removeMonitor(anchorWheelMonitor) }
    if let documentObserver { NotificationCenter.default.removeObserver(documentObserver) }
    if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
    if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
  }

  /// Set while a rung change is in flight, from the rung until the copy
  /// has gone. The user's scroll ends it: the
  /// hold measurably put a wheel back for 0.1–0.3 s, so the moment one
  /// arrives the hold and any pending jump are dropped here and this is
  /// called once, for the view to end the restore and show the grid.
  /// Two ways in, both the user's: a scroll-wheel event over the scroll
  /// view (a mouse wheel posts no live-scroll notification) and the live
  /// scroll AppKit starts for a trackpad gesture or a scroller drag.
  var onUserScroll: (() -> Void)? {
    didSet { watchUserScroll(onUserScroll != nil) }
  }
  private var wheelMonitor: Any?
  private var liveScrollObserver: (any NSObjectProtocol)?

  private func watchUserScroll(_ on: Bool) {
    if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
    liveScrollObserver = nil
    if !on, let wheelMonitor {
      NSEvent.removeMonitor(wheelMonitor)
      self.wheelMonitor = nil
    }
    guard on else { return }
    if let scrollView {
      liveScrollObserver = NotificationCenter.default.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.userScrolled() }
      }
    }
    if wheelMonitor == nil {
      // Local: runs before the event reaches the scroll view, so the hold
      // is gone by the time the wheel moves the offset.
      wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        MainActor.assumeIsolated { self?.wheel(event) }
        return event
      }
    }
  }

  private func wheel(_ event: NSEvent) {
    guard event.scrollingDeltaY != 0, let scrollView, event.window === scrollView.window,
      scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
    else { return }
    userScrolled()
  }

  /// The user has started scrolling: the offset is theirs from here on.
  func userScrolled() {
    guard let handler = onUserScroll else { return }
    pendingJump = nil
    holdOffset = nil
    onUserScroll = nil
    handler()
  }

  var scrollView: NSScrollView? {
    if let foundScrollView { return foundScrollView }
    var current = anchorView?.superview
    while let view = current {
      if let scroll = view as? NSScrollView {
        foundScrollView = scroll
        return scroll
      }
      current = view.superview
    }
    guard let anchorView, let window = anchorView.window,
      let contentView = window.contentView
    else { return nil }
    let hit = Self.findScrollView(under: contentView, containing: anchorView)
    foundScrollView = hit
    return hit
  }

  /// While a rung change's restore owns the offset (from the jump until
  /// the grid shows), an offset nobody here wrote is put back at once, in
  /// the same notification, before anything draws. Measured: right after the jump SwiftUI's `HostingScrollView` wrote back
  /// the offset it had stored before the change (876.775 over the new
  /// 10085 pt document, from `updateContext` → `setBoundsOrigin:`), so the
  /// knob went back before it went forward. Our own scrolls move the hold.
  var holdOffset: CGFloat?
  private var holding = false
  private var clipObserver: (any NSObjectProtocol)?

  private func observeClip() {
    if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    clipObserver = nil
    guard let clip = foundScrollView?.contentView else { return }
    clip.postsBoundsChangedNotifications = true
    clipObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reassertHold() }
    }
  }

  private func reassertHold() {
    guard let hold = holdOffset, !holding, let offset, abs(offset - hold) > 0.5 else { return }
    holding = true
    defer { holding = false }
    scroll(to: hold)
  }

  private func observeDocument() {
    observeClip()
    if let documentObserver { NotificationCenter.default.removeObserver(documentObserver) }
    documentObserver = nil
    guard let document = foundScrollView?.documentView else { return }
    document.postsFrameChangedNotifications = true
    documentObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: document, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.applyPendingJump() }
    }
  }

  /// Pins the scroller style. The pin a turn after the grid's update can
  /// find no scroll view yet (once, under load, the grid kept the
  /// system's style), so it also runs the moment any later lookup finds
  /// it — the idle tracker looks on every frame report.
  func pinStyle() {
    guard let style, let scrollView = foundScrollView, scrollView.scrollerStyle != style
    else { return }
    scrollView.scrollerStyle = style
  }

  /// Jumps to `pendingJump`, if one is waiting; true when it moved.
  @discardableResult
  func applyPendingJump() -> Bool {
    guard let target = pendingJump else { return false }
    pendingJump = nil
    guard let landed = scroll(to: target) else { return false }
    holdOffset = landed
    return true
  }

  private static func findScrollView(
    under view: NSView, containing target: NSView
  ) -> NSScrollView? {
    if let scroll = view as? NSScrollView {
      let targetFrame = target.convert(target.bounds, to: nil)
      let scrollFrame = scroll.convert(scroll.bounds, to: nil)
      if scrollFrame.contains(
        CGPoint(x: targetFrame.midX, y: targetFrame.midY))
      {
        return scroll
      }
    }
    for subview in view.subviews {
      if let found = findScrollView(under: subview, containing: target) {
        return found
      }
    }
    return nil
  }

  /// The scroll offset in the content's flipped coordinates (points from
  /// the top). Nil when the hosted scroll view has not been found yet.
  var offset: CGFloat? {
    scrollView?.contentView.bounds.origin.y
  }

  /// The largest in-range scroll offset: past this there is no content
  /// under the viewport at all.
  private var maximumOffset: CGFloat? {
    guard let scrollView, let document = scrollView.documentView else { return nil }
    return max(0, document.frame.height - scrollView.contentView.bounds.height)
  }

  /// Scrolls by an exact delta, snapped (no animation), CLAMPED to the
  /// document: the offset becomes a number we computed, not one a layout
  /// estimate produced — but never one that lands outside the content.
  ///
  /// The clamp is load-bearing, not defensive (user-reported defect, fixed
  /// here): `NSClipView.scroll(to:)` does NOT run `constrainBoundsRect`, so
  /// it will happily park outside the document. Zooming out repeatedly is
  /// the easy way to trigger it — 80 assets go from 40 rows at n=2 to 10 at
  /// n=8, so the content shrinks about fourfold under a restore that was
  /// computed against the taller layout. Landing past the end realises
  /// nothing, which reads as a blank band above the grid that grows with
  /// every further rung; any real scroll relaids out, the offset gets
  /// constrained, and the rows spring back up.
  @discardableResult
  func scroll(by delta: CGFloat) -> CGFloat? {
    guard let scrollView else { return nil }
    let clip = scrollView.contentView
    let origin = clip.bounds.origin
    var target = origin.y + delta
    if let maximumOffset { target = min(target, maximumOffset) }
    target = max(0, target)
    if holdOffset != nil { holdOffset = target }
    widthAnchor = nil
    holding = true
    defer { holding = false }
    clip.scroll(to: NSPoint(x: origin.x, y: target))
    scrollView.reflectScrolledClipView(clip)
    return clip.bounds.origin.y
  }

  /// Whether a scroll by `delta` would move at all: false when the offset
  /// already sits at the end of the document that `delta` points past.
  func canScroll(by delta: CGFloat) -> Bool {
    guard let offset, let maximumOffset else { return false }
    return delta < 0 ? offset > 0.5 : offset < maximumOffset - 0.5
  }

  /// Scrolls to an exact offset, clamped like `scroll(by:)`.
  @discardableResult
  func scroll(to target: CGFloat) -> CGFloat? {
    guard let offset else { return nil }
    return scroll(by: target - offset)
  }

  /// Pulls an already-out-of-range offset back in. The restore loop scrolls
  /// against a document whose height the lazy container is still correcting,
  /// so an offset that was in range when written can be stranded a moment
  /// later; this runs when the loop stops, so it never leaves the view
  /// parked in a void for the user to scroll out of by hand.
  @discardableResult
  func clampIntoRange() -> CGFloat? {
    guard let scrollView, let maximumOffset else { return nil }
    let clip = scrollView.contentView
    let current = clip.bounds.origin.y
    let target = min(max(0, current), maximumOffset)
    guard abs(target - current) > 0.5 else { return current }
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
    scrollView.reflectScrolledClipView(clip)
    return clip.bounds.origin.y
  }
}

private struct GridScrollHost: NSViewRepresentable {
  let box: GridScrollHostBox
  let style: NSScroller.Style

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    box.anchorView = view
    return view
  }

  /// Overlay scrollers are thin and fade out while idle. With "Always show
  /// scroll bars" on, SwiftUI hosts a legacy scroller that never hides, so the
  /// grid's scroll view is pinned to the overlay style.
  func updateNSView(_ view: NSView, context: Context) {
    box.style = style
    DispatchQueue.main.async { [box] in
      _ = box.scrollView
      box.pinStyle()
      box.observeWidthAnchor()
    }
  }
}

/// The row on the viewport's top edge, as the last idle report before a
/// width change saw it. Everything the new offset needs, measured at
/// one width, so it is computed from the original every time — the anchor
/// is not walked from step to step and so comes back exactly.
struct WidthAnchor {
  /// Any cell of the row (its first one is not needed: the row is
  /// `index / columns`).
  let id: GalleryModel.Row.ID
  let columns: Int
  let firstRowID: GalleryModel.Row.ID?
  let grouped: Bool
  /// `gridWidth` the frame was measured at, and the scroll offset then.
  let width: CGFloat
  /// The document view's width then: `gridWidth` follows the document by a
  /// turn, so the width change is read off the document.
  let documentWidth: CGFloat
  let offset: CGFloat
  /// The row's top in the viewport and its height, then.
  let y: CGFloat
  let height: CGFloat
  /// What a cell adds below its square.
  let captionExtra: CGFloat
  /// Reported at offset 0: stays at the top.
  let atTop: Bool
  /// A width change has used it; reports no longer replace it.
  var locked = false
  /// The offset and width of the last write: a different offset at the
  /// same width means something else moved the scroll view.
  var writtenOffset: CGFloat?
  var writtenDocumentHeight: CGFloat?
  var writtenWidth: CGFloat?
}

/// The idle layout's geometry in the grid's scroll space, written on every
/// idle report. A reference, so the writes never invalidate the view.
private final class IdleLayoutBox {
  var frames: [GalleryModel.Row.ID: CGRect] = [:]
  var headers: [String: CGRect] = [:]
  /// The scroll offset when `frames` were reported.
  var offset: CGFloat?
}

/// The anchor a restore is putting back (`AssetGridView.correctOnReport`).
private final class RestoreTargetBox {
  var id: GalleryModel.Row.ID?
  var y: CGFloat = 0
  /// Corrections still allowed on frame reports for this change.
  var corrections = 0
  /// A settle check is queued (`AssetGridView.settleCheck`).
  var checkQueued = false
  /// Consecutive checks that found the anchor where it will stay.
  var settledChecks = 0
  /// The scroll offset when the last frame report arrived: a scroll since
  /// then moves every reported frame by exactly its delta.
  var reportOffset: CGFloat?
}

/// The departing layout's visible region at a rung change: the cells and month headers the user was looking at, at the
/// scroll-space frames they had, and the pinned header as it was. Drawn
/// over the scroll view, not in its content, so the restore's scrolling
/// never moves it; only what was visible is kept, so it costs a screenful
/// of cells whatever the catalog's size.
private struct FrozenGrid {
  struct Cell {
    let row: GalleryModel.Row
    let frame: CGRect
  }
  struct Header {
    let month: String
    let frame: CGRect
  }
  let columns: Int
  let cells: [Cell]
  let headers: [Header]
  let sticky: StickyMonthHeaderState?
}

/// The copy of the departing layout (`FrozenGrid`), each cell and header
/// at the frame it had. The cells are the grid's own `AssetGridCell`, so
/// they draw what the grid drew (the thumbnail cache's memory peek gives
/// fresh cells their image at once). The anchor's cell reports where it
/// is (`GridFadeCopyAnchorKey`). Its own view type, so the grid's body
/// names only the live cells: the copy never takes a click, a drag or a
/// context menu, and `DragOutTests.gridWiring` reads every `AssetGridCell`
/// in the body's type as a live branch.
private struct FrozenGridLayer: View {
  let frozen: FrozenGrid
  @ObservedObject var model: GalleryModel
  let anchorID: GalleryModel.Row.ID?
  let scrollSpace: String
  let usageCaption: UsageGridCaption

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(frozen.headers, id: \.month) { header in
        if let group = model.groupedRows.first(where: { $0.month == header.month }) {
          GridSectionHeader(model: model, key: group.month, loaded: group.rows.count)
          .frame(width: header.frame.width, height: header.frame.height)
          .offset(x: header.frame.minX, y: header.frame.minY)
        }
      }
      ForEach(frozen.cells, id: \.row.id) { cell in
        AssetGridCell(
          row: cell.row,
          cache: model.thumbnails,
          overlays: model.gridOverlays,
          thumbnailSizing: model.gridThumbnailSizing,
          isSelected: model.selectedIDs.contains(cell.row.id),
          quickLook: nil,
          tier: SourceTier(columns: frozen.columns),
          usageCaption: usageCaption)
          .frame(width: cell.frame.width, height: cell.frame.height)
          .background {
            if cell.row.id == anchorID {
              GeometryReader { geo in
                Color.clear.preference(
                  key: GridFadeCopyAnchorKey.self,
                  value: geo.frame(in: .named(scrollSpace)).midY)
              }
            }
          }
          .offset(x: cell.frame.minX, y: cell.frame.minY)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .clipped()
  }
}

/// The asset grid: a fixed-column-count `LazyVGrid`.
/// The column count is decoupled from the pane width: with `n` constant the
/// cell width is a linear function of the pane width with slope exactly
/// `1/n`, so a sidebar drag or window resize tracks through arithmetic —
/// smoothness comes from the math, not from animation. An adaptive
/// `GridItem(.adaptive)` grid flips its count mid-drag, and animating that
/// flip (a frozen departing layout and a two-layout lerp) measured ~62 µs
/// per cell, losing 60 fps near ~280 cells.
struct AssetGridView: View {
  @ObservedObject var model: GalleryModel
  /// The scroller style the grid's scroll view is pinned to. The app always
  /// uses the default; the tests' second leg hosts the grid pinned to
  /// `.legacy`, the style a mouse-attached Mac or "Always show scroll bars"
  /// would otherwise hand the grid.
  var scrollerStyle: NSScroller.Style = .overlay
  /// Reduce motion: nil follows the system; the tests set it.
  var reducesMotion: Bool?
  /// Tests only: receives the click handlers (`GridClickProbe`).
  var clickProbe: GridClickProbe?
  /// Usage's captions (the date line on Images, "Line N" and
  /// "same as above" on Files). `.none` is the library's.
  var usageCaption: UsageGridCaption = .none
  /// Usage ▸ Files' grid is three columns wide, a
  /// contact sheet, whatever the zoom ladder says; nil follows the
  /// rung (the library, Orphans, Usage ▸ Images).
  var columnCount: Int? = nil

  /// The columns laid out: the override, else the model's rung.
  private var columns: Int { columnCount ?? model.gridColumns }
  @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
  /// The one hovered cell, cleared on every column change.
  @State private var hover = GridHoverState()

  /// Pinch zoom state: the last scale the recognizer reported (deltas
  /// are measured against it; nil between gestures) and the rung accumulator.
  @State private var pinchPreviousScale: CGFloat?
  @State private var pinchAccumulator = PinchZoomAccumulator()

  /// The crossfade. Three mechanisms were measured in the
  /// running app before this shape was chosen:
  ///
  /// * `.id(n)` + `.transition(.opacity)` — the identity change races the
  ///   preference flush (the anchor got chosen from the NEW layout's frames
  ///   — the no-restore row, not the user's row), and for the fade's
  ///   duration the scroll reader's registry holds duplicate row ids (the
  ///   dying grid's and the replacement's), which made `scrollTo` resolve
  ///   unreliably — one switch never restored (anchor 28 pt off centre at
  ///   settle), and post-fade `scrollTo` calls centred the wrong rows
  ///   outright.
  /// * `ScrollViewProxy.scrollTo` for the restore — it consults the lazy
  ///   container's layout estimates for anything not realised, and the
  ///   estimates are wild in both directions: a mid-catalog jump landed
  ///   ~20 pt off, a post-churn one centred a row 27 places from the
  ///   request, one corrective jump measurably grew the pane ~500 pt wider
  ///   over 500 ms (window auto-grow off a ballooned estimate), and two of
  ///   three probe parks to a far row did not move the view at all.
  /// * A ZStack staging of the departing layout — the copy participates in
  ///   layout, so removing it at cleanup collapsed the container and the
  ///   scroll re-anchored ~136 pt after the fade ended, a visible jump.
  ///
  /// What survives: ONE persistent grid — no identity churn; the cells
  /// re-wrap in place, so thumbnail state survives — opacity as plain state
  /// crossfaded inside `withAnimation`, and the restore as exact
  /// arithmetic: the anchor's viewport y is remembered before the change,
  /// and the hosted scroll view is moved by the exact delta. No registry,
  /// no far jumps on estimates.
  ///
  /// The old layout is not staged in the content: anything there moves with
  /// every scroll the restore makes, and the copy is up for the whole fade.
  /// It is `FrozenGrid`, over the scroll view.
  @State private var frozen: FrozenGrid?
  /// The anchor of the newest change, for `GridFadeStateKey`.
  @State private var fadeAnchorID: GalleryModel.Row.ID?
  @State private var activeOpacity: Double = 1
  @State private var frozenOpacity: Double = 1
  /// The layout the user is looking at, kept from the idle reports (cells
  /// and month headers in the scroll space), for the frozen copy.
  @State private var idleLayout = IdleLayoutBox()
  /// The columns the active grid is currently rendering. `onChange` fires
  /// after `model.gridColumns` has already moved AND after the relaid-out
  /// grid's first preference flush has arrived (both measured), so the
  /// departing layout's count and the anchor are kept here, one step ahead
  /// of the mess.
  @State private var displayedColumns: Int?

  /// Scroll anchoring. `rowFrames`/`viewportHeight` are the
  /// selector's inputs; `lastAnchorID`/`lastAnchorY` are updated on every
  /// accepted frame report while idle, so at the moment the rung changes
  /// they already name the row under the centre line of the layout the user
  /// is looking at and the exact viewport y it sits at. `lastTrusted*`
  /// carry the accepted layout's geometry so the coarse restore jump can
  /// run on zero new measurements (cell widths are `cellWidth` arithmetic,
  /// heights scale with width at fixed per-asset aspect).
  @State private var rowFrames: [GalleryModel.Row.ID: CGRect] = [:]
  /// Which month header is pinned; only `StickyMonthHeader` reads it.
  @State private var stickyHeader = StickyMonthHeaderState()
  @State private var viewportHeight: CGFloat = 0
  @State private var lastAnchorID: GalleryModel.Row.ID?
  @State private var lastAnchorY: CGFloat?
  @State private var lastTrustedWidth: CGFloat?
  @State private var lastTrustedPitch: CGFloat?
  /// What a cell adds below its square (captions): the one number that is
  /// the same at every width, so a row's height at any width is
  /// `cellWidth + captionExtra`. Read from the trusted frames.
  @State private var captionExtra: CGFloat?
  /// The width the grids are laid out at (the pane minus `gridInset`).
  @State private var gridWidth: CGFloat?
  /// A restore loop is in flight (measured failure mode: the tracker
  /// re-armed at cleanup while the loop still ran, replaced the anchor, and
  /// the loop "converged" onto the replacement). While set, the tracker
  /// does not re-select; each change captures the anchor it wants and bumps
  /// `restoreGeneration` — only the newest loop may scroll.
  @State private var restoring = false
  @State private var restoreGeneration = 0
  /// The anchor the newest restore is putting back, for the correction that
  /// rides on the frame reports (`correctOnReport`). A reference: written
  /// and read off the render path.
  @State private var restoreTarget = RestoreTargetBox()
  /// Published through `GridRestoresSettledKey`, written only after the
  /// restore's last clamp.
  @State private var settledRestores = 0
  @State private var scrollBox = GridScrollHostBox()
  /// Keyboard focus: a click on a cell or the blank takes it, and
  /// with it the arrows, Home / End and Edit ▸ Select All / Copy.
  @FocusState private var gridFocused: Bool

  static let cellSpacing = DesignMetrics.grid.gap
  /// A row's caption already ends the cell, so rows sit one caption gap
  /// further apart than columns.
  static let rowSpacing = DesignMetrics.grid.gap + DesignMetrics.grid.captionSpacing
  /// Total horizontal padding around the grid (`.padding(gridInset / 2)`
  /// below), so the layout width and this constant cannot drift apart.
  static let gridInset = DesignMetrics.grid.inset
  /// The crossfade length for a column-count change (a fade, not
  /// flying cells). Long enough to read as a fade, short enough that a
  /// rung-walk does not feel delayed.
  static let fadeDuration: TimeInterval = 0.2
  /// How many passes a restore may spend before it gives up and clamps.
  /// Passes that wait for the fade or walk closer to the anchor are free.
  static let restoreBudget = 12
  /// The named coordinate space the row frames are measured in — the scroll
  /// viewport itself, so a row's `minY` is its distance from the top of the
  /// visible region.
  static let scrollSpace = "pinax.grid.scroll"

  /// The only cell width the model can render at `paneWidth` with `columns`
  /// columns:
  ///
  ///     (paneWidth − gridInset − (columns − 1) · cellSpacing) / columns
  ///
  /// Linear in `paneWidth`, slope exactly `1/columns`, no thresholds
  /// anywhere in the domain — asserted by `AssetGridTests`. With the count
  /// constant there is no stale count to pair with a fresh width.
  static func cellWidth(columns: Int, paneWidth: CGFloat) -> CGFloat {
    guard columns > 0 else { return 0 }
    let usable = paneWidth - gridInset - CGFloat(columns - 1) * cellSpacing
    return max(0, usable / CGFloat(columns))
  }

  /// The offset that keeps a row where it was when the grid's width goes
  /// from `oldWidth` to `newWidth` at the same column count.
  /// Every row is `cellWidth + captionExtra` high, so the `rowsAbove` rows
  /// over the anchor scale and nothing else does: month headers and gaps
  /// cancel (same as `arithmeticOffset`, whose `centre()` this repeats on
  /// purpose, so the rung-change restore stays independent). A row top in the viewport
  /// (`y >= 0`) keeps its y; one above it keeps the fraction of its height
  /// that is hidden.
  static func anchoredOffset(
    rowsAbove: Int, columns: Int, oldWidth: CGFloat, newWidth: CGFloat,
    captionExtra: CGFloat, offset: CGFloat, rowTopY y: CGFloat
  ) -> CGFloat {
    func height(_ width: CGFloat) -> CGFloat {
      cellWidth(columns: columns, paneWidth: width + gridInset) + captionExtra
    }
    let old = height(oldWidth)
    let new = height(newWidth)
    let contentTop = offset + y + CGFloat(rowsAbove) * (new - old)
    let newY = y >= 0 || old <= 0 ? y : y * new / old
    return contentTop - newY
  }

  /// Remembers the row on the viewport's top edge from each idle report,
  /// until a width change has used it. Only frames laid out at the width
  /// `gridWidth` names count: a report can arrive at the new width before
  /// `gridWidth` follows, and would take a drifted row for the anchor.
  private func trackWidthAnchor(_ frames: [GalleryModel.Row.ID: CGRect]) {
    guard scrollBox.widthAnchor?.locked != true, let gridWidth, let offset = scrollBox.offset,
      let documentWidth = scrollBox.scrollView?.documentView?.frame.width,
      abs(documentWidth - gridWidth - Self.gridInset) <= 0.5
    else { return }
    let columns = self.columns
    let cell = Self.cellWidth(columns: columns, paneWidth: gridWidth + Self.gridInset)
    let top = model.showsRowSections ? DesignMetrics.sectionHeader.height : 0
    // One snapshot or none: a report that mixes widths is a layout caught
    // half-way, and its rows sit at positions from two different widths.
    guard frames.values.allSatisfy({ abs($0.width - cell) <= 0.5 || !isRealisedFrame($0) })
    else { return }
    var pick: (id: GalleryModel.Row.ID, frame: CGRect)?
    for (id, frame) in frames
    where frame.height > 0 && frame.maxY > top + 0.5 && isRealisedFrame(frame) {
      if let current = pick,
        frame.minY > current.frame.minY || (frame.minY == current.frame.minY && id > current.id)
      {
        continue
      }
      pick = (id, frame)
    }
    guard let pick else { return }
    scrollBox.widthAnchor = WidthAnchor(
      id: pick.id, columns: columns, firstRowID: model.rows.first?.id,
      grouped: model.showsRowSections, width: gridWidth, documentWidth: documentWidth,
      offset: offset,
      y: pick.frame.minY, height: pick.frame.height,
      captionExtra: pick.frame.height - pick.frame.width, atTop: offset <= 0.5)
  }

  /// Runs inside the document's frame-change notification: the offset
  /// that keeps the anchor row, written in the layout pass that carries
  /// the new size (no frame shows the new height at the old offset). A
  /// rung change, a restore, a pending jump or the hold in flight: the
  /// anchor is dropped and the rung-change restore owns the offset.
  private func applyWidthAnchor() {
    guard var anchor = scrollBox.widthAnchor else { return }
    guard let documentWidth = scrollBox.scrollView?.documentView?.frame.width,
      let offset = scrollBox.offset,
      scrollBox.pendingJump == nil, scrollBox.holdOffset == nil, frozen == nil, !restoring,
      displayedColumns == nil || displayedColumns == columns,
      anchor.columns == columns, anchor.grouped == model.showsRowSections,
      anchor.firstRowID == model.rows.first?.id
    else {
      scrollBox.widthAnchor = nil
      return
    }
    let gridWidth = anchor.width + (documentWidth - anchor.documentWidth)
    let widthMoved = abs(gridWidth - (anchor.writtenWidth ?? anchor.width)) > 0.01
    if !anchor.locked && abs(gridWidth - anchor.width) <= 0.01 { return }
    if anchor.locked, !widthMoved, let written = anchor.writtenOffset, abs(offset - written) > 1,
      anchor.writtenDocumentHeight == scrollBox.scrollView?.documentView?.frame.height
    {
      // Same width, same document, and somebody else moved the offset: it
      // is theirs now.
      scrollBox.widthAnchor = nil
      return
    }
    let target: CGFloat
    if anchor.atTop {
      target = 0
    } else {
      guard let above = rowsAbove(anchor.id, columns: anchor.columns) else {
        scrollBox.widthAnchor = nil
        return
      }
      target = Self.anchoredOffset(
        rowsAbove: above, columns: anchor.columns, oldWidth: anchor.width, newWidth: gridWidth,
        captionExtra: anchor.captionExtra, offset: anchor.offset, rowTopY: anchor.y)
    }
    scrollBox.scrollForWidthAnchor(to: target)
    anchor.locked = true
    anchor.writtenWidth = gridWidth
    anchor.writtenOffset = scrollBox.offset
    anchor.writtenDocumentHeight = scrollBox.scrollView?.documentView?.frame.height
    scrollBox.widthAnchor = anchor
  }

  /// The scroll anchor for a column-count change: the row whose
  /// centre is closest to the viewport's centre line, among the rows the
  /// lazy grid realises. Rows lying entirely outside the viewport are not
  /// candidates — a row realised just off-screen must not steal the anchor
  /// from one the user is actually looking at. Pure arithmetic over the
  /// reported frames, unit-tested directly in `AssetGridTests`.
  static func anchorRowID(
    frames: [GalleryModel.Row.ID: CGRect], viewportHeight: CGFloat
  ) -> GalleryModel.Row.ID? {
    guard viewportHeight > 0 else { return nil }
    let centre = viewportHeight / 2
    return frames
      .filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }
      .min { a, b in
        let first = abs(a.value.midY - centre)
        let second = abs(b.value.midY - centre)
        return first == second ? a.key < b.key : first < second
      }?.key
  }

  var body: some View {
    withPinchZoom(
      ScrollView {
        VStack(spacing: 0) {
          gridLayer(columns: columns)
            .opacity(activeOpacity)
            .padding(Self.gridInset / 2)

          // Paging sentinel. It must be lazy: a sentinel that mounts with the
          // content is always "appeared" the moment the grid mounts, which
          // measurably cascaded every page into memory (caught by
          // sentinelPagesWithoutCascade). Inside a LazyVStack the sentinel
          // realizes only when its region is near the viewport: a short
          // catalog keeps filling until it scrolls out; a long one pages
          // exactly when the bottom approaches. The task re-keys on every
          // append; the model's own guards stop the loop at the last page.
          LazyVStack(spacing: 0) {
            Color.clear
              .frame(height: 1)
              .accessibilityHidden(true)
              .task(id: model.rows.count) {
                await model.loadNextPage()
              }
          }
        }
      }
      // A click the cells do not take — gaps, insets, below the last row —
      // clears the selection, as in Finder and Photos. Cell taps win: a
      // child's gesture takes precedence over its ancestor's.
      .contentShape(Rectangle())
      .onTapGesture { blankClicked() }
      // One pointer tracker for the whole grid, on the scroll
      // view (the viewport is `scrollSpace`), resolved against the cell
      // frames the grid already reports. Inside the scrolled content a
      // tracker measurably broke the rung-change restore — one per cell
      // or one for the grid, the fade-hold test lost its anchor row in 5 of
      // 5 cases.
      .onContinuousHover(coordinateSpace: .named(Self.scrollSpace)) { phase in
        switch phase {
        case let .active(point): hover.pointer(at: point, in: rowFrames)
        case .ended: hover.clear()
        }
      }
      .focusable()
      .focusEffectDisabled()
      .focused($gridFocused)
      // `onKeyPress`, not `onMoveCommand`: both reach the focused grid
      // (measured), but only the key press carries its modifiers — ⇧ from
      // `onMoveCommand` would ride on `NSApp.currentEvent`.
      .onKeyPress(
        keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end], phases: [.down, .repeat]
      ) { press in
        let move: GalleryModel.GridMove
        switch press.key {
        case .leftArrow: move = .left
        case .rightArrow: move = .right
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .home: move = .home
        default: move = .end
        }
        moveSelection(move, extending: press.modifiers.contains(.shift))
        return .handled
      }
      // Edit ▸ Select All / Copy reach the grid through the responder chain
      // once it holds focus (measured: never before). A text field with
      // focus answers both itself, ahead of the grid.
      // Keys the Quick Look panel hands over take this same path.
      .onAppear {
        model.gridKeyboardMove = { move in moveSelection(move, extending: false) }
        clickProbe?.blank = { blankClicked() }
        clickProbe?.cell = { row in cellClicked(row) }
      }
      .onDisappear { model.gridKeyboardMove = nil }
      .onCommand(#selector(NSResponder.selectAll(_:))) {
        model.selectAllLoaded()
      }
      .onCommand(#selector(NSText.copy(_:))) {
        model.copySelectionInDefaultFormat()
      }
      .overlay(alignment: .topLeading) {
        if let frozen {
          FrozenGridLayer(
            frozen: frozen, model: model, anchorID: fadeAnchorID,
            scrollSpace: Self.scrollSpace, usageCaption: usageCaption
          )
          .overlay(alignment: .top) {
            if let sticky = frozen.sticky { stickyHeaderOverlay(state: sticky) }
          }
          .opacity(frozenOpacity)
            .allowsHitTesting(false)
        }
      }
      .coordinateSpace(name: Self.scrollSpace)
      .overlay(alignment: .top) {
        if model.showsRowSections {
          stickyHeaderOverlay(state: stickyHeader)
            .opacity(activeOpacity)
        }
      }
      .background(GridScrollHost(box: scrollBox, style: scrollerStyle))
      .background(
        GeometryReader { geo in
          Color.clear.preference(
            key: ViewportHeightKey.self, value: geo.size.height)
        })
      .onPreferenceChange(RowFramesKey.self) { frames in
        rowFrames = frames
        restoreTarget.reportOffset = scrollBox.offset
        correctOnReport()
        // Track the anchor continuously while idle: at the rung change this
        // value already names the row under the centre line, so the restore
        // never depends on reading state mid-transition (measured race —
        // see the class header).
        if isIdle {
          trackIdle(frames)
          trackWidthAnchor(frames)
        }
      }
      .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
      .preference(key: GridRestoresSettledKey.self, value: settledRestores)
      .preference(
        key: GridFadeStateKey.self,
        value: GridFadeState(
          anchorID: fadeAnchorID, copyPresent: frozen != nil,
          activeOpacity: activeOpacity))
      .onChange(of: model.gridColumns) { _, _ in
        // A fixed grid (Files) does not follow the rung.
        guard columnCount == nil else { return }
        hover.clear()
        gridColumnsChanged()
      }
    )
  }

  /// The tracker's gate: no rung change in flight. It needs BOTH
  /// conditions: `frozen` / `restoring` for our own transition (the copy
  /// outlives the loop by its fade, the loop can outlive neither), and
  /// `displayedColumns == model.gridColumns` because the relaid-out grid's
  /// first preference flush measurably arrives BEFORE onChange fires —
  /// without the second condition the tracker swallows the new layout and
  /// overwrites the user's anchor on the very pass that betrays the change.
  /// The idle tracker: what a rung change will start from. Runs on every
  /// idle report, and once more when a change ends (`becameIdle`) — the
  /// last report of a change can arrive while it is still running, and
  /// without that the next change measurably started from the layout
  /// before this one (a stale anchor, offset and copy: 50–220 pt jumps on
  /// a second ⌘= with no scroll in between).
  private func trackIdle(_ frames: [GalleryModel.Row.ID: CGRect]) {
    idleLayout.frames = frames
    idleLayout.offset = scrollBox.offset
    if displayedColumns == nil { displayedColumns = columns }
    if let id = Self.anchorRowID(
      frames: frames, viewportHeight: viewportHeight)
    {
      lastAnchorID = id
      lastAnchorY = frames[id]?.midY
      let trusted = trustedFrames(frames)
      if let width = trusted.values.first?.width, width > 0,
        let maxHeight = trusted.values.map(\.height).max(), maxHeight > 0
      {
        // Max height, not modal: a grid row is as tall as its tallest
        // cell, so the pitch the arithmetic coarse must predict
        // follows the tallest cell — using the modal height measurably
        // under-jumps on mixed-aspect catalogs.
        lastTrustedWidth = width
        lastTrustedPitch = maxHeight + Self.rowSpacing
        captionExtra = maxHeight - width
      }
    }
  }

  /// A change has fully ended: re-read the idle state from the frames the
  /// new layout last reported.
  private func becameIdle() {
    guard isIdle else { return }
    trackIdle(newLayoutFrames())
  }

  private var isIdle: Bool {
    frozen == nil && !restoring
      && (displayedColumns == nil || displayedColumns == columns)
  }

  private func stickyHeaderOverlay(state: StickyMonthHeaderState) -> some View {
    StickyMonthHeader(state: state, model: model)
      .padding(.horizontal, Self.gridInset / 2)
      // The plate spans the visible content, not the scroll view's
      // frame: with legacy scrollers the two differ by the scroller's
      // width and the plate would run under it.
      .frame(width: gridWidth.map { $0 + Self.gridInset }, alignment: .top)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
  }

  /// What the user is looking at now, from the last idle reports.
  private func freezeVisibleLayout(columns: Int) -> FrozenGrid {
    let rows = Dictionary(
      model.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func visible(_ frame: CGRect) -> Bool { frame.maxY > 0 && frame.minY < viewportHeight }
    let cells = trustedFrames(idleLayout.frames).compactMap { id, frame in
      visible(frame) ? rows[id].map { FrozenGrid.Cell(row: $0, frame: frame) } : nil
    }
    var headers: [FrozenGrid.Header] = []
    var sticky: StickyMonthHeaderState?
    if model.showsRowSections {
      let state = StickyMonthHeaderState()
      for (month, frame) in idleLayout.headers {
        state.report(month: month, minY: frame.minY)
        if visible(frame) { headers.append(FrozenGrid.Header(month: month, frame: frame)) }
      }
      sticky = state
    }
    return FrozenGrid(columns: columns, cells: cells, headers: headers, sticky: sticky)
  }

  /// The offset that puts `id` back at the viewport y it had, by
  /// arithmetic: every row is `cellWidth + captionExtra` high (square
  /// cells), so the anchor's content y in either layout is a count of rows
  /// above it — grouped, each month wrapping on its own; the month headers
  /// above it are the same in both layouts and cancel, as does whatever
  /// sits above the grid, so the anchor stays at the y it had when the
  /// idle layout was reported at `idleLayout.offset`. Nil while a number is
  /// missing.
  private func arithmeticOffset(id: GalleryModel.Row.ID, previousColumns: Int) -> CGFloat? {
    guard let gridWidth, let captionExtra, let offset = idleLayout.offset,
      let old = rowsAbove(id, columns: previousColumns),
      let new = rowsAbove(id, columns: columns)
    else { return nil }
    func centre(_ rows: Int, _ columns: Int) -> CGFloat {
      let height =
        Self.cellWidth(columns: columns, paneWidth: gridWidth + Self.gridInset) + captionExtra
      return CGFloat(rows) * (height + Self.rowSpacing) + height / 2
    }
    return offset + centre(new, columns) - centre(old, previousColumns)
  }

  /// How many grid rows lie above `id`'s row at `columns` columns, every
  /// month's rows counted grouped.
  private func rowsAbove(_ id: GalleryModel.Row.ID, columns: Int) -> Int? {
    guard columns > 0 else { return nil }
    guard model.showsRowSections else {
      return model.rows.firstIndex { $0.id == id }.map { $0 / columns }
    }
    var above = 0
    for group in model.groupedRows {
      if let index = group.rows.firstIndex(where: { $0.id == id }) {
        return above + index / columns
      }
      above += (group.rows.count + columns - 1) / columns
    }
    return nil
  }

  /// The new grid is hidden while a rung change lands it (the copy up,
  /// the grid at opacity 0). A click then is dropped, not
  /// held for the grid: the user aimed at the copy, and the new layout puts
  /// a different cell (or a gap) under the same point, so passing it on
  /// once the grid shows would act on something they never saw there.
  /// Without the guard the copy takes no hits and a view at opacity 0
  /// takes none in SwiftUI, so the click falls through to the scroll
  /// view's blank tap and clears the selection.
  private var clicksIgnored: Bool { frozen != nil && activeOpacity == 0 }

  private func blankClicked() {
    guard !clicksIgnored else { return }
    model.clearSelection()
    gridFocused = true
  }

  private func cellClicked(_ row: GalleryModel.Row) {
    guard !clicksIgnored else { return }
    model.clickCell(row)
    gridFocused = true
  }

  private func moveSelection(_ move: GalleryModel.GridMove, extending: Bool) {
    guard let target = model.moveSelection(move, extending: extending) else { return }
    scrollIntoView(target.id, move: move)
  }

  /// Brings the row the keyboard reached fully into the viewport by the
  /// exact delta its measured frame gives. A row the lazy grid has
  /// not realised yet has no frame: Home / End go to the document's ends,
  /// an arrow steps half a viewport its way, and the next pass measures.
  private func scrollIntoView(
    _ id: GalleryModel.Row.ID, move: GalleryModel.GridMove, attempt: Int = 0
  ) {
    if let frame = rowFrames[id], isRealisedFrame(frame) {
      let margin = Self.gridInset / 2
      // Grouped, the pinned month header covers the viewport's top edge.
      let top = margin + (model.showsRowSections ? DesignMetrics.sectionHeader.height : 0)
      if frame.minY < top {
        scrollBox.scroll(by: frame.minY - top)
      } else if frame.maxY > viewportHeight - margin {
        scrollBox.scroll(by: min(frame.maxY - viewportHeight + margin, frame.minY - top))
      }
      return
    }
    guard attempt < 20 else { return }
    switch move {
    case .home: scrollBox.scroll(by: -(scrollBox.offset ?? 0))
    case .end: scrollBox.scroll(by: .greatestFiniteMagnitude)
    case .left, .up: scrollBox.scroll(by: -viewportHeight / 2)
    case .right, .down: scrollBox.scroll(by: viewportHeight / 2)
    }
    DispatchQueue.main.async {
      scrollIntoView(id, move: move, attempt: attempt + 1)
    }
  }

  /// A single cell click's selection action: `GalleryModel.cellClick`.
  static func selectionMode(
    for flags: NSEvent.ModifierFlags
  ) -> GalleryModel.SelectionMode {
    GalleryModel.cellClick(clickCount: 1, modifiers: flags).mode
  }

  /// The grid layout.
  ///
  /// Grouped, the layer is a `VStack` of months, each a
  /// header and its own fixed-column grid at the same `cellWidth` — so
  /// every month wraps on its own, which is why the restore does not jump
  /// by arithmetic in this mode (see `walkTowardAnchor`). Ungrouped, it is
  /// the one grid it always was.
  ///
  /// A plain `VStack`, not a `LazyVStack`. Lazy, a
  /// month nobody had built yet was sized from the months already built —
  /// a one-row month standing in for an eight-row one — so the document
  /// grew and shrank under the scroller as months got built. Each month's
  /// grid stays lazy, and with every row the same height (square cells)
  /// its own estimate is exact. The pinned header is `StickyMonthHeader`,
  /// an overlay fed by the in-flow headers' positions.
  private func gridLayer(columns: Int) -> some View {
    gridLayerContent(columns: columns)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
        // Not from `onAppear`: the copy of the view that closure captures
        // is the first body's, whose `@State` is not linked yet (measured:
        // it read `gridWidth` as nil). A copy taken after install reads
        // the live state.
        scrollBox.onDocumentResize = { applyWidthAnchor() }
        if width != gridWidth { gridWidth = width }
      }
  }

  @ViewBuilder
  private func gridLayerContent(columns: Int) -> some View {
    if model.showsRowSections {
      VStack(alignment: .leading, spacing: Self.rowSpacing) {
        ForEach(model.groupedRows, id: \.month) { group in
          GridSectionHeader(model: model, key: group.month, loaded: group.rows.count)
          .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.scrollSpace))
          } action: { frame in
            stickyHeader.report(month: group.month, minY: frame.minY)
            if isIdle { idleLayout.headers[group.month] = frame }
          }
          .onDisappear {
            stickyHeader.forget(month: group.month)
            idleLayout.headers[group.month] = nil
          }
          grid(columns: columns, rows: group.rows)
            .frame(
              height: exactGridHeight(columns: columns, rowCount: group.rows.count),
              alignment: .top)
        }
      }
    } else {
      // Ungrouped only: grouped, a fixed frame on each month's grid
      // measurably broke the rung-change restore (legacy scrollers, 40
      // months: 2 runs in 3 never found the row again), and the drift the
      // frame cures (the known grouped-0.6 intermittent) is left alone.
      grid(columns: columns, rows: model.rows)
        .frame(
          height: exactGridHeight(columns: columns, rowCount: model.rows.count),
          alignment: .top)
    }
  }

  /// The grid's exact height: every row is `cellWidth + captionExtra` high
  /// (square cells), so the sum needs no lazy estimate. The estimate for
  /// rows nobody had built came from rows measured at an earlier width (the
  /// pane is 15 pt narrower while the system draws legacy scrollers) and
  /// stayed stale until the last row was built — a measured 3.75 pt per row,
  /// 67 pt over 18 rows, that appeared near the bottom of the document.
  /// `nil` until both numbers are measured.
  private func exactGridHeight(columns: Int, rowCount: Int) -> CGFloat? {
    guard let gridWidth, let captionExtra, columns > 0, rowCount > 0 else { return nil }
    let cell = Self.cellWidth(columns: columns, paneWidth: gridWidth + Self.gridInset)
    guard cell > 0 else { return nil }
    let lines = (rowCount + columns - 1) / columns
    return CGFloat(lines) * (cell + captionExtra) + CGFloat(lines - 1) * Self.rowSpacing
  }

  @ViewBuilder
  private func grid(
    columns: Int, rows: [GalleryModel.Row]
  ) -> some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: Self.cellSpacing),
        count: columns),
      spacing: 0
    ) {
      ForEach(rows) { row in
        AssetGridCell(
          row: row,
          cache: model.thumbnails,
          overlays: model.gridOverlays,
          thumbnailSizing: model.gridThumbnailSizing,
          isSelected: model.selectedIDs.contains(row.id),
          quickLook: model.quickLook,
          tier: SourceTier(columns: columns),
          hover: hover,
          usageCaption: usageCaption)
          // One gesture: a double-click is the same tap with the event's
          // `clickCount` at 2, so a single click is never delayed.
          .onTapGesture { cellClicked(row) }
          .assetContextMenu(model: model, row: row)
          // A drag is not a tap, so starting one never selects.
          .onDrag { model.dragItemProvider(for: row) ?? NSItemProvider() }
          .id(row.id)
          .background {
            GeometryReader { geo in
              Color.clear.preference(
                key: RowFramesKey.self,
                value: [row.id: geo.frame(in: .named(Self.scrollSpace))])
            }
          }
          // The row gap is part of the row, not the grid's `spacing`: the
          // lazy grid's estimate for rows it has not built then counts the
          // gap too (measured: with `spacing`, rows built after a
          // wide width step sat a gap — or a whole row — off).
          .padding(.bottom, Self.rowSpacing)
      }
    }
  }

  /// The crossfade + anchor restore across a rung change.
  ///
  /// With the copy in the content and the relaid-out grid fading in at
  /// once, every step the restore took inside the 0.2 s fade moved both
  /// pictures — and grouped, the walk took five or six viewport steps over
  /// ~300 ms, landing after the fade had ended. With the document height
  /// changing one turn before the first corrective scroll, the knob went
  /// the wrong way first (measured, zoom in 0.51 → 0.31 → 0.53; zoom out
  /// 0.53 → 0.89 → 0.54).
  ///
  /// So, in this one turn: the visible region of the departing layout is
  /// frozen into a copy over the scroll view (viewport coordinates — no
  /// scroll moves it), the relaid-out grid is hidden, and the offset jumps
  /// straight to where arithmetic puts the anchor, in the same turn as the
  /// document's new height, so the knob takes one step. The restore loop
  /// then checks the landing on measured frames (and walks, hidden, if the
  /// arithmetic was short); once the anchor is measured in place the grid
  /// fades in over the copy. Reduce motion swaps without the fade.
  private func gridColumnsChanged() {
    let previousColumns = frozen?.columns ?? displayedColumns ?? columns
    // The anchor is captured HERE, once: this handler runs after the model
    // moved but the tracker's gate has kept `lastAnchorID` at the user's
    // row (measured). From now on the restore owns a frozen (id, y); the
    // tracker stays frozen (`restoring`) until the newest loop finishes.
    let anchorID = lastAnchorID
    let anchorY = lastAnchorY
    fadeAnchorID = anchorID
    restoreGeneration += 1
    let generation = restoreGeneration
    restoring = true
    displayedColumns = columns
    // A change while the copy is still up keeps the picture the user had.
    if frozen == nil { frozen = freezeVisibleLayout(columns: previousColumns) }
    withAnimation(nil) {
      activeOpacity = 0
      frozenOpacity = 1
    }
    scrollBox.onUserScroll = { userTookTheScroll() }
    guard let anchorID, let anchorY else {
      finishRestore(generation: generation)
      return
    }
    restoreTarget.id = anchorID
    restoreTarget.y = anchorY
    restoreTarget.corrections = 3
    restoreTarget.checkQueued = false
    restoreTarget.settledChecks = 0
    scrollBox.pendingJump = arithmeticOffset(id: anchorID, previousColumns: previousColumns)
    let jumped = scrollBox.pendingJump != nil
    DispatchQueue.main.async {
      // The document did not change size (or is not found): jump now.
      scrollBox.applyPendingJump()
      restoreAnchor(
        id: anchorID, targetY: anchorY, generation: generation,
        previousColumns: previousColumns, arithmeticCoarseDone: jumped,
        attempt: 0, budget: Self.restoreBudget, walkGap: nil, stable: 0)
    }
  }

  /// The arithmetic jump lands where the rows would be if the lazy grid knew
  /// every row's height; the anchor can still sit a few points off
  /// (measured: ±12 pt ungrouped — one row gap the lazy grid's estimate
  /// sometimes drops — and 2–4 pt grouped). A residual that size is
  /// corrected in the report that carries it, in the same turn: a turn
  /// later showed the knob a jump and then a step back. A larger one waits
  /// for the next turn's check (`settleCheck`), which every report queues:
  /// measured, a report inside the change put the anchor
  /// 276 pt from where the next turn's fresh report put it, and correcting
  /// on it left the grid 276 pt off.
  private func correctOnReport() {
    guard restoring, scrollBox.pendingJump == nil, restoreTarget.id != nil else { return }
    if let delta = anchorDelta(), abs(delta) > 0.5, abs(delta) <= Self.rowSpacing + 0.5,
      scrollBox.canScroll(by: delta), restoreTarget.corrections > 0
    {
      restoreTarget.corrections -= 1
      restoreTarget.settledChecks = 0
      scrollBox.scroll(by: delta)
    }
    guard !restoreTarget.checkQueued else { return }
    restoreTarget.checkQueued = true
    let generation = restoreGeneration
    DispatchQueue.main.async { settleCheck(generation: generation) }
  }

  /// How far the anchor is from where it was, nil while its new frame is
  /// not measured. A frame is read where the last report put it, moved by
  /// any scroll since: measured on the sweep, a scroll written inside the
  /// report was not always reported back, and a check that took the stale
  /// frame at its word sat on it until the loop gave up, 276 pt off.
  private func anchorDelta() -> CGFloat? {
    guard let id = restoreTarget.id, let frame = newLayoutFrames()[id],
      model.showsRowSections ? frame.height > 0 : isRealisedFrame(frame)
    else { return nil }
    let scrolled = (scrollBox.offset ?? 0) - (restoreTarget.reportOffset ?? scrollBox.offset ?? 0)
    return frame.midY - scrolled - restoreTarget.y
  }

  /// Shows the grid once two checks in a row find the anchor where it will
  /// stay (in place, or out of reach at the top or bottom of the document);
  /// corrects it when a check finds it off. Two checks, not one (measured
  /// on the sweep): the first report after the jump had the anchor in
  /// place and the next, at the same offset, 276 pt above it — its month
  /// still had rows above it laid out from estimates — and the grid had
  /// already been shown.
  private func settleCheck(generation: Int) {
    restoreTarget.checkQueued = false
    guard generation == restoreGeneration, restoring, frozen != nil, activeOpacity == 0,
      let delta = anchorDelta()
    else { return }
    if abs(delta) <= 0.5 || !scrollBox.canScroll(by: delta) {
      restoreTarget.settledChecks += 1
      if restoreTarget.settledChecks >= 2 {
        reveal(generation: generation)
        return
      }
    } else {
      restoreTarget.settledChecks = 0
      guard restoreTarget.corrections > 0 else { return }
      restoreTarget.corrections -= 1
      scrollBox.scroll(by: delta)
    }
    // The next report queues the next check; this one covers a turn that
    // brings none.
    restoreTarget.checkQueued = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
      settleCheck(generation: generation)
    }
  }

  /// The grid fades in over the frozen copy, which leaves once the fade is
  /// over. Runs once per change, on the first pass that measures the
  /// anchor in place (or when the loop gives up).
  private func reveal(generation: Int) {
    guard generation == restoreGeneration, frozen != nil, activeOpacity == 0 else { return }
    if reducesMotion ?? systemReducesMotion {
      withAnimation(nil) {
        activeOpacity = 1
        frozen = nil
      }
      scrollBox.onUserScroll = nil
      becameIdle()
      return
    }
    withAnimation(.easeInOut(duration: Self.fadeDuration)) {
      activeOpacity = 1
      frozenOpacity = 0
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration + 0.05) {
      guard generation == restoreGeneration else { return }
      withAnimation(nil) { frozen = nil }
      scrollBox.onUserScroll = nil
      becameIdle()
    }
  }

  /// Moves the hosted scroll view by the exact delta that puts the
  /// remembered anchor back at the viewport y the user saw it at.
  ///
  /// Frames are only trusted when they are plausibly realised: the lazy
  /// container also reports ESTIMATED frames for rows near (or beyond) an
  /// out-of-range offset, in content-absolute coordinates — measured at a
  /// deep park: the anchor reported 618 pt past the viewport bottom, a
  /// blind delta scrolled past the content end, realisation emptied, and
  /// the layout clamped back 974 pt. A realised row's midY always lies
  /// within one row height of the viewport; anything else is an estimate.
  ///
  /// When the anchor is not realisable from the current offset (deep
  /// scroll, rung change), the loop jumps coarsely and the following
  /// measured pass lands exactly: measured-coarse from the new layout's
  /// own frames when it has any, else arithmetic-coarse on zero new data
  /// (old trusted width → pane → new `cellWidth`; pitch scales with width).
  /// Both coarse jumps place the anchor at `floor(index / columns) * pitch`,
  /// which only the ungrouped grid obeys; grouped, the loop walks instead
  /// (`walkTowardAnchor`).
  private func restoreAnchor(
    id: GalleryModel.Row.ID,
    targetY: CGFloat,
    generation: Int,
    previousColumns: Int,
    arithmeticCoarseDone: Bool,
    attempt: Int,
    budget: Int,
    walkGap: Int?,
    stable: Int
  ) {
    guard generation == restoreGeneration else { return }
    guard budget > 0 else {
      finishRestore(generation: generation)
      return
    }

    // Only frames from the NEW layout are trusted. Right after a rung
    // change the dictionary measurably mixes both layouts' rows (retained
    // row views reporting old widths — 28 entries with the old width
    // dominant at n=2→3), so the new layout's width is identified as the
    // modal width and everything else is discarded before any arithmetic
    // runs.
    let trusted = newLayoutFrames()
    // Grouped, the months stack in a plain VStack, so a live row's
    // frame is exact wherever it lies — no lazy estimate to distrust — and
    // the measured delta can land it from offscreen too.
    if let frame = trusted[id],
      model.showsRowSections ? frame.height > 0 : isRealisedFrame(frame)
    {
      let delta = frame.midY - targetY
      if abs(delta) <= 0.5 {
        // The anchor is in place: the grid may show (once per change).
        reveal(generation: generation)
        // Two stable passes ~120 ms apart: the lazy layout corrects its
        // estimates for a while after a jump, and a single zero reading
        // measurably drifted ~16 pt afterwards.
        if stable >= 1 {
          finishRestore(generation: generation)
          return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
          restoreAnchor(
            id: id, targetY: targetY, generation: generation,
            previousColumns: previousColumns,
            arithmeticCoarseDone: arithmeticCoarseDone,
            attempt: attempt + 1, budget: budget - 1,
            walkGap: walkGap, stable: stable + 1)
        }
        return
      }
      // While corrections remain, landing is the frame report's job
      // (`correctOnReport`): this pass can run before the first report
      // after the jump and read frames laid out at the old offset —
      // measured, it scrolled back 316 pt (6→5) or to the old offset
      // (5→4), and the report's correction then scrolled forward again.
      if restoreTarget.corrections > 0, restoreTarget.id == id {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
          restoreAnchor(
            id: id, targetY: targetY, generation: generation,
            previousColumns: previousColumns,
            arithmeticCoarseDone: arithmeticCoarseDone,
            attempt: attempt + 1, budget: budget - 1, walkGap: walkGap, stable: 0)
        }
        return
      }
      guard scrollBox.canScroll(by: delta) else {
        // Out of reach at the top or bottom: this is where it lands.
        finishRestore(generation: generation)
        return
      }
      scrollBox.scroll(by: delta)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
        restoreAnchor(
          id: id, targetY: targetY, generation: generation,
          previousColumns: previousColumns,
          arithmeticCoarseDone: arithmeticCoarseDone,
          attempt: attempt + 1, budget: budget - 1, walkGap: walkGap, stable: 0)
      }
      return
    }

    var arithmeticDone = arithmeticCoarseDone
    // A walk step that brought the realised band closer to the anchor is
    // progress, not a retry: it spends no budget (measured under
    // load: 3→2 columns, the band crept from index 44 to 75 toward 79 one
    // viewport per pass and the twelfth attempt stopped it short). The gap
    // is a row count that only shrinks while this holds, so the walk still
    // ends; a step that does not shrink it spends as before.
    var gap = walkGap
    var spent = 1
    if model.showsRowSections {
      if attempt >= 1 {
        gap = walkTowardAnchor(id: id, trusted: trusted, attempt: attempt)
        if let gap, let walkGap, gap < walkGap { spent = 0 }
      }
    } else if attempt >= 2, trusted.count >= 3,
      let index = model.rows.firstIndex(where: { $0.id == id }),
      let sample = trusted.values.first, sample.height > 0,
      let offset = scrollBox.offset
    {
      let pitch = sample.height + Self.rowSpacing
      let row = floor(CGFloat(index) / CGFloat(columns))
      let anchorContentY = row * pitch + sample.height / 2
      scrollBox.scroll(by: anchorContentY - targetY - offset)
    } else if !arithmeticCoarseDone, attempt >= 1,
      let index = model.rows.firstIndex(where: { $0.id == id }),
      let oldWidth = lastTrustedWidth, let oldPitch = lastTrustedPitch,
      oldWidth > 0, let offset = scrollBox.offset
    {
      // Usable while the dictionary is empty or garbage — measured: the
      // realisation reports nothing for ~300 ms on content-shrinking
      // changes, and without this the restore lands visibly after the
      // fade. One shot: after it the anchor is near the viewport, the
      // measured passes take over.
      let pane = oldWidth * CGFloat(previousColumns) + Self.gridInset
        + CGFloat(previousColumns - 1) * Self.cellSpacing
      let newWidth = Self.cellWidth(
        columns: columns, paneWidth: pane)
      let pitch = oldPitch * newWidth / oldWidth
      let row = floor(CGFloat(index) / CGFloat(columns))
      let anchorContentY = row * pitch + (pitch - Self.rowSpacing) / 2
      scrollBox.scroll(by: anchorContentY - targetY - offset)
      arithmeticDone = true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
      restoreAnchor(
        id: id, targetY: targetY, generation: generation,
        previousColumns: previousColumns,
        arithmeticCoarseDone: arithmeticDone,
        attempt: attempt + 1, budget: budget - spent, walkGap: gap, stable: 0)
    }
  }

  /// The grouped grid's coarse step. Only turning the arithmetic coarse off
  /// here changes nothing (measured) — the measured-coarse above places the anchor with the same
  /// `floor(index / columns) * pitch`, and in a `LazyVStack` of month
  /// sections that is wrong twice over: each section wraps on its own and
  /// has a header, and the sections above the viewport that have not been
  /// laid out are only height estimates, so no formula can know where the
  /// anchor sits in content coordinates. Offscreen, 120 assets over 12
  /// months at 900×700, the 2→3 rung jumped 4870→5878 and the anchor never
  /// realised again (no adaptation and both coarse jumps off all
  /// lost it). What is measurable is order: the anchor's index against the
  /// indices of the rows that are realised says which way it lies, so the
  /// view moves one viewport that way and the next pass measures again; a
  /// viewport-sized step cannot skip past it, because the realised band is
  /// at least that tall. Once it realises, the measured delta above lands
  /// it exactly.
  ///
  /// The anchor can also lie INSIDE the realised band and still not be
  /// realised (seen with 40 months × 3 assets,
  /// 3→2): its section's grid had laid out the row's two neighbours at
  /// the new width, the anchor itself kept its three-column frame at a y it
  /// no longer had, and no further layout pass came for over a second, so
  /// neither this walk nor the delta ever moved. A 1 pt scroll, alternating
  /// in direction, is a layout pass: the next report realises the anchor
  /// and the delta takes over.
  ///
  /// Returns how many rows lie between the anchor and the realised band
  /// (0 inside it), nil when there was nothing to measure.
  @discardableResult
  private func walkTowardAnchor(
    id: GalleryModel.Row.ID, trusted: [GalleryModel.Row.ID: CGRect],
    attempt: Int
  ) -> Int? {
    let order = Dictionary(
      model.rows.enumerated().map { ($1.id, $0) },
      uniquingKeysWith: { first, _ in first })
    guard let anchorIndex = order[id] else { return nil }
    let realised = trusted.filter { isRealisedFrame($0.value) }.keys
      .compactMap { order[$0] }
    guard let first = realised.min(), let last = realised.max() else { return nil }
    if anchorIndex < first {
      scrollBox.scroll(by: -viewportHeight)
      return first - anchorIndex
    } else if anchorIndex > last {
      scrollBox.scroll(by: viewportHeight)
      return anchorIndex - last
    } else {
      scrollBox.scroll(by: attempt.isMultiple(of: 2) ? 1 : -1)
      return 0
    }
  }

  /// The user scrolled while a rung change was in flight (the box has already dropped its hold and pending jump): the scroll is
  /// theirs. Every loop and check of this change stops (a new generation),
  /// and the new grid shows at once — no fade, no copy left half-faded —
  /// wherever the user's scroll takes it. If the fade had already begun it
  /// simply ends now.
  private func userTookTheScroll() {
    restoreGeneration += 1
    restoring = false
    withAnimation(nil) {
      activeOpacity = 1
      frozenOpacity = 1
      frozen = nil
    }
    becameIdle()
    settledRestores += 1
  }

  /// Every exit from the restore loop goes through here. The clamp runs
  /// twice: once now, and once after the lazy container has had a beat to
  /// correct the document height it was still revising while the loop ran —
  /// an offset that was in range when written can be stranded by the
  /// correction, which is the blank-band defect all over again.
  private func finishRestore(generation: Int) {
    guard generation == restoreGeneration else { return }
    reveal(generation: generation)
    restoring = false
    scrollBox.holdOffset = nil
    scrollBox.clampIntoRange()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      guard generation == restoreGeneration else { return }
      scrollBox.clampIntoRange()
      becameIdle()
      settledRestores += 1
    }
  }

  /// The subset of reported frames that belong to the layout now on screen:
  /// the entries whose width matches the dictionary's modal width. All rows
  /// of one layout share a width; a rung transition briefly leaves stale
  /// rows of the old width in the merge.
  private func trustedFrames(
    _ frames: [GalleryModel.Row.ID: CGRect]
  ) -> [GalleryModel.Row.ID: CGRect] {
    guard !frames.isEmpty else { return frames }
    var histogram: [Int: Int] = [:]
    for frame in frames.values {
      histogram[Int(frame.width.rounded()), default: 0] += 1
    }
    guard let modal = histogram.max(by: { $0.value < $1.value })?.key else {
      return frames
    }
    return frames.filter {
      Int($0.value.width.rounded()) == modal
    }
  }

  /// The reported frames that belong to the layout being restored: the
  /// entries at the width `cellWidth` gives the current column count. The
  /// modal width (`trustedFrames`) is not enough here (measured): right
  /// after the jump the dictionary held ten rows at the old width and
  /// seven at the new, so the modal pick was the old layout and the loop
  /// scrolled 1787 pt off the anchor's stale frame.
  private func newLayoutFrames() -> [GalleryModel.Row.ID: CGRect] {
    guard let gridWidth else { return trustedFrames(rowFrames) }
    let width = Self.cellWidth(columns: columns, paneWidth: gridWidth + Self.gridInset)
    return rowFrames.filter { abs($0.value.width - width) <= 0.5 }
  }

  /// A frame the lazy container actually laid out (not an estimate): a
  /// realised row's centre is within one row height of the viewport.
  private func isRealisedFrame(_ frame: CGRect) -> Bool {
    frame.height > 0 && frame.midY > -frame.height
      && frame.midY < viewportHeight + frame.height
  }

  /// The pinch path: `MagnifyGesture` feeds the zoom accumulator.
  /// `simultaneousGesture` because trackpad pinch and
  /// two-finger scroll are distinct event streams; the scroll never has to
  /// win arbitration against zoom.
  private func withPinchZoom<V: View>(_ content: V) -> some View {
    content.simultaneousGesture(
      MagnifyGesture()
        .onChanged { value in pinchUpdate(scale: value.magnification) }
        .onEnded { _ in pinchEnded() }
    )
  }

  private func pinchUpdate(scale: CGFloat) {
    defer { pinchPreviousScale = scale }
    guard let previous = pinchPreviousScale else { return }
    var rungs = pinchAccumulator.advance(by: scale - previous)
    while rungs > 0 {
      model.zoomIn()
      rungs -= 1
    }
    while rungs < 0 {
      model.zoomOut()
      rungs += 1
    }
  }

  private func pinchEnded() {
    pinchPreviousScale = nil
    pinchAccumulator.reset()
  }
}

