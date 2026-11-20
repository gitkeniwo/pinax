import CoreGraphics

// Settings ▸ General and Gallery. A value within 1 pt of an existing tier
// uses the tier (noted where it does).

extension DesignMetrics.settings {
  /// A section's note wraps at 480; uncapped, a long note made the Gallery
  /// page 619 wide.
  public static let sectionNoteMaxWidth: CGFloat = 480

  /// General ▸ Catalog: the database glyph (`svg` 22).
  public static let catalogIconSize: CGFloat = 22
  /// General ▸ Downloads: the folder glyph in the menu (`svg` 15).
  public static let folderIconSize: CGFloat = 15
  /// General ▸ Copying: a long template's chip stops here (`max-width: 250px`).
  public static let formatChipMaxWidth: CGFloat = 250

  /// The Copy format sheet: as wide as the other settings sheets, its
  /// fields `m` apart, the sheet `xl` in.
  public static let formatSheetSpacing = DesignMetrics.spacing.m
  public static let formatSheetPadding = DesignMetrics.spacing.xl

  /// Gallery ▸ Thumbnails: the preview row (`padding: 16`), the cell drawn
  /// at the medium tier's 132 pt, and "Preview" 14 from the right and 10
  /// from the bottom.
  public static let previewPadding = DesignMetrics.spacing.l
  public static let previewCellWidth: CGFloat = 132
  public static let previewLabelTrailing: CGFloat = 14
  public static let previewLabelBottom: CGFloat = 10

  /// Gallery ▸ Details show: "and" between the two menus (`.r` gap 12).
  public static let detailsShowSpacing = DesignMetrics.spacing.m

  /// Gallery ▸ Source tags: five cards (`grid` gap 8, 12 in), each a
  /// 46 pt sample (radius 8, a 0.5 ring, 2 when chosen) over its name 6
  /// below.
  public static let sourceCardSpacing = DesignMetrics.spacing.s
  public static let sourceCardsPadding = DesignMetrics.spacing.m
  public static let sourceCardNameSpacing: CGFloat = 6
  public static let sourceCardSampleHeight: CGFloat = 46
  public static let sourceCardRadius: CGFloat = 8
  public static let sourceCardRingWidth: CGFloat = 0.5
  public static let sourceCardSelectedRingWidth: CGFloat = 2
}
