import CatalogCore
import Foundation
import GRDB
import Testing

/// Claiming Externals ▸ Your Domains URLs. Temporary catalogs and an
/// in-memory fetcher only; every host is `.invalid`, so nothing here can
/// reach a real bucket or CDN.
@Suite struct ExternalsClaimTests {
  static let prefix = "https://img.pinax.invalid"
  static let oldPrefix = "https://old.pinax.invalid"

  // MARK: - Relink equals a rescan

  @Test(
    "After a claim, usage.asset_id equals a rescan of the same document, row for row",
    arguments: [0, 1, 2])
  func relinkEqualsRescan(fixture: Int) async throws {
    try await withClaimCatalog { database, fetcher in
      let documents: [UsageDocument]
      switch fixture {
      case 0:
        // The three URL forms: current prefix, `?w=`, retired domain.
        documents = [
          document(
            "blog",
            [
              "\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png?w=800",
              "\(Self.oldPrefix)/2019/c.png",
            ])
        ]
      case 1:
        // Two projects, one URL shared, `?w=` and plain forms of one key.
        documents = [
          document(
            "blog", ["\(Self.prefix)/2020/a.png?w=400", "\(Self.prefix)/2020/a.png", "\(Self.oldPrefix)/2019/c.png"]),
          document("notes", ["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2021/d.png"]),
        ]
      default:
        // Claimable rows among rows that must stay external.
        try fetcher.fail("\(Self.prefix)/2020/gone.png", .notFound(URL(string: "https://x.invalid")!))
        documents = [
          document(
            "blog",
            [
              "\(Self.prefix)/2020/a.png", "\(Self.oldPrefix)/2019/c.png?w=10",
              "\(Self.prefix)/cdn-cgi/image/width=80/2020/a.png", "\(Self.prefix)//2020/a.png",
              "\(Self.prefix)/2020/gone.png", "https://elsewhere.invalid/e.png",
            ])
        ]
      }
      for doc in documents {
        _ = try CatalogUsage.sync(doc, project: doc.project, in: database)
      }
      let result = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      #expect(result.relinkedUsage > 0)
      let relinked = try usageLinks(database)
      for doc in documents {
        _ = try CatalogUsage.sync(doc, project: doc.project, in: database)
      }
      let rescanned = try usageLinks(database)
      #expect(relinked == rescanned)
      // The three forms are all linked.
      for link in relinked
      where link.url.hasSuffix("invalid/2020/a.png") || link.url.contains("b.png?w=")
        || link.url.hasPrefix(Self.oldPrefix)
      {
        #expect(link.assetID != nil, "\(link.url) not linked")
      }
    }
  }

