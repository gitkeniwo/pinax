import Foundation

/// What compression did to an upload: the original it came from and the
/// options it was made with. Present on an outcome only when the stored
/// bytes are a recompressed copy.
public struct UploadCompressionFacts: Equatable, Sendable {
  public let options: CompressionOptions
  public let sourceSHA256: String
  public let sourceByteSize: Int64
  /// The original's size as displayed, after its EXIF orientation.
  public let sourceWidth: Int?
  public let sourceHeight: Int?
  public let sourceMime: String
  /// The copy is in another format than the original (HEIC or PNG to JPEG).
  public let formatChanged: Bool

  public init(
    options: CompressionOptions,
    sourceSHA256: String,
    sourceByteSize: Int64,
    sourceWidth: Int?,
    sourceHeight: Int?,
    sourceMime: String,
    formatChanged: Bool
  ) {
    self.options = options
    self.sourceSHA256 = sourceSHA256
    self.sourceByteSize = sourceByteSize
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    self.sourceMime = sourceMime
    self.formatChanged = formatChanged
  }

  init(options: CompressionOptions, sourceSHA256: String, image: CompressedImage) {
    self.init(
      options: options,
      sourceSHA256: sourceSHA256,
      sourceByteSize: Int64(image.sourceByteSize),
      sourceWidth: image.sourceWidth,
      sourceHeight: image.sourceHeight,
      sourceMime: image.sourceMime,
      formatChanged: image.sourceMime != image.mime
    )
  }

  /// The facts recorded in a compressed asset's `meta`, or nil when the
  /// asset is an uploaded original (or its record is unreadable).
  init?(asset: Asset) {
    guard let sourceSHA256 = asset.sourceSHA256,
      let record = Self.record(inMeta: asset.meta),
      let sourceBytes = record["source_bytes"] as? NSNumber,
      let sourceMime = record["source_mime"] as? String
    else { return nil }
    var options = CompressionOptions(longestEdge: nil)
    if let edge = record["longest_edge"] as? NSNumber { options.longestEdge = edge.intValue }
    if let quality = CompressionQuality(json: record["quality"]) { options.quality = quality }
    if let removes = record["remove_metadata"] as? Bool { options.removesMetadata = removes }
    self.init(
      options: options,
      sourceSHA256: sourceSHA256,
      sourceByteSize: sourceBytes.int64Value,
      sourceWidth: (record["source_width"] as? NSNumber)?.intValue,
      sourceHeight: (record["source_height"] as? NSNumber)?.intValue,
      sourceMime: sourceMime,
      formatChanged: sourceMime != asset.mime
    )
  }

  /// The fingerprint a compressed asset was made with, from its `meta`.
  static func fingerprint(inMeta meta: String) -> String? {
    record(inMeta: meta)?["fingerprint"] as? String
  }

  /// `meta` with these facts under `compression`, every other key kept.
  func merged(intoMeta meta: String) -> String {
    var object =
      (try? JSONSerialization.jsonObject(with: Data(meta.utf8))) as? [String: Any] ?? [:]
    var record: [String: Any] = [
      "fingerprint": options.fingerprint,
      "quality": options.quality.percent,
      "remove_metadata": options.removesMetadata,
      "source_bytes": sourceByteSize,
      "source_mime": sourceMime,
    ]
    record["longest_edge"] = options.longestEdge
    record["source_width"] = sourceWidth
    record["source_height"] = sourceHeight
    object["compression"] = record
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return meta }
    return String(decoding: data, as: UTF8.self)
  }

  private static func record(inMeta meta: String) -> [String: Any]? {
    let object = (try? JSONSerialization.jsonObject(with: Data(meta.utf8))) as? [String: Any]
    return object?["compression"] as? [String: Any]
  }
}

/// A file read, hashed, looked up and (when asked) compressed, but not yet
/// uploaded. `UploadPipeline.upload(_:useOriginal:…)` finishes it, sending
/// either the compressed copy or the original.
public struct PreparedUpload: Sendable {
  /// What the catalog already has for this file.
  public enum Match: Sendable {
    /// The original's bytes are already stored as this asset.
    case original(Asset)
    /// A copy of the original compressed with the same options is stored
    /// as this asset.
    case compressedCopy(Asset)
  }

  public let fileURL: URL
  /// The hash of the original file.
  public let sourceSHA256: String
  /// The options asked for, or nil when the upload is not compressed.
  public let compressionOptions: CompressionOptions?
  public let force: Bool
  public let match: Match?
  /// What the compressor made of the original; nil when it was not run
  /// (no options, or the catalog already has a match).
  public let compression: CompressionResult?
  /// The original's bytes; nil when a match made reading them unnecessary.
  let sourceData: Data?

  /// The upload would reuse an asset instead of sending anything.
  public var isDuplicate: Bool { match != nil && !force }
  public var sourceByteSize: Int64? { sourceData.map { Int64($0.count) } }
}
