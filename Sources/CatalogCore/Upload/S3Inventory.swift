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

  public init(
    key: String,
    byteSize: Int64,
    mime: String?,
    lastModified: String?,
    metadata: [String: String],
    cacheControl: String? = nil
  ) {
    self.key = key
    self.byteSize = byteSize
    self.mime = mime
    self.lastModified = lastModified
    self.metadata = metadata
    self.cacheControl = cacheControl
  }
}

public protocol ObjectInventory: Sendable {
  func listObjects() async throws -> [S3ObjectSummary]
  func headObject(key: String) async throws -> S3ObjectHead
}

public struct S3ObjectInventory: ObjectInventory {
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
    var metadata: [String: String] = [:]
    for (name, value) in http.allHeaderFields {
      let normalizedName = String(describing: name).lowercased()
      guard normalizedName.hasPrefix("x-amz-meta-") else { continue }
      metadata[String(normalizedName.dropFirst("x-amz-meta-".count))] = String(describing: value)
    }
    return S3ObjectHead(
      key: key,
      byteSize: Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
      mime: http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(
        String.init),
      lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
      metadata: metadata,
      cacheControl: http.value(forHTTPHeaderField: "Cache-Control")
    )
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
