import SwiftUI

// The Overview's roles. The design's sizes read as the macOS text style of
// nearest size.
extension View {
  /// A hero cell's number (board 21 bold): title, 22.
  public func pinaxHeroFigure() -> some View {
    font(.title.weight(.bold))
      .monospacedDigit()
  }

  /// The Uploads card's numbers (board 19 bold): title2, 17.
  public func pinaxOverviewFigure() -> some View {
    font(.title2.weight(.bold))
      .monospacedDigit()
  }

  /// Upload Activity's title (board 14 semibold): title3, 15.
  public func pinaxOverviewHeading() -> some View {
    font(.title3.weight(.semibold))
  }

  /// A card's title (board 13 semibold).
  public func pinaxOverviewCardTitle() -> some View {
    font(.body.weight(.semibold))
  }

  /// A hero cell's title (board 11.5 semibold): subheadline, 11.
  public func pinaxOverviewLabel() -> some View {
    font(.subheadline.weight(.semibold))
  }

  /// The small capitals over a figure (board `.cap`, 10.5 semibold,
  /// uppercase): caption, 10.
  public func pinaxOverviewCaps() -> some View {
    font(.caption.weight(.semibold))
      .textCase(.uppercase)
      .foregroundStyle(.secondary)
  }

  /// A list row's figure (board 12.5 semibold): body, 13.
  public func pinaxOverviewValue() -> some View {
    font(.body.weight(.semibold))
      .monospacedDigit()
  }

  /// A project's name (board 12.5 medium).
  public func pinaxOverviewName() -> some View {
    font(.body.weight(.medium))
  }

  /// The chart label's count (board 10.5 bold).
  public func pinaxOverviewCalloutFigure() -> some View {
    font(.caption.weight(.bold))
      .monospacedDigit()
  }
}
