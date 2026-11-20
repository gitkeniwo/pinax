import SwiftUI

// The inspector's empty state. Sizes are the macOS text style of nearest
// size.
extension View {
  /// The empty inspector's title (board 13 semibold, fg2).
  public func pinaxEmptyTitle() -> some View {
    font(.body.weight(.semibold))
      .foregroundStyle(.secondary)
  }

  /// The empty inspector's hint (board 11, fg3).
  public func pinaxEmptyHint() -> some View {
    font(.subheadline)
      .foregroundStyle(.tertiary)
  }
}
