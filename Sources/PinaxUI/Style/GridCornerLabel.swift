import SwiftUI

/// The library grid's corner label (`AssetGridCell`'s format, size, date):
/// a caption2 line on a material chip. Externals' format chip is the same
/// one.
struct GridCornerLabel: ViewModifier {
  var weight: Font.Weight = .regular

  func body(content: Content) -> some View {
    content
      .font(.caption2.weight(weight))
      .lineLimit(1)
      .padding(.horizontal, 5)
      .padding(.vertical, 3)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignMetrics.radius.chip))
  }
}

extension View {
  func gridCornerLabel(weight: Font.Weight = .regular) -> some View {
    modifier(GridCornerLabel(weight: weight))
  }
}
