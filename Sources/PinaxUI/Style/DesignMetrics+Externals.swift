import CoreGraphics

// The Externals table and its inspector.

extension DesignMetrics {
  /// The Externals table: the scope bar, its header, a domain row and a
  /// reference row. The numbers are the canvas's inline CSS values.
  public enum externalsTable {
    // MARK: Scope bar

    /// `height:38px;padding:0 12px;gap:8px`.
    public static let scopeHeight: CGFloat = 38
    public static let scopeHorizontalPadding: CGFloat = DesignMetrics.spacing.m
    public static let scopeSpacing: CGFloat = DesignMetrics.spacing.s
    /// The segmented control: a `grp` capsule with 2 pt of padding; each
    /// segment 2 × 10 with 5 between the name and its count.
    public static let segmentGroupRadius: CGFloat = 7
    public static let segmentPadding: CGFloat = 2
    public static let segmentHorizontalPadding: CGFloat = 10
    public static let segmentVerticalPadding: CGFloat = 2
    public static let segmentRadius: CGFloat = 5
    public static let segmentSpacing: CGFloat = 5
    /// The active segment's plate (`var(--seg)`) and its hairline shadow.
    public static let segmentHairline: CGFloat = 0.5
    public static let segmentShadowRadius: CGFloat = 1
    public static let segmentShadowOpacity: Double = 0.06

    // MARK: Header and rows

    /// The column header: 26 high, 11 pt, `padding:0 16px 0 44px`.
    public static let headerHeight: CGFloat = 26
    public static let headerLeading: CGFloat = 44
    public static let headerTrailing: CGFloat = DesignMetrics.spacing.l
    public static let headerSpacing: CGFloat = 10
    /// A domain row: 34 high, `padding:0 8px`, 8 between the square and the
    /// name; the count capsule is 34 wide, 11 pt tabular.
    public static let hostRowHeight: CGFloat = 34
    public static let hostSpacing: CGFloat = DesignMetrics.spacing.s
    public static let rowLeading: CGFloat = DesignMetrics.spacing.s
    public static let rowTrailing: CGFloat = DesignMetrics.spacing.s
    public static let countWidth: CGFloat = 34
    /// A reference row: 38 high, content starts 36 in (the tree line's
    /// elbow stops 3 before the 28 pt placeholder), 10 between items.
    public static let childRowHeight: CGFloat = 38
    public static let childLeading: CGFloat = 36
    public static let childSpacing: CGFloat = 10
    /// The four columns after Host: Used In 176, Kind 34, Refs 34.
    public static let usedInWidth: CGFloat = 176
    public static let usedInSpacing: CGFloat = 5
    public static let kindWidth: CGFloat = 34
    public static let refsWidth: CGFloat = 34
    /// Size, between Kind and Refs — "999.9 MB" with its
    /// large dot; the large dot 6, 4 before the figure.
    public static let sizeWidth: CGFloat = 64
    public static let largeDot: CGFloat = 6
    public static let largeDotSpacing: CGFloat = 4
    /// The selected reference row: `border-radius:7px;background:var(--accentFill)`.
    public static let selectionRadius: CGFloat = 7
    public static let selectionInset: CGFloat = DesignMetrics.spacing.s

    // MARK: Domain square and tree lines

    /// The domain's letter square: 20 × 20, corner 5 (`tile`), at the row's
    /// leading 8. Closed, a second square of its colour sits 3 right and 3
    /// up at 58 % light / 62 % dark; the front wears a 1.5 ring of the
    /// window's ground.
    public static let hostSquareSide: CGFloat = 20
    public static let hostSquareRadius: CGFloat = 5
    public static let hostStackOffset: CGFloat = 3
    public static let hostStackOpacityLight: Double = 0.58
    public static let hostStackOpacityDark: Double = 0.62
    public static let hostStackRing: CGFloat = 1.5
    /// The tree line: from the domain square's bottom middle (x = 17) to
    /// the child row's middle, an arc of 7, then right, stopping 3 before
    /// the 28 pt placeholder; 1.5 solid `--tree`.
    public static let treeX: CGFloat = 17
    public static let treeGap: CGFloat = 3
    public static let treeRadius: CGFloat = 7
    public static let treeLineWidth: CGFloat = 1.5
    /// The parent square's bottom sits 7 above the first child row's top
    /// (the canvas's `top:-7px`).
    public static let treeFirstRise: CGFloat = 7

