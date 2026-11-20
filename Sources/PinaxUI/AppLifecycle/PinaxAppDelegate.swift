import AppKit

/// App-level lifecycle glue. Two jobs:
///
/// - `applicationShouldTerminateAfterLastWindowClosed` returns `false`:
///   closing the gallery must quit nothing — the `MenuBarExtra` stays alive.
/// - It observes window close/key notifications and re-runs the Dock policy,
///   so the tile disappears with the last real window and returns when one
///   reopens (including via ⌘0 or the menu bar item).
///
/// Selector-based observers (not block-based) keep every callback on the
/// main actor without hops; notifications are delivered on `.main`.
@MainActor
public final class PinaxAppDelegate: NSObject, NSApplicationDelegate {
  public func applicationWillFinishLaunching(_ notification: Notification) {
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification, object: nil)
    center.addObserver(
      self, selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification, object: nil)
  }

  public func applicationShouldTerminateAfterLastWindowClosed(
    _ application: NSApplication
  ) -> Bool {
    false
  }

  /// During `windowWillClose` the closing window is still in `NSApp.windows`;
  /// passing it as `excluding:` is what lets the policy actually drop to
  /// `.accessory` on the last close.
  @objc private func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    AppActivation.syncActivationPolicy(excluding: window)
  }

  /// A scene window becoming key again (reopen via ⌘0, the menu bar item, or
  /// the Window menu) must restore `.regular`. Panels and the menu bar
  /// window can never become key here, so the predicate is safe to re-run.
  @objc private func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window.isPinaxActivatingWindow
    else { return }
    AppActivation.syncActivationPolicy()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
