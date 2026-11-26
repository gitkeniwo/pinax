import Foundation

public struct S3ObjectSummary: Equatable, Sendable {
  public let key: String
  public let byteSize: Int64
  public let lastModified: String?

  public init(key: String, byteSize: Int64, lastModified: String? = nil) {
    self.key = key
    self.byteSize = byteSize
    self.lastModified = lastModified
  }
}

public struct S3ObjectHead: Equatable, Sendable {
  public let key: String
  public let byteSize: Int64
  public let mime: String?
  public let lastModified: String?
  public let metadata: [String: String]
  public let cacheControl: String?
  /// As sent, quotes included.
  public let etag: String?

  public init(
    key: String,
    byteSize: Int64,
    mime: String?,
    lastModified: String?,
    metadata: [String: String],
    cacheControl: String? = nil,
    etag: String? = nil
  ) {
    self.key = key
    self.byteSize = byteSize
    self.mime = mime
    self.lastModified = lastModified
    self.metadata = metadata
    self.cacheControl = cacheControl
    self.etag = etag
  }
}

/// An object's bytes and headers as the bucket returned them to a signed GET.
public struct S3StoredObject: Equatable, Sendable {
  public let key: String
  public let data: Data
  /// As sent, quotes included, so it can be sent back unchanged.
  public let etag: String
  /// The whole header value, parameters included.
  public let contentType: String?
  /// Nil when the object has none.
  public let cacheControl: String?
  public let contentLength: Int64
  public let lastModified: String?
  /// `x-amz-meta-*`, with the prefix removed and the name lowercased.
  public let metadata: [String: String]
  /// Whichever of `Content-Encoding`, `Content-Disposition`,
  /// `Content-Language` and `Expires` the response has, under those names.
  public let otherHeaders: [String: String]

  public init(
    key: String,
    data: Data,
    etag: String,
    contentType: String?,
    cacheControl: String?,
    contentLength: Int64,
    lastModified: String?,
    metadata: [String: String],
    otherHeaders: [String: String] = [:]
  ) {
    self.key = key
    self.data = data
    self.etag = etag
    self.contentType = contentType
    self.cacheControl = cacheControl
    self.contentLength = contentLength
    self.lastModified = lastModified
    self.metadata = metadata
    self.otherHeaders = otherHeaders
  }
}

public enum ObjectReadError: Error, Equatable, CustomStringConvertible {
  case notFound(String)
  /// The received bytes cannot be shown to be the stored ones: their count is
  /// not `Content-Length`, or there is none. `URLSession` decompresses some
  /// encodings by itself, which also ends up here.
  case lengthMismatch(key: String, expected: Int64?, received: Int64, contentEncoding: String?)
  case missingETag(String)

  public var description: String {
    switch self {
    case let .notFound(key):
      return "Object does not exist: \(key)"
    case let .lengthMismatch(key, expected, received, contentEncoding):
      let promised = expected.map { "Content-Length was \($0)" } ?? "there was no Content-Length"
      let encoding = contentEncoding.map { " (Content-Encoding: \($0))" } ?? ""
      return "Read of \(key) is unverifiable: received \(received) bytes, \(promised)\(encoding)."
    case let .missingETag(key):
      return "The response for \(key) has no ETag."
    }
  }
}

public protocol ObjectInventory: Sendable {
  func listObjects() async throws -> [S3ObjectSummary]
  func headObject(key: String) async throws -> S3ObjectHead
}

public protocol ObjectReading: Sendable {
  func getObject(key: String) async throws -> S3StoredObject
}

public struct S3ObjectInventory: ObjectInventory, ObjectReading {
  private let backend: Backend
  private let signer: SigV4Signer
  private let session: URLSession
  private let requestTimeout: TimeInterval
  private let maxRetries: Int
  private let baseRetryDelay: TimeInterval

