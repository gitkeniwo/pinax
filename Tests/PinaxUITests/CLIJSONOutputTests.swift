import CatalogCore
import Foundation
import GRDB
import Testing

/// `--format json` on the read commands, run as the built binary: standard
/// output is parsed and compared with values written out by hand. A missing
/// value must be present as `null`.
@Suite struct CLIJSONOutputTests {
  private let first = String(format: "%064x", 1)
  private let second = String(format: "%064x", 2)

  private func withFixture(_ body: (DatabasePool, URL) throws -> Void) throws {
    let (database, directory) = try makeCLITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(database, directory)
  }

  private func object(_ text: String) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
  }

  /// Runs `arguments --format json`, expecting success and a quiet stderr.
  private func json(_ arguments: [String], in directory: URL) throws -> NSDictionary {
    let result = try CLIProcess.run(arguments + ["--format", "json"], in: directory)
    #expect(result.status == 0, "\(result.stderr)")
    #expect(result.stderr.isEmpty)
    return try object(result.stdout)
  }

  private func expect(_ document: NSDictionary, _ expected: [String: Any]) {
    #expect(document == expected as NSDictionary)
  }

  @Test("show")
  func show() throws {
    try withFixture { _, directory in
      let full = try json(["show", first], in: directory)
      expect(
        full,
        [
          "schema": "pinax.asset.v1",
          "asset": [
            "id": 1, "sha256": first, "backend": "r2", "key": "blog/asset-0.png",
            "url": "https://img.example.com/blog/asset-0.png", "bytes": 1000,
            "width": 800, "height": 600, "mime": "image/png",
            "original_filename": "asset-0.png", "state": "active", "pinned": false,
            "favorite": false, "labels": [String](), "source": "pinax",
            "note": "hello", "meta": "{}", "uploaded_at": "2026-08-01T00:00:00Z",
            "created_at": "2026-08-01T00:00:00Z", "updated_at": "2026-08-01T00:00:00Z",
            "tags": ["cats"],
            "projects": [["slug": "blog", "name": "Blog", "live_usage": 1]],
          ] as [String: Any],
        ])
      let sparse = try #require(try json(["show", second], in: directory)["asset"] as? [String: Any])
      for key in ["width", "height", "original_filename", "note"] {
        #expect(sparse[key] is NSNull, "\(key)")
      }
    }
  }

  @Test("note show")
  func note() throws {
    try withFixture { _, directory in
      expect(
        try json(["note", "show", first], in: directory),
        [
          "schema": "pinax.note.v1", "sha256": first, "key": "blog/asset-0.png", "note": "hello",
        ])
      expect(
        try json(["note", "show", second], in: directory),
        [
          "schema": "pinax.note.v1", "sha256": second, "key": "blog/asset-1.png",
          "note": NSNull(),
        ])
    }
  }

  @Test("project ls")
  func projects() throws {
    try withFixture { database, directory in
      try database.write { db in
        try db.execute(
          sql: """
            UPDATE project SET backend_id = NULL, key_template = '{sha256}.{ext}'
            WHERE slug = 'notes'
            """)
      }
      expect(
        try json(["project", "ls"], in: directory),
        [
          "schema": "pinax.projects.v1",
          "projects": [
            [
              "slug": "blog", "name": "Blog", "key_prefix": "blog", "key_template": NSNull(),
              "backend": "r2",
            ] as [String: Any],
            [
              "slug": "notes", "name": "Notes", "key_prefix": "notes",
              "key_template": "{sha256}.{ext}", "backend": NSNull(),
            ] as [String: Any],
          ],
        ])
    }
  }

  @Test("backend ls and show say nothing about credentials")
  func backends() throws {
    try withFixture { database, directory in
      try database.write { db in
        try db.execute(sql: "UPDATE backend SET keychain_ref = 'backend.r2'")
      }
      let record = [
        "slug": "r2", "kind": "s3", "endpoint": "http://127.0.0.1:9", "bucket": "images",
        "region": "auto", "url_prefix": "https://img.example.com",
      ]
      expect(
        try json(["backend", "ls"], in: directory),
        ["schema": "pinax.backends.v1", "backends": [record]])
      expect(
        try json(["backend", "show", "r2"], in: directory),
        ["schema": "pinax.backend.v1", "backend": record, "url_prefix_links": 2])
    }
  }

  @Test("orphans keeps its notes on standard error")
  func orphans() throws {
    try withFixture { _, directory in
      let table = try CLIProcess.run(["orphans"], in: directory)
      let result = try CLIProcess.run(["orphans", "--format", "json"], in: directory)
      #expect(result.status == 0)
      #expect(result.stderr == table.stderr)
      #expect(table.stdout.hasPrefix("SHA256\tKEY\tURL\n"))
      expect(
        try object(result.stdout),
        [
          "schema": "pinax.orphans.v1", "project": NSNull(), "minimum_scans": 2,
          "assets": [
            [
              "sha256": second, "key": "blog/asset-1.png",
              "url": "https://img.example.com/blog/asset-1.png", "width": NSNull(),
              "height": NSNull(), "bytes": 1001, "mime": "image/png",
              "filename": "blog/asset-1.png", "uploaded_at": "2026-08-02T00:00:00Z",
              "projects": ["blog"],
            ] as [String: Any]
          ],
          "untracked": [
            [
              "sha256": String(format: "%064x", 3), "key": "notes/asset-2.png",
              "url": "https://img.example.com/notes/asset-2.png", "width": 800, "height": 600,
              "bytes": 1002, "mime": "image/png", "filename": "asset-2.png",
              "uploaded_at": "2026-08-03T00:00:00Z", "projects": ["notes"],
            ] as [String: Any]
          ],
          "untracked_projects": ["notes"], "unscanned_projects": [String](),
        ])
    }
  }

  @Test("externals, in the table's order")
  func externals() throws {
    try withFixture { _, directory in
      func item(_ line: Int, _ url: String, _ domain: String, _ match: Any) -> [String: Any] {
        [
          "project": "blog", "kind": "markdown", "source_ref": "site/a.md#L\(line)",
          "raw_url": url, "domain": domain, "match": match,
        ]
      }
      let items = [
        item(
          2, "https://img.example.com/blog/gone.png", "yours",
          ["backend": "r2", "prefix": "https://img.example.com", "current": true]),
        item(
          3, "https://old.example.com/blog/missing.png", "yours",
          ["backend": "r2", "prefix": "https://old.example.com", "current": false]),
        item(4, "https://elsewhere.example.org/x.png", "other", NSNull()),
      ]
      expect(
        try json(["externals"], in: directory),
        ["schema": "pinax.externals.v1", "project": NSNull(), "items": items])
      expect(
        try json(["externals", "list", "--project", "notes"], in: directory),
        ["schema": "pinax.externals.v1", "project": "notes", "items": [Any]()])
      let table = try CLIProcess.run(["externals"], in: directory)
      #expect(
        table.stdout.split(separator: "\n").dropFirst().map {
          String($0.split(separator: "\t").last!)
        } == items.map { $0["raw_url"] as! String })
    }
  }

  @Test("doctor is its report, warnings included")
  func doctor() throws {
    try withFixture { database, directory in
      // Two asset rows for one object is a warning.
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO backend
              (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
               created_at, updated_at)
            SELECT 2, 'again', kind, endpoint, bucket, region, url_prefix, '', meta,
              created_at, updated_at FROM backend WHERE id = 1;
            INSERT INTO asset
              (sha256, backend_id, key, byte_size, mime, uploaded_at, created_at, updated_at)
            SELECT sha256, 2, key, byte_size, mime, uploaded_at, created_at, updated_at
              FROM asset WHERE id = 1;
            """)
      }
      let table = try CLIProcess.run(["doctor"], in: directory)
      let document = try json(["doctor"], in: directory)
      #expect(document["schema"] as? Int == 1)
      let checks = try #require(document["checks"] as? [[String: String]])
      for check in checks {
        #expect(Set(check.keys) == ["name", "status", "detail"])
      }
      #expect(checks.contains { $0["status"] == "warning" })
      #expect(!table.stderr.isEmpty)
      let lines = (table.stdout + table.stderr).split(separator: "\n")
      #expect(checks.count == lines.count)
    }
  }

  @Test("restore reports the tables and the follow-ups")
  func restore() throws {
    try withFixture { _, directory in
      let file = directory.appendingPathComponent("backup.json").path
      #expect(try CLIProcess.run(["backup", "-o", file], in: directory).status == 0)
      let target = directory.appendingPathComponent("target/catalog.sqlite")
      try FileManager.default.removeItem(at: directory.appendingPathComponent("site"))
      let result = try CLIProcess.run(
        ["restore", file, "--format", "json"], in: directory,
        environment: ["PINAX_DB": target.path])
      #expect(result.status == 0, "\(result.stderr)")
      #expect(result.stderr.isEmpty)
      expect(
        try object(result.stdout),
        [
          "schema": "pinax.restore.v1",
          "tables": [
            "backend": 1, "backend_prefix_history": 1, "asset": 3, "project": 2,
            "asset_project": 3, "tag": 1, "asset_tag": 1, "scan": 2, "usage": 4,
            "asset_label": 0,
          ],
          "favorites": 0,
          "backends_without_credentials": ["r2"],
          "projects_with_missing_sources": [
            [
              "project": "blog", "name": "Blog",
              "paths": [directory.appendingPathComponent("site").path],
            ] as [String: Any]
          ],
        ])
    }
  }
}
