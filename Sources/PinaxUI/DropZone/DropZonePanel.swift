import AppKit
import Combine
import SwiftUI

/// The floating, never-focus-stealing surface for both the drop target and
/// the results list (one window, not two). An `NSPanel` rather
/// than a scene: `.nonactivatingPanel` keeps focus with the app the user is
/// dragging out of, which a SwiftUI `Window` cannot promise.
final class DropZonePanel: NSPanel {
  static let defaultSize = DropZoneSize.defaultSize

  /// False while unattended: the panel must not take key focus from the app
  /// the user is dragging out of. On only while a review waits, so Esc and
  /// Return reach its Cancel and Upload.
  var allowsBecomingKey = false

  init(contentView: NSView, size: CGSize) {
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      // Resizable: the edge and the corner grip change the size
      // inside Settings' ranges; the size left at is written back.
      styleMask: [.nonactivatingPanel, .borderless, .resizable],
      backing: .buffered,
      defer: false
    )
    self.contentView = contentView
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isFloatingPanel = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    contentMinSize = CGSize(
      width: DropZoneSize.widthRange.lowerBound, height: DropZoneSize.heightRange.lowerBound)
    contentMaxSize = CGSize(
      width: DropZoneSize.widthRange.upperBound, height: DropZoneSize.heightRange.upperBound)
  }

  /// The zone must never take key focus while unattended, even when clicked.
  override var canBecomeKey: Bool { allowsBecomingKey }
  override var canBecomeMain: Bool { false }
}

/// Owns the panel and the drag monitor and keeps the panel's visibility in
/// step with the model. Pure AppKit glue; every decision lives in `DropZoneModel`
/// (visibility) and `PreferencesStore` + `DropZonePlacement` (where the panel
/// sits). Placement is always *recomputed* from live screen geometry — never
/// nudged incrementally — so a screen change re-places the panel instead of
/// stranding it off-screen.
@MainActor
public final class DropZoneController: ObservableObject {
  public let model: DropZoneModel
  private let preferences: PreferencesStore
  private let monitor: DragMonitor
  private var panel: DropZonePanel?
  /// The view-side state of the one panel: its drop flag, hover preview and
  /// the look the preferences push (layout).
  let viewState = DropZoneViewState()
  private var modelCancellable: AnyCancellable?
  private var preferencesCancellable: AnyCancellable?
  private var screenObserver: (any NSObjectProtocol)?
  private var reduceMotionObserver: (any NSObjectProtocol)?
  private var resizeObserver: (any NSObjectProtocol)?
  /// The display the visible panel was last placed on. With "follow cursor"
  /// on, a drag that crosses between displays re-places the zone onto the
  /// display the cursor is now on.
  private var placedScreenID: CGDirectDisplayID?
  /// A review was waiting on screen at the last look: the panel took key
  /// once, as it began.
  private var wasReviewing = false

  /// Test seam: how many times placement was recomputed from live screen
  /// geometry. The property is that the panel re-places itself after a
  /// screen change — this counts the re-placement itself, which no assertion
  /// on "the corner setting was read" can stand in for.
  public private(set) var placementRecomputations = 0
  /// Test seam: each show and hide of the window, and whether it animated.
  private(set) var windowChanges: [DropZonePanelMotion.WindowChange] = []
  /// Fading out: still on screen until the fade ends. A show meanwhile
  /// bumps the generation so the fade's end leaves the panel up.
  private var isHiding = false
  /// Sliding in: the frame is on its way to where placement put it.
  /// Test seam too — a frame read before this clears is mid-slide.
  public private(set) var isAppearing = false
  private var hideGeneration = 0

