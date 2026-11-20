import AppKit
import CatalogCore
import SwiftUI

// The key template block's colours. Dark values the design leaves open
// come from colours PinaxPalette already has.

extension PinaxPalette {
  public enum KeyTemplateColors {
    /// A token's ground: the placeholder's ink at a low opacity; about 20 %
    /// of the bright ink in the dark.
    public static func tokenGround(_ placeholder: KeyTemplatePlaceholder, dark: Bool) -> RGBA {
      let ink: Ink
      let alpha: Double
      switch placeholder {
      case .prefix: (ink, alpha) = (.blue, 0.12)
      case .year, .month, .day: (ink, alpha) = (.purple, 0.11)
      case .name: (ink, alpha) = (.green, 0.14)
      case .hash: (ink, alpha) = (.orange, 0.11)
      case .ext: (ink, alpha) = (.gray, 0.13)
      }
      let value = PinaxPalette.inkValue(ink, dark: dark)
      return RGBA(value.r, value.g, value.b, dark ? 0.20 : alpha)
    }

    /// A token's name and the example's text (`#3c3836`; dark `#ebdbb2`).
    public static func text(dark: Bool) -> RGBA { RGBA(hex: dark ? 0xebdbb2 : 0x3c3836) }

    /// Literal text in the field and the example, the example's arrow and
    /// `UTC` (`.lit`: `#a1a1a6`; dark: the gray ink `#a89984`).
    public static func literal(dark: Bool) -> RGBA {
      dark ? PinaxPalette.inkValue(.gray, dark: true) : RGBA(hex: 0xa1a1a6)
    }

    /// The field's ring with an error, and the wavy line under a `{…}` that
    /// is not a placeholder (`.fld.bad`: `#cc241d`; dark the bright red).
    public static func errorRing(dark: Bool) -> RGBA { PinaxPalette.value(.red, dark: dark) }

    /// A callout's ground: orange 6 % for a warning, red 5.5 % for an
    /// error (`.call`, `.call.err`), the bright colours in the dark.
    public static func calloutGround(error: Bool, dark: Bool) -> RGBA {
      let value = PinaxPalette.value(error ? .red : .orange, dark: dark)
      return RGBA(value.r, value.g, value.b, error ? 0.055 : 0.06)
    }

    /// A callout's words: body text for a warning, the red ink for an
    /// error; `#fe8019` / `#fb4934` in the dark.
    public static func calloutText(error: Bool, dark: Bool) -> RGBA {
      if error { return PinaxPalette.inkValue(.red, dark: dark) }
      return dark ? PinaxPalette.inkValue(.orange, dark: true) : text(dark: false)
    }

    /// Insert's ground (`.ins`: the teal at 10 %) and words (`#2f6569`;
    /// dark: the accent's `#83a598`).
    public static func insertGround(dark: Bool) -> RGBA {
      let teal = PinaxPalette.value(.accentFill, dark: dark)
      return RGBA(teal.r, teal.g, teal.b, 0.10)
    }

    public static func insertText(dark: Bool) -> RGBA {
      dark ? PinaxPalette.value(.accent, dark: true) : RGBA(hex: 0x2f6569)
    }

    /// Reset to Default (`.lnk`: the teal `#3d7c80`; dark the accent's
    /// `#83a598`, the teal being too dark on the dark group).
    public static func link(dark: Bool) -> RGBA {
      dark ? PinaxPalette.value(.accent, dark: true) : PinaxPalette.value(.accentFill, dark: false)
    }

