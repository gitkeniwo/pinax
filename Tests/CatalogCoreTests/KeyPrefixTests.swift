import CatalogCore
import Foundation
import GRDB
import Testing

/// The key-prefix predicate and
/// the prefix tree's children aggregate.
@Suite struct KeyPrefixTests {
  private func makeDatabase(
    keys: [String], archived: Set<String> = []
  ) throws -> (DatabasePool, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
          """)
      for (index, key) in keys.enumerated() {
        let stamp = "2026-08-01T00:00:00Z"
        var asset = Asset(
          sha256: String(format: "%064x", index + 1), backendID: 1, key: key,
          byteSize: 100, width: 1, height: 1, mime: "image/png",
          originalFilename: "asset-\(index).png",
          state: archived.contains(key) ? "archived" : "active", note: nil,
          uploadedAt: stamp, createdAt: stamp, updatedAt: stamp)
        try asset.insert(db)
      }
    }
    return (database, directory)
  }

  private func keys(under prefix: String?, in database: DatabasePool) throws -> [String] {
    var query = AssetQuery()
    query.keyPrefix = prefix
    query.limit = 1000
    return try CatalogAssets.page(query, in: database).items.map(\.asset.key).sorted()
  }

  // MARK: - Wildcard characters are literal

  @Test("A key prefix matches only keys under it: _ % and \\ are literal")
  func prefixPredicateEscapes() throws {
    let (database, directory) = try makeDatabase(keys: [
      "blog/a.png", "blog_x/b.png", "blogAx/c.png", "blog/deep/d.png",
      "blog%/e.png", "blogZZ/f.png", "a\\b/g.png", "aXb/h.png", "blog.png", "blog0/i.png",
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    // blog_x/… and blog/… seeded, blog
    // selects only the latter (and its deeper levels).
    #expect(try keys(under: "blog", in: database) == ["blog/a.png", "blog/deep/d.png"])
    // `_` is not "any one character"; `%` is not "any run"; `\` is itself.
    #expect(try keys(under: "blog_x", in: database) == ["blog_x/b.png"])
    #expect(try keys(under: "blog%", in: database) == ["blog%/e.png"])
    #expect(try keys(under: "a\\b", in: database) == ["a\\b/g.png"])
    // Strictly under: a file named like the prefix is not inside it.
    #expect(try keys(under: "blog/deep", in: database) == ["blog/deep/d.png"])
    // The byte range's two ends: `.` sorts just below `/`, `0` just above.
    #expect(try keys(under: "blog", in: database).allSatisfy { $0.hasPrefix("blog/") })
    #expect(try keys(under: "blog0", in: database) == ["blog0/i.png"])
    // nil is the whole catalog.
    #expect(try keys(under: nil, in: database).count == 10)
  }

  // MARK: - The children aggregate

  @Test("Children are the next segment level with subtree counts; loose files make no child")
  func childrenShapeAndCounts() throws {
    let (database, directory) = try makeDatabase(
      keys: [
        "blog/202603/a.png", "blog/202603/b.png", "blog/202604/c.png", "blog/top.png",
        "notes/x.png", "root.png", "blog/202605/z.png", "blog_x/y.png",
      ],
      archived: ["blog/202605/z.png"])
    defer { try? FileManager.default.removeItem(at: directory) }

    func children(_ prefix: String?) throws -> [String] {
      try CatalogAssets.keyPrefixChildren(under: prefix, backendID: 1, in: database)
        .map { "\($0.segment):\($0.assetCount)" }
    }
    // root.png sits at the root: no child for it. The archived key counts,
    // because the grid shows it. blog's count includes
    // its loose top.png.
    #expect(try children(nil) == ["blog:5", "blog_x:1", "notes:1"])
    #expect(try children("blog") == ["202603:2", "202604:1", "202605:1"])
    #expect(try children("blog/202603") == [])
    // `_` in the parent prefix is literal here too.
    #expect(try children("blog_x") == [])
  }

  /// The tree's count for a node and the grid's rows for that node come
  /// from the same range and the same scope — every state, as the grid's
  /// query has no state filter — so a row can never promise N and open
  /// onto M.
  @Test("Every child's count equals the rows its prefix selects")
  func childCountsMatchThePredicate() throws {
    let (database, directory) = try makeDatabase(
      keys: [
        "blog/202603/a.png", "blog/202603/b.png", "blog/202604/c.png", "blog/top.png",
        "blog_x/y.png", "blog%/w.png", "blog/202605/z.png",
      ],
      archived: ["blog/202605/z.png"])
    defer { try? FileManager.default.removeItem(at: directory) }

    var frontier: [String?] = [nil]
    var visited = 0
    while let parent = frontier.popLast() {
      for child in try CatalogAssets.keyPrefixChildren(under: parent, backendID: 1, in: database) {
        let path = parent.map { "\($0)/\(child.segment)" } ?? child.segment
        var query = AssetQuery()
        query.keyPrefix = path
        #expect(try CatalogAssets.count(query, in: database) == child.assetCount, "\(path)")
        frontier.append(path)
        visited += 1
      }
    }
    #expect(visited == 6)  // blog, blog_x, blog%, blog/202603, blog/202604, blog/202605
  }

  @Test("The async overload returns what the synchronous one does")
  func asyncChildren() async throws {
    let (database, directory) = try makeDatabase(keys: ["blog/202603/a.png", "notes/x.png"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let sync = try syncChildren(in: database)
    let async = try await CatalogAssets.keyPrefixChildren(under: nil, backendID: 1, in: database)
    #expect(sync.map(\.segment) == async.map(\.segment))
    #expect(sync.map(\.assetCount) == async.map(\.assetCount))
  }

  /// Outside any async context, so overload resolution picks the
  /// synchronous sibling.
  private func syncChildren(in database: DatabasePool) throws -> [(segment: String, assetCount: Int, hasSubPrefixes: Bool)] {
    try CatalogAssets.keyPrefixChildren(under: nil, backendID: 1, in: database)
  }

  /// A `LIKE` predicate ignores ASCII case, so `blog` would also select
  /// `Blog/…` (under "blog" → ["Blog/b.png", "blog/a.png"]), while the
  /// children aggregate's `GROUP BY` shows `Blog` and `blog` as two nodes
  /// of 1 — a node that promises 1 and opens onto 2. S3 keys are
  /// case-sensitive, and so is the byte range.
  @Test("The prefix predicate is byte-exact: `blog` and `Blog` are two prefixes")
  func prefixPredicateKeepsCase() throws {
    let (database, directory) = try makeDatabase(keys: ["blog/a.png", "Blog/b.png"])
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try CatalogAssets.keyPrefixChildren(under: nil, backendID: 1, in: database).map(\.segment)
      == ["Blog", "blog"])
    let underBlog = try keys(under: "blog", in: database)
    #expect(underBlog == ["blog/a.png"])
    #expect(try keys(under: "Blog", in: database) == ["Blog/b.png"])
  }
}
