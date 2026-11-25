import Foundation

/// Why the compressor left an image alone. The caller uploads the original.
public enum SkipReason: String, Codable, Hashable, Sendable {
  /// A PNG with at least one pixel that is not fully opaque.
  case transparent
  /// More than one frame: animated GIF, PNG, WebP or HEIC sequences.
  case animated
  /// A format the compressor does not rewrite, such as GIF, WebP or SVG.
  case unsupportedFormat
  /// The recompressed copy did not save enough to be worth it.
  case notSmaller
  /// The bytes could not be decoded or encoded as an image.
  case unreadable
}
