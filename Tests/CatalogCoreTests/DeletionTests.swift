import Foundation
import GRDB
import Testing

@testable import CatalogCore

/// Permanent deletion. Every remote call goes to `FakeBucket`, a
/// URLProtocol on a `.invalid` host; nothing reaches an object store. A
/// DELETE outside the test's allow-list, or any method but HEAD and DELETE,
/// is answered 418 and recorded in `forbidden`; every test ends asserting
/// `forbidden` is empty and the whole request sequence.
@Suite(.serialized) struct DeletionTests {
  static let a = "blog/202610/a-111111111111.png"
  static let b = "blog/202610/b-222222222222.png"

  /// The asset row's columns, as values that can leave an async read (`Row` cannot).
  @Sendable private static func assetColumns(_ db: GRDB.Database) throws -> [String: DatabaseValue]? {
    try Row.fetchOne(db, sql: "SELECT * FROM asset").map {
      Dictionary(uniqueKeysWithValues: $0.map { ($0, $1) })
    }
  }

  // MARK: The normal path

  @Test("Delete: HEAD, DELETE, HEAD for exactly the staged key; the tombstone goes; the rest stays")
  func happyPath() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    try f.seed("blog/202610/keep-444444444444.png", sha: f.sha("k"), state: "archived")
    FakeBucket.reset(allow: [Self.a], objects: [Self.a: f.sha("a")])
    let staged = try CatalogDeletion.stage([Self.a], in: f.db)
    #expect(staged.map(\.key) == [Self.a])
    #expect(try f.count("asset") == 1)
    #expect(try CatalogDeletion.pending(in: f.db).map(\.phase) == [.staged])
    #expect(FakeBucket.trace.isEmpty)  // staging is catalog-only
    let results = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    #expect(results.map(\.outcome) == [.deleted(versioned: false)])
    #expect(FakeBucket.trace == ["HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)", "HEAD /bucket/\(Self.a)"])
    #expect(FakeBucket.forbidden.isEmpty)
    #expect(try f.count("pending_deletion") == 0)
    #expect(try f.count("asset") == 1)
  }

  @Test("A versioned bucket's delete marker is reported, not hidden")
  func versionedBucket() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    FakeBucket.reset(allow: [Self.a], objects: [Self.a: f.sha("a")])
    FakeBucket.deleteHeaders = ["x-amz-delete-marker": "true", "x-amz-version-id": "v1"]
    try CatalogDeletion.stage([Self.a], in: f.db)
    let results = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    #expect(results.map(\.outcome) == [.deleted(versioned: true)])
    #expect(FakeBucket.trace == ["HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)", "HEAD /bucket/\(Self.a)"])
    #expect(FakeBucket.forbidden.isEmpty)
  }

  // MARK: The floors

  @Test("Floor: an active asset is refused; nothing is written or sent")
  func notArchived() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "active")
    try f.seed(Self.b, sha: f.sha("b"), state: "archived")
    FakeBucket.reset(allow: [], objects: [:])
    #expect(throws: CatalogDeletionError.notArchived([Self.a])) {
      try CatalogDeletion.stage([Self.b, Self.a], in: f.db)
    }
    #expect(try f.count("asset") == 2)
    #expect(try f.count("pending_deletion") == 0)
    #expect(try await CatalogDeletion.resume(in: f.db, remote: f.remote).isEmpty)
    #expect(FakeBucket.trace.isEmpty)
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("Floor: an unknown identifier refuses the whole batch")
  func unknownIdentifierRefusesBatch() throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    #expect(throws: AssetCatalogError.assetNotFound("abcdef")) {
      try CatalogDeletion.stage([Self.a, "abcdef"], in: f.db)
    }
    #expect(try f.count("asset") == 1)
    #expect(try f.count("pending_deletion") == 0)
  }

  @Test("Floor: empty, prefix, slash-ended, wildcard and dot keys are refused with zero requests")
  func keyGuard() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    let bad = ["", "  ", "/", "blog/", "blog/202610/", "blog/*", "*", "a//b.png", "../x.png", "a/./b.png", "/a.png"]
    FakeBucket.reset(allow: [], objects: [:])
    // Below every caller: the deleter itself never builds the request.
    let deleter = f.deleter
    for key in bad {
      await #expect(throws: ObjectDeleteError.self) { _ = try await deleter.delete(key: key) }
      await #expect(throws: ObjectDeleteError.self) { _ = try await deleter.head(key: key) }
    }
    // And in the catalog: a row with such a key is refused at staging.
    for (index, key) in bad.enumerated() {
      try f.seed(key, sha: f.sha("bad\(index)"), state: "archived")
      #expect(throws: CatalogDeletionError.self) {
        try CatalogDeletion.stage([f.sha("bad\(index)")], in: f.db)
      }
    }
    #expect(try f.count("pending_deletion") == 0)
    #expect(try f.count("asset") == bad.count)
    #expect(FakeBucket.trace.isEmpty)
    #expect(FakeBucket.forbidden.isEmpty)
    // A good key is exactly one object under the bucket.
    let url = try deleter.objectURL(key: "blog/202610/a b-111111111111.png")
    #expect(url.absoluteString == "https://s3.t23.invalid/bucket/blog/202610/a%20b-111111111111.png")
  }

  @Test("Floor: an object whose x-amz-meta-sha256 is not ours (PicGo import: no header) is never deleted")
  func shaMismatch() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    let picgo = "picgo/old.png"
    let other = "blog/202610/c-333333333333.png"
    try f.seed(picgo, sha: f.sha("p"), state: "archived", meta: #"{"imported_from":"picgo"}"#)
    try f.seed(other, sha: f.sha("c"), state: "archived")
    FakeBucket.reset(allow: [], objects: [picgo: nil, other: f.sha("someone else")])
    try CatalogDeletion.stage([picgo, other], in: f.db)
    let results = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    #expect(
      results.map(\.outcome) == [.refusedMismatch(found: nil), .refusedMismatch(found: f.sha("someone else"))])
    #expect(FakeBucket.trace == ["HEAD /bucket/\(picgo)", "HEAD /bucket/\(other)"])
    #expect(FakeBucket.forbidden.isEmpty)
    let pending = try CatalogDeletion.pending(in: f.db)
    #expect(pending.map(\.phase) == [.refused, .refused])
    #expect(pending[0].lastError?.contains("missing") == true)
  }

  @Test("Floor: a key another backend on the same bucket names is refused; nothing written or sent")
  func sharedKeyAcrossBackends() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    // Same endpoint (case and trailing slash aside) and bucket, another slug.
    let twin = try f.addBackend(slug: "twin", endpoint: "HTTPS://s3.t23.invalid/")
    try f.seed(Self.a, sha: f.sha("a2"), state: "archived", backendID: twin)
    FakeBucket.reset(allow: [], objects: [Self.a: f.sha("a")])
    #expect(throws: CatalogDeletionError.sharedKey(Self.a, backends: ["t23", "twin"])) {
      try CatalogDeletion.stage([f.sha("a")], in: f.db)
    }
    // By key alone it is ambiguous.
    #expect(throws: AssetCatalogError.self) { try CatalogDeletion.stage([Self.a], in: f.db) }
    #expect(try f.count("asset") == 2)
    #expect(try f.count("pending_deletion") == 0)
    #expect(FakeBucket.trace.isEmpty)
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("Floor: more than 100 per confirmation is refused before anything")
  func limit() throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    let many = [Self.a] + (1...100).map { "missing-\($0).png" }
    #expect(throws: CatalogDeletionError.tooMany(101, limit: 100)) {
      try CatalogDeletion.stage(many, in: f.db)
    }
    #expect(try f.count("asset") == 1)
    #expect(try f.count("pending_deletion") == 0)
  }

  @Test("Live usage is returned; by default it refuses, includeUsed lets it through")
  func liveUsage() throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seedUsed(Self.a, sha: f.sha("a"))
    try f.seed(Self.b, sha: f.sha("b"), state: "archived")
    #expect(throws: CatalogDeletionError.stillUsed([Self.a: 1])) {
      try CatalogDeletion.stage([Self.b, Self.a], in: f.db)
    }
    #expect(try f.count("asset") == 2)
    #expect(try f.count("pending_deletion") == 0)
    let plan = try CatalogDeletion.plan([Self.b, Self.a], in: f.db, includeUsed: true)
    #expect(plan.map(\.liveUsage) == [0, 1])
    #expect(try f.count("asset") == 2)  // plan writes nothing
    let staged = try CatalogDeletion.stage([Self.b, Self.a], in: f.db, includeUsed: true)
    #expect(staged.map(\.liveUsage) == [0, 1])
    #expect(staged[1].projects == ["blog"])
    #expect(try f.count("asset") == 0)
    #expect(try f.count("pending_deletion") == 2)
  }

  @Test("The row's delete cascades; usage keeps its rows with asset_id NULL and shows in Externals as yours")
  func cascade() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seedUsed(Self.a, sha: f.sha("a"))
    try CatalogDeletion.stage([Self.a], in: f.db, includeUsed: true)
    let counts = try ["asset_project", "asset_tag", "asset_label", "tag", "usage"].map(f.count)
    #expect(counts == [0, 0, 0, 0, 1])  // the tag no one carries goes too
    #expect(try f.count("usage", "WHERE asset_id IS NULL") == 1)
    let externals = try await CatalogUsage.externalReferences(in: f.db)
    #expect(externals.references.map(\.domain) == [.yours])
  }

  // MARK: Failures converge

  @Test("403 keeps the tombstone with a readable permission error; resume finishes")
  func forbiddenThenResume() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    FakeBucket.reset(allow: [Self.a], objects: [Self.a: f.sha("a")])
    FakeBucket.deleteStatus = 403
    try CatalogDeletion.stage([Self.a], in: f.db)
    let first = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    guard case let .failed(message) = first.first?.outcome else {
      Issue.record("expected a failure, got \(first)")
      return
    }
    #expect(message.contains("no permission to delete"))
    #expect(message.contains("Object Read & Write"))
    let pending = try CatalogDeletion.pending(in: f.db)
    #expect(pending.map(\.attempts) == [1])
    #expect(pending.map(\.phase) == [.deleteSent])
    #expect(pending.first?.lastError == message)
    FakeBucket.deleteStatus = 204
    let second = try await CatalogDeletion.resume(in: f.db, remote: f.remote)
    #expect(second.map(\.outcome) == [.deleted(versioned: false)])
    #expect(try f.count("pending_deletion") == 0)
    #expect(
      FakeBucket.trace == [
        "HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)",
        "HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)", "HEAD /bucket/\(Self.a)",
      ])
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("5xx keeps the tombstone; each key stands alone; resume finishes")
  func serverErrorPartial() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    try f.seed(Self.b, sha: f.sha("b"), state: "archived")
    FakeBucket.reset(allow: [Self.a, Self.b], objects: [Self.a: f.sha("a"), Self.b: f.sha("b")])
    FakeBucket.deleteStatusByKey = [Self.a: 503]
    try CatalogDeletion.stage([Self.a, Self.b], in: f.db)
    let first = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    #expect(first.map(\.key) == [Self.a, Self.b])
    #expect(first[1].outcome == .deleted(versioned: false))
    guard case let .failed(message) = first[0].outcome else {
      Issue.record("expected a failure, got \(first)")
      return
    }
    #expect(message.contains("503"))
    #expect(try CatalogDeletion.pending(in: f.db).map(\.key) == [Self.a])
    FakeBucket.deleteStatusByKey = [:]
    #expect(try await CatalogDeletion.resume(in: f.db, remote: f.remote).map(\.outcome) == [.deleted(versioned: false)])
    #expect(try f.count("pending_deletion") == 0)
    #expect(
      FakeBucket.trace == [
        "HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)",
        "HEAD /bucket/\(Self.b)", "DELETE /bucket/\(Self.b)", "HEAD /bucket/\(Self.b)",
        "HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)", "HEAD /bucket/\(Self.a)",
      ])
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("No network: nothing sent, the tombstone stays staged; resume finishes")
  func offline() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    FakeBucket.reset(allow: [Self.a], objects: [Self.a: f.sha("a")])
    FakeBucket.offlineFrom = 0
    try CatalogDeletion.stage([Self.a], in: f.db)
    let first = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    guard case .failed = first.first?.outcome else {
      Issue.record("expected a failure, got \(first)")
      return
    }
    #expect(try CatalogDeletion.pending(in: f.db).map(\.phase) == [.staged])
    FakeBucket.offlineFrom = nil
    #expect(try await CatalogDeletion.resume(in: f.db, remote: f.remote).map(\.outcome) == [.deleted(versioned: false)])
    #expect(
      FakeBucket.trace == [
        "HEAD /bucket/\(Self.a)",  // the one that never left
        "HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)", "HEAD /bucket/\(Self.a)",
      ])
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("Cut off after the DELETE (before the confirming HEAD): resume HEADs 404 and sends no second DELETE")
  func interruptedAfterDelete() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    FakeBucket.reset(allow: [Self.a], objects: [Self.a: f.sha("a")])
    FakeBucket.offlineFrom = 2  // HEAD, DELETE go through; the confirming HEAD does not
    try CatalogDeletion.stage([Self.a], in: f.db)
    let first = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    guard case .failed = first.first?.outcome else {
      Issue.record("expected a failure, got \(first)")
      return
    }
    #expect(try CatalogDeletion.pending(in: f.db).map(\.phase) == [.deleteSent])
    FakeBucket.offlineFrom = nil
    #expect(try await CatalogDeletion.resume(in: f.db, remote: f.remote).map(\.outcome) == [.alreadyGone])
    #expect(
      FakeBucket.trace == [
        "HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)", "HEAD /bucket/\(Self.a)",
        "HEAD /bucket/\(Self.a)",
      ])
    #expect(try f.count("pending_deletion") == 0)
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("Already deleted in the console (HEAD 404): converges without a DELETE")
  func deletedByHand() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    FakeBucket.reset(allow: [], objects: [:])
    try CatalogDeletion.stage([Self.a], in: f.db)
    #expect(try await CatalogDeletion.purge(in: f.db, remote: f.remote).map(\.outcome) == [.alreadyGone])
    #expect(FakeBucket.trace == ["HEAD /bucket/\(Self.a)"])
    #expect(try f.count("pending_deletion") == 0)
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("Re-uploaded while the delete was owed: the new row owns the key; nothing is sent")
  func supersededByReupload() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    FakeBucket.reset(allow: [], objects: [Self.a: f.sha("a")])
    try CatalogDeletion.stage([Self.a], in: f.db)
    try f.seed(Self.a, sha: f.sha("a"), state: "active")  // same bytes, same month, same key
    #expect(try await CatalogDeletion.resume(in: f.db, remote: f.remote).map(\.outcome) == [.superseded])
    #expect(FakeBucket.trace.isEmpty)
    #expect(try f.count("pending_deletion") == 0)
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("Missing credentials for the backend: the tombstone stays with the error; nothing sent")
  func noCredentials() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    FakeBucket.reset(allow: [], objects: [Self.a: f.sha("a")])
    try CatalogDeletion.stage([Self.a], in: f.db)
    struct NoKey: Error {}
    let results = try await CatalogDeletion.resume(in: f.db, remote: { _ in throw NoKey() })
    guard case .failed = results.first?.outcome else {
      Issue.record("expected a failure, got \(results)")
      return
    }
    #expect(try CatalogDeletion.pending(in: f.db).map(\.attempts) == [1])
    #expect(FakeBucket.trace.isEmpty)
    #expect(FakeBucket.forbidden.isEmpty)
  }

  // MARK: Keep remote, restore

  @Test("Remove from the catalog only: zero requests ever; the tombstone stays; resume skips it")
  func keepRemote() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    let picgo = "picgo/old.png"
    try f.seed(picgo, sha: f.sha("p"), state: "archived", meta: #"{"imported_from":"picgo"}"#)
    FakeBucket.reset(allow: [], objects: [picgo: nil])
    try CatalogDeletion.removeFromCatalogOnly([picgo], in: f.db)
    #expect(try f.count("asset") == 0)
    let pending = try CatalogDeletion.pending(in: f.db)
    #expect(pending.map(\.keepRemote) == [true])
    #expect(pending.map(\.phase) == [.kept])
    #expect(try await CatalogDeletion.resume(in: f.db, remote: f.remote).isEmpty)
    #expect(try await CatalogDeletion.purge(pending.map(\.id), in: f.db, remote: f.remote).isEmpty)
    #expect(FakeBucket.trace.isEmpty)
    #expect(FakeBucket.forbidden.isEmpty)
    #expect(try f.count("pending_deletion") == 1)
  }

  @Test("Restore puts the row back with its projects, tags, labels and usage — only while the object is there")
  func restore() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seedUsed(Self.a, sha: f.sha("a"))
    try await f.db.write { try $0.execute(sql: "UPDATE asset SET favorite = 1, note = 'n'") }
    let before = try await f.db.read(Self.assetColumns)
    FakeBucket.reset(allow: [], objects: [Self.a: f.sha("a")])
    try CatalogDeletion.stage([Self.a], in: f.db, includeUsed: true)
    let id = try CatalogDeletion.pending(in: f.db)[0].id
    try await CatalogDeletion.restore(id, in: f.db)
    let after = try await f.db.read(Self.assetColumns)
    #expect(after == before)
    let counts = try ["asset_project", "asset_tag", "asset_label", "tag", "pending_deletion"].map(f.count)
    #expect(counts == [1, 1, 1, 1, 0])
    #expect(try f.count("usage", "WHERE asset_id IS NULL") == 0)
    #expect(FakeBucket.trace.isEmpty)  // no delete was ever sent: no check needed

    // Once a delete was sent, restore needs a HEAD that finds our bytes.
    FakeBucket.reset(allow: [Self.a], objects: [Self.a: f.sha("a")])
    FakeBucket.offlineFrom = 2
    try CatalogDeletion.stage([Self.a], in: f.db, includeUsed: true)
    _ = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    FakeBucket.offlineFrom = nil
    let sent = try CatalogDeletion.pending(in: f.db)[0]
    #expect(sent.phase == .deleteSent)
    await #expect(throws: CatalogDeletionError.restoreNeedsRemoteCheck(Self.a)) {
      try await CatalogDeletion.restore(sent.id, in: f.db)
    }
    await #expect(throws: CatalogDeletionError.objectGone(Self.a)) {
      try await CatalogDeletion.restore(sent.id, in: f.db, remote: f.remote)
    }
    #expect(try f.count("asset") == 0)
    #expect(
      FakeBucket.trace == [
        "HEAD /bucket/\(Self.a)", "DELETE /bucket/\(Self.a)", "HEAD /bucket/\(Self.a)",
        "HEAD /bucket/\(Self.a)",
      ])
    #expect(FakeBucket.forbidden.isEmpty)
  }

  // MARK: reindex, doctor

  @Test("reindex skips keys with a tombstone instead of resurrecting them")
  func reindexSkipsTombstones() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    try f.seed(Self.b, sha: f.sha("b"), state: "archived")
    try CatalogDeletion.stage([Self.a], in: f.db)
    try CatalogDeletion.removeFromCatalogOnly([Self.b], in: f.db)
    let inventory = ReindexInventory(objects: [Self.a: f.sha("a"), Self.b: f.sha("b")])
    let result = try await CatalogReindex.run(backend: f.backend, inventory: inventory, database: f.db)
    #expect(result.reconstructed == 0)
    #expect(result.skippedPendingDeletion == 2)
    #expect(try f.count("asset") == 0)
    #expect(await inventory.heads.isEmpty)
  }

  @Test("doctor warns about owed deletes, listing key and last error; silent when there are none")
  func doctorWarns() async throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    func check() throws -> DoctorCheck? {
      try CatalogDoctor.run(database: f.db, databaseURL: f.databaseURL, credentialExists: { _ in true })
        .checks.first { $0.name == "pending-deletions" }
    }
    #expect(try check() == nil)
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    try f.seed(Self.b, sha: f.sha("b"), state: "archived")
    try CatalogDeletion.removeFromCatalogOnly([Self.b], in: f.db)
    #expect(try check() == nil)  // kept on purpose: nothing is owed
    FakeBucket.reset(allow: [Self.a], objects: [Self.a: f.sha("a")])
    FakeBucket.deleteStatus = 403
    try CatalogDeletion.stage([Self.a], in: f.db)
    _ = try await CatalogDeletion.purge(in: f.db, remote: f.remote)
    let warning = try check()
    #expect(warning?.status == .warning)
    #expect(warning?.detail.contains(Self.a) == true)
    #expect(warning?.detail.contains("no permission to delete") == true)
    #expect(warning?.detail.contains(Self.b) == false)
    #expect(FakeBucket.forbidden.isEmpty)
  }

  @Test("Tombstones stay out of backups; the backup's tables are the same ten")
  func backupLeavesTombstonesOut() throws {
    let f = try DeletionFixture()
    defer { f.remove() }
    try f.seed(Self.a, sha: f.sha("a"), state: "archived")
    try CatalogDeletion.stage([Self.a], in: f.db)
    let backup = try CatalogBackups.create(from: f.db)
    let json = String(decoding: try JSONEncoder().encode(backup), as: UTF8.self)
    #expect(!json.contains("\"pending_deletion\""))  // (the migration list names v3, as it should)
    #expect(!json.contains(Self.a))
    #expect(backup.tables.assets.isEmpty)
  }

  // MARK: Whole-repo guard

  @Test("The HTTP method literal \"DELETE\" appears in exactly one place: S3ObjectDeleter")
  func deleteLiteralLivesInOnePlace() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources")
    let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    var hits: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let text = try String(contentsOf: url, encoding: .utf8)
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() {
        let code = line.trimmingCharacters(in: .whitespaces)
        guard !code.hasPrefix("//") else { continue }
        guard code.contains("\"DELETE\"") || code.contains("DeleteObjects")
          || code.contains("?delete") || code.contains("DeleteBucket")
        else { continue }
        hits.append("\(url.path.replacingOccurrences(of: sources.path + "/", with: "")):\(index + 1)")
      }
    }
    #expect(hits.count == 1)
    #expect(hits.first?.hasPrefix("CatalogCore/Upload/S3ObjectDeleter.swift:") == true)
  }
}

