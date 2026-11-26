import Foundation
import GRDB
import Testing

@testable import CatalogCore

/// A favorite is never an orphan candidate: not in the orphans report and not
/// in Overview's counts.
@Suite struct OrphansFavoriteTests {
  /// Project `blog` with two unused assets, `kept.png` (10 bytes, a favorite
  /// once marked) and `plain.png` (20 bytes).
  private func withCatalog(_ body: (DatabasePool) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-favorite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref,
             created_at, updated_at)
          VALUES
            (1, 'r2', 's3', 'https://storage.example.com', 'images', 'auto',
             'https://img.example.com', '', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO project (id, slug, name, key_prefix, backend_id, created_at, updated_at)
          VALUES (1, 'blog', 'Blog', 'blog', 1, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO asset
            (id, sha256, backend_id, key, byte_size, mime, state, pinned,
             uploaded_at, created_at, updated_at)
          VALUES
            (1, '\(String(repeating: "1", count: 64))', 1, 'blog/kept.png', 10, 'image/png',
             'active', 0, '2026-08-10T00:00:00Z', '2026-08-10T00:00:00Z',
             '2026-08-10T00:00:00Z'),
            (2, '\(String(repeating: "2", count: 64))', 1, 'blog/plain.png', 20, 'image/png',
             'active', 0, '2026-08-11T00:00:00Z', '2026-08-11T00:00:00Z',
             '2026-08-11T00:00:00Z');
          INSERT INTO asset_project (asset_id, project_id, added_at)
          VALUES (1, 1, '2026-08-10T00:00:00Z'), (2, 1, '2026-08-11T00:00:00Z');
          """)
    }
    try await body(database)
  }

  private func keys(_ project: String?, in database: DatabasePool) throws -> [String] {
    try CatalogUsage.orphans(project: project, in: database).assets.map(\.asset.key)
  }

  @Test("The orphans report leaves favorites out, for the catalog and for one project")
  func report() async throws {
    try await withCatalog { database in
      #expect(try keys(nil, in: database) == ["blog/kept.png", "blog/plain.png"])
      #expect(try keys("blog", in: database) == ["blog/kept.png", "blog/plain.png"])
      try await CatalogAssets.setFavorite(true, for: ["blog/kept.png"], in: database)
      #expect(try keys(nil, in: database) == ["blog/plain.png"])
      #expect(try keys("blog", in: database) == ["blog/plain.png"])
      try await CatalogAssets.setFavorite(false, for: ["blog/kept.png"], in: database)
      #expect(try keys(nil, in: database) == ["blog/kept.png", "blog/plain.png"])
    }
  }

  @Test("Overview's orphan counts leave favorites out, in total and per project")
  func overview() async throws {
    try await withCatalog { database in
      try await CatalogAssets.setFavorite(true, for: ["blog/kept.png"], in: database)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC")!
      for scope in [nil, "blog"] {
        let stats = try await CatalogStats.load(project: scope, calendar: calendar, in: database)
        #expect(stats.orphanCandidates.count == 1, "\(scope ?? "all")")
        #expect(stats.orphanCandidates.bytes == 20, "\(scope ?? "all")")
        #expect(stats.projects.map(\.orphanCandidates) == [1], "\(scope ?? "all")")
        #expect(stats.assets.count == 2)
        #expect(stats.favorites == 1)
      }
    }
  }
}
