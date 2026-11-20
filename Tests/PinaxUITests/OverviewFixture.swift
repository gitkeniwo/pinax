import CatalogCore
import Foundation
import GRDB

/// The Overview's fixture. Every date is absolute; the
/// page's "now" and calendar are injected (`now`, `calendar(firstWeekday:)`).
///
/// `now` is Tue 2026-10-06 12:00 UTC. The 53-week heat map ends with the week
/// holding `now`, so it starts Mon 2025-10-06 (weeks from Monday) or
/// Sun 2025-10-05 (weeks from Sunday).
///
/// index  uploaded (UTC)          projects     notes
///   0    2025-10-05 12:00        blog         outside 53 weeks from Mon; first day from Sun
///   1    2025-10-06 00:00        blog         first day from Mon, on the week boundary
///   2    2026-09-15 09:00        notes        tag travel
///   3    2026-09-28 10:00        blog         tag travel, favorite; used (current domain)
///   4    2026-10-04 12:00        blog, notes  tag cover; used by blog (old domain); a Sunday:
///                                             last week from Mon, this week from Sun
///   5    2026-10-05 00:00        blog         Monday 00:00, the week boundary
///   6    2026-10-05 08:00        —            image/jpeg on backend b2
///   7    2026-10-06 08:00        blog, notes  tags travel and cover: the one asset with two, so
///                                             tagged assets ≠ the sum of tag counts
///   8    2026-10-06 09:00        blog         archived, tag cover
///   9    2025-03-10 10:00        notes        image/jpeg
///  10–11 2026-09-15 10:00        —            Sep 15: 3 uploads (with 2)
///  12–16 2026-08-20 10:00        —            Aug 20: 5 uploads
///  17–24 2026-07-01 10:00        —            Jul 1: 8 uploads
///
/// Byte sizes are 1000 + index (`seedAsset`). Blog's latest scan (two
/// completed) references 3 on the current prefix, 4 on the retired
/// `https://old-img.example.com`, and three unmatched URLs: two on your
/// domains (current and retired prefix), one elsewhere. Notes is never
/// scanned.
enum OverviewFixture {
  static let now = date("2026-10-06T12:00:00Z")

  static func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  static func calendar(
    firstWeekday: Int, timeZone: TimeZone = TimeZone(identifier: "UTC")!
  ) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.firstWeekday = firstWeekday
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  static let uploads: [(index: Int, at: String, project: String?, tag: String?)] = [
    (0, "2025-10-05T12:00:00Z", "blog", nil),
    (1, "2025-10-06T00:00:00Z", "blog", nil),
    (2, "2026-09-15T09:00:00Z", "notes", "travel"),
    (3, "2026-09-28T10:00:00Z", "blog", "travel"),
    (4, "2026-10-04T12:00:00Z", "blog", "cover"),
    (5, "2026-10-05T00:00:00Z", "blog", nil),
    (6, "2026-10-05T08:00:00Z", nil, nil),
    (7, "2026-10-06T08:00:00Z", "blog", "travel"),
    (8, "2026-10-06T09:00:00Z", "blog", "cover"),
    (9, "2025-03-10T10:00:00Z", "notes", nil),
  ]
    + (10...11).map { ($0, "2026-09-15T10:00:00Z", nil, nil) }
    + (12...16).map { ($0, "2026-08-20T10:00:00Z", nil, nil) }
    + (17...24).map { ($0, "2026-07-01T10:00:00Z", nil, nil) }

  static func seed(_ database: DatabasePool) async throws {
    for upload in uploads {
      try seedAsset(
        database, index: upload.index, uploadedAt: upload.at, projectSlug: upload.project,
        tag: upload.tag)
    }
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          VALUES (2, 'b2', 's3', 'https://b2.example.com', 'images', 'auto',
                  'https://b2-img.example.com', 'backend.b2', '{}',
                  '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO backend_prefix_history (backend_id, url_prefix, retired_at)
          VALUES (1, 'https://old-img.example.com', '2026-01-01T00:00:00Z');
          UPDATE asset SET mime = 'image/jpeg', backend_id = 2 WHERE key = 'x/asset-6.png';
          UPDATE asset SET mime = 'image/jpeg' WHERE key = 'notes/asset-9.png';
          UPDATE asset SET favorite = 1 WHERE key = 'blog/asset-3.png';
          UPDATE asset SET state = 'archived' WHERE key = 'blog/asset-8.png';
          INSERT INTO asset_project (asset_id, project_id, added_at)
          SELECT id, 2, '2026-10-06T08:00:00Z' FROM asset
          WHERE key IN ('blog/asset-4.png', 'blog/asset-7.png');
          INSERT INTO asset_tag (asset_id, tag_id)
          SELECT asset.id, tag.id FROM asset, tag
          WHERE asset.key = 'blog/asset-7.png' AND tag.name = 'cover';
          """)
    }
    let document = UsageDocument(
      project: "blog",
      refs: [
        "https://img.example.com/blog/asset-3.png",
        "https://old-img.example.com/blog/asset-4.png",
        "https://img.example.com/blog/missing.png",
        "https://old-img.example.com/blog/gone.png",
        "https://cdn.other.org/x.png",
      ].map { UsageReference(rawURL: $0, sourceReference: "post.md") })
    for second in [0, 60] {
      _ = try CatalogUsage.sync(
        document, project: "blog", in: database,
        now: date("2026-10-06T10:00:00Z").addingTimeInterval(Double(second)))
    }
  }

  static func withDatabase(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(database)
    try await body(database)
  }
}
