import Foundation
import SwiftUI
import Testing
@testable import PinaxUI

/// The preferences store owns machine-local state in `UserDefaults` and
/// nothing else. The property under test: a preference can
/// only change through an explicit set — displaying anything never fires the
/// change hook, and no code path here can reach a catalog row.
@MainActor
@Suite struct PreferencesStoreTests {
  @Test("A fresh store defaults the drop zone to on")
  func freshDefault() throws {
    let defaults = try makeDefaults()
    let store = PreferencesStore(defaults: defaults)
    #expect(store.isDropZoneEnabled)
  }

  @Test("The store reads the key the earlier shell wrote")
  func readsExistingChoice() throws {
    let defaults = try makeDefaults()
    defaults.set(false, forKey: "pinax.dropZone.enabled")
    #expect(!PreferencesStore(defaults: defaults).isDropZoneEnabled)
  }

  @Test("An explicit set persists and fires the hook exactly once per change")
  func explicitSetPersistsAndNotifies() throws {
    let defaults = try makeDefaults()
    let store = PreferencesStore(defaults: defaults)
    var observed: [Bool] = []
    store.onDropZoneEnabledChange = { observed.append($0) }

    store.isDropZoneEnabled = false
    #expect(observed == [false])
    #expect(defaults.object(forKey: "pinax.dropZone.enabled") as? Bool == false)

    // Re-setting the same value is not a change: no hook, no write churn.
    store.isDropZoneEnabled = false
    #expect(observed == [false])

    store.isDropZoneEnabled = true
    #expect(observed == [false, true])
    #expect(defaults.object(forKey: "pinax.dropZone.enabled") as? Bool == true)
  }

  @Test("A store without a hook tolerates changes")
  func nilHookIsSafe() throws {
    let defaults = try makeDefaults()
    let store = PreferencesStore(defaults: defaults)
    store.isDropZoneEnabled = false
    #expect(!store.isDropZoneEnabled)
  }

