import AppKit
import SwiftUI

/// One choice in Settings ▸ Appearance ▸ Menu Bar Icon.
public struct MenuBarIcon: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String

  /// The template image set in the app's asset catalog.
  public var assetName: String { "MenuBarIcon-\(id)" }
}

/// The icons on offer, in `Design/MenuBarIcon/menu-bar-icons.json` order.
/// The list is written out here and locked to the manifest and to the asset
/// catalog's `MenuBarIcons` folder by `MenuBarIconTests`; the images and the
/// manifest belong to `Scripts/make-menu-bar-icons.sh`.
public enum MenuBarIconCatalog {
  public static let icons: [MenuBarIcon] = [
    MenuBarIcon(id: "tablet", name: "Tablet"),
    MenuBarIcon(id: "tablet-outline", name: "Tablet Outline"),
    MenuBarIcon(id: "tablet-upload", name: "Tablet Upload"),
    MenuBarIcon(id: "aten", name: "Aten"),
    MenuBarIcon(id: "aten-outline", name: "Aten Outline"),
    MenuBarIcon(id: "aten-fan", name: "Aten Fan"),
    MenuBarIcon(id: "horizon-upload", name: "Horizon Upload"),
  ]

  /// What a fresh install shows; the manifest's `default: true`.
  public static let defaultID = "tablet"

  /// `id` if it is still offered, else nil.
  public static func known(_ id: String?) -> String? {
    guard let id, icons.contains(where: { $0.id == id }) else { return nil }
    return id
  }

  public static func icon(_ id: String) -> MenuBarIcon? {
    icons.first { $0.id == id }
  }

  /// The point size the menu bar item draws an icon at. The images are
  /// 18 pt; the three tablet glyphs sit small in their canvas, so they are
  /// drawn a little larger (the glyph scripts and image sets are not
  /// touched).
  public static func displaySize(for id: String) -> CGFloat {
    let resolved = known(id) ?? defaultID
    return resolved.hasPrefix("tablet") ? tabletDisplaySize : imagePointSize
  }

  public static let imagePointSize: CGFloat = 18
  public static let tabletDisplaySize: CGFloat = 21

  /// The image the menu bar item shows for a stored id. An id no longer
  /// offered reads as the default, never as a blank item.
  public static func imageName(for id: String) -> String {
    "MenuBarIcon-\(known(id) ?? defaultID)"
  }
}

/// The menu bar item's label: the chosen template image, or the state drawn
/// over it (`MenuBarIconState`: progress ring, failure dot, ✓), named "Pinax"
/// for accessibility with the state in its value. Every variant is a template
/// image, so the system tints it for the light and dark menu bar and the
/// open-menu highlight. It observes the preferences and the activity itself
/// because the `App` scene only observes the app model.
public struct MenuBarIconLabel: View {
  @ObservedObject private var preferences: PreferencesStore
  @ObservedObject private var activity: MenuBarActivity

  public init(preferences: PreferencesStore, activity: MenuBarActivity) {
    self.preferences = preferences
    self.activity = activity
  }

  /// Without live activity: the chosen icon only.
  @MainActor
  public init(preferences: PreferencesStore) {
    self.init(preferences: preferences, activity: MenuBarActivity())
  }

  /// The asset the item draws now.
  public var imageName: String { MenuBarIconCatalog.imageName(for: preferences.menuBarIconID) }

  public var state: MenuBarIconState { activity.state(iconID: preferences.menuBarIconID) }

  public var body: some View {
    let state = state
    let side = MenuBarIconCatalog.displaySize(for: preferences.menuBarIconID)
    return Image(nsImage: MenuBarIconDrawing.image(for: state, side: side))
      .accessibilityLabel("Pinax")
      .accessibilityValue(state.accessibilityValue)
  }
}

/// Draws the state variants in code (no extra image files): a template
/// `NSImage` of `side` pt square.
enum MenuBarIconDrawing {
  static func image(for state: MenuBarIconState, side: CGFloat) -> NSImage {
    let canvas = NSSize(width: side, height: side)
    let image = NSImage(size: canvas, flipped: false) { rect in
      switch state {
      case .idle(let id):
        base(id)?.draw(in: rect)
      case .failureDot(let id):
        base(id)?.draw(in: rect)
        let radius = side * 0.17
        let center = NSPoint(x: rect.maxX - radius - 0.5, y: rect.maxY - radius - 0.5)
        // A clear halo keeps the dot readable against the glyph.
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: dotRect(center, radius + 1.2)).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: dotRect(center, radius)).fill()
      case .progress:
        ring(in: rect, fraction: state.fraction)
      case .copied:
        check(in: rect)
      }
      return true
    }
    image.isTemplate = true
    return image
  }

  private static func base(_ id: String) -> NSImage? {
    NSImage(named: MenuBarIconCatalog.imageName(for: id))
  }

  private static func dotRect(_ center: NSPoint, _ radius: CGFloat) -> NSRect {
    NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
  }

  /// A faint full track under an arc that starts at 12 o'clock; a minimum
  /// sweep so the first upload of a batch already shows movement.
  private static func ring(in rect: NSRect, fraction: Double) {
    let width: CGFloat = 2
    let inset = rect.insetBy(dx: width / 2 + rect.width * 0.1, dy: width / 2 + rect.height * 0.1)
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = min(inset.width, inset.height) / 2
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    NSColor.black.withAlphaComponent(0.3).setStroke()
    track.stroke()
    let sweep = 360 * max(0.08, fraction)
    let arc = NSBezierPath()
    arc.appendArc(
      withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
    arc.lineWidth = width
    arc.lineCapStyle = .round
    NSColor.black.setStroke()
    arc.stroke()
  }

  private static func check(in rect: NSRect) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.width * 0.2, y: rect.height * 0.5))
    path.line(to: NSPoint(x: rect.width * 0.42, y: rect.height * 0.28))
    path.line(to: NSPoint(x: rect.width * 0.8, y: rect.height * 0.72))
    path.lineWidth = 2.2
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.black.setStroke()
    path.stroke()
  }
}
