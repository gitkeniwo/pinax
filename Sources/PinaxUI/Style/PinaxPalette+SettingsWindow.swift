import AppKit
import SwiftUI

// The settings window's colours: the settings icons' gradients, the faded
// gruvbox group as ink, and the window's grounds. Rows marked "inferred"
// have no design value.

extension PinaxPalette {
  /// The faded gruvbox group, for text in the light appearance; the bright
  /// group (the plain tokens' dark values) in the dark one.
  public enum Ink: String, CaseIterable, Sendable {
    case red, green, yellow, blue, purple, aqua, orange, gray
  }

  public static func inkValue(_ ink: Ink, dark: Bool) -> RGBA {
    switch ink {
    case .red: return RGBA(hex: dark ? 0xfb4934 : 0x9d0006)
    case .green: return RGBA(hex: dark ? 0xb8bb26 : 0x79740e)
    case .yellow: return RGBA(hex: dark ? 0xfabd2f : 0xb57614)
    case .blue: return RGBA(hex: dark ? 0x83a598 : 0x076678)
    case .purple: return RGBA(hex: dark ? 0xd3869b : 0x8f3f71)
    case .aqua: return RGBA(hex: dark ? 0x8ec07c : 0x427b58)
    case .orange: return RGBA(hex: dark ? 0xfe8019 : 0xaf3a03)
    case .gray: return RGBA(hex: dark ? 0xa89984 : 0x7c6f64)
    }
  }

  public static func ink(_ ink: Ink) -> Color {
    Color(nsColor: gui7Dynamic("pinax.ink.\(ink.rawValue)") { inkValue(ink, dark: $0) })
  }

  /// Status ink: the text beside a status symbol or inside a pill.
  public enum StatusInk {
    public static let pass = PinaxPalette.ink(.green)
    public static let info = PinaxPalette.ink(.blue)
    public static let warning = PinaxPalette.ink(.orange)
    public static let failure = PinaxPalette.ink(.red)
  }

  /// A settings status: its colour for symbols, dots and pill
  /// grounds, and its ink for words.
  public enum SettingsStatus: Sendable {
    case pass, info, warning, failure

    public var token: Token {
      switch self {
      case .pass: .green
      case .info: .blue
      case .warning: .orange
      case .failure: .red
      }
    }

    public var ink: Color {
      switch self {
      case .pass: StatusInk.pass
      case .info: StatusInk.info
      case .warning: StatusInk.warning
      case .failure: StatusInk.failure
      }
    }
  }

  // MARK: Settings icons

  /// A settings icon's gradient, top then bottom.
  public static func settingsIconGradient(_ tab: SettingsTab, dark: Bool) -> (top: RGBA, bottom: RGBA) {
    let pair: (Int, Int)
    switch (tab, dark) {
    case (.general, false): pair = (0xa89984, 0x7c6f64)
    case (.general, true): pair = (0xbdae93, 0x928374)
    case (.appearance, false): pair = (0x504945, 0x282828)
    case (.appearance, true): pair = (0x665c54, 0x3c3836)
    case (.dropZone, false): pair = (0x458588, 0x076678)
    case (.dropZone, true): pair = (0x83a598, 0x458588)
    case (.gallery, false): pair = (0xd65d0e, 0xaf3a03)
    case (.gallery, true): pair = (0xfe8019, 0xd65d0e)
    case (.projects, false): pair = (0x689d6a, 0x427b58)
    case (.projects, true): pair = (0x8ec07c, 0x689d6a)
    case (.backends, false): pair = (0xb16286, 0x8f3f71)
    case (.backends, true): pair = (0xd3869b, 0xb16286)
    case (.maintenance, false): pair = (0x98971a, 0x79740e)
    case (.maintenance, true): pair = (0xb8bb26, 0x98971a)
    }
    return (RGBA(hex: pair.0), RGBA(hex: pair.1))
  }

  /// A settings icon's glyph: cream in the light appearance, dark in the
  /// dark one — but Appearance's near-black tile keeps a light glyph.
  public static func settingsIconGlyph(_ tab: SettingsTab, dark: Bool) -> RGBA {
    guard dark else { return RGBA(hex: 0xfbf1c7) }
    return RGBA(hex: tab == .appearance ? 0xebdbb2 : 0x282828)
  }