  @Test("A `?w=` reference seen first still fetches the canonical URL")
  func canonicalFetchURL() async throws {
    try await withClaimCatalog { database, fetcher in
      _ = try CatalogUsage.sync(
        document(
          "blog",
          ["\(Self.prefix)/2020/a.png?w=800", "\(Self.prefix)/2020/a.png",
           "\(Self.oldPrefix)/2019/c.png"]),
        project: "blog", in: database)
      let result = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      #expect(result.claimed.map(\.key).sorted() == ["2019/c.png", "2020/a.png"])
      #expect(
        fetcher.requested.sorted() == [
          "\(Self.prefix)/2019/c.png", "\(Self.prefix)/2020/a.png",
        ])
    }
  }

  // MARK: - Skip categories

  @Test("cdn-cgi, //, other backend, same content, 404 and 403 each land in their category")
  func skipCategories() async throws {
    try await withClaimCatalog { database, fetcher in
      _ = try CatalogConfiguration.addBackend(
        slug: "b2", endpoint: "https://s3.pinax.invalid", bucket: "other", region: "auto",
        urlPrefix: "https://other.pinax.invalid", keychainReference: "", to: database)
      let existing = try await seedAsset(database, key: "blog/202601/known.png", bytes: Data("known".utf8))
      // The seeded asset is also the CDN check's sample; its URL answers truly.
      fetcher.serve("\(Self.prefix)/\(existing)", Data("known".utf8))
      fetcher.serve("\(Self.prefix)/2020/same.png", Data("known".utf8))
      try fetcher.fail("\(Self.prefix)/2020/gone.png", .notFound(URL(string: "https://x.invalid")!))
      try fetcher.fail("\(Self.prefix)/2020/locked.png", .forbidden(URL(string: "https://x.invalid")!))
      _ = try CatalogUsage.sync(
        document(
          "blog",
          [
            "\(Self.prefix)/cdn-cgi/image/width=80/2020/a.png", "\(Self.prefix)//2020/a.png",
            "https://other.pinax.invalid/2020/b.png", "\(Self.prefix)/2020/same.png",
            "\(Self.prefix)/2020/gone.png", "\(Self.prefix)/2020/locked.png",
          ]),
        project: "blog", in: database)
      let before = try count(database, "asset")
      let result = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      let reasons = Dictionary(
        result.skipped.map { ($0.url, $0.reason) }, uniquingKeysWith: { a, _ in a })
      #expect(reasons["\(Self.prefix)/cdn-cgi/image/width=80/2020/a.png"] == "bad_key")
      #expect(reasons["\(Self.prefix)//2020/a.png"] == "bad_key")
      #expect(reasons["https://other.pinax.invalid/2020/b.png"] == "other_backend")
      #expect(reasons["\(Self.prefix)/2020/same.png"] == "same_content")
      #expect(reasons["\(Self.prefix)/2020/gone.png"] == "not_found")
      #expect(reasons["\(Self.prefix)/2020/locked.png"] == "forbidden")
      #expect(result.skipped.count == 6)
      #expect(
        result.skipped.first { $0.reason == "same_content" }?.existingKey == existing)
      #expect(result.claimed.isEmpty)
      #expect(try count(database, "asset") == before)
      // Neither a transform path nor a leading-slash key was ever fetched.
      #expect(!fetcher.requested.contains { $0.contains("cdn-cgi") || $0.contains("invalid//") })
      #expect(result.hasFailures)
    }
  }

  @Test("Without a cancel, a transport error is fetch_failed — not cancelled, not remaining")
  func transportErrorIsFetchFailed() async throws {
    try await withClaimCatalog { database, fetcher in
      let broken = "\(Self.prefix)/2020/timeout.png"
      try fetcher.fail(broken, .failed(URL(string: broken)!, detail: "timed out"))
      _ = try CatalogUsage.sync(
        document("blog", [broken, "\(Self.prefix)/2020/fine.png"]), project: "blog",
        in: database)
      let result = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      #expect(!result.cancelled)
      #expect(result.remaining == 0)
      #expect(result.skippedCounts == ["fetch_failed": 1])
      #expect(result.skipped.first?.url == broken)
      #expect(result.skipped.first?.detail == "timed out")
      #expect(result.claimed.map(\.key) == ["2020/fine.png"])
      #expect(result.hasFailures)
    }
  }

  // MARK: - Project attachment

  @Test("A URL two projects use is attached to both; one project's URL to it alone")
  func attachesEveryReferencingProject() async throws {
    try await withClaimCatalog { database, fetcher in
      _ = try CatalogUsage.sync(
        document("blog", ["\(Self.prefix)/2020/shared.png", "\(Self.prefix)/2020/blog-only.png"]),
        project: "blog", in: database)
      _ = try CatalogUsage.sync(
        document("notes", ["\(Self.prefix)/2020/shared.png"]), project: "notes", in: database)
      let result = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      #expect(result.claimed.count == 2)
      let links = try await database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT a.key, p.slug FROM asset_project ap
            JOIN asset a ON a.id = ap.asset_id JOIN project p ON p.id = ap.project_id
            ORDER BY a.key, p.slug
            """
        ).map { "\($0["key"] as String) \($0["slug"] as String)" }
      }
      #expect(links == ["2020/blog-only.png blog", "2020/shared.png blog", "2020/shared.png notes"])
    }
  }

  // MARK: - Cancel and resume

  @Test("Cancelling after k keys keeps those k; the re-run sends them no GET")
  func cancelKeepsCommittedAndResumes() async throws {
    try await withClaimCatalog { database, fetcher in
      let urls = (1...6).map { "\(Self.prefix)/2020/p\($0).png" }
      _ = try CatalogUsage.sync(document("blog", urls), project: "blog", in: database)
      let cancellation = ExternalsClaimCancellation()
      let k = 2
      fetcher.onFetch = { count in if count == k { cancellation.cancel() } }
      let first = try await ExternalsClaim.run(
        in: database, fetcher: fetcher, maxConcurrentFetches: 1, cancellation: cancellation)
      #expect(first.cancelled)
      // Which k keys got the gate first is the scheduler's choice, so assert the set.
      let claimedKeys = Set(first.claimed.map(\.key))
      #expect(claimedKeys.count == k)
      #expect(claimedKeys.isSubset(of: Set((1...6).map { "2020/p\($0).png" })))
      #expect(first.remaining == 6 - k)
      #expect(try count(database, "asset") == k)
      #expect(fetcher.requested.count == k)
      let claimedURLs = Set(claimedKeys.map { "\(Self.prefix)/\($0)" })

      // The first run relinked p1, p2, so they left Externals. Undo that link,
      // as if the run had stopped between its commit and its relink: the
      // re-run must still filter them before any GET, then link them.
      try await database.write { db in
        try db.execute(sql: "UPDATE usage SET asset_id = NULL")
      }
      fetcher.onFetch = nil
      fetcher.resetRequests()
      let second = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      #expect(second.alreadyInCatalog == k)
      #expect(second.relinkedUsage == 6)
      #expect(second.claimed.count == 6 - k)
      #expect(fetcher.requested.filter { claimedURLs.contains($0) }.isEmpty)
      #expect(try count(database, "asset") == 6)
    }
  }

  // MARK: - CDN byte check

  @Test("A CDN serving different bytes for one known image refuses the whole batch")
  func cdnRewriteRefusesBatch() async throws {
    try await withClaimCatalog { database, fetcher in
      let sampleKeys = ["blog/202601/s1.png", "blog/202601/s2.png", "blog/202601/s3.png"]
      for key in sampleKeys {
        _ = try await seedAsset(database, key: key, bytes: Data("original \(key)".utf8))
        fetcher.serve("\(Self.prefix)/\(key)", Data("original \(key)".utf8))
      }
      fetcher.serve("\(Self.prefix)/blog/202601/s2.png", Data("re-encoded".utf8))
      _ = try CatalogUsage.sync(
        document("blog", ["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png"]),
        project: "blog", in: database)
      let assetsBefore = try count(database, "asset")
      let linksBefore = try count(database, "asset_project")
      let result = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      #expect(result.refused)
      #expect(result.cdnCheck.map(\.status) == [.rewritesBytes])
      #expect(result.cdnCheck.first?.mismatched == ["blog/202601/s2.png"])
      #expect(result.claimed.isEmpty)
      #expect(try count(database, "asset") == assetsBefore)
      #expect(try count(database, "asset_project") == linksBefore)
      #expect(!fetcher.requested.contains { $0.hasPrefix("\(Self.prefix)/2020/") })
      #expect(result.hasFailures)
    }
  }

  @Test("Matching samples pass; no Pinax-uploaded sample means unchecked, and the claim goes on")
  func cdnCheckMatchedAndUnchecked() async throws {
    try await withClaimCatalog { database, fetcher in
      _ = try CatalogUsage.sync(
        document("blog", ["\(Self.prefix)/2020/a.png"]), project: "blog", in: database)
      let unchecked = try await ExternalsClaim.run(
        in: database, fetcher: fetcher, dryRun: true)
      #expect(unchecked.cdnCheck.map(\.status) == [.unchecked])
      #expect(unchecked.claimed.count == 1)

      _ = try await seedAsset(database, key: "blog/202601/s1.png", bytes: Data("s1".utf8))
      fetcher.serve("\(Self.prefix)/blog/202601/s1.png", Data("s1".utf8))
      // A claimed asset is not a sample: its bytes came from the CDN.
      _ = try await seedAsset(
        database, key: "2019/claimed.png", bytes: Data("c".utf8),
        meta: "{\"imported_from\":\"externals\"}")
      fetcher.serve("\(Self.prefix)/2019/claimed.png", Data("different".utf8))
      let matched = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      #expect(matched.cdnCheck.map(\.status) == [.matched])
      #expect(matched.cdnCheck.first?.sampled == 1)
      #expect(matched.claimed.count == 1)
    }
  }

  // MARK: - Dry run

  @Test("--dry-run leaves row counts and changeStamp unchanged")
  func dryRunWritesNothing() async throws {
    try await withClaimCatalog { database, fetcher in
      _ = try CatalogUsage.sync(
        document("blog", ["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png?w=9"]),
        project: "blog", in: database)
      let stamp = try await CatalogAssets.changeStamp(in: database)
      let counts = try snapshotCounts(database)
      let result = try await ExternalsClaim.run(in: database, fetcher: fetcher, dryRun: true)
      #expect(result.dryRun)
      #expect(result.claimed.count == 2)
      #expect(result.relinkedUsage == 2)
      #expect(try snapshotCounts(database) == counts)
      #expect(try await CatalogAssets.changeStamp(in: database) == stamp)
    }
  }

  // MARK: - Row contents

  @Test("The row records Last-Modified, the externals provenance and the key's last segment")
  func rowContents() async throws {
    try await withClaimCatalog { database, fetcher in
      fetcher.lastModified = Date(timeIntervalSince1970: 1_700_000_000)
      _ = try CatalogUsage.sync(
        document("blog", ["\(Self.prefix)/2020/%E4%B8%AD%20a.png"]), project: "blog",
        in: database)
      _ = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      let asset = try #require(
        try await database.read { db in try Asset.fetchOne(db) })
      #expect(asset.key == "2020/中 a.png")
      #expect(asset.uploadedAt == "2023-11-14T22:13:20Z")
      #expect(
        asset.meta
          == #"{"imported_from":"externals","source_url":"https://img.pinax.invalid/2020/%E4%B8%AD%20a.png"}"#)
      #expect(asset.originalFilename == "中 a.png")
      #expect(asset.mime == "image/png")
      #expect(asset.sha256 == Hashing.sha256(of: fetcher.body(for: "2020/中 a.png")))
      #expect(fetcher.requested == ["\(Self.prefix)/2020/%E4%B8%AD%20a.png"])
    }
  }

  // MARK: - source_url

  @Test("A claim records the referenced URL without query or fragment, next to imported_from")
  func claimRecordsSourceURL() async throws {
    try await withClaimCatalog { database, fetcher in
      _ = try CatalogUsage.sync(
        document(
          "blog",
          [
            // One key, three forms: the plain current-prefix URL wins.
            "\(Self.oldPrefix)/2020/a.png#top", "\(Self.prefix)/2020/a.png?w=400",
            "\(Self.prefix)/2020/a.png",
            // Only a retired-domain form, with a query: that URL, cut.
            "\(Self.oldPrefix)/2019/c.png?w=10#x",
            // Only a `?w=` form on the current prefix.
            "\(Self.prefix)/2021/%E4%B8%AD.png?w=9",
          ]),
        project: "blog", in: database)
      let result = try await ExternalsClaim.run(in: database, fetcher: fetcher)
      #expect(result.claimed.count == 3)
      let metas = try await database.read { db in
        Dictionary(
          uniqueKeysWithValues: try Asset.fetchAll(db).map { ($0.key, $0.meta) })
      }
      #expect(
        metas["2020/a.png"]
          == #"{"imported_from":"externals","source_url":"https://img.pinax.invalid/2020/a.png"}"#)
      #expect(
        metas["2019/c.png"]
          == #"{"imported_from":"externals","source_url":"https://old.pinax.invalid/2019/c.png"}"#)
      #expect(
        metas["2021/中.png"]
          == #"{"imported_from":"externals","source_url":"https://img.pinax.invalid/2021/%E4%B8%AD.png"}"#)
      // The migration reserve: whatever writes source_url writes imported_from.
      for (key, meta) in metas {
        let object = try #require(
          try JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any], "\(key)")
        #expect(object["imported_from"] as? String == "externals", "\(key)")
        #expect((object["source_url"] as? String)?.isEmpty == false, "\(key)")
        #expect(AssetSource.of(meta: meta) == .bucket, "\(key)")
      }
    }
  }

  // MARK: - changeStamp

  @Test("A relink alone moves changeStamp")
  func relinkMovesChangeStamp() async throws {
    try await withClaimCatalog { database, _ in
      _ = try CatalogUsage.sync(
        document("blog", ["\(Self.prefix)/2020/a.png"]), project: "blog", in: database)
      _ = try await seedAsset(database, key: "2020/a.png", bytes: Data("a".utf8))
      let stamp = try await CatalogAssets.changeStamp(in: database)
      let linked = try await CatalogUsage.relinkUnmatched(in: database)
      #expect(linked == 1)
      #expect(try await CatalogAssets.changeStamp(in: database) != stamp)
      #expect(try usageLinks(database).allSatisfy { $0.assetID != nil })
    }
  }

  // MARK: - 429 / 503

  @Test("The URLSession fetcher waits and retries once on 429 and 503, and reads Last-Modified")
  func throttleRetriesOnce() async throws {
    let fetcher = URLSessionPublicObjectFetcher(
      session: StubProtocol.session, requestTimeout: 5, throttleBackoff: 0)
    StubProtocol.script(
      "https://cdn.pinax.invalid/t1.png",
      [(429, Data()), (200, Data("ok".utf8))])
    let object = try await fetcher.fetchObject(URL(string: "https://cdn.pinax.invalid/t1.png")!)
    #expect(object.data == Data("ok".utf8))
    #expect(object.lastModified == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(StubProtocol.hits("https://cdn.pinax.invalid/t1.png") == 2)

    StubProtocol.script(
      "https://cdn.pinax.invalid/t2.png", [(503, Data()), (503, Data()), (200, Data())])
    await #expect(throws: PublicObjectFetchError.failed(
      URL(string: "https://cdn.pinax.invalid/t2.png")!, detail: "HTTP 503")) {
      _ = try await fetcher.fetchObject(URL(string: "https://cdn.pinax.invalid/t2.png")!)
    }
    #expect(StubProtocol.hits("https://cdn.pinax.invalid/t2.png") == 2)

    StubProtocol.script("https://cdn.pinax.invalid/t3.png", [(500, Data()), (200, Data())])
    await #expect(throws: PublicObjectFetchError.self) {
      _ = try await fetcher.fetchObject(URL(string: "https://cdn.pinax.invalid/t3.png")!)
    }
    #expect(StubProtocol.hits("https://cdn.pinax.invalid/t3.png") == 1)
  }

  // MARK: - Fixtures

  struct Link: Equatable {
    let row: String
    let url: String
    let assetID: Int64?
  }

  private func document(_ project: String, _ urls: [String]) -> UsageDocument {
    UsageDocument(
      project: project,
      refs: urls.enumerated().map {
        UsageReference(rawURL: $0.element, sourceReference: "src/\(project).md#L\($0.offset + 1)")
      })
  }

  /// (raw URL, asset id) for every row of each project's latest scan, in a
  /// stable order — the property's two sides.
  private func usageLinks(_ database: CatalogDatabasePool) throws -> [Link] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT p.slug, u.source_ref, u.raw_url, u.kind, u.asset_id FROM usage u
          JOIN project p ON p.id = u.project_id AND u.last_scan_id = p.last_scan_id
          ORDER BY p.slug, u.source_ref, u.raw_url, u.kind
          """
      ).map {
        Link(
          row: "\($0["slug"] as String) \($0["source_ref"] as String) \($0["raw_url"] as String)",
          url: $0["raw_url"], assetID: $0["asset_id"])
      }
    }
  }

  private func count(_ database: CatalogDatabasePool, _ table: String) throws -> Int {
    try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
  }

  private func snapshotCounts(_ database: CatalogDatabasePool) throws -> [Int] {
    try database.read { db in
      try [
        "SELECT COUNT(*) FROM asset", "SELECT COUNT(*) FROM asset_project",
        "SELECT COUNT(*) FROM usage", "SELECT COUNT(asset_id) FROM usage",
        "SELECT COUNT(*) FROM scan",
      ].map { try Int.fetchOne(db, sql: $0) ?? 0 }
    }
  }

  @discardableResult
  private func seedAsset(
    _ database: CatalogDatabasePool, key: String, bytes: Data, meta: String = "{}"
  ) async throws -> String {
    try await database.write { db in
      _ = try Asset(
        sha256: Hashing.sha256(of: bytes), backendID: 1, key: key, byteSize: Int64(bytes.count),
        mime: "image/png", meta: meta, uploadedAt: "2026-01-01T00:00:00Z",
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"
      ).insertAndFetch(db)
    }
    return key
  }

  private func withClaimCatalog(
    _ body: (CatalogDatabasePool, ClaimFetcher) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://s3.pinax.invalid", bucket: "images", region: "auto",
      urlPrefix: Self.prefix, keychainReference: "", to: database)
    try CatalogConfiguration.addOldDomain(Self.oldPrefix, backendSlug: "r2", in: database)
    _ = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "blog", backendSlug: "r2", to: database)
    _ = try CatalogConfiguration.addProject(
      slug: "notes", name: "Notes", keyPrefix: "notes", backendSlug: "r2", to: database)
    try await body(database, ClaimFetcher())
  }
}

