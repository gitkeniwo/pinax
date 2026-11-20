import AppKit
import SwiftUI

/// The Overview's colours: gruvbox hues from `PinaxPalette`, one per figure —
/// its square, its title and its chart; text and numbers keep the text colours
/// — on the page's own grey ground and cards. This table, like `LabelColor`, is
/// the one place on the page a hue is named.
public enum OverviewPalette {
  // MARK: Hues (the board's `--grn`, `--blu`, …)

  /// Hero band: Assets green, Storage blue, Uploads orange, Used yellow.
  public static let assets = PinaxPalette.green
  public static let storage = PinaxPalette.blue
  public static let uploads = PinaxPalette.orange
  public static let used = PinaxPalette.yellow
  /// Upload Activity's icon, title and cells.
  public static let activity = PinaxPalette.green
  /// The Uploads chart card.
  public static let uploadsChart = PinaxPalette.blue

  /// A Library or Usage row's square.
  public static func token(_ row: OverviewModel.ListRow.Kind) -> PinaxPalette.Token {
    switch row {
    case .favorites: return .red
    case .archived: return .gray
    case .tagged: return .purple
    case .usedImages: return .orange
    case .orphanCandidates: return .purple
    case .domains: return .aqua
    }
  }

  /// Composition: a backend's share, in the order the backends come
  /// (the board's one backend is orange; the rest inferred), and the
  /// tagged share of the Tags row.
  public static let backendHues: [PinaxPalette.Token] = [
    .orange, .yellow, .purple, .aqua, .blue, .red, .green,
  ]
  public static let tagged = PinaxPalette.Token.purple

  // MARK: Grounds (the board's `t` table: `cbg`, `card`, `line`)

  public enum Ground: CaseIterable, Sendable {
    /// The page under the cards.
    case page
    /// A card or a grouped list.
    case card
    /// A card's 0.5 pt rim.
    case line
  }

  public static func value(_ ground: Ground, dark: Bool) -> PinaxPalette.RGBA {
    switch ground {
    case .page: return PinaxPalette.RGBA(hex: dark ? 0x1c1c1e : 0xe9e9ec)
    case .card: return PinaxPalette.RGBA(hex: dark ? 0x2c2c2e : 0xf4f4f6)
    case .line: return dark ? PinaxPalette.RGBA(255, 255, 255, 0.08) : PinaxPalette.RGBA(0, 0, 0, 0.08)
    }
  }

  static func dynamic(_ name: String, _ value: @escaping (Bool) -> PinaxPalette.RGBA) -> Color {
    Color(
      nsColor: NSColor(name: NSColor.Name("pinax.overview.\(name)")) { appearance in
        value(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
      })
  }

  /// Also the status bar's ground under the Overview (`GalleryStatusBar`).
  public static let page = dynamic("page") { value(.page, dark: $0) }
  public static let card = dynamic("card") { value(.card, dark: $0) }
  public static let line = dynamic("line") { value(.line, dark: $0) }
  /// A bar's empty track (the board's `--count`).
  public static let track = PinaxPalette.count

  // MARK: Heat map

  /// The heat map's five levels (the board's `h0`…`h4`): none in black 6 %
  /// (white 7 % dark), then green at 30, 50, 75 and 100 %.
  public static func heatValue(_ level: Int, dark: Bool) -> PinaxPalette.RGBA {
    let green = PinaxPalette.value(.green, dark: dark)
    switch level {
    case ..<1: return dark ? PinaxPalette.RGBA(255, 255, 255, 0.07) : PinaxPalette.RGBA(0, 0, 0, 0.06)
    case 1: return PinaxPalette.RGBA(green.r, green.g, green.b, 0.30)
    case 2: return PinaxPalette.RGBA(green.r, green.g, green.b, 0.50)
    case 3: return PinaxPalette.RGBA(green.r, green.g, green.b, 0.75)
    default: return green
    }
  }

  public static let heat: [Color] = (0..<5).map { level in
    dynamic("heat\(level)") { heatValue(level, dark: $0) }
  }
}
