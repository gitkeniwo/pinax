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
    quality: CompressionQuality = .default,
    removesMetadata: Bool = true
  ) {
    self.longestEdge = longestEdge
    self.quality = quality
    self.removesMetadata = removesMetadata
  }

  public static let `default` = CompressionOptions()

  /// A short, stable string naming these options, such as `e2048-q85-m1`.
  /// Two uploads of the same source with the same fingerprint produce an
  /// equivalent copy, so the second can reuse the first.
  public var fingerprint: String {
    let edge = longestEdge.map { String($0) } ?? "none"
    return "e\(edge)-q\(quality.percent)-m\(removesMetadata ? 1 : 0)"
  }

  /// `fingerprint` as it would be written today. Earlier versions named
  /// the quality (`e2048-qhigh-m1`); those names become their percentage,
  /// so a copy made at the old high step matches one asked for at 85.
  public static func normalizedFingerprint(_ fingerprint: String) -> String {
    fingerprint.split(separator: "-", omittingEmptySubsequences: false)
      .map { part -> String in
        guard part.hasPrefix("q"),
          let percent = CompressionQuality.legacyNames[String(part.dropFirst())]
        else { return String(part) }
        return "q\(percent)"
      }
      .joined(separator: "-")
  }
}
