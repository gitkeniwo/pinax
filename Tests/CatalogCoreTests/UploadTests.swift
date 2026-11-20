import CatalogCore
import Foundation
import Network
import Testing

private let emptySHA256 =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

@Test("SigV4 matches public AWS known-answer vectors")
func sigV4KnownAnswerVectors() throws {
  let credentials = BackendCredentials(
    accessKeyID: "AKIDEXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  )
  let signer = SigV4Signer(credentials: credentials, region: "us-east-1", service: "service")
  let date = try #require(awsVectorDateFormatter.date(from: "20150830T123600Z"))
  let vectors = ["get-vanilla", "get-vanilla-query-order-key"]

  for name in vectors {
    let directory = "Fixtures/aws-sig-v4-test-suite/\(name)"
    let requestURL = try #require(
      Bundle.module.url(forResource: name, withExtension: "req", subdirectory: directory)
    )
    let authorizationURL = try #require(
      Bundle.module.url(forResource: name, withExtension: "authz", subdirectory: directory)
    )
    let fixture = try String(contentsOf: requestURL, encoding: .utf8)
    let expected = try String(contentsOf: authorizationURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let request = try requestFromAWSFixture(fixture)
    let signed = try signer.sign(request, payloadHash: emptySHA256, date: date)
    #expect(signed.value(forHTTPHeaderField: "Authorization") == expected)
  }
}

@Test("SigV4 matches a known S3 path with space and plus")
func sigV4S3PathKnownAnswer() throws {
  let signer = SigV4Signer(
    credentials: BackendCredentials(
      accessKeyID: "AKIDEXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    ),
    region: "us-east-1"
  )
  var request = URLRequest(
    url: try #require(
      URL(string: "https://examplebucket.s3.amazonaws.com/photos/space%20%2B.png")
    )
  )
  request.httpMethod = "GET"
  request.setValue(emptySHA256, forHTTPHeaderField: "x-amz-content-sha256")
  let date = try #require(awsVectorDateFormatter.date(from: "20130524T000000Z"))
  let signed = try signer.sign(request, payloadHash: emptySHA256, date: date)
  #expect(
    signed.value(forHTTPHeaderField: "Authorization")
      == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=7c8a66f4931532944dce061b9ca09b5e0c79b1bc5d6e0ded3529dffa195029ad"
  )
}

@Test("S3 uploader sends signed path-style PUT and HEAD requests")
func s3UploaderRequestsAndErrors() async throws {
  MockURLProtocol.reset()
  MockURLProtocol.handler = { request in
    let path = request.url?.path ?? ""
    if request.httpMethod == "PUT" {
      return (200, ["ETag": "\"etag-1\""], Data())
    }
    if path.hasSuffix("missing.png") {
      return (404, [:], Data())
    }
    if path.hasSuffix("broken.png") {
      return (503, [:], Data("<Error><Code>SlowDown</Code></Error>".utf8))
    }
    return (200, [:], Data())
  }

  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  let session = URLSession(configuration: configuration)
  let backend = makeUploadBackend()
  let uploader = S3Uploader(
    backend: backend,
    credentials: BackendCredentials(accessKeyID: "access", secretAccessKey: "secret"),
    session: session,
    baseRetryDelay: 0
  )
  let upload = UploadRequest(
    data: Data("abc".utf8),
    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    key: "blog/my image.png",
    mime: "image/png",
    metadata: [
      "sha256": String(repeating: "a", count: 64),
      "orig-filename": "my image.png",
      "width": "1",
      "height": "1",
    ]
  )

  let result = try await uploader.upload(upload)
  #expect(result == UploadResult(key: upload.key, etag: "\"etag-1\""))
  #expect(try await uploader.exists(key: upload.key))
  #expect(try await uploader.exists(key: "missing.png") == false)

  do {
    _ = try await uploader.exists(key: "broken.png")
    Issue.record("Expected the typed S3 HTTP error")
  } catch let error as S3UploaderError {
    #expect(
      error
        == .http(
          statusCode: 503,
          body: "<Error><Code>SlowDown</Code></Error>"
        ))
  }

  let requests = MockURLProtocol.requests
  let put = try #require(requests.first(where: { $0.httpMethod == "PUT" }))
  #expect(put.url?.absoluteString == "https://storage.example.com/images/blog/my%20image.png")
  #expect(put.value(forHTTPHeaderField: "Content-Type") == "image/png")
  #expect(put.value(forHTTPHeaderField: "Cache-Control") == S3Uploader.immutableCacheControl)
  #expect(put.value(forHTTPHeaderField: "x-amz-meta-sha256") == String(repeating: "a", count: 64))
  #expect(put.value(forHTTPHeaderField: "x-amz-meta-orig-filename") == "my image.png")
  #expect(put.value(forHTTPHeaderField: "x-amz-meta-width") == "1")
  #expect(put.value(forHTTPHeaderField: "x-amz-meta-height") == "1")
  #expect(
    put.value(forHTTPHeaderField: "x-amz-content-sha256")
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  #expect(put.value(forHTTPHeaderField: "Authorization")?.contains("/auto/s3/aws4_request") == true)
  #expect(requests.filter { $0.httpMethod == "HEAD" }.count == 6)
  #expect(requests.filter { $0.url?.path.hasSuffix("broken.png") == true }.count == 4)

  do {
    _ = try await uploader.upload(
      UploadRequest(
        data: Data(),
        sha256: emptySHA256,
        key: "bad.png",
        mime: "image/png",
        metadata: ["project": "blog"]
      ))
    Issue.record("Expected mutable metadata to be rejected")
  } catch let error as S3UploaderError {
    #expect(error == .invalidMetadataKey("project"))
  }
  do {
    _ = try await uploader.upload(
      UploadRequest(
        data: Data(),
        sha256: emptySHA256,
        key: "bad-header.png",
        mime: "图片/png",
        metadata: [:]
      ))
    Issue.record("Expected non-ASCII Content-Type to be rejected")
  } catch let error as S3UploaderError {
    #expect(error == .nonASCIIHeaderValue("Content-Type"))
  }
}

