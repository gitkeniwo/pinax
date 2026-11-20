import SwiftUI

// The Externals table's small type and the scope bar's segments. View code
// names the role; only Typography names the font.
extension View {
  /// The table's column header (canvas 11, secondary).
  public func pinaxTableHeader() -> some View {
    font(.subheadline)
  }

  /// A reference row's host-less path (canvas 10.5).
  public func pinaxTablePath() -> some View {
    font(.system(size: DesignMetrics.externalsTable.pathSize))
  }

  /// The Kind column's mark (canvas 9.5, weight 700).
  public func pinaxTableKind() -> some View {
    font(.system(size: DesignMetrics.externalsTable.kindSize, weight: .bold))
  }

  /// The line capsule ("L18", 10.5, tabular).
  public func pinaxLineCapsule() -> some View {
    font(.system(size: DesignMetrics.externalsTable.pathSize))
      .monospacedDigit()
  }

  /// A scope bar's segment name (canvas 12).
  public func pinaxScopeSegment() -> some View {
    font(.callout)
  }

  /// The inspector preview's "Not loaded from host" (canvas 11.5).
  public func pinaxPreviewNote() -> some View {
    font(.subheadline)
  }

  /// The "Load preview" button's words (canvas 11.5 medium).
  public func pinaxLoadPreview() -> some View {
    font(.subheadline.weight(.medium))
  }
}
