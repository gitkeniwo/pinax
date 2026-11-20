import Foundation
import GRDB
import Testing

@testable import CatalogCore

/// A new key is never overwritten. Stub
/// uploaders and a stub URL protocol only; no real bucket.
/// Serialized: the S3 tests share one stub URL protocol's state.
@Suite(.serialized) struct KeyCollisionTests {
  private static let pngs = [
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  ]
  private let date = ISO8601DateFormatter().date(from: "2026-10-27T10:00:00Z")!

  private final class Fixture {
    let directory: URL
    let database: CatalogDatabasePool
    let backend: Backend
    let project: Project
    let files: [URL]

    init(template: String?, date: Date) throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinax-collision-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
      try Database.migrate(database)
      backend = try CatalogConfiguration.addBackend(
        slug: "r2", endpoint: "https://storage.example.com", bucket: "images", region: "auto",
        urlPrefix: "https://img.example.com", keychainReference: "backend.r2", to: database,
        now: date)
      project = try CatalogConfiguration.addProject(
        slug: "blog", name: "Blog", keyPrefix: "blog", keyTemplate: template,
        backendSlug: "r2", to: database, now: date)
      // Two different images, both called image.png.
      let root = directory
      files = try KeyCollisionTests.pngs.enumerated().map { index, base64 in
        let folder = root.appendingPathComponent("drop\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("image.png")
        try Data(base64Encoded: base64)!.write(to: url)
        return url
      }
    }

    func pipeline(_ uploader: any Uploader) -> UploadPipeline {
      UploadPipeline(database: database, uploader: uploader, backend: backend, project: project)
    }