@Test("S3 metadata reaches the wire as reversible ASCII")
func s3TransmittedMetadataIsASCII() async throws {
  let server = try LoopbackHTTPServer()
  let port = try server.start()
  let timestamp = "2026-08-20T00:00:00Z"
  let backend = Backend(
    slug: "loopback",
    kind: "s3",
    endpoint: "http://127.0.0.1:\(port)",
    bucket: "images",
    region: "auto",
    urlPrefix: "http://127.0.0.1:\(port)",
    keychainRef: "loopback",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  let session = URLSession(configuration: .ephemeral)
  let uploader = S3Uploader(
    backend: backend,
    credentials: BackendCredentials(accessKeyID: "access", secretAccessKey: "secret"),
    session: session
  )
  let filename = "截屏2026-08-20 15.36.19.png"
  let encodedFilename = MetadataValueCodec.encode(filename)
  #expect(encodedFilename.unicodeScalars.allSatisfy { $0.value <= 127 })
  #expect(try MetadataValueCodec.decode(encodedFilename) == filename)

  _ = try await uploader.upload(
    UploadRequest(
      data: Data("abc".utf8),
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      key: "wire test+plus.png",
      mime: "image/png",
      metadata: [
        "sha256": String(repeating: "a", count: 64),
        "orig-filename": filename,
        "width": "1",
        "height": "1",
      ]
    ))

  let requestHead = try server.waitForRequestHead()
  #expect(headerValue("x-amz-meta-orig-filename", in: requestHead) == encodedFilename)
  #expect(headerValue("x-amz-meta-orig-filename", in: requestHead)?.isEmpty == false)
  #expect(headerValue("authorization", in: requestHead)?.isEmpty == false)
  #expect(requestHead.contains("PUT /images/wire%20test%2Bplus.png HTTP/1.1\r\n"))
}

private func headerValue(_ name: String, in requestHead: String) -> String? {
  for line in requestHead.components(separatedBy: "\r\n") {
    guard let separator = line.firstIndex(of: ":"),
      line[..<separator].lowercased() == name.lowercased()
    else {
      continue
    }
    return line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
  }
  return nil
}

@Test(
  "S3 integration uploads and reaches a tiny PNG",
  .enabled(
    if: ProcessInfo.processInfo.environment["PINAX_INTEGRATION"] == "1",
    "Set PINAX_INTEGRATION=1 to use a real bucket."
  )
)
func s3Integration() async throws {
  let environment = ProcessInfo.processInfo.environment
  let endpoint = try #require(environment["PINAX_S3_ENDPOINT"])
  let bucket = try #require(environment["PINAX_S3_BUCKET"])
  let urlPrefix = try #require(environment["PINAX_S3_URL_PREFIX"])
  let accessKeyID = try #require(environment["PINAX_ACCESS_KEY_ID"])
  let secretAccessKey = try #require(environment["PINAX_SECRET_ACCESS_KEY"])
  let region = environment["PINAX_S3_REGION"] ?? "auto"
  let timestamp = "2026-08-20T00:00:00Z"
  let backend = Backend(
    slug: "integration",
    kind: "s3",
    endpoint: endpoint,
    bucket: bucket,
    region: region,
    urlPrefix: urlPrefix,
    keychainRef: "integration",
    createdAt: timestamp,
    updatedAt: timestamp
  )
  let uploader = S3Uploader(
    backend: backend,
    credentials: BackendCredentials(
      accessKeyID: accessKeyID,
      secretAccessKey: secretAccessKey
    )
  )
  let png = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  )!
  let payloadHash = try sha256ForIntegrationFixture(png)
  let key = "pinax-test/\(UUID().uuidString.lowercased()) space+plus.png"
  _ = try await uploader.upload(
    UploadRequest(
      data: png,
      sha256: payloadHash,
      key: key,
      mime: "image/png",
      metadata: [
        "sha256": payloadHash,
        "orig-filename": "截屏 pixel.png",
        "width": "1",
        "height": "1",
      ]
    ))
  #expect(try await uploader.exists(key: key))

  var publicRequest = URLRequest(url: try #require(URL(string: "\(urlPrefix)/\(key)")))
  publicRequest.httpMethod = "HEAD"
  let (_, response) = try await URLSession.shared.data(for: publicRequest)
  let http = try #require(response as? HTTPURLResponse)
  #expect((200..<300).contains(http.statusCode))
}

private func requestFromAWSFixture(_ fixture: String) throws -> URLRequest {
  let lines = fixture.split(separator: "\n", omittingEmptySubsequences: false)
  let requestLine = lines[0].split(separator: " ")
  let target = String(requestLine[1])
  let headers: [String: String] = Dictionary(
    uniqueKeysWithValues: lines.dropFirst().compactMap { line in
      guard let separator = line.firstIndex(of: ":") else { return nil }
      return (
        String(line[..<separator]),
        String(line[line.index(after: separator)...])
      )
    }
  )
  let host = try #require(headers["Host"])
  var request = URLRequest(url: try #require(URL(string: "https://\(host)\(target)")))
  request.httpMethod = String(requestLine[0])
  for (name, value) in headers where name != "Host" {
    request.setValue(value, forHTTPHeaderField: name)
  }
  return request
}

private func makeUploadBackend() -> Backend {
  Backend(
    slug: "r2",
    kind: "s3",
    endpoint: "https://storage.example.com",
    bucket: "images",
    region: "auto",
    urlPrefix: "https://img.example.com",
    keychainRef: "backend.r2",
    createdAt: "2026-08-20T00:00:00Z",
    updatedAt: "2026-08-20T00:00:00Z"
  )
}

private func sha256ForIntegrationFixture(_ data: Data) throws -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("pixel.png")
  try data.write(to: file)
  return try Hashing.sha256(ofFileAt: file)
}

private let awsVectorDateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
  return formatter
}()

