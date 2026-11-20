import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// `CatalogStats.load` on 5,000 assets, and Show in Library's
/// paging on the same catalog. A measurement, not a
/// property: it runs only with `PINAX_MEASURE=1` and prints its numbers.
@MainActor
@Suite("Overview timing", .enabled(if: ProcessInfo.processInfo.environment["PINAX_MEASURE"] != nil))
struct OverviewTimingTests {
  nonisolated static let assetCount = 5_000

  /// 5,000 assets over two years (one in fifty archived, one in ten a
  /// favorite), four projects, twenty tags on half of them, two backends;
  /// two projects scanned twice, 1,600 references between them.
  static func seed(_ database: DatabasePool) async throws {
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          VALUES (2, 'b2', 's3', 'https://b2.example.com', 'images', 'auto',
                  'https://b2-img.example.com', 'backend.b2', '{}',
                  '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO project
            (id, slug, name, key_prefix, backend_id, last_scan_id, created_at, updated_at)
          VALUES (3, 'social', 'Social', 'social', 1, NULL, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
                 (4, 'docs', 'Docs', 'docs', 1, NULL, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          """)
      for tag in 0..<20 {
        try db.execute(sql: "INSERT INTO tag (id, name) VALUES (?, ?)", arguments: [tag + 1, "tag-\(tag)"])
      }
      let start = OverviewFixture.date("2024-10-06T00:00:00Z").timeIntervalSince1970
      let formatter = ISO8601DateFormatter()
      for index in 0..<assetCount {
        let at = formatter.string(
          from: Date(timeIntervalSince1970: start + Double(index) * 730 * 86_400 / Double(assetCount)))
        let project = index % 4 + 1
        let slug = ["blog", "notes", "social", "docs"][index % 4]
        try db.execute(
          sql: """
            INSERT INTO asset
              (id, sha256, backend_id, key, byte_size, mime, state, favorite,
               uploaded_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            index + 1, String(format: "%064x", index + 1), index % 7 == 0 ? 2 : 1,
            "\(slug)/asset-\(index).png", 10_000 + index, index % 3 == 0 ? "image/jpeg" : "image/png",
            index % 50 == 0 ? "archived" : "active", index % 10 == 0 ? 1 : 0, at, at, at,
          ])
        try db.execute(
          sql: "INSERT INTO asset_project (asset_id, project_id, added_at) VALUES (?, ?, ?)",
          arguments: [index + 1, project, at])
        if index % 2 == 0 {
          try db.execute(
            sql: "INSERT INTO asset_tag (asset_id, tag_id) VALUES (?, ?)",
            arguments: [index + 1, index % 20 + 1])
        }
      }
    }
    for (slug, residue) in [("blog", 0), ("notes", 1)] {
      let refs = stride(from: residue, to: 3_200, by: 4).map {
        UsageReference(
          rawURL: "https://img.example.com/\(slug)/asset-\($0).png", sourceReference: "p\($0 % 90).md")
      } + (0..<400).map {
        UsageReference(rawURL: "https://cdn.other.org/\(slug)-\($0).png", sourceReference: "p.md")
      }
      for second in [0, 60] {
        _ = try CatalogUsage.sync(
          UsageDocument(project: slug, refs: refs), project: slug, in: database,
          now: OverviewFixture.date("2026-10-06T10:00:00Z").addingTimeInterval(Double(second)))
      }
    }
  }

  static func milliseconds(_ body: () async throws -> Void) async rethrows -> Double {
    let clock = ContinuousClock()
    let elapsed = try await clock.measure { try await body() }
    return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
  }

  @Test("CatalogStats.load on 5,000 assets, and Show in Library on the oldest")
  func measure() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await Self.seed(database)
    let calendar = OverviewFixture.calendar(firstWeekday: 2)

    var all: [Double] = []
    var blog: [Double] = []
    for _ in 0..<7 {
      all.append(try await Self.milliseconds { _ = try await CatalogStats.load(calendar: calendar, in: database) })
      blog.append(
        try await Self.milliseconds {
          _ = try await CatalogStats.load(project: "blog", calendar: calendar, in: database)
        })
    }
    let stats = try await CatalogStats.load(calendar: calendar, in: database)
    print(
      "PINAX_MEASURE CatalogStats.load All Projects ms:", all.map { ($0 * 10).rounded() / 10 },
      "median", all.sorted()[3])
    print(
      "PINAX_MEASURE CatalogStats.load blog ms:", blog.map { ($0 * 10).rounded() / 10 },
      "median", blog.sorted()[3])
    print(
      "PINAX_MEASURE fixture: assets", stats.assets.count, "archived", stats.archived, "used",
      stats.usedImages, "orphans", stats.orphanCandidates.count, "days", stats.uploadsByDay.count)

    // Show in Library pages All Assets until the asset is loaded.
    // The oldest active asset is on the last page (newest first).
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try #require(UserDefaults(suiteName: "pinaxui-t09-\(UUID().uuidString)")),
      databaseOpener: { database },
      chooseSourceFolder: { _ in nil })
    await app.start()
    let gallery = try #require(app.gallery)
    var library: [Double] = []
    for _ in 0..<3 {
      gallery.select(.usage, in: .reports)
      library.append(try await Self.milliseconds { await gallery.showInLibrary(assetID: 2) })
      #expect(gallery.selectedIDs == [2])
    }
    print(
      "PINAX_MEASURE showInLibrary oldest ms:", library.map { $0.rounded() }, "rows loaded",
      gallery.rows.count)
  }
}