  public init(model: DropZoneModel, preferences: PreferencesStore) {
    self.model = model
    self.preferences = preferences
    self.monitor = DragMonitor(
      onSample: { [weak model] urls, modifiers in
        model?.dragDidChange(fileURLs: urls, modifiers: modifiers)
      },
      onDragEnded: { [weak model] in model?.dragDidEnd() }
    )
    modelCancellable = model.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refreshWindowVisibility() }
    preferencesCancellable = preferences.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.applyLook()
        self?.replaceIfVisible()
      }
    // Undock, dock, resolution change: re-place whatever is on screen now.
    // The panel never survives this on a cached origin.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.replaceIfVisible() }
    }
    // Reduce Motion stills the upload arc and the fresh glow.
    reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.viewState.reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      }
    }
  }

  deinit {
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
    if let reduceMotionObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
    }
    if let resizeObserver {
      NotificationCenter.default.removeObserver(resizeObserver)
    }
  }

  public func setEnabled(_ enabled: Bool) {
    if enabled {
      monitor.start()
    } else {
      monitor.stop()
      model.disable()
      refreshWindowVisibility()
    }
  }

  /// The panel's current frame, nil while it has never been shown. Read-only
  /// exposure for tests; placement itself stays private.
  public var panelFrame: NSRect? { panel?.frame }
  /// The panel's content view, nil while it has never been shown. Read-only
  /// exposure for tests: its tracking area is the pointer wiring.
  public var panelContentView: NSView? { panel?.contentView }
  /// The panel itself, nil while it has never been shown. Read-only
  /// exposure for tests (its appearance, its frame).
  var panelWindow: NSPanel? { panel }

  private func refreshWindowVisibility() {
    if model.isWindowVisible {
      let panel = ensurePanel()
      let screen = targetScreen()
      let screenID = screen?.displayID
      let crossedScreens =
        preferences.dropZoneFollowsCursor && screenID != nil && screenID != placedScreenID
      if isHiding {
        // Shown again while fading out: back to full, where it is.
        hideGeneration += 1
        isHiding = false
        animateAlpha(of: panel, to: 1)
      }
      if !panel.isVisible || crossedScreens {
        position(panel, on: screen)
        if !panel.isVisible {
          appear(panel, corner: preferences.dropZoneCorner)
        }
      }
      let reviewing = model.isReviewing
      panel.allowsBecomingKey = reviewing
      if reviewing, !wasReviewing { panel.makeKey() }
      wasReviewing = reviewing
    } else {
      if let panel, panel.isVisible, !isHiding { disappear(panel) }
      panel?.allowsBecomingKey = false
      wasReviewing = false
      placedScreenID = nil
    }
  }

  /// Fades the panel in while it slides out of its corner into place;
  /// at once under Reduce Motion.
  private func appear(_ panel: DropZonePanel, corner: DropZoneCorner) {
    let reduces = viewState.reducesMotion
    guard !reduces else {
      panel.alphaValue = 1
      panel.orderFrontRegardless()
      windowChanges.append(.appeared(animated: false))
      return
    }
    let target = panel.frame.origin
    let offset = DropZonePanelMotion.appearOffset(corner: corner)
    panel.alphaValue = 0
    panel.setFrameOrigin(NSPoint(x: target.x + offset.dx, y: target.y + offset.dy))
    panel.orderFrontRegardless()
    isAppearing = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = DropZonePanelMotion.appearDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
      panel.animator().setFrameOrigin(target)
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated { self?.isAppearing = false }
    }
    windowChanges.append(.appeared(animated: true))
  }

  /// Fades the panel out, then orders it out — unless it was asked back
  /// meanwhile; at once under Reduce Motion.
  private func disappear(_ panel: DropZonePanel) {
    guard !viewState.reducesMotion else {
      panel.orderOut(nil)
      panel.alphaValue = 1
      windowChanges.append(.disappeared(animated: false))
      return
    }
    isHiding = true
    hideGeneration += 1
    let generation = hideGeneration
    NSAnimationContext.runAnimationGroup { context in
      context.duration = DropZonePanelMotion.disappearDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self, weak panel] in
      MainActor.assumeIsolated {
        guard let self, let panel, self.hideGeneration == generation else { return }
        self.isHiding = false
        panel.orderOut(nil)
        panel.alphaValue = 1
      }
    }
    windowChanges.append(.disappeared(animated: true))
  }

  private func animateAlpha(of panel: DropZonePanel, to alpha: CGFloat) {
    guard !viewState.reducesMotion else {
      panel.alphaValue = alpha
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = DropZonePanelMotion.appearDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = alpha
    }
  }

  /// Re-runs placement unconditionally for an already-visible panel — the
  /// reaction to a preference change (new corner) or a screen-parameters
  /// change (undock, resolution, Dock moved). Incremental "nudging" is
  /// deliberately absent: a panel stranded off-screen by a removed display
  /// is fixed by the same recomputation that honors a new corner.
  private func replaceIfVisible() {
    guard let panel, panel.isVisible else { return }
    position(panel, on: targetScreen())
  }

  private func ensurePanel() -> DropZonePanel {
    if let panel { return panel }
    let size = preferences.dropZoneSize
    let hosting = NSHostingView(rootView: DropZoneView(model: model, state: viewState))
    // The panel sets the size; the root fills whatever it is.
    hosting.sizingOptions = []
    let panel = DropZonePanel(
      contentView: PointerTrackingView(
        content: hosting, size: size,
        onEnter: { [weak model] in model?.pointerDidEnter() },
        onExit: { [weak model] in model?.pointerDidExit() },
        onResizeEnd: { [weak self] in self?.panelDidEndResize() }),
      size: size)
    self.panel = panel
    // The edge (a live resize) and the corner grip end in the same place.
    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.panelDidEndResize() }
    }
    applyLook()
    return panel
  }

  /// The size the user left the panel at, clamped, becomes Settings ▸ Size;
  /// the panel then takes the clamped size and is placed at its corner again.
  private func panelDidEndResize() {
    guard let panel else { return }
    preferences.setDropZoneSize(panel.contentLayoutRect.size)
    applyLook()
    replaceIfVisible()
  }

  /// Settings ▸ Drop Zone ▸ Look and Size: Light and Dark force the
  /// panel's appearance — the behind-window material and the SwiftUI
  /// palette both follow it — and Match System leaves it to the system.
  /// Only this panel's appearance is touched, never the app's.
  private func applyLook() {
    viewState.layout = preferences.dropZoneLayout
    panel?.appearance = preferences.dropZoneAppearance.nsAppearance
    // Settings ▸ Size; a live resize in progress is left alone.
    let size = preferences.dropZoneSize
    if let panel, !panel.inLiveResize, panel.contentLayoutRect.size != size {
      panel.setContentSize(size)
    }
    if viewState.panelSize != size { viewState.panelSize = size }
  }

  private func position(_ panel: DropZonePanel, on screen: NSScreen?) {
    guard let visibleFrame = screen?.visibleFrame else { return }
    let origin = DropZonePlacement.origin(
      corner: preferences.dropZoneCorner,
      panelSize: panel.frame.size,
      visibleFrame: visibleFrame)
    if isAppearing {
      // Through the animator, so the slide still under way cannot carry
      // the panel back to where it was headed.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        panel.animator().setFrameOrigin(origin)
      }
    } else {
      panel.setFrameOrigin(origin)
    }
    placedScreenID = screen?.displayID
    placementRecomputations += 1
  }

  /// "Follow cursor across screens" on: the display under the mouse (that is
  /// where a live drag is). Off: the main display.
  private func targetScreen() -> NSScreen? {
    if preferences.dropZoneFollowsCursor {
      let location = NSEvent.mouseLocation
      if let containing = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) {
        return containing
      }
    }
    return NSScreen.main
  }
}