    func assetCount() throws -> Int {
      try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset")! }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// A row the delete flow leaves in pending_deletion for `key`.
    func stagePendingDeletion(key: String, keepRemote: Bool, backendID: Int64? = nil) throws {
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO pending_deletion
              (backend_id, key, sha256, byte_size, keep_remote, phase, snapshot,
               requested_at, updated_at)
            VALUES (?, ?, ?, 1, ?, ?, '{}', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')
            """,
          arguments: [
            backendID ?? backend.id, key, String(repeating: "a", count: 64), keepRemote,
            keepRemote ? "kept" : "delete_sent",
          ])
      }
    }
  }

  private let taken = UploadPipelineError.keyTaken("blog/202610/image.png")

  @Test("The key-taken error reads exactly as specified")
  func message() {
    #expect(
      taken.description
        == "The key \"blog/202610/image.png\" is already taken in this bucket. Add {hash} to the project's key template, or rename the file."
    )
  }

  @Test("Two same-named images uploaded at once: one succeeds, the other is refused")
  func concurrentSameName() async throws {
    let fixture = try Fixture(template: "{prefix}/{year}{month}/{name}.{ext}", date: date)
    defer { fixture.remove() }
    let bucket = StubBucket(putDelay: 0.2)
    let pipeline = fixture.pipeline(bucket)
    func attempt(_ url: URL) async -> Result<UploadOutcome, Error> {
      do { return .success(try await pipeline.upload(fileURL: url, date: date)) } catch {
        return .failure(error)
      }
    }
    async let first = attempt(fixture.files[0])
    async let second = attempt(fixture.files[1])
    let results = await [first, second]

    #expect(results.filter { (try? $0.get()) != nil }.count == 1)
    let failures = results.compactMap { result -> Error? in
      if case let .failure(error) = result { return error }
      return nil
    }
    #expect(failures.count == 1)
    #expect(failures.first as? UploadPipelineError == taken)
    #expect(await bucket.puts.count == 1)
    #expect(try fixture.assetCount() == 1)
  }

  @Test("A key the catalog already has sends no PUT")
  func catalogPrecheck() async throws {
    let fixture = try Fixture(template: "{prefix}/{year}{month}/{name}.{ext}", date: date)
    defer { fixture.remove() }
    let bucket = StubBucket()
    let pipeline = fixture.pipeline(bucket)
    _ = try await pipeline.upload(fileURL: fixture.files[0], date: date)
    #expect(await bucket.puts.count == 1)

    await #expect(throws: taken) {
      try await pipeline.upload(fileURL: fixture.files[1], date: date)
    }
    #expect(await bucket.puts.count == 1)
    // The claim was released: the same file deduplicates as before.
    #expect(try await pipeline.upload(fileURL: fixture.files[0], date: date).deduplicated)
  }

  @Test(
    "A key waiting in pending_deletion counts as taken: no PUT",
    arguments: [false, true])
  func pendingDeletionPrecheck(keepRemote: Bool) async throws {
    let fixture = try Fixture(template: "{prefix}/{year}{month}/{name}.{ext}", date: date)
    defer { fixture.remove() }
    try fixture.stagePendingDeletion(key: "blog/202610/image.png", keepRemote: keepRemote)
    let bucket = StubBucket()
    await #expect(throws: taken) {
      try await fixture.pipeline(bucket).upload(fileURL: fixture.files[0], date: date)
    }
    #expect(await bucket.puts.isEmpty)
    #expect(await bucket.heads.isEmpty)
    #expect(try fixture.assetCount() == 0)
  }

  @Test("pending_deletion under another backend doesn't take the key; dry-run doesn't check")
  func pendingDeletionScope() async throws {
    let fixture = try Fixture(template: "{prefix}/{year}{month}/{name}.{ext}", date: date)
    defer { fixture.remove() }
    let other = try CatalogConfiguration.addBackend(
      slug: "b2", endpoint: "https://other.example.com", bucket: "images", region: "auto",
      urlPrefix: "https://other.example.com", keychainReference: "backend.b2",
      to: fixture.database, now: date)
    try fixture.stagePendingDeletion(
      key: "blog/202610/image.png", keepRemote: false, backendID: other.id)
    let bucket = StubBucket()
    let pipeline = fixture.pipeline(bucket)
    let outcome = try await pipeline.upload(fileURL: fixture.files[0], date: date)
    #expect(outcome.key == "blog/202610/image.png")
    #expect(await bucket.puts.count == 1)

    try fixture.stagePendingDeletion(key: "blog/202610/image-2.png", keepRemote: true)
    let renamed = fixture.files[1].deletingLastPathComponent()
      .appendingPathComponent("image-2.png")
    try FileManager.default.moveItem(at: fixture.files[1], to: renamed)
    let dry = try await pipeline.upload(fileURL: renamed, dryRun: true, date: date)
    #expect(dry.key == "blog/202610/image-2.png")
    #expect(await bucket.puts.count == 1)
  }

  @Test("412, and the object there has this sha256: treated as uploaded")
  func preconditionSameContent() async throws {
    let fixture = try Fixture(template: "{prefix}/{year}{month}/{name}.{ext}", date: date)
    defer { fixture.remove() }
    let sha = try Hashing.sha256(ofFileAt: fixture.files[0])
    let bucket = StubBucket(objects: ["blog/202610/image.png": sha])
    let outcome = try await fixture.pipeline(bucket).upload(fileURL: fixture.files[0], date: date)
    #expect(outcome.key == "blog/202610/image.png")
    #expect(!outcome.deduplicated)
    #expect(await bucket.puts.map(\.createOnly) == [true])
    #expect(await bucket.heads == ["blog/202610/image.png"])
    #expect(try fixture.assetCount() == 1)
  }

  @Test("412, and the object there is other content or has no sha256: refused")
  func preconditionOtherContent() async throws {
    for remote in ["0" + String(repeating: "f", count: 63), nil] as [String?] {
      let fixture = try Fixture(template: "{prefix}/{year}{month}/{name}.{ext}", date: date)
      defer { fixture.remove() }
      let bucket = StubBucket(objects: ["blog/202610/image.png": remote ?? StubBucket.noMetadata])
      await #expect(throws: taken) {
        try await fixture.pipeline(bucket).upload(fileURL: fixture.files[0], date: date)
      }
      #expect(await bucket.objects["blog/202610/image.png"] == (remote ?? StubBucket.noMetadata))
      #expect(try fixture.assetCount() == 0)
    }
  }

  @Test("A forced re-upload keeps its key and sends no If-None-Match")
  func forceIsUnconditional() async throws {
    let fixture = try Fixture(template: nil, date: date)
    defer { fixture.remove() }
    let bucket = StubBucket()
    let pipeline = fixture.pipeline(bucket)
    let first = try await pipeline.upload(fileURL: fixture.files[0], date: date)
    let forced = try await pipeline.upload(fileURL: fixture.files[0], force: true, date: date)
    #expect(forced.key == first.key)
    #expect(await bucket.puts.map(\.createOnly) == [true, false])
    #expect(await bucket.heads.isEmpty)
  }

  @Test("The default template with {hash}: same-named images get two keys, as before")
  func defaultTemplateUnchanged() async throws {
    let fixture = try Fixture(template: nil, date: date)
    defer { fixture.remove() }
    let bucket = StubBucket()
    let pipeline = fixture.pipeline(bucket)
    async let first = pipeline.upload(fileURL: fixture.files[0], date: date)
    async let second = pipeline.upload(fileURL: fixture.files[1], date: date)
    let keys = try await [first, second].map(\.key)
    #expect(Set(keys).count == 2)
    #expect(keys.allSatisfy { $0.hasPrefix("blog/202610/image-") && $0.hasSuffix(".png") })
    #expect(await bucket.puts.count == 2)
    #expect(try fixture.assetCount() == 2)
  }

  // MARK: - S3Uploader

  private func s3Uploader() -> S3Uploader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PreconditionURLProtocol.self]
    return S3Uploader(
      backend: Backend(
        id: 1, slug: "r2", kind: "s3", endpoint: "https://storage.example.com",
        bucket: "images", region: "auto", urlPrefix: "https://img.example.com",
        keychainRef: "backend.r2", createdAt: "2026-10-27T00:00:00Z",
        updatedAt: "2026-10-27T00:00:00Z"),
      credentials: BackendCredentials(accessKeyID: "access", secretAccessKey: "secret"),
      session: URLSession(configuration: configuration), maxRetries: 0, baseRetryDelay: 0)
  }

  private func request(createOnly: Bool) -> UploadRequest {
    let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    return UploadRequest(
      data: Data("abc".utf8), sha256: hash, key: "blog/image.png", mime: "image/png",
      metadata: ["sha256": hash], createOnly: createOnly)
  }

  @Test("S3: create-only PUTs carry a signed If-None-Match: *, and 412 is its own error")
  func s3ConditionalPut() async throws {
    PreconditionURLProtocol.reset(status: 412)
    let uploader = s3Uploader()
    await #expect(throws: UploaderError.objectAlreadyExists(key: "blog/image.png")) {
      try await uploader.upload(request(createOnly: true))
    }
    let sent = try #require(PreconditionURLProtocol.captured.first)
    #expect(PreconditionURLProtocol.captured.count == 1)
    #expect(sent.value(forHTTPHeaderField: "If-None-Match") == "*")
    let authorization = try #require(sent.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains("if-none-match"))

    // The signature still verifies: re-signing what was sent, at its own
    // x-amz-date, reproduces the Authorization header.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let amzDate = try #require(
      sent.value(forHTTPHeaderField: "x-amz-date").flatMap(formatter.date(from:)))
    var unsigned = sent
    unsigned.setValue(nil, forHTTPHeaderField: "Authorization")
    // Added by URLSession after signing; not part of what was signed.
    unsigned.setValue(nil, forHTTPHeaderField: "Content-Length")
    let resigned = try SigV4Signer(
      credentials: BackendCredentials(accessKeyID: "access", secretAccessKey: "secret"),
      region: "auto", service: "s3"
    ).sign(unsigned, payloadHash: request(createOnly: true).sha256, date: amzDate)
    #expect(resigned.value(forHTTPHeaderField: "Authorization") == authorization)

    PreconditionURLProtocol.reset(status: 200)
    _ = try await uploader.upload(request(createOnly: false))
    #expect(PreconditionURLProtocol.captured.first?.value(forHTTPHeaderField: "If-None-Match") == nil)

    // Without create-only, a 412 stays a plain HTTP error.
    PreconditionURLProtocol.reset(status: 412)
    await #expect(throws: S3UploaderError.http(statusCode: 412, body: "")) {
      try await uploader.upload(request(createOnly: false))
    }
  }

  @Test("S3: HEAD reports the object's x-amz-meta-sha256, or absent on 404")
  func s3Head() async throws {
    let uploader = s3Uploader()
    PreconditionURLProtocol.reset(status: 200, headers: ["x-amz-meta-sha256": "abc123"])
    #expect(try await uploader.head(key: "blog/image.png") == .present(sha256: "abc123"))
    #expect(PreconditionURLProtocol.captured.first?.httpMethod == "HEAD")
    PreconditionURLProtocol.reset(status: 200)
    #expect(try await uploader.head(key: "blog/image.png") == .present(sha256: nil))
    PreconditionURLProtocol.reset(status: 404)
    #expect(try await uploader.head(key: "blog/image.png") == .absent)
  }
}

/// An in-memory bucket that honours create-only PUTs the way S3 does.
private actor StubBucket: Uploader {
  static let noMetadata = "<no sha256 metadata>"

  struct Put: Equatable {
    let key: String
    let createOnly: Bool
  }

  private(set) var objects: [String: String]
  private(set) var puts: [Put] = []
  private(set) var heads: [String] = []
  private let putDelay: TimeInterval

  init(objects: [String: String] = [:], putDelay: TimeInterval = 0) {
    self.objects = objects
    self.putDelay = putDelay
  }

  func upload(_ request: UploadRequest) async throws -> UploadResult {
    puts.append(Put(key: request.key, createOnly: request.createOnly))
    if putDelay > 0 { try await Task.sleep(nanoseconds: UInt64(putDelay * 1_000_000_000)) }
    if request.createOnly, objects[request.key] != nil {
      throw UploaderError.objectAlreadyExists(key: request.key)
    }
    objects[request.key] = request.sha256
    return UploadResult(key: request.key, etag: "stub")
  }

  func exists(key: String) async throws -> Bool { objects[key] != nil }

  func head(key: String) async throws -> ObjectPresence {
    heads.append(key)
    guard let sha = objects[key] else { return .absent }
    return .present(sha256: sha == Self.noMetadata ? nil : sha)
  }
}

private final class PreconditionURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requests: [URLRequest] = []
  nonisolated(unsafe) private static var status = 200
  nonisolated(unsafe) private static var headers: [String: String] = [:]

  static var captured: [URLRequest] { lock.withLock { requests } }

  static func reset(status: Int, headers: [String: String] = [:]) {
    lock.withLock {
      requests = []
      Self.status = status
      Self.headers = headers
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let (status, headers) = Self.lock.withLock { () -> (Int, [String: String]) in
      Self.requests.append(request)
      return (Self.status, Self.headers)
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
