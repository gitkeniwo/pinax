import Foundation
import Testing
@testable import CatalogCore

/// The signed object reader against a URLProtocol on a `.invalid` host;
/// nothing reaches a network.
@Suite(.serialized) struct ObjectReaderTests {
  private static let emptyHash =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  private func inventory(maxRetries: Int = 3) -> S3ObjectInventory {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReaderStub.self]
    return S3ObjectInventory(
      backend: Backend(
        slug: "r2", kind: "s3", endpoint: "https://store.invalid", bucket: "images",
        region: "auto", urlPrefix: "https://cdn.invalid", keychainRef: "",
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"),
      credentials: BackendCredentials(accessKeyID: "access", secretAccessKey: "secret"),
      session: URLSession(configuration: configuration),
      maxRetries: maxRetries,
      baseRetryDelay: 0)
  }

  private func ok(
    _ body: String = "hello", headers: [String: String] = [:], without: [String] = []
  ) -> ReaderStub.Answer {
    var all = ["ETag": "\"abc123\"", "Content-Length": String(body.utf8.count)]
      .merging(headers) { $1 }
    for name in without { all[name] = nil }
    return ReaderStub.Answer(status: 200, headers: all, body: Data(body.utf8))
  }

  @Test("The GET is signed, and neither answered from the URL cache nor compressed")
  func signedRequest() async throws {
    ReaderStub.script([ok()])
    let object = try await inventory().getObject(key: "a.txt")
    #expect(object.data == Data("hello".utf8))
    let request = try #require(ReaderStub.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://store.invalid/images/a.txt")
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 "))
    #expect(authorization.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date,"))
    #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == Self.emptyHash)
    #expect(request.value(forHTTPHeaderField: "x-amz-date") != nil)
    #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
  }

  @Test("A key with spaces, CJK and + is encoded as headObject encodes it")
  func keyEncoding() async throws {
    let key = "blog/my photo+中.png"
    ReaderStub.script([ok(), ok()])
    let object = try await inventory().getObject(key: key)
    _ = try await inventory().headObject(key: key)
    #expect(object.key == key)
    let urls = ReaderStub.requests.compactMap { $0.url?.absoluteString }
    let expected = "https://store.invalid/images/blog/my%20photo%2B%E4%B8%AD.png"
    #expect(urls == [expected, expected])
  }

