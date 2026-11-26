import CatalogCore
import Foundation
import GRDB
import Testing

@Test("Asset list filters by project, tag, state, and date")
func assetListFilters() throws {
  try withAssetCatalog { database in
    var query = AssetQuery()
    query.project = "blog"
    query.tag = "hero"
    query.state = .active
    query.since = "2026-08-01T00:00:00Z"
    query.limit = 10
    let items = try CatalogAssets.page(query, in: database).items
    #expect(items.count == 1)
    #expect(items[0].asset.key == "blog/hero image.png")
    #expect(items[0].url == "https://img.example.com/blog/hero%20image.png")

    let json = try PublicAssetJSON.encode(
      items.map { PublicAsset(asset: $0.asset, backend: $0.backend) }
    )
    let root = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    #expect(root["schema"] as? Int == 1)
    let assets = try #require(root["assets"] as? [[String: Any]])
    #expect(assets.count == 1)
    #expect(assets[0]["sha256"] as? String == items[0].asset.sha256)
    #expect(assets[0]["id"] == nil)
    #expect(assets[0]["backend_id"] == nil)
    #expect(assets[0]["keychain_ref"] == nil)

    var archivedQuery = AssetQuery()
    archivedQuery.state = .archived
    archivedQuery.limit = 1
    let archived = try CatalogAssets.page(archivedQuery, in: database).items
    #expect(archived.map(\.asset.key) == ["archive/old.png"])
  }
}

@Test("Asset identifiers accept exact keys and unambiguous SHA-256 prefixes")
func assetIdentifierResolution() throws {
  try withAssetCatalog { database in
    let byKey = try CatalogAssets.resolve("blog/hero image.png", in: database)
    #expect(byKey.asset.sha256.hasPrefix("abcdef1"))

    let byPrefix = try CatalogAssets.resolve("abcdef1", in: database)
    #expect(byPrefix.asset.key == "blog/hero image.png")

    do {
      _ = try CatalogAssets.resolve("abcdef", in: database)
      Issue.record("Expected an ambiguous identifier.")
    } catch let AssetCatalogError.ambiguousIdentifier(identifier, candidates) {
      #expect(identifier == "abcdef")
      #expect(candidates.count == 2)
    }

    #expect(throws: AssetCatalogError.invalidSHA256Prefix("abc")) {
      _ = try CatalogAssets.resolve("abc", in: database)
    }
  }
}

@Test("Asset details include tags and live usage counts per project")
func assetDetailsIncludeUsage() throws {
  try withAssetCatalog { database in
    let details = try CatalogAssets.details("abcdef1", in: database)
    #expect(details.tags == ["hero"])
    #expect(!details.favorite)
    #expect(details.labels == [])
    #expect(details.projects.count == 1)
    #expect(details.projects[0].slug == "blog")
    #expect(details.projects[0].liveUsageCount == 1)
  }
}

@Test("Asset details include the favorite flag and labels, labels in Finder's order")
func assetDetailsIncludeCuration() throws {
  try withAssetCatalog { database in
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE asset SET favorite = 1 WHERE id = 1;
          INSERT INTO asset_label (asset_id, label) VALUES (1, 'blue'), (1, 'red');
          """)
    }
    let details = try CatalogAssets.details("abcdef1", in: database)
    #expect(details.favorite)
    #expect(details.labels == [.red, .blue])
  }
}

private func withAssetCatalog(_ body: (CatalogDatabasePool) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  try database.write { db in
    try db.execute(
      sql: """
        INSERT INTO backend
          (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta, created_at, updated_at)
        VALUES
          (1, 'r2', 's3', 'https://storage.example.com', 'images', 'auto',
           'https://img.example.com', 'backend.r2', '{}',
           '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        INSERT INTO project
          (id, slug, name, key_prefix, backend_id, created_at, updated_at)
        VALUES
          (1, 'blog', 'Blog', 'blog', 1, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        INSERT INTO asset
          (id, sha256, backend_id, key, byte_size, width, height, mime, orig_filename,
           state, pinned, meta, uploaded_at, created_at, updated_at)
        VALUES
          (1, 'abcdef1111111111111111111111111111111111111111111111111111111111', 1,
           'blog/hero image.png', 100, 10, 20, 'image/png', 'hero image.png',
           'active', 0, '{}', '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z',
           '2026-08-20T00:00:00Z'),
          (2, 'abcdef2222222222222222222222222222222222222222222222222222222222', 1,
           'archive/old.png', 200, 30, 40, 'image/png', 'old.png',
           'archived', 0, '{}', '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z',
           '2026-07-01T00:00:00Z');
        INSERT INTO asset_project (asset_id, project_id, added_at)
        VALUES (1, 1, '2026-08-20T00:00:00Z');
        INSERT INTO tag (id, name) VALUES (1, 'hero');
        INSERT INTO asset_tag (asset_id, tag_id) VALUES (1, 1);
        INSERT INTO scan (id, project_id, started_at, finished_at, found_count)
        VALUES (1, 1, '2026-08-20T00:00:00Z', '2026-08-20T00:01:00Z', 1);
        UPDATE project SET last_scan_id = 1 WHERE id = 1;
        INSERT INTO usage
          (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
        VALUES
          (1, 1, 'https://img.example.com/blog/hero%20image.png', 'post.md', 'markdown',
           '2026-08-20T00:00:00Z', '2026-08-20T00:01:00Z', 1);
        """
    )
  }
  try body(database)
}

@Test("A key two backends share is ambiguous, never resolved to whichever row comes first")
func sharedKeyAcrossBackendsIsAmbiguous() throws {
  try withAssetCatalog { database in
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta, created_at, updated_at)
          VALUES
            (2, 'twin', 's3', 'https://storage.example.com', 'images', 'auto',
             'https://img2.example.com', 'backend.twin', '{}',
             '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO asset
            (id, sha256, backend_id, key, byte_size, mime, state, meta, uploaded_at, created_at, updated_at)
          VALUES
            (3, 'fedcba3333333333333333333333333333333333333333333333333333333333', 2,
             'blog/hero image.png', 100, 'image/png', 'active', '{}',
             '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z');
          """)
    }
    let candidates = [
      "abcdef111111 blog/hero image.png (r2)", "fedcba333333 blog/hero image.png (twin)",
    ]
    #expect(throws: AssetCatalogError.ambiguousIdentifier("blog/hero image.png", candidates: candidates)) {
      try CatalogAssets.resolve("blog/hero image.png", in: database)
    }
    #expect(throws: AssetCatalogError.ambiguousIdentifier("blog/hero image.png", candidates: candidates)) {
      try CatalogAssets.setNote("x", for: "blog/hero image.png", in: database)
    }
    let notes = try database.read { try String.fetchAll($0, sql: "SELECT note FROM asset WHERE note IS NOT NULL") }
    #expect(notes.isEmpty)
    // A key only one backend holds still resolves exactly.
    #expect(try CatalogAssets.resolve("archive/old.png", in: database).asset.id == 2)
  }
}
