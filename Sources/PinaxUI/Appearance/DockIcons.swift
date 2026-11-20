import AppKit

/// One choice in Settings ▸ Appearance ▸ App Icon.
public struct DockIcon: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  /// The icon the bundle already carries (`AppIcon.appiconset`): choosing
  /// it restores the app's own icon instead of setting a copy.
  public let isBundle: Bool

  /// The image set in the app's asset catalog; nil for the bundle icon.
  public var assetName: String? { isBundle ? nil : "DockIcon-\(id)" }
}

/// The icons on offer, in `Design/AppIcon/dock-icons.json` order. The list
/// is written out here and locked to the manifest and to the asset
/// catalog's `DockIcons` folder by `DockIconTests`, so adding or removing an
/// icon is a manifest + image set + this list change the test checks;
/// `Scripts/add-dock-icon.sh` makes all three from a tuner recipe.
public enum DockIconCatalog {
  public static let icons: [DockIcon] = [
    DockIcon(id: "ivory-linen", name: "Ivory Linen", isBundle: false),
    DockIcon(id: "museum-spotlight", name: "Museum Spotlight", isBundle: false),
    DockIcon(id: "sage-linen", name: "Sage Linen", isBundle: false),
    DockIcon(id: "ivory-glyph", name: "Ivory Glyph", isBundle: true),
    DockIcon(id: "ivory-glyph-spotlight", name: "Ivory Glyph Spotlight", isBundle: false),
    DockIcon(id: "limestone", name: "Limestone", isBundle: false),
    DockIcon(id: "limestone-spotlight", name: "Limestone Spotlight", isBundle: false),
  ]

  public static let bundleID = "ivory-glyph"
  /// What the Dark slot takes the first time Match System Appearance is on:
  /// every default is Ivory Glyph, the app's own icon.
  public static let darkDefaultID = "ivory-glyph"

  /// `id` if it is still offered, else nil.
  public static func known(_ id: String?) -> String? {
    guard let id, icons.contains(where: { $0.id == id }) else { return nil }
    return id
  }

  public static func icon(_ id: String) -> DockIcon? {
    icons.first { $0.id == id }
  }

  /// Which icon the Dock shows. An id no longer offered reads as the
  /// bundle icon, never as a blank tile.
  public static func iconID(
    matchesSystem: Bool, selected: String, light: String, dark: String, systemIsDark: Bool
  ) -> String {
    let chosen = matchesSystem ? (systemIsDark ? dark : light) : selected
    return known(chosen) ?? bundleID
  }
}

/// Puts the chosen icon on the Dock tile at run time through
/// `NSApp.applicationIconImage` — the bundle on disk is never written and
/// `NSWorkspace.setIcon` is never called, so Finder, Launchpad and
/// notifications keep the default icon. Every system hook is injected so
/// tests drive it without touching the real Dock.
@MainActor
public final class DockIconApplier {
  private let preferences: PreferencesStore
  private let image: @MainActor (String) -> NSImage?
  private let systemIsDark: @MainActor () -> Bool
  private let setIcon: @MainActor (NSImage?) -> Void
  private var appearanceObservation: NSKeyValueObservation?
  private var activationObserver: NSObjectProtocol?

  /// The icon last applied.
  public private(set) var appliedID: String?

  public init(
    preferences: PreferencesStore,
    image: @escaping @MainActor (String) -> NSImage? = { NSImage(named: "DockIcon-\($0)") },
    systemIsDark: @escaping @MainActor () -> Bool = {
      NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    },
    setIcon: @escaping @MainActor (NSImage?) -> Void = { NSApp.applicationIconImage = $0 }
  ) {
    self.preferences = preferences
    self.image = image
    self.systemIsDark = systemIsDark
    self.setIcon = setIcon
  }

  /// The real app's applier: sets `NSApp`'s tile and follows the system
  /// appearance and the Dock tile coming back.
  public static func system(preferences: PreferencesStore) -> DockIconApplier {
    let applier = DockIconApplier(preferences: preferences)
    applier.observeSystem()
    return applier
  }

  /// Follows the preferences from now on and applies the current choice.
  public func start() {
    preferences.onDockIconChange = { [weak self] in self?.reapply() }
    reapply()
  }

  /// The real app only: follows the system appearance (automatic
  /// appearance included) and re-applies whenever the Dock tile comes
  /// back after the app was an accessory.
  public func observeSystem() {
    appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.appearanceDidChange() }
    }
    activationObserver = NotificationCenter.default.addObserver(
      forName: AppActivation.didBecomeRegular, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reapply() }
    }
  }

  public func appearanceDidChange() {
    reapply()
  }

  /// Sets the tile from the current preferences — the bundle icon, or an
  /// image the app cannot find, restores the app's own icon (nil).
  public func reapply() {
    let id = DockIconCatalog.iconID(
      matchesSystem: preferences.dockIconMatchesSystem,
      selected: preferences.dockIconID,
      light: preferences.effectiveDockIconLightID,
      dark: preferences.dockIconDarkID,
      systemIsDark: systemIsDark())
    appliedID = id
    let isBundle = DockIconCatalog.icon(id)?.isBundle ?? true
    setIcon(isBundle ? nil : image(id))
  }
}
