import Foundation
import ImageIO
@testable import PinaxUI
import Testing

/// Settings ▸ Appearance ▸ Menu Bar Icon. Only the
/// preference, the pure choice of image and the files on disk are tested;
/// the real menu bar item is never created. Own UserDefaults suites.
@MainActor
@Suite struct MenuBarIconTests {
  // MARK: - Preferences

  @Test("A fresh install shows Tablet")
  func defaultIsTablet() throws {
    let store = PreferencesStore(defaults: try makeDefaults())
    #expect(store.menuBarIconID == "tablet")
  }

  @Test("The choice survives a relaunch, for every icon")
  func roundTrip() throws {
    for icon in MenuBarIconCatalog.icons {
      let defaults = try makeDefaults()
      PreferencesStore(defaults: defaults).menuBarIconID = icon.id
      #expect(PreferencesStore(defaults: defaults).menuBarIconID == icon.id, "\(icon.id)")
    }
  }

  @Test("A stored id that is no longer offered reads as Tablet")
  func unknownIDFallsBack() throws {
    let defaults = try makeDefaults()
    defaults.set("retired-icon", forKey: "pinax.appearance.menuBarIcon")
    #expect(PreferencesStore(defaults: defaults).menuBarIconID == "tablet")
    defaults.set("", forKey: "pinax.appearance.menuBarIcon")
    #expect(PreferencesStore(defaults: defaults).menuBarIconID == "tablet")
  }

  // MARK: - Preference → image name

  @Test("Preference → image name, every icon; an unknown id draws the default")
  func imageNameIsPure() {
    let expected = [
      "tablet": "MenuBarIcon-tablet",
      "tablet-outline": "MenuBarIcon-tablet-outline",
      "tablet-upload": "MenuBarIcon-tablet-upload",
      "aten": "MenuBarIcon-aten",
      "aten-outline": "MenuBarIcon-aten-outline",
      "aten-fan": "MenuBarIcon-aten-fan",
      "horizon-upload": "MenuBarIcon-horizon-upload",
    ]
    #expect(MenuBarIconCatalog.icons.count == expected.count)
    for icon in MenuBarIconCatalog.icons {
      #expect(MenuBarIconCatalog.imageName(for: icon.id) == expected[icon.id], "\(icon.id)")
      #expect(icon.assetName == expected[icon.id], "\(icon.id)")
    }
    #expect(MenuBarIconCatalog.imageName(for: "retired-icon") == "MenuBarIcon-tablet")
    #expect(MenuBarIconCatalog.imageName(for: "") == "MenuBarIcon-tablet")
  }

  @Test("the three tablet glyphs are drawn at 21 pt, the others at the image's own 18 pt; unknown reads as Tablet")
  func displaySizes() {
    for icon in MenuBarIconCatalog.icons {
      let expected: CGFloat = icon.id.hasPrefix("tablet") ? 21 : 18
      #expect(MenuBarIconCatalog.displaySize(for: icon.id) == expected, "\(icon.id)")
    }
    #expect(MenuBarIconCatalog.icons.filter { MenuBarIconCatalog.displaySize(for: $0.id) == 21 }.count == 3)
    #expect(MenuBarIconCatalog.displaySize(for: "retired-icon") == 21)
  }

  @Test("The menu bar item's label follows the store at once, and never draws a blank")
  func labelFollowsTheStore() throws {
    let store = PreferencesStore(defaults: try makeDefaults())
    let label = MenuBarIconLabel(preferences: store)
    #expect(label.imageName == "MenuBarIcon-tablet")
    store.menuBarIconID = "aten-fan"
    #expect(label.imageName == "MenuBarIcon-aten-fan")
    store.menuBarIconID = "retired-icon"  // set at run time, not read at launch
    #expect(label.imageName == "MenuBarIcon-tablet")
  }

  // MARK: - Manifest, code and asset catalog agree

  @Test("The manifest, the code's list and the asset catalog's MenuBarIcons agree; every set is template, 18/36/54 px")
  func manifestCodeAndAssetsAgree() throws {
    struct Manifest: Decodable {
      struct Icon: Decodable {
        let id: String
        let name: String
        let `default`: Bool?
      }
      let icons: [Icon]
    }
    let manifest = try JSONDecoder().decode(
      Manifest.self,
      from: Data(
        contentsOf: repositoryRoot.appendingPathComponent("Design/MenuBarIcon/menu-bar-icons.json")))
    #expect(manifest.icons.count >= 2)
    #expect(manifest.icons.map(\.id) == MenuBarIconCatalog.icons.map(\.id))
    #expect(manifest.icons.map(\.name) == MenuBarIconCatalog.icons.map(\.name))
    #expect(manifest.icons.filter { $0.default ?? false }.map(\.id) == [MenuBarIconCatalog.defaultID])
    #expect(MenuBarIconCatalog.known(MenuBarIconCatalog.defaultID) != nil)

    let folder = repositoryRoot.appendingPathComponent(
      "PinaxApp/PinaxApp/Assets.xcassets/MenuBarIcons", isDirectory: true)
    let sets = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      .filter { $0.hasSuffix(".imageset") }
    let expected = MenuBarIconCatalog.icons.map { "\($0.assetName).imageset" }
    #expect(Set(sets) == Set(expected), "\(sets.sorted())")
    #expect(sets.count == expected.count)

    struct ImageSet: Decodable {
      struct Image: Decodable {
        let filename: String?
        let scale: String?
      }
      struct Properties: Decodable {
        let templateRenderingIntent: String?
        enum CodingKeys: String, CodingKey { case templateRenderingIntent = "template-rendering-intent" }
      }
      let images: [Image]
      let properties: Properties?
    }
    let sizes = ["1x": 18, "2x": 36, "3x": 54]
    for icon in MenuBarIconCatalog.icons {
      let set = folder.appendingPathComponent("\(icon.assetName).imageset", isDirectory: true)
      let contents = try JSONDecoder().decode(
        ImageSet.self, from: Data(contentsOf: set.appendingPathComponent("Contents.json")))
      #expect(contents.properties?.templateRenderingIntent == "template", "\(icon.id)")
      #expect(contents.images.compactMap(\.scale).sorted() == ["1x", "2x", "3x"], "\(icon.id)")
      for image in contents.images {
        let scale = try #require(image.scale, "\(icon.id)")
        let file = try #require(image.filename, "\(icon.id) \(scale)")
        #expect(file.hasSuffix(".png"), "\(icon.id)/\(file)")
        let url = set.appendingPathComponent(file)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(icon.id)/\(file)")
        let properties = try #require(
          CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let side = try #require(sizes[scale])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == side, "\(icon.id)/\(file)")
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == side, "\(icon.id)/\(file)")
      }
    }
  }

  // MARK: - Helpers

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-menu-bar-icon-\(UUID().uuidString)"))
  }
}
