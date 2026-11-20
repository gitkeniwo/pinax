import CoreGraphics

// The settings window: its frame, sidebar, icons and list column. A value
// within 1 pt of an existing tier uses the tier (noted where it does).

extension DesignMetrics.settings {
  /// The sidebar's default width: `.sb`'s 212 less a fifth.
  public static let sidebarWidth: CGFloat = 170
  /// An ordinary page's content area (780 − 212).
  public static let contentWidth: CGFloat = 568
  /// Projects / Backends: the list column (`.lst`: 210) and the detail.
  public static let listColumnWidth: CGFloat = 210
  public static let detailWidth: CGFloat = 538
  /// The hairline right of the sidebar and of a list column (`.sb`: 0.5).
  public static let columnDividerWidth: CGFloat = 0.5

  /// The window's width for a page: 568 or 748 beside the sidebar, at
  /// the sidebar's own width; the user drags the sidebar between 160 and
  /// 320 and the window widens or narrows with it (738 / 918 at the default).
  public static func windowWidth(for tab: SettingsTab, sidebar: CGFloat = sidebarWidth) -> CGFloat {
    sidebar + (tab.hasListColumn ? listColumnWidth + detailWidth : contentWidth)
  }
  public static let sidebarMinWidth: CGFloat = 160
  public static let sidebarMaxWidth: CGFloat = 320
  /// The strip astride the sidebar's edge that takes the drag.
  public static let sidebarEdgeHitWidth = DesignMetrics.spacing.s

  /// The title band over the content (`.bar`: 52 tall, 28 in, on the
  /// page's ground), which is also the window's toolbar height, so the
  /// traffic lights sit in it.
  public static let titleBarHeight: CGFloat = 52
  public static let pageInset: CGFloat = 28
  /// `.body`: 6 above the first section, 32 below the last, 24 between.
  public static let pageTopInset: CGFloat = 6
  public static let pageBottomInset: CGFloat = 32
  public static let sectionSpacing = DesignMetrics.spacing.xl

  /// Sidebar rows: a 20 pt icon, 9 to the name (tier `s`, 8), and the
  /// 10 pt gap before Drop Zone, Projects and Maintenance (`.sbgap`).
  public static let sidebarIconSize: CGFloat = 20
  public static let sidebarIconSpacing = DesignMetrics.spacing.s
  public static let sidebarGroupGap: CGFloat = 10
  /// The first row starts 52 down (`.sb` 16 + `.lights` 2 + 12 + 22); the
  /// sidebar list adds about 10 of its own above its first row.
  public static let sidebarListTopInset: CGFloat = 42

  /// A settings icon: corner radius and glyph box as fractions of its side,
  /// and how much of the glyph box the drawn glyph spans (strokes from 2.6
  /// to 17.4 of a 20 box).
  public static let iconCornerRatio: CGFloat = 0.235
  public static let iconGlyphRatio: CGFloat = 0.74
  public static let iconGlyphExtent: CGFloat = 0.74

  /// A section (`.sec`: 7 between title, note and group — tier `s`; the
  /// title and note sit 2 in from the group's edge).
  public static let sectionInnerSpacing = DesignMetrics.spacing.s
  public static let sectionTitleInset: CGFloat = 2
  /// A group (`.g`: radius 10) and its rows (`.r`: at least 40 tall,
  /// 8 × 14 in, 12 between parts; the divider starts 14 in).
  public static let groupRadius = DesignMetrics.radius.panel
  public static let groupRingWidth: CGFloat = 0.5
  public static let rowMinHeight: CGFloat = 40
  public static let rowVerticalPadding = DesignMetrics.spacing.s
  public static let rowHorizontalPadding: CGFloat = 14
  public static let rowSpacing = DesignMetrics.spacing.m
  /// `.s`: the subtitle 2 under the title.
  public static let rowSubtitleSpacing: CGFloat = 2
  public static let rowDividerWidth: CGFloat = 0.5

  /// The header card (`New-General`: 14 × 16 in, 14 to the icon, a 44 pt
  /// icon with radius 10).
  public static let headerVerticalPadding: CGFloat = 14
  public static let headerHorizontalPadding = DesignMetrics.spacing.l
  public static let headerSpacing: CGFloat = 14
  public static let headerIconSize: CGFloat = 44
  public static let headerIconRadius = DesignMetrics.radius.panel

  /// A code chip (`.chip`: 1 × 6 in, radius 5 — tier `chip`, 4).
  public static let chipVerticalPadding: CGFloat = 1
  public static let chipHorizontalPadding: CGFloat = 6
  public static let chipRadius = DesignMetrics.radius.chip

  /// A status pill (`.pill`: 2 × 8 in, 5 between dot and words — tier
  /// `xs`, 4; a 7 pt dot).
  public static let pillVerticalPadding: CGFloat = 2
  public static let pillHorizontalPadding = DesignMetrics.spacing.s
  public static let pillSpacing = DesignMetrics.spacing.xs
  public static let pillDotSize: CGFloat = 7

  /// The +/− bar under a group (`New-General`: at least 34 tall, 4 × 10
  /// in, 2 between buttons) and under a list column (`.lft`: 4 × 8 in).
  public static let addRemoveBarMinHeight: CGFloat = 34
  public static let addRemoveBarVerticalPadding = DesignMetrics.spacing.xs
  public static let addRemoveBarHorizontalPadding: CGFloat = 10
  public static let addRemoveBarSpacing: CGFloat = 2
  public static let listFooterHorizontalPadding = DesignMetrics.spacing.s

  /// A list column's rows (`.li`: 6 × 8 in, radius 7, 9 to the icon —
  /// tier `s`, 8; 2 between rows; the list 8 in; a 24 pt icon).
  public static let listPadding = DesignMetrics.spacing.s
  public static let listRowSpacing: CGFloat = 2
  public static let listRowVerticalPadding: CGFloat = 6
  public static let listRowHorizontalPadding = DesignMetrics.spacing.s
  public static let listRowIconSpacing = DesignMetrics.spacing.s
  public static let listRowRadius: CGFloat = 7
  public static let listRowIconSize: CGFloat = 24
}
