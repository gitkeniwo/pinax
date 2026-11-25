import CatalogCore
import Foundation
import GRDB
import Testing

private let a = String(repeating: "a", count: 64)
private let b = String(repeating: "b", count: 64)
/// Shares its first seven characters with `b`.
private let c = String(repeating: "b", count: 7) + String(repeating: "c", count: 57)

/// Three assets in `blog`; blog's latest scan references `b` twice. `docs` is
/// empty.
private func withCurationCatalog(_ body: (DatabasePool) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("pinax-batch-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  try await database.write { db in
    try db.execute(
      sql: """
        INSERT INTO backend
          (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
           created_at, updated_at)
        VALUES
          (1, 'r2', 's3', 'https://storage.example.com', 'images', 'auto',
           'https://img.example.com', 'backend.r2', '{}',
           '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        INSERT INTO project (id, slug, name, key_prefix, backend_id, created_at, updated_at)
        VALUES
          (1, 'blog', 'Blog', 'blog', 1, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
          (2, 'docs', 'Docs', 'docs', 1, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        """)
    for (index, sha) in [a, b, c].enumerated() {
      var asset = Asset(
        sha256: sha, backendID: 1, key: "blog/\(index).png", byteSize: 1, width: 1, height: 1,
        mime: "image/png", originalFilename: nil, uploadedAt: "2026-08-01T00:00:00Z",
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z")
      try asset.insert(db)
    }
    try db.execute(
      sql: """
        INSERT INTO asset_project (asset_id, project_id, added_at)
        SELECT id, 1, '2026-08-01T00:00:00Z' FROM asset;
        INSERT INTO scan (id, project_id, started_at, finished_at, found_count)
        VALUES (1, 1, '2026-08-20T10:00:00Z', '2026-08-20T10:01:00Z', 2);
        UPDATE project SET last_scan_id = 1 WHERE id = 1;
        INSERT INTO usage
          (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
        SELECT 1, id, 'https://img.example.com/blog/1.png', ref, 'markdown',
               '2026-08-20T10:00:00Z', '2026-08-20T10:01:00Z', 1
        FROM asset, (SELECT 'one.md' AS ref UNION SELECT 'two.md') WHERE key = 'blog/1.png';
        """)
  }
  try await body(database)
}

/// Every row a curation write could touch.
private func curationRows(_ database: DatabasePool) async throws -> [String] {
  try await database.read { db in
    try String.fetchAll(
      db,
      sql: """
        SELECT 'asset ' || id || ' ' || state || ' ' || favorite || ' ' || updated_at FROM asset
        UNION ALL SELECT 'label ' || asset_id || ' ' || label FROM asset_label
        UNION ALL
        SELECT 'member ' || asset_id || ' ' || project_id || ' ' || added_at FROM asset_project
        ORDER BY 1
        """)
  }
}

@Suite struct CurationBatchTests {
  private let bad = AssetCatalogError.unresolvedIdentifiers([.assetNotFound("dddddd")])

  @Test("One unresolved identifier among three writes nothing, in every batch write")
  func oneBadIdentifier() async throws {
    try await withCurationCatalog { database in
      let identifiers = ["blog/0.png", "dddddd", "blog/2.png"]
      let rows = try await curationRows(database)
      await #expect(throws: bad) {
        try await CatalogAssets.setState(.archived, for: identifiers, in: database)
      }
      await #expect(throws: bad) {
        try await CatalogAssets.setFavorite(true, for: identifiers, in: database)
      }
      await #expect(throws: bad) {
        try await CatalogAssets.setLabel(.red, true, for: identifiers, in: database)
      }
      await #expect(throws: bad) {
        try await CatalogAssets.addToProject("docs", identifiers: identifiers, in: database)
      }
      await #expect(throws: bad) {
        try await CatalogAssets.removeFromProject("blog", identifiers: identifiers, in: database)
      }
      await #expect(throws: bad) {
        try await CatalogAssets.moveAssets(
          identifiers, fromProject: "blog", toProject: "docs", in: database)
      }
      #expect(try await curationRows(database) == rows)
    }
  }

  @Test("The error lists every bad identifier, each with its own reason")
  func allBadIdentifiers() async throws {
    try await withCurationCatalog { database in
      do {
        try await CatalogAssets.setFavorite(
          true, for: ["dddddd", "blog/0.png", "bbbbbbb", "nope", "dddddd"], in: database)
        Issue.record("Expected the batch to be refused.")
      } catch let AssetCatalogError.unresolvedIdentifiers(errors) {
        #expect(
          errors == [
            .assetNotFound("dddddd"),
            .ambiguousIdentifier(
              "bbbbbbb", candidates: ["\(b.prefix(12)) blog/1.png", "\(c.prefix(12)) blog/2.png"]),
            .invalidSHA256Prefix("nope"),
          ])
        let message = AssetCatalogError.unresolvedIdentifiers(errors).description
        #expect(message.split(separator: "\n").count == 3)
      }
    }
  }

  @Test("One referenced asset keeps the whole unlink or move from happening")
  func liveUsageRefusesBatch() async throws {
    try await withCurationCatalog { database in
      let blocked = AssetCatalogError.unlinkBlockedForAssets(
        project: "blog",
        assets: [LiveUsedAsset(sha256: b, key: "blog/1.png", liveCount: 2)])
      let identifiers = ["blog/0.png", "blog/1.png", "blog/2.png"]
      let rows = try await curationRows(database)
      await #expect(throws: blocked) {
        try await CatalogAssets.removeFromProject("blog", identifiers: identifiers, in: database)
      }
      #expect(throws: blocked) {
        try CatalogAssets.removeFromProject("blog", identifiers: identifiers, in: database)
      }
      await #expect(throws: blocked) {
        try await CatalogAssets.moveAssets(
          identifiers, fromProject: "blog", toProject: "docs", in: database)
      }
      #expect(try await curationRows(database) == rows)

      let changes = try await CatalogAssets.moveAssets(
        identifiers, fromProject: "blog", toProject: "docs", in: database, confirmed: true)
      #expect(changes.map(\.after.projects) == [["docs"], ["docs"], ["docs"]])
    }
  }

  @Test("A one-asset form still throws the error about that asset")
  func singleForms() async throws {
    try await withCurationCatalog { database in
      let blocked = AssetCatalogError.unlinkBlockedByLiveUsage(project: "blog", liveCount: 2)
      #expect(throws: blocked) {
        try CatalogAssets.removeFromProject("blog", identifier: b, in: database)
      }
      await #expect(throws: blocked) {
        try await CatalogAssets.removeFromProject("blog", identifier: b, in: database)
      }
      await #expect(throws: blocked) {
        try await CatalogAssets.moveAsset(b, fromProject: "blog", toProject: "docs", in: database)
      }
      await #expect(throws: AssetCatalogError.assetNotFound("dddddd")) {
        try await CatalogAssets.addToProject("docs", identifier: "dddddd", in: database)
      }
      #expect(throws: AssetCatalogError.invalidSHA256Prefix("nope")) {
        try CatalogAssets.addToProject("docs", identifier: "nope", in: database)
      }
    }
  }

  @Test("A dry run returns the changes and rolls them back")
  func dryRun() async throws {
    try await withCurationCatalog { database in
      let rows = try await curationRows(database)
      let stamp = try await CatalogAssets.changeStamp(in: database)
      let planned = try await CatalogAssets.setState(
        .archived, for: ["blog/0.png", a, "blog/2.png"], in: database, dryRun: true)
      // Named twice, listed once.
      #expect(planned.map(\.key) == ["blog/0.png", "blog/2.png"])
      #expect(planned.map(\.before.state) == ["active", "active"])
      #expect(planned.map(\.after.state) == ["archived", "archived"])
      let linked = try await CatalogAssets.addToProject(
        "docs", identifiers: ["blog/0.png"], in: database, dryRun: true)
      #expect(linked.first?.after.projects == ["blog", "docs"])
      #expect(try await curationRows(database) == rows)
      #expect(try await CatalogAssets.changeStamp(in: database) == stamp)

      let written = try await CatalogAssets.setState(
        .archived, for: ["blog/0.png", "blog/2.png"], in: database)
      #expect(written == planned)
      #expect(try await CatalogAssets.changeStamp(in: database) != stamp)
    }
  }

  @Test("A missing project writes nothing")
  func missingProject() async throws {
    try await withCurationCatalog { database in
      let rows = try await curationRows(database)
      await #expect(throws: AssetCatalogError.projectNotFound("ghost")) {
        try await CatalogAssets.moveAssets(
          ["blog/0.png"], fromProject: "blog", toProject: "ghost", in: database)
      }
      await #expect(throws: AssetCatalogError.projectNotFound("ghost")) {
        try await CatalogAssets.addToProject("ghost", identifiers: ["blog/0.png"], in: database)
      }
      #expect(try await curationRows(database) == rows)
    }
  }
}
