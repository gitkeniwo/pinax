import AppKit
import SwiftUI

// MARK: Sidebar Catalog rows

extension PinaxPalette {
  /// The Catalog tree lines, solid so crossing verticals do not darken
  /// (`--tree`: light `#bcbcc1`, dark `#626266`).
  public static let tree = Color(nsColor: dynamic(light: RGBA(0xbc, 0xbc, 0xc1), dark: RGBA(0x62, 0x62, 0x66)))

  /// The sidebar's ground (`--side`: light `#e9e9eb`, dark `#3a3a3c`): the
  /// ring that parts a stacked folder's front square from the layer behind.
  public static let sidebarGround = Color(
    nsColor: dynamic(light: RGBA(0xe9, 0xe9, 0xeb), dark: RGBA(0x3a, 0x3a, 0x3c)))

  private static func dynamic(light: RGBA, dark: RGBA) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
    }
  }
}
