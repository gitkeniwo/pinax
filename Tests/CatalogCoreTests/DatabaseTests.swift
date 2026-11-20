import Foundation
import GRDB
import Testing

@testable import CatalogCore

@Test("DB location honors PINAX_DB and creates parent directories")
func databaseLocationEnvironmentOverride() throws {
  try withTemporaryDirectory { root in
    let expected = root.appendingPathComponent("nested/catalog.sqlite")

    let actual = try DBLocation.resolve(
      environment: ["PINAX_DB": expected.path],
      homeDirectory: root
    )

    #expect(actual == expected.standardizedFileURL)
    var isDirectory: ObjCBool = false
    #expect(
      FileManager.default.fileExists(
        atPath: expected.deletingLastPathComponent().path,
        isDirectory: &isDirectory
      ))
    #expect(isDirectory.boolValue)
  }
}

@Test("DB location uses the application support default")
func databaseLocationDefault() throws {
  try withTemporaryDirectory { home in
    let actual = try DBLocation.resolve(environment: [:], homeDirectory: home)

    #expect(
      actual
        == home.appendingPathComponent(
          "Library/Application Support/tech.gitkeniwo.pinax/catalog.sqlite"
        ))
  }
}

@Test("DB location refuses a new catalog in synced storage without creating directories")
func databaseLocationRejectsSyncedCreation() throws {
  try withTemporaryDirectory { home in
    let databaseURL = home.appendingPathComponent("Dropbox/pinax/catalog.sqlite")

    #expect(throws: DatabaseLocationError.self) {
      try DBLocation.resolve(
        environment: ["PINAX_DB": databaseURL.path],
        homeDirectory: home
      )
    }
    #expect(!FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path))
  }
}

@Test("Existing synced catalog returns a typed location warning")
func existingSyncedDatabaseReturnsWarning() throws {
  try withTemporaryDirectory { home in
    let databaseURL = home.appendingPathComponent("Dropbox/pinax/catalog.sqlite")
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: databaseURL.path, contents: Data()))

    let warning = try DatabasePathSafety.prepareToOpen(
      at: databaseURL,
      homeDirectory: home
    )
    let problem = try #require(DatabasePathSafety.problem(at: databaseURL, homeDirectory: home))
    #expect(warning == .unsafeExistingDatabase(problem: problem))
  }
}

@Test("Migrating twice applies the initial migration once")
func migrationIsIdempotent() throws {
  try withDatabase(migrated: false) { database in
    try CatalogCore.Database.migrate(database)
    try CatalogCore.Database.migrate(database)

    let migrationCount = try database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v1_initial'"
      )
    }
    #expect(migrationCount == 1)
  }
}

@Test("Database pool uses WAL and enforces foreign keys")
func databaseConfiguration() throws {
  try withDatabase { database in
    let settings = try database.read { db in
      (
        try String.fetchOne(db, sql: "PRAGMA journal_mode"),
        try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
      )
    }

    #expect(settings.0 == "wal")
    #expect(settings.1 == 1)
  }
}

