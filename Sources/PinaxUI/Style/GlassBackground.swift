import AppKit
import SwiftUI

/// The only place in the codebase that knows the SDK version for glass
/// styling. Call sites never mention availability.
enum GlassSupport {
  /// Before macOS 26 a SwiftUI material only blends with its own window, so
  /// the drop zone — a borderless window with nothing of its own behind it —
  /// read as flat grey. There the panel's lowest layer
  /// is an AppKit behind-window effect view and SwiftUI only tints it; on 26
  /// `.glassEffect` does the whole job.
  static var panelUsesBehindWindowMaterial: Bool {
    if #available(macOS 26.0, *) { return false }
    return true
  }

  /// The behind-window layer: blends with whatever is behind the
  /// panel on screen, always active (the panel never becomes key), clipped
  /// to the panel's rounded shape. The material follows the panel's
  /// appearance; `.hudWindow` is the closest to the design's 34 pt blur in
  /// both light and dark.
  static func makeBehindWindowView(cornerRadius: CGFloat) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.maskImage = roundedMask(cornerRadius: cornerRadius)
    return view
  }

  /// A stretchable rounded-rectangle mask: the corners stay, the middle
  /// stretches, so one image fits every panel size.
  private static func roundedMask(cornerRadius radius: CGFloat) -> NSImage {
    let edge = 2 * radius + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

private struct GlassBackground<S: Shape>: ViewModifier {
  let shape: S
  let tint: Color
  let rim: Color

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      // The blur itself is the AppKit layer underneath (`GlassSupport`);
      // this is the canvas's translucent wash and its 1 pt highlight rim.
      content
        .background(tint, in: shape)
        .overlay(shape.stroke(rim, lineWidth: DesignMetrics.dropZone.rimWidth))
    }
  }
}

extension View {
  func glassBackground<S: Shape>(in shape: S, tint: Color, rim: Color) -> some View {
    modifier(GlassBackground(shape: shape, tint: tint, rim: rim))
  }
}
