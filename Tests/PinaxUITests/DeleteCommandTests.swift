import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing

@testable import pinax

/// `pinax delete`. Every remote call goes to `DeleteBucket`, a URLProtocol on
/// a `.invalid` host whose DELETEs outside the allowed keys, and any method
/// but HEAD and DELETE, land in `forbidden`; no Keychain is read. The real
/// binary runs only command lines that never ask for a remote.
@Suite(.serialized) struct DeleteCommandTests {
  static let a = "blog/asset-0.png"
  static let b = "blog/asset-1.png"
  static let imported = "blog/asset-2.png"

  // MARK: Without a delete

  @Test("Without --confirm: the plan, exit 77, no request, nothing written")
  func unconfirmed() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    let before = try await f.state()

    let binary = try CLIProcess.run(["delete", Self.a, Self.imported], in: f.directory)
    #expect(binary.status == 77)
    #expect(
      binary.stdout == """
        SHA256\tKEY\tBACKEND\tBYTES\tOBJECT\tLIVE_USAGE
        000000000000\tblog/asset-0.png\tr2\t1000\tdelete\t0
        000000000000\tblog/asset-2.png\tr2\t1002\tkeep\t0

        """)
    #expect(
      binary.stderr
        == "Error: Nothing was deleted. Pass --confirm to delete the 2 listed; this cannot be undone.\n")

    let report = try await DeleteCommandOperations.delete(
      [Self.a, Self.imported], mode: .unconfirmed, in: f.database, remote: f.remote)
    #expect(report.failure?.exitCode == 77)
    #expect(try await f.state() == before)
    #expect(f.remoteCalls.value == 0)
    #expect(DeleteBucket.trace.isEmpty)
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  @Test("--dry-run: the plan, exit 0, no request, the same rows and change stamp")
  func dryRun() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    let before = try await f.state()

    // --dry-run wins over --confirm.
    let binary = try CLIProcess.run(
      ["delete", Self.a, "--dry-run", "--confirm", "--format", "json"], in: f.directory)
    #expect(binary.status == 0)
    #expect(binary.stderr == "Dry run: nothing was written.\n")
    let root = try json(binary.stdout)
    #expect(root["schema"] as? String == "pinax.delete.v1")
    #expect((root["results"] as? [Any])?.isEmpty == true)
    let entry = try #require((root["plan"] as? [[String: Any]])?.first)
    #expect(
      entry.keys.sorted() == ["backend", "bytes", "deletes_remote", "key", "live_usage", "sha256"])
    #expect(entry["sha256"] as? String == String(format: "%064x", 1))
    #expect(entry["key"] as? String == Self.a)
    #expect(entry["backend"] as? String == "r2")
    #expect(entry["bytes"] as? Int == 1000)
    #expect(entry["deletes_remote"] as? Bool == true)
    #expect(entry["live_usage"] as? Int == 0)

    let report = try await DeleteCommandOperations.delete(
      [Self.a, Self.imported], mode: .dryRun, in: f.database, remote: f.remote)
    #expect(report.failure == nil)
    #expect(try await f.state() == before)
    #expect(f.remoteCalls.value == 0)
    #expect(DeleteBucket.trace.isEmpty)
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  // MARK: The delete

  @Test("--confirm: HEAD, DELETE, HEAD per object; an imported object stays; the gallery sees it")
  func confirmed() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    DeleteBucket.reset(allow: [Self.a, Self.b], objects: f.objects)

    let report = try await DeleteCommandOperations.delete(
      [Self.a, Self.b, Self.imported], mode: .confirmed, format: .json, in: f.database,
      remote: f.remote)
    #expect(report.failure == nil)
    #expect(report.notes.isEmpty)
    let results = try #require(try json(report.output)["results"] as? [[String: Any]])
    #expect(results.map { $0["key"] as? String } == [Self.a, Self.b, Self.imported])
    #expect(
      results.map { $0["outcome"] as? String } == ["deleted", "deleted", "removed_from_catalog"])
    #expect(results.allSatisfy { $0["error"] is NSNull })
    #expect((try json(report.output)["plan"] as? [Any])?.count == 3)
    #expect(
      DeleteBucket.trace == [
        "HEAD /images/\(Self.a)", "DELETE /images/\(Self.a)", "HEAD /images/\(Self.a)",
        "HEAD /images/\(Self.b)", "DELETE /images/\(Self.b)", "HEAD /images/\(Self.b)",
      ])
    #expect(DeleteBucket.forbidden.isEmpty)

    #expect(try await ReadOnlyCatalog(database: f.database).page(AssetQuery()).items.isEmpty)
    let tombstones = try CatalogDeletion.pending(in: f.database)
    #expect(tombstones.map(\.key) == [Self.imported])
    #expect(tombstones.map(\.keepRemote) == [true])
    // A row kept on purpose is not an owed delete.
    #expect(
      try DeleteCommandOperations.pending(in: f.database)
        == "BACKEND\tKEY\tSHA256\tBYTES\tPHASE\tATTEMPTS\tLAST_ERROR")
  }

  @Test("An imported asset alone needs no remote and no credentials")
  func importedOnly() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    let report = try await DeleteCommandOperations.delete(
      [Self.imported], mode: .confirmed, in: f.database,
      remote: { _ in throw DeletionRemoteError.missingCredentials("r2") })
    #expect(report.output == "KEY\tOUTCOME\tERROR\n\(Self.imported)\tremoved_from_catalog\t-")
    #expect(DeleteBucket.trace.isEmpty)
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  // MARK: Refusals

  @Test("An asset that is not archived refuses the batch: 77, with the archive hint")
  func notArchived() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    try await f.database.write { db in
      try db.execute(sql: "UPDATE asset SET state = 'active' WHERE key = ?", arguments: [Self.b])
    }
    let before = try await f.state()
    let binary = try CLIProcess.run(["delete", Self.a, Self.b], in: f.directory)
    #expect(binary.status == 77)
    #expect(binary.stdout == "")
    #expect(
      binary.stderr == """
        Run `pinax archive` on them first.
        Error: Archive first; only archived assets can be deleted: \(Self.b)

        """)
    await f.expectRefusal([Self.a, Self.b], code: 77)
    #expect(try await f.state() == before)
    #expect(f.remoteCalls.value == 0)
    #expect(DeleteBucket.trace.isEmpty)
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  @Test("Live usage refuses even with --confirm: 77; --include-used lets it through")
  func liveUsage() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    // The imported asset is guarded too, though its object would stay.
    try seedLiveUsage(
      f.database, projectSlug: "blog", sha256: String(format: "%064x", 3), count: 2)
    let before = try await f.state()
    let binary = try CLIProcess.run(
      ["delete", Self.a, Self.imported, "--dry-run"], in: f.directory)
    #expect(binary.status == 77)
    #expect(
      binary.stderr == """
        Pass --include-used to delete them anyway.
        Error: Still referenced: \(Self.imported) (2)

        """)
    await f.expectRefusal([Self.a, Self.imported], code: 77)
    #expect(try await f.state() == before)
    #expect(f.remoteCalls.value == 0)
    #expect(DeleteBucket.trace.isEmpty)

    DeleteBucket.reset(allow: [Self.a], objects: f.objects)
    let report = try await DeleteCommandOperations.delete(
      [Self.a, Self.imported], mode: .confirmed, includeUsed: true, in: f.database,
      remote: f.remote)
    #expect(report.failure == nil)
    #expect(
      DeleteBucket.trace == [
        "HEAD /images/\(Self.a)", "DELETE /images/\(Self.a)", "HEAD /images/\(Self.a)",
      ])
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  @Test("Bad identifiers refuse the whole batch, each named: 66")
  func badIdentifiers() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    let before = try await f.state()
    let binary = try CLIProcess.run(
      ["delete", Self.a, "blog/nope.png", "abcdef"], in: f.directory)
    #expect(binary.status == 66)
    #expect(binary.stderr.contains("'blog/nope.png'"))
    #expect(binary.stderr.contains("No asset matches 'abcdef'."))
    await f.expectRefusal([Self.a, "abcdef"], code: 66)
    #expect(try await f.state() == before)
    #expect(f.remoteCalls.value == 0)
    #expect(DeleteBucket.trace.isEmpty)
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  @Test("101 assets refuse the batch: 77")
  func overTheLimit() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    for index in 3..<101 {
      try seedAsset(f.database, index: index, uploadedAt: "2026-08-01T00:00:00Z")
    }
    try await f.database.write { try $0.execute(sql: "UPDATE asset SET state = 'archived'") }
    let keys = (0..<101).map { "blog/asset-\($0).png" }
    let before = try await f.state()
    let binary = try CLIProcess.run(["delete"] + keys, in: f.directory)
    #expect(binary.status == 77)
    #expect(binary.stderr.contains("101 assets requested; at most 100"))
    await f.expectRefusal(keys, code: 77)
    #expect(try await f.state() == before)
    #expect(f.remoteCalls.value == 0)
    #expect(DeleteBucket.trace.isEmpty)
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  @Test("A key another backend on the same bucket names refuses the batch: 77")
  func sharedKey() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    try await f.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          SELECT 2, 'twin', kind, endpoint, bucket, region, url_prefix, '', meta,
            created_at, updated_at FROM backend WHERE id = 1;
          INSERT INTO asset
            (sha256, backend_id, key, byte_size, mime, state, meta, uploaded_at, created_at,
             updated_at)
          VALUES ('\(String(repeating: "f", count: 64))', 2, '\(Self.a)', 1, 'image/png',
            'archived', '{}', 'x', 'x', 'x');
          """)
    }
    let before = try await f.state()
    let twin = String(repeating: "f", count: 64)
    // The plan alone already refuses.
    let binary = try CLIProcess.run(["delete", twin, "--dry-run"], in: f.directory)
    #expect(binary.status == 77)
    await f.expectRefusal([twin], code: 77)
    #expect(try await f.state() == before)
    #expect(f.remoteCalls.value == 0)
    #expect(DeleteBucket.trace.isEmpty)
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  @Test("Missing credentials refuse before the first write: 78")
  func missingCredentials() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    let before = try await f.state()
    do {
      _ = try await DeleteCommandOperations.delete(
        [Self.a, Self.imported], mode: .confirmed, in: f.database,
        remote: { throw DeletionRemoteError.missingCredentials($0.slug) })
      Issue.record("expected missing credentials")
    } catch {
      #expect(CLIExit.code(for: error) == 78)
      #expect("\(error)" == "No credentials for backend 'r2' in Keychain.")
    }
    #expect(try await f.state() == before)
    #expect(DeleteBucket.trace.isEmpty)
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  // MARK: Owed deletes

  @Test("403: exit 69 with the permission sentence, the tombstone stays; --resume finishes")
  func forbiddenThenResume() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    DeleteBucket.reset(allow: [Self.a], objects: f.objects)
    DeleteBucket.deleteStatus = 403
    let first = try await DeleteCommandOperations.delete(
      [Self.a], mode: .confirmed, in: f.database, remote: f.remote)
    #expect(first.failure?.exitCode == 69)
    #expect(first.output.hasPrefix("KEY\tOUTCOME\tERROR\n\(Self.a)\tfailed\t"))
    #expect(first.notes.count == 1)
    #expect(first.notes.first?.contains("has no permission to delete") == true)

    let listed = try CLIProcess.run(["delete", "--pending", "--format", "json"], in: f.directory)
    #expect(listed.status == 0)
    let root = try json(listed.stdout)
    #expect(root["schema"] as? String == "pinax.pending-deletions.v1")
    let owed = try #require(root["pending"] as? [[String: Any]])
    #expect(owed.map { $0["key"] as? String } == [Self.a])
    #expect(owed.first?["backend"] as? String == "r2")
    #expect(owed.first?["phase"] as? String == "delete_sent")
    #expect(owed.first?["attempts"] as? Int == 1)
    #expect((owed.first?["last_error"] as? String)?.contains("permission") == true)

    DeleteBucket.deleteStatus = 204
    let second = try await DeleteCommandOperations.resume(
      backend: "r2", in: f.database, remote: f.remote)
    #expect(second.failure == nil)
    #expect(second.output == "KEY\tOUTCOME\tERROR\n\(Self.a)\tdeleted\t-")
    #expect(try CatalogDeletion.pending(in: f.database).isEmpty)
    #expect(
      DeleteBucket.trace == [
        "HEAD /images/\(Self.a)", "DELETE /images/\(Self.a)",
        "HEAD /images/\(Self.a)", "DELETE /images/\(Self.a)", "HEAD /images/\(Self.a)",
      ])
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  @Test("--resume: missing credentials are 78; a foreign object is 77; a mix is 1")
  func resumeStatuses() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    _ = try CatalogDeletion.stage([Self.a, Self.b], in: f.database)
    let missing: DeletionRemote = { throw DeletionRemoteError.missingCredentials($0.slug) }
    let first = try await DeleteCommandOperations.resume(in: f.database, remote: missing)
    #expect(first.failure?.exitCode == 78)
    #expect(try CatalogDeletion.pending(in: f.database).map(\.attempts) == [1, 1])
    #expect(DeleteBucket.trace.isEmpty)

    // Not ours: neither is sent a DELETE.
    DeleteBucket.reset(allow: [], objects: [Self.a: nil, Self.b: nil])
    let refused = try await DeleteCommandOperations.resume(
      format: .json, in: f.database, remote: f.remote)
    #expect(refused.failure?.exitCode == 77)
    let results = try #require(try json(refused.output)["results"] as? [[String: Any]])
    #expect(results.map { $0["outcome"] as? String } == ["refused_mismatch", "refused_mismatch"])
    #expect((results.first?["error"] as? String)?.contains("x-amz-meta-sha256") == true)
    #expect(DeleteBucket.trace == ["HEAD /images/\(Self.a)", "HEAD /images/\(Self.b)"])
    #expect(DeleteBucket.forbidden.isEmpty)

    // One refused, one failed by the store.
    DeleteBucket.reset(allow: [Self.b], objects: [Self.a: nil, Self.b: f.objects[Self.b]!])
    DeleteBucket.deleteStatus = 503
    let mixed = try await DeleteCommandOperations.resume(in: f.database, remote: f.remote)
    #expect(mixed.failure?.exitCode == 1)
    #expect(
      DeleteBucket.trace == [
        "HEAD /images/\(Self.a)", "HEAD /images/\(Self.b)", "DELETE /images/\(Self.b)",
      ])
    #expect(DeleteBucket.forbidden.isEmpty)
  }

  @Test("--resume --backend takes only that backend's tombstones; an unknown one is 66")
  func resumeOneBackend() async throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    try await f.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          SELECT 2, 'other', kind, endpoint, 'elsewhere', region, url_prefix, '', meta,
            created_at, updated_at FROM backend WHERE id = 1;
          UPDATE asset SET backend_id = 2 WHERE key = '\(Self.b)';
          """)
    }
    _ = try CatalogDeletion.stage([Self.a, Self.b], in: f.database)
    DeleteBucket.reset(allow: [Self.a], objects: f.objects)
    let report = try await DeleteCommandOperations.resume(
      backend: "r2", in: f.database, remote: f.remote)
    #expect(report.failure == nil)
    #expect(try CatalogDeletion.pending(in: f.database).map(\.key) == [Self.b])
    #expect(
      DeleteBucket.trace == [
        "HEAD /images/\(Self.a)", "DELETE /images/\(Self.a)", "HEAD /images/\(Self.a)",
      ])
    #expect(DeleteBucket.forbidden.isEmpty)

    let unknown = try CLIProcess.run(["delete", "--resume", "--backend", "nope"], in: f.directory)
    #expect(unknown.status == 66)
  }

  @Test("Command lines that mix the modes are usage errors: 64")
  func usage() throws {
    let f = try DeleteFixture()
    defer { f.remove() }
    for arguments in [
      [], ["--resume", "--pending"], ["--pending", Self.a], ["--resume", "--confirm"],
      ["--pending", "--dry-run"], ["--resume", "--include-used"],
      [Self.a, "--backend", "r2"],
    ] {
      let result = try CLIProcess.run(["delete"] + arguments, in: f.directory)
      #expect(result.status == 64, "\(arguments)")
    }
  }

  private func json(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }
}