@Test("Usage rejects a missing project")
func usageForeignKey() throws {
  try withDatabase { database in
    #expect(throws: (any Error).self) {
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO usage (
              project_id, raw_url, source_ref, first_seen, last_seen
            ) VALUES (
              999, 'https://example.com/image.png', 'post.md#L1',
              '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z'
            )
            """)
      }
    }
  }
}

@Test("Live usage includes only assets from the project's latest completed scan")
func liveUsageTracksProjectLastScan() throws {
  try withDatabase { database in
    try database.write { db in
      try insertBackendAssetAndProject(db)
      try db.execute(
        sql: """
          INSERT INTO scan (id, project_id, started_at, finished_at)
          VALUES (
            1, 1, '2026-08-20T00:00:00Z', '2026-08-20T00:00:01Z'
          );

          INSERT INTO usage (
            id, project_id, asset_id, raw_url, source_ref,
            first_seen, last_seen, last_scan_id
          ) VALUES (
            1, 1, 1, 'https://img.example.com/blog/image.png', 'post.md#L1',
            '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z', 1
          );

          INSERT INTO usage (
            id, project_id, asset_id, raw_url, source_ref,
            first_seen, last_seen, last_scan_id
          ) VALUES (
            2, 1, NULL, 'https://external.example.com/image.png', 'post.md#L2',
            '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z', 1
          );
          """)
    }

    let beforeCompletion = try database.read { db in
      try AssetLiveUsage.fetchAll(db, sql: "SELECT * FROM asset_live_usage")
    }
    #expect(beforeCompletion.isEmpty)

    try database.write { db in
      try db.execute(sql: "UPDATE project SET last_scan_id = 1 WHERE id = 1")
    }
    let live = try database.read { db in
      try AssetLiveUsage.fetchAll(db, sql: "SELECT * FROM asset_live_usage")
    }
    #expect(live.count == 1)
    #expect(live.first?.assetID == 1)
    #expect(live.first?.projectID == 1)
    #expect(live.first?.count == 1)

    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO scan (id, project_id, started_at, finished_at)
          VALUES (
            2, 1, '2026-08-21T00:00:00Z', '2026-08-21T00:00:01Z'
          );
          UPDATE project SET last_scan_id = 2 WHERE id = 1;
          """)
    }
    let afterNewerScan = try database.read { db in
      try AssetLiveUsage.fetchAll(db, sql: "SELECT * FROM asset_live_usage")
    }
    #expect(afterNewerScan.isEmpty)
  }
}

@Test("Deleting a project cascades references but retains the asset")
func projectDeleteCascade() throws {
  try withDatabase { database in
    try database.write { db in
      try insertBackendAssetAndProject(db)
      try db.execute(
        sql: """
          INSERT INTO asset_project (asset_id, project_id, added_at)
          VALUES (1, 1, '2026-08-20T00:00:00Z');

          INSERT INTO scan (id, project_id, started_at, finished_at)
          VALUES (
            1, 1, '2026-08-20T00:00:00Z', '2026-08-20T00:00:01Z'
          );

          UPDATE project SET last_scan_id = 1 WHERE id = 1;

          INSERT INTO usage (
            id, project_id, asset_id, raw_url, source_ref,
            first_seen, last_seen, last_scan_id
          ) VALUES (
            1, 1, 1, 'https://img.example.com/blog/image.png', 'post.md#L1',
            '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z', 1
          );

          DELETE FROM project WHERE id = 1;
          """)
    }

    let counts = try database.read { db in
      (
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_project"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
      )
    }
    #expect(counts.0 == 0)
    #expect(counts.1 == 0)
    #expect(counts.2 == 0)
    #expect(counts.3 == 1)

    let foreignKeyViolations = try database.read { db in
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
    }
    #expect(foreignKeyViolations.isEmpty)
  }
}

private func withDatabase(
  migrated: Bool = true,
  _ body: (DatabasePool) throws -> Void
) throws {
  try withTemporaryDirectory { directory in
    let database = try CatalogCore.Database.open(
      at: directory.appendingPathComponent("catalog.sqlite")
    )
    if migrated {
      try CatalogCore.Database.migrate(database)
    }
    try body(database)
  }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func insertBackendAssetAndProject(_ db: GRDB.Database) throws {
  try db.execute(
    sql: """
      INSERT INTO backend (
        id, slug, kind, endpoint, bucket, url_prefix, keychain_ref,
        created_at, updated_at
      ) VALUES (
        1, 'r2', 's3', 'https://example.r2.cloudflarestorage.com', 'images',
        'https://img.example.com', 'r2',
        '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z'
      );

      INSERT INTO asset (
        id, sha256, backend_id, key, byte_size, mime,
        uploaded_at, created_at, updated_at
      ) VALUES (
        1, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        1, 'blog/image.png', 100, 'image/png',
        '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z',
        '2026-08-20T00:00:00Z'
      );

      INSERT INTO project (
        id, slug, name, backend_id, created_at, updated_at
      ) VALUES (
        1, 'blog', 'Blog', 1,
        '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z'
      );
      """)
}
