import Foundation

public struct PublicAsset: Codable, Equatable, Sendable {
  public let sha256: String
  public let key: String
  public let url: String
  public let width: Int?
  public let height: Int?
  public let bytes: Int64
  public let mime: String
  public let filename: String
  public let uploadedAt: String
  public let deduplicated: Bool?
  public let dryRun: Bool?
  /// Present only for an upload whose stored bytes are a compressed copy.
  public let compression: PublicCompression?

  public init(
    sha256: String,
    key: String,
    url: String,
    width: Int?,
    height: Int?,
    bytes: Int64,
    mime: String,
    filename: String,
    uploadedAt: String,
    deduplicated: Bool? = nil,
    dryRun: Bool? = nil,
    compression: PublicCompression? = nil
  ) {
    self.sha256 = sha256
    self.key = key
    self.url = url
    self.width = width
    self.height = height
    self.bytes = bytes
    self.mime = mime
    self.filename = filename
    self.uploadedAt = uploadedAt
    self.deduplicated = deduplicated
    self.dryRun = dryRun
    self.compression = compression
  }

  public init(asset: Asset, backend: Backend) {
    self.init(
      sha256: asset.sha256,
      key: asset.key,
      url: URLResolver.url(for: asset, backend: backend),
      width: asset.width,
      height: asset.height,
      bytes: asset.byteSize,
      mime: asset.mime,
      filename: asset.originalFilename ?? asset.key,
      uploadedAt: asset.uploadedAt
    )
  }

  public init(upload: UploadOutcome) {
    self.init(
      sha256: upload.sha256,
      key: upload.key,
      url: upload.url,
      width: upload.width,
      height: upload.height,
      bytes: upload.byteSize,
      mime: upload.mime,
      filename: upload.originalFilename,
      uploadedAt: upload.uploadedAt,
      deduplicated: upload.deduplicated,
      dryRun: upload.dryRun,
      compression: upload.compression.map(PublicCompression.init(facts:))
    )
  }

  enum CodingKeys: String, CodingKey {
    case sha256, key, url, width, height, bytes, mime, filename, deduplicated, compression
    case uploadedAt = "uploaded_at"
    case dryRun = "dry_run"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sha256, forKey: .sha256)
    try container.encode(key, forKey: .key)
    try container.encode(url, forKey: .url)
    try container.encodeIfPresent(width, forKey: .width)
    try container.encodeIfPresent(height, forKey: .height)
    try container.encode(bytes, forKey: .bytes)
    try container.encode(mime, forKey: .mime)
    try container.encode(filename, forKey: .filename)
    try container.encode(uploadedAt, forKey: .uploadedAt)
    try container.encodeIfPresent(deduplicated, forKey: .deduplicated)
    try container.encodeIfPresent(dryRun, forKey: .dryRun)
    try container.encodeIfPresent(compression, forKey: .compression)
  }
}

/// An upload's compression in the public JSON: the original it was made
/// from and the options used.
public struct PublicCompression: Codable, Equatable, Sendable {
  public let sourceSHA256: String
  public let sourceBytes: Int64
  public let sourceWidth: Int?
  public let sourceHeight: Int?
  public let sourceMime: String
  public let formatChanged: Bool
  /// Absent when the image was not resized.
  public let longestEdge: Int?
  public let quality: CompressionQuality
  public let removeMetadata: Bool

  public init(facts: UploadCompressionFacts) {
    sourceSHA256 = facts.sourceSHA256
    sourceBytes = facts.sourceByteSize
    sourceWidth = facts.sourceWidth
    sourceHeight = facts.sourceHeight
    sourceMime = facts.sourceMime
    formatChanged = facts.formatChanged
    longestEdge = facts.options.longestEdge
    quality = facts.options.quality
    removeMetadata = facts.options.removesMetadata
  }

  enum CodingKeys: String, CodingKey {
    case quality
    case sourceSHA256 = "source_sha256"
    case sourceBytes = "source_bytes"
    case sourceWidth = "source_width"
    case sourceHeight = "source_height"
    case sourceMime = "source_mime"
    case formatChanged = "format_changed"
    case longestEdge = "longest_edge"
    case removeMetadata = "remove_metadata"
  }
}

public struct PublicAssetCollection: Codable, Equatable, Sendable {
  public let schema: Int
  public let assets: [PublicAsset]

  public init(schema: Int = 1, assets: [PublicAsset]) {
    self.schema = schema
    self.assets = assets
  }
}

public enum PublicAssetJSON {
  public static func encode(_ assets: [PublicAsset]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(
      decoding: try encoder.encode(PublicAssetCollection(assets: assets)),
      as: UTF8.self
    )
  }
}
