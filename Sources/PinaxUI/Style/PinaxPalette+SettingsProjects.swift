import AppKit
import SwiftUI

// Settings ▸ Projects and Backends colours.

extension PinaxPalette.Settings {
  /// A source's folder glyph (`svg path fill="#5aa7f7"`, Finder's folder;
  /// the same in dark, inferred).
  public static let sourceFolder = Color(nsColor: PinaxPalette.RGBA(hex: 0x5aa7f7).nsColor)
}

// The list column's island: a level under the detail's
// groups. Light: white 50 % over the window, a black 8 % ring, a black 7 %
// line over the footer. Dark: the group's `#2c2c2e` at 50 % (the same step
// down, inferred), white 8 % ring and white 7 % line (inferred).

extension PinaxPalette.Settings {
  public static let island = islandDynamic("pinax.settings.island") {
    $0 ? PinaxPalette.RGBA(0x2c, 0x2c, 0x2e, 0.5) : PinaxPalette.RGBA(255, 255, 255, 0.5)
  }
  public static let islandRing = islandDynamic("pinax.settings.islandRing") {
    $0 ? PinaxPalette.RGBA(255, 255, 255, 0.08) : PinaxPalette.RGBA(0, 0, 0, 0.08)
  }
  public static let islandFooterDivider = islandDynamic("pinax.settings.islandFooterDivider") {
    $0 ? PinaxPalette.RGBA(255, 255, 255, 0.07) : PinaxPalette.RGBA(0, 0, 0, 0.07)
  }

  private static func islandDynamic(
    _ name: String, _ value: @escaping @Sendable (Bool) -> PinaxPalette.RGBA
  ) -> Color {
    Color(
      nsColor: NSColor(name: NSColor.Name(name)) { appearance in
        value(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
      })
  }
}
