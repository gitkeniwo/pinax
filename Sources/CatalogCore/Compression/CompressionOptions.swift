import Foundation

/// How an upload copy is recompressed.
public struct CompressionOptions: Hashable, Codable, Sendable {
  /// The longest edge of the output in pixels, or `nil` to keep the size.
  /// Images are only ever made smaller, never larger.
  public var longestEdge: Int?
  public var quality: CompressionQuality
  /// When on, the output keeps only its color profile. When off, the EXIF,
  /// TIFF, IPTC and GPS fields of the source are copied to the output.
  public var removesMetadata: Bool

  public init(
    longestEdge: Int? = 2048,
    quality: CompressionQuality = .high,
    removesMetadata: Bool = true
  ) {
    self.longestEdge = longestEdge
    self.quality = quality
    self.removesMetadata = removesMetadata
  }

  public static let `default` = CompressionOptions()

  /// A short, stable string naming these options, such as `e2048-qhigh-m1`.
  /// Two uploads of the same source with the same fingerprint produce an
  /// equivalent copy, so the second can reuse the first.
  public var fingerprint: String {
    let edge = longestEdge.map { String($0) } ?? "none"
    return "e\(edge)-q\(quality.rawValue)-m\(removesMetadata ? 1 : 0)"
  }
}
