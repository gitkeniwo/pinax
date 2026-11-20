import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// The built-in usage scanner. The fixture tree and every
/// expected reference are written out by hand.
@Suite struct UsageScannerTests {
  /// A source folder `site` and, beside it, a folder `outside` that only
  /// symbolic links reach.
  private struct Fixture {
    let directory: URL
    var site: URL { directory.appendingPathComponent("site") }
    var outside: URL { directory.appendingPathComponent("outside") }

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinax-scan-\(UUID().uuidString)", isDirectory: true)
      try write("posts/a.md", """
        # Title
        ![cat](https://img.example.com/blog/cat)
        See [docs](https://docs.astro.build/en/guide/) and (https://example.org/x.png).
        Twice: https://img.example.com/blog/a.png https://img.example.com/blog/a.png
        Old: https://old.example.com/blog/legacy, then more.
        Balanced: https://example.org/Foo_(bar).jpg!
        """)
      try write(
        "pages/index.astro",
        #"<img src="https://cdn.example.net/p.webp?w=1&amp;h=2" alt="">"# + "\n")
      try write("styles/site.css", "body { background: url('https://img.example.com/blog/bg.jpg'); }\r\n")
      try write("notes.txt", "https://img.example.com/blog/txt.png\n")
      try write("node_modules/pkg/readme.md", "https://img.example.com/blog/nm.png\n")
      try write(".hidden/x.md", "https://img.example.com/blog/hidden.png\n")
      try write("dist/out.html", "https://img.example.com/blog/dist.png\n")
      var big = Data("https://img.example.com/blog/big.png\n".utf8)
      big.append(Data(repeating: 0x61, count: 6 * 1024 * 1024))
      try write("big.md", big)
      var binary = Data([0x00, 0x01])
      binary.append(Data("https://img.example.com/blog/binary.png\n".utf8))
      try write("binary.md", binary)
      try write("../outside/linked.md", "https://img.example.com/blog/linked.png\n")
      try FileManager.default.createSymbolicLink(
        at: site.appendingPathComponent("linked.md"),
        withDestinationURL: outside.appendingPathComponent("linked.md"))
      try FileManager.default.createSymbolicLink(
        at: site.appendingPathComponent("linked-folder"), withDestinationURL: outside)
      try write(".git/HEAD", "ref: refs/heads/main\n")
      try write(
        ".git/packed-refs",
        "# pack-refs with: peeled fully-peeled sorted\n"
          + "630159d3a6b1c0e2f4d5a7b8c9d0e1f2a3b4c5d6 refs/heads/main\n")
    }

    func write(_ path: String, _ text: String) throws { try write(path, Data(text.utf8)) }

    func write(_ path: String, _ data: Data) throws {
      let url = site.appendingPathComponent(path).standardizedFileURL
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }

