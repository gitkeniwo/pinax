import CoreGraphics

// Settings ▸ Appearance, Drop Zone and Maintenance. A value within 1 pt of
// an existing tier uses the tier (noted where it does).

extension DesignMetrics.settings {
  /// Appearance ▸ App icon: the picker row (14 above and beside, 18 below,
  /// 18 from the Light / Dark switch to the icons).
  public static let appIconRowTopPadding: CGFloat = 14
  public static let appIconRowBottomPadding: CGFloat = 18
  public static let appIconRowSpacing: CGFloat = 18
  /// Seven columns 4 apart (`grid-template-columns: repeat(7, …)`, tier
  /// `xs`); a 52 pt tile, 3 pt inside its ring (`.ring`: radius 15, 2.5
  /// wide), its name 7 under it (tier `s`, 8) and at most 68 wide.
  public static let appIconColumns = 7
  public static let appIconColumnSpacing = DesignMetrics.spacing.xs
  public static let appIconTileSize: CGFloat = 52
  public static let appIconRingPadding: CGFloat = 3
  public static let appIconRingRadius: CGFloat = 15
  public static let appIconRingWidth = DesignMetrics.selection.ringWidth
  public static let appIconNameSpacing = DesignMetrics.spacing.s
  public static let appIconNameWidth: CGFloat = 68

  /// Drop Zone's switch card (`.r`: 12 × 14 in, a 32 pt icon) and the page
  /// dimmed under it while the switch is off (`.dim`: 45 %).
  public static let switchCardVerticalPadding = DesignMetrics.spacing.m
  public static let switchCardIconSize: CGFloat = 32
  public static let disabledOpacity: CGFloat = 0.45

  /// Position on screen: the 76 × 48 screen (radius 6, tier `thumbnail`),
  /// its 16 × 11 corners 5 in (radius 3), the row 12 above and below
  /// (tier `m`).
  public static let cornerScreenWidth: CGFloat = 76
  public static let cornerScreenHeight: CGFloat = 48
  public static let cornerScreenRadius = DesignMetrics.radius.thumbnail
  public static let cornerWidth: CGFloat = 16
  public static let cornerHeight: CGFloat = 11
  public static let cornerRadius: CGFloat = 3
  public static let cornerInset: CGFloat = 5
  public static let cornerRowVerticalPadding = DesignMetrics.spacing.m

  /// Size: two number fields with steppers, 6 apart (tier `xs`, 4 — 2 off,
  /// so 6 stays), the step one press makes, and the Reset row (34 tall).
  public static let sizeFieldSpacing: CGFloat = 6
  public static let sizeStep: Double = 10
  public static let linkRowMinHeight: CGFloat = 34

  /// Maintenance's status card (`.r`: 14 in, a 32 pt symbol) and each
  /// check's 16 pt symbol (`.ok`, `.wt`; the old `statusSymbolWidth`).
  public static let statusCardPadding: CGFloat = 14
  public static let statusCardSymbolSize: CGFloat = 32
  public static let checkSymbolSize = statusSymbolWidth

  /// A row's pop-up (the grouped form's, the user's reference shot): the
  /// value, 4 after it (tier `xs`) a 16 × 18 box (radius 5) round ⌃⌄.
  public static let popUpSpacing = DesignMetrics.spacing.xs
  public static let popUpIndicatorWidth: CGFloat = 16
  public static let popUpIndicatorHeight: CGFloat = 18
  public static let popUpIndicatorRadius: CGFloat = 5

  /// Projects ▸ Compression ▸ Quality: a small slider 140 wide, its tick
  /// marks 1 × 4 under the track, set in by half the small knob (20 wide)
  /// so each sits under the knob's center at its value; then, 8 after it
  /// (tier `s`), the percentage in a 36 wide column so the row never shifts.
  public static let qualitySliderWidth: CGFloat = 140
  public static let qualityTickInset: CGFloat = 10
  public static let qualityTickWidth: CGFloat = 1
  public static let qualityTickHeight: CGFloat = 4
  public static let qualityValueSpacing = DesignMetrics.spacing.s
  public static let qualityValueWidth: CGFloat = 36
}
