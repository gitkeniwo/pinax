import AppKit
import Foundation
import ImageIO
@testable import PinaxUI
import Testing

/// Settings ▸ Appearance ▸ App Icon. The Dock icon
/// is swapped at run time only; these tests never touch `NSApp`'s icon —
/// the applier's image source and icon setter are the test's own — and use
/// their own UserDefaults suites.
@MainActor
@Suite struct DockIconTests {
  // MARK: - Preferences

  @Test("Defaults are match off and the bundle icon everywhere, the dark slot included")
  func defaults() throws {
    let store = PreferencesStore(defaults: try makeDefaults())
    #expect(store.dockIconID == "ivory-glyph")
    #expect(store.dockIconMatchesSystem == false)
    #expect(store.dockIconLightID == nil)
    #expect(store.effectiveDockIconLightID == "ivory-glyph")
    #expect(store.dockIconDarkID == "ivory-glyph")
  }

  @Test("Every field survives a relaunch")
  func roundTrip() throws {
    let defaults = try makeDefaults()
    let first = PreferencesStore(defaults: defaults)
    first.dockIconID = "sage-linen"
    first.dockIconMatchesSystem = true
    first.dockIconLightID = "limestone"
    first.dockIconDarkID = "museum-spotlight"

    let second = PreferencesStore(defaults: defaults)
    #expect(second.dockIconID == "sage-linen")
    #expect(second.dockIconMatchesSystem == true)
    #expect(second.dockIconLightID == "limestone")
    #expect(second.dockIconDarkID == "museum-spotlight")
  }

  @Test("The first time Match System Appearance is turned on, Light takes the current icon and Dark Ivory Glyph")
  func firstMatchSeedsTheSlots() throws {
    let defaults = try makeDefaults()
    let store = PreferencesStore(defaults: defaults)
    store.dockIconID = "sage-linen"
    store.dockIconMatchesSystem = true
    #expect(store.dockIconLightID == "sage-linen")
    #expect(store.dockIconDarkID == "ivory-glyph")
    #expect(PreferencesStore(defaults: defaults).dockIconLightID == "sage-linen")

    // Only the first time: a Light chosen since stays when the icon changes.
    store.dockIconMatchesSystem = false
    store.dockIconID = "limestone"
    store.dockIconMatchesSystem = true
    #expect(store.dockIconLightID == "sage-linen")
  }

  @Test("A stored id that is no longer offered reads as that slot's default")
  func unknownIDsFallBack() throws {
    let defaults = try makeDefaults()
    for key in [
      "pinax.appearance.dockIcon", "pinax.appearance.dockIcon.light",
      "pinax.appearance.dockIcon.dark",
    ] {
      defaults.set("retired-icon", forKey: key)
    }
    let store = PreferencesStore(defaults: defaults)
    #expect(store.dockIconID == "ivory-glyph")
    #expect(store.dockIconLightID == nil)
    #expect(store.effectiveDockIconLightID == "ivory-glyph")
    #expect(store.dockIconDarkID == "ivory-glyph")
  }

  static let removedIDs = ["spotlight", "gilded-damask", "crimson-velvet", "midnight-polychrome"]

