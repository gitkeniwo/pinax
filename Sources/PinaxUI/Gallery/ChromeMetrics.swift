import SwiftUI

/// The one place the window's three bars — jump bar, find strip, status
/// bar — agree on their metrics. Three bars that each pick
/// their own 5/6/8 pt padding look fine one screenshot at a time and
/// amateur side by side; this enum is what makes a later tweak to one bar
/// a deliberate change to the shared contract, and `ChromeMetricsTests`
/// asserts the rendered bars actually honour it.
enum ChromeMetrics {
  /// The status bar (bottom): a read-only text strip.
  static let barHeight: CGFloat = 24
  /// The find strip and the jump bar (top chrome): control-bearing rows.
  static let stripHeight: CGFloat = 30
  /// Horizontal inset every bar's content keeps from the column edges.
  static let horizontalPadding: CGFloat = 10
  /// Every bar renders text the same way: small, secondary, tabular
  /// digits, middle truncation (keys and filenames are long in the middle).
  static func text(_ value: String) -> some View {
    Text(value)
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .lineLimit(1)
      .truncationMode(.middle)
  }
}
