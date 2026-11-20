import SwiftUI

/// Text has five roles and one error style. Views name the role; only this
/// file names a font. `ChromeMetrics.text` is the one other exception, and it
/// belongs to the bars.
extension View {
  /// Month group headers, report page titles.
  public func pinaxTitle() -> some View {
    font(.title2.weight(.semibold))
  }

  /// Small headings: inspector sections, subheadings inside settings groups.
  public func pinaxSectionTitle() -> some View {
    font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
  }

  /// Body text: filenames, row labels.
  public func pinaxBody() -> some View {
    font(.body)
  }

  /// Counts, dates, supporting text.
  public func pinaxSecondary() -> some View {
    font(.subheadline)
      .foregroundStyle(.secondary)
  }

  /// Grid captions, chip text, the status bar.
  public func pinaxCaption() -> some View {
    font(.caption)
      .foregroundStyle(.secondary)
  }

  /// Keys, digests, URLs.
  public func pinaxMono() -> some View {
    font(.system(.caption, design: .monospaced))
  }

  /// The only red in the app.
  public func pinaxError() -> some View {
    foregroundStyle(Color(nsColor: .systemRed))
  }
  // MARK: Shared roles. Design sizes, read as the macOS text style of that
  // size: subheadline is 11 pt, caption 10 pt (caption is 10 on macOS, not
  // 11).

  /// A sidebar row's name (canvas 13, weight 500).
  public func pinaxRowTitle() -> some View {
    font(.body.weight(.medium))
  }

  /// A sidebar group's title (canvas 11 semibold, tertiary grey).
  public func pinaxGroupTitle() -> some View {
    font(.subheadline.weight(.semibold))
      .foregroundStyle(.tertiary)
  }

  /// The number in a count capsule (canvas 11).
  public func pinaxCount() -> some View {
    font(.subheadline)
      .monospacedDigit()
  }

  /// A section header band's title (canvas 11.5 semibold).
  public func pinaxBandTitle() -> some View {
    font(.subheadline.weight(.semibold))
  }

  /// A stat pill's figure (canvas 13 semibold).
  public func pinaxStatFigure() -> some View {
    font(.body.weight(.semibold))
      .monospacedDigit()
  }

  /// A soft capsule's words (canvas 11.5 medium).
  public func pinaxCapsuleLabel() -> some View {
    font(.subheadline.weight(.medium))
  }

  /// The letters on a format square (canvas 8.5, weight 800).
  public func pinaxSquareLabel() -> some View {
    font(.system(size: 8.5, weight: .heavy))
  }

  /// A glyph drawn at a part's own point size.
  func pinaxGlyph(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
    font(.system(size: size, weight: weight))
  }
}
