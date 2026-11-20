import SwiftUI

// Settings ▸ Appearance, Drop Zone and Maintenance roles, read as the macOS
// text style of the design's size.

extension View {
  /// An app icon's name under its tile (`.opt span`: 11; the chosen one
  /// medium).
  public func pinaxSettingsIconName(selected: Bool) -> some View {
    font(.subheadline.weight(selected ? .medium : .regular))
  }

  /// A value at a row's trailing end, and the words beside a control
  /// (`.v`: 12, secondary).
  public func pinaxSettingsValue() -> some View {
    font(.callout)
      .foregroundStyle(.secondary)
  }

  /// A link-styled button in a row (`.lnk`: 12).
  public func pinaxSettingsLink() -> some View {
    font(.callout)
  }

  /// A row pop-up's ⌃⌄ (the grouped form's: 10, semibold).
  public func pinaxSettingsPopUpChevron() -> some View {
    font(.system(size: 10, weight: .semibold))
  }
}
