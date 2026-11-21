import AppKit
import SwiftUI

/// Settings ▸ Drop Zone's mini desktop, one set per appearance: a fixed
/// wallpaper (never the user's own), its menu bar, and the desktop's rim
/// against the settings window.
struct DropZonePreviewPalette {
  /// The wallpaper's 165° wash, top to bottom.
  let wash: [Color]
  /// Its two glows: top right and bottom left.
  let topGlow: Color
  let bottomGlow: Color
  let menuBar: Color
  let menuBarMark: Color
  let menuBarClock: Color

  static let dark = DropZonePreviewPalette(
    wash: [color(0x1a2133), color(0x251f36), color(0x2c1e2b)],
    topGlow: color(0x3c5585), bottomGlow: color(0x6a3657),
    menuBar: color(0x0a0a10, 0.32), menuBarMark: color(0xffffff, 0.55),
    menuBarClock: color(0xffffff, 0.75))

  static let light = DropZonePreviewPalette(
    wash: [color(0xe3ebf7), color(0xebe5f3), color(0xf7e6dd)],
    topGlow: color(0xb7d0f2), bottomGlow: color(0xf4c9d4),
    menuBar: color(0xffffff, 0.42), menuBarMark: color(0x000000, 0.42),
    menuBarClock: color(0x000000, 0.6))

  static func of(_ scheme: ColorScheme) -> DropZonePreviewPalette {
    scheme == .dark ? dark : light
  }

  /// The desktop's edge in the settings window's own appearance (white
  /// 14 %; light black 12 %, inferred).
  static func rim(window scheme: ColorScheme) -> Color {
    scheme == .dark ? color(0xffffff, 0.14) : color(0x000000, 0.12)
  }

  private static func color(_ hex: Int, _ alpha: Double = 1) -> Color {
    Color(nsColor: PinaxPalette.RGBA(hex: hex, alpha: alpha).nsColor)
  }
}
