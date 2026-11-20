import AppKit
import SwiftUI

// Settings ▸ Appearance and Drop Zone: the system accent their selections
// are drawn in, and Drop Zone's corner picker. Rows marked "inferred" have
// no design value.

extension PinaxPalette.Settings {
  /// The chosen app icon's ring and name, the chosen corner: the main
  /// window's teal, not the system accent.
  public static let systemAccent = PinaxPalette.accentFill

  /// The little screen behind the corners (`.screen`: `#dfe7f3` → `#c9d4e6`;
  /// dark `#3a4150` → `#2c3240`, inferred), its edge (black 18 %; dark
  /// white 12 %, inferred).
  public static let cornerScreenTop = Color(
    nsColor: s3Dynamic("pinax.settings.cornerScreen.top") { PinaxPalette.RGBA(hex: $0 ? 0x3a4150 : 0xdfe7f3) })
  public static let cornerScreenBottom = Color(
    nsColor: s3Dynamic("pinax.settings.cornerScreen.bottom") { PinaxPalette.RGBA(hex: $0 ? 0x2c3240 : 0xc9d4e6) })
  public static let cornerScreenEdge = Color(
    nsColor: s3Dynamic("pinax.settings.cornerScreen.edge") {
      $0 ? PinaxPalette.RGBA(255, 255, 255, 0.12) : PinaxPalette.RGBA(0, 0, 0, 0.18)
    })
  /// An unchosen corner (`.cn`: white 75 %, edge black 15 %; dark white
  /// 22 % and white 15 %, inferred).
  public static let corner = Color(
    nsColor: s3Dynamic("pinax.settings.corner") {
      $0 ? PinaxPalette.RGBA(255, 255, 255, 0.22) : PinaxPalette.RGBA(255, 255, 255, 0.75)
    })
  public static let cornerEdge = Color(
    nsColor: s3Dynamic("pinax.settings.corner.edge") {
      $0 ? PinaxPalette.RGBA(255, 255, 255, 0.15) : PinaxPalette.RGBA(0, 0, 0, 0.15)
    })

  /// The box round a row pop-up's ⌃⌄ (the grouped form's: black 7 %; dark
  /// white 12 %, inferred), never the accent.
  public static let popUpIndicator = Color(
    nsColor: s3Dynamic("pinax.settings.popUpIndicator") {
      $0 ? PinaxPalette.RGBA(255, 255, 255, 0.12) : PinaxPalette.RGBA(0, 0, 0, 0.07)
    })

  private static func s3Dynamic(_ name: String, _ value: @escaping @Sendable (Bool) -> PinaxPalette.RGBA) -> NSColor {
    NSColor(name: NSColor.Name(name)) { appearance in
      value(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
    }
  }
}
