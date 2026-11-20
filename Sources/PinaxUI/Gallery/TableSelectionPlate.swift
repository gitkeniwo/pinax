import AppKit
import SwiftUI

/// The asset table's selected row plate (accentFill, corner 7).
/// SwiftUI's `Table` has no row-background API, so this background view
/// finds the table it belongs to, turns off AppKit's own highlight, and puts
/// a rounded plate behind the selected rows' cells. It never changes the
/// selection: clicks, keys and ⌘C stay the table's.
struct AssetTableSelectionPlate: NSViewRepresentable {
  var selectedIndexes: IndexSet = []
  /// Off on the Usage table, whose disclosure rows do not map one
  /// to one onto the model's; its system selection stays as it was.
  var enabled = true

  func makeNSView(context: Context) -> TablePlateHost {
    let view = TablePlateHost()
    view.selectedIndexes = selectedIndexes
    view.enabled = enabled
    return view
  }

  func updateNSView(_ view: TablePlateHost, context: Context) {
    view.selectedIndexes = selectedIndexes
    view.enabled = enabled
    view.schedule()
    view.applyNow()
  }
}

final class TablePlateHost: NSView {
  var selectedIndexes = IndexSet()
  var enabled = true
  private weak var table: NSTableView?
  private var originalSelectionStyle: NSTableView.SelectionHighlightStyle?
  private var observers: [NSObjectProtocol] = []
  private var settleTimer: Timer?
  private var settleTicks = 0

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      detach()
    } else {
      attach()
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    schedule()
  }

  deinit { detach() }

  private func attach() {
    guard let root = window?.contentView, let found = Self.findTable(in: root) else { return }
    guard found !== table else {
      schedule()
      return
    }
    detach()
    table = found
    originalSelectionStyle = found.selectionHighlightStyle
    if let clip = found.enclosingScrollView?.contentView {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in self?.schedule() })
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSTableView.selectionDidChangeNotification, object: found, queue: .main
      ) { [weak self] _ in self?.schedule() })
    apply()
    settleSoon()
  }

  private func detach() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    settleTimer?.invalidate()
    settleTimer = nil
    table = nil
  }

  /// The table builds its row views after SwiftUI's update; a handful of
  /// short runloop turns catches them without polling for the view's life.
  private func settleSoon() {
    settleTimer?.invalidate()
    settleTicks = 6
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      self.apply()
      self.settleTicks -= 1
      if self.settleTicks <= 0 { timer.invalidate() }
    }
    settleTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  /// Layout and SwiftUI both settle a runloop turn later than the call that
  /// asked, so re-apply after they do.
  func schedule() {
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  func applyNow() { apply() }

  private func apply() {
    guard let table else { return }
    table.selectionHighlightStyle = .none
    let rows = table.rows(in: table.visibleRect)
    guard rows.length > 0 else { return }
    for index in rows.lowerBound..<rows.upperBound {
      guard let row = table.rowView(atRow: index, makeIfNecessary: false) else { continue }
      row.selectionHighlightStyle = .none
      row.wantsLayer = true
      row.backgroundColor = .clear
      row.layer?.backgroundColor = NSColor.clear.cgColor
      row.layer?.cornerRadius = 0
      row.subviews.filter { $0 is PinaxRowPlate }.forEach { $0.removeFromSuperview() }
      guard selectedIndexes.contains(index) else { continue }
      let plate = PinaxRowPlate()
      plate.frame = row.bounds.insetBy(
        dx: DesignMetrics.assetTable.selectionInset,
        dy: DesignMetrics.assetTable.selectionVerticalInset)
      plate.autoresizingMask = [.width, .height]
      row.addSubview(plate, positioned: .below, relativeTo: nil)
    }
  }

  private static func findTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView, table.tableColumns.count > 1 { return table }
    for subview in view.subviews {
      if let found = findTable(in: subview) { return found }
    }
    return nil
  }
}

/// The plate itself: accentFill, corner 7, never a hit target.
final class PinaxRowPlate: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = DesignMetrics.assetTable.selectedRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    updateColor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    updateColor()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColor()
  }

  private func updateColor() {
    var resolved = NSColor.clear
    effectiveAppearance.performAsCurrentDrawingAppearance {
      resolved = PinaxPalette.nsColor(.accentFill)
    }
    layer?.backgroundColor = resolved.cgColor
  }
}

/// The Externals list's AppKit side: `List` draws its rows in an
/// `NSTableView` whose own blue highlight shows around the accentFill plate
/// the rows already draw, and whose inset style pads every row another few
/// points. This background view finds that table, the nearest one around
/// it, and turns both off. Selection, keys and clicks stay the list's.
struct ListHighlightOff: NSViewRepresentable {
  /// Changes with the selection, so the update re-applies after SwiftUI's.
  var selectionCount = 0

  func makeNSView(context: Context) -> ListHighlightHost { ListHighlightHost() }

  func updateNSView(_ view: ListHighlightHost, context: Context) {
    view.apply()
    DispatchQueue.main.async { view.apply() }
  }
}

final class ListHighlightHost: NSView {
  private weak var table: NSTableView?
  private var observer: NSObjectProtocol?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    apply()
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    apply()
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  deinit { observer.map(NotificationCenter.default.removeObserver) }

  func apply() {
    if table == nil, let found = nearestTable() {
      table = found
      // The table's own resize, in the same layout pass and before it
      // draws: the column never shows at its old width (no flash on the
      // Grid → Table switch).
      found.postsFrameChangedNotifications = true
      observer = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: found, queue: nil
      ) { [weak self] _ in MainActor.assumeIsolated { self?.apply() } }
    }
    guard let table else { return }
    if table.style != .plain { table.style = .plain }
    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
    if table.intercellSpacing != .zero { table.intercellSpacing = .zero }
    // The one column spans the table, so the rows' trailing columns line
    // up under the header's.
    if table.columnAutoresizingStyle != .lastColumnOnlyAutoresizingStyle {
      table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }
    if let column = table.tableColumns.last, abs(NSMaxX(table.rect(ofColumn: table.numberOfColumns - 1)) - table.bounds.width) > 0.5 {
      column.maxWidth = .greatestFiniteMagnitude
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        table.sizeLastColumnToFit()
      }
    }
    let rows = table.rows(in: table.visibleRect)
    guard rows.length > 0 else { return }
    for index in rows.lowerBound..<rows.upperBound {
      table.rowView(atRow: index, makeIfNecessary: false)?.selectionHighlightStyle = .none
    }
  }

  /// The table whose scroll view covers this view's middle (this view is
  /// the list's background, so it has the list's frame), searched from the
  /// closest ancestor out: never the sidebar's outline beside it.
  private func nearestTable() -> NSTableView? {
    guard window != nil else { return nil }
    let middle = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
    var ancestor = superview
    while let view = ancestor {
      var tables: [NSTableView] = []
      Self.collectTables(in: view, into: &tables)
      if let found = tables.first(where: { table in
        let frame = table.enclosingScrollView ?? table
        return frame.convert(frame.bounds, to: nil).contains(middle)
      }) {
        return found
      }
      ancestor = view.superview
    }
    return nil
  }

  private static func collectTables(in view: NSView, into tables: inout [NSTableView]) {
    if let table = view as? NSTableView {
      tables.append(table)
      return
    }
    for subview in view.subviews { collectTables(in: subview, into: &tables) }
  }
}
