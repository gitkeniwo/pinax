import SwiftUI

// The inspector's roles, its sizes read as the macOS text style of that
// size (body 13, callout 12, subheadline 11, caption 10).
extension View {
  /// The inspector header's file name (canvas 13.5 bold: body, within 1 pt).
  public func pinaxInspectorTitle() -> some View {
    font(.body.weight(.bold))
  }

  /// A band's key ("Source:", canvas 12, secondary grey).
  public func pinaxFieldKey() -> some View {
    font(.callout)
      .foregroundStyle(.secondary)
  }

  /// A band's value (canvas 12).
  public func pinaxFieldValue() -> some View {
    font(.callout)
  }

  /// The link's file name (canvas 12, weight 500).
  public func pinaxLinkName() -> some View {
    font(.callout.weight(.medium))
  }

  /// The link's "host › path" (canvas 11, tertiary grey).
  public func pinaxLinkPath() -> some View {
    font(.subheadline)
      .foregroundStyle(.tertiary)
  }

  /// The format pop-up's name (canvas 11.5).
  public func pinaxPopupLabel() -> some View {
    font(.subheadline)
  }

  /// A footnote under a band's rows (canvas 10.5, tertiary grey).
  public func pinaxFootnote() -> some View {
    font(.caption)
      .foregroundStyle(.tertiary)
  }

  /// "+ Add tag…" (canvas 11.5: subheadline, within 1 pt).
  public func pinaxTagField() -> some View {
    font(.subheadline)
  }
}
