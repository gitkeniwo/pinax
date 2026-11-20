import Foundation

/// Why a key can never become a delete request. An empty key would make
/// `DELETE /<bucket>/` — S3's DeleteBucket; a trailing slash names a
/// "folder"; a wildcard or dot segment is not one object.
public enum DeletionKeyGuard {
  public static func problem(_ key: String) -> String? {
    if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty" }
    if key.hasPrefix("/") { return "leading slash" }
    if key.hasSuffix("/") { return "a prefix, not an object" }
    if key.contains("*") { return "wildcard" }
    if key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
      return "control character"
    }
    let segments = key.split(separator: "/", omittingEmptySubsequences: false)
    if segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
      return "empty or dot path segment"
    }
    return nil
  }

  public static func check(_ key: String) throws {
    if let reason = problem(key) { throw ObjectDeleteError.unsafeKey(key, reason: reason) }
  }
}

public enum ObjectDeleteError: Error, Equatable, CustomStringConvertible {
  case unsafeKey(String, reason: String)
  case permissionDenied(backend: String, operation: String)
  case http(statusCode: Int, body: String)

  public var description: String {
    switch self {
    case let .unsafeKey(key, reason):
      return "Refusing to delete key '\(key)': \(reason)."
    case let .permissionDenied(backend, "DeleteObject"):
      return
        "The key for backend '\(backend)' can upload but has no permission to delete. "
        + "Give it delete permission (R2: Object Read & Write; B2: deleteFiles; "
        + "AWS or MinIO: s3:DeleteObject), or delete the object in the provider's console; "
        + "Pinax checks it is gone on the next try."
    case let .permissionDenied(backend, operation):
      return
        "The key for backend '\(backend)' has no permission for \(operation); "
        + "Pinax checks an object before deleting it, which needs read access."
    case let .http(statusCode, body):
      return "S3 returned HTTP \(statusCode): \(body)"
    }
  }
}

/// What a HEAD found at a key.
public enum ObjectPresence: Equatable, Sendable {
  case absent
  /// `sha256` is the object's `x-amz-meta-sha256`, which only Pinax writes.
  case present(sha256: String?)
}

public struct ObjectDeleteReceipt: Equatable, Sendable {
  /// The bucket keeps versions: the delete added a marker (or hid the
  /// object), and older versions stay until the bucket removes them.
  public let versioned: Bool

  public init(versioned: Bool) {
    self.versioned = versioned
  }
}

public protocol ObjectDeleting: Sendable {
  func head(key: String) async throws -> ObjectPresence
  func delete(key: String) async throws -> ObjectDeleteReceipt
}

/// The only code in Pinax that sends a delete to an object store, and only
/// for one exact object per request: no DeleteObjects batch, no bucket,
/// no listing. Callers are `CatalogDeletion` alone.
public struct S3ObjectDeleter: ObjectDeleting {
  private let backend: Backend
  private let signer: SigV4Signer
  private let session: URLSession
  private let requestTimeout: TimeInterval

  public init(
    backend: Backend,
    credentials: BackendCredentials,
    session: URLSession = .shared,
    requestTimeout: TimeInterval = 60
  ) {
    self.backend = backend
    signer = SigV4Signer(credentials: credentials, region: backend.region, service: "s3")
    self.session = session
    self.requestTimeout = requestTimeout
  }

  public func head(key: String) async throws -> ObjectPresence {
    let (_, http) = try await send("HEAD", key: key)
    switch http.statusCode {
    case 200..<300:
      return .present(sha256: http.value(forHTTPHeaderField: "x-amz-meta-sha256"))
    case 404:
      return .absent
    case 403:
      throw ObjectDeleteError.permissionDenied(backend: backend.slug, operation: "HeadObject")
    default:
      throw ObjectDeleteError.http(statusCode: http.statusCode, body: "")
    }
  }

  public func delete(key: String) async throws -> ObjectDeleteReceipt {
    let (data, http) = try await send("DELETE", key: key)
    switch http.statusCode {
    case 200..<300, 404:
      let marker = http.value(forHTTPHeaderField: "x-amz-delete-marker")?.lowercased() == "true"
      let version = http.value(forHTTPHeaderField: "x-amz-version-id").map {
        !$0.isEmpty && $0 != "null"
      }
      return ObjectDeleteReceipt(versioned: marker || version == true)
    case 403:
      throw ObjectDeleteError.permissionDenied(backend: backend.slug, operation: "DeleteObject")
    default:
      throw ObjectDeleteError.http(
        statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }
  }

  /// The object's URL, built only after the key guard passed.
  func objectURL(key: String) throws -> URL {
    try DeletionKeyGuard.check(key)
    guard var components = URLComponents(string: backend.endpoint),
      components.scheme != nil,
      components.host != nil
    else {
      throw S3UploaderError.invalidEndpoint(backend.endpoint)
    }
    let decodedBase =
      components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
    let base = decodedBase.hasSuffix("/") ? String(decodedBase.dropLast()) : decodedBase
    components.percentEncodedPath = SigV4Signer.awsEncode(
      "\(base)/\(backend.bucket)/\(key)", preserveSlash: true)
    components.query = nil
    components.fragment = nil
    guard let url = components.url else {
      throw S3UploaderError.invalidEndpoint(backend.endpoint)
    }
    return url
  }

  private func send(_ method: String, key: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: try objectURL(key: key))
    request.httpMethod = method
    request.timeoutInterval = requestTimeout
    request.setValue(Self.emptyPayloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    let signed = try signer.sign(request, payloadHash: Self.emptyPayloadHash)
    let (data, response) = try await session.data(for: signed)
    guard let http = response as? HTTPURLResponse else { throw S3UploaderError.invalidResponse }
    return (data, http)
  }

  private static let emptyPayloadHash =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
