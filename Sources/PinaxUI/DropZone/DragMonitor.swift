import AppKit
import Foundation

/// The drag pasteboard seam. Every member can be a synchronous XPC round trip
/// to the pasteboard server, which is why `DragMonitor` gates on `changeCount`
/// and resolves URLs away from the main thread.
public protocol DragPasteboardReading: Sendable {
  var changeCount: Int { get }
  func fileURLs() -> [URL]
}

/// `NSPasteboard(name: .drag)` behind `DragPasteboardReading`. The pasteboard
/// object is looked up per call so the conforming type stays a plain value.
public struct SystemDragPasteboard: DragPasteboardReading {
  public init() {}

  public var changeCount: Int {
    NSPasteboard(name: .drag).changeCount
  }

  public func fileURLs() -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    return NSPasteboard(name: .drag)
      .readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
  }
}

/// Detects file drags anywhere on the system via global (and local) mouse
/// monitors — global *mouse* monitoring needs no Accessibility permission —
/// and reports them to the model. The pasteboard discipline lives in
/// `dragEventOccurred`: compare `changeCount`, never let a second read queue
/// behind a slow one, resolve off the main thread, and hop back with plain
/// values only. Within one drag session the pasteboard never changes, so the
/// session's URLs are cached and every subsequent drag event re-samples with
/// the modifier flags held *now* — a mid-drag ⌥ press or release must reach
/// the model without a single extra pasteboard read.
@MainActor
public final class DragMonitor {
  private let pasteboard: any DragPasteboardReading
  private let onSample: @MainActor ([URL], NSEvent.ModifierFlags) -> Void
  private let onDragEnded: @MainActor () -> Void

  private var inFlight = false
  private var lastResolvedChangeCount = 0
  /// The current drag session's resolved URLs. One drag writes the drag
  /// pasteboard exactly once, so its changeCount — and therefore its URLs —
  /// are stable for the session; the flags are not, and they are what keeps
  /// changing per event.
  private var cachedDragURLs: [URL] = []
  private var globalMonitor: Any?
  private var localMonitor: Any?

  public init(
    pasteboard: any DragPasteboardReading = SystemDragPasteboard(),
    onSample: @escaping @MainActor ([URL], NSEvent.ModifierFlags) -> Void,
    onDragEnded: @escaping @MainActor () -> Void
  ) {
    self.pasteboard = pasteboard
    self.onSample = onSample
    self.onDragEnded = onDragEnded
  }

  /// Baselines the pasteboard's `changeCount` so a drag that ended before the
  /// monitor existed (its content is still sitting there, stale) never shows
  /// the zone. Exposed separately from the monitors so tests need no NSEvent.
  public func baselinePasteboard() {
    lastResolvedChangeCount = pasteboard.changeCount
  }

  public func start() {
    baselinePasteboard()
    installMonitors()
  }

  public func stop() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
    cachedDragURLs = []
  }

  private func installMonitors() {
    let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      // NSEvent is not Sendable; the two values the main actor needs are
      // extracted (as plain values) before the hop. The flags ride along so
      // the model can gate visibility on the modifier held *during* the drag.
      let type = event.type
      let flags = event.modifierFlags.rawValue
      Task { @MainActor [weak self] in
        self?.receive(type, flags: NSEvent.ModifierFlags(rawValue: flags))
      }
    }
    // Global monitors see nothing while our own app is active (e.g. a drag
    // started from the gallery), so a local monitor covers that half.
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      let type = event.type
      let flags = event.modifierFlags.rawValue
      Task { @MainActor [weak self] in
        self?.receive(type, flags: NSEvent.ModifierFlags(rawValue: flags))
      }
      return event
    }
  }

  private func receive(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags) {
    switch type {
    case .leftMouseDragged:
      dragEventOccurred(flags: flags)
    case .leftMouseUp:
      mouseUpOccurred()
    default:
      break
    }
  }

  public func dragEventOccurred(flags: NSEvent.ModifierFlags = []) {
    guard !inFlight else { return }
    inFlight = true
    let pasteboard = self.pasteboard
    let known = lastResolvedChangeCount
    let flagBits = flags.rawValue
    // The gate is part of the XPC cost, so it runs off the main thread too:
    // reading `changeCount` here, 60 times a second, is exactly the freeze
    // that discipline exists to prevent. Only the one-time
    // `baselinePasteboard()` read ever touches the pasteboard on the main
    // actor.
    Task.detached(priority: .userInitiated) {
      let changeCount = pasteboard.changeCount
      guard changeCount != known else {
        let flags = NSEvent.ModifierFlags(rawValue: flagBits)
        await MainActor.run { self.finishUnchangedSample(flags: flags) }
        return
      }
      let urls = pasteboard.fileURLs()
      let flags = NSEvent.ModifierFlags(rawValue: flagBits)
      await MainActor.run { self.finishRead(urls: urls, changeCount: changeCount, flags: flags) }
    }
  }

  private func finishRead(urls: [URL], changeCount: Int, flags: NSEvent.ModifierFlags) {
    inFlight = false
    lastResolvedChangeCount = changeCount
    cachedDragURLs = urls
    onSample(urls, flags)
  }

  /// The drag session continues with an untouched pasteboard: its URLs are
  /// already known, so this re-samples with the flags held *now* and touches
  /// no pasteboard API at all (the rule against reading the drag pasteboard
  /// on the main thread concerns XPC reads; this path performs none). This
  /// is what makes a mid-drag modifier press/release reach the model and
  /// keeps the model publishing during a drag, which the follow-cursor
  /// placement rides on.
  private func finishUnchangedSample(flags: NSEvent.ModifierFlags) {
    inFlight = false
    guard !cachedDragURLs.isEmpty else { return }
    onSample(cachedDragURLs, flags)
  }

  public func mouseUpOccurred() {
    // The session is over: without this, any later mouse drag with an
    // unchanged pasteboard would resurrect this session's sample.
    cachedDragURLs = []
    onDragEnded()
  }
}