    func remove() {
      _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", directory.path])
        .waitUntilExit()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private static let expectedReferences = [
    UsageReference(
      rawURL: "https://cdn.example.net/p.webp?w=1&h=2",
      sourceReference: "site/pages/index.astro#L1", kind: "html"),
    UsageReference(
      rawURL: "https://img.example.com/blog/cat", sourceReference: "site/posts/a.md#L2",
      kind: "markdown"),
    UsageReference(
      rawURL: "https://example.org/x.png", sourceReference: "site/posts/a.md#L3", kind: "markdown"),
    UsageReference(
      rawURL: "https://img.example.com/blog/a.png", sourceReference: "site/posts/a.md#L4",
      kind: "markdown"),
    UsageReference(
      rawURL: "https://old.example.com/blog/legacy", sourceReference: "site/posts/a.md#L5",
      kind: "markdown"),
    UsageReference(
      rawURL: "https://example.org/Foo_(bar).jpg", sourceReference: "site/posts/a.md#L6",
      kind: "markdown"),
    UsageReference(
      rawURL: "https://img.example.com/blog/bg.jpg", sourceReference: "site/styles/site.css#L1",
      kind: "css"),
  ]

  private static let expectedDocument = UsageDocument(
    project: "blog",
    sourceRevision: "site:630159d3a6b1c0e2f4d5a7b8c9d0e1f2a3b4c5d6",
    coverage: ["site/**/*.{md,mdx,markdown,html,htm,astro,vue,svelte,jsx,tsx,css,scss,yml,yaml}"],
    refs: expectedReferences)

  /// The test catalog, with `https://old.example.com` as `r2`'s retired
  /// prefix and `blog`'s one source pointing at the fixture.
  private func catalog(_ fixture: Fixture) throws -> (DatabasePool, URL) {
    let (database, directory) = try makeUITestDatabase()
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend_prefix_history (backend_id, url_prefix, retired_at)
          VALUES (1, 'https://old.example.com', '2026-08-01T00:00:00Z')
          """)
    }
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: fixture.site.path)], in: database)
    return (database, directory)
  }

  private func scanCount(_ database: DatabasePool) throws -> Int {
    try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan")! }
  }

  // MARK: - properties 1 and 2

  @Test("The fixture scans to the hand-written document, byte for byte across two scans")
  func fixtureDocument() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (database, directory) = try catalog(fixture)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try UsageScanner.scan(project: "blog", in: database)
    #expect(first.document == Self.expectedDocument)
    #expect(first.files == 3)
    #expect(first.skipped == 2)
    let second = try UsageScanner.scan(project: "blog", in: database)
    // JSONEncoder's key order is unspecified; sorted keys make bytes comparable.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(second.document) == encoder.encode(first.document))
  }

  @Test("Each keep rule is proven by a URL only it admits")
  func keepRulesAreIndependent() {
    let backend = UsageScanBackend(
      backend: Backend(
        slug: "r2", kind: "s3", endpoint: "https://storage.example.com", bucket: "images",
        region: "auto", urlPrefix: "https://img.example.com", keychainRef: "backend.r2",
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z"),
      retiredPrefixes: ["https://old.example.com"])
    // Only the prefix: no image extension.
    #expect(UsageScanner.keeps("https://img.example.com/blog/cat", backends: [backend]))
    #expect(!UsageScanner.keeps("https://img.example.com/blog/cat", backends: []))
    // Only the retired prefix.
    #expect(UsageScanner.keeps("https://old.example.com/blog/legacy", backends: [backend]))
    // Only the extension: a third-party host, upper-case extension, query after it.
    #expect(UsageScanner.keeps("https://example.org/x.png", backends: []))
    #expect(UsageScanner.keeps("https://example.org/X.PNG?w=2", backends: []))
    // Neither.
    #expect(!UsageScanner.keeps("https://docs.astro.build/en/guide/", backends: [backend]))
    #expect(!UsageScanner.keeps("https://example.org/page?file=x.png", backends: [backend]))
    #expect(!UsageScanner.keeps("https://example.png", backends: [backend]))
    #expect(!UsageScanner.keeps("https://img.example.com.evil.net/blog/cat", backends: [backend]))
  }

  @Test("URL extraction ends, trims and unescapes as specified")
  func extraction() {
    #expect(
      UsageScanner.urls(in: #"<a href="https://a.example/x.png">https://b.example/y</a>"#)
        == ["https://a.example/x.png", "https://b.example/y"])
    #expect(UsageScanner.urls(in: "[t](https://a.example/x.png) and https://b.example/z.") == [
      "https://a.example/x.png", "https://b.example/z",
    ])
    #expect(UsageScanner.urls(in: "(see https://a.example/w_(x)_y.png?)") == ["https://a.example/w_(x)_y.png"])
    #expect(UsageScanner.urls(in: "`https://a.example/c` 'https://a.example/d'|http://a.example/e]") == [
      "https://a.example/c", "https://a.example/d", "http://a.example/e",
    ])
    #expect(UsageScanner.urls(in: "https://a.example/q?a=1&amp;b=2;:!?,") == ["https://a.example/q?a=1&b=2"])
    #expect(UsageScanner.urls(in: "//cdn.example/x.png and ftp://a/x.png") == [])
  }

  /// A destination written `<…>` (CommonMark) runs to
  /// its `>`, spaces included; an unclosed `<` falls back to the bare rule.
  @Test("Angle-bracketed URLs run to their closing bracket")
  func angleBracketed() {
    #expect(UsageScanner.urls(in: "![](<https://x.invalid/a b.png>)") == ["https://x.invalid/a b.png"])
    #expect(UsageScanner.urls(in: "<https://x.invalid/a b.png>") == ["https://x.invalid/a b.png"])
    #expect(
      UsageScanner.urls(in: "![](<https://x.invalid/a b.png>) ![](https://x.invalid/c.png) <https://x.invalid/d e.png>")
        == ["https://x.invalid/a b.png", "https://x.invalid/c.png", "https://x.invalid/d e.png"])
    #expect(UsageScanner.urls(in: "![](<https://x.invalid/a b.png)") == ["https://x.invalid/a"])
    #expect(UsageScanner.urls(in: "<https://x.invalid/a b.png") == ["https://x.invalid/a"])
  }

  /// A `<` before the `>` means the first bracket never closed (CommonMark):
  /// it stops at the space, and the second one reads to its own `>`.
  @Test("A second '<' before the '>' leaves the first bracket unclosed")
  func angleBracketReopened() {
    #expect(
      UsageScanner.urls(in: "<https://x.invalid/a b <https://x.invalid/c d.png>")
        == ["https://x.invalid/a", "https://x.invalid/c d.png"])
    #expect(
      UsageScanner.urls(in: "![](<https://x.invalid/a b <https://x.invalid/c d.png>)")
        == ["https://x.invalid/a", "https://x.invalid/c d.png"])
  }

  @Test("Kinds by file extension")
  func kinds() {
    #expect(UsageScanner.kind(forPath: "a/b.MDX") == "markdown")
    #expect(UsageScanner.kind(forPath: "a.markdown") == "markdown")
    #expect(UsageScanner.kind(forPath: "p.svelte") == "html")
    #expect(UsageScanner.kind(forPath: "p.htm") == "html")
    #expect(UsageScanner.kind(forPath: "s.scss") == "css")
    #expect(UsageScanner.kind(forPath: "c.yml") == "yaml")
    #expect(UsageScanner.kind(forPath: "n.txt") == "text")
  }

  @Test("HEAD resolves through a loose ref, packed-refs or a detached sha; a .git file gives none")
  func gitRevision() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sha = "630159d3a6b1c0e2f4d5a7b8c9d0e1f2a3b4c5d6"
    #expect(UsageScanner.gitRevision(fixture.site) == sha)
    try fixture.write(".git/refs/heads/main", "1111111111111111111111111111111111111111\n")
    #expect(UsageScanner.gitRevision(fixture.site) == "1111111111111111111111111111111111111111")
    try fixture.write(".git/HEAD", "2222222222222222222222222222222222222222\n")
    #expect(UsageScanner.gitRevision(fixture.site) == "2222222222222222222222222222222222222222")
    try FileManager.default.removeItem(at: fixture.site.appendingPathComponent(".git"))
    try fixture.write(".git", "gitdir: /elsewhere/.git/worktrees/site\n")
    #expect(UsageScanner.gitRevision(fixture.site) == nil)
  }

  // MARK: - property 3: end to end through the CLI command

  @Test("usage scan through the real parser syncs, and orphans and externals follow by hand")
  func endToEnd() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (database, directory) = try catalog(fixture)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (index, key) in ["blog/cat", "blog/a.png", "blog/legacy", "blog/bg.jpg", "blog/unused.png"]
      .enumerated()
    {
      try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z", key: key)
    }

    let command = try #require(
      try Pinax.parseAsRoot(["usage", "scan", "--project", "blog"]) as? UsageScanCommand)
    #expect(try command.output(in: database) == "scan 1: 7 refs\n3 files, 2 skipped")
    #expect(try command.output(in: database) == "scan 2: 7 refs\n3 files, 2 skipped")

    let orphans = try CatalogUsage.orphans(project: "blog", in: database)
    #expect(orphans.unscannedProjects == [])
    #expect(orphans.assets.map(\.asset.key) == ["blog/unused.png"])
    #expect(
      try CatalogUsage.externals(project: "blog", in: database).map(\.rawURL) == [
        "https://cdn.example.net/p.webp?w=1&h=2",
        "https://example.org/x.png",
        "https://example.org/Foo_(bar).jpg",
      ])
  }

  // MARK: - property 4

  @Test("A missing source folder fails the scan and syncs nothing")
  func missingFolderFails() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (database, directory) = try catalog(fixture)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gone = fixture.directory.appendingPathComponent("gone").path
    try CatalogConfiguration.setProjectSources(
      slug: "blog",
      [
        ProjectSource(label: "site", path: fixture.site.path),
        ProjectSource(label: "gone", path: gone),
      ], in: database)
    let command = try #require(
      try Pinax.parseAsRoot(["usage", "scan", "--project", "blog"]) as? UsageScanCommand)
    #expect(throws: UsageScanError.sourceNotFound(label: "gone", path: gone)) {
      try command.output(in: database)
    }
    #expect(try scanCount(database) == 0)

    try CatalogConfiguration.setProjectSources(slug: "blog", [], in: database)
    #expect(throws: UsageScanError.noSources("blog")) { try command.output(in: database) }
    #expect(try scanCount(database) == 0)
  }

  @Test("--dry-run prints the document and leaves the catalog's change stamp alone")
  func dryRunWritesNothing() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (database, directory) = try catalog(fixture)
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = try await CatalogAssets.changeStamp(in: database)
    let command = try #require(
      try Pinax.parseAsRoot(["usage", "scan", "--project", "blog", "--dry-run"]) as? UsageScanCommand)
    let output = try command.output(in: database)
    #expect(try JSONDecoder().decode(UsageDocument.self, from: Data(output.utf8)) == Self.expectedDocument)
    #expect(try await CatalogAssets.changeStamp(in: database) == before)
    #expect(try scanCount(database) == 0)
  }

  // MARK: - property 5

  @Test("A read-only fixture scans the same")
  func readOnlyFixture() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (database, directory) = try catalog(fixture)
    defer { try? FileManager.default.removeItem(at: directory) }
    let chmod = try Process.run(
      URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "a-w", fixture.site.path])
    chmod.waitUntilExit()
    #expect(chmod.terminationStatus == 0)
    #expect(!FileManager.default.isWritableFile(atPath: fixture.site.path))
    #expect(try UsageScanner.scan(project: "blog", in: database).document == Self.expectedDocument)
  }
}
