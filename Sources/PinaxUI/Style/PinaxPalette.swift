import AppKit
import SwiftUI

/// The app's colours: gruvbox, the dark
/// group in the light appearance and the bright group in the dark one,
/// plus the accent pair and the translucent grounds the parts sit on.
/// Every hued piece of UI takes its colour from here; neutral grounds
/// (window, sidebar, inspector) stay the system's.
public enum PinaxPalette {
  public enum Token: String, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, aqua, gray
    /// Text, strokes and icons that mark the selection or a link.
    case accent
    /// The solid selection ground under white text.
    case accentFill
    /// The accent's light ground (blue at 16 % / 22 %).
    case soft
    /// A count capsule's ground.
    case count
    /// A control group's ground.
    case grp
    /// The inspector's section header ground.
    case band
  }

  /// 0–255 channels and an opacity, as the design files write them.
  public struct RGBA: Equatable, Sendable, CustomStringConvertible {
    public let r: Int, g: Int, b: Int
    public let alpha: Double

    public init(_ r: Int, _ g: Int, _ b: Int, _ alpha: Double = 1) {
      self.r = r
      self.g = g
      self.b = b
      self.alpha = alpha
    }

    init(hex: Int, alpha: Double = 1) {
      self.init((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF, alpha)
    }

    public var description: String {
      alpha == 1
        ? String(format: "#%02x%02x%02x", r, g, b)
        : String(format: "#%02x%02x%02x@%.2f", r, g, b, alpha)
    }

    var nsColor: NSColor {
      NSColor(
        srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
        alpha: CGFloat(alpha))
    }
  }

  /// The token's value in one appearance.
  public static func value(_ token: Token, dark: Bool) -> RGBA {
    switch token {
    case .red: return RGBA(hex: dark ? 0xfb4934 : 0xcc241d)
    case .orange: return RGBA(hex: dark ? 0xfe8019 : 0xd65d0e)
    case .yellow: return RGBA(hex: dark ? 0xfabd2f : 0xd79921)
    case .green: return RGBA(hex: dark ? 0xb8bb26 : 0x98971a)
    case .blue: return RGBA(hex: dark ? 0x83a598 : 0x458588)
    case .purple: return RGBA(hex: dark ? 0xd3869b : 0xb16286)
    case .aqua: return RGBA(hex: dark ? 0x8ec07c : 0x689d6a)
    case .gray: return RGBA(hex: dark ? 0xa89984 : 0x928374)
    case .accent: return RGBA(hex: dark ? 0x83a598 : 0x076678)
    case .accentFill: return RGBA(hex: 0x3d7c80)
    case .soft: return RGBA(hex: dark ? 0x83a598 : 0x458588, alpha: dark ? 0.22 : 0.16)
    case .count: return dark ? RGBA(255, 255, 255, 0.10) : RGBA(0, 0, 0, 0.07)
    case .grp: return dark ? RGBA(255, 255, 255, 0.08) : RGBA(0, 0, 0, 0.05)
    case .band: return dark ? RGBA(255, 255, 255, 0.07) : RGBA(0, 0, 0, 0.06)
    }
  }

  /// The token as a colour that follows the drawing appearance.
  public static func nsColor(_ token: Token) -> NSColor {
    NSColor(name: NSColor.Name("pinax.\(token.rawValue)")) { appearance in
      let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return value(token, dark: dark).nsColor
    }
  }

  public static func color(_ token: Token) -> Color { Color(nsColor: nsColor(token)) }

  public static let red = color(.red)
  public static let orange = color(.orange)
  public static let yellow = color(.yellow)
  public static let green = color(.green)
  public static let blue = color(.blue)
  public static let purple = color(.purple)
  public static let aqua = color(.aqua)
  public static let gray = color(.gray)
  public static let accent = color(.accent)
  public static let accentFill = color(.accentFill)
  public static let soft = color(.soft)
  public static let count = color(.count)
  public static let grp = color(.grp)
  public static let band = color(.band)

  /// Four-level status ink for views that are not errors. Keeping the
  /// mapping here lets those views name a semantic role instead of a
  /// system colour or a palette case.
  public enum Status {
    public static let pass = PinaxPalette.color(.green)
    public static let info = PinaxPalette.color(.blue)
    public static let warning = PinaxPalette.color(.orange)
    public static let failure = PinaxPalette.color(.red)
  }

  /// The stat pills' ink in the light appearance: the hue's darker gruvbox
  /// shade, readable on its own 15 % ground. In the dark appearance the ink is
  /// the token itself.
  static func statInk(_ token: Token, dark: Bool) -> RGBA {
    switch (token, dark) {
    case (.purple, false): return RGBA(hex: 0x8f3f71)
    case (.blue, false): return RGBA(hex: 0x076678)
    default: return value(token, dark: dark)
    }
  }

  // MARK: Formats

  /// JPEG blue, PNG aqua, GIF purple, WEBP orange, any
  /// other gray.
  public static func formatToken(mime: String) -> Token {
    switch mime.lowercased() {
    case "image/jpeg", "image/jpg", "image/pjpeg": return .blue
    case "image/png": return .aqua
    case "image/gif": return .purple
    case "image/webp": return .orange
    default: return .gray
    }
  }

  /// The few letters a format square shows ("JPG").
  public static func formatBadge(mime: String) -> String {
    let subtype = mime.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    let base = subtype.split(separator: "+").first.map(String.init) ?? subtype
    switch base {
    case "jpeg", "jpg", "pjpeg": return "JPG"
    case "": return "—"
    default: return String(base.prefix(4)).uppercased()
    }
  }

  // MARK: Domains

  /// The hues a domain may get: the seven that are not gray.
  public static let domainTokens: [Token] = [
    .red, .orange, .yellow, .green, .blue, .purple, .aqua,
  ]

  /// A domain's colour (Externals' letter squares): FNV-1a over the
  /// lowercased host's UTF-8, so the same domain gets the same hue in
  /// every instance and every launch — `hashValue` is seeded per process.
  public static func domainToken(_ domain: String) -> Token {
    domainTokens[Int(stableHash(domain.lowercased()) % UInt64(domainTokens.count))]
  }

  /// 64-bit FNV-1a.
  static func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
  }
}
