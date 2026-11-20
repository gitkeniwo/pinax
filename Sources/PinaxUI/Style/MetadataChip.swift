import SwiftUI

/// Compact metadata chrome shared by inspector tags/format badges and the
/// future grid overlay. macOS has no standard tag-chip control, so this owns
/// only the missing layout and shape while retaining system label/background
/// styles.
struct MetadataChipStyle: ViewModifier {
  private let cornerRadius: CGFloat = 4.5

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.quaternary)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
  }
}

extension View {
  func metadataChipStyle() -> some View {
    modifier(MetadataChipStyle())
  }
}
