import CoreGraphics

// Usage's range bar, its file list and file header, and the grid's
// reference badge.

extension DesignMetrics {
  /// The range bar that replaced Usage's big title row (`.usageScope` in
  /// the source: `height:38px;gap:8px;padding:0 12px`).
  public enum usageScope {
    public static let height: CGFloat = 38
    public static let horizontalPadding: CGFloat = DesignMetrics.spacing.m
    public static let spacing: CGFloat = DesignMetrics.spacing.s
  }

  /// "Old domains": `height:22px;padding:0 9px;border-radius:11px;
  /// box-shadow:inset 0 0 0 1px var(--sep)`, a 12 pt glyph 5 before the
  /// words.
  public enum usageOutlineCapsule {
    public static let height: CGFloat = 22
    public static let radius: CGFloat = 11
    public static let horizontalPadding: CGFloat = 9
    public static let spacing: CGFloat = 5
    public static let lineWidth: CGFloat = 1
    public static let glyph: CGFloat = 12
  }

  /// The reference-count badge on a Usage ▸ Images cell:
  /// `right:5px;top:5px;padding:2px 6px;border-radius:5px`, a 10 pt link
  /// glyph 3 before the number.
  public enum usageRefsBadge {
    public static let inset: CGFloat = 5
    public static let horizontalPadding: CGFloat = 6
    public static let verticalPadding: CGFloat = 2
    public static let radius: CGFloat = 5
    public static let spacing: CGFloat = 3
    public static let glyph: CGFloat = 10
  }

  /// The line badge in a Used In row and under a Files grid cell:
  /// `padding:1px 6px;border-radius:5px;background:var(--count)`.
  public enum usageLineBadge {
    public static let horizontalPadding: CGFloat = 6
    public static let verticalPadding: CGFloat = 1
    public static let radius: CGFloat = 5
  }

  /// Usage ▸ Files' left list (source: `width:236px;padding:8px 6px`; a row
  /// is `height:36px;padding:0 8px;border-radius:7px`).
  public enum usageFiles {
    public static let listHorizontalPadding: CGFloat = 6
    public static let listVerticalPadding: CGFloat = DesignMetrics.spacing.s
    /// The group header: `gap:5px;padding:2px 6px 6px`.
    public static let groupSpacing: CGFloat = 5
    public static let groupTopPadding: CGFloat = 2
    public static let groupBottomPadding: CGFloat = 6
    public static let groupHorizontalPadding: CGFloat = 6
    public static let groupGlyph: CGFloat = 11
    /// A file row.
    public static let rowHeight: CGFloat = 36
    public static let rowHorizontalPadding: CGFloat = DesignMetrics.spacing.s
    public static let rowRadius: CGFloat = 7
    public static let rowSpacing: CGFloat = 2
    /// The selected row's second line: white 75 %.
    public static let selectedSecondaryOpacity: Double = 0.75
    /// The right side's file header: `height:50px;gap:10px;padding:0 12px`.
    public static let headerHeight: CGFloat = 50
    public static let headerHorizontalPadding: CGFloat = DesignMetrics.spacing.m
    public static let headerSpacing: CGFloat = 10
    /// The Open / Reveal group: a grp capsule of two 30 pt items.
    public static let actionWidth: CGFloat = 30
  }

  /// The Files grid caption's "same as above" (source: `font-size:10px;
  /// color:var(--fg3)`).
  public enum usageCaption {
    public static let sameAsAboveSpacing: CGFloat = DesignMetrics.spacing.xs
  }

  /// The file list's header, folder groups and drag handle, and Images'
  /// file strip.
  public enum usageRevision {
    /// The list's width bounds while its divider is dragged; the canvas's
    /// 236 is where it starts (`DesignMetrics.usage.filesWidth`).
    public static let listMinWidth: CGFloat = 180
    public static let listMaxWidth: CGFloat = 420
    /// The divider's hit area and the grip shown on hover
    /// (`width:9px;margin:0 -4px`; the grip `5 x 30, radius 3`).
    public static let dividerHitWidth: CGFloat = 9
    /// The divider's line: a hairline at rest, twice that while hovered or dragged.
    public static let dividerLine: CGFloat = 1
    public static let dividerLineActive: CGFloat = 2
    public static let gripWidth: CGFloat = 5
    public static let gripHeight: CGFloat = 30
    public static let gripRadius: CGFloat = 3
    /// The list's header: `height:30px;padding:0 8px 0 14px`.
    public static let listHeaderHeight: CGFloat = 30
    public static let listHeaderLeading: CGFloat = 14
    public static let listHeaderTrailing: CGFloat = DesignMetrics.spacing.s
    /// A folder group's header: `height:26px;gap:3px`, a 12 pt folder —
    /// filled open, outlined closed — and a 1px-3px plate per segment.
    public static let groupHeaderHeight: CGFloat = 26
    public static let groupSpacing: CGFloat = 3
    public static let groupGlyph: CGFloat = 12
    public static let segmentHorizontalPadding: CGFloat = 3
    public static let segmentVerticalPadding: CGFloat = 1
    public static let segmentRadius: CGFloat = 4
    /// A file row under a group: `padding-left:22px`.
    public static let rowLeadingIndent: CGFloat = 22
    /// Images' file strip: `gap:8px`, a 20 pt doc square.
    public static let stripSpacing: CGFloat = DesignMetrics.spacing.s
  }
}
