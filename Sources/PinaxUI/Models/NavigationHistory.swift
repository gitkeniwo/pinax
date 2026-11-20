import Foundation

/// The jump bar's ◀ ▶: Xcode's Go Back / Go Forward over
/// the places the sidebar has shown. A place is a (navigator, selection)
/// pair — the same row in two navigators is two places, and going back
/// across a navigator switch restores both halves. Pure value, so the
/// history property is asserted without a window.
///
/// Browser rules: visiting a new place after going back cuts the forward
/// run; going back or forward moves the cursor and never adds an entry, so
/// the length only changes on a visit.
public struct NavigationHistory: Equatable, Sendable {
  public struct Place: Hashable, Sendable {
    public let navigator: SidebarNavigator
    public let selection: GalleryModel.SidebarSelection

    public init(_ navigator: SidebarNavigator, _ selection: GalleryModel.SidebarSelection) {
      self.navigator = navigator
      self.selection = selection
    }
  }

  public private(set) var places: [Place]
  public private(set) var cursor: Int

  public init(start: Place) {
    places = [start]
    cursor = 0
  }

  public var current: Place { places[cursor] }
  public var canGoBack: Bool { cursor > 0 }
  public var canGoForward: Bool { cursor < places.count - 1 }

  /// Records `place` as the newest step. Staying where the cursor already
  /// is records nothing.
  public mutating func visit(_ place: Place) {
    guard place != current else { return }
    places.removeSubrange((cursor + 1)...)
    places.append(place)
    cursor += 1
  }

  public mutating func goBack() -> Place? {
    guard canGoBack else { return nil }
    cursor -= 1
    return current
  }

  public mutating func goForward() -> Place? {
    guard canGoForward else { return nil }
    cursor += 1
    return current
  }

  /// A navigator's launch placeholder (`.all` in Time and Collections,
  /// which have no such row) resolving to its real default is not a step
  /// the user took: every recorded placeholder becomes the default.
  mutating func replace(_ placeholder: Place, with resolved: Place) {
    places = places.map { $0 == placeholder ? resolved : $0 }
  }
}
