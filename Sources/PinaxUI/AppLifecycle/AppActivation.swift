import AppKit

/// Which of the app's windows make it a "regular" app (Dock tile + ⌘-Tab)
/// while open. Matched by stable identifier, never by title: SwiftUI embeds
/// the scene id in the `NSWindow` identifier, so the gallery window's
/// identifier contains `"gallery"` and the Settings scene's contains
/// `"settings"`. The drop zone panel (a borderless `NSPanel` with no
/// identifier) and the `MenuBarExtra`'s own window must **not** count, or
/// the Dock icon would never go away.
extension NSWindow {
  public var isPinaxActivatingWindow: Bool {
    // Case-insensitive: SwiftUI's Settings window identifier is
    // "com_apple_SwiftUI.Settings_window" — capital S.
    guard let id = identifier?.rawValue.lowercased() else { return false }
    return id.contains("gallery") || id.contains("settings")
  }
}

/// The Dock-icon policy: `.regular` while any real window is open,
/// `.accessory` once the last one closes — while the `MenuBarExtra` keeps
/// running. Shaped after Clop's `ClopApp.syncActivationPolicy`, whose two
/// load-bearing details are preserved verbatim: the closing window is still
/// in `NSApp.windows` during `windowWillClose` (hence `excluding:`), and only
/// windows that are visible or miniaturized count.
@MainActor
public enum AppActivation {
  /// Posted after the app becomes `.regular` — the Dock tile is back, and
  /// a custom Dock icon must be set again.
  public static let didBecomeRegular = Notification.Name("PinaxAppDidBecomeRegular")

  private static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
    NSApp.setActivationPolicy(policy)
    if policy == .regular {
      NotificationCenter.default.post(name: didBecomeRegular, object: nil)
    }
  }

  public static func syncActivationPolicy(excluding closing: NSWindow? = nil) {
    let hasRealWindow = NSApp.windows.contains { w in
      w !== closing && (w.isVisible || w.isMiniaturized) && w.isPinaxActivatingWindow
    }
    setPolicy(hasRealWindow ? .regular : .accessory)
  }

  /// Promote to `.regular` from inside a `MenuBarExtra` action. Menu bar
  /// actions run in a tracking run loop, where a single
  /// `setActivationPolicy(.regular)` often does not register in the Dock and
  /// ⌘-Tab until the next cycle (Clop's `BatchWindow.present` re-asserts on
  /// the next tick for exactly this reason). Immediate call + one deferred
  /// re-assert, plus activation so the reopened window comes to front.
  public static func makeRegularNow() {
    setPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
      setPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
