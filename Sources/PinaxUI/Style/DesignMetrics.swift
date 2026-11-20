import CoreGraphics

/// Every number a view lays out with comes from here, so that "12" means the
/// same gap everywhere and changing it is one edit.
///
/// `ChromeMetrics` stays separate: the three bars have their own contract and
/// their own tests.
public enum DesignMetrics {
  /// The only gaps allowed between stacked things.
  public enum spacing {
    /// Flush: stacked pieces that read as one (Usage's chips, a file's name
    /// over its directory).
    public static let none: CGFloat = 0
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
  }

  /// One radius per kind of rounded container.
  public enum radius {
    public static let thumbnail: CGFloat = 6
    public static let chip: CGFloat = 4
    public static let panel: CGFloat = 10
  }

  /// The asset grid.
  public enum grid {
    public static let gap: CGFloat = 8
    public static let inset: CGFloat = 16
    public static let captionSpacing: CGFloat = 4
  }

  /// The ring drawn around a selected thumbnail.
  public enum selection {
    public static let ringWidth: CGFloat = 2.5
    public static let ringGap: CGFloat = 2
    /// Derived, never written as its own number: the ring sits outside the
    /// thumbnail, so its corner grows by the gap and the stroke.
    public static var ringRadius: CGFloat {
      DesignMetrics.radius.thumbnail + ringGap + ringWidth
    }
  }

  /// The inspector column.
  public enum inspector {
    public static let padding: CGFloat = 16
    public static let sectionSpacing: CGFloat = 16
    public static let rowSpacing: CGFloat = 8
    public static let previewMaxHeight: CGFloat = 220
  }

  /// The table view mode.
  public enum table {
    /// Row-height rungs, Make Smaller to Make Bigger. The thumbnail column
    /// grows with the row.
    public static let rowHeights: [CGFloat] = [28, 36, 44, 60, 80]
    /// The row height the table had before it had rungs (measured: 44, a
    /// 36 pt thumbnail in an automatic-height row).
    public static let defaultRowHeight: CGFloat = 44
    /// Row height minus thumbnail side (measured: 44 − 36).
    public static let thumbnailInset: CGFloat = 8
    /// Added to the widest date-and-time string's width for the Uploaded
    /// column's minimum (`AssetTableView.uploadedColumnWidth`): the inset
    /// table's 17 pt intercell spacing (measured) and a little slack.
    public static let cellPadding: CGFloat = 24
  }

  /// The Settings window (widths in `DesignMetrics+SettingsWindow.swift`): the
  /// user drags the height, from 420.
  public enum settings {
    public static let minHeight: CGFloat = 420
    /// The height a new window opens at.
    public static let idealHeight: CGFloat = 1080
    /// Backends ▸ Unreferenced Objects: the import's progress bar (H44Bucket ④).
    public static let progressBarWidth: CGFloat = 180
    /// Confirmation sheets, as wide as Add Backend's.
    public static let sheetWidth: CGFloat = 420
    /// Maintenance's status symbols, one column wide so ✓ and ⚠ line up.
    public static let statusSymbolWidth: CGFloat = 16
    /// Appearance ▸ App Icon: one cell's thumbnail and the cell's width
    /// (room for a two-line name under it).
    public static let dockIconSize: CGFloat = 64
    public static let dockIconCellWidth: CGFloat = 88
    /// Drop Zone ▸ Size: the number field beside each slider ("560").
    public static let sizeFieldWidth: CGFloat = 52
  }

  /// Month headers in the grid and group headers in lists.
  /// The Add Tag… / Edit Note… popover.
  public enum contextEditor {
    public static let width: CGFloat = 260
    public static let listMaxHeight: CGFloat = 180
    public static let noteMinHeight: CGFloat = 100
  }

