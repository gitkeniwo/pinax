import CatalogCore
import Foundation
import GRDB
import Testing

@Test("Domain migration preserves usage identity and resolves retired prefixes")
func domainMigration() throws {
  try withStewardshipCatalog { database in
    let first = Date(timeIntervalSince1970: 1_788_192_000)
    let second = first.addingTimeInterval(60)
    let third = second.addingTimeInterval(60)
    let backend = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://storage.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://a.example.com",
      keychainReference: "backend.r2",
      to: database,
      now: first
    )
    _ = try CatalogConfiguration.addProject(
      slug: "blog",
      name: "Blog",
      keyPrefix: "blog",
      backendSlug: "r2",
      to: database,
      now: first
    )
    let backendID = try #require(backend.id)
    let knownAsset = try insertStewardshipAsset(
      key: "blog/known.png",
      sha256: String(repeating: "1", count: 64),
      backendID: backendID,
      in: database,
      now: first
    )

    _ = try CatalogUsage.sync(
      UsageDocument(
        project: "blog",
        refs: [
          UsageReference(
            rawURL: "https://a.example.com/blog/known.png",
            sourceReference: "post.md#known",
            kind: "markdown"
          ),
          UsageReference(
            rawURL: "https://a.example.com/blog/later.png",
            sourceReference: "post.md#later",
            kind: "markdown"
          ),
        ]
      ),
      project: "blog",
      in: database,
      now: first
    )
    let original = try database.read { db in
      try Usage.filter(Column("source_ref") == "post.md#known").fetchOne(db)
    }
    #expect(original?.assetID == knownAsset.id)

    let updated = try CatalogConfiguration.setBackendURLPrefix(
      slug: "r2",
      urlPrefix: "https://b.example.com/",
      in: database,
      now: second
    )
    #expect(updated.urlPrefix == "https://b.example.com")
    #expect(
      try CatalogConfiguration.rewriteMap(backendSlug: "r2", in: database)
        == RewriteMap(
          current: "https://b.example.com",
          retired: ["https://a.example.com"]
        )
    )

    _ = try CatalogUsage.sync(
      UsageDocument(
        project: "blog",
        refs: [
          UsageReference(
            rawURL: "https://b.example.com/blog/known.png",
            sourceReference: "post.md#known",
            kind: "markdown"
          )
        ]
      ),
      project: "blog",
      in: database,
      now: second
    )
    let rewritten = try database.read { db in
      try Usage.filter(Column("source_ref") == "post.md#known").fetchAll(db)
    }
    #expect(rewritten.count == 1)
    #expect(rewritten[0].id == original?.id)
    #expect(rewritten[0].firstSeen == original?.firstSeen)
    #expect(rewritten[0].lastSeen != original?.lastSeen)
    #expect(rewritten[0].rawURL == "https://b.example.com/blog/known.png")
    #expect(rewritten[0].assetID == knownAsset.id)

    let laterAsset = try insertStewardshipAsset(
      key: "blog/later.png",
      sha256: String(repeating: "2", count: 64),
      backendID: backendID,
      in: database,
      now: third
    )
    _ = try CatalogUsage.sync(
      UsageDocument(
        project: "blog",
        refs: [
          UsageReference(
            rawURL: "https://a.example.com/blog/later.png",
            sourceReference: "post.md#later",
            kind: "markdown"
          )
        ]
      ),
      project: "blog",
      in: database,
      now: third
    )
    let stale = try database.read { db in
      try Usage.filter(Column("source_ref") == "post.md#later").fetchOne(db)
    }
    #expect(stale?.assetID == laterAsset.id)
    #expect(stale?.firstSeen == ISO8601DateFormatter().string(from: first))
  }
}

