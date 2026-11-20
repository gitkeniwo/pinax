import Foundation

public struct UploadRequest: Sendable {
  public let data: Data
  public let sha256: String
  public let key: String
  public let mime: String
  public let metadata: [String: String]
  public let cacheControl: String?
  /// Create the object only if the key is free (`If-None-Match: *`); an
  /// occupied key throws `UploaderError.objectAlreadyExists`.
  public let createOnly: Bool

  public init(
    data: Data,
    sha256: String,
    key: String,
    mime: String,
    metadata: [String: String],
    cacheControl: String? = nil,
    createOnly: Bool = false
  ) {
    self.data = data
    self.sha256 = sha256
    self.key = key
    self.mime = mime
    self.metadata = metadata
    self.cacheControl = cacheControl
    self.createOnly = createOnly
  }
}

public struct UploadResult: Equatable, Sendable {
  public let key: String
  public let etag: String?

  public init(key: String, etag: String?) {
    self.key = key
    self.etag = etag
  }
}

public enum UploaderError: Error, Equatable, CustomStringConvertible {
  /// A create-only upload found an object already at the key (HTTP 412).
  case objectAlreadyExists(key: String)

  public var description: String {
    switch self {
    case let .objectAlreadyExists(key):
      return "An object already exists at \"\(key)\"."
    }
  }
}

public protocol Uploader: Sendable {
  func upload(_ request: UploadRequest) async throws -> UploadResult
  // Normal dedupe trusts the catalog. Phase 9 reindex uses HEAD to inspect remote objects.
  func exists(key: String) async throws -> Bool
  /// What is at `key`, with its `x-amz-meta-sha256`. Asked only after a
  /// create-only upload was refused, to tell a lost response from a clash.
  func head(key: String) async throws -> ObjectPresence
}

extension Uploader {
  /// An uploader that cannot read metadata reports an object of unknown
  /// content, so a refused create-only upload stays a key clash.
  public func head(key: String) async throws -> ObjectPresence {
    try await exists(key: key) ? .present(sha256: nil) : .absent
  }
}
