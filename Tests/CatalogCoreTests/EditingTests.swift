import CatalogCore
import Foundation
import GRDB
import Testing

private func makeEditingDatabase() throws -> (database: DatabasePool, directory: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("pinax-edit-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  try database.write { db in
    try db.execute(
      sql: """
        INSERT INTO backend
          (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
           created_at, updated_at)
        VALUES
          (1, 'r2', 's3', 'https://storage.example.com', 'images', 'auto',
           'https://img.example.com', 'backend.r2', '{}',
           '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        INSERT INTO project
          (id, slug, name, key_prefix, backend_id, created_at, updated_at)
        VALUES
          (1, 'blog', 'Blog', 'blog', 1, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
          (2, 'docs', 'Docs', 'docs', 1, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        """
    )
  }
  return (database, directory)
}

private func seedSingleAsset(_ database: DatabasePool) throws -> String {
  try database.write { db in
    var asset = Asset(
      sha256: String(repeating: "5", count: 64),
      backendID: 1,
      key: "blog/hero.png",
      byteSize: 100,
      width: 10,
      height: 20,
      mime: "image/png",
      originalFilename: "hero.png",
      uploadedAt: "2026-08-20T12:00:00Z",
      createdAt: "2026-08-20T12:00:00Z",
      updatedAt: "2026-08-20T12:00:00Z"
    )
    try asset.insert(db)
    return asset.sha256
  }
}

private func fetchNote(_ database: DatabasePool, _ identifier: String) throws -> String? {
  try CatalogAssets.resolve(identifier, in: database).asset.note
}

private func projectSlugs(_ database: DatabasePool, _ identifier: String) throws -> [String] {
  try CatalogAssets.details(identifier, in: database).projects.map(\.slug)
}

private func updatedAtOf(_ database: DatabasePool, _ identifier: String) throws -> String {
  try CatalogAssets.details(identifier, in: database).item.asset.updatedAt
}

/// One live reference to asset 1 inside blog's latest scan — the state the
/// unlink guard exists for.
private func seedLiveReference(_ database: DatabasePool) throws {
  try database.write { db in
    try db.execute(
      sql: """
        INSERT INTO scan (id, project_id, started_at, finished_at, found_count)
        VALUES (1, 1, '2026-08-20T10:00:00Z', '2026-08-20T10:01:00Z', 1);
        UPDATE project SET last_scan_id = 1 WHERE id = 1;
        INSERT INTO usage
          (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
        VALUES
          (1, 1, 'https://img.example.com/hero.png', 'post.md', 'markdown',
           '2026-08-20T10:00:00Z', '2026-08-20T10:01:00Z', 1);
        """
    )
  }
}

