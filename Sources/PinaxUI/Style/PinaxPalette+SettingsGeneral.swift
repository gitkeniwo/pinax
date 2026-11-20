import AppKit
import SwiftUI

// The grounds Settings ▸ General and Gallery add. Dark values marked
// "inferred" follow the settings window's group and window grounds.

extension PinaxPalette.Settings {
  /// Gallery ▸ Thumbnails' preview row (`#fafafb`; dark `#29292b`,
  /// inferred: a step under the group's `#2c2c2e`).
  public static let previewGround = Color(
    nsColor: s2Dynamic("pinax.settings.previewGround") { PinaxPalette.RGBA(hex: $0 ? 0x29292b : 0xfafafb) })
  /// A source tag card's sample (`.smp`: `#f5f5f7`, the window's ground)
  /// and its ring (black 8 %; dark white 8 %).
  public static let cardSample = window
  public static let cardRing = Color(
    nsColor: s2Dynamic("pinax.settings.cardRing") {
      $0 ? PinaxPalette.RGBA(255, 255, 255, 0.08) : PinaxPalette.RGBA(0, 0, 0, 0.08)
    })
  /// The chosen card: its ring, its name, and its sample's ground (the
  /// accent at 5 %) — the main window's teal, not the system accent.
  public static let chosenCard = PinaxPalette.accentFill
  public static let chosenCardGround = PinaxPalette.accentFill.opacity(0.05)
  /// The preview's sample image (`linear-gradient(135deg, #f3b37c,
  /// #c8653a 60%, #6d4a7a)`): the stops and where they sit.
  public static let previewImageStops: [(color: PinaxPalette.RGBA, location: CGFloat)] = [
    (PinaxPalette.RGBA(hex: 0xf3b37c), 0), (PinaxPalette.RGBA(hex: 0xc8653a), 0.6),
    (PinaxPalette.RGBA(hex: 0x6d4a7a), 1),
  ]

  private static func s2Dynamic(
    _ name: String, _ value: @escaping @Sendable (Bool) -> PinaxPalette.RGBA
  ) -> NSColor {
    NSColor(name: NSColor.Name(name)) { appearance in
      value(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
    }
  }
}