  static func settingsIconColors(_ tab: SettingsTab) -> (top: Color, bottom: Color, glyph: Color) {
    let name = "pinax.settingsIcon.\(tab)"
    return (
      Color(nsColor: gui7Dynamic("\(name).top") { settingsIconGradient(tab, dark: $0).top }),
      Color(nsColor: gui7Dynamic("\(name).bottom") { settingsIconGradient(tab, dark: $0).bottom }),
      Color(nsColor: gui7Dynamic("\(name).glyph") { settingsIconGlyph(tab, dark: $0) }))
  }

  /// The glyph inside a status symbol.
  public static let statusGlyph = Color(
    nsColor: gui7Dynamic("pinax.statusGlyph") { RGBA(hex: $0 ? 0x282828 : 0xfbf1c7) })

  // MARK: Settings grounds

  public enum Settings {
    /// The content area (`.win`: `#f5f5f7`; dark `#1e1e1e`).
    public static let window = Color(
      nsColor: gui7Dynamic("pinax.settings.window") { RGBA(hex: $0 ? 0x1e1e1e : 0xf5f5f7) })
    /// A form group (`.g`: `#fff`; dark `#2c2c2e`).
    public static let group = Color(
      nsColor: gui7Dynamic("pinax.settings.group") { RGBA(hex: $0 ? 0x2c2c2e : 0xffffff) })
    /// A group's hairline ring (`.g`: black 9 %; dark white 8 %).
    public static let groupRing = Color(
      nsColor: gui7Dynamic("pinax.settings.groupRing") { $0 ? RGBA(255, 255, 255, 0.08) : RGBA(0, 0, 0, 0.09) })
    /// The line between rows (`.r + .r`: `#e3e3e7`; dark white 8 %).
    public static let rowDivider = Color(
      nsColor: gui7Dynamic("pinax.settings.rowDivider") { $0 ? RGBA(255, 255, 255, 0.08) : RGBA(hex: 0xe3e3e7) })
    /// The edge right of the sidebar and of a list column (`.sb`: black 10 %,
    /// `.lst`: black 8 % — one token, 8 %; dark white 8 %).
    public static let columnDivider = Color(
      nsColor: gui7Dynamic("pinax.settings.columnDivider") { $0 ? RGBA(255, 255, 255, 0.08) : RGBA(0, 0, 0, 0.08) })
    /// A list column's ground (`#fbfbfc`; dark `#262628`, inferred from the
    /// sidebar's value).
    public static let listColumn = Color(
      nsColor: gui7Dynamic("pinax.settings.listColumn") { RGBA(hex: $0 ? 0x262628 : 0xfbfbfc) })
    /// A selected list row (the accent at 12 %) — the main window's
    /// teal, as the sidebar's selection, not the system accent.
    public static let listSelection = Color(
      nsColor: gui7Dynamic("pinax.settings.listSelection") {
        let accent = PinaxPalette.value(.accentFill, dark: $0)
        return RGBA(accent.r, accent.g, accent.b, 0.12)
      })
    /// The sidebar's row names: the main sidebar's `.primary` as its
    /// vibrant column renders it (measured: `#565656`; dark
    /// `#ededed`), which this sidebar's list does not get on its own.
    public static let sidebarText = Color(
      nsColor: gui7Dynamic("pinax.settings.sidebarText") { RGBA(hex: $0 ? 0xededed : 0x565656) })
    /// A code chip's ground and ink (`.chip`: `#f0f0f3` / `#3a3a3c`; dark
    /// white 8 % / `#d1d1d6`, inferred).
    public static let chip = Color(
      nsColor: gui7Dynamic("pinax.settings.chip") { $0 ? RGBA(255, 255, 255, 0.08) : RGBA(hex: 0xf0f0f3) })
    public static let chipInk = Color(
      nsColor: gui7Dynamic("pinax.settings.chipInk") { RGBA(hex: $0 ? 0xd1d1d6 : 0x3a3a3c) })
  }

  /// A status pill's ground (the status colour at 16 %).
  static func pillGround(_ token: Token) -> Color {
    Color(nsColor: gui7Dynamic("pinax.pill.\(token.rawValue)") {
      let value = PinaxPalette.value(token, dark: $0)
      return RGBA(value.r, value.g, value.b, 0.16)
    })
  }

  private static func gui7Dynamic(_ name: String, _ value: @escaping @Sendable (Bool) -> RGBA) -> NSColor {
    NSColor(name: NSColor.Name(name)) { appearance in
      value(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
    }
  }
}