  /// - Parameters:
  ///   - maxRetries: for `getObject`, after an HTTP 429 or 5xx.
  public init(
    backend: Backend,
    credentials: BackendCredentials,
    session: URLSession = .shared,
    requestTimeout: TimeInterval = 60,
    maxRetries: Int = 3,
    baseRetryDelay: TimeInterval = 0.25
  ) {
    self.backend = backend
    signer = SigV4Signer(credentials: credentials, region: backend.region, service: "s3")
    self.session = session
    self.requestTimeout = requestTimeout
    self.maxRetries = max(0, maxRetries)
    self.baseRetryDelay = max(0, baseRetryDelay)
  }

  public func listObjects() async throws -> [S3ObjectSummary] {
    var objects: [S3ObjectSummary] = []
    var continuationToken: String?
    repeat {
      var request = URLRequest(url: try bucketURL(continuationToken: continuationToken))
      request.httpMethod = "GET"
      request.timeoutInterval = requestTimeout
      request.setValue(Self.emptyPayloadHash, forHTTPHeaderField: "x-amz-content-sha256")
      let signed = try signer.sign(request, payloadHash: Self.emptyPayloadHash)
      let (data, response) = try await session.data(for: signed)
      let http = try httpResponse(response)
      guard (200..<300).contains(http.statusCode) else {
        throw S3UploaderError.http(
          statusCode: http.statusCode,
          body: String(decoding: data, as: UTF8.self)
        )
      }
      let page = try ListObjectsParser.parse(data)
      objects.append(contentsOf: page.objects)
      continuationToken = page.isTruncated ? page.nextContinuationToken : nil
      if page.isTruncated, continuationToken == nil {
        throw S3UploaderError.invalidResponse
      }
    } while continuationToken != nil
    return objects
  }

