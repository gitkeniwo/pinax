import SwiftUI

// Usage's roles, the sizes read as the macOS text style of that point size
// (body 13, callout 12, subheadline 11, caption 10).

extension View {
  /// The range bar's counts and words (canvas 11.5, `var(--fg2)`).
  public func pinaxScopeSummary() -> some View {
    font(.subheadline)
      .foregroundStyle(.secondary)
      .monospacedDigit()
  }

  /// Usage ▸ Files' sort menu label: small, bold, dark grey, the list
  /// header's quiet control.
  public func pinaxListSortLabel() -> some View {
    font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
  }

  /// The range bar's numbers (canvas 11.5 semibold, `var(--fg)`).
  public func pinaxScopeFigure() -> some View {
    font(.subheadline.weight(.semibold))
      .monospacedDigit()
  }

  /// "Old domains" (canvas 11.5, `var(--fg2)`).
  public func pinaxOutlineCapsuleLabel() -> some View {
    font(.subheadline)
      .foregroundStyle(.secondary)
  }

  /// The reference-count badge's number (canvas 10 semibold).
  public func pinaxRefsBadge() -> some View {
    font(.caption.weight(.semibold))
      .monospacedDigit()
  }

  /// A Files cell's "same as above" (canvas 10, tertiary grey).
  public func pinaxSameAsAbove() -> some View {
    font(.caption2)
      .foregroundStyle(.tertiary)
  }

  /// The file list's group header (canvas 11 semibold, `var(--fg3)`).
  public func pinaxUsageGroupHeader() -> some View {
    font(.subheadline.weight(.semibold))
      .foregroundStyle(.tertiary)
  }

  /// A file row's name (canvas 13, weight 500).
  public func pinaxUsageFileName() -> some View {
    font(.body.weight(.medium))
  }

  /// A file row's date (canvas 10.5, `var(--fg2)`; caption is 10).
  public func pinaxUsageFileDate() -> some View {
    font(.caption)
      .monospacedDigit()
  }

  /// The file header's name (canvas 13 bold).
  public func pinaxUsageHeaderName() -> some View {
    font(.body.weight(.bold))
  }

  /// The file header's "N images · N refs" (canvas 11, `var(--fg2)`).
  public func pinaxUsageHeaderDetail() -> some View {
    font(.subheadline)
      .foregroundStyle(.secondary)
      .monospacedDigit()
  }

  /// A band's trailing figure (Usage's Used In count; canvas weight 500).
  public func pinaxBandCount() -> some View {
    font(.subheadline.weight(.medium))
      .monospacedDigit()
  }
}
