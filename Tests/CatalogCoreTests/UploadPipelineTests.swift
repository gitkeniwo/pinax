import Foundation
import GRDB
import Testing

@testable import CatalogCore

@Test("Concurrent duplicate uploads perform one network request and persist one asset")
func uploadPipelineDeduplicates() async throws {
  let fixture = try UploadFixture()
  defer { fixture.remove() }
  let uploader = CountingUploader()
  let pipeline = UploadPipeline(
    database: fixture.database,
    uploader: uploader,
    backend: fixture.backend,
    project: fixture.project
  )

  async let first = pipeline.upload(fileURL: fixture.imageURL, date: fixture.date)
  async let second = pipeline.upload(fileURL: fixture.imageURL, date: fixture.date)
  let outcomes = try await [first, second]

  #expect(await uploader.uploadCount == 1)
  #expect(try fixture.rowCount("asset") == 1)
  #expect(try fixture.rowCount("asset_project") == 1)
  #expect(outcomes.map(\.url).allSatisfy { $0 == outcomes[0].url })
  #expect(
    try UploadOutput.format([outcomes[0]], as: .markdown)
      == "![pixel](https://img.example.com/blog/202608/pixel-431ced6916a2.png)"
  )

  let duplicate = try await pipeline.upload(fileURL: fixture.imageURL, date: fixture.date)
  #expect(duplicate.deduplicated)
  #expect(await uploader.uploadCount == 1)

  let unscopedPipeline = UploadPipeline(
    database: fixture.database,
    uploader: uploader,
    backend: fixture.backend
  )
  let forced = try await unscopedPipeline.upload(
    fileURL: fixture.imageURL,
    force: true,
    date: fixture.date.addingTimeInterval(86_400)
  )
  #expect(forced.key == outcomes[0].key)
  #expect(await uploader.uploadCount == 2)
}

@Test("Dry-run reports the planned key without network or database writes")
func uploadPipelineDryRun() async throws {
  let fixture = try UploadFixture()
  defer { fixture.remove() }
  let uploader = CountingUploader()
  let pipeline = UploadPipeline(
    database: fixture.database,
    uploader: uploader,
    backend: fixture.backend,
    project: fixture.project
  )

  let outcome = try await pipeline.upload(
    fileURL: fixture.imageURL,
    dryRun: true,
    date: fixture.date
  )

  #expect(outcome.dryRun)
  #expect(!outcome.deduplicated)
  #expect(outcome.key == "blog/202608/pixel-431ced6916a2.png")
  #expect(await uploader.uploadCount == 0)
  #expect(try fixture.rowCount("asset") == 0)
}

@Test("Upload JSON is a versioned collection for one or many assets")
func uploadJSONContract() async throws {
  let fixture = try UploadFixture()
  defer { fixture.remove() }
  let outcome = try await UploadPipeline(
    database: fixture.database,
    backend: fixture.backend,
    project: fixture.project
  ).upload(fileURL: fixture.imageURL, dryRun: true, date: fixture.date)

  for outcomes in [[outcome], [outcome, outcome]] {
    let json = try UploadOutput.format(outcomes, as: .json)
    let root = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    #expect(root["schema"] as? Int == 1)
    let assets = try #require(root["assets"] as? [[String: Any]])
    #expect(assets.count == outcomes.count)
    #expect(assets[0]["sha256"] as? String == outcome.sha256)
    #expect(assets[0]["deduplicated"] as? Bool == false)
    #expect(assets[0]["dry_run"] as? Bool == true)
    #expect(assets[0]["id"] == nil)
    #expect(assets[0]["backend_id"] == nil)
    #expect(assets[0]["keychain_ref"] == nil)
  }
}

@Test("Upload signs the exact owned bytes sent to the uploader")
func uploadHashMatchesOwnedPayload() async throws {
  let fixture = try UploadFixture()
  defer { fixture.remove() }
  let original = try Data(contentsOf: fixture.imageURL)
  let payload = original + Data([0])
  #expect(Hashing.sha256(of: original) != Hashing.sha256(of: payload))
  let uploader = CapturingUploader()
  let pipeline = UploadPipeline(
    database: fixture.database,
    uploader: uploader,
    backend: fixture.backend,
    project: fixture.project,
    dataReader: { _ in payload }
  )

  let outcome = try await pipeline.upload(fileURL: fixture.imageURL, date: fixture.date)
  let request = try #require(await uploader.request)

  #expect(request.data == payload)
  #expect(request.sha256 == Hashing.sha256(of: payload))
  #expect(outcome.sha256 == request.sha256)
  let storedHash = try await fixture.database.read { db in
    try String.fetchOne(db, sql: "SELECT sha256 FROM asset")
  }
  #expect(storedHash == request.sha256)
}

