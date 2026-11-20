import CatalogCore
import Foundation
import GRDB
import Testing

/// Restoring a backup into an empty catalog.
/// Temporary catalogs only; nothing touches the user's database.
@Suite struct RestoreTests {
  private func makeEmptyCatalog() throws -> (database: DatabasePool, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-restore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    return (database, directory)
  }

  /// Every table at least two rows; non-consecutive ids; favourites, labels,
  /// prefix history; the project.last_scan_id ↔ scan.project_id cycle;
  /// a usage row whose asset_id is NULL.
  private func makeFixtureCatalog() throws -> (database: DatabasePool, directory: URL) {
    let (database, directory) = try makeEmptyCatalog()
    try database.write { db in
      try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          VALUES
            (3, 'r2', 's3', 'https://storage.example.com', 'images', 'auto',
             'https://img.example.com', 'backend.r2', '{"x":1}',
             '2026-08-01T00:00:00Z', '2026-08-02T00:00:00Z'),
            (7, 'old', 's3', 'https://old.example.com', 'legacy', 'eu-west-1',
             'https://old.example.com/i', 'backend.old', '{}',
             '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z');
          INSERT INTO backend_prefix_history (id, backend_id, url_prefix, retired_at) VALUES
            (2, 3, 'https://cdn.example.com', '2026-08-03T00:00:00Z'),
            (5, 3, 'https://pics.example.com', '2026-08-04T00:00:00Z');
          INSERT INTO project
            (id, slug, name, key_prefix, backend_id, last_scan_id, note, meta,
             created_at, updated_at)
          VALUES
            (4, 'blog', 'Blog', 'blog', 3, 22, 'n',
             '{"sources":[{"label":"site","path":"/nonexistent/blog"}],"keep":true}',
             '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
            (9, 'notes', 'Notes', '', NULL, 23, NULL, '{}',
             '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO asset
            (id, sha256, backend_id, key, byte_size, width, height, mime, orig_filename,
             state, pinned, note, meta, uploaded_at, created_at, updated_at, favorite)
          VALUES
            (10, 'a10', 3, 'blog/a.png', 100, 10, 20, 'image/png', 'a.png', 'active', 0,
             NULL, '{}', '2026-08-05T00:00:00Z', '2026-08-05T00:00:00Z',
             '2026-08-05T00:00:00Z', 0),
            (12, 'a12', 3, 'blog/b.png', 200, NULL, NULL, 'image/png', NULL, 'archived', 1,
             'note', '{"m":2}', '2026-08-06T00:00:00Z', '2026-08-06T00:00:00Z',
             '2026-08-07T00:00:00Z', 1),
            (15, 'a15', 7, 'c.jpg', 300, 30, 40, 'image/jpeg', 'c.jpg', 'active', 0,
             NULL, '{}', '2026-08-08T00:00:00Z', '2026-08-08T00:00:00Z',
             '2026-08-08T00:00:00Z', 1);
          INSERT INTO asset_project (asset_id, project_id, added_at) VALUES
            (10, 4, '2026-08-05T00:00:00Z'), (12, 4, '2026-08-06T00:00:00Z'),
            (15, 9, '2026-08-08T00:00:00Z');
          INSERT INTO tag (id, name) VALUES (2, 'hero'), (6, 'diagram');
          INSERT INTO asset_tag (asset_id, tag_id) VALUES (10, 2), (15, 6), (15, 2);
          INSERT INTO scan
            (id, project_id, started_at, finished_at, source_rev, coverage, found_count)
          VALUES
            (21, 4, '2026-08-09T00:00:00Z', '2026-08-09T00:01:00Z', 'abc', '["site"]', 2),
            (22, 4, '2026-08-10T00:00:00Z', '2026-08-10T00:01:00Z', NULL, '[]', 2),
            (23, 9, '2026-08-11T00:00:00Z', NULL, NULL, '[]', NULL);
          INSERT INTO usage
            (id, project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen,
             last_scan_id)
          VALUES
            (30, 4, 10, 'https://img.example.com/blog/a.png', 'site/a.md#L1', 'markdown',
             '2026-08-09T00:00:00Z', '2026-08-10T00:00:00Z', 22),
            (31, 4, NULL, 'https://elsewhere.example.org/x.png', 'site/a.md#L4', 'html',
             '2026-08-09T00:00:00Z', '2026-08-10T00:00:00Z', 22),
            (34, 9, 15, 'https://old.example.com/i/c.jpg', 'notes.md#L2', 'markdown',
             '2026-08-11T00:00:00Z', '2026-08-11T00:00:00Z', NULL);
          INSERT INTO asset_label (asset_id, label) VALUES
            (10, 'red'), (15, 'blue'), (15, 'gray');
          """)
    }
    return (database, directory)
  }

  private func encodedTables(_ backup: CatalogBackup) throws -> [String: String] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let object = try JSONSerialization.jsonObject(with: encoder.encode(backup.tables))
    let tables = try #require(object as? [String: Any])
    return try tables.mapValues {
      String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]),
        as: UTF8.self)
    }
  }

  /// The fixture's backup with its JSON edited, as a file from elsewhere would be.
  private func editedBackup(
    _ backup: CatalogBackup, _ edit: (inout [String: Any]) throws -> Void
  ) throws -> Data {
    var object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
    try edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
  }

  @Test("create → restore into an empty catalog → create round-trips every table")
  func roundTrip() throws {
    let (source, sourceDirectory) = try makeFixtureCatalog()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let (target, targetDirectory) = try makeEmptyCatalog()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }

    let original = try CatalogBackups.create(from: source)
    for (name, count) in CatalogTableCounts(original.tables).tables {
      #expect(count >= 2, "fixture table \(name) has \(count) rows")
    }
    let data = try JSONEncoder().encode(original)
    let summary = try CatalogBackups.restore(try CatalogBackups.decode(data), into: target)
    #expect(summary == CatalogTableCounts(original.tables))
    #expect(summary.favorites == 2)

    let again = try CatalogBackups.create(from: target)
    #expect(again.schema == original.schema)
    #expect(again.migrations == original.migrations)
    let before = try encodedTables(original)
    let after = try encodedTables(again)
    #expect(before.keys.sorted() == after.keys.sorted())
    for key in before.keys.sorted() {
      #expect(before[key] == after[key], "table \(key) differs after restore")
    }
  }

  @Test("A catalog with a single tag row refuses, says how many, and is unchanged")
  func nonEmptyCatalogRefuses() throws {
    let (source, sourceDirectory) = try makeFixtureCatalog()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let (target, targetDirectory) = try makeEmptyCatalog()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }
    try target.write { try $0.execute(sql: "INSERT INTO tag (id, name) VALUES (40, 'mine')") }
    let before = try CatalogBackups.create(from: target)

    var expected = CatalogTableCounts()
    expected.tags = 1
    #expect(throws: CatalogRestoreError.catalogNotEmpty(expected)) {
      try CatalogBackups.restore(try CatalogBackups.create(from: source), into: target)
    }
    #expect(CatalogRestoreError.catalogNotEmpty(expected).description.contains("tag 1"))
    #expect(try encodedTables(CatalogBackups.create(from: target)) == encodedTables(before))
  }

  @Test("A dangling reference rolls the whole restore back")
  func danglingReferenceRollsBack() throws {
    let (source, sourceDirectory) = try makeFixtureCatalog()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let (target, targetDirectory) = try makeEmptyCatalog()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }

    let data = try editedBackup(try CatalogBackups.create(from: source)) { object in
      var tables = try #require(object["tables"] as? [String: Any])
      var assets = try #require(tables["assets"] as? [[String: Any]])
      assets[1]["backend_id"] = 999
      tables["assets"] = assets
      object["tables"] = tables
    }
    let backup = try CatalogBackups.decode(data)
    #expect {
      try CatalogBackups.restore(backup, into: target)
    } throws: { error in
      guard case .integrity(let detail) = error as? CatalogRestoreError else { return false }
      return detail.contains("asset")
    }
    #expect(try CatalogBackups.counts(in: target) == CatalogTableCounts())
    #expect(try CatalogBackups.counts(in: target).isEmpty)
  }

  /// A catalog with rows of its own, sharing ids with the fixture's.
  private func makeOccupiedCatalog() throws -> (database: DatabasePool, directory: URL) {
    let (database, directory) = try makeFixtureCatalog()
    try database.write { db in
      try db.execute(sql: "INSERT INTO tag (id, name) VALUES (40, 'mine')")
      try db.execute(sql: "UPDATE asset SET note = 'only here'")
    }
    return (database, directory)
  }

  @Test("replace: a catalog with rows of its own becomes exactly the backup, every table")
  func replaceRoundTrip() throws {
    let (source, sourceDirectory) = try makeFixtureCatalog()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let (target, targetDirectory) = try makeOccupiedCatalog()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }

    let original = try CatalogBackups.create(from: source)
    let confirmed = try CatalogBackups.counts(in: target)
    #expect(!confirmed.isEmpty)
    let summary = try CatalogBackups.replace(
      try CatalogBackups.decode(try JSONEncoder().encode(original)), into: target,
      confirmed: confirmed)
    #expect(summary == CatalogTableCounts(original.tables))
    let before = try encodedTables(original)
    let after = try encodedTables(try CatalogBackups.create(from: target))
    for key in before.keys.sorted() {
      #expect(before[key] == after[key], "table \(key) differs after replace")
    }
    #expect(try target.read { try String.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
  }

  @Test("replace: a catalog that changed since the user confirmed is refused, unchanged")
  func replaceRefusesChangedCatalog() throws {
    let (source, sourceDirectory) = try makeFixtureCatalog()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let (target, targetDirectory) = try makeOccupiedCatalog()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }

    let confirmed = try CatalogBackups.counts(in: target)
    try target.write { try $0.execute(sql: "INSERT INTO tag (id, name) VALUES (41, 'later')") }
    let before = try encodedTables(try CatalogBackups.create(from: target))
    let now = try CatalogBackups.counts(in: target)
    #expect(throws: CatalogRestoreError.catalogChanged(now)) {
      try CatalogBackups.replace(
        try CatalogBackups.create(from: source), into: target, confirmed: confirmed)
    }
    #expect(try encodedTables(try CatalogBackups.create(from: target)) == before)
  }

  @Test("replace: a dangling reference rolls back the clearing too — the old catalog is intact")
  func replaceRollsBack() throws {
    let (source, sourceDirectory) = try makeFixtureCatalog()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let (target, targetDirectory) = try makeOccupiedCatalog()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }

    let data = try editedBackup(try CatalogBackups.create(from: source)) { object in
      var tables = try #require(object["tables"] as? [String: Any])
      var assets = try #require(tables["assets"] as? [[String: Any]])
      assets[1]["backend_id"] = 999
      tables["assets"] = assets
      object["tables"] = tables
    }
    let before = try encodedTables(try CatalogBackups.create(from: target))
    let confirmed = try CatalogBackups.counts(in: target)
    #expect {
      try CatalogBackups.replace(try CatalogBackups.decode(data), into: target, confirmed: confirmed)
    } throws: { error in
      guard case .integrity = error as? CatalogRestoreError else { return false }
      return true
    }
    #expect(try encodedTables(try CatalogBackups.create(from: target)) == before)
  }

  @Test("Versions — unknown migration, schema, pre-v2 backups, v2 without keys")
  func versions() throws {
    let (source, sourceDirectory) = try makeFixtureCatalog()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let original = try CatalogBackups.create(from: source)

    let newer = try CatalogBackups.decode(
      try editedBackup(original) {
        $0["migrations"] = ["v1_initial", "v2_favorite_label", "v9_from_the_future"]
      })
    let schemaTwo = try CatalogBackups.decode(try editedBackup(original) { $0["schema"] = 2 })
    let notPrefix = try CatalogBackups.decode(
      try editedBackup(original) { $0["migrations"] = ["v2_favorite_label"] })
    for (backup, expected) in [
      (newer, CatalogRestoreError.newerVersion(unknownMigrations: ["v9_from_the_future"])),
      (schemaTwo, .unsupportedSchema(2)),
      (notPrefix, .incompatibleMigrations(["v2_favorite_label"])),
    ] {
      let (target, directory) = try makeEmptyCatalog()
      defer { try? FileManager.default.removeItem(at: directory) }
      #expect(throws: expected) { try CatalogBackups.validate(backup, for: target) }
      #expect(throws: expected) { try CatalogBackups.restore(backup, into: target) }
      #expect(try CatalogBackups.counts(in: target).isEmpty)
    }
    #expect(
      CatalogRestoreError.newerVersion(unknownMigrations: ["v9"]).description
        .contains("newer version of Pinax"))

    // Written before v2_favorite_label: neither key.
    let withoutKeys: (inout [String: Any]) throws -> Void = { object in
      var tables = try #require(object["tables"] as? [String: Any])
      tables["asset_favorites"] = nil
      tables["asset_labels"] = nil
      object["tables"] = tables
    }
    let old = try CatalogBackups.decode(
      try editedBackup(original) { object in
        try withoutKeys(&object)
        object["migrations"] = ["v1_initial"]
      })
    let (target, targetDirectory) = try makeEmptyCatalog()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }
    let summary = try CatalogBackups.restore(old, into: target)
    #expect(summary.assets == 3)
    #expect(summary.favorites == 0)
    #expect(summary.assetLabels == 0)

    // Claims v2 but lacks the keys: a format error, before any confirmation.
    #expect(throws: DecodingError.self) {
      try CatalogBackups.decode(try editedBackup(original, withoutKeys))
    }
  }
}
