import CoreGraphics

// The Key template block under Key prefix. A value within 1 pt of an
// existing tier uses the tier (noted where it does).

extension DesignMetrics.settings {
  /// The field (`.fld`): as wide as Key prefix's, 24 high, text 3 in.
  public static let keyTemplateFieldWidth = keyPrefixFieldWidth
  public static let keyTemplateFieldHeight: CGFloat = 24
  public static let keyTemplateFieldInset: CGFloat = 3
  /// Its rings: the teal when focused, red with an error, as Key prefix's.
  public static let keyTemplateRingWidth = keyPrefixFocusRingWidth
  public static let keyTemplateFieldRadius = keyPrefixFieldRadius
  /// The field's resting edge (`.fld`: inset 0.5 black 20 %).
  public static let keyTemplateFieldBorderWidth: CGFloat = 0.5

  /// A token (`.t`): 18 high, corner 4, 5 in at the sides, 2 between two
  /// (1 each side; 1 to a literal, `.lit`'s margin).
  public static let keyTemplateTokenHeight: CGFloat = 18
  public static let keyTemplateTokenRadius = DesignMetrics.radius.chip
  public static let keyTemplateTokenPadding: CGFloat = 5
  public static let keyTemplateTokenMargin: CGFloat = 1
  /// A token in a callout (`.call .t`): 16 high, 4 in.
  public static let keyTemplateSmallTokenHeight: CGFloat = 16
  public static let keyTemplateSmallTokenPadding: CGFloat = 4
  /// The wavy line under a `{…}` that is not a placeholder: 1 thick, 1.5
  /// up and down every 2, 2 under the text's bottom.
  public static let keyTemplateSquiggleWidth: CGFloat = 1
  public static let keyTemplateSquiggleAmplitude: CGFloat = 1.5
  public static let keyTemplateSquiggleStep: CGFloat = 2
  public static let keyTemplateSquiggleOffset: CGFloat = 2

  /// The block (`.kt`): 9 above, 12 below, its lines (`.sub`) 8 under the
  /// field and 8 apart.
  public static let keyTemplateTopPadding: CGFloat = 9
  public static let keyTemplateBottomPadding: CGFloat = 12
  public static let keyTemplateLineSpacing = DesignMetrics.spacing.s
  /// The example: a capsule 24
  /// high, 10 in at the sides; "Key" 2 before the path; the path's parts
  /// 3 apart, its slashes at 30 %; the ⋯ chip 16 high, 6 in; the clock 13.
  public static let keyTemplatePillHeight: CGFloat = 24
  public static let keyTemplatePillPadding: CGFloat = 10
  public static let keyTemplatePillSpacing: CGFloat = 5
  public static let keyTemplatePillLabelGap: CGFloat = 2
  public static let keyTemplatePillEdgeWidth: CGFloat = 0.5
  public static let keyTemplatePathSpacing: CGFloat = 3
  public static let keyTemplateSlashOpacity: Double = 0.3
  public static let keyTemplateChipHeight: CGFloat = 16
  public static let keyTemplateChipPadding: CGFloat = 6
  public static let keyTemplateClockSize: CGFloat = 13
  /// The clock's tip: 8 × 5 in, after 0.3 s on the clock.
  public static let keyTemplateTipHorizontalPadding = DesignMetrics.spacing.s
  public static let keyTemplateTipVerticalPadding: CGFloat = 5
  public static let keyTemplateTipDelay: Double = 0.3
  /// The key card (C-1): 300 wide, 12 in at the sides, 10 above and 12
  /// below, its lines 8 apart; Copy a capsule 6 in. It opens after 0.5 s
  /// on ⋯ and closes 0.3 s after the pointer leaves both.
  public static let keyTemplateCardWidth: CGFloat = 300
  public static let keyTemplateCardHorizontalPadding: CGFloat = 12
  public static let keyTemplateCardTopPadding: CGFloat = 10
  public static let keyTemplateCardBottomPadding: CGFloat = 12
  public static let keyTemplateCardSpacing = DesignMetrics.spacing.s
  public static let keyTemplateCardKeyLineSpacing: CGFloat = 4
  public static let keyTemplateCardRuleHeight: CGFloat = 0.5
  public static let keyTemplateCopyPadding: CGFloat = 6
  public static let keyTemplateCopyVerticalPadding: CGFloat = 1
  public static let keyTemplateCopySpacing: CGFloat = 4
  public static let keyTemplateCardOpenDelay: Double = 0.5
  public static let keyTemplateCardCloseDelay: Double = 0.3
  /// A callout (`.call`): corner 7, 7 × 9 in, the icon 7 before the words.
  public static let keyTemplateCalloutRadius: CGFloat = 7
  public static let keyTemplateCalloutVerticalPadding: CGFloat = 7
  public static let keyTemplateCalloutHorizontalPadding: CGFloat = 9
  public static let keyTemplateCalloutSpacing: CGFloat = 7
  /// A token among the callout's words sits this far below the baseline.
  public static let keyTemplateCalloutTokenBaseline: CGFloat = -4
  /// Insert: a segment at the field's trailing end, as a combo box's
  /// button — a hairline before it, the braces in grey, as tall as the
  /// field and as wide.
  public static let keyTemplateInsertWidth: CGFloat = 24
  /// The Insert popover (`.menu`: 232 wide, 5 in; a row 26 high, 6 in,
  /// corner 5; its header 6 in, 4 above the rows).
  public static let keyTemplateMenuWidth: CGFloat = 232
  public static let keyTemplateMenuPadding: CGFloat = 5
  public static let keyTemplateMenuRowHeight: CGFloat = 26
  public static let keyTemplateMenuRowPadding: CGFloat = 6
  public static let keyTemplateMenuRowRadius: CGFloat = 5
  public static let keyTemplateMenuRowSpacing = DesignMetrics.spacing.s
}

extension DesignMetrics.settings {
  /// The callout's lines 1.4 apart (`.call`: line-height 1.4 on 12).
  public static let keyTemplateCalloutLineSpacing: CGFloat = 2
}