/// Hosts the zone and reports the pointer entering and leaving the panel —
/// the countdown pauses while it is inside. `.activeAlways`
/// because the panel never becomes key.
private final class PointerTrackingView: NSView {
  private let onEnter: @MainActor () -> Void
  private let onExit: @MainActor () -> Void

  init(
    content: NSView, size: CGSize, onEnter: @escaping @MainActor () -> Void,
    onExit: @escaping @MainActor () -> Void, onResizeEnd: @escaping @MainActor () -> Void
  ) {
    self.onEnter = onEnter
    self.onExit = onExit
    super.init(frame: NSRect(origin: .zero, size: size))
    // The lowest layer blends with what is behind the panel.
    if GlassSupport.panelUsesBehindWindowMaterial {
      let glass = GlassSupport.makeBehindWindowView(
        cornerRadius: DesignMetrics.dropZone.panelRadius)
      glass.frame = bounds
      glass.autoresizingMask = [.width, .height]
      addSubview(glass)
    }
    content.frame = bounds
    content.autoresizingMask = [.width, .height]
    addSubview(content)
    // The bottom-right grip, over the content.
    let gripSize = DesignMetrics.dropZone.gripSize
    let grip = ResizeGripView(onEnd: onResizeEnd)
    grip.frame = NSRect(x: bounds.maxX - gripSize, y: 0, width: gripSize, height: gripSize)
    grip.autoresizingMask = [.minXMargin, .maxYMargin]
    addSubview(grip)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func mouseEntered(with event: NSEvent) { onEnter() }
  override func mouseExited(with event: NSEvent) { onExit() }
}

/// The panel's bottom-right corner grip: dragging it resizes the
/// panel with its top-left corner fixed, inside the panel's min and max
/// size; letting go ends the resize like a live resize from the edge does.
private final class ResizeGripView: NSView {
  private let onEnd: @MainActor () -> Void
  private var start: (frame: NSRect, mouse: NSPoint)?

  init(onEnd: @escaping @MainActor () -> Void) {
    self.onEnd = onEnd
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var mouseDownCanMoveWindow: Bool { false }

  override func resetCursorRects() {
    if #available(macOS 15.0, *) {
      addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
    } else {
      addCursorRect(bounds, cursor: .crosshair)
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    start = (window.frame, NSEvent.mouseLocation)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let window, let start else { return }
    let mouse = NSEvent.mouseLocation
    let content = DropZoneSize.clamped(
      CGSize(
        width: start.frame.width + mouse.x - start.mouse.x,
        height: start.frame.height - (mouse.y - start.mouse.y)))
    window.setFrame(
      NSRect(
        x: start.frame.minX, y: start.frame.maxY - content.height,
        width: content.width, height: content.height),
      display: true)
  }

  override func mouseUp(with event: NSEvent) {
    guard start != nil else { return }
    start = nil
    onEnd()
  }

  /// Three short diagonals, like a window's grow box, in the secondary
  /// label colour of the panel's appearance.
  override func draw(_ dirtyRect: NSRect) {
    let inset = DesignMetrics.dropZone.gripInset
    let reach = bounds.width - 2 * inset
    let path = NSBezierPath()
    for step in 1...3 {
      let length = reach * CGFloat(step) / 3
      path.move(to: NSPoint(x: bounds.maxX - inset, y: inset + length))
      path.line(to: NSPoint(x: bounds.maxX - inset - length, y: inset))
    }
    path.lineWidth = DesignMetrics.dropZone.gripLine
    path.lineCapStyle = .round
    NSColor.tertiaryLabelColor.setStroke()
    path.stroke()
  }
}

private extension NSScreen {
  var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
