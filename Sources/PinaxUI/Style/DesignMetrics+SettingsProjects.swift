import CoreGraphics

// Settings ▸ Projects and Backends. A value within 1 pt of an existing tier
// uses the tier (noted where it does).

extension DesignMetrics.settings {
  /// Projects ▸ Storage: the Key prefix field, 300 wide. Focused, it draws a
  /// 1.5 ring in the teal (half the system ring's 3) on its rounded border's 5
  /// corner.
  public static let keyPrefixFieldWidth: CGFloat = 300
  public static let keyPrefixFocusRingWidth: CGFloat = 1.5
  public static let keyPrefixFieldRadius: CGFloat = 5
  /// Projects ▸ Sources: a source's folder glyph (`svg` 18) and "Scanned …"
  /// 8 before Scan Now (`margin-right: 8`, tier `s`).
  public static let sourceFolderIconSize: CGFloat = 18
  public static let scanStatusSpacing = DesignMetrics.spacing.s
  /// A source's fields under it (Label, Include, Exclude): the fields'
  /// labels in a column (`Example` / `Insert` in the key template block:
  /// 64 wide) and the fields `s` apart.
  public static let sourceFieldLabelWidth: CGFloat = 64
  public static let sourceFieldSpacing = DesignMetrics.spacing.s
  /// A command source's row: "in <folder>" at most this wide, cut in the
  /// middle; `s` between the sources' group and the automation one.
  public static let sourceRunsInMaxWidth: CGFloat = 170
  public static let sourceGroupSpacing = DesignMetrics.spacing.s
  /// A test run's symbol and its words.
  public static let commandTestSpacing: CGFloat = 6
  /// The command confirmation: 440 wide; a command too long for the sheet
  /// scrolls inside this height. Its card: 10 in, 12 at the sides, the two
  /// lines `xs` apart, a 10 corner.
  public static let commandSheetWidth: CGFloat = 440
  public static let commandSheetCommandMaxHeight: CGFloat = 240
  public static let commandCardVerticalPadding: CGFloat = 10
  public static let commandCardHorizontalPadding = DesignMetrics.spacing.m
  public static let commandCardRadius: CGFloat = 10

  /// Backends ▸ Connection: the copy glyph (`svg` 14, the button 2 × 4 in —
  /// tiers `xs` both ways, 2 off → 4 kept as `xs` for the side only).
  public static let copyIconSize: CGFloat = 14
  /// The Endpoint's host at most this wide, cut in the middle, so the
  /// row's title keeps its width.
  public static let endpointValueMaxWidth: CGFloat = 240
  /// Public URL: the new prefix's field while Change… is open.
  public static let urlPrefixFieldWidth: CGFloat = 260
  /// A tool's results under its row (the old Form's result lists), `xs`
  /// between lines.
  public static let toolResultSpacing = DesignMetrics.spacing.xs
}

// The list column as a floating island, on Projects and Backends. The row
// icon and the footer's + sit on the page title's left edge:
// 12 + 8 + 8 = 12 + 16 = `pageInset` (28).

extension DesignMetrics.settings {
  /// The island's width: 196 at first, dragged between 160 and 280.
  public static let islandDefaultWidth: CGFloat = 196
  public static let islandMinWidth: CGFloat = 160
  public static let islandMaxWidth: CGFloat = 280
  /// Its margins: 12 left and below, the detail's top inset above (so its
  /// top meets the header card's), 16 to the detail.
  public static let islandLeadingInset: CGFloat = 12
  public static let islandBottomInset: CGFloat = 12
  public static let islandTopInset = pageTopInset
  public static let islandDetailGap: CGFloat = 16
  /// Its corner and the hairline inside its edge.
  public static let islandRadius: CGFloat = 12
  public static let islandRingWidth: CGFloat = 0.5
  /// Inside: 8 round the rows; rows 38 high, 2 apart, 8 in at the sides,
  /// the selection's corner 6.
  public static let islandPadding: CGFloat = 8
  public static let islandRowHeight: CGFloat = 38
  public static let islandRowSpacing: CGFloat = 2
  public static let islandRowHorizontalPadding: CGFloat = 8
  public static let islandRowRadius: CGFloat = 6
  /// The footer: 28 high under a 0.5 line, + 16 in from the island's edge.
  public static let islandFooterHeight: CGFloat = 28
  public static let islandFooterLeadingPadding: CGFloat = 16
  /// The strip astride the island's right edge that drags its width.
  public static let islandResizeHitWidth: CGFloat = 10
}