    // MARK: Reference row parts

    /// The placeholder: 28 × 28, corner 6, a 1.5 dashed outline.
    public static let thumbnail: CGFloat = 28
    public static let thumbnailRadius: CGFloat = 6
    public static let placeholderStroke: CGFloat = 1.5
    public static let placeholderDash: CGFloat = 3
    /// The line capsule ("L18"): 30 wide, centred, corner 4, 10.5 pt tabular.
    public static let lineCapsuleWidth: CGFloat = 30
    public static let lineCapsuleRadius: CGFloat = 4
    public static let lineCapsuleVerticalPadding: CGFloat = 1
    /// The second line's path size (canvas 10.5).
    public static let pathSize: CGFloat = 10.5
    /// The Kind mark (canvas 9.5, 700).
    public static let kindSize: CGFloat = 9.5
  }

  /// The Externals inspector: a 130 pt preview with a lock
  /// placeholder and one "Load preview" button, then Link → Used In →
  /// Details as `band` sections.
  public enum externalsInspector {
    /// Hosts' count column, after the size column.
    public static let hostCountWidth: CGFloat = 16
    public static let previewHeight: CGFloat = 130
    public static let previewRadius: CGFloat = DesignMetrics.inspector.previewRadius
    public static let lockGlyph: CGFloat = 22
    public static let previewSpacing: CGFloat = 7
    /// The button: 22 high, corner 6, 10 across, a 12 pt glyph 5 before
    /// the words.
    public static let loadHeight: CGFloat = 22
    public static let loadRadius: CGFloat = 6
    public static let loadHorizontalPadding: CGFloat = 10
    public static let loadSpacing: CGFloat = 5
    public static let loadGlyph: CGFloat = 12
    /// The button's 0.5 pt line (`box-shadow:0 0 0 .5px var(--fieldline)`).
    public static let loadLineWidth: CGFloat = 0.5
    /// The sections' rows: 8 below a band, 2 across.
    public static let rowTopPadding: CGFloat = DesignMetrics.spacing.s
    public static let rowHorizontalPadding: CGFloat = 2
    /// A Used In row: a 13 pt document glyph 7 before the file.
    public static let usedInSpacing: CGFloat = 7
    public static let usedInGlyph: CGFloat = 13
    /// The Remote row's dot (canvas 7).
    public static let remoteDot: CGFloat = 7
    public static let remoteDotSpacing: CGFloat = 5
  }

  /// The library table's thumbnail: rounded, with its format block.
  public enum assetTable {
    public static let thumbnailRadius: CGFloat = DesignMetrics.radius.thumbnail
    /// The format block on the thumbnail's trailing bottom corner: the
    /// grid caption's 13 pt square.
    public static let formatBlock: CGFloat = DesignMetrics.colorSquare.caption
    public static let formatBlockRadius: CGFloat = DesignMetrics.colorSquare.captionRadius
    public static let formatBlockInset: CGFloat = 2
    public static let formatBlockLineWidth: CGFloat = 0.5
    /// The selected row's own radius (the canvas's 7) and the plate's inset
    /// from the row: 4 across, 2 top and bottom, as the inset table style
    /// draws its own.
    public static let selectedRadius: CGFloat = 7
    public static let selectionInset: CGFloat = 4
    public static let selectionVerticalInset: CGFloat = 2
    /// Secondary text on a selected row: white at 75 %.
    public static let selectedSecondaryOpacity: Double = 0.75
  }
}