// MARK: - Fixture

private struct DeletionFixture {
  let directory: URL
  let databaseURL: URL
  let db: DatabasePool
  let backend: Backend
  let credentials = BackendCredentials(accessKeyID: "AKIDT23", secretAccessKey: "t23-secret")

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-t23-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    databaseURL = directory.appendingPathComponent("catalog.sqlite")
    db = try CatalogCore.Database.open(at: databaseURL)
    try CatalogCore.Database.migrate(db)
    backend = try db.write { db in
      try Backend(
        slug: "t23", kind: "s3", endpoint: "https://s3.t23.invalid", bucket: "bucket",
        urlPrefix: "https://cdn.t23.invalid", keychainRef: "", createdAt: "x", updatedAt: "x"
      ).insertAndFetch(db)
    }
  }

  var deleter: S3ObjectDeleter {
    S3ObjectDeleter(backend: backend, credentials: credentials, session: FakeBucket.session)
  }

  var remote: DeletionRemote {
    let credentials = credentials
    return { backend in
      S3ObjectDeleter(backend: backend, credentials: credentials, session: FakeBucket.session)
    }
  }

  func sha(_ seed: String) -> String { Hashing.sha256(of: Data(seed.utf8)) }

  func count(_ table: String) throws -> Int { try count(table, "") }

  func count(_ table: String, _ condition: String) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table) \(condition)")! }
  }

  func addBackend(slug: String, endpoint: String) throws -> Int64 {
    try db.write { db in
      try Backend(
        slug: slug, kind: "s3", endpoint: endpoint, bucket: "bucket",
        urlPrefix: "https://cdn2.t23.invalid", keychainRef: "", createdAt: "x", updatedAt: "x"
      ).insertAndFetch(db).id!
    }
  }

  func seed(
    _ key: String, sha: String, state: String, meta: String = "{}", backendID: Int64? = nil
  ) throws {
    try db.write { db in
      _ = try Asset(
        sha256: sha, backendID: backendID ?? backend.id!, key: key, byteSize: 1, mime: "image/png",
        state: state, meta: meta, uploadedAt: "2026-10-09T00:00:00Z", createdAt: "x", updatedAt: "x"
      ).insertAndFetch(db)
    }
  }

  /// Archived, in project "blog", with a tag, a label and one live usage.
  func seedUsed(_ key: String, sha: String) throws {
    try seed(key, sha: sha, state: "archived")
    try db.write { db in
      let id = try Int64.fetchOne(db, sql: "SELECT id FROM asset WHERE key = ?", arguments: [key])!
      try db.execute(
        sql: "INSERT INTO project (slug, name, backend_id, created_at, updated_at) VALUES ('blog','Blog',?, 'x','x')",
        arguments: [backend.id])
      try db.execute(sql: "INSERT INTO asset_project VALUES (?, 1, 'x')", arguments: [id])
      try db.execute(sql: "INSERT INTO tag (name) VALUES ('t')")
      try db.execute(sql: "INSERT INTO asset_tag VALUES (?, 1)", arguments: [id])
      try db.execute(sql: "INSERT INTO asset_label VALUES (?, 'red')", arguments: [id])
      try db.execute(sql: "INSERT INTO scan (project_id, started_at, finished_at) VALUES (1, 'x', 'x')")
      try db.execute(sql: "UPDATE project SET last_scan_id = 1")
      try db.execute(
        sql: """
          INSERT INTO usage (project_id, asset_id, raw_url, source_ref, first_seen, last_seen, last_scan_id)
          VALUES (1, ?, ?, 'post.md', 'x', 'x', 1)
          """, arguments: [id, "https://cdn.t23.invalid/\(key)"])
    }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor ReindexInventory: ObjectInventory {
  let objects: [String: String]
  private(set) var heads: [String] = []

  init(objects: [String: String]) { self.objects = objects }

  nonisolated func listObjects() async throws -> [S3ObjectSummary] {
    objects.keys.sorted().map { S3ObjectSummary(key: $0, byteSize: 1) }
  }

  func headObject(key: String) async throws -> S3ObjectHead {
    heads.append(key)
    return S3ObjectHead(
      key: key, byteSize: 1, mime: "image/png", lastModified: nil,
      metadata: [
        "sha256": objects[key]!, "orig-filename": MetadataValueCodec.encode("a.png"),
        "width": "1", "height": "1",
      ])
  }
}

/// The fake bucket at `s3.t23.invalid`. `objects` maps key → the
/// `x-amz-meta-sha256` it carries (nil: an object without one).
private final class FakeBucket: URLProtocol {
  static let host = "s3.t23.invalid"
  nonisolated(unsafe) private static var state = State()
  private static let lock = NSLock()

  struct State {
    var objects: [String: String?] = [:]
    var allow: Set<String> = []
    var trace: [String] = []
    var forbidden: [String] = []
    var deleteStatus = 204
    var deleteStatusByKey: [String: Int] = [:]
    var deleteHeaders: [String: String] = [:]
    var offlineFrom: Int?
  }

  static func reset(allow keys: Set<String>, objects: [String: String?]) {
    lock.withLock { state = State(objects: objects, allow: keys) }
  }

  static var trace: [String] { lock.withLock { state.trace } }
  static var forbidden: [String] { lock.withLock { state.forbidden } }
  static var deleteStatus: Int {
    get { lock.withLock { state.deleteStatus } }
    set { lock.withLock { state.deleteStatus = newValue } }
  }
  static var deleteStatusByKey: [String: Int] {
    get { lock.withLock { state.deleteStatusByKey } }
    set { lock.withLock { state.deleteStatusByKey = newValue } }
  }
  static var deleteHeaders: [String: String] {
    get { lock.withLock { state.deleteHeaders } }
    set { lock.withLock { state.deleteHeaders = newValue } }
  }
  /// From this request index on (counting the trace), the network is down.
  static var offlineFrom: Int? {
    get { lock.withLock { state.offlineFrom } }
    set { lock.withLock { state.offlineFrom = newValue } }
  }

  static var session: URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeBucket.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let method = request.httpMethod ?? "?"
    let path = request.url?.path(percentEncoded: true) ?? ""
    let key = String(path.dropFirst("/bucket/".count)).removingPercentEncoding ?? ""
    enum Reply {
      case status(Int, [String: String])
      case offline
    }
    let reply: Reply = Self.lock.withLock {
      let index = Self.state.trace.count
      Self.state.trace.append("\(method) \(path)")
      guard request.url?.host == Self.host, path.hasPrefix("/bucket/") else {
        Self.state.forbidden.append("\(method) \(request.url?.absoluteString ?? "?")")
        return .status(418, [:])
      }
      if let offline = Self.state.offlineFrom, index >= offline { return .offline }
      switch method {
      case "HEAD":
        guard let sha = Self.state.objects[key] else { return .status(404, [:]) }
        var headers = ["Content-Length": "1"]
        if let sha { headers["x-amz-meta-sha256"] = sha }
        return .status(200, headers)
      case "DELETE":
        guard Self.state.allow.contains(key) else {
          Self.state.forbidden.append("DELETE \(path)")
          return .status(418, [:])
        }
        let status = Self.state.deleteStatusByKey[key] ?? Self.state.deleteStatus
        if (200..<300).contains(status) { Self.state.objects[key] = nil }
        return .status(status, Self.state.deleteHeaders)
      default:
        Self.state.forbidden.append("\(method) \(path)")
        return .status(418, [:])
      }
    }
    switch reply {
    case .offline:
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    case let .status(status, headers):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data())
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}