  @Test("The four removed icons are in none of the three lists")
  func removedIconsAreGone() throws {
    #expect(DockIconCatalog.icons.count == 7)
    for id in Self.removedIDs {
      #expect(!DockIconCatalog.icons.contains { $0.id == id }, "\(id) in icons")
      let manifest = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Design/AppIcon/dock-icons.json"),
        encoding: .utf8)
      #expect(!manifest.contains("\"\(id)\""), "\(id) in manifest")
      let set = repositoryRoot.appendingPathComponent(
        "PinaxApp/PinaxApp/Assets.xcassets/DockIcons/DockIcon-\(id).imageset")
      #expect(!FileManager.default.fileExists(atPath: set.path), "\(id) image set")
    }
  }

  @Test("With fresh preferences the single pick, and Light and Dark once Match System Appearance is on, are all Ivory Glyph")
  func freshPreferencesAreIvoryGlyphEverywhere() throws {
    let store = PreferencesStore(defaults: try makeDefaults())
    #expect(store.dockIconID == "ivory-glyph")
    store.dockIconMatchesSystem = true
    #expect(store.effectiveDockIconLightID == "ivory-glyph")
    #expect(store.dockIconDarkID == "ivory-glyph")
    for dark in [false, true] {
      #expect(
        DockIconCatalog.iconID(
          matchesSystem: true, selected: store.dockIconID, light: store.effectiveDockIconLightID,
          dark: store.dockIconDarkID, systemIsDark: dark) == "ivory-glyph")
    }
  }

  @Test("Removed ids stored in any of the three keys read as Ivory Glyph and are not written back")
  func removedStoredIDsReadAsIvoryGlyphAndStay() throws {
    let keys = [
      "pinax.appearance.dockIcon", "pinax.appearance.dockIcon.light",
      "pinax.appearance.dockIcon.dark",
    ]
    for (offset, id) in Self.removedIDs.enumerated() {
      let defaults = try makeDefaults()
      for key in keys { defaults.set(id, forKey: key) }
      defaults.set(true, forKey: "pinax.appearance.dockIcon.matchesSystem")
      let store = PreferencesStore(defaults: defaults)
      #expect(store.dockIconID == "ivory-glyph", "\(id)")
      #expect(store.effectiveDockIconLightID == "ivory-glyph", "\(id)")
      #expect(store.dockIconDarkID == "ivory-glyph", "\(id)")
      for dark in [false, true] {
        #expect(
          DockIconCatalog.iconID(
            matchesSystem: true, selected: id, light: id, dark: id, systemIsDark: dark)
            == "ivory-glyph", "\(id)")
        #expect(
          DockIconCatalog.iconID(
            matchesSystem: false, selected: id, light: id, dark: id, systemIsDark: dark)
            == "ivory-glyph", "\(id)")
      }
      // Reading changed nothing on disk, even after a second launch.
      _ = PreferencesStore(defaults: defaults)
      for key in keys { #expect(defaults.string(forKey: key) == id, "\(offset) \(key)") }
    }
  }

  // MARK: - Which icon

  @Test("(match, selected, light, dark, system dark) → icon, every combination")
  func choiceIsExhaustive() {
    let ids = DockIconCatalog.icons.map(\.id) + ["retired-icon"]
    let offered = Set(DockIconCatalog.icons.map(\.id))
    var checked = 0
    for matches in [false, true] {
      for systemIsDark in [false, true] {
        for selected in ids {
          for light in ids {
            for dark in ids {
              let chosen: String
              switch (matches, systemIsDark) {
              case (false, _): chosen = selected
              case (true, false): chosen = light
              case (true, true): chosen = dark
              }
              let expected = offered.contains(chosen) ? chosen : "ivory-glyph"
              let got = DockIconCatalog.iconID(
                matchesSystem: matches, selected: selected, light: light, dark: dark,
                systemIsDark: systemIsDark)
              #expect(got == expected, "\(matches) \(selected) \(light) \(dark) \(systemIsDark)")
              checked += 1
            }
          }
        }
      }
    }
    // Every offered icon plus one retired id, in each of the three slots.
    let n = DockIconCatalog.icons.count + 1
    #expect(checked == 2 * 2 * n * n * n)
    // Spot checks written out.
    #expect(DockIconCatalog.iconID(
      matchesSystem: false, selected: "sage-linen", light: "limestone",
      dark: "ivory-linen", systemIsDark: true) == "sage-linen")
    #expect(DockIconCatalog.iconID(
      matchesSystem: true, selected: "sage-linen", light: "limestone",
      dark: "ivory-linen", systemIsDark: true) == "ivory-linen")
    #expect(DockIconCatalog.iconID(
      matchesSystem: true, selected: "sage-linen", light: "limestone",
      dark: "ivory-linen", systemIsDark: false) == "limestone")
  }

  // MARK: - Manifest, code and asset catalog agree

  @Test("The manifest, the code's list and the asset catalog's DockIcons agree; every image is 1024 px")
  func manifestCodeAndAssetsAgree() throws {
    struct Manifest: Decodable {
      struct Icon: Decodable {
        let id: String
        let name: String
        let bundle: Bool?
      }
      let icons: [Icon]
    }
    let manifest = try JSONDecoder().decode(
      Manifest.self,
      from: Data(contentsOf: repositoryRoot.appendingPathComponent("Design/AppIcon/dock-icons.json")))
    #expect(manifest.icons.count >= 2)
    #expect(manifest.icons.map(\.id) == DockIconCatalog.icons.map(\.id))
    #expect(manifest.icons.map(\.name) == DockIconCatalog.icons.map(\.name))
    #expect(manifest.icons.map { $0.bundle ?? false } == DockIconCatalog.icons.map(\.isBundle))
    #expect(DockIconCatalog.icons.filter(\.isBundle).map(\.id) == [DockIconCatalog.bundleID])
    #expect(DockIconCatalog.icons.contains { $0.id == DockIconCatalog.darkDefaultID })

    let folder = repositoryRoot.appendingPathComponent(
      "PinaxApp/PinaxApp/Assets.xcassets/DockIcons", isDirectory: true)
    let sets = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      .filter { $0.hasSuffix(".imageset") }
    let expected = DockIconCatalog.icons.compactMap(\.assetName).map { "\($0).imageset" }
    #expect(!expected.isEmpty)
    #expect(Set(sets) == Set(expected), "\(sets.sorted())")

    struct ImageSet: Decodable {
      struct Image: Decodable { let filename: String? }
      let images: [Image]
    }
    for name in expected {
      let set = folder.appendingPathComponent(name, isDirectory: true)
      let contents = try JSONDecoder().decode(
        ImageSet.self, from: Data(contentsOf: set.appendingPathComponent("Contents.json")))
      let files = contents.images.compactMap(\.filename)
      #expect(files.count == 1, "\(name)")
      for file in files {
        #expect(file.hasSuffix(".png"), "\(name)/\(file)")
        let url = set.appendingPathComponent(file)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(name)/\(file)")
        let properties = try #require(
          CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024, "\(name)/\(file)")
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1024, "\(name)/\(file)")
      }
    }
  }

  // MARK: - The applier

  @Test("A change applies at once; the bundle icon restores the app's own; a missing image is not a blank")
  func applierFollowsPreferences() throws {
    let store = PreferencesStore(defaults: try makeDefaults())
    var isDark = false
    var applied: [String?] = []
    // One image per id, told apart by identity.
    let images = Dictionary(
      uniqueKeysWithValues: DockIconCatalog.icons.map { ($0.id, NSImage(size: NSSize(width: 1, height: 1))) })
    let applier = DockIconApplier(
      preferences: store,
      image: { id in id == "limestone" ? nil : images[id] },
      systemIsDark: { isDark },
      setIcon: { image in
        applied.append(image.map { image in images.first { $0.value === image }?.key ?? "<other image>" })
      })
    applier.start()
    #expect(applied == [nil])  // the bundle icon: restore, not a copy of it

    store.dockIconID = "sage-linen"
    #expect(applied.last == "sage-linen")

    // An image the app cannot find restores the app's own icon.
    store.dockIconID = "limestone"
    #expect(applied.last == .some(nil))

    // Match System Appearance: the system's appearance decides.
    store.dockIconID = "sage-linen"
    store.dockIconMatchesSystem = true
    #expect(applied.last == "sage-linen")
    isDark = true
    applier.appearanceDidChange()
    #expect(applied.last == .some(nil))  // Dark slot defaults to the bundle icon: restore

    // The Dock tile coming back re-applies the same choice.
    let count = applied.count
    applier.reapply()
    #expect(applied.count == count + 1)
    #expect(applied.last == .some(nil))
  }

  @Test("Following the system with Light ≠ the selected icon — light shows Light, dark shows Dark")
  func lightSlotIsShown() throws {
    let store = PreferencesStore(defaults: try makeDefaults())
    store.dockIconID = "sage-linen"
    store.dockIconMatchesSystem = true
    store.dockIconLightID = "limestone"
    store.dockIconDarkID = "museum-spotlight"
    var isDark = false
    var applied: [String?] = []
    let images = Dictionary(
      uniqueKeysWithValues: DockIconCatalog.icons.map { ($0.id, NSImage(size: NSSize(width: 1, height: 1))) })
    let applier = DockIconApplier(
      preferences: store,
      image: { images[$0] },
      systemIsDark: { isDark },
      setIcon: { image in
        applied.append(image.map { image in images.first { $0.value === image }?.key ?? "<other image>" })
      })
    applier.start()
    #expect(applied == ["limestone"])
    isDark = true
    applier.appearanceDidChange()
    #expect(applied.last == "museum-spotlight")
    isDark = false
    applier.appearanceDidChange()
    #expect(applied.last == "limestone")
  }

  // MARK: - Installed at launch

  @Test("The app model installs the applier at launch — applied once, no window hosted")
  func appInstallsTheApplierAtLaunch() throws {
    let defaults = try makeDefaults()
    let seeded = PreferencesStore(defaults: defaults)
    seeded.dockIconID = "sage-linen"
    seeded.dockIconMatchesSystem = true
    seeded.dockIconLightID = "limestone"
    var setCount = 0
    let app = PinaxAppModel(
      dockIcon: { preferences in
        DockIconApplier(
          preferences: preferences, image: { _ in nil }, systemIsDark: { false },
          setIcon: { _ in setCount += 1 })
      },
      defaults: defaults)
    #expect(setCount == 1)
    #expect(app.dockIconApplier?.appliedID == "limestone")

    // The installed applier follows the app's own preferences.
    app.preferences.dockIconMatchesSystem = false
    #expect(setCount == 2)
    #expect(app.dockIconApplier?.appliedID == "sage-linen")
  }

  // MARK: - Helpers

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-dock-icon-\(UUID().uuidString)"))
  }
}