  /// The title area's project picker.
  public enum projectPicker {
    public static let width: CGFloat = 300
    public static let listMaxHeight: CGFloat = 320
    /// The project line's gaps: symbol, name, chevron.
    public static let chevronSpacing: CGFloat = DesignMetrics.spacing.xs
    /// The title over its project line, a row's name over its detail, the
    /// rows of a section and the footer's buttons: flush, like Xcode's.
    public static let stackSpacing: CGFloat = 0
  }

  public enum sectionHeader {
    public static let height: CGFloat = 36
  }

  /// The restore confirmation and Catalog Restored sheets.
  public enum backupSheet {
    public static let width: CGFloat = 440
  }

  /// Usage ▸ Files: the file list's fixed width beside the images.
  public enum usage {
    public static let filesWidth: CGFloat = 236
  }

  /// Externals' tiles; the table's rows are in `DesignMetrics+Externals.swift`.
  public enum externals {
    public static let tileAspectRatio: CGFloat = 156.0 / 112.0
    /// The exception badge, a filled circle
    /// in the tile's top-right corner, and its inset (the library's
    /// corner-label inset).
    public static let badgeSize: CGFloat = 20
    public static let badgeInset: CGFloat = 6
    public static let badgeShadowRadius: CGFloat = 1
    /// A tile whose image the batch has imported, until the batch ends.
    public static let importedOpacity: Double = 0.42
    /// The status bar's import progress bar.
    public static let importProgressWidth: CGFloat = 140
    /// The ⓘ popover's width.
    public static let infoWidth: CGFloat = 300
  }

  /// Overview: Health's cards on a grouped page — the one page that draws
  /// content on cards.
  public enum overview {
    public static let cardRadius: CGFloat = 12
    public static let cardVerticalPadding: CGFloat = 14
    public static let cardHorizontalPadding: CGFloat = 16
    public static let pageMaxWidth: CGFloat = 1240
    /// A heat-map day's pitch — cell plus gap — grows with the card from
    /// the minimum (GitHub's 11 + 3) to the maximum; the gap stays.
    public static let heatMinPitch: CGFloat = 14
    public static let heatMaxPitch: CGFloat = 22
    public static let heatGap: CGFloat = 3
    /// The Mon / Wed / Fri column left of the cells.
    public static let heatWeekdayWidth: CGFloat = 32
    public static let heatLegendCell: CGFloat = 10
    public static let uploadsChartHeight: CGFloat = 220
    public static let periodPickerWidth: CGFloat = 420
    public static let barCornerRadius: CGFloat = 4
    /// The average's dashed rule.
    public static let averageLineWidth: CGFloat = 1
    public static let averageLineDash: [CGFloat] = [4, 3]
    /// A day outside the period chosen below.
    public static let fadedOpacity: Double = 0.35
    /// The bars around the one under the pointer.
    public static let unselectedBarOpacity: Double = 0.35
    /// The small cards: four to a row where four of this width fit, else
    /// two, else one; a sparkline at their bottom right.
    public static let metricMinWidth: CGFloat = 160
    public static let sparklineWidth: CGFloat = 72
    public static let sparklineHeight: CGFloat = 28
    /// A horizontal bar row: name, bar, figures. The name and figure
    /// columns are 120 where there is room and give way down to 96, so a
    /// row fits the centre column's minimum (`GalleryWidthBudget.detailMin`);
    /// the bar column takes what is left.
    public static let barThickness: CGFloat = 8
    public static let barLabelWidth: CGFloat = 120
    public static let barFigureWidth: CGFloat = 120
    public static let barColumnMinWidth: CGFloat = 96
    /// By Kind or By Backend with its bars still readable; two of them and
    /// the gap must fit for the two to sit side by side.
    public static let breakdownSectionMinWidth: CGFloat = 320
  }