@Test("A source URL goes to the object metadata and asset meta, never imported_from")
func uploadRecordsSourceURL() async throws {
  let fixture = try UploadFixture()
  defer { fixture.remove() }
  let uploader = CapturingUploader()
  let pipeline = UploadPipeline(
    database: fixture.database,
    uploader: uploader,
    backend: fixture.backend,
    project: fixture.project
  )

  _ = try await pipeline.upload(
    fileURL: fixture.imageURL, date: fixture.date,
    sourceURL: "https://example.org/图/a.png?w=440#top")
  let request = try #require(await uploader.request)

  #expect(request.metadata["source-url"] == "https://example.org/%E5%9B%BE/a.png")
  let meta = try #require(
    try await fixture.database.read { db in try String.fetchOne(db, sql: "SELECT meta FROM asset") })
  let provenance = AssetProvenance(meta: meta)
  #expect(provenance.sourceURL == "https://example.org/图/a.png")
  #expect(provenance.importedFrom == nil)
  #expect(AssetSource.of(meta: meta) == .migrated)
}

@Test("Without a source URL the upload writes no source metadata")
func uploadWithoutSourceURL() async throws {
  let fixture = try UploadFixture()
  defer { fixture.remove() }
  let uploader = CapturingUploader()
  let pipeline = UploadPipeline(
    database: fixture.database, uploader: uploader, backend: fixture.backend, project: fixture.project)

  _ = try await pipeline.upload(fileURL: fixture.imageURL, date: fixture.date)
  let request = try #require(await uploader.request)

  #expect(request.metadata["source-url"] == nil)
  let meta = try await fixture.database.read { db in try String.fetchOne(db, sql: "SELECT meta FROM asset") }
  #expect(AssetSource.of(meta: meta) == .pinax)
}

@Test("A failed upload leaves the catalog unchanged")
func failedUploadLeavesNoAsset() async throws {
  let fixture = try UploadFixture()
  defer { fixture.remove() }
  let uploader = CountingUploader(shouldFail: true)
  let pipeline = UploadPipeline(
    database: fixture.database,
    uploader: uploader,
    backend: fixture.backend,
    project: fixture.project
  )

  do {
    _ = try await pipeline.upload(fileURL: fixture.imageURL, date: fixture.date)
    Issue.record("Expected the uploader to fail.")
  } catch is TestUploadError {
  }

  #expect(await uploader.uploadCount == 1)
  #expect(try fixture.rowCount("asset") == 0)
  #expect(try fixture.rowCount("asset_project") == 0)
}

@Test("S3 retries 429 and 5xx responses with the same request")
func s3RetriesTransientResponses() async throws {
  RetryURLProtocol.reset()
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [RetryURLProtocol.self]
  let session = URLSession(configuration: configuration)
  let backend = Backend(
    id: 1,
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
  let uploader = S3Uploader(
    backend: backend,
    credentials: BackendCredentials(accessKeyID: "access", secretAccessKey: "secret"),
    session: session,
    requestTimeout: 7,
    maxRetries: 2,
    baseRetryDelay: 0
  )
  let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  _ = try await uploader.upload(
    UploadRequest(
      data: Data("abc".utf8),
      sha256: hash,
      key: "retry.png",
      mime: "image/png",
      metadata: ["sha256": hash, "source-url": "https://example.org/a.png"]
    ))

  let requests = RetryURLProtocol.capturedRequests
  #expect(requests.count == 3)
  #expect(requests[0].value(forHTTPHeaderField: "x-amz-meta-source-url") == "https://example.org/a.png")
  #expect(requests.allSatisfy { $0.url == requests[0].url })
  #expect(requests.allSatisfy { $0.httpBody == requests[0].httpBody })
  #expect(requests.allSatisfy { $0.timeoutInterval == 7 })
}

private enum TestUploadError: Error {
  case failed
}

private actor CountingUploader: Uploader {
  private(set) var uploadCount = 0
  private let shouldFail: Bool

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  func upload(_ request: UploadRequest) async throws -> UploadResult {
    uploadCount += 1
    if shouldFail { throw TestUploadError.failed }
    return UploadResult(key: request.key, etag: "test")
  }

  func exists(key: String) async throws -> Bool {
    false
  }
}

private actor CapturingUploader: Uploader {
  private(set) var request: UploadRequest?

  func upload(_ request: UploadRequest) async throws -> UploadResult {
    self.request = request
    return UploadResult(key: request.key, etag: "test")
  }

  func exists(key: String) async throws -> Bool {
    false
  }
}

private final class UploadFixture {
  let directory: URL
  let database: CatalogDatabasePool
  let backend: Backend
  let project: Project
  let imageURL: URL
  let date = Date(timeIntervalSince1970: 1_787_184_000)

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    backend = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://storage.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://img.example.com",
      keychainReference: "backend.r2",
      to: database,
      now: date
    )
    project = try CatalogConfiguration.addProject(
      slug: "blog",
      name: "Blog",
      keyPrefix: "blog",
      backendSlug: "r2",
      to: database,
      now: date
    )
    imageURL = directory.appendingPathComponent("pixel.png")
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
    try png.write(to: imageURL)
  }

  func rowCount(_ table: String) throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")!
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class RetryURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var requests: [URLRequest] = []

  static var capturedRequests: [URLRequest] {
    lock.withLock { requests }
  }

  static func reset() {
    lock.withLock { requests = [] }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let attempt = Self.lock.withLock { () -> Int in
      Self.requests.append(request)
      return Self.requests.count
    }
    let status = attempt == 1 ? 429 : attempt == 2 ? 503 : 200
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
