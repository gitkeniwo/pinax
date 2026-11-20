import CoreGraphics

// MARK: Sidebar

extension DesignMetrics.sidebarRow {
  /// Where the sidebar List starts a row's content, measured from the
  /// selection plate's leading edge (macOS 15, hosted sidebar: the cell
  /// starts at x 16 in a level with no native disclosure column, the plate
  /// at 8). Points left of it take no clicks (measured: a button pulled
  /// past it got no taps), so nothing clickable goes there.
  public static let listContentInset: CGFloat = 8

  /// A Library row's content starts 6 in from the plate (canvas
  /// `padding:0 6px`).
  public static let contentPadding: CGFloat = 6

  /// The leading padding that puts a plain row's square `contentPadding`
  /// in from the plate: -2. Only the square and the name sit there, which
  /// select the row like any other point of it.
  public static var plainLeading: CGFloat { contentPadding - listContentInset }

  /// No chevron. Each level below the
  /// first indents its square 26, under the name of the row above
  /// (`pad: 6 + lv * 26`).
  public static let levelIndent: CGFloat = 26

  /// A closed row that opens: a second square of its colour behind its
  /// own, 3 right and 3 up (`left:3px;top:-3px`), at 58 % light / 62 %
  /// dark (`back`); white at 50 % on the selected row.
  public static let stackOffset: CGFloat = 3
  public static let stackOpacityLight: Double = 0.58
  public static let stackOpacityDark: Double = 0.62
  public static let stackOpacitySelected: Double = 0.5
  /// The front square's ring in the sidebar's ground that parts the two
  /// layers (`box-shadow:0 0 0 1.5px var(--side)`).
  public static let stackRing: CGFloat = 1.5

  /// Tree lines (`border-left/bottom:1.5px solid var(--tree)`,
  /// `border-bottom-left-radius:7px`): from the parent square's bottom
  /// middle down to the child row's middle, then right, stopping 3 before
  /// the child's square.
  public static let treeLineWidth: CGFloat = 1.5
  public static let treeRadius: CGFloat = 7
  public static let treeGap: CGFloat = 3

  /// The count capsule's fixed width (`width:34px;text-align:center`).
  public static let countWidth: CGFloat = 34
}