  @Test("The app model and its settings view share one store over one suite")
  func appModelExposesStore() throws {
    let defaults = try makeDefaults()
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: {
      throw URLError(.cannotOpenFile)
    })
    app.preferences.isDropZoneEnabled = false
    #expect(
      defaults.object(forKey: "pinax.dropZone.enabled") as? Bool == false)
    #expect(!app.preferences.isDropZoneEnabled)
  }

  // MARK: - Placement and behaviour preferences

  @Test("Drop zone preferences have their defaults, bottom-left included")
  func h4Defaults() throws {
    let store = PreferencesStore(defaults: try makeDefaults())
    // The bottom-left default is defect 11's fix: it deliberately differs
    // from Clop's bottom-right so the two panels do not overlap.
    #expect(store.dropZoneCorner == .bottomLeft)
    #expect(!store.dropZoneRequiresModifier)
    #expect(store.dropZoneModifier == .option)
    #expect(!store.dropZoneFollowsCursor)
    #expect(store.dropZoneAutoHideSeconds == 30)
    #expect(store.copiesURLsOnUpload)
  }

  @Test("Each drop zone preference persists under its own key and reloads")
  func h4Persistence() throws {
    let defaults = try makeDefaults()
    let store = PreferencesStore(defaults: defaults)

    store.dropZoneCorner = .topRight
    store.dropZoneRequiresModifier = true
    store.dropZoneModifier = .command
    store.dropZoneFollowsCursor = true
    store.dropZoneAutoHideSeconds = 0
    store.copiesURLsOnUpload = false

    #expect(defaults.string(forKey: "pinax.dropZone.corner") == "topRight")
    #expect(defaults.bool(forKey: "pinax.dropZone.requiresModifier"))
    #expect(defaults.string(forKey: "pinax.dropZone.modifier") == "command")
    #expect(defaults.bool(forKey: "pinax.dropZone.followsCursor"))
    #expect(defaults.integer(forKey: "pinax.dropZone.autoHideSeconds") == 0)
    #expect(defaults.bool(forKey: "pinax.dropZone.copiesURLsOnUpload") == false)

    let reloaded = PreferencesStore(defaults: defaults)
    #expect(reloaded.dropZoneCorner == .topRight)
    #expect(reloaded.dropZoneRequiresModifier)
    #expect(reloaded.dropZoneModifier == .command)
    #expect(reloaded.dropZoneFollowsCursor)
    #expect(reloaded.dropZoneAutoHideSeconds == 0)
    #expect(!reloaded.copiesURLsOnUpload)
  }

  @Test("An unparsable stored corner or modifier falls back to the default")
  func h4GarbageTolerance() throws {
    let defaults = try makeDefaults()
    defaults.set("sideways", forKey: "pinax.dropZone.corner")
    defaults.set("hyper", forKey: "pinax.dropZone.modifier")
    let store = PreferencesStore(defaults: defaults)
    #expect(store.dropZoneCorner == .bottomLeft)
    #expect(store.dropZoneModifier == .option)
  }

  // MARK: - Grid zoom persistence

  /// The ladder is [2, 3, 4, 5, 6, 8] with default 4 — `GridZoom.columns`
  /// in the product code; restated by number here because this suite tests
  /// the public surface, where that constant is not visible.
  @Test("The zoom rung defaults to 4, persists under its own key, and reloads")
  func gridColumnsPersistence() throws {
    let defaults = try makeDefaults()
    let store = PreferencesStore(defaults: defaults)
    #expect(store.gridColumns == 4)

    store.gridColumns = 6
    #expect(defaults.integer(forKey: "pinax.grid.columns") == 6)
    #expect(PreferencesStore(defaults: defaults).gridColumns == 6)

    store.gridColumns = 2
    #expect(PreferencesStore(defaults: defaults).gridColumns == 2)
  }

  @Test("Off-ladder rungs never persist: stored garbage reads as the default, in-memory garbage is refused")
  func gridColumnsGarbageTolerance() throws {
    let defaults = try makeDefaults()
    defaults.set(7, forKey: "pinax.grid.columns")
    #expect(PreferencesStore(defaults: defaults).gridColumns == 4)
    defaults.set(0, forKey: "pinax.grid.columns")
    #expect(PreferencesStore(defaults: defaults).gridColumns == 4)

    // A write off the ladder is refused in memory and leaves storage alone.
    let store = PreferencesStore(defaults: defaults)
    store.gridColumns = 5
    store.gridColumns = 7
    #expect(store.gridColumns == 5)
    #expect(defaults.integer(forKey: "pinax.grid.columns") == 5)
  }

  @Test("The app model seeds the gallery from the store and writes zoom changes back")
  func appModelWiresGridColumns() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }

    let defaults = try makeDefaults()
    defaults.set(6, forKey: "pinax.grid.columns")
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)

    // Seed: the stored rung reaches the gallery at creation.
    #expect(gallery.gridColumns == 6)

    // Writeback: a zoom step reaches the store and the suite.
    gallery.zoomOut()
    #expect(gallery.gridColumns == 8)
    #expect(app.preferences.gridColumns == 8)
    #expect(defaults.integer(forKey: "pinax.grid.columns") == 8)
  }

  // MARK: - Gallery display preferences

  @Test("Gallery display choices persist under pinax keys and tolerate unknown enum values")
  func galleryDisplayPersistence() throws {
    let defaults = try makeDefaults()
    let store = PreferencesStore(defaults: defaults)
    #expect(store.gridOverlays == GridOverlayOptions())
    #expect(store.gridThumbnailSizing == .fillGrid)

    store.gridOverlays = GridOverlayOptions(
      metadataVisibility: .off,
      showsFilename: false,
      showsUploadDateBelowImage: false,
      leadingCorner: .format,
      trailingCorner: .fileSize)
    store.gridThumbnailSizing = .originalAspect

    #expect(defaults.string(forKey: "pinax.grid.metadata.visibility") == "off")
    #expect(defaults.object(forKey: "pinax.grid.metadata.filename") as? Bool == false)
    #expect(defaults.bool(forKey: "pinax.grid.metadata.uploadDate") == false)
    #expect(defaults.string(forKey: "pinax.grid.metadata.leadingCorner") == "format")
    #expect(defaults.string(forKey: "pinax.grid.metadata.trailingCorner") == "fileSize")
    #expect(defaults.string(forKey: "pinax.grid.thumbnailSizing") == "originalAspect")

    let reloaded = PreferencesStore(defaults: defaults)
    #expect(reloaded.gridOverlays == store.gridOverlays)
    #expect(reloaded.gridThumbnailSizing == .originalAspect)

    defaults.set("future-corner", forKey: "pinax.grid.metadata.leadingCorner")
    defaults.set("future-sizing", forKey: "pinax.grid.thumbnailSizing")
    let tolerant = PreferencesStore(defaults: defaults)
    #expect(tolerant.gridOverlays.leadingCorner == GridOverlayOptions.defaultLeadingCorner)
    #expect(tolerant.gridThumbnailSizing == .fillGrid)
  }

  @Test("Settings, View Show, jump-bar, and status controls converge on one preference")
  func galleryDisplayEntrypointsSharePreference() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }

    let defaults = try makeDefaults()
    defaults.set(false, forKey: "pinax.grid.metadata.uploadDate")
    defaults.set("noteIndicator", forKey: "pinax.grid.metadata.leadingCorner")
    defaults.set("originalAspect", forKey: "pinax.grid.thumbnailSizing")
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)

    // Initial settings state seeds every gallery entry point.
    #expect(gallery.gridOverlays == app.preferences.gridOverlays)
    #expect(gallery.gridThumbnailSizing == app.preferences.gridThumbnailSizing)

    // Settings and View ▸ Show both write the store directly.
    app.preferences.gridOverlays = GridOverlayOptions(
      metadataVisibility: .off,
      showsUploadDateBelowImage: true,
      leadingCorner: .fileSize,
      trailingCorner: .format)
    app.preferences.gridThumbnailSizing = .fillGrid
    #expect(gallery.gridOverlays == app.preferences.gridOverlays)
    #expect(gallery.gridThumbnailSizing == .fillGrid)

    // The jump-bar and status controls write the gallery model; writeback
    // reaches the exact same store observed by Settings and View ▸ Show.
    gallery.gridOverlays.metadataVisibility = .always
    gallery.gridOverlays.trailingCorner = .dimensions
    gallery.toggleGridThumbnailSizing()
    #expect(app.preferences.gridOverlays == gallery.gridOverlays)
    #expect(app.preferences.gridThumbnailSizing == .originalAspect)
    #expect(PreferencesStore(defaults: defaults).gridOverlays == gallery.gridOverlays)
  }

  @Test("The jump bar's display options and View ▸ Show read one state")
  func jumpBarAndViewShowShareOneState() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: try makeDefaults(), databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)

    // The bindings the two menus actually hand to `GridOverlayMenuItems`,
    // taken from the views themselves: a menu that hands in a copy
    // (`.constant(...)`) drops these writes and fails below.
    let jumpBar = JumpBar(model: gallery).displayOptionsItems.$overlays
    let viewShow = PinaxCommands(app: app).showItems.$overlays
    #expect(jumpBar.wrappedValue.metadataVisibility == .hoverOrSelected)
    #expect(viewShow.wrappedValue.metadataVisibility == .hoverOrSelected)

    // One change in the jump bar: both menus' Grid Metadata checkmarks.
    jumpBar.wrappedValue.metadataVisibility = .off
    #expect(jumpBar.wrappedValue.metadataVisibility == .off)
    #expect(viewShow.wrappedValue.metadataVisibility == .off)

    // One change in View ▸ Show: both menus read it.
    viewShow.wrappedValue.metadataVisibility = .always
    viewShow.wrappedValue.leadingCorner = .fileSize
    #expect(jumpBar.wrappedValue == viewShow.wrappedValue)
    #expect(jumpBar.wrappedValue.leadingCorner == .fileSize)
  }

  /// The toggles a menu body declares, as title → the state each one shows.
  /// A `Toggle` keeps its title and a private `Binding<ToggleState>` as
  /// stored properties (measured); the state type is not public, so this
  /// reads what the toggle shows and cannot flip it.
  private func toggles(in view: Any) -> [String: String] {
    let mirror = Mirror(reflecting: view)
    if String(describing: type(of: view)).hasPrefix("Toggle<") {
      let title = "\(mirror.descendant("label", "storage", "anyTextStorage", "key") ?? "")"
      let shown = "\(mirror.descendant("_toggleState", "_value") ?? "")"
      return [title: shown]
    }
    return mirror.children.reduce(into: [:]) { found, child in
      found.merge(toggles(in: child.value)) { first, _ in first }
    }
  }

  @Test("View ▸ Show carries a filename toggle that shows the one filename preference, which persists")
  func viewShowFilenameToggle() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    #expect(gallery.gridOverlays.showsFilename, "shown by default")

    // The body of the items the app's View ▸ Show installs, before and
    // after the preference changes from the jump bar's side.
    func filenameToggle() throws -> String {
      let found = toggles(in: PinaxCommands(app: app).showItems.body)
      return try #require(
        found.first { $0.key.contains("Filename Below Thumbnail") }?.value,
        "no filename toggle among \(found.keys.sorted())")
    }
    let on = try filenameToggle()
    gallery.gridOverlays.showsFilename = false
    let off = try filenameToggle()
    #expect(on != off, "the toggle shows \(on) both ways")
    #expect(app.preferences.gridOverlays.showsFilename == false)
    #expect(PreferencesStore(defaults: defaults).gridOverlays.showsFilename == false)
    #expect(
      app.preferences.gridOverlays.metadataVisibility == .hoverOrSelected,
      "the metadata setting is a different control")
  }

  @Test("The month-grouping switch defaults on and survives a relaunch")
  func monthGroupingPersists() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()

    let first = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await first.start()
    let gallery = try #require(first.gallery)
    #expect(gallery.groupsByMonth)

    gallery.groupsByMonth = false
    #expect(defaults.object(forKey: "pinax.grid.groupsByMonth") as? Bool == false)

    let relaunched = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await relaunched.start()
    #expect(try #require(relaunched.gallery).groupsByMonth == false)
  }

  @Test("Auto hide after offers exactly Never plus the seven rungs, labelled")
  func autoHideRungs() {
    #expect(DropZoneAutoHide.choices == [0, 30, 60, 120, 180, 240, 300, 600])
    #expect(
      DropZoneAutoHide.choices.map(DropZoneAutoHide.label)
        == ["Never", "30 s", "1 min", "2 min", "3 min", "4 min", "5 min", "10 min"])
  }

  @Test("The Drop Zone settings pane's Auto hide picker offers exactly those rungs")
  func autoHidePickerRendersTheRungs() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: try makeDefaults(), databaseOpener: { database })
    // The settings scene the app installs (`Settings { PinaxSettingsView(...) }`),
    // on the Drop Zone page.
    app.settingsTab = .dropZone
    let settings = PinaxSettingsView(preferences: app.preferences, app: app)
    #expect(intForEachData(in: settings.body, within: "DropZoneSettingsPane") == [[0, 30, 60, 120, 180, 240, 300, 600]])
  }

  /// Every `ForEach` over `[Int]` inside the first view named `pane`, whose
  /// body is opened on the way down (a pane is a view, not stored content).
  private func intForEachData(in view: Any, within pane: String, inside: Bool = false) -> [[Int]] {
    let typeName = String(describing: type(of: view))
    if typeName.hasPrefix(pane), let paneView = view as? any View {
      return intForEachData(in: openedBody(paneView), within: pane, inside: true)
    }
    let mirror = Mirror(reflecting: view)
    if inside, typeName.hasPrefix("ForEach<Array<Int>"), let data = mirror.descendant("data") as? [Int] {
      return [data]
    }
    return mirror.children.flatMap { intForEachData(in: $0.value, within: pane, inside: inside) }
  }

  private func openedBody<V: View>(_ view: V) -> Any { view.body }

  @Test("A stored 10 s reads back as 30 s under the same key; other rungs are kept")
  func autoHideLegacyValue() throws {
    let defaults = try makeDefaults()
    defaults.set(10, forKey: "pinax.dropZone.autoHideSeconds")
    #expect(PreferencesStore(defaults: defaults).dropZoneAutoHideSeconds == 30)
    for kept in [0, 60, 120, 600] {
      defaults.set(kept, forKey: "pinax.dropZone.autoHideSeconds")
      #expect(PreferencesStore(defaults: defaults).dropZoneAutoHideSeconds == kept)
    }
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(
      UserDefaults(suiteName: "pinaxui-prefs-tests-\(UUID().uuidString)"))
  }
}
