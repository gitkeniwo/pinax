import CoreGraphics

// The inspector's numbers.

extension DesignMetrics.inspector {
  /// The preview: never shorter than the canvas's 160 pt box (option 2:
  /// "预览图加高到 160"), still capped by `previewMaxHeight`; corner 8.
  public static let previewMinHeight: CGFloat = 160
  public static let previewRadius: CGFloat = 8
  /// The gap between the header, the preview, the stat pills and each band
  /// (`margin-top:12px`).
  public static let bandSpacing: CGFloat = DesignMetrics.spacing.m
}

extension DesignMetrics {
  /// The inspector's header: a 28 pt format square, the
  /// name over "date · kind", the collapse button at the far right.
  public enum inspectorHeader {
    /// Canvas 9: the s rung.
    public static let spacing: CGFloat = DesignMetrics.spacing.s
    /// The title over its subtitle: flush, as the canvas's column.
    public static let titleSpacing: CGFloat = DesignMetrics.spacing.none
    /// The title item's width in the toolbar's inspector section: the
    /// 300 pt column less the toggle's item and the toolbar's insets
    /// (inferred; the canvas's 286 column draws 14 + 18 + 12 around it).
    public static let width: CGFloat = 220
    /// From the column's leading edge (canvas 14).
    public static let leadingInset: CGFloat = 14
  }

  /// The two stat pills under the preview: 6 apart, widths 1 : 1.35.
  public enum inspectorStats {
    public static let spacing: CGFloat = 6
    public static let dimensionsShare: CGFloat = 1.35
  }

  /// A band's content: the key column (48, right-aligned, with a colon) and
  /// its rows (`grid-template-columns:48px …; column-gap:8px; row-gap:7px;
  /// padding:8px 2px 0`).
  public enum inspectorFields {
    public static let keyWidth: CGFloat = 48
    public static let columnSpacing: CGFloat = DesignMetrics.spacing.s
    /// Canvas 7: the s rung.
    public static let rowSpacing: CGFloat = DesignMetrics.spacing.s
    public static let topPadding: CGFloat = DesignMetrics.spacing.s
    public static let horizontalPadding: CGFloat = 2
    /// The link's name over its "host › path": flush (`line-height:1.25`).
    public static let linkLineSpacing: CGFloat = DesignMetrics.spacing.none
    /// Source's colour square before its sentence (canvas 14, 5 apart: the
    /// 13 pt caption square and the xs rung).
    public static let sourceSpacing: CGFloat = DesignMetrics.spacing.xs
  }

  /// The link row's second line: the format pop-up (22 high, corner 6,
  /// 8 across, a 10 pt chevron 3 after the name) and the icon buttons.
  public enum inspectorLink {
    public static let popupHeight: CGFloat = 22
    public static let popupRadius: CGFloat = 6
    public static let popupHorizontalPadding: CGFloat = DesignMetrics.spacing.s
    public static let popupChevron: CGFloat = 10
    public static let popupSpacing: CGFloat = 3
  }

  /// Projects rows: letter square, name, the live dot and the switch.
  public enum inspectorProjects {
    /// Canvas 7: the s rung.
    public static let spacing: CGFloat = DesignMetrics.spacing.s
    public static let liveDot: CGFloat = 7
    public static let liveSpacing: CGFloat = DesignMetrics.spacing.xs
    /// The footnote under the rows (canvas `padding-top:5px`: the xs rung).
    public static let footnoteSpacing: CGFloat = DesignMetrics.spacing.xs
  }

  /// Labels: the heart, then seven
  /// seamless equal segments, 18 high, corner 6; the chosen one full with a
  /// check, the rest at 35 %.
  public enum labelBand {
    public static let height: CGFloat = 18
    public static let radius: CGFloat = 6
    public static let dimmedOpacity: Double = 0.35
    public static let check: CGFloat = 11
    public static let heart: CGFloat = 13
    /// Canvas 7: the s rung.
    public static let spacing: CGFloat = DesignMetrics.spacing.s
  }
}

extension DesignMetrics {
  /// The inspector's text fields: the note 26 high,
  /// 8 across, 12 pt; "+ Add tag…" 22 high, 7 across, 11.5 pt, the plus 4
  /// before it; both corner 6 on fieldbg with a 0.5 pt fieldline. A
  /// focused field's line is the accent at 1 pt (inferred: the canvas draws
  /// no focus).
  public enum inspectorField {
    public static let radius: CGFloat = 6
    public static let lineWidth: CGFloat = 0.5
    public static let focusedLineWidth: CGFloat = 1
    public static let noteHeight: CGFloat = 26
    public static let notePadding: CGFloat = DesignMetrics.spacing.s
    /// A wrapped note's lines keep a little air top and bottom (inferred).
    public static let noteVerticalPadding: CGFloat = DesignMetrics.spacing.xs
    public static let tagHeight: CGFloat = 22
    public static let tagPadding: CGFloat = 7
    public static let tagIconSpacing: CGFloat = DesignMetrics.spacing.xs
    public static let tagIcon: CGFloat = 10
  }

  /// A project's membership switch: 34 × 18, corner 5, green, a white
  /// 11 pt check 5 in from the right. Off is the count ground with no mark.
  public enum membershipSwitch {
    public static let width: CGFloat = 34
    public static let height: CGFloat = 18
    public static let radius: CGFloat = 5
    public static let check: CGFloat = 11
    public static let checkInset: CGFloat = 5
  }

  /// Used In's rows in the band: a 13 pt document glyph, 6 before the 12 pt
  /// line.
  public enum inspectorUsedIn {
    public static let spacing: CGFloat = 6
    public static let glyph: CGFloat = 13
  }
}
