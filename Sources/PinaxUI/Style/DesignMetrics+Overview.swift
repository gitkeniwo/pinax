import CoreGraphics

extension DesignMetrics {
  /// The Overview's cards. The page's margins, the cards' padding and the
  /// heat map's pitch stay `DesignMetrics.overview`'s: the heat map's
  /// layout is not to move.
  public enum overviewD {
    /// `.card` / `.grp`: corner 10, a 0.5 pt rim.
    public static let cardRadius: CGFloat = 10
    public static let rimWidth: CGFloat = 0.5
    /// The two columns under the heat map: 14 apart, side by side where two
    /// of `columnMinWidth` fit.
    public static let columnGap: CGFloat = 14
    public static let columnMinWidth: CGFloat = 320
    /// A grouped list's title over it (`.sec`, padding 0 4 5) and the room
    /// above the next one (`padding-top:10px`).
    public static let sectionTitleInset: CGFloat = DesignMetrics.spacing.xs
    public static let sectionGap: CGFloat = 10

    // MARK: Hero band

    /// A cell's padding (10 14) and the gap between its words and its bars.
    public static let heroVerticalPadding: CGFloat = 10
    public static let heroHorizontalPadding: CGFloat = 14
    public static let heroSpacing: CGFloat = 10
    public static let heroLineSpacing: CGFloat = DesignMetrics.spacing.xs
    /// The title's square (board 16, corner 4; `ColorSquare.folder` 18/5 is
    /// the nearest shared size) and its gap.
    public static let heroTitleSpacing: CGFloat = 6
    /// The mini bars: 3 wide, 2 apart, 24 high, corner 1.5; all but the
    /// highlighted one at 45 %.
    public static let sparkBarWidth: CGFloat = 3
    public static let sparkBarGap: CGFloat = 2
    public static let sparkHeight: CGFloat = 24
    public static let sparkBarRadius: CGFloat = 1.5
    public static let sparkBarMinimum: CGFloat = 1
    public static let sparkDimOpacity: Double = 0.45
    /// Used's bar, in place of the mini bars: Composition's.
    public static let ratioWidth: CGFloat = 72

    // MARK: Upload Activity (colour and legend only)

    public static let heatCellRadius: CGFloat = 3
    public static let heatLegendRadius: CGFloat = 2.5

    // MARK: Uploads chart

    public static let chartHeight: CGFloat = 104
    public static let chartSpacing: CGFloat = 6
    /// Bars other than the peak or the one under the pointer.
    public static let dimBarOpacity: Double = 0.5
    public static let averageLineWidth: CGFloat = 1.5
    public static let averageOpacity: Double = 0.7
    /// The label on the peak: corner 6, padding 3 7.
    public static let calloutRadius: CGFloat = 6
    public static let calloutVerticalPadding: CGFloat = 3
    public static let calloutHorizontalPadding: CGFloat = 7

    // MARK: Lists

    /// `.li`: 34 high, padding 0 12, gap 9 (8, the nearest step).
    public static let rowHeight: CGFloat = 34
    public static let rowPadding: CGFloat = DesignMetrics.spacing.m
    public static let rowSpacing: CGFloat = DesignMetrics.spacing.s
    /// A project's row: 42 high, a 14 pt folder.
    public static let projectRowHeight: CGFloat = 42
    public static let projectIcon: CGFloat = 14
    public static let chevron: CGFloat = 11
    /// Composition: a 56 label, a seamless 10-high bar (corner 4), 104 of
    /// figures.
    public static let compositionLabelWidth: CGFloat = 56
    public static let compositionFigureWidth: CGFloat = 104
    public static let seamHeight: CGFloat = 10
    public static let seamRadius: CGFloat = 4
  }
}
