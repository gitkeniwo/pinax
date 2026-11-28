import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import CatalogCore

/// The upload compressor: sizes, orientation, color profiles, metadata,
/// which formats are skipped and when a copy saves enough. Every image is
/// drawn in code by `CompressionFixtures`.
@Suite struct ImageCompressorTests {
  private typealias F = CompressionFixtures

  private let gps: [CFString: Any] = [
    kCGImagePropertyGPSLatitude: 52.37,
    kCGImagePropertyGPSLatitudeRef: "N",
    kCGImagePropertyGPSLongitude: 4.89,
    kCGImagePropertyGPSLongitudeRef: "E",
  ]

  /// A photo saved at full JPEG quality, so any of the three steps shrinks it.
  private func photoJPEG(
    width: Int = 800,
    height: Int = 600,
    space: CGColorSpace = F.sRGB,
    properties: [CFString: Any] = [:]
  ) throws -> Data {
    try F.jpeg(F.photo(width: width, height: height, noise: 10, space: space), properties: properties)
  }

  private func compressed(_ data: Data, _ options: CompressionOptions) throws -> CompressedImage {
    let result = ImageCompressor.compress(data, options: options)
    return try #require(result.compressedImage, "expected a compressed copy, got \(result)")
  }

  // MARK: - Size

  @Test func shrinksToTheLongestEdge() throws {
    let landscape = try compressed(
      photoJPEG(width: 1200, height: 900), CompressionOptions(longestEdge: 800))
    #expect(landscape.width == 800)
    #expect(landscape.height == 600)
    #expect(landscape.sourceWidth == 1200)
    #expect(landscape.sourceHeight == 900)

    let portrait = try compressed(
      photoJPEG(width: 900, height: 1200), CompressionOptions(longestEdge: 800))
    #expect(portrait.width == 600)
    #expect(portrait.height == 800)
  }

  @Test func neverEnlarges() throws {
    let source = try photoJPEG(width: 600, height: 450)
    for edge in [2048, nil] as [Int?] {
      let image = try compressed(source, CompressionOptions(longestEdge: edge))
      #expect(image.width == 600)
      #expect(image.height == 450)
    }
  }

  // MARK: - Orientation, color, metadata

  @Test(arguments: [true, false])
  func drawsTheOrientationIntoThePixels(removesMetadata: Bool) throws {
    // Stored 800 × 600 with red on the left; orientation 6 shows it turned
    // a quarter clockwise, so the red half is on top.
    var random = F.SplitMix64(seed: 3)
    let stored = try F.image(width: 800, height: 600) { x, _ in
      let jitter = Int(random.next() % 21) - 10
      return x < 400 ? (220 + jitter, 30, 30, 255) : (30, 30, 220 + jitter, 255)
    }
    let source = try F.jpeg(stored, properties: [kCGImagePropertyOrientation: 6])

    let image = try compressed(
      source, CompressionOptions(longestEdge: nil, removesMetadata: removesMetadata))
    #expect(image.width == 600)
    #expect(image.height == 800)
    #expect(image.sourceWidth == 600)
    #expect(image.sourceHeight == 800)

    let properties = F.properties(of: image.data)
    #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect((tiff?[kCGImagePropertyTIFFOrientation] as? Int ?? 1) == 1)

    let decoded = try #require(F.decoded(image.data))
    #expect(decoded.width == 600)
    #expect(decoded.height == 800)
    let top = try #require(F.pixel(of: decoded, x: 300, y: 200))
    let bottom = try #require(F.pixel(of: decoded, x: 300, y: 600))
    #expect(top.r > 150 && top.b < 100, "top should be red, got \(top)")
    #expect(bottom.b > 150 && bottom.r < 100, "bottom should be blue, got \(bottom)")
  }

