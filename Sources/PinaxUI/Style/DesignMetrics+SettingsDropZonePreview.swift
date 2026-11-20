import CoreGraphics

// Settings ▸ Drop Zone's preview column: the mini desktop, its menu bar,
// the panel's place on it, and the lines under it.

extension DesignMetrics.settings {
  /// Drop Zone only: the preview column right of the form, and the margin
  /// after it (170 + 568 + 380 + 28 = 1146 at the default sidebar). The
  /// form's own trailing 28 is the gap before the column.
  public static let previewColumnWidth: CGFloat = 380
  public static let previewTrailingInset: CGFloat = 28

  /// The mini desktop: a window-screenshot-like rounded rectangle.
  public static let previewDesktopWidth: CGFloat = 380
  public static let previewDesktopHeight: CGFloat = 536
  public static let previewDesktopRadius: CGFloat = 10
  public static let previewDesktopRimWidth: CGFloat = 0.5
  public static let previewDesktopShadowRadius: CGFloat = 1.5
  public static let previewDesktopShadowOffset: CGFloat = 1
  public static let previewDesktopShadowOpacity: CGFloat = 0.4

  /// Its menu bar: 16 tall, 9 in, 7 between the marks; a 6 pt dot, 4 pt
  /// bars, an 8 pt clock.
  public static let previewMenuBarHeight: CGFloat = 16
  public static let previewMenuBarInset: CGFloat = 9
  public static let previewMenuBarSpacing: CGFloat = 7
  public static let previewMenuBarDot: CGFloat = 6
  public static let previewMenuBarMark: CGFloat = 4
  public static let previewMenuBarLeadingMarks: [CGFloat] = [18, 14, 16, 12]
  public static let previewMenuBarTrailingMarks: [CGFloat] = [8, 8]
  public static let previewMenuBarClockSize: CGFloat = 8

  /// The panel sits this far from the desktop's edges and from the menu
  /// bar: 356 × 496 to fit in, so 340 × 420 shows at 100 % and 560 × 800
  /// at 62 %.
  public static let previewPanelMargin: CGFloat = 12
  public static let previewPanelShadowRadius: CGFloat = 14
  public static let previewPanelShadowOffset: CGFloat = 6
  public static let previewPanelShadowOpacity: CGFloat = 0.32
  /// Before macOS 26 the preview draws the panel's frost itself: the
  /// wallpaper under it, blurred.
  public static let previewFrostBlur: CGFloat = 24

  /// The resize grip: the real panel's 16 pt grip, unscaled, 5 in from
  /// the panel's corner; its hover ground's radius.
  public static let previewGripCornerInset: CGFloat = 5
  public static let previewGripHoverRadius: CGFloat = 6

  /// Under the desktop: 10 to the size label, 10 to the stage segments,
  /// 6 to the note.
  public static let previewLabelGap: CGFloat = 10
  public static let previewSegmentGap: CGFloat = 10
  public static let previewNoteGap: CGFloat = 6
}
