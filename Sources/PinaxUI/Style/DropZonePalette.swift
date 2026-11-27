import AppKit
import SwiftUI

/// The drop zone's colours, for both the List and the Shelf. The panel is
/// the one place outside `PinaxPalette` that names its own hues: system blue
/// and Pinax green as the accents, three muted status hues, and the
/// illustration's neutral greys. Like `OverviewPalette`, this table is the
/// one place a hue is named for it.
public struct DropZonePalette {
  /// Text on the glass.
  public let primary: Color
  public let secondary: Color
  /// The accent: system blue in light, Pinax green in dark.
  public let accent: Color
  /// The tint laid over the behind-window material, and its 1 pt rim.
  public let panelTint: Color
  public let panelRim: Color
  /// The header's project pill.
  public let pillFill: Color
  public let pillStroke: Color
  /// An icon button's rounded hover ground.
  public let buttonHover: Color
  /// A card at rest and hovered:
  /// fill, hairline rim, shadow — standing off the panel's glass.
  public let cardFill: Color
  public let cardRim: Color
  public let cardHoverFill: Color
  public let cardHoverRim: Color
  public let cardShadow: Color
  public let cardHoverShadow: Color
  /// The project token on a card.
  public let tokenFill: Color
  /// The three status hues.
  public let done: Color
  public let uploading: Color
  public let failed: Color
  /// The upload ring's empty track.
  public let track: Color
  /// The illustration: line and paper (never black in dark).
  public let ink: Color
  public let paper: Color
  /// The drag overlay's thin glass wash.
  public let dropWash: Color
  /// Words that step back further than `secondary`: a copy that will not
  /// be sent.
  public let tertiary: Color
  /// Review's bottom bar: its hairline, its buttons' ground, and Upload's
  /// green, a step deeper than the dark accent so white text reads on it.
  public let rule: Color
  public let buttonFill: Color
  public let primaryButton: Color

  public static let light = DropZonePalette(
    primary: Color(hex: 0x1d1d1f),
    secondary: Color(hex: 0x5f5f66),
    accent: Color(nsColor: .systemBlue),
    panelTint: Color(hex: 0xfafafc, opacity: 0.42),
    panelRim: Color.white.opacity(0.65),
    pillFill: Color.white.opacity(0.55),
    pillStroke: Color.black.opacity(0.10),
    buttonHover: Color.black.opacity(0.07),
    cardFill: Color.white.opacity(0.78),
    cardRim: Color.black.opacity(0.06),
    cardHoverFill: Color.white.opacity(0.92),
    cardHoverRim: Color.black.opacity(0.07),
    cardShadow: Color(hex: 0x1e1e3c, opacity: 0.10),
    cardHoverShadow: Color(hex: 0x1e1e3c, opacity: 0.16),
    tokenFill: Color.black.opacity(0.05),
    done: Color(hex: 0x5f8a6c),
    uploading: Color(hex: 0x5d7896),
    failed: Color(hex: 0xb0644f),
    track: Color.black.opacity(0.16),
    ink: Color(hex: 0x3d3a36),
    paper: Color(hex: 0xfbfaf7),
    dropWash: Color(hex: 0xfafafc, opacity: 0.35),
    tertiary: Color(hex: 0x8e8e93),
    rule: Color.black.opacity(0.10),
    buttonFill: Color.black.opacity(0.06),
    primaryButton: Color(hex: 0x367f2b))

  public static let dark = DropZonePalette(
    primary: Color(hex: 0xf5f5f7),
    secondary: Color(hex: 0xa1a1aa),
    accent: Color(hex: 0x5db84a),
    panelTint: Color(hex: 0x18181c, opacity: 0.52),
    panelRim: Color.white.opacity(0.14),
    pillFill: Color.white.opacity(0.08),
    pillStroke: Color.white.opacity(0.16),
    buttonHover: Color.white.opacity(0.14),
    cardFill: Color.white.opacity(0.10),
    cardRim: Color.white.opacity(0.10),
    cardHoverFill: Color.white.opacity(0.16),
    cardHoverRim: Color.white.opacity(0.20),
    cardShadow: Color.black.opacity(0.25),
    cardHoverShadow: Color.black.opacity(0.35),
    tokenFill: Color.white.opacity(0.08),
    done: Color(hex: 0x93c09f),
    uploading: Color(hex: 0xa3b8d2),
    failed: Color(hex: 0xe09a85),
    track: Color.white.opacity(0.22),
    ink: Color(hex: 0xa9a9b1),
    paper: Color(hex: 0x4a4a51),
    dropWash: Color(hex: 0x141418, opacity: 0.30),
    tertiary: Color(hex: 0x85858d),
    rule: Color.white.opacity(0.14),
    buttonFill: Color.white.opacity(0.14),
    primaryButton: Color(hex: 0x367f2b))

  public static func of(_ scheme: ColorScheme) -> DropZonePalette {
    scheme == .dark ? dark : light
  }
}

extension Color {
  fileprivate init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: opacity)
  }
}