  /// The drop zone panel.
  public enum dropZone {
    /// The panel's own glass shape and its 1 pt highlight rim.
    public static let panelRadius: CGFloat = 22
    public static let rimWidth: CGFloat = 1
    /// The space between the panel's edge and its header and content.
    public static let panelInset: CGFloat = 12
    /// List: a card's thumbnail, its rounding, the card's own
    /// rounding, inner padding and the gap between thumbnail and text.
    public static let thumbnail: CGFloat = 54
    public static let thumbnailRadius: CGFloat = 9
    public static let cardRadius: CGFloat = 14
    public static let cardPadding: CGFloat = 10
    public static let cardGap: CGFloat = 10
    /// Shelf: two columns of 112 pt thumbnails.
    public static let shelfColumnGap: CGFloat = 12
    public static let shelfRowGap: CGFloat = 10
    public static let shelfThumbnail: CGFloat = 112
    public static let shelfThumbnailRadius: CGFloat = 12
    /// The gap between a card's text lines (canvas 3 pt).
    public static let textSpacing: CGFloat = 3
    /// The gap between the meta text and the project token.
    public static let metaSpacing: CGFloat = 6
    /// Icon buttons (header and card): 30 × 28 with a 7 pt hover ground,
    /// set 2 pt apart; the card's row starts 6 pt left so the first
    /// symbol lines up with the text above it.
    public static let iconButtonWidth: CGFloat = 30
    public static let iconButtonHeight: CGFloat = 28
    public static let iconButtonRadius: CGFloat = 7
    public static let iconButtonGap: CGFloat = 2
    public static let actionRowLead: CGFloat = 6
    /// The header's framed project pill.
    public static let pillHeight: CGFloat = 30
    /// The header's row: the pill's height, so the content area below it is
    /// the same whether or not the header floats over a drag's scrim.
    public static let headerHeight: CGFloat = 30
    public static let pillRadius: CGFloat = 9
    public static let pillPadding: CGFloat = 10
    /// The project token on a card: 1 pt high padding, 6 pt across.
    public static let tokenRadius: CGFloat = 6
    public static let tokenPaddingV: CGFloat = 1
    public static let tokenPaddingH: CGFloat = 6
    public static let tokenGap: CGFloat = 3
    /// The status layer: the upload ring sits 3 pt outside the image, 2.4 pt
    /// wide; the "already in library" copy sits 4 pt up and right. The
    /// status layer never reaches further out than `statusOutset`.
    public static let ringWidth: CGFloat = 2.4
    /// The ring's path, outside the image: its stroke's outer edge lands
    /// on `statusOutset`.
    public static var ringOutset: CGFloat { statusOutset - ringWidth / 2 }
    /// How far the ring's stroke reaches past the image.
    public static var ringReach: CGFloat { ringOutset + ringWidth / 2 }
    public static let dedupeOffset: CGFloat = 4
    public static let statusOutset: CGFloat = 4
    public static let dedupeCopyOpacity: Double = 0.38
    public static let paperRingWidth: CGFloat = 2
    public static let pendingImageOpacity: Double = 0.78
    public static let failedImageBrightness: Double = -0.22
    /// The glass retry knob over a failed image, List and Shelf.
    public static let knobList: CGFloat = 20
    public static let knobShelf: CGFloat = 40
    public static let knobScrim: Double = 0.45
    /// Shelf: the hover action bar floats 6 pt inside the image's bottom.
    public static let shelfBarInset: CGFloat = 6
    public static let shelfBarPadding: CGFloat = 3
    public static let shelfBarRadius: CGFloat = 10
    public static let shelfBarButtonWidth: CGFloat = 28
    public static let shelfBarButtonHeight: CGFloat = 24
    public static let shelfBarScrim: Double = 0.5
    /// A card's hairline rim and its shadow at rest (canvas v4: 0 1 3) and
    /// hovered (0 6 18): radius and drop.
    public static let cardRimWidth: CGFloat = 0.5
    public static let cardShadowRadius: CGFloat = 1.5
    public static let cardShadowOffset: CGFloat = 1
    public static let cardHoverShadowRadius: CGFloat = 9
    public static let cardHoverShadowOffset: CGFloat = 6
    /// The panel's bottom-right resize grip.
    public static let gripSize: CGFloat = 16
    public static let gripInset: CGFloat = 4
    public static let gripLine: CGFloat = 1
    /// The viewfinder: four rounded corner brackets just inside the content
    /// area in the illustration's ink, the same under a drag.
    public static let bracketLength: CGFloat = 30
    public static let bracketWidth: CGFloat = 2
    public static let bracketRadius: CGFloat = 14
    public static let bracketInset: CGFloat = 6
    /// The box illustration: drawn in a 150 × 118 box with a
    /// 1.6 pt line; the words sit 14 below it.
    public static let illustrationWidth: CGFloat = 150
    public static let illustrationHeight: CGFloat = 118
    public static let illustrationLine: CGFloat = 1.6
    public static let illustrationGap: CGFloat = 14
    /// Under a drag, what is already there blurs and fades behind a wash.
    public static let dragBlur: CGFloat = 8
    public static let dragSaturation: Double = 1.1
    public static let dragContentOpacity: Double = 0.5
    /// The photo stack: up to three cards fanned in a 150 × 130 box, each
    /// with a white border and a soft shadow, and the count on an accent
    /// badge at the bottom right.
    public static let stackWidth: CGFloat = 150
    public static let stackHeight: CGFloat = 130
    public static let stackCardWidth: CGFloat = 96
    public static let stackCardHeight: CGFloat = 76
    public static let stackCardRadius: CGFloat = 12
    public static let stackCardBorder: CGFloat = 3
    public static let stackShadowRadius: CGFloat = 10
    public static let stackShadowOffset: CGFloat = 8
    public static let stackShadowOpacity: Double = 0.18
    public static let badgeSize: CGFloat = 44
    public static let badgeBorder: CGFloat = 3
    public static let badgeTrailing: CGFloat = 6
    public static let badgeBottom: CGFloat = 4
    /// The hover preview (modelled on Clop's): a fixed share of
    /// the panel's width, a radius clearly larger than `radius.panel`, a
    /// soft wide shadow, and a slightly see-through image.
    public static let previewWidthFraction: CGFloat = 0.45
    public static let previewRadius: CGFloat = 18
    public static let previewShadowRadius: CGFloat = 16
    public static let previewShadowOffset: CGFloat = 6
    public static let previewShadowOpacity: Double = 0.45
    public static let previewOpacity: Double = 0.92
    /// Clearance between the preview and the pointer, and between the
    /// preview and the panel's edge (the shadow must not be cut off there).
    public static let previewPointerGap: CGFloat = 12
    public static let previewEdgeInset: CGFloat = 16
  }

