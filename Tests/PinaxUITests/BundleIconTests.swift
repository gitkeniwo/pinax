import Foundation
import ImageIO
import Testing

@Suite("Bundle icon asset contract")
struct BundleIconTests {
  private struct AppIconCatalog: Decodable {
    struct Image: Decodable, Hashable {
      /// Optional in the catalog format: an empty slot has no file. The
      /// artwork test below asserts that ours are all filled.
      let filename: String?
      let idiom: String
      let scale: String
      let size: String
    }

    struct Info: Decodable {
      let author: String
      let version: Int
    }

    let images: [Image]
    let info: Info
  }

  private struct Slot: Hashable {
    let size: String
    let scale: String
  }

  @Test("AppIcon contains the complete, duplicate-free macOS flat size set")
  func appIconSlotsAreComplete() throws {
    let catalog: AppIconCatalog = try decodeJSON(
      at: repositoryRoot
        .appendingPathComponent("PinaxApp/PinaxApp/Assets.xcassets/AppIcon.appiconset/Contents.json"))
    let expected: Set<Slot> = [
      Slot(size: "16x16", scale: "1x"),
      Slot(size: "16x16", scale: "2x"),
      Slot(size: "32x32", scale: "1x"),
      Slot(size: "32x32", scale: "2x"),
      Slot(size: "128x128", scale: "1x"),
      Slot(size: "128x128", scale: "2x"),
      Slot(size: "256x256", scale: "1x"),
      Slot(size: "256x256", scale: "2x"),
      Slot(size: "512x512", scale: "1x"),
      Slot(size: "512x512", scale: "2x"),
    ]
    let actual = catalog.images.map { Slot(size: $0.size, scale: $0.scale) }

    // Positive controls establish that the expected catalog was decoded before
    // the duplicate-free negative assertion is evaluated.
    #expect(catalog.info.author == "xcode")
    #expect(catalog.info.version == 1)
    #expect(catalog.images.allSatisfy { $0.idiom == "mac" })
    #expect(Set(actual) == expected)
    #expect(actual.count == expected.count)
    #expect(Set(actual).count == actual.count)

    let physicalWidths = try catalog.images.map { image in
      let points = try #require(Int(image.size.split(separator: "x")[0]))
      let scale = try #require(Int(image.scale.dropLast()))
      return points * scale
    }
    #expect(physicalWidths.min() == 16)
    #expect(physicalWidths.max() == 1024)
  }

  /// The artwork is rendered from `Design/AppIcon/pinax.svg` by `Scripts/make-app-icon.sh`.
  /// The contract above only checks the shape (ten slots); this asserts
  /// every slot has its file.
  @Test("Every AppIcon slot names a PNG that exists at the declared pixel size")
  func appIconSlotsCarryArtworkAtTheDeclaredSize() throws {
    let iconset = repositoryRoot
      .appendingPathComponent("PinaxApp/PinaxApp/Assets.xcassets/AppIcon.appiconset")
    let catalog: AppIconCatalog = try decodeJSON(at: iconset.appendingPathComponent("Contents.json"))

    #expect(catalog.images.count == 10)
    for image in catalog.images {
      let slot = "\(image.size)@\(image.scale)"
      let filename = try #require(image.filename, "\(slot) has no filename")
      let url = iconset.appendingPathComponent(filename)
      #expect(FileManager.default.fileExists(atPath: url.path), "\(slot): \(filename) is missing")

      let points = try #require(Int(image.size.split(separator: "x")[0]))
      let scale = try #require(Int(image.scale.dropLast()))
      let expected = points * scale

      let source = try #require(
        CGImageSourceCreateWithURL(url as CFURL, nil), "\(slot): \(filename) is not an image")
      let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        "\(slot): \(filename) has no properties")
      #expect(properties[kCGImagePropertyPixelWidth] as? Int == expected, "\(slot): \(filename)")
      #expect(properties[kCGImagePropertyPixelHeight] as? Int == expected, "\(slot): \(filename)")
    }
  }

  @Test("The app target selects AppIcon in both build configurations")
  func appIconIsWiredIntoTheAppTarget() throws {
    let project = try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("PinaxApp/PinaxApp.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    let setting = "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"

    // The synchronized app group is the positive resource-membership control;
    // the two settings are the target's Debug and Release configurations.
    #expect(project.contains("PBXFileSystemSynchronizedRootGroup"))
    #expect(project.contains("path = PinaxApp;"))
    #expect(project.components(separatedBy: setting).count - 1 == 2)
  }

  @Test("The menu bar item draws the chosen template image, not a system symbol")
  func menuBarDrawsChosenImage() throws {
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent("PinaxApp/PinaxApp/PinaxAppApp.swift"),
      encoding: .utf8)

    #expect(!source.contains("photo.stack"))
    #expect(source.contains("MenuBarIconLabel(preferences: app.preferences, activity: app.menuBarActivity)"))
    #expect(source.contains(".menuBarExtraStyle(.window)"))
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func decodeJSON<Value: Decodable>(at url: URL) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
  }
}
