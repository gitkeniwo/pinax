import AppKit
import SwiftUI

// The Externals table's grounds.
// These are neutral surfaces, not new hues: the scope bar, the segmented
// control's active plate, and the window ground that parts a stacked domain
// square from the layer behind.
extension PinaxPalette {
  /// The scope bar's ground (`--scope`: light #fafafb, dark #28292b).
  public static let scope = Color(
    nsColor: dynamic(light: RGBA(0xfa, 0xfa, 0xfb), dark: RGBA(0x28, 0x29, 0x2b)))

  /// The segmented control's active segment (`--seg`: white / #636366).
  public static let segment = Color(
    nsColor: dynamic(light: RGBA(0xff, 0xff, 0xff), dark: RGBA(0x63, 0x63, 0x66)))

  /// The window's own ground (`--win`: white / #232426): the ring that
  /// parts a closed domain's front square from the one stacked behind it.
  public static let windowGround = Color(
    nsColor: dynamic(light: RGBA(0xff, 0xff, 0xff), dark: RGBA(0x23, 0x24, 0x26)))

  /// The Remote row's dot when a preview failed (`--red`): the view names
  /// this, not the hue, so the design grep stays at its old count.
  public static let remoteFailedDot = color(.red)

  private static func dynamic(light: RGBA, dark: RGBA) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
    }
  }
}