  /// The menu bar panel's statistics card and Library page.
  public enum menuBarLibrary {
    /// The panel: its inset and the gap between blocks;
    /// the Library page's gap.
    public static let panelPadding: CGFloat = 10
    public static let homeSpacing: CGFloat = 10
    public static let pageSpacing: CGFloat = 12
    /// The header: the gap between its items, the project pill.
    public static let headerSpacing: CGFloat = 8
    public static let headerInset: CGFloat = 2
    public static let pillHeight: CGFloat = 22
    public static let pillRadius: CGFloat = 6
    public static let pillHorizontalPadding: CGFloat = 7
    public static let pillSpacing: CGFloat = 5
    /// The rows under the divider: Drop Zone While Dragging, Show Drop
    /// Zone, Quit Pinax; the divider's inset.
    public static let footerRowHeight: CGFloat = 26
    public static let footerRowPadding: CGFloat = 6
    public static let footerDividerInset: CGFloat = 4
    /// A number over its label, in the card and on the page.
    public static let labelSpacing: CGFloat = 1
    public static let cellHorizontalPadding: CGFloat = 10
    public static let cellVerticalPadding: CGFloat = 8
    /// The card's strip of bars: its height and its insets.
    public static let cardBarsHeight: CGFloat = 22
    public static let cardBarsTop: CGFloat = 6
    public static let cardBarsBottom: CGFloat = 7
    /// The column on the right with the ›.
    public static let chevronColumnWidth: CGFloat = 30
    /// Between the card's bars, and the page's.
    public static let barSpacing: CGFloat = 3
    public static let pageBarSpacing: CGFloat = 4
    /// The cards' corner, as a Control Center module's (continuous).
    public static let cardRadius: CGFloat = 14
    /// The card's open / close (a Control Center module opening), one
    /// spring each way: opening does not overshoot (the window's edge would
    /// cut the bounce off and leave only the content wobbling); closing
    /// settles with a slight bounce onto the card.
    public static let expandResponse: Double = 0.34
    public static let expandDamping: Double = 1.0
    public static let collapseResponse: Double = 0.36
    public static let collapseDamping: Double = 0.86
    /// The platter's corner once it fills the panel: the card's, so the
    /// Library page at rest looks as it always has.
    public static let panelRadius: CGFloat = 14
    /// Where along the open (0 = home, 1 = Library) each part changes: the
    /// platter's outline fades out by `borderFadeEnd`; the card's numbers,
    /// bars and › by `cardFadeEnd`; the rest of the home page fades by
    /// `homeFadeEnd` and shrinks to `homeShrunkScale` by `homeScaleEnd`;
    /// the Library page fades in from `libraryFadeStart` to `libraryFadeEnd`.
    public static let borderFadeEnd: Double = 0.4
    public static let cardFadeEnd: Double = 0.25
    public static let homeFadeEnd: Double = 0.3
    public static let homeScaleEnd: Double = 0.5
    public static let homeShrunkScale: CGFloat = 0.96
    public static let libraryFadeStart: Double = 0.3
    public static let libraryFadeEnd: Double = 0.8
    /// With Reduce Motion: a plain cross-fade, the platter not moving.
    public static let fadeDuration: Double = 0.18
    public static let barRadius: CGFloat = 2
    /// A bar with no uploads: a short stub, not a hairline.
    public static let barMinHeight: CGFloat = 3
    /// The page's UPLOADS · 14 DAYS bars.
    public static let pageBarsHeight: CGFloat = 48
    public static let bigNumberSpacing: CGFloat = 22
    /// The backend bar: its height, the gap between segments, the legend.
    public static let backendBarHeight: CGFloat = 8
    public static let backendGap: CGFloat = 2
    public static let legendSpacing: CGFloat = 14
    public static let legendSwatchSpacing: CGFloat = 5
    public static let legendSwatch: CGFloat = 8
    /// A Needs attention row.
    public static let rowHeight: CGFloat = 30
    public static let rowSpacing: CGFloat = 9
    public static let rowDot: CGFloat = 7
    public static let listSpacing: CGFloat = 2
  }
  // MARK: Shared parts

