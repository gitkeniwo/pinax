import CatalogCore
import Foundation

/// What a card says about a recompressed upload: the original and the copy
/// that is sent in its place. nil on a card whose file goes up as it is.
public struct CardCompression: Equatable, Sendable {
  public let sourceByteSize: Int64
  /// The original's size as displayed, after its EXIF orientation.
  public let sourceWidth: Int?
  public let sourceHeight: Int?
  public let sourceMime: String
  public let byteSize: Int64
  public let width: Int?
  public let height: Int?
  public let mime: String
  public let options: CompressionOptions

  public init(
    sourceByteSize: Int64, sourceWidth: Int?, sourceHeight: Int?, sourceMime: String,
    byteSize: Int64, width: Int?, height: Int?, mime: String, options: CompressionOptions
  ) {
    self.sourceByteSize = sourceByteSize
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    self.sourceMime = sourceMime
    self.byteSize = byteSize
    self.width = width
    self.height = height
    self.mime = mime
    self.options = options
  }

  /// A copy the compressor has just made, before it is sent.
  init(image: CompressedImage, options: CompressionOptions) {
    self.init(
      sourceByteSize: Int64(image.sourceByteSize), sourceWidth: image.sourceWidth,
      sourceHeight: image.sourceHeight, sourceMime: image.sourceMime,
      byteSize: Int64(image.byteSize), width: image.width, height: image.height,
      mime: image.mime, options: options)
  }

  /// What a landed upload stored; nil when it stored the original.
  init?(outcome: UploadOutcome) {
    guard let facts = outcome.compression else { return nil }
    self.init(
      sourceByteSize: facts.sourceByteSize, sourceWidth: facts.sourceWidth,
      sourceHeight: facts.sourceHeight, sourceMime: facts.sourceMime,
      byteSize: outcome.byteSize, width: outcome.width, height: outcome.height,
      mime: outcome.mime, options: facts.options)
  }

  /// "3.1 MB → 412 kB"
  var sizeChange: String {
    "\(PinaxFormat.fileSize(sourceByteSize)) → \(PinaxFormat.fileSize(byteSize))"
  }

  /// "HEIC → JPEG", or nil when the copy keeps the original's format.
  var formatChange: String? {
    guard sourceMime != mime else { return nil }
    return "\(PinaxFormat.shortKind(mime: sourceMime)) → \(PinaxFormat.shortKind(mime: mime))"
  }

  /// The copy has fewer bytes than the original. A converted format is sent
  /// even when it does not.
  var isSmaller: Bool { byteSize < sourceByteSize }

  /// "−87%", "+12%" when the copy is larger, or nil when the change rounds
  /// to nothing. A smaller copy never reads as "−100%".
  var percentChange: String? {
    guard sourceByteSize > 0 else { return nil }
    let change = Double(byteSize - sourceByteSize) / Double(sourceByteSize) * 100
    let percent = Int(abs(change).rounded())
    guard percent > 0 else { return nil }
    return change < 0 ? "−\(min(percent, 99))%" : "+\(percent)%"
  }

  /// "Longest edge 2048 · Quality 85% · metadata removed"
  var settingsSummary: String {
    [
      options.longestEdge.map { "Longest edge \($0)" } ?? "Not resized",
      "Quality \(options.quality)",
      options.removesMetadata ? "metadata removed" : "metadata kept",
    ].joined(separator: " · ")
  }
}
