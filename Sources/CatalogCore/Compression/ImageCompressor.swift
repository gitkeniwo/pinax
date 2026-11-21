import CoreGraphics
import Foundation
import ImageIO

/// Recompresses image bytes into a smaller JPEG for upload.
///
/// A pure function of its input: it reads no files, touches no network or
/// catalog, and never changes the caller's bytes. The rules:
///
/// - Images are only ever scaled down, to `longestEdge`, never up.
/// - The EXIF orientation is drawn into the pixels and the output says 1.
/// - Sixteen-bit, CMYK and other sources become 8-bit RGB (or 8-bit gray);
///   an RGB or gray color profile such as Display P3 is kept.
/// - JPEG becomes JPEG, and an opaque PNG becomes JPEG, but only when the copy
///   saves at least 10% and at least 20 kB; otherwise the result is
///   `.skipped(.notSmaller)` and the original should be uploaded.
/// - HEIC always becomes JPEG, whatever the size, because browsers cannot
///   show HEIC.
/// - PNGs with any transparent pixel, anything with more than one frame, and
///   other formats (GIF, WebP, SVG, TIFF…) are skipped.
public enum ImageCompressor {
  /// The least a copy must save, as a fraction of the source.
  static let minimumSavedPercent = 10
  /// The least a copy must save, in bytes.
  static let minimumSavedBytes = 20_000

  static let outputMime = "image/jpeg"
  static let outputExtension = "jpg"

  public static func compress(_ data: Data, options: CompressionOptions) -> CompressionResult {
    if looksLikeMarkup(data) {
      return .skipped(.unsupportedFormat)
    }

    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard
      let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
      let typeIdentifier = CGImageSourceGetType(source) as String?
    else {
      return .skipped(.unreadable)
    }

    let frameCount = CGImageSourceGetCount(source)
    if frameCount == 0 {
      return .skipped(.unreadable)
    }
    if frameCount > 1 {
      return .skipped(.animated)
    }

    guard let format = SourceFormat(typeIdentifier: typeIdentifier) else {
      return .skipped(.unsupportedFormat)
    }

    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
        as? [CFString: Any],
      let storedWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let storedHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      storedWidth > 0, storedHeight > 0
    else {
      return .skipped(.unreadable)
    }

    if format == .png {
      guard let fullImage = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions) else {
        return .skipped(.unreadable)
      }
      if hasTransparentPixels(fullImage) {
        return .skipped(.transparent)
      }
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let swapsAxes = (5...8).contains(orientation)
    let sourceWidth = swapsAxes ? storedHeight : storedWidth
    let sourceHeight = swapsAxes ? storedWidth : storedHeight

    let sourceLongest = max(storedWidth, storedHeight)
    let targetLongest = max(1, min(options.longestEdge ?? sourceLongest, sourceLongest))
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: targetLongest,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let decoded = CGImageSourceCreateThumbnailAtIndex(
        source, 0, thumbnailOptions as CFDictionary),
      let image = eightBitImage(from: decoded),
      let encoded = encodeJPEG(
        image,
        quality: options.quality,
        sourceProperties: options.removesMetadata ? nil : properties)
    else {
      return .skipped(.unreadable)
    }

    if format.compressesOnlyWhenSmaller
      && !savesEnough(sourceByteSize: data.count, outputByteSize: encoded.count)
    {
      return .skipped(.notSmaller)
    }

    return .compressed(
      CompressedImage(
        data: encoded,
        mime: outputMime,
        fileExtension: outputExtension,
        width: image.width,
        height: image.height,
        sourceByteSize: data.count,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        sourceMime: format.mime))
  }

  /// Whether a copy of `outputByteSize` saves enough over the source: at
  /// least 10% of it and at least 20 kB, both inclusive.
  static func savesEnough(sourceByteSize: Int, outputByteSize: Int) -> Bool {
    let saved = sourceByteSize - outputByteSize
    return saved >= minimumSavedBytes && saved * 100 >= sourceByteSize * minimumSavedPercent
  }