  /// Sidebar rows.
  public enum sidebarRow {
    public static let height: CGFloat = 30
    /// What the sidebar List adds above and below a row's content
    /// (measured on the hosted sidebar, macOS 15: content 30 gave a 38 pt
    /// pitch, content 20 a 28 pt one).
    public static let listVerticalInset: CGFloat = 8
    /// The row content's height that makes the pitch `height`.
    public static var contentHeight: CGFloat { height - listVerticalInset }
    /// The gap between the colour square and the name (canvas 8).
    public static let iconSpacing: CGFloat = DesignMetrics.spacing.s
    /// The selected row's solid ground and the 1 pt white rim on its square.
    public static let selectionRadius: CGFloat = 7
    /// The plate's inset from the sidebar's edges (the canvas list's
    /// `padding:8px`).
    public static let selectionInset: CGFloat = DesignMetrics.spacing.s
    public static let selectedRimWidth: CGFloat = 1
    public static let selectedRimOpacity: Double = 0.55
  }

  /// Colour squares: a white glyph or letters on a token colour. One size
  /// per place the canvas draws one.
  public enum colorSquare {
    /// Sidebar rows: 20, corner 5, a 13 pt glyph.
    public static let sidebar: CGFloat = 20
    public static let sidebarRadius: CGFloat = 5
    public static let sidebarGlyph: CGFloat = 13
    /// Catalog folder rows and the inspector's project letter: 18, corner 5.
    public static let folder: CGFloat = 18
    public static let folderRadius: CGFloat = 5
    public static let folderGlyph: CGFloat = 12
    /// The inspector header's format square: 28, corner 7.
    public static let header: CGFloat = 28
    public static let headerRadius: CGFloat = 7
    /// A grid caption's source square: 13, corner 3.5.
    public static let caption: CGFloat = 13
    public static let captionRadius: CGFloat = 3.5
    public static let captionGlyph: CGFloat = 9
  }

