import Foundation

/// What an optimize run was asked to do: the `run.params` JSON.
public struct OptimizeRunParams: Codable, Equatable, Sendable {
  /// By slug: restoring a backup nulls `run.backend_id`.
  public var backend: String
  public var prefix: String
  public var names: [String]
  /// Nil keeps the size.
  public var longestEdge: Int?
  public var quality: CompressionQuality
  public var keepMetadata: Bool
  public var fingerprint: String
  /// Nil measures every selected image.
  public var sample: Int?
  /// Nil seeds the sample with the run's number.
  public var seed: UInt64?

  public init(
    backend: String, prefix: String, names: [String], options: CompressionOptions, sample: Int?,
    seed: UInt64?
  ) {
    self.backend = backend
    self.prefix = prefix
    self.names = names
    longestEdge = options.longestEdge
    quality = options.quality
    keepMetadata = !options.removesMetadata
    fingerprint = options.fingerprint
    self.sample = sample
    self.seed = seed
  }

  enum CodingKeys: String, CodingKey {
    case backend, prefix, names, quality, fingerprint, sample, seed
    case longestEdge = "longest_edge"
    case keepMetadata = "keep_metadata"
  }
}

/// One selected row as it was when the run read it.
public struct OptimizeSelectedImage: Codable, Equatable, Sendable {
  public var assetID: Int64
  public var key: String
  public var sha256: String
  public var bytes: Int64

  public init(assetID: Int64, key: String, sha256: String, bytes: Int64) {
    self.assetID = assetID
    self.key = key
    self.sha256 = sha256
    self.bytes = bytes
  }

  enum CodingKeys: String, CodingKey {
    case key, sha256, bytes
    case assetID = "asset_id"
  }
}

/// The whole selection, not only the sample.
public struct OptimizeSelectedEvent: Codable, Equatable, Sendable {
  /// The seed the sample was drawn with.
  public var seed: UInt64
  /// How many images the sample holds.
  public var sample: Int
  public var images: [OptimizeSelectedImage]

  public init(seed: UInt64, sample: Int, images: [OptimizeSelectedImage]) {
    self.seed = seed
    self.sample = sample
    self.images = images
  }
}

/// What measuring one object found.
public enum OptimizeOutcome: String, Codable, CaseIterable, Sendable {
  /// A copy smaller by the compressor's threshold that could replace it.
  case smaller
  case notSmaller = "not_smaller"
  case transparent
  case animated
  case unsupportedFormat = "unsupported_format"
  case unreadable
  /// The copy would not be the format the object is served as.
  case formatWouldChange = "format_would_change"
  /// Another asset on the backend already has the copy's hash, as its own or
  /// as its original's.
  case duplicateHash = "duplicate_hash"
  /// The object has headers or metadata a replacement would not keep.
  case unsupportedHeaders = "unsupported_headers"
  /// The bucket's bytes do not hash to the row's `sha256`.
  case hashMismatch = "hash_mismatch"
  case notFound = "not_found"
  case readFailed = "read_failed"

  /// Why an object that was read would be left as it is.
  public static let skipReasons: [OptimizeOutcome] = [
    .notSmaller, .transparent, .animated, .unsupportedFormat, .unreadable, .formatWouldChange,
    .duplicateHash, .unsupportedHeaders,
  ]

  /// False when the object never arrived, so nothing is known about it.
  public var wasRead: Bool { self != .notFound && self != .readFailed }

  /// The words after "Left <key> — " and in the report's table.
  public var label: String {
    switch self {
    case .smaller: return "smaller"
    case .notSmaller: return "not smaller"
    case .transparent: return "transparent"
    case .animated: return "animated"
    case .unsupportedFormat: return "unsupported format"
    case .unreadable: return "unreadable"
    case .formatWouldChange: return "format would change"
    case .duplicateHash: return "another asset has the new hash"
    case .unsupportedHeaders: return "unsupported headers"
    case .hashMismatch: return "the bucket’s bytes differ from the catalog"
    case .notFound: return "not in the bucket"
    case .readFailed: return "couldn’t be read"
    }
  }

  var level: RunLevel {
    switch self {
    case .smaller, .notSmaller, .transparent, .animated: return .info
    case .unsupportedFormat, .unreadable, .formatWouldChange, .duplicateHash, .unsupportedHeaders,
      .hashMismatch:
      return .warning
    case .notFound, .readFailed: return .error
    }
  }
}

/// One sampled object. The `after` fields are set whenever the compressor made
/// a copy, including one that a later check rules out.
public struct ObjectMeasuredEvent: Codable, Equatable, Sendable {
  public var assetID: Int64
  public var key: String
  public var outcome: OptimizeOutcome
  /// The row's size.
  public var bytesBefore: Int64
  public var bytesAfter: Int64?
  public var widthBefore: Int?
  public var heightBefore: Int?
  public var widthAfter: Int?
  public var heightAfter: Int?
  public var sha256After: String?
  /// The headers that rule the object out, or why it could not be read.
  public var detail: String?

  public init(
    assetID: Int64, key: String, outcome: OptimizeOutcome, bytesBefore: Int64,
    bytesAfter: Int64? = nil, widthBefore: Int? = nil, heightBefore: Int? = nil,
    widthAfter: Int? = nil, heightAfter: Int? = nil, sha256After: String? = nil,
    detail: String? = nil
  ) {
    self.assetID = assetID
    self.key = key
    self.outcome = outcome
    self.bytesBefore = bytesBefore
    self.bytesAfter = bytesAfter
    self.widthBefore = widthBefore
    self.heightBefore = heightBefore
    self.widthAfter = widthAfter
    self.heightAfter = heightAfter
    self.sha256After = sha256After
    self.detail = detail
  }

  enum CodingKeys: String, CodingKey {
    case key, outcome, detail
    case assetID = "asset_id"
    case bytesBefore = "bytes_before"
    case bytesAfter = "bytes_after"
    case widthBefore = "width_before"
    case heightBefore = "height_before"
    case widthAfter = "width_after"
    case heightAfter = "height_after"
    case sha256After = "sha256_after"
  }
}