@Test("One source can retain current and retired URLs for the same asset")
func sameSourceDuplicateAssetReferences() throws {
  try withStewardshipCatalog { database in
    let now = Date(timeIntervalSince1970: 1_788_192_000)
    let backend = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://storage.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://old.example.com",
      keychainReference: "backend.r2",
      to: database,
      now: now
    )
    _ = try CatalogConfiguration.addProject(
      slug: "blog",
      name: "Blog",
      keyPrefix: "blog",
      backendSlug: "r2",
      to: database,
      now: now
    )
    _ = try insertStewardshipAsset(
      key: "blog/known.png",
      sha256: String(repeating: "1", count: 64),
      backendID: try #require(backend.id),
      in: database,
      now: now
    )
    _ = try CatalogConfiguration.setBackendURLPrefix(
      slug: "r2",
      urlPrefix: "https://new.example.com",
      in: database,
      now: now
    )

    let result = try CatalogUsage.sync(
      UsageDocument(
        project: "blog",
        refs: [
          UsageReference(
            rawURL: "https://old.example.com/blog/known.png",
            sourceReference: "dup.md"
          ),
          UsageReference(
            rawURL: "https://new.example.com/blog/known.png",
            sourceReference: "dup.md"
          ),
        ]
      ),
      project: "blog",
      in: database,
      now: now
    )
    let rows = try database.read { db in
      try Usage.filter(Column("source_ref") == "dup.md").order(Column("raw_url")).fetchAll(db)
    }

    #expect(result.foundCount == 2)
    #expect(rows.count == 2)
    #expect(
      Set(rows.map(\.rawURL)) == [
        "https://new.example.com/blog/known.png",
        "https://old.example.com/blog/known.png",
      ])
    #expect(rows.allSatisfy { $0.lastScanID == result.scanID })

    let repeated = try CatalogUsage.sync(
      UsageDocument(
        project: "blog",
        refs: [
          UsageReference(
            rawURL: "https://new.example.com/blog/known.png",
            sourceReference: "dup.md"
          ),
          UsageReference(
            rawURL: "https://old.example.com/blog/known.png",
            sourceReference: "dup.md"
          ),
        ]
      ),
      project: "blog",
      in: database,
      now: now.addingTimeInterval(60)
    )
    let repeatedRows = try database.read { db in
      try Usage.filter(Column("source_ref") == "dup.md").fetchAll(db)
    }
    #expect(repeated.foundCount == 2)
    #expect(repeatedRows.count == 2)
    #expect(Set(repeatedRows.compactMap(\.id)) == Set(rows.compactMap(\.id)))
    #expect(repeatedRows.allSatisfy { $0.lastScanID == repeated.scanID })
  }
}

private func withStewardshipCatalog(
  _ body: (CatalogDatabasePool) throws -> Void
) throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  try body(database)
}

@discardableResult
private func insertStewardshipAsset(
  key: String,
  sha256: String,
  backendID: Int64,
  in database: CatalogDatabasePool,
  now: Date
) throws -> Asset {
  let timestamp = ISO8601DateFormatter().string(from: now)
  return try database.write { db in
    try Asset(
      sha256: sha256,
      backendID: backendID,
      key: key,
      byteSize: 100,
      width: 10,
      height: 20,
      mime: "image/png",
      originalFilename: (key as NSString).lastPathComponent,
      uploadedAt: timestamp,
      createdAt: timestamp,
      updatedAt: timestamp
    ).insertAndFetch(db)
  }
}

@Test("Doctor checks storage, SQLite, scans, and credentials")
func doctorChecks() throws {
  try withStewardshipCatalog { database in
    let now = Date(timeIntervalSince1970: 1_788_192_000)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://storage.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://img.example.com",
      keychainReference: "backend.r2",
      to: database,
      now: now
    )
    _ = try CatalogConfiguration.addProject(
      slug: "resume",
      name: "Resume",
      keyPrefix: "resume",
      backendSlug: "r2",
      to: database,
      now: now
    )
    let databaseURL = URL(fileURLWithPath: database.path)
    let report = try CatalogDoctor.run(
      database: database,
      databaseURL: databaseURL,
      credentialExists: { _ in false }
    )
    #expect(!report.hasFailures)
    #expect(
      report.checks.contains {
        $0.name == "integrity-check" && $0.status == .pass && $0.detail == "ok"
      })
    #expect(
      report.checks.contains {
        $0.name == "journal-mode" && $0.status == .pass && $0.detail == "wal"
      })
    #expect(
      report.checks.contains {
        $0.name == "usage-scans" && $0.status == .warning && $0.detail == "resume"
      })
    #expect(
      report.checks.contains {
        $0.name == "backend-credentials" && $0.status == .warning
          && $0.detail == "missing credentials: r2"
      })
  }

  let cloudPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/CloudStorage/Dropbox/catalog.sqlite")
  #expect(DatabasePathSafety.problem(at: cloudPath)?.contains("synced storage") == true)
}