  /// Count capsules ("169"): 1 pt high padding, 6 across, fully round.
  public enum countCapsule {
    public static let verticalPadding: CGFloat = 1
    public static let horizontalPadding: CGFloat = 6
    /// The capsule on a selected row: white at 22 %.
    public static let onAccentOpacity: Double = 0.22
  }

  /// Control groups in the toolbar: a 26 pt grp ground, corner 7, its
  /// items split by 1 × 14 rules.
  public enum controlGroup {
    public static let height: CGFloat = 26
    public static let radius: CGFloat = 7
    /// Canvas 9 and 8: within 1 pt of the spacing rungs, so the rungs.
    public static let horizontalPadding: CGFloat = DesignMetrics.spacing.s
    public static let itemSpacing: CGFloat = DesignMetrics.spacing.s
    public static let dividerWidth: CGFloat = 1
    public static let dividerHeight: CGFloat = 14
  }

  /// The inspector's section header band: 22 high, corner 5, a 10 pt
  /// chevron 5 pt before the title.
  public enum band {
    public static let height: CGFloat = 22
    public static let radius: CGFloat = 5
    public static let horizontalPadding: CGFloat = 6
    /// Canvas 5: the xs rung.
    public static let spacing: CGFloat = DesignMetrics.spacing.xs
    public static let chevron: CGFloat = 10
  }

  /// Icon buttons (copy / download / open): 26 × 22 on grp, corner 6,
  /// a 14 pt symbol, 4 apart.
  public enum iconButton {
    public static let width: CGFloat = 26
    public static let height: CGFloat = 22
    public static let radius: CGFloat = 6
    public static let symbol: CGFloat = 14
    public static let spacing: CGFloat = DesignMetrics.spacing.xs
  }

  /// Stat pills (size, dimensions): 28 high, corner 7, a 13 pt icon.
  public enum statPill {
    public static let height: CGFloat = 28
    public static let radius: CGFloat = 7
    public static let horizontalPadding: CGFloat = 8
    public static let spacing: CGFloat = 6
    public static let icon: CGFloat = 13
    /// The ground's opacity over the hue, light / dark.
    public static let lightGround: Double = 0.15
    public static let darkGround: Double = 0.20
  }

  /// Soft grounds (accent at 16 % / 22 %): the navigator switcher's
  /// selected quarter, and the range bars' status capsule.
  public enum soft {
    public static let plateHeight: CGFloat = 22
    public static let plateRadius: CGFloat = 6
    public static let capsuleHeight: CGFloat = 22
    /// Canvas 9: the s rung.
    public static let capsuleHorizontalPadding: CGFloat = DesignMetrics.spacing.s
  }

  /// The navigator switcher row: 8 pt in from the sidebar's edges, its
  /// quarters 4 apart.
  public enum navigatorSwitcher {
    public static let horizontalPadding: CGFloat = DesignMetrics.spacing.s
    public static let spacing: CGFloat = DesignMetrics.spacing.xs
  }
}
