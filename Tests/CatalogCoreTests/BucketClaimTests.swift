import CatalogCore
import Foundation
import GRDB
import Testing

/// Importing bucket objects the catalog lacks
/// and no page uses. A stub inventory stands in for the signed List, the
/// in-memory `ClaimFetcher` for the GETs; every host is `.invalid`.
@Suite struct BucketClaimTests {
  static let prefix = "https://img.pinax.invalid"

  @Test("Candidates exclude keys in the catalog, tombstoned keys, bad keys and referenced keys")
  func filterExcludes() async throws {
    try await withBucketCatalog { database, backend, _ in
      try await seedAsset(database, key: "blog/202601/known.png", bytes: Data("known".utf8))
      try await tombstone(database, key: "2024/doomed.png")
      _ = try CatalogUsage.sync(
        UsageDocument(
          project: "blog",
          refs: [UsageReference(rawURL: "\(Self.prefix)/2024/used.png", sourceReference: "a.md#L1")]),
        project: "blog", in: database)
      let inventory = CountingInventory(keys: [
        "blog/202601/known.png", "2024/doomed.png", "cdn-cgi/image/w=8/x.png", "/lead.png",
        "2024/", "2024/used.png", "2024/09/22-1727038934-a.png", "202409/icon_256x256.png",
      ])
      let found = try await BucketClaim.find(backend: backend, inventory: inventory, in: database)
      #expect(found.candidates.map(\.key) == ["2024/09/22-1727038934-a.png", "202409/icon_256x256.png"])
      #expect(found.alreadyInCatalog == 1)
      #expect(found.pendingDeletion == ["2024/doomed.png"])
      #expect(found.badKeys == ["cdn-cgi/image/w=8/x.png", "/lead.png", "2024/"])
      #expect(found.referenced == ["2024/used.png"])
      #expect(found.objects.count == 8)
      #expect(inventory.lists == 1)
      #expect(inventory.heads == 0)
    }
  }

  @Test("Only the latest scan's unmatched rows make a key referenced; an older scan's leave it a candidate")
  func olderScanDoesNotReference() async throws {
    try await withBucketCatalog { database, backend, _ in
      func doc(_ keys: [String]) -> UsageDocument {
        UsageDocument(
          project: "blog",
          refs: keys.enumerated().map {
            UsageReference(rawURL: "\(Self.prefix)/\($0.element)", sourceReference: "a.md#L\($0.offset + 1)")
          })
      }
      // Scan 1 saw both keys; scan 2 (the project's latest) only `now.png`.
      _ = try CatalogUsage.sync(doc(["2024/gone.png", "2024/now.png"]), project: "blog", in: database)
      _ = try CatalogUsage.sync(doc(["2024/now.png"]), project: "blog", in: database)
      let inventory = CountingInventory(keys: ["2024/gone.png", "2024/now.png"])
      let found = try await BucketClaim.find(backend: backend, inventory: inventory, in: database)
      #expect(found.referenced == ["2024/now.png"])
      #expect(found.candidates.map(\.key) == ["2024/gone.png"])
    }
  }

