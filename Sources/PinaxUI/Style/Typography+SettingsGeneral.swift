import SwiftUI

// Settings ▸ General and Gallery roles, read as the macOS text style of the
// design's size (11 → subheadline).

extension View {
  /// A source tag card's name (`.card .nm`: 11; chosen, the accent at 500).
  public func pinaxSettingsCardName(chosen: Bool) -> some View {
    font(.subheadline.weight(chosen ? .medium : .regular))
      .foregroundStyle(chosen ? PinaxPalette.Settings.chosenCard : Color.primary)
  }
}