// MARK: - Fixture

/// Three archived assets on `r2`, whose endpoint is the fake bucket; the
/// third is an import. No backend has a Keychain reference.
private struct DeleteFixture {
  final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func add() { lock.withLock { stored += 1 } }
  }

  let database: DatabasePool
  let directory: URL
  let remoteCalls = Count()

  init() throws {
    (database, directory) = try makeUITestDatabase()
    for index in 0..<3 {
      try seedAsset(
        database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z",
        meta: index == 2 ? #"{"imported_from":"picgo"}"# : "{}")
    }
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE backend SET keychain_ref = '', endpoint = 'https://\(DeleteBucket.host)';
          UPDATE asset SET state = 'archived';
          """)
    }
    DeleteBucket.reset(allow: [], objects: [:])
  }

  /// What the bucket holds under each key, as Pinax wrote it.
  var objects: [String: String?] {
    Dictionary(
      uniqueKeysWithValues: (0..<3).map {
        ("blog/asset-\($0).png", String(format: "%064x", $0 + 1) as String?)
      })
  }

  var remote: DeletionRemote {
    let calls = remoteCalls
    return { backend in
      calls.add()
      return S3ObjectDeleter(
        backend: backend,
        credentials: BackendCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret"),
        session: DeleteBucket.session)
    }
  }

  /// Rows, tombstones and the gallery's change stamp.
  func state() async throws -> [String] {
    let rows = try await database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT 'asset ' || id || ' ' || state || ' ' || updated_at FROM asset
          UNION ALL SELECT 'member ' || asset_id || ' ' || project_id FROM asset_project
          UNION ALL SELECT 'owed ' || id || ' ' || phase || ' ' || attempts FROM pending_deletion
          ORDER BY 1
          """)
    }
    return rows + [try await CatalogAssets.changeStamp(in: database)]
  }

  /// A confirmed delete that throws an error with this exit status.
  func expectRefusal(_ identifiers: [String], code: Int32) async {
    do {
      _ = try await DeleteCommandOperations.delete(
        identifiers, mode: .confirmed, in: database, remote: remote)
      Issue.record("expected a refusal for \(identifiers)")
    } catch {
      #expect(CLIExit.code(for: error) == code, "\(error)")
    }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A fake S3 bucket on a `.invalid` host, path style, buckets `images` and
/// `elsewhere`.
private final class DeleteBucket: URLProtocol {
  static let host = "s3.delete.invalid"
  nonisolated(unsafe) private static var state = State()
  private static let lock = NSLock()

  struct State {
    var objects: [String: String?] = [:]
    var allow: Set<String> = []
    var trace: [String] = []
    var forbidden: [String] = []
    var deleteStatus = 204
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

  static var session: URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeleteBucket.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let method = request.httpMethod ?? "?"
    let path = request.url?.path(percentEncoded: true) ?? ""
    let key = path.split(separator: "/").dropFirst().joined(separator: "/")
    let (status, headers): (Int, [String: String]) = Self.lock.withLock {
      Self.state.trace.append("\(method) \(path)")
      guard request.url?.host == Self.host else {
        Self.state.forbidden.append("\(method) \(request.url?.absoluteString ?? "?")")
        return (418, [:])
      }
      switch method {
      case "HEAD":
        guard let sha = Self.state.objects[key] else { return (404, [:]) }
        var headers = ["Content-Length": "1"]
        if let sha { headers["x-amz-meta-sha256"] = sha }
        return (200, headers)
      case "DELETE":
        guard path.hasPrefix("/images/"), Self.state.allow.contains(key) else {
          Self.state.forbidden.append("DELETE \(path)")
          return (418, [:])
        }
        let status = Self.state.deleteStatus
        if (200..<300).contains(status) { Self.state.objects[key] = nil }
        return (status, [:])
      default:
        Self.state.forbidden.append("\(method) \(path)")
        return (418, [:])
      }
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
