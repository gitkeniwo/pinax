import AppKit
import SwiftUI

/// The menu bar panel's statistics card and Library page, like
/// `OverviewPalette`: the one place there a hue is named — the orange
/// attention dots, one colour per backend, and the card, pill, bar and
/// accent colours, as light / dark pairs.
enum MenuBarPalette {
  static let attention = Color(nsColor: .systemOrange)
  static let scanDot = Color(nsColor: .secondaryLabelColor)

  /// The statistics and uploads cards' fill, and the fill under the
  /// pointer: a light wash over the panel's own frosted material, so the
  /// panel shows through (an opaque #F8F8F9 / #343438 read as too white).
  static let card = pair(light: (0xFF, 0xFF, 0xFF, 0.32), dark: (0xFF, 0xFF, 0xFF, 0.05))
  static let cardHover = pair(light: (0, 0, 0, 0.05), dark: (0xFF, 0xFF, 0xFF, 0.10))
  /// The cards' (and the opening platter's) outline: Control Center's
  /// module shape, a continuous-curvature corner.
  static let cardShape = RoundedRectangle(
    cornerRadius: DesignMetrics.menuBarLibrary.cardRadius, style: .continuous)
  /// The card's frame and its hairlines.
  static let cardBorder = pair(light: (0, 0, 0, 0.10), dark: (0xFF, 0xFF, 0xFF, 0.10))
  /// The project pill.
  static let track = pair(light: (0, 0, 0, 0.07), dark: (0xFF, 0xFF, 0xFF, 0.07))
  /// A bar; the current one is `accent`.
  static let bar = pair(light: (0xB9, 0xBB, 0xC2, 1), dark: (0x5A, 0x5B, 0x61, 1))
  /// The canvas's Pinax green: the current bar.
  static let accent = pair(light: (0x1F, 0x8A, 0x4C, 1), dark: (0x4C, 0xC2, 0x7A, 1))
  /// The same green as a control fill: the Drop Zone While Dragging switch.
  static let accentFill = pair(light: (0x1F, 0x8A, 0x4C, 1), dark: (0x1E, 0x7D, 0x43, 1))

  /// The backend bar's segments, in `CatalogStats.backends` order; more
  /// backends than colours repeat from the start.
  static let backends: [Color] = [
    Color(nsColor: .systemBlue),
    Color(nsColor: .systemOrange),
    Color(nsColor: .systemTeal),
    Color(nsColor: .systemPurple),
    Color(nsColor: .systemPink),
    Color(nsColor: .systemBrown),
  ]

  static func backend(_ index: Int) -> Color { backends[index % backends.count] }

  /// 0–255 channels and an opacity, as the canvas writes them.
  private typealias RGBA = (r: Int, g: Int, b: Int, alpha: CGFloat)

  /// A colour that follows the drawing appearance.
  private static func pair(light: RGBA, dark: RGBA) -> Color {
    func color(_ value: RGBA) -> NSColor {
      NSColor(
        srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255,
        blue: CGFloat(value.b) / 255, alpha: value.alpha)
    }
    return Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
      })
  }
}