@Test("Doctor warns when recovered assets have no projects")
func doctorWarnsAboutMissingCatalogRelationships() throws {
  try withStewardshipCatalog { database in
    let now = Date(timeIntervalSince1970: 1_788_192_000)
    let backend = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://storage.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://img.example.com",
      keychainReference: "backend.r2",
      to: database,
      now: now
    )
    _ = try insertStewardshipAsset(
      key: "recovered.png",
      sha256: String(repeating: "a", count: 64),
      backendID: try #require(backend.id),
      in: database,
      now: now
    )

    let report = try CatalogDoctor.run(
      database: database,
      databaseURL: URL(fileURLWithPath: database.path),
      credentialExists: { _ in true }
    )
    let usageScans = try #require(report.checks.first { $0.name == "usage-scans" })
    #expect(usageScans.status == .warning)
    #expect(
      usageScans.detail
        == "1 asset, 0 projects. Reindex does not restore projects, tags, or usage history.")
  }
}

@Test("Backup exports every database table in a versioned document")
func backupContract() throws {
  try withStewardshipCatalog { database in
    let now = Date(timeIntervalSince1970: 1_788_192_000)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://storage.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://img.example.com",
      keychainReference: "backend.r2",
      to: database,
      now: now
    )
    _ = try CatalogConfiguration.addProject(
      slug: "blog",
      name: "Blog",
      keyPrefix: "blog",
      backendSlug: "r2",
      to: database,
      now: now
    )
    let backup = try CatalogBackups.create(from: database, now: now)
    #expect(backup.schema == 1)
    #expect(backup.migrations == ["v1_initial", "v2_favorite_label", "v3_pending_deletion", "v4_project_key_template", "v5_run", "v6_asset_source_sha256"])
    #expect(backup.tables.backends.map(\.slug) == ["r2"])
    #expect(backup.tables.projects.map(\.slug) == ["blog"])
    #expect(backup.tables.assets.isEmpty)
    #expect(backup.tables.backendPrefixHistory.isEmpty)
    #expect(backup.tables.assetProjects.isEmpty)
    #expect(backup.tables.tags.isEmpty)
    #expect(backup.tables.assetTags.isEmpty)
    #expect(backup.tables.scans.isEmpty)
    #expect(backup.tables.usages.isEmpty)
    #expect(backup.tables.assetFavorites.isEmpty)
    #expect(backup.tables.assetLabels.isEmpty)

    let json = String(decoding: try JSONEncoder().encode(backup), as: UTF8.self)
    #expect(json.contains("\"schema\":1"))
    #expect(json.contains("\"backend_prefix_history\":[]"))
    #expect(!json.contains("secretAccessKey"))
  }
}

@Test("S3 inventory paginates listings and reads object metadata")
func s3InventoryRequests() async throws {
  PhaseNineURLProtocol.reset()
  PhaseNineURLProtocol.handler = { request in
    if request.httpMethod == "HEAD" {
      return (
        200,
        [
          "Content-Length": "123",
          "Content-Type": "image/png",
          "Last-Modified": "Wed, 20 Aug 2026 00:00:00 GMT",
          "x-amz-meta-sha256": String(repeating: "a", count: 64),
          "x-amz-meta-orig-filename": "pixel.png",
          "x-amz-meta-width": "1",
          "x-amz-meta-height": "1",
        ],
        Data()
      )
    }
    let continued = request.url?.query?.contains("continuation-token=") == true
    let xml =
      continued
      ? """
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>second + image.png</Key><LastModified>2026-08-20T00:01:00Z</LastModified><Size>20</Size></Contents>
      </ListBucketResult>
      """
      : """
      <ListBucketResult>
        <IsTruncated>true</IsTruncated>
        <NextContinuationToken>next+token</NextContinuationToken>
        <Contents><Key>first.png</Key><LastModified>2026-08-20T00:00:00Z</LastModified><Size>10</Size></Contents>
      </ListBucketResult>
      """
    return (200, ["Content-Type": "application/xml"], Data(xml.utf8))
  }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [PhaseNineURLProtocol.self]
  let backend = Backend(
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
  let inventory = S3ObjectInventory(
    backend: backend,
    credentials: BackendCredentials(accessKeyID: "access", secretAccessKey: "secret"),
    session: URLSession(configuration: configuration)
  )
  let objects = try await inventory.listObjects()
  #expect(objects.map(\.key) == ["first.png", "second + image.png"])
  let head = try await inventory.headObject(key: "second + image.png")
  #expect(head.byteSize == 123)
  #expect(head.mime == "image/png")
  #expect(head.metadata["sha256"] == String(repeating: "a", count: 64))
  let requests = PhaseNineURLProtocol.requests
  #expect(requests.filter { $0.httpMethod == "GET" }.count == 2)
  #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") != nil })
  #expect(
    requests.last?.url?.absoluteString
      == "https://storage.example.com/images/second%20%2B%20image.png")
}