  @Test("An import attaches no project, writes the bucket provenance, and GETs only candidates")
  func importRows() async throws {
    try await withBucketCatalog { database, backend, fetcher in
      fetcher.lastModified = Date(timeIntervalSince1970: 1_700_000_000)
      try await tombstone(database, key: "2024/doomed.png")
      let inventory = CountingInventory(keys: [
        "2024/doomed.png", "cdn-cgi/x.png", "2024/09/22-1727038934-中 a.png", "202409/b.png",
      ])
      let result = try await BucketClaim.run(
        backend: backend, inventory: inventory, in: database, fetcher: fetcher)
      #expect(result.listed == 4)
      #expect(result.candidates == 2)
      #expect(result.claimed.map(\.key) == ["2024/09/22-1727038934-中 a.png", "202409/b.png"])
      #expect(result.claimed.allSatisfy { $0.projects.isEmpty })
      #expect(result.skippedCounts == ["pending_deletion": 1, "bad_key": 1])
      #expect(!result.hasFailures)
      #expect(try count(database, "asset_project") == 0)
      let assets = try await database.read { db in try Asset.order(Column("key")).fetchAll(db) }
      #expect(assets.map(\.meta) == ["{\"imported_from\":\"bucket\"}", "{\"imported_from\":\"bucket\"}"])
      #expect(assets.first?.originalFilename == "22-1727038934-中 a.png")
      #expect(assets.first?.uploadedAt == "2023-11-14T22:13:20Z")
      #expect(
        fetcher.requested.sorted() == [
          "\(Self.prefix)/2024/09/22-1727038934-%E4%B8%AD%20a.png", "\(Self.prefix)/202409/b.png",
        ])
      #expect(inventory.heads == 0)
    }
  }

  @Test("A re-run sends no GET: what the first run imported is filtered before fetching")
  func rerunSendsNoGet() async throws {
    try await withBucketCatalog { database, backend, fetcher in
      // A Pinax-uploaded asset, so the first run's CDN check GETs it too.
      try await seedAsset(database, key: "blog/202601/s1.png", bytes: Data("s1".utf8))
      fetcher.serve("\(Self.prefix)/blog/202601/s1.png", Data("s1".utf8))
      let inventory = CountingInventory(keys: ["blog/202601/s1.png", "2024/a.png", "2024/b.png"])
      // One Find, imported twice — the settings section's Import after an
      // earlier import — then a fresh List and import, the CLI re-run.
      let found = try await BucketClaim.find(backend: backend, inventory: inventory, in: database)
      let first = try await BucketClaim.run(
        found, backend: backend, in: database, fetcher: fetcher)
      #expect(first.claimed.count == 2)
      #expect(first.cdnCheck.map(\.status) == [.matched])
      fetcher.resetRequests()
      let second = try await BucketClaim.run(
        found, backend: backend, in: database, fetcher: fetcher)
      let third = try await BucketClaim.run(
        backend: backend, inventory: inventory, in: database, fetcher: fetcher)
      #expect(fetcher.requested.isEmpty)
      for rerun in [second, third] {
        #expect(rerun.claimed.isEmpty)
        #expect(rerun.candidates == 0)
        #expect(rerun.alreadyInCatalog == 3)
        #expect(rerun.cdnCheck.isEmpty)
      }
    }
  }

  @Test("--dry-run fetches and counts but leaves rows and changeStamp unchanged")
  func dryRunWritesNothing() async throws {
    try await withBucketCatalog { database, backend, fetcher in
      let inventory = CountingInventory(keys: ["2024/a.png", "2024/b.png", "2024/c.png"])
      let stamp = try await CatalogAssets.changeStamp(in: database)
      let assets = try count(database, "asset")
      let result = try await BucketClaim.run(
        backend: backend, inventory: inventory, in: database, fetcher: fetcher, dryRun: true)
      #expect(result.dryRun)
      #expect(result.claimed.count == 3)
      #expect(try count(database, "asset") == assets)
      #expect(try await CatalogAssets.changeStamp(in: database) == stamp)
    }
  }

  @Test("No CDN sample: unchecked, and the import goes on; a rewritten sample refuses it")
  func cdnCheck() async throws {
    try await withBucketCatalog { database, backend, fetcher in
      let inventory = CountingInventory(keys: ["2024/a.png"])
      let found = try await BucketClaim.find(backend: backend, inventory: inventory, in: database)
      #expect(found.cdnSamples == 0)
      let unchecked = try await BucketClaim.run(
        found, backend: backend, in: database, fetcher: fetcher, dryRun: true)
      #expect(unchecked.cdnCheck.map(\.status) == [.unchecked])
      #expect(unchecked.claimed.count == 1)

      try await seedAsset(database, key: "blog/202601/s1.png", bytes: Data("s1".utf8))
      fetcher.serve("\(Self.prefix)/blog/202601/s1.png", Data("re-encoded".utf8))
      let again = try await BucketClaim.find(backend: backend, inventory: inventory, in: database)
      #expect(again.cdnSamples == 1)
      let refused = try await BucketClaim.run(
        again, backend: backend, in: database, fetcher: fetcher)
      #expect(refused.refused)
      #expect(refused.claimed.isEmpty)
      #expect(refused.hasFailures)
      #expect(try count(database, "asset") == 1)
    }
  }

  @Test("A 404 and a transport error are counted like the Externals import; nothing is cancelled")
  func failureCategories() async throws {
    try await withBucketCatalog { database, backend, fetcher in
      try fetcher.fail("\(Self.prefix)/2024/gone.png", .notFound(URL(string: "https://x.invalid")!))
      try fetcher.fail(
        "\(Self.prefix)/2024/slow.png", .failed(URL(string: "https://x.invalid")!, detail: "timed out"))
      let inventory = CountingInventory(keys: ["2024/gone.png", "2024/slow.png", "2024/ok.png"])
      let result = try await BucketClaim.run(
        backend: backend, inventory: inventory, in: database, fetcher: fetcher)
      #expect(result.skippedCounts == ["not_found": 1, "fetch_failed": 1])
      #expect(!result.cancelled)
      #expect(result.claimed.map(\.key) == ["2024/ok.png"])
      #expect(result.hasFailures)
    }
  }

  // MARK: - Helpers

  private func count(_ database: CatalogDatabasePool, _ table: String) throws -> Int {
    try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
  }

  private func seedAsset(_ database: CatalogDatabasePool, key: String, bytes: Data) async throws {
    try await database.write { db in
      _ = try Asset(
        sha256: Hashing.sha256(of: bytes), backendID: 1, key: key, byteSize: Int64(bytes.count),
        mime: "image/png", uploadedAt: "2026-01-01T00:00:00Z",
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"
      ).insertAndFetch(db)
    }
  }

  private func tombstone(_ database: CatalogDatabasePool, key: String) async throws {
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO pending_deletion
            (backend_id, key, sha256, byte_size, snapshot, requested_at, updated_at)
          VALUES (1, ?, ?, 1, '{}', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
          """, arguments: [key, String(repeating: "d", count: 64)])
    }
  }

  private func withBucketCatalog(
    _ body: (CatalogDatabasePool, Backend, ClaimFetcher) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bucket-claim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    let backend = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://s3.pinax.invalid", bucket: "images", region: "auto",
      urlPrefix: Self.prefix, keychainReference: "", to: database)
    _ = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "blog", backendSlug: "r2", to: database)
    try await body(database, backend, ClaimFetcher())
  }
}

/// A signed List stand-in: returns fixed keys and counts List and HEAD calls.
final class CountingInventory: ObjectInventory, @unchecked Sendable {
  private let lock = NSLock()
  private let keys: [String]
  private var listCount = 0
  private var headCount = 0

  init(keys: [String]) { self.keys = keys }

  var lists: Int { lock.withLock { listCount } }
  var heads: Int { lock.withLock { headCount } }

  func listObjects() async throws -> [S3ObjectSummary] {
    lock.withLock { listCount += 1 }
    return keys.map { S3ObjectSummary(key: $0, byteSize: 1) }
  }

  func headObject(key: String) async throws -> S3ObjectHead {
    lock.withLock { headCount += 1 }
    return S3ObjectHead(key: key, byteSize: 1, mime: nil, lastModified: nil, metadata: [:])
  }
}