  public func headObject(key: String) async throws -> S3ObjectHead {
    var request = URLRequest(url: try objectURL(key: key))
    request.httpMethod = "HEAD"
    request.timeoutInterval = requestTimeout
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(Self.emptyPayloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    let signed = try signer.sign(request, payloadHash: Self.emptyPayloadHash)
    let (data, response) = try await session.data(for: signed)
    let http = try httpResponse(response)
    guard (200..<300).contains(http.statusCode) else {
      throw S3UploaderError.http(
        statusCode: http.statusCode,
        body: String(decoding: data, as: UTF8.self)
      )
    }
    return S3ObjectHead(
      key: key,
      byteSize: Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
      mime: http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(
        String.init),
      lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
      metadata: Self.userMetadata(http),
      cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
      etag: http.value(forHTTPHeaderField: "ETag")
    )
  }

  public func getObject(key: String) async throws -> S3StoredObject {
    var request = URLRequest(url: try objectURL(key: key))
    request.httpMethod = "GET"
    request.timeoutInterval = requestTimeout
    // An `immutable` object would otherwise be answered from the URL cache.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(Self.emptyPayloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    var signed = try signer.sign(request, payloadHash: Self.emptyPayloadHash)
    // Added after signing, so an intermediary may rewrite it.
    signed.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let (data, response) = try await S3Retry.data(
      for: signed, session: session, maxRetries: maxRetries, baseDelay: baseRetryDelay)
    let http = try httpResponse(response)
    if http.statusCode == 404 {
      throw ObjectReadError.notFound(key)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw S3UploaderError.http(
        statusCode: http.statusCode,
        body: String(decoding: data, as: UTF8.self)
      )
    }
    let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
    guard let contentLength, contentLength == Int64(data.count) else {
      throw ObjectReadError.lengthMismatch(
        key: key,
        expected: contentLength,
        received: Int64(data.count),
        contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding")
      )
    }
    guard let etag = http.value(forHTTPHeaderField: "ETag") else {
      throw ObjectReadError.missingETag(key)
    }
    var otherHeaders: [String: String] = [:]
    for name in ["Content-Encoding", "Content-Disposition", "Content-Language", "Expires"] {
      otherHeaders[name] = http.value(forHTTPHeaderField: name)
    }
    return S3StoredObject(
      key: key,
      data: data,
      etag: etag,
      contentType: http.value(forHTTPHeaderField: "Content-Type"),
      cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
      contentLength: contentLength,
      lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
      metadata: Self.userMetadata(http),
      otherHeaders: otherHeaders
    )
  }

  private static func userMetadata(_ response: HTTPURLResponse) -> [String: String] {
    var metadata: [String: String] = [:]
    for (name, value) in response.allHeaderFields {
      let normalizedName = String(describing: name).lowercased()
      guard normalizedName.hasPrefix("x-amz-meta-") else { continue }
      metadata[String(normalizedName.dropFirst("x-amz-meta-".count))] = String(describing: value)
    }
    return metadata
  }

  private func bucketURL(continuationToken: String?) throws -> URL {
    var components = try endpointComponents()
    components.percentEncodedPath = SigV4Signer.awsEncode(
      joinedPath(components.percentEncodedPath, backend.bucket),
      preserveSlash: true
    )
    var queryItems = [URLQueryItem(name: "list-type", value: "2")]
    if let continuationToken {
      queryItems.append(URLQueryItem(name: "continuation-token", value: continuationToken))
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw S3UploaderError.invalidEndpoint(backend.endpoint)
    }
    return url
  }

  private func objectURL(key: String) throws -> URL {
    var components = try endpointComponents()
    components.percentEncodedPath = SigV4Signer.awsEncode(
      joinedPath(components.percentEncodedPath, "\(backend.bucket)/\(key)"),
      preserveSlash: true
    )
    guard let url = components.url else {
      throw S3UploaderError.invalidEndpoint(backend.endpoint)
    }
    return url
  }

  private func endpointComponents() throws -> URLComponents {
    guard var components = URLComponents(string: backend.endpoint),
      components.scheme != nil,
      components.host != nil
    else {
      throw S3UploaderError.invalidEndpoint(backend.endpoint)
    }
    components.query = nil
    components.fragment = nil
    return components
  }

  private func joinedPath(_ encodedBase: String, _ suffix: String) -> String {
    let decodedBase = encodedBase.removingPercentEncoding ?? encodedBase
    let base = decodedBase.hasSuffix("/") ? String(decodedBase.dropLast()) : decodedBase
    return "\(base)/\(suffix)"
  }

  private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
      throw S3UploaderError.invalidResponse
    }
    return response
  }

  private static let emptyPayloadHash =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}

private struct ListObjectsPage {
  let objects: [S3ObjectSummary]
  let isTruncated: Bool
  let nextContinuationToken: String?
}

private final class ListObjectsParser: NSObject, XMLParserDelegate {
  private var objects: [S3ObjectSummary] = []
  private var currentKey: String?
  private var currentSize: Int64?
  private var currentLastModified: String?
  private var currentText = ""
  private var isTruncated = false
  private var nextContinuationToken: String?

  static func parse(_ data: Data) throws -> ListObjectsPage {
    let delegate = ListObjectsParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
      throw parser.parserError ?? S3UploaderError.invalidResponse
    }
    return ListObjectsPage(
      objects: delegate.objects,
      isTruncated: delegate.isTruncated,
      nextContinuationToken: delegate.nextContinuationToken
    )
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentText = ""
    if elementName == "Contents" {
      currentKey = nil
      currentSize = nil
      currentLastModified = nil
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "Key":
      currentKey = value
    case "Size":
      currentSize = Int64(value)
    case "LastModified":
      currentLastModified = value
    case "IsTruncated":
      isTruncated = value.lowercased() == "true"
    case "NextContinuationToken":
      nextContinuationToken = value.isEmpty ? nil : value
    case "Contents":
      if let currentKey, let currentSize {
        objects.append(
          S3ObjectSummary(
            key: currentKey,
            byteSize: currentSize,
            lastModified: currentLastModified
          ))
      }
    default:
      break
    }
    currentText = ""
  }
}
