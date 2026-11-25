import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `pinax ls`, run as the built binary. In upload order:
///   zebra  blog, tag `cats`, favorite, red and blue, with a note
///   apple  blog, from PicGo
///   mango  notes, backend `alt`, from a bucket import
///   old    blog, archived
@Suite struct AssetListCommandTests {
  private let zebra = "blog/2026/zebra.png"
  private let apple = "blog/2026-extra/apple.jpg"
  private let mango = "notes/mango.gif"
  private let old = "blog/2026/old.png"

  private func withFixture(_ body: (DatabasePool, URL) throws -> Void) throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(
      database, index: 0, uploadedAt: "2026-07-10T00:00:00Z", origFilename: "Zebra.png",
      tag: "cats", key: zebra)
    try seedAsset(
      database, index: 1, uploadedAt: "2026-08-01T00:00:00Z", origFilename: "apple.jpg",
      key: apple, meta: #"{"imported_from":"picgo"}"#)
    try seedAsset(
      database, index: 2, uploadedAt: "2026-08-15T12:00:00Z", origFilename: "mango.gif",
      projectSlug: "notes", key: mango, meta: #"{"imported_from":"bucket"}"#)
    try seedAsset(
      database, index: 3, uploadedAt: "2026-08-20T00:00:00Z", origFilename: "old.png",
      key: old)
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          SELECT 2, 'alt', kind, endpoint, bucket, region, 'https://alt.example.com', '', meta,
            created_at, updated_at FROM backend WHERE id = 1;
          UPDATE asset SET favorite = 1, note = 'A sunny Day', byte_size = 20 WHERE id = 1;
          UPDATE asset SET mime = 'image/jpeg', byte_size = 40 WHERE id = 2;
          UPDATE asset SET mime = 'image/gif', byte_size = 30, backend_id = 2,
            width = NULL, height = NULL WHERE id = 3;
          UPDATE asset SET state = 'archived', byte_size = 10 WHERE id = 4;
          INSERT INTO asset_label (asset_id, label) VALUES (1, 'blue'), (1, 'red'), (2, 'green');
          """)
    }
    try body(database, directory)
  }

  /// The KEY column of the table, which `arguments` must succeed in printing.
  private func keys(_ arguments: [String], in directory: URL) throws -> [String] {
    let result = try CLIProcess.run(["ls"] + arguments, in: directory)
    #expect(result.status == 0, "\(arguments): \(result.stderr)")
    let lines = result.stdout.split(separator: "\n")
    #expect(lines.first == "SHA256\tSTATE\tBYTES\tKEY\tURL")
    return lines.dropFirst().map { String($0.split(separator: "\t")[3]) }
  }

  private func expectKeys(
    _ arguments: [String], _ expected: [String], in directory: URL,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let listed = try keys(arguments, in: directory)
    #expect(listed == expected, "\(arguments)", sourceLocation: sourceLocation)
  }

  private func document(_ arguments: [String], in directory: URL) throws -> [String: Any] {
    let result = try CLIProcess.run(["ls"] + arguments + ["--format", "json"], in: directory)
    #expect(result.status == 0, "\(result.stderr)")
    #expect(result.stderr.isEmpty)
    return try #require(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
  }

  @Test("Only active assets are listed unless --state says otherwise")
  func state() throws {
    try withFixture { _, directory in
      try expectKeys([], [mango, apple, zebra], in: directory)
      try expectKeys(["--state", "active"], [mango, apple, zebra], in: directory)
      try expectKeys(["--state", "archived"], [old], in: directory)
      try expectKeys(["--state", "all"], [old, mango, apple, zebra], in: directory)
      let urls = try CLIProcess.run(["ls", "--format", "url"], in: directory)
      #expect(
        urls.stdout == """
          https://alt.example.com/notes/mango.gif
          https://img.example.com/blog/2026-extra/apple.jpg
          https://img.example.com/blog/2026/zebra.png

          """)
    }
  }

  @Test("--project, --tag, --backend, --favorites, --label, --source")
  func filters() throws {
    try withFixture { _, directory in
      try expectKeys(["--project", "notes"], [mango], in: directory)
      try expectKeys(["--tag", "cats"], [zebra], in: directory)
      try expectKeys(["--backend", "alt"], [mango], in: directory)
      try expectKeys(["--backend", "r2"], [apple, zebra], in: directory)
      try expectKeys(["--favorites"], [zebra], in: directory)
      try expectKeys(["--label", "blue"], [zebra], in: directory)
      try expectKeys(["--label", "gray"], [], in: directory)
      try expectKeys(["--source", "picgo"], [apple], in: directory)
      try expectKeys(["--source", "picgo", "--source", "bucket"], [mango, apple], in: directory)
      try expectKeys(["--source", "pinax"], [zebra], in: directory)
    }
  }

  @Test("--since is inclusive and --until exclusive, in all three spellings")
  func dates() throws {
    try withFixture { _, directory in
      try expectKeys(["--since", "2026-08"], [mango, apple], in: directory)
      try expectKeys(["--until", "2026-08"], [zebra], in: directory)
      try expectKeys(["--until", "2026-08-15"], [apple, zebra], in: directory)
      try expectKeys(["--until", "2026-08-15T12:00:01Z"], [mango, apple, zebra], in: directory)
      try expectKeys(["--since", "2026-07-11", "--until", "2026-08-02"], [apple], in: directory)
    }
  }

  @Test("--search with --search-field, --match, --case-sensitive")
  func search() throws {
    try withFixture { _, directory in
      try expectKeys(["--search", "sunny"], [zebra], in: directory)
      try expectKeys(["--search", "sunny", "--search-field", "note"], [zebra], in: directory)
      try expectKeys(["--search", "sunny", "--search-field", "key"], [], in: directory)
      try expectKeys(["--search", "extra", "--search-field", "key"], [apple], in: directory)
      try expectKeys(["--search", "extra", "--search-field", "filename"], [], in: directory)
      let name = ["--search-field", "filename"]
      try expectKeys(name + ["--search", "an"], [mango], in: directory)
      try expectKeys(name + ["--search", "an", "--match", "begins"], [], in: directory)
      try expectKeys(name + ["--search", "ma", "--match", "begins"], [mango], in: directory)
      try expectKeys(name + ["--search", ".png", "--match", "ends"], [zebra], in: directory)
      try expectKeys(name + ["--search", "mango", "--match", "matches"], [], in: directory)
      try expectKeys(name + ["--search", "mango.gif", "--match", "matches"], [mango], in: directory)
      try expectKeys(name + ["--search", "zebra"], [zebra], in: directory)
      try expectKeys(name + ["--search", "zebra", "--case-sensitive"], [], in: directory)
      try expectKeys(name + ["--search", "Zebra", "--case-sensitive"], [zebra], in: directory)
    }
  }

  @Test("--key-prefix takes whole path segments")
  func keyPrefix() throws {
    try withFixture { _, directory in
      try expectKeys(["--key-prefix", "blog/2026"], [zebra], in: directory)
      try expectKeys(["--key-prefix", "/blog/2026/"], [zebra], in: directory)
      try expectKeys(["--key-prefix", "blog"], [apple, zebra], in: directory)
    }
  }

  @Test("--sort, --asc, --desc")
  func sorting() throws {
    try withFixture { _, directory in
      try expectKeys(["--asc"], [zebra, apple, mango], in: directory)
      try expectKeys(["--sort", "name", "--asc"], [apple, mango, zebra], in: directory)
      try expectKeys(["--sort", "name"], [zebra, mango, apple], in: directory)
      try expectKeys(["--sort", "size", "--desc"], [apple, mango, zebra], in: directory)
      try expectKeys(["--sort", "kind", "--asc"], [mango, apple, zebra], in: directory)
      try expectKeys(["--sort", "uploaded", "--desc"], [mango, apple, zebra], in: directory)
    }
  }

  // By kind, a page of three ends between the two PNGs.
  @Test(
    "Two pages through the cursor are the whole list",
    arguments: [("uploaded", 2), ("name", 2), ("size", 2), ("kind", 3)])
  func cursor(sort: String, limit: Int) throws {
    try withFixture { _, directory in
      let order = ["--state", "all", "--sort", sort, "--asc"]
      let all = try keys(order, in: directory)
      #expect(all.count == 4)
      let size = ["--limit", String(limit)]
      let first = try document(order + size, in: directory)
      let next = try #require(first["next"] as? String)
      let second = try document(order + size + ["--after", next], in: directory)
      #expect(second["next"] is NSNull)
      let paged = [first, second].flatMap { page in
        (page["assets"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
      }
      #expect(paged == all)
      // The same cursor continues the table.
      try expectKeys(order + ["--after", next], Array(all.dropFirst(limit)), in: directory)
    }
  }

  @Test("A bad argument is 64, an unknown backend 66")
  func badArguments() throws {
    try withFixture { _, directory in
      let next = try #require(
        try document(["--limit", "1"], in: directory)["next"] as? String)
      for arguments in [
        ["--after", "nonsense"], ["--after", next, "--sort", "name"],
        ["--after", next, "--asc"], ["--until", "yesterday"], ["--key-prefix", "/"],
        ["--asc", "--desc"], ["--state", "gone"], ["--label", "pink"], ["--source", "web"],
      ] {
        let result = try CLIProcess.run(["ls"] + arguments, in: directory)
        #expect(result.status == 64, "\(arguments): \(result.stderr)")
        #expect(result.stdout.isEmpty)
      }
      let backend = try CLIProcess.run(["ls", "--backend", "nope"], in: directory)
      #expect(backend.status == 66)
      #expect(backend.stderr == "Error: Backend 'nope' does not exist.\n")
      try expectKeys(["--limit", String(Int.max)], [mango, apple, zebra], in: directory)
    }
  }

  @Test("JSON carries each asset's catalog fields, with null for what is missing")
  func json() throws {
    try withFixture { _, directory in
      let page = try document(["--source", "pinax", "--source", "bucket"], in: directory)
      let expected: [String: Any] = [
        "schema": "pinax.list.v1",
        "next": NSNull(),
        "assets": [
          [
            "id": 3, "sha256": String(format: "%064x", 3), "backend": "alt", "key": mango,
            "url": "https://alt.example.com/notes/mango.gif", "width": NSNull(),
            "height": NSNull(), "bytes": 30, "mime": "image/gif", "filename": "mango.gif",
            "uploaded_at": "2026-08-15T12:00:00Z", "state": "active", "favorite": false,
            "labels": [String](), "tags": [String](), "source": "bucket", "note": NSNull(),
          ] as [String: Any],
          [
            "id": 1, "sha256": String(format: "%064x", 1), "backend": "r2", "key": zebra,
            "url": "https://img.example.com/blog/2026/zebra.png", "width": 800,
            "height": 600, "bytes": 20, "mime": "image/png", "filename": "Zebra.png",
            "uploaded_at": "2026-07-10T00:00:00Z", "state": "active", "favorite": true,
            "labels": ["red", "blue"], "tags": ["cats"], "source": "pinax",
            "note": "A sunny Day",
          ] as [String: Any],
        ],
      ]
      #expect(page as NSDictionary == expected as NSDictionary)
    }
  }
}
