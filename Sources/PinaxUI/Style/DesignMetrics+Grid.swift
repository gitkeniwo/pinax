import CoreGraphics

// The grid's scrim, caption, jump bar and month header numbers.
extension DesignMetrics {
  /// The metadata scrim on a thumbnail: 5 in from the left and bottom,
  /// padding 2 × 6, corner 5, black 55 %.
  public enum scrim {
    public static let inset: CGFloat = 5
    public static let horizontalPadding: CGFloat = 6
    public static let verticalPadding: CGFloat = 2
    public static let radius: CGFloat = 5
    public static let opacity: Double = 0.55
  }

  /// The caption under a thumbnail: the date's plate reaches 5 past the
  /// text on each side; its corner is `radius.chip`.
  public enum gridCaption {
    public static let datePlatePadding: CGFloat = 5
  }

  /// The jump bar: a 30 pt strip.
  public enum jumpBar {
    /// The current segment's capsule: `padding:1px 7px;border-radius:5px;
    /// background:var(--count)`.
    public static let currentVerticalPadding: CGFloat = 1
    public static let currentHorizontalPadding: CGFloat = 7
    public static let currentRadius: CGFloat = 5
    /// The grouping switch when on: `height:20px;padding:0 6px;
    /// border-radius:5px;background:var(--soft)`.
    public static let toggleHeight: CGFloat = 20
    public static let toggleHorizontalPadding: CGFloat = 6
    public static let toggleRadius: CGFloat = 5
  }
}