@Test("Reindex reconstructs Pinax assets and reports legacy objects")
func reindexRecovery() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  let now = Date(timeIntervalSince1970: 1_788_192_000)
  let backend = try CatalogConfiguration.addBackend(
    slug: "r2",
    endpoint: "https://storage.example.com",
    bucket: "images",
    region: "auto",
    urlPrefix: "https://img.example.com",
    keychainReference: "backend.r2",
    to: database,
    now: now
  )
  let sha256 = String(repeating: "a", count: 64)
  let inventory = StewardshipInventory(
    objects: [
      S3ObjectSummary(
        key: "blog/pixel.png",
        byteSize: 123,
        lastModified: "2026-08-19T23:00:00.000Z"
      ),
      S3ObjectSummary(key: "blog/head-date.png", byteSize: 124),
      S3ObjectSummary(key: "legacy.png", byteSize: 50),
    ],
    heads: [
      "blog/pixel.png": S3ObjectHead(
        key: "blog/pixel.png",
        byteSize: 123,
        mime: "image/png",
        lastModified: nil,
        metadata: [
          "sha256": sha256,
          "orig-filename": MetadataValueCodec.encode("截屏 pixel.png"),
          "width": "1",
          "height": "2",
        ]
      ),
      "blog/head-date.png": S3ObjectHead(
        key: "blog/head-date.png",
        byteSize: 124,
        mime: "image/png",
        lastModified: "Wed, 19 Aug 2026 22:00:00 GMT",
        metadata: [
          "sha256": String(repeating: "b", count: 64),
          "orig-filename": MetadataValueCodec.encode("head date.png"),
          "width": "3",
          "height": "4",
        ]
      ),
      "legacy.png": S3ObjectHead(
        key: "legacy.png",
        byteSize: 50,
        mime: "image/png",
        lastModified: nil,
        metadata: [:]
      ),
    ]
  )

  let dryRun = try await CatalogReindex.run(
    backend: backend,
    inventory: inventory,
    database: database,
    dryRun: true,
    now: now
  )
  #expect(dryRun.reconstructed == 2)
  #expect(try await database.read { try Asset.fetchCount($0) } == 0)

  let result = try await CatalogReindex.run(
    backend: backend,
    inventory: inventory,
    database: database,
    now: now
  )
  #expect(result.scanned == 3)
  #expect(result.reconstructed == 2)
  #expect(
    result.missingMetadata == [
      ReindexMissingMetadata(
        key: "legacy.png",
        missing: ["sha256", "orig-filename", "width", "height"]
      )
    ])
  let assets = try await database.read { try Asset.order(Column("key")).fetchAll($0) }
  #expect(assets.count == 2)
  #expect(assets[0].key == "blog/head-date.png")
  #expect(assets[0].uploadedAt == "2026-08-19T22:00:00Z")
  #expect(assets[1].sha256 == sha256)
  #expect(assets[1].width == 1)
  #expect(assets[1].height == 2)
  #expect(assets[1].originalFilename == "截屏 pixel.png")
  #expect(assets[1].uploadedAt == "2026-08-19T23:00:00Z")

  let repeated = try await CatalogReindex.run(
    backend: backend,
    inventory: inventory,
    database: database,
    now: now
  )
  #expect(repeated.reconstructed == 0)
  #expect(repeated.existing == 2)
  #expect(try await database.read { try Asset.fetchCount($0) } == 2)
}

private struct StewardshipInventory: ObjectInventory {
  let objects: [S3ObjectSummary]
  let heads: [String: S3ObjectHead]

  func listObjects() async throws -> [S3ObjectSummary] {
    objects
  }

  func headObject(key: String) async throws -> S3ObjectHead {
    try #require(heads[key])
  }
}

private final class PhaseNineURLProtocol: URLProtocol {
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
        throw URLError(.badServerResponse)
      }
      let (status, headers, data) = try handler(request)
      let response = try #require(
        HTTPURLResponse(
          url: requestURL,
          statusCode: status,
          httpVersion: "HTTP/1.1",
          headerFields: headers
        ))
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
