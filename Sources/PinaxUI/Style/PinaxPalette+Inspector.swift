import AppKit
import SwiftUI

// The inspector's own colours.
extension PinaxPalette {
  /// The Projects row's "1 live" dot (gruvbox's
  /// faded green #79740e in the light appearance, bright green in the dark).
  static func live(dark: Bool) -> RGBA {
    dark ? value(.green, dark: true) : RGBA(hex: 0x79740e)
  }

  public static let liveDot = Color(
    nsColor: NSColor(name: NSColor.Name("pinax.live")) { appearance in
      live(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
    })
}

// The inspector's text fields: white 75 % over a 0.5 pt black 14 % line in
// the light appearance, black 20 % under white 14 % in the dark.
extension PinaxPalette {
  static func field(dark: Bool) -> RGBA {
    dark ? RGBA(0, 0, 0, 0.20) : RGBA(255, 255, 255, 0.75)
  }

  static func fieldLine(dark: Bool) -> RGBA {
    dark ? RGBA(255, 255, 255, 0.14) : RGBA(0, 0, 0, 0.14)
  }

  public static let fieldGround = Color(
    nsColor: NSColor(name: NSColor.Name("pinax.field")) { appearance in
      field(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
    })

  public static let fieldLine = Color(
    nsColor: NSColor(name: NSColor.Name("pinax.fieldLine")) { appearance in
      fieldLine(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
    })
}
