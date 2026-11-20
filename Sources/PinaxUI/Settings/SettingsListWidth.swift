import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// A list column's width, one per page, remembered in the UI's defaults
/// (not the catalog): the last drag's, kept within 160–280.
struct SettingsListWidth {
  let key: String
  let defaults: UserDefaults

  static let range = Metrics.islandMinWidth...Metrics.islandMaxWidth

  static func clamped(_ width: CGFloat) -> CGFloat {
    min(max(width, range.lowerBound), range.upperBound)
  }

  /// The remembered width, or 196 when there is none.
  var stored: CGFloat {
    guard let value = defaults.object(forKey: key) as? Double else { return Metrics.islandDefaultWidth }
    return Self.clamped(CGFloat(value))
  }

  /// Keeps `width`, clamped; returns what was kept.
  @discardableResult
  func store(_ width: CGFloat) -> CGFloat {
    let kept = Self.clamped(width)
    defaults.set(Double(kept), forKey: key)
    return kept
  }

  static func page(_ tab: SettingsTab, defaults: UserDefaults) -> Self {
    Self(key: "settings.\(tab).listWidth", defaults: defaults)
  }
}

extension EnvironmentValues {
  /// Where the settings window keeps its own UI state (list widths); the
  /// app's standard defaults, a suite in tests.
  @Entry var settingsDefaults: UserDefaults = .standard
}
