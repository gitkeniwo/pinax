import SwiftUI

// The grid's text roles, sizes read as the macOS text style of that point
// size: caption is 10 pt, title2 17 pt.
extension View {
  /// The metadata scrim's words (10 pt, weight 600, white).
  public func pinaxScrimLabel() -> some View {
    font(.caption.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(.white)
  }

  /// A month header's month (17 pt bold).
  public func pinaxMonthTitle() -> some View {
    font(.title2.weight(.bold))
  }

  /// A month header's year (17 pt, tertiary).
  public func pinaxMonthYear() -> some View {
    font(.title2)
      .foregroundStyle(.tertiary)
  }

  /// The jump bar's current segment (weight 500, primary),
  /// at the bar's own size (`ChromeMetrics.text`).
  public func pinaxBarCurrent() -> some View {
    font(.caption.weight(.medium))
      .foregroundStyle(.primary)
      .monospacedDigit()
  }
}
