import SwiftUI

// The settings window's roles, read as the macOS text style of the design's
// size (body 13, callout 12, subheadline 11, title3 15; 11.5 reads as 11
// and 14 as 15).

extension View {
  /// The page title over the content (`.bar`: 15 semibold).
  public func pinaxSettingsPageTitle() -> some View {
    font(.title3.weight(.semibold))
  }

  /// A section's title (`.h`: 13 semibold).
  public func pinaxSettingsSectionTitle() -> some View {
    font(.body.weight(.semibold))
  }

  /// A section's note under its title (`.d`: 12, secondary).
  public func pinaxSettingsSectionNote() -> some View {
    font(.callout)
      .foregroundStyle(.secondary)
  }

  /// A row's subtitle (11.5, secondary; read as 11).
  public func pinaxSettingsRowSubtitle() -> some View {
    font(.subheadline)
      .foregroundStyle(.secondary)
  }

  /// A header card's title (`New-General` 15 semibold, `New-Projects` 14).
  public func pinaxSettingsHeaderTitle() -> some View {
    font(.title3.weight(.semibold))
  }

  /// A code chip's text (`.chip`: SF Mono 11).
  public func pinaxSettingsChip() -> some View {
    font(.system(.subheadline, design: .monospaced))
  }

  /// A status pill's words (`.pill`: 11.5).
  public func pinaxSettingsPill() -> some View {
    font(.subheadline)
  }

  /// A list column row's subtitle (`.li .sub`: 11, secondary).
  public func pinaxSettingsListSubtitle() -> some View {
    font(.subheadline)
      .foregroundStyle(.secondary)
  }
}