  @Test(arguments: [true, false])
  func keepsTheDisplayP3Profile(removesMetadata: Bool) throws {
    let source = try photoJPEG(space: F.displayP3)
    #expect(F.properties(of: source)[kCGImagePropertyProfileName] as? String == "Display P3")

    let image = try compressed(source, CompressionOptions(removesMetadata: removesMetadata))
    #expect(F.properties(of: image.data)[kCGImagePropertyProfileName] as? String == "Display P3")
    let decoded = try #require(F.decoded(image.data))
    #expect(decoded.colorSpace?.name == CGColorSpace.displayP3)
  }

  private func photoWithLocation() throws -> Data {
    try photoJPEG(properties: [
      kCGImagePropertyGPSDictionary: gps,
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:11:01 10:00:00"
      ],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test Camera"],
    ])
  }

  @Test func removingMetadataDropsLocationAndCameraFields() throws {
    let source = try photoWithLocation()
    #expect(F.properties(of: source)[kCGImagePropertyGPSDictionary] != nil)

    let image = try compressed(source, CompressionOptions(removesMetadata: true))
    let properties = F.properties(of: image.data)
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
  }

  @Test func keepingMetadataCopiesLocationAndCameraFields() throws {
    let image = try compressed(
      photoWithLocation(), CompressionOptions(longestEdge: 400, removesMetadata: false))
    let properties = F.properties(of: image.data)
    let location = try #require(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
    #expect((location[kCGImagePropertyGPSLatitude] as? Double).map { abs($0 - 52.37) < 0.001 } == true)
    #expect(location[kCGImagePropertyGPSLatitudeRef] as? String == "N")
    let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:11:01 10:00:00")
    #expect(exif[kCGImagePropertyExifPixelXDimension] as? Int == 400)
    let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    #expect(tiff[kCGImagePropertyTIFFMake] as? String == "Test Camera")
  }

  @Test func convertsSixteenBitAndCMYKToEightBitRGB() throws {
    let photo = try F.photo(width: 600, height: 400, noise: 10)

    let sixteenBit = try F.png(F.redrawn(photo, bitsPerComponent: 16, space: F.sRGB))
    #expect(F.decoded(sixteenBit)?.bitsPerComponent == 16)
    let fromSixteen = try #require(
      F.decoded(compressed(sixteenBit, CompressionOptions(longestEdge: nil)).data))
    #expect(fromSixteen.bitsPerComponent == 8)
    #expect(fromSixteen.colorSpace?.model == .rgb)

    let cmyk = try F.jpeg(
      F.redrawn(photo, bitsPerComponent: 8, space: CGColorSpaceCreateDeviceCMYK()))
    #expect(F.decoded(cmyk)?.colorSpace?.model == .cmyk)
    let fromCMYK = try #require(
      F.decoded(compressed(cmyk, CompressionOptions(longestEdge: nil)).data))
    #expect(fromCMYK.bitsPerComponent == 8)
    #expect(fromCMYK.colorSpace?.model == .rgb)
  }

  // MARK: - Formats

  @Test func skipsAPNGWithOneTransparentPixel() throws {
    let image = try F.photo(width: 400, height: 300, noise: 10, alphaInfo: .premultipliedLast) {
      x, y in x == 17 && y == 23 ? 0 : 255
    }
    let result = ImageCompressor.compress(try F.png(image), options: .default)
    #expect(result == .skipped(.transparent))
  }

  @Test func convertsAnOpaquePNGToJPEG() throws {
    // An alpha channel that is opaque everywhere, as many screenshots have.
    let image = try F.photo(width: 800, height: 600, noise: 10, alphaInfo: .premultipliedLast)
    let source = try F.png(image)
    let stored = try #require(F.decoded(source))
    #expect([.last, .premultipliedLast, .first, .premultipliedFirst].contains(stored.alphaInfo))

    let copy = try compressed(source, .default)
    #expect(copy.mime == "image/jpeg")
    #expect(copy.fileExtension == "jpg")
    #expect(copy.sourceMime == "image/png")
    #expect(copy.sourceByteSize == source.count)
    #expect(copy.byteSize < source.count)
    #expect(F.properties(of: copy.data)[kCGImagePropertyJFIFDictionary] != nil)
  }

  @Test func leavesAScreenshotPNGThatWouldNotShrink() throws {
    let source = try F.png(F.screenshot(width: 1440, height: 900))
    #expect(ImageCompressor.compress(source, options: .default) == .skipped(.notSmaller))
    let unresized = CompressionOptions(longestEdge: nil, quality: 60)
    #expect(ImageCompressor.compress(source, options: unresized) == .skipped(.notSmaller))
  }

  @Test func leavesAJPEGThatWouldNotShrink() throws {
    let source = try F.jpeg(F.photo(width: 800, height: 600, noise: 10), quality: 0.5)
    let options = CompressionOptions(longestEdge: nil, quality: 85)
    #expect(ImageCompressor.compress(source, options: options) == .skipped(.notSmaller))
  }

  @Test(.enabled(if: CompressionFixtures.canEncodeHEIC))
  func alwaysConvertsHEICEvenWhenItSavesNothing() throws {
    let source = try F.heic(F.photo(width: 64, height: 64, noise: 0))
    #expect(source.count < ImageCompressor.minimumSavedBytes)

    let copy = try compressed(source, .default)
    #expect(copy.mime == "image/jpeg")
    #expect(copy.fileExtension == "jpg")
    #expect(copy.sourceMime == "image/heic")
    #expect(!ImageCompressor.savesEnough(sourceByteSize: source.count, outputByteSize: copy.byteSize))
    #expect(CGImageSourceGetType(CGImageSourceCreateWithData(copy.data as CFData, nil)!) as String?
      == "public.jpeg")
  }

  @Test func skipsAnimatedGIF() throws {
    let red = try F.image(width: 64, height: 64) { _, _ in (220, 30, 30, 255) }
    let blue = try F.image(width: 64, height: 64) { _, _ in (30, 30, 220, 255) }
    let source = try F.gif([red, blue])
    #expect(ImageCompressor.compress(source, options: .default) == .skipped(.animated))
  }

  @Test func skipsStillGIFAndSVG() throws {
    let still = try F.gif([F.image(width: 64, height: 64) { _, _ in (30, 30, 220, 255) }])
    #expect(ImageCompressor.compress(still, options: .default) == .skipped(.unsupportedFormat))

    let svg = Data(
      #"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>"#
        .utf8)
    #expect(ImageCompressor.compress(svg, options: .default) == .skipped(.unsupportedFormat))
  }

  @Test func reportsBytesThatAreNotAnImage() {
    #expect(ImageCompressor.compress(Data(), options: .default) == .skipped(.unreadable))
    let noise = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    #expect(ImageCompressor.compress(noise, options: .default) == .skipped(.unreadable))
  }

  // MARK: - Quality and threshold

  @Test func qualityStepsGetSmallerInOrder() throws {
    let source = try photoJPEG()
    let sizes = try ([85, 75, 60] as [CompressionQuality]).map {
      try compressed(source, CompressionOptions(longestEdge: nil, quality: $0)).byteSize
    }
    #expect(sizes[0] > sizes[1])
    #expect(sizes[1] > sizes[2])
    #expect(([85, 75, 60, 40, 100] as [CompressionQuality]).map(\.jpegQuality) == [0.85, 0.75, 0.6, 0.4, 1])
  }

  @Test func aCopyMustSaveTenPercent() {
    #expect(ImageCompressor.savesEnough(sourceByteSize: 1_000_000, outputByteSize: 900_000))
    #expect(!ImageCompressor.savesEnough(sourceByteSize: 1_000_000, outputByteSize: 900_001))
  }

  @Test func aCopyMustSaveTwentyKilobytes() {
    #expect(ImageCompressor.savesEnough(sourceByteSize: 100_000, outputByteSize: 80_000))
    #expect(!ImageCompressor.savesEnough(sourceByteSize: 100_000, outputByteSize: 80_001))
    #expect(!ImageCompressor.savesEnough(sourceByteSize: 50_000, outputByteSize: 60_000))
  }

  // MARK: - Options

  @Test func fingerprintIsStable() {
    #expect(CompressionOptions.default == CompressionOptions(longestEdge: 2048, quality: 85, removesMetadata: true))
    #expect(CompressionOptions.default.fingerprint == "e2048-q85-m1")
    #expect(
      CompressionOptions(longestEdge: nil, quality: 60, removesMetadata: false).fingerprint
        == "enone-q60-m0")
    #expect(CompressionOptions(longestEdge: 3840, quality: 75).fingerprint == "e3840-q75-m1")

    var all = Set<String>()
    for edge in [1600, 2048, 2560, 3840, nil] as [Int?] {
      for quality in [85, 75, 60] as [CompressionQuality] {
        for removes in [true, false] {
          all.insert(
            CompressionOptions(longestEdge: edge, quality: quality, removesMetadata: removes)
              .fingerprint)
        }
      }
    }
    #expect(all.count == 30)
  }

  @Test("A quality is a whole percentage from 40 to 100; the old names read as 85, 75 and 60")
  func qualityPercentages() throws {
    #expect(CompressionQuality.default.percent == 85)
    #expect(CompressionOptions.default.quality == 85)
    #expect(CompressionQuality.ticks == [60, 75, 85])
    #expect(CompressionQuality(parsing: "high")?.percent == 85)
    #expect(CompressionQuality(parsing: "Medium")?.percent == 75)
    #expect(CompressionQuality(parsing: "small")?.percent == 60)
    #expect(CompressionQuality(parsing: "40")?.percent == 40)
    #expect(CompressionQuality(parsing: "100")?.percent == 100)
    #expect(CompressionQuality(parsing: "39") == nil)
    #expect(CompressionQuality(parsing: "101") == nil)
    #expect(CompressionQuality(parsing: "85.5") == nil)
    #expect(CompressionQuality(parsing: "huge") == nil)
    #expect(CompressionQuality(json: NSNumber(value: 70))?.percent == 70)
    #expect(CompressionQuality(json: NSNumber(value: 0.7)) == nil)
    #expect(CompressionQuality(json: "small")?.percent == 60)
    #expect(CompressionQuality(json: NSNumber(value: 20)) == nil)
    #expect(CompressionQuality(5).percent == 40 && CompressionQuality(500).percent == 100)
    #expect(CompressionQuality(85).description == "85%")

    // Codable writes a number and reads a number or an old name.
    #expect(String(decoding: try JSONEncoder().encode([CompressionQuality(70)]), as: UTF8.self) == "[70]")
    let decoded = try JSONDecoder().decode([CompressionQuality].self, from: Data(#"[70, "high", "small"]"#.utf8))
    #expect(decoded.map(\.percent) == [70, 85, 60])
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([CompressionQuality].self, from: Data("[30]".utf8))
    }
  }

  @Test("Fingerprints that name the old steps read as their percentage")
  func legacyFingerprints() {
    #expect(CompressionOptions.normalizedFingerprint("e2048-qhigh-m1") == "e2048-q85-m1")
    #expect(CompressionOptions.normalizedFingerprint("enone-qmedium-m0") == "enone-q75-m0")
    #expect(CompressionOptions.normalizedFingerprint("e3840-qsmall-m1") == "e3840-q60-m1")
    #expect(CompressionOptions.normalizedFingerprint("e2048-q72-m1") == "e2048-q72-m1")
    #expect(CompressionOptions.normalizedFingerprint("e2048-qhuge-m1") == "e2048-qhuge-m1")
    #expect(
      CompressionOptions.normalizedFingerprint("e2048-qhigh-m1") == CompressionOptions.default.fingerprint)
  }
}
