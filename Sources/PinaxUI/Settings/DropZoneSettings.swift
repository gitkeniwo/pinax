import AppKit
import CoreGraphics
import Foundation

/// The drop zone's vocabulary of user preferences, modelled on Clop's
/// own settings because Clop is the app being collided with. These are
/// value types on purpose: placement and gating are pure decisions over
/// values, testable without a window server.
public enum DropZoneCorner: String, CaseIterable, Sendable {
  case topLeft
  case topRight
  case bottomLeft
  case bottomRight

  public var label: String {
    switch self {
    case .topLeft: "Top Left"
    case .topRight: "Top Right"
    case .bottomLeft: "Bottom Left"
    case .bottomRight: "Bottom Right"
    }
  }
}

/// The keyboard modifier that gates drag visibility when "Require modifier
/// to show" is on (Clop's `onlyShowDropZoneOnOption`).
public enum DropZoneModifier: String, CaseIterable, Sendable {
  case option
  case control
  case command

  public var label: String {
    switch self {
    case .option: "Option ⌥"
    case .control: "Control ⌃"
    case .command: "Command ⌘"
    }
  }

  private var flags: NSEvent.ModifierFlags {
    switch self {
    case .option: .option
    case .control: .control
    case .command: .command
    }
  }

  /// Whether a drag event's live flags open the gate. Device-dependent bits
  /// are masked out first so a mouse button's own flag can never pose as a
  /// keyboard modifier.
  public func isSatisfied(by eventFlags: NSEvent.ModifierFlags) -> Bool {
    let keyboardOnly = eventFlags.intersection(.deviceIndependentFlagsMask)
    return !keyboardOnly.intersection(flags).isEmpty
  }
}

/// Pure placement arithmetic: the panel origin that puts a `panelSize` panel
/// in `corner` of `visibleFrame`. The controller's job reduces to running
/// this against the screens that exist *right now* — never against a cached
/// origin — which is what makes a screen change (undock, resolution, Dock
/// moved) re-place the panel instead of stranding it.
public enum DropZonePlacement {
  public static let margin: CGFloat = 24

  public static func origin(
    corner: DropZoneCorner,
    panelSize: CGSize,
    visibleFrame: NSRect,
    margin: CGFloat = DropZonePlacement.margin
  ) -> CGPoint {
    switch corner {
    case .topLeft:
      CGPoint(x: visibleFrame.minX + margin, y: visibleFrame.maxY - panelSize.height - margin)
    case .topRight:
      CGPoint(
        x: visibleFrame.maxX - panelSize.width - margin,
        y: visibleFrame.maxY - panelSize.height - margin)
    case .bottomLeft:
      CGPoint(x: visibleFrame.minX + margin, y: visibleFrame.minY + margin)
    case .bottomRight:
      CGPoint(x: visibleFrame.maxX - panelSize.width - margin, y: visibleFrame.minY + margin)
    }
  }
}

/// "Auto hide after": the rungs the settings picker offers, in
/// seconds, 0 = Never. The picker renders exactly this list.
public enum DropZoneAutoHide {
  public static let choices = [0, 30, 60, 120, 180, 240, 300, 600]

  public static func label(_ seconds: Int) -> String {
    switch seconds {
    case 0: "Never"
    case ..<60: "\(seconds) s"
    default: "\(seconds / 60) min"
    }
  }

  /// A stored value off the ladder — the retired 10 s rung — reads as the
  /// nearest rung at or above it; the storage key is unchanged.
  public static func normalized(_ stored: Int) -> Int {
    choices.contains(stored) ? stored : choices.first { $0 >= stored } ?? choices.last ?? stored
  }
}

/// Settings ▸ Drop Zone ▸ Look: the panel's own
/// appearance, independent of the system's and of the main window's.
public enum DropZoneAppearance: String, CaseIterable, Sendable {
  case light
  case dark
  case system

  public var label: String {
    switch self {
    case .light: "Light"
    case .dark: "Dark"
    case .system: "Match System"
    }
  }

  /// What the panel's `appearance` is set to: forced for Light and Dark,
  /// nil (inherit the system's) for Match System.
  public var nsAppearance: NSAppearance? {
    switch self {
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    case .system: nil
    }
  }
}

/// Settings ▸ Drop Zone ▸ Look: card rows, or a two-column shelf of large
/// thumbnails.
public enum DropZoneLayout: String, CaseIterable, Sendable {
  case list
  case shelf

  public var label: String {
    switch self {
    case .list: "List"
    case .shelf: "Shelf"
    }
  }
}

/// Settings ▸ Drop Zone ▸ Uploads ▸ Upload into. With Current Project, the
/// panel's picker and the app's current project are one value. A fixed choice
/// is where every appearance of the panel starts; the panel's picker then
/// changes only that appearance, never the app's current project — the one
/// exception to that single source, and only while a fixed choice is set. A
/// fixed project that is gone reads as Current Project.
public enum DropZoneUploadInto: Hashable, Sendable {
  case currentProject
  case noProject
  case project(String)

  private static let projectPrefix = "project:"

  /// Stored form: "current", "none" or "project:<slug>"; anything else is
  /// Current Project.
  public init(rawValue: String) {
    switch rawValue {
    case "none": self = .noProject
    case let raw where raw.hasPrefix(Self.projectPrefix) && raw.count > Self.projectPrefix.count:
      self = .project(String(raw.dropFirst(Self.projectPrefix.count)))
    default: self = .currentProject
    }
  }

  public var rawValue: String {
    switch self {
    case .currentProject: "current"
    case .noProject: "none"
    case .project(let slug): Self.projectPrefix + slug
    }
  }

  /// What the choice means with these projects: a fixed project that no
  /// longer exists is Current Project.
  public func resolved(projects: [String]) -> DropZoneUploadInto {
    if case .project(let slug) = self, !projects.contains(slug) { return .currentProject }
    return self
  }
}

/// Settings ▸ Drop Zone ▸ Size, in points.
public enum DropZoneSize {
  public static let widthRange: ClosedRange<Double> = 280...560
  public static let heightRange: ClosedRange<Double> = 320...800
  public static let defaultSize = CGSize(width: 340, height: 420)

  /// "Width 280–560, height 320–800".
  public static var rangeDescription: String {
    func span(_ range: ClosedRange<Double>) -> String {
      "\(Int(range.lowerBound))–\(Int(range.upperBound))"
    }
    return "Width \(span(widthRange)), height \(span(heightRange))"
  }

  public static func clamped(_ size: CGSize) -> CGSize {
    CGSize(
      width: min(max(size.width, widthRange.lowerBound), widthRange.upperBound),
      height: min(max(size.height, heightRange.lowerBound), heightRange.upperBound))
  }
}