// MARK: - Doubles

/// Serves a distinct PNG per path unless told otherwise, records every
/// requested URL, and can fail or hook a request. No network.
final class ClaimFetcher: PublicObjectFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var bodies: [String: Data] = [:]
  private var failures: [String: PublicObjectFetchError] = [:]
  private var requests: [String] = []
  var onFetch: (@Sendable (Int) -> Void)?
  var lastModified: Date?

  var requested: [String] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  func resetRequests() {
    lock.lock()
    requests = []
    lock.unlock()
  }

  func serve(_ url: String, _ data: Data) {
    lock.lock()
    bodies[url] = data
    lock.unlock()
  }

  func fail(_ url: String, _ error: PublicObjectFetchError) throws {
    lock.lock()
    failures[url] = error
    lock.unlock()
  }

  private func record(_ url: URL) -> (
    Int, PublicObjectFetchError?, Data?, (@Sendable (Int) -> Void)?, Date?
  ) {
    lock.lock()
    defer { lock.unlock() }
    requests.append(url.absoluteString)
    return (
      requests.count, failures[url.absoluteString], bodies[url.absoluteString], onFetch,
      lastModified
    )
  }

  /// The bytes served for a key under the test prefix.
  func body(for key: String) -> Data {
    ScriptedFetcher.pngPayload(width: 4, height: 3, seed: key)
  }

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    let object = try await fetchObject(url)
    return (object.data, object.mime, object.contentLength)
  }

  func fetchObject(_ url: URL) async throws -> PublicObject {
    let (count, failure, body, hook, modified) = record(url)
    hook?(count)
    if let failure { throw failure }
    let data =
      body
      ?? ScriptedFetcher.pngPayload(
        width: 4, height: 3,
        seed: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    return PublicObject(
      data: data, mime: "image/png", contentLength: Int64(data.count), lastModified: modified)
  }
}

/// A URLProtocol answering scripted statuses per URL, so the real
/// URLSession fetcher runs without a network.
final class StubProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var scripts: [String: [(Int, Data)]] = [:]
  nonisolated(unsafe) private static var counts: [String: Int] = [:]

  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }()

  static func script(_ url: String, _ responses: [(Int, Data)]) {
    lock.lock()
    scripts[url] = responses
    counts[url] = 0
    lock.unlock()
  }

  static func hits(_ url: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[url] ?? 0
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!.absoluteString
    Self.lock.lock()
    let index = Self.counts[url] ?? 0
    Self.counts[url] = index + 1
    let script = Self.scripts[url] ?? []
    Self.lock.unlock()
    let (status, data) = index < script.count ? script[index] : (404, Data())
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Type": "image/png", "Content-Length": String(data.count),
        "Last-Modified": "Tue, 14 Nov 2023 22:13:20 GMT",
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