private func membershipCount(_ database: DatabasePool, sha: String, project slug: String) throws
  -> Int
{
  try database.read { db in
    try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM asset_project ap
        JOIN asset a ON a.id = ap.asset_id
        JOIN project p ON p.id = ap.project_id
        WHERE a.sha256 = ? AND p.slug = ?
        """,
      arguments: [sha, slug]) ?? 0
  }
}

@Suite struct EditingTests {
  @Test("setNote stores text and clears on nil or whitespace")
  func setNoteLifecycle() throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)

    try CatalogAssets.setNote("a hero shot", for: sha, in: database, now: Date(timeIntervalSince1970: 1_800_000_000))
    var note = try fetchNote(database, sha)
    let updatedAt = try updatedAtOf(database, sha)
    #expect(note == "a hero shot")
    #expect(updatedAt == "2027-01-15T08:00:00Z")

    try CatalogAssets.setNote("   ", for: sha, in: database)
    note = try fetchNote(database, sha)
    #expect(note == nil)

    try CatalogAssets.setNote(nil, for: sha, in: database)
    note = try fetchNote(database, sha)
    #expect(note == nil)
  }

  @Test("setNote via the async sibling matches the synchronous result")
  func setNoteAsync() async throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)

    try await CatalogAssets.setNote("async note", for: sha, in: database)
    let note = try fetchNote(database, sha)
    #expect(note == "async note")  }

  @Test("Project membership is added idempotently and reflected in details")
  func addToProject() throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)

    try CatalogAssets.addToProject("docs", identifier: sha, in: database)
    try CatalogAssets.addToProject("docs", identifier: sha, in: database)

    #expect(try projectSlugs(database, sha) == ["docs"])

    #expect(throws: AssetCatalogError.projectNotFound("missing")) {
      try CatalogAssets.addToProject("missing", identifier: sha, in: database)
    }
  }

  @Test("Removing membership deletes only that link and is a no-op when absent")
  func removeFromProject() throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)

    try CatalogAssets.addToProject("blog", identifier: sha, in: database)
    try CatalogAssets.addToProject("docs", identifier: sha, in: database)
    try CatalogAssets.removeFromProject("docs", identifier: sha, in: database)
    try CatalogAssets.removeFromProject("docs", identifier: sha, in: database)

    #expect(try projectSlugs(database, sha) == ["blog"])

    let count = try database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM asset_project ap JOIN project p ON p.id = ap.project_id WHERE p.slug = 'docs'"
      ) ?? 0
    }
    #expect(count == 0)
  }

  @Test("Membership editing works through the async siblings")
  func membershipAsync() async throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)

    try await CatalogAssets.addToProject("docs", identifier: sha, in: database)
    var slugs = try await CatalogAssets.details(sha, in: database).projects.map(\.slug)
    #expect(slugs == ["docs"])

    try await CatalogAssets.removeFromProject("docs", identifier: sha, in: database)
    slugs = try await CatalogAssets.details(sha, in: database).projects.map(\.slug)
    #expect(slugs.isEmpty)
  }

  @Test("Unlinking a still-referenced asset is refused unless confirmed")
  func unlinkLiveUsageGuard() async throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)
    try await CatalogAssets.addToProject("blog", identifier: sha, in: database)
    try seedLiveReference(database)

    let blocked = AssetCatalogError.unlinkBlockedByLiveUsage(project: "blog", liveCount: 1)
    #expect(throws: blocked) {
      try CatalogAssets.removeFromProject("blog", identifier: sha, in: database)
    }
    await #expect(throws: blocked) {
      try await CatalogAssets.removeFromProject("blog", identifier: sha, in: database)
    }
    #expect(try membershipCount(database, sha: sha, project: "blog") == 1)

    try await CatalogAssets.removeFromProject("blog", identifier: sha, in: database, confirmed: true)
    #expect(try membershipCount(database, sha: sha, project: "blog") == 0)
  }

  @Test("moveAsset is atomic — a bad target leaves the old membership intact")
  func moveAssetAtomicity() async throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)
    try await CatalogAssets.addToProject("blog", identifier: sha, in: database)

    await #expect(throws: AssetCatalogError.projectNotFound("ghost")) {
      try await CatalogAssets.moveAsset(sha, fromProject: "blog", toProject: "ghost", in: database)
    }
    #expect(try membershipCount(database, sha: sha, project: "blog") == 1)

    try await CatalogAssets.moveAsset(sha, fromProject: "blog", toProject: "docs", in: database)
    #expect(try membershipCount(database, sha: sha, project: "blog") == 0)
    #expect(try membershipCount(database, sha: sha, project: "docs") == 1)

    // Unlink via nil target, then link again via nil source.
    try await CatalogAssets.moveAsset(sha, fromProject: "docs", toProject: nil, in: database)
    #expect(try membershipCount(database, sha: sha, project: "docs") == 0)
    try await CatalogAssets.moveAsset(sha, fromProject: nil, toProject: "docs", in: database)
    #expect(try membershipCount(database, sha: sha, project: "docs") == 1)
  }

  @Test("moveAsset away from a still-referenced project is refused whole")
  func moveAssetLiveUsageGuard() async throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)
    try await CatalogAssets.addToProject("blog", identifier: sha, in: database)
    try seedLiveReference(database)

    await #expect(throws: AssetCatalogError.unlinkBlockedByLiveUsage(project: "blog", liveCount: 1)) {
      try await CatalogAssets.moveAsset(sha, fromProject: "blog", toProject: "docs", in: database)
    }
    #expect(try membershipCount(database, sha: sha, project: "blog") == 1)
    #expect(try membershipCount(database, sha: sha, project: "docs") == 0)

    try await CatalogAssets.moveAsset(
      sha, fromProject: "blog", toProject: "docs", in: database, confirmed: true)
    #expect(try membershipCount(database, sha: sha, project: "blog") == 0)
    #expect(try membershipCount(database, sha: sha, project: "docs") == 1)
  }

  @Test("doctor flags referenced assets whose membership is missing, and clears when repaired")
  func doctorUsageMembershipCheck() throws {
    let (database, directory) = try makeEditingDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sha = try seedSingleAsset(database)

    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO scan (id, project_id, started_at, finished_at, found_count)
          VALUES (1, 1, '2026-08-20T10:00:00Z', '2026-08-20T10:01:00Z', 1);
          UPDATE project SET last_scan_id = 1 WHERE id = 1;
          INSERT INTO usage
            (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
          VALUES
            (1, 1, 'https://img.example.com/hero.png', 'post.md', 'markdown',
             '2026-08-20T10:00:00Z', '2026-08-20T10:01:00Z', 1);
          """
      )
    }

    func membershipCheck() throws -> DoctorCheck {
      let report = try CatalogDoctor.run(
        database: database,
        databaseURL: directory.appendingPathComponent("catalog.sqlite"),
        credentialExists: { _ in true }
      )
      return try #require(report.checks.first { $0.name == "usage-membership" })
    }

    var check = try membershipCheck()
    #expect(check.status == .warning)
    #expect(check.detail.contains("blog"))

    try CatalogAssets.addToProject("blog", identifier: sha, in: database)
    check = try membershipCheck()
    #expect(check.status == .pass)
  }
}
