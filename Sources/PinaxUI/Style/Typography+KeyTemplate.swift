import AppKit
import SwiftUI

// The key template block's text. The field is AppKit, so its fonts are
// `NSFont`s; the lines under it use the shared roles (callout 12).

public enum KeyTemplateFonts {
  /// The field's text (12.5, the body face — not monospaced).
  public static let field = NSFont.systemFont(ofSize: 12.5)
  /// A token's name (`.t`: 12, weight 500).
  public static let token = NSFont.systemFont(ofSize: 12, weight: .medium)
  /// A token in a callout (`.call .t`: 11.5).
  public static let smallToken = NSFont.systemFont(ofSize: 11.5, weight: .medium)
}

extension KeyTemplateFonts {
  /// The example's path and the key card's key (11.5 / 12, monospaced);
  /// the file in each is semibold.
  public static let path = Font.system(size: 11.5, design: .monospaced)
  public static let pathFile = path.weight(.semibold)
  public static let cardKey = Font.system(size: 12, design: .monospaced)
  public static let cardKeyFile = cardKey.weight(.semibold)
}

extension View {
  /// "Key" at the capsule's start, and the ⋯ chip (10.5 / 500).
  public func pinaxKeyTemplatePillLabel() -> some View {
    font(.system(size: 10.5, weight: .medium))
  }

  /// The clock after the example (13).
  public func pinaxKeyTemplateClock() -> some View {
    font(.system(size: 13))
  }

  /// The clock's tip, the card's header and its last line, and Copy (11).
  public func pinaxKeyTemplateSmall() -> some View {
    font(.system(size: 11))
  }

  public func pinaxKeyTemplateCardHeader() -> some View {
    font(.system(size: 11, weight: .medium))
  }

  /// A callout's words (`.call`: 12) and its icon (14).
  public func pinaxKeyTemplateCallout() -> some View {
    font(.callout)
  }

  public func pinaxKeyTemplateCalloutIcon() -> some View {
    font(.system(size: 14))
  }

  /// Insert's braces (12 / 500); the popover's header (`.mh`: 11 / 500)
  /// and a row's sample value (`.mi .v`: 12, tabular).
  public func pinaxKeyTemplateInsert() -> some View {
    font(.callout.weight(.medium))
  }

  public func pinaxKeyTemplateMenuHeader() -> some View {
    font(.caption.weight(.medium))
  }

  public func pinaxKeyTemplateMenuSample() -> some View {
    font(.callout.monospacedDigit())
  }

  /// Reset to Default (`.lnk`: 12).
  public func pinaxKeyTemplateLink() -> some View {
    font(.callout)
  }
}