private enum LoopbackHTTPServerError: Error {
  case startupTimeout
  case requestTimeout
}

private final class LoopbackHTTPServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "tech.gitkeniwo.pinax.tests.loopback")
  private let ready = DispatchSemaphore(value: 0)
  private let received = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var boundPort: UInt16?
  private var requestHead: String?

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    self.listener = try NWListener(using: parameters)
  }

  deinit {
    listener.cancel()
  }

  func start() throws -> UInt16 {
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.lock.withLock {
          self.boundPort = self.listener.port?.rawValue
        }
        self.ready.signal()
      case .failed:
        self.ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connection.start(queue: self.queue)
      self.receive(on: connection, accumulated: Data())
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success,
      let port = lock.withLock({ boundPort })
    else {
      throw LoopbackHTTPServerError.startupTimeout
    }
    return port
  }

  func waitForRequestHead() throws -> String {
    guard received.wait(timeout: .now() + 5) == .success,
      let requestHead = lock.withLock({ requestHead })
    else {
      throw LoopbackHTTPServerError.requestTimeout
    }
    return requestHead
  }

  private func receive(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      var request = accumulated
      if let data {
        request.append(data)
      }
      if let delimiter = request.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: request[..<delimiter.upperBound], as: UTF8.self)
        self.lock.withLock {
          self.requestHead = head
        }
        self.received.signal()
        let response = Data(
          "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
        )
        connection.send(
          content: response,
          completion: .contentProcessed { _ in
            connection.cancel()
          })
      } else if !complete && error == nil {
        self.receive(on: connection, accumulated: request)
      } else {
        connection.cancel()
      }
    }
  }
}

private final class MockURLProtocol: URLProtocol {
  typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)

  private static let lock = NSLock()
  private static var recordedRequests: [URLRequest] = []
  static var handler: Handler?

  static var requests: [URLRequest] {
    lock.withLock { recordedRequests }
  }

  static func reset() {
    lock.withLock { recordedRequests = [] }
    handler = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.withLock { Self.recordedRequests.append(request) }
    do {
      guard let handler = Self.handler, let requestURL = request.url else {
        throw URLError(.badURL)
      }
      let (status, headers, data) = try handler(request)
      guard
        let response = HTTPURLResponse(
          url: requestURL,
          statusCode: status,
          httpVersion: "HTTP/1.1",
          headerFields: headers
        )
      else {
        throw URLError(.badServerResponse)
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !data.isEmpty {
        client?.urlProtocol(self, didLoad: data)
      }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
