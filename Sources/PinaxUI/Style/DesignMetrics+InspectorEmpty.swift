import CoreGraphics

extension DesignMetrics {
  /// The inspector's empty state — a faint 28 pt glyph, a title, one hint line,
  /// 6 apart, held 28 from the sides and lifted 52 off centre.
  public enum inspectorEmpty {
    public static let glyph: CGFloat = 28
    public static let glyphOpacity: Double = 0.7
    public static let spacing: CGFloat = 6
    public static let horizontalPadding: CGFloat = 28
    public static let bottomPadding: CGFloat = 52
  }
}