  @Test("Headers are returned as sent; an absent Cache-Control is nil")
  func headersAsSent() async throws {
    ReaderStub.script([
      ok(headers: [
        "ETag": "\"d41d8-2\"",
        "Content-Type": "text/plain; charset=utf-8",
        "Last-Modified": "Tue, 14 Nov 2023 22:13:20 GMT",
        "X-Amz-Meta-Sha256": "feed",
        "x-amz-meta-orig-filename": "a%20b.txt",
        "Content-Disposition": "attachment; filename=\"a.txt\"",
        "Content-Language": "en",
        "Expires": "Wed, 15 Nov 2023 22:13:20 GMT",
        "x-amz-request-id": "not-recorded",
      ])
    ])
    let object = try await inventory().getObject(key: "a.txt")
    #expect(object.etag == "\"d41d8-2\"")
    #expect(object.contentType == "text/plain; charset=utf-8")
    #expect(object.cacheControl == nil)
    #expect(object.contentLength == 5)
    #expect(object.lastModified == "Tue, 14 Nov 2023 22:13:20 GMT")
    #expect(object.metadata == ["sha256": "feed", "orig-filename": "a%20b.txt"])
    #expect(
      object.otherHeaders == [
        "Content-Disposition": "attachment; filename=\"a.txt\"",
        "Content-Language": "en",
        "Expires": "Wed, 15 Nov 2023 22:13:20 GMT",
      ])
  }

  @Test("A present Cache-Control and Content-Encoding are returned as sent")
  func cacheControlAndEncoding() async throws {
    ReaderStub.script([
      ok(headers: ["Cache-Control": "no-store", "Content-Encoding": "zstd"])
    ])
    let object = try await inventory().getObject(key: "a.txt")
    #expect(object.cacheControl == "no-store")
    #expect(object.otherHeaders == ["Content-Encoding": "zstd"])
  }

  @Test("headObject returns the ETag, quotes included, or nil")
  func headETag() async throws {
    ReaderStub.script([ok(), ok(without: ["ETag"])])
    #expect(try await inventory().headObject(key: "a.txt").etag == "\"abc123\"")
    #expect(try await inventory().headObject(key: "a.txt").etag == nil)
  }

  @Test("A byte count other than Content-Length throws, and so does no Content-Length")
  func lengthMismatch() async throws {
    ReaderStub.script([ok(headers: ["Content-Length": "9"])])
    await #expect(
      throws: ObjectReadError.lengthMismatch(
        key: "a.txt", expected: 9, received: 5, contentEncoding: nil)
    ) {
      _ = try await inventory().getObject(key: "a.txt")
    }
    // What a body that URLSession decompressed looks like.
    ReaderStub.script([ok(headers: ["Content-Length": "3", "Content-Encoding": "gzip"])])
    await #expect(
      throws: ObjectReadError.lengthMismatch(
        key: "a.txt", expected: 3, received: 5, contentEncoding: "gzip")
    ) {
      _ = try await inventory().getObject(key: "a.txt")
    }
    ReaderStub.script([ok(without: ["Content-Length"])])
    await #expect(
      throws: ObjectReadError.lengthMismatch(
        key: "a.txt", expected: nil, received: 5, contentEncoding: nil)
    ) {
      _ = try await inventory().getObject(key: "a.txt")
    }
  }

  @Test("A response without an ETag throws")
  func missingETag() async throws {
    ReaderStub.script([ok(without: ["ETag"])])
    await #expect(throws: ObjectReadError.missingETag("a.txt")) {
      _ = try await inventory().getObject(key: "a.txt")
    }
  }

  @Test("404 is notFound, asked once")
  func notFound() async throws {
    ReaderStub.script([ReaderStub.Answer(status: 404)])
    await #expect(throws: ObjectReadError.notFound("gone.txt")) {
      _ = try await inventory().getObject(key: "gone.txt")
    }
    #expect(ReaderStub.requests.count == 1)
  }

  @Test("503 and 429 are retried until the object comes")
  func retried() async throws {
    ReaderStub.script([ReaderStub.Answer(status: 503), ReaderStub.Answer(status: 429), ok()])
    #expect(try await inventory().getObject(key: "a.txt").data == Data("hello".utf8))
    #expect(ReaderStub.requests.count == 3)
  }

  @Test("A 503 that stays is an HTTP error after the retries")
  func retriesRunOut() async throws {
    ReaderStub.script(Array(repeating: ReaderStub.Answer(status: 503), count: 5))
    await #expect(throws: S3UploaderError.http(statusCode: 503, body: "")) {
      _ = try await inventory(maxRetries: 2).getObject(key: "a.txt")
    }
    #expect(ReaderStub.requests.count == 3)
  }

  @Test("403 is an HTTP error with the body, asked once")
  func forbidden() async throws {
    ReaderStub.script([ReaderStub.Answer(status: 403, body: Data("AccessDenied".utf8))])
    await #expect(throws: S3UploaderError.http(statusCode: 403, body: "AccessDenied")) {
      _ = try await inventory().getObject(key: "a.txt")
    }
    #expect(ReaderStub.requests.count == 1)
  }
}

/// Answers each request with the next scripted answer.
private final class ReaderStub: URLProtocol {
  struct Answer {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var answers: [Answer] = []
  nonisolated(unsafe) private static var recorded: [URLRequest] = []

  static var requests: [URLRequest] { lock.withLock { recorded } }

  static func script(_ next: [Answer]) {
    lock.withLock {
      answers = next
      recorded = []
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let answer: Answer? = Self.lock.withLock {
      Self.recorded.append(request)
      return Self.answers.isEmpty ? nil : Self.answers.removeFirst()
    }
    guard let answer, let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
        headerFields: answer.headers)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !answer.body.isEmpty { client?.urlProtocol(self, didLoad: answer.body) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
