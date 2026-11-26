import Foundation

public enum S3UploaderError: Error, Equatable, CustomStringConvertible {
  case invalidEndpoint(String)
  case invalidMetadataKey(String)
  case nonASCIIHeaderValue(String)
  case invalidResponse
  case http(statusCode: Int, body: String)

  public var description: String {
    switch self {
    case let .invalidEndpoint(endpoint):
      return "Invalid S3 endpoint: \(endpoint)"
    case let .invalidMetadataKey(key):
      return "S3 metadata '\(key)' is not an allowed immutable asset fact."
    case let .nonASCIIHeaderValue(header):
      return "HTTP header '\(header)' contains a value that cannot be signed safely."
    case .invalidResponse:
      return "The S3 endpoint returned a non-HTTP response."
    case let .http(statusCode, body):
      return "S3 returned HTTP \(statusCode): \(body)"
    }
  }
}

/// Sends a request again, with exponential backoff, while it is answered with
/// HTTP 429 or 5xx; after `maxRetries` the last answer is returned.
enum S3Retry {
  static func data(
    for request: URLRequest, session: URLSession, maxRetries: Int, baseDelay: TimeInterval
  ) async throws -> (Data, URLResponse) {
    for attempt in 0..<maxRetries {
      let result = try await session.data(for: request)
      guard let response = result.1 as? HTTPURLResponse else {
        return result
      }
      let retryable = response.statusCode == 429 || (500..<600).contains(response.statusCode)
      guard retryable else {
        return result
      }
      let delay = baseDelay * pow(2, Double(attempt))
      if delay > 0 {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
    }
    return try await session.data(for: request)
  }
}

public struct S3Uploader: Uploader {
  public static let immutableCacheControl = "public, max-age=31536000, immutable"

  private static let allowedMetadata = Set([
    "x-amz-meta-sha256",
    "x-amz-meta-orig-filename",
    "x-amz-meta-width",
    "x-amz-meta-height",
    "x-amz-meta-source-url",
    "x-amz-meta-source-sha256",
  ])

  private let backend: Backend
  private let signer: SigV4Signer
  private let session: URLSession
  private let requestTimeout: TimeInterval
  private let maxRetries: Int
  private let baseRetryDelay: TimeInterval

  public init(
    backend: Backend,
    credentials: BackendCredentials,
    session: URLSession = .shared,
    requestTimeout: TimeInterval = 60,
    maxRetries: Int = 3,
    baseRetryDelay: TimeInterval = 0.25
  ) {
    self.backend = backend
    self.signer = SigV4Signer(credentials: credentials, region: backend.region, service: "s3")
    self.session = session
    self.requestTimeout = requestTimeout
    self.maxRetries = max(0, maxRetries)
    self.baseRetryDelay = max(0, baseRetryDelay)
  }

  public func upload(_ request: UploadRequest) async throws -> UploadResult {
    var urlRequest = URLRequest(url: try objectURL(key: request.key))
    urlRequest.httpMethod = "PUT"
    urlRequest.httpBody = request.data
    urlRequest.timeoutInterval = requestTimeout
    try Self.setASCIIHeader(request.mime, name: "Content-Type", on: &urlRequest)
    try Self.setASCIIHeader(
      request.cacheControl ?? Self.immutableCacheControl,
      name: "Cache-Control",
      on: &urlRequest
    )
    for (key, value) in request.metadata {
      let header =
        key.lowercased().hasPrefix("x-amz-meta-")
        ? key.lowercased()
        : "x-amz-meta-\(key.lowercased())"
      guard Self.allowedMetadata.contains(header) else {
        throw S3UploaderError.invalidMetadataKey(key)
      }
      try Self.setASCIIHeader(
        MetadataValueCodec.encode(value),
        name: header,
        on: &urlRequest
      )
    }

    if request.createOnly {
      urlRequest.setValue("*", forHTTPHeaderField: "If-None-Match")
    }

    try Self.setASCIIHeader(
      request.sha256,
      name: "x-amz-content-sha256",
      on: &urlRequest
    )
    let signedRequest = try signer.sign(urlRequest, payloadHash: request.sha256)
    let (data, response) = try await send(signedRequest)
    let http = try Self.httpResponse(response)
    if request.createOnly, http.statusCode == 412 {
      throw UploaderError.objectAlreadyExists(key: request.key)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw S3UploaderError.http(
        statusCode: http.statusCode,
        body: String(decoding: data, as: UTF8.self)
      )
    }
    return UploadResult(
      key: request.key,
      etag: http.value(forHTTPHeaderField: "ETag")
    )
  }

  public func exists(key: String) async throws -> Bool {
    try await head(key: key) != .absent
  }

  public func head(key: String) async throws -> ObjectPresence {
    var request = URLRequest(url: try objectURL(key: key))
    request.httpMethod = "HEAD"
    request.timeoutInterval = requestTimeout
    request.setValue(Self.emptyPayloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    let signedRequest = try signer.sign(request, payloadHash: Self.emptyPayloadHash)
    let (data, response) = try await send(signedRequest)
    let http = try Self.httpResponse(response)
    if http.statusCode == 404 {
      return .absent
    }
    guard (200..<300).contains(http.statusCode) else {
      throw S3UploaderError.http(
        statusCode: http.statusCode,
        body: String(decoding: data, as: UTF8.self)
      )
    }
    return .present(sha256: http.value(forHTTPHeaderField: "x-amz-meta-sha256"))
  }

  private func objectURL(key: String) throws -> URL {
    guard var components = URLComponents(string: backend.endpoint),
      components.scheme != nil,
      components.host != nil,
      let endpointPath = components.percentEncodedPath.removingPercentEncoding
    else {
      throw S3UploaderError.invalidEndpoint(backend.endpoint)
    }
    let base = endpointPath.hasSuffix("/") ? String(endpointPath.dropLast()) : endpointPath
    let objectPath = "\(base)/\(backend.bucket)/\(key)"
    components.percentEncodedPath = SigV4Signer.awsEncode(objectPath, preserveSlash: true)
    components.query = nil
    components.fragment = nil
    guard let url = components.url else {
      throw S3UploaderError.invalidEndpoint(backend.endpoint)
    }
    return url
  }

  private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await S3Retry.data(
      for: request, session: session, maxRetries: maxRetries, baseDelay: baseRetryDelay)
  }

  private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
      throw S3UploaderError.invalidResponse
    }
    return response
  }

  private static func setASCIIHeader(
    _ value: String,
    name: String,
    on request: inout URLRequest
  ) throws {
    guard value.unicodeScalars.allSatisfy({ $0.value <= 127 }),
      !value.contains("\r"),
      !value.contains("\n")
    else {
      throw S3UploaderError.nonASCIIHeaderValue(name)
    }
    request.setValue(value, forHTTPHeaderField: name)
  }

  private static let emptyPayloadHash =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