    public static func nsColor(_ name: String, _ value: @escaping @Sendable (Bool) -> RGBA) -> NSColor {
      NSColor(name: NSColor.Name("pinax.keyTemplate.\(name)")) { appearance in
        value(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nsColor
      }
    }

    public static func color(_ name: String, _ value: @escaping @Sendable (Bool) -> RGBA) -> Color {
      Color(nsColor: nsColor(name, value))
    }

    /// The field's AppKit colours, and the same as SwiftUI colours.
    public static let textNSColor = nsColor("text") { text(dark: $0) }
    public static let literalNSColor = nsColor("literal") { literal(dark: $0) }
    public static let errorRingNSColor = nsColor("errorRing") { errorRing(dark: $0) }
    public static let textColor = Color(nsColor: textNSColor)
    public static let literalColor = Color(nsColor: literalNSColor)
    public static let errorRingColor = Color(nsColor: errorRingNSColor)
    public static let warningGround = color("warningGround") { calloutGround(error: false, dark: $0) }
    public static let errorGround = color("errorGround") { calloutGround(error: true, dark: $0) }
    public static let warningText = color("warningText") { calloutText(error: false, dark: $0) }
    public static let errorText = color("errorText") { calloutText(error: true, dark: $0) }
    public static let warningIcon = PinaxPalette.color(.orange)
    public static let errorIcon = PinaxPalette.color(.red)
    public static let insertGroundColor = color("insertGround") { insertGround(dark: $0) }
    public static let insertTextColor = color("insertText") { insertText(dark: $0) }
    public static let linkColor = color("link") { link(dark: $0) }
  }
}

extension PinaxPalette.KeyTemplateColors {
  /// The field's ground and resting edge (`.fld`: `#fff`, inset 0.5 black
  /// 20 %; dark: the band's white 7 % and the count's white 10 %).
  public static func fieldGround(dark: Bool) -> PinaxPalette.RGBA {
    dark ? PinaxPalette.value(.band, dark: true) : PinaxPalette.RGBA(255, 255, 255)
  }

  public static func fieldBorder(dark: Bool) -> PinaxPalette.RGBA {
    dark ? PinaxPalette.value(.count, dark: true) : PinaxPalette.RGBA(0, 0, 0, 0.2)
  }

  /// A popover row under the pointer (`.mi:hover`: the teal at 12 %).
  public static func tealGround(_ alpha: Double, dark: Bool) -> PinaxPalette.RGBA {
    let teal = PinaxPalette.value(.accentFill, dark: dark)
    return PinaxPalette.RGBA(teal.r, teal.g, teal.b, alpha)
  }

  public static let menuHoverColor = color("menuHover") { tealGround(0.12, dark: $0) }
  /// Insert's segment while its popover is open: the band's wash.
  public static let insertOpenGroundColor = PinaxPalette.band

  /// The example's capsule: black 4 % with a 7 % edge and a white
  /// 90 % top light; in the dark white 6 %, edge 6 %, light 14 %.
  public static func pillGround(dark: Bool) -> PinaxPalette.RGBA {
    dark ? PinaxPalette.RGBA(255, 255, 255, 0.06) : PinaxPalette.RGBA(0, 0, 0, 0.04)
  }

  public static func pillEdge(dark: Bool) -> PinaxPalette.RGBA {
    dark ? PinaxPalette.RGBA(255, 255, 255, 0.06) : PinaxPalette.RGBA(0, 0, 0, 0.07)
  }

  public static func pillLight(dark: Bool) -> PinaxPalette.RGBA {
    PinaxPalette.RGBA(255, 255, 255, dark ? 0.14 : 0.9)
  }

  /// The ⋯ chip: black 6 % (the band), white 10 % in the dark (the count).
  public static func chipGround(dark: Bool) -> PinaxPalette.RGBA {
    PinaxPalette.value(dark ? .count : .band, dark: dark)
  }

  public static let pillGroundColor = color("pillGround") { pillGround(dark: $0) }
  public static let pillEdgeColor = color("pillEdge") { pillEdge(dark: $0) }
  public static let pillLightColor = color("pillLight") { pillLight(dark: $0) }
  public static let chipGroundColor = color("chipGround") { chipGround(dark: $0) }
  public static let fieldGroundColor = color("fieldGround") { fieldGround(dark: $0) }
  public static let fieldBorderColor = color("fieldBorder") { fieldBorder(dark: $0) }
}
