import AppKit
import SwiftUI

/// The translucent, behind-window "sidebar" material Xcode's navigator uses:
/// the desktop shows through, blurred, and it dims with the window when the
/// window is inactive.
///
/// SwiftUI's `.regularMaterial` cannot give this look: it blends within the
/// window, so over the window's own opaque background it reads as plain grey.
/// The navigation sidebar already gets this effect view from the system
/// (measured: an `NSVisualEffectView` with material `.sidebar`,
/// blending `.behindWindow`, behind the sidebar's outline); the inspector
/// column does not, so it uses this one.
struct SidebarMaterialBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