  // MARK: - Formats

  enum SourceFormat: Equatable {
    case jpeg
    case heic
    case heif
    case png

    init?(typeIdentifier: String) {
      switch typeIdentifier {
      case "public.jpeg": self = .jpeg
      case "public.heic": self = .heic
      case "public.heif": self = .heif
      case "public.png": self = .png
      default: return nil
      }
    }

    var mime: String {
      switch self {
      case .jpeg: return "image/jpeg"
      case .heic: return "image/heic"
      case .heif: return "image/heif"
      case .png: return "image/png"
      }
    }

    /// HEIC is converted whatever the size; the others only when it pays.
    var compressesOnlyWhenSmaller: Bool {
      switch self {
      case .jpeg, .png: return true
      case .heic, .heif: return false
      }
    }
  }

  /// SVG and other XML: ImageIO cannot decode them, but they are a known
  /// format to leave alone rather than unreadable bytes.
  private static func looksLikeMarkup(_ data: Data) -> Bool {
    var bytes = data.prefix(64)[...]
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
      bytes = bytes.dropFirst(3)
    }
    let first = bytes.first { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D) }
    return first == UInt8(ascii: "<")
  }

  // MARK: - Pixels

  /// Whether any pixel is less than fully opaque. An alpha channel that is
  /// opaque everywhere, common in screenshots, does not count.
  static func hasTransparentPixels(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
      return false
    default:
      break
    }
    let width = image.width
    let height = image.height
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let pixels = context.data
    else {
      // Cannot inspect it: treat as transparent so it is left alone.
      return true
    }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytesPerRow = context.bytesPerRow
    let bytes = pixels.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    for row in 0..<height {
      let start = bytes + row * bytesPerRow + 3
      for column in 0..<width where start[column * 4] != 0xFF {
        return true
      }
    }
    return false
  }

  /// Redraws `image` as opaque 8-bit RGB or gray, keeping its color profile
  /// when it is an RGB or gray one and using sRGB otherwise (CMYK, Lab,
  /// extended range). Any transparency is flattened onto white.
  static func eightBitImage(from image: CGImage) -> CGImage? {
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    var space = sRGB
    if let sourceSpace = image.colorSpace,
      sourceSpace.model == .rgb || sourceSpace.model == .monochrome,
      !CGColorSpaceUsesExtendedRange(sourceSpace)
    {
      space = sourceSpace
    }

    func makeContext(_ space: CGColorSpace) -> CGContext? {
      let isGray = space.model == .monochrome
      return CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: isGray
          ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    guard let context = makeContext(space) ?? makeContext(sRGB) else {
      return nil
    }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    return context.makeImage()
  }

  // MARK: - Encoding

  /// Encodes `image` as JPEG with orientation 1. With `sourceProperties`, the
  /// source's EXIF, TIFF, IPTC and GPS fields are copied across; without,
  /// the output carries only what ImageIO always writes, including the
  /// image's color profile.
  static func encodeJPEG(
    _ image: CGImage,
    quality: CompressionQuality,
    sourceProperties: [CFString: Any]?
  ) -> Data? {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, "public.jpeg" as CFString, 1, nil)
    else {
      return nil
    }

    var properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality.jpegQuality,
      kCGImagePropertyOrientation: 1,
    ]
    if let source = sourceProperties {
      if var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
        exif[kCGImagePropertyExifPixelXDimension] = image.width
        exif[kCGImagePropertyExifPixelYDimension] = image.height
        properties[kCGImagePropertyExifDictionary] = exif
      }
      if var tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff[kCGImagePropertyTIFFOrientation] = 1
        properties[kCGImagePropertyTIFFDictionary] = tiff
      }
      for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
        if let dictionary = source[key] {
          properties[key] = dictionary
        }
      }
    }

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return output as Data
  }
}
