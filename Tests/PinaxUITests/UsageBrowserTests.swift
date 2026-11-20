import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Usage over the current project — or all — by image
/// and by file. Every expected list below is worked out by hand from the
/// fixture, not from the code under test.
@MainActor
@Suite struct UsageBrowserTests {
  // MARK: - Property 1: the fixture, by hand

  @Test("Images by uses then name, files by references, lines, old domains and the summary, by hand")
  func handComputedFixture() async throws {
    try await withFixture { database, ids in
      let all = UsageBrowser(try await CatalogUsage.liveUsage(in: database))
      // Matched and live only: the external URL and blog's superseded scan
      // drop out; 4 + 1 + 1 references.
      #expect(all.usage.references.count == 6)
      #expect(all.images.map(\.assetID) == [ids.a0, ids.a1, ids.a2])
      #expect(all.images.map(\.uses) == [4, 1, 1])
      #expect(all.images.map(\.hasOldDomain) == [false, true, false])
      #expect(
        all.image(ids.a0)?.references.map { "\($0.reference.projectSlug) \($0.file) \($0.line ?? 0) \($0.reference.kind)" }
          == [
            "blog posts/a.md 3 markdown", "blog posts/a.md 9 markdown", "blog posts/b.md 1 html",
            "notes notes/n.md 4 markdown",
          ])
      #expect(all.files.map(\.path) == ["posts/a.md", "notes/n.md", "posts/b.md"])
      #expect(all.files.map(\.referenceCount) == [3, 2, 1])
      #expect(all.files[0].images.map(\.assetID) == [ids.a0, ids.a1])
      #expect(all.files[0].images.map(\.line) == [3, 5])
      #expect(all.files[1].images.map(\.assetID) == [ids.a2, ids.a0])
      #expect(all.files[1].images.map(\.line) == [2, 4])

      // Every reference of a file, in line order; the image
      // already used higher up repeats (the grid's "same as above").
      #expect(
        all.files[0].occurrences
          == [
            UsageOccurrence(assetID: ids.a0, line: 3), UsageOccurrence(assetID: ids.a1, line: 5),
            UsageOccurrence(assetID: ids.a0, line: 9),
          ])

      // The range bar's wording, read against a fixed
      // "now" so the relative date is a constant.
      let summaries = try await ReadOnlyCatalog(database: database).projectSummaries()
      let now = try #require(
        ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z"))
      #expect(
        all.rangeSummary(projects: summaries, now: now, locale: Locale(identifier: "en_US"))
          .text == "6 refs · 3 files · scanned 1 week ago")
      #expect(all.rangeSummary(projects: [], now: now).text.hasPrefix("6 refs · 3 files"))
      #expect(
        UsageBrowser(
          LiveUsageSet(
            references: all.usage.references, assets: all.usage.assets, scannedProjects: [],
            projectSources: [:])
        ).rangeSummary(projects: []) == .noScan)

      // Old Domains: only the retired-prefix reference; the summary still
      // counts everything.
      let old = UsageBrowser(all.usage, oldDomainsOnly: true)
      #expect(old.images.map(\.assetID) == [ids.a1])
      #expect(old.files.map(\.path) == ["posts/a.md"])
      #expect(old.files.first?.images.map(\.line) == [5])
      #expect(
        old.rangeSummary(projects: summaries, now: now, locale: Locale(identifier: "en_US"))
          == all.rangeSummary(projects: summaries, now: now, locale: Locale(identifier: "en_US")))

      // Files' list groups: "project › directory", by project then
      // directory, each group in the list's order.
      let groups = all.fileListGroups(sort: .picking(.references), dates: [:], scope: nil)
      #expect(groups.map(\.title) == ["blog › posts", "notes › notes"])
      #expect(
        groups.map { $0.files.map(\.path) }
          == [["posts/a.md", "posts/b.md"], ["notes/n.md"]])
    }
  }

  // MARK: - Property 2: All Projects and one project

  @Test("The model follows the current project; the Project column stands only under All Projects")
  func allProjectsAndOne() async throws {
    try await withFixture { database, ids in
      let model = makeModel(database)
      await model.loadInitialData()
      // Images ▸ Table: one row per image (Files opens first, the grid cuts by file).
      model.usagePage = .images
      model.viewMode = .table
      model.select(.usage, in: .reports)
      await model.reload()
      #expect(model.rows.map(\.id) == [ids.a0, ids.a1, ids.a2])
      #expect(model.rows.map(\.usage) == model.usageBrowser?.images.map {
        .image(uses: $0.uses, hasOldDomain: $0.hasOldDomain, references: $0.references)
      })
      #expect(
        AssetTableView.visibleUsageColumns(selection: .usage, currentProjectSlug: nil)
          == ["uses", "domain", "project"])

      model.currentProjectSlug = "blog"
      await until { model.usageBrowser?.usage.projectSources.keys.sorted() == ["blog"] }
      #expect(model.rows.map(\.id) == [ids.a0, ids.a1])
      #expect(model.rows.map(\.usageUses) == [3, 1])
      #expect(
        AssetTableView.visibleUsageColumns(selection: .usage, currentProjectSlug: "blog")
          == ["uses", "domain"])
      #expect(AssetTableView.visibleUsageColumns(selection: .all, currentProjectSlug: nil) == [])
      let oneProject = try #require(model.usageBrowser)
      #expect(
        oneProject.rangeSummary(projects: model.reportScopeProjects)
          .text.hasPrefix("4 refs · 2 files"))

      // Files: the first file is selected; the grid lists its references
      // in line order — a0 at 3, a1 at 5, a0 again at 9, the repeat marked
      // "same as above".
      model.usagePage = .files
      await until { model.rows.first?.usage == .line(3) }
      #expect(model.usageSelectedFileID == "blog\u{0}posts/a.md")
      #expect(model.rows.map(\.id).prefix(2) == [ids.a0, ids.a1])
      #expect(model.rows.map(\.usage) == [.line(3), .line(5), .line(9)])
      #expect(model.rows.map(\.repeatsPreviousImage) == [false, false, true])
      #expect(model.rows[2].id != ids.a0, "the repeat's cell has an id of its own")
      model.usageSelectedFileID = "blog\u{0}posts/b.md"
      #expect(model.rows.map(\.id) == [ids.a0])
      #expect(model.rows.map(\.usage) == [.line(1)])
      #expect(AssetGridCell.usageMark(.line(1)) == nil)
      #expect(
        !AssetGridCell.showsReferenceBadge(
          .image(uses: 1, hasOldDomain: false, references: [])))
      #expect(
        AssetGridCell.showsReferenceBadge(.image(uses: 3, hasOldDomain: false, references: [])))
      #expect(AssetGridCell.usageMark(.image(uses: 1, hasOldDomain: true, references: [])) == "OLD")
      #expect(AssetGridCell.usageMark(.image(uses: 3, hasOldDomain: false, references: [])) == nil)
    }
  }

  // MARK: - Property 5: the library's own view, selection and ⌘C

  @Test("Usage ▸ Images is the library's grid and table over model.rows, and ⌘C renders CopyTemplate")
  func imagesReuseTheLibrary() async throws {
    try await withFixture { database, ids in
      let model = makeModel(database)
      await model.loadInitialData()
      // Images ▸ Table: one row per image (Files opens first, the grid cuts by file).
      model.usagePage = .images
      model.viewMode = .table
      model.select(.usage, in: .reports)
      await model.reload()

      model.viewMode = .grid
      #expect(firstView(in: UsageView(model: model).body, typePrefix: "AssetGridView") != nil)
      model.viewMode = .table
      #expect(firstView(in: UsageView(model: model).body, typePrefix: "AssetTableView") != nil)

      // The library's selection over the Usage rows, clicked back to front:
      // ⌘C still reads in Usage order.
      let rows = model.rows
      #expect(rows.map(\.id) == [ids.a0, ids.a1, ids.a2])
      model.select(rows[2], mode: .replace)
      model.select(rows[0], mode: .toggle)
      let keyFormat = CopyFormat(name: "Key", template: "{key}")
      model.defaultCopyFormat = keyFormat
      let board = NSPasteboard(name: NSPasteboard.Name("PinaxUsageTests-\(UUID().uuidString)"))
      model.copySelectionInDefaultFormat(to: board)
      #expect(board.string(forType: .string) == "blog/asset-0.png\nnotes/asset-2.png")
      // The context menu's Copy As on the same selection: the one
      // CopyTemplate.render call both go through.
      let item = try #require(model.contextMenuItems(for: rows[0]).first { $0.id == "copyAs" })
      guard case let .copyAs(target, _) = item else { return }
      let menuBoard = NSPasteboard(name: NSPasteboard.Name("PinaxUsageTests-\(UUID().uuidString)"))
      model.copy(keyFormat, for: target, to: menuBoard)
      #expect(menuBoard.string(forType: .string) == board.string(forType: .string))
    }
  }

  @Test("The new symbols exist")
  func symbols() {
    for name in ["link", "arrow.clockwise"] {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  // MARK: - Property 3: the Open File rule

  @Test("Open File / Reveal only for <label>/ of a configured source whose file exists; Copy New URL only on old domains")
  func openFileRule() async throws {
    try await withFixture { database, ids in
      let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-src-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: source) }
      try "![g](https://img.example.com/blog/asset-3.png)\n".write(
        to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
      try CatalogConfiguration.setProjectSources(
        slug: "blog", [ProjectSource(label: "src", path: source.path)], in: database)
      // a3: the built-in scanner's format, once for a file that is there and
      // once for one that is gone; "docs/" is no source of blog's, though
      // guide.md is there under src.
      try await addReferences(
        database, asset: "blog/asset-3.png", project: "blog", scan: 2,
        ["src/guide.md#L2", "src/gone.md#L4", "docs/guide.md#L1"])
      let guide = source.appendingPathComponent("guide.md")

      let model = makeModel(database)
      await model.loadInitialData()
      model.currentProjectSlug = "blog"
      // Images ▸ Table: one row per image (Files opens first, the grid cuts by file).
      model.usagePage = .images
      model.viewMode = .table
      model.select(.usage, in: .reports)
      await model.reload()
      let a3 = try #require(model.rows.first { $0.id == ids.a3 })
      #expect(model.usageMenuItems(for: a3) == [.showInLibrary(ids.a3)])
      let children = try #require(a3.usageChildren)
      #expect(children.map(\.usageFile) == ["docs/guide.md", "src/gone.md", "src/guide.md"])
      #expect(model.usageMenuItems(for: children[0]) == [.showInLibrary(ids.a3)])
      #expect(model.usageMenuItems(for: children[1]) == [.showInLibrary(ids.a3)])
      #expect(
        model.usageMenuItems(for: children[2])
          == [.openFile(guide), .revealInFinder(guide), .showInLibrary(ids.a3)])
      // An external scanner's reference (no label) and an old-domain one.
      let a0 = try #require(model.rows.first { $0.id == ids.a0 }?.usageChildren?.first)
      #expect(model.usageMenuItems(for: a0) == [.showInLibrary(ids.a0)])
      let a1 = try #require(model.rows.first { $0.id == ids.a1 })
      #expect(
        model.usageMenuItems(for: a1)
          == [.copyNewURL("https://cdn.example.net/blog/asset-1.png"), .showInLibrary(ids.a1)])

      // Files: the right side's image and the buttons over it.
      model.usagePage = .files
      await until { model.usageSelectedFileID != nil && model.rows.first?.usage != nil }
      let browser = try #require(model.usageBrowser)
      let guideFile = try #require(browser.files.first { $0.path == "src/guide.md" })
      #expect(model.usageFileURL(guideFile) == guide)
      #expect(browser.files.filter { model.usageFileURL($0) != nil }.map(\.path) == ["src/guide.md"])
      model.usageSelectedFileID = guideFile.id
      #expect(model.rows.map(\.usage) == [.line(2)])
      #expect(model.usageMenuItems(for: model.rows[0]) == [.openFile(guide), .revealInFinder(guide)])
      model.usageSelectedFileID = "blog\u{0}posts/a.md"
      let old = try #require(model.rows.first { $0.id == ids.a1 })
      #expect(model.usageMenuItems(for: old) == [.copyNewURL("https://cdn.example.net/blog/asset-1.png")])

      // Show in Library: Library ▸ All Assets, the asset selected.
      await model.showInLibrary(assetID: ids.a3)
      #expect(model.navigator == .library)
      #expect(model.sidebarSelection == .all)
      #expect(model.selectedIDs == [ids.a3])
    }
  }

  @Test("Two projects each name a source 'src'; Open File looks only in the reference's own project's")
  func openFileSameLabel() async throws {
    try await withFixture { database, ids in
      var folders: [String: URL] = [:]
      for slug in ["blog", "notes"] {
        let folder = FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-src-\(slug)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try CatalogConfiguration.setProjectSources(
          slug: slug, [ProjectSource(label: "src", path: folder.path)], in: database)
        folders[slug] = folder
      }
      defer { folders.values.forEach { try? FileManager.default.removeItem(at: $0) } }
      // x.md is only in notes' folder; both projects reference src/x.md.
      let notesFile = try #require(folders["notes"]).appendingPathComponent("x.md")
      try "![n](https://img.example.com/notes/asset-2.png)\n".write(
        to: notesFile, atomically: true, encoding: .utf8)
      try await addReferences(database, asset: "notes/asset-2.png", project: "notes", scan: 3, ["src/x.md#L1"])
      try await addReferences(database, asset: "blog/asset-3.png", project: "blog", scan: 2, ["src/x.md#L1"])

      let model = makeModel(database)
      await model.loadInitialData()
      // Images ▸ Table: one row per image (Files opens first, the grid cuts by file).
      model.usagePage = .images
      model.viewMode = .table
      model.select(.usage, in: .reports)
      await model.reload()
      #expect(model.currentProjectSlug == nil)
      let notes = try #require(
        model.rows.first { $0.id == ids.a2 }?.usageChildren?.first { $0.usageFile == "src/x.md" })
      #expect(
        model.usageMenuItems(for: notes)
          == [.openFile(notesFile), .revealInFinder(notesFile), .showInLibrary(ids.a2)])
      let blog = try #require(
        model.rows.first { $0.id == ids.a3 }?.usageChildren?.first { $0.usageFile == "src/x.md" })
      #expect(model.usageMenuItems(for: blog) == [.showInLibrary(ids.a3)])
    }
  }

  // MARK: - Property 6: Used In

  @Test("Two projects, 7 references → 5 rows and Show All (7), which lands on Usage ▸ Images ▸ Table with the row selected and open")
  func usedInShowAll() async throws {
    try await withFixture { database, ids in
      let notes = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-src-\(UUID().uuidString)", isDirectory: true)
      try CatalogConfiguration.setProjectSources(
        slug: "notes", [ProjectSource(label: "notes", path: notes.path)], in: database)
      // a0: 3 in blog, 1 + 3 in notes = 7.
      try await addReferences(
        database, asset: "blog/asset-0.png", project: "notes", scan: 3,
        ["notes/m.md#L1", "notes/m.md#L2", "notes/m.md#L8"])
      let model = makeModel(database)
      await model.loadInitialData()
      model.currentProjectSlug = "notes"
      let row = try #require(model.rows.first { $0.id == ids.a0 })
      model.select(row, mode: .replace)
      await until { model.usedIn != nil }

      let group = try #require(collectViews(AssetInspectorView(model: model), as: UsedInGroup.self).first)
      // The notes source label comes off; ordered by project, file, line.
      #expect(
        group.rowTexts == [
          "blog · posts/a.md:3", "blog · posts/a.md:9", "blog · posts/b.md:1",
          "notes · m.md:1", "notes · m.md:2",
        ])
      #expect(group.showAllTitle == "Show All (7)")

      group.showAll()
      // a0 is already selected from the library: wait for Usage's own rows.
      await until {
        model.sidebarSelection == .usage && model.rows.first?.usage != nil
          && model.selectedIDs == [ids.a0]
      }
      #expect(model.navigator == .reports)
      #expect(model.sidebarSelection == .usage)
      #expect(model.currentProjectSlug == "notes")
      #expect(model.usagePage == .images)
      #expect(model.viewMode == .table)
      #expect(model.selectedIDs == [ids.a0])
      #expect(model.usageExpandedIDs.contains(ids.a0))
      #expect(model.rows.first { $0.id == ids.a0 }?.usageChildren?.count == 4)
    }
  }

  @Test("Not used, Unknown and — each read as one row")
  func usedInStates() async throws {
    try await withFixture { database, ids in
      let model = makeModel(database)
      await model.loadInitialData()
      let rows = model.rows
      model.select(try #require(rows.first { $0.id == ids.a3 }), mode: .replace)
      await until { model.usedIn != nil }
      #expect(model.usedIn == .notUsed)
      #expect(usedInGroup(model)?.rowTexts == ["Not used"])
      #expect(usedInGroup(model)?.showAllTitle == nil)
      model.select(try #require(rows.first { $0.id == ids.a0 }), mode: .toggle)
      #expect(usedInGroup(model)?.rowTexts == ["—"])
      #expect(usedInGroup(model)?.showAllTitle == nil)
    }
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(try #require(model.rows.first), mode: .replace)
    await until { model.usedIn != nil }
    #expect(usedInGroup(model)?.rowTexts == ["Unknown"])
  }

  private func usedInGroup(_ model: GalleryModel) -> UsedInGroup? {
    collectViews(AssetInspectorView(model: model), as: UsedInGroup.self).first
  }

  private func addReferences(
    _ database: DatabasePool, asset key: String, project: String, scan: Int, _ sources: [String]
  ) async throws {
    try await database.write { db in
      for source in sources {
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            SELECT p.id, a.id, 'https://img.example.com/' || a.key, ?, 'markdown',
              '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z', ?
            FROM project p, asset a WHERE p.slug = ? AND a.key = ?
            """,
          arguments: [source, scan, project, key])
      }
    }
  }

  // MARK: - Fixture

  struct IDs {
    let a0: Int64
    let a1: Int64
    let a2: Int64
    let a3: Int64
  }

  /// Two backends; b2's URLs moved from old.example.net to cdn.example.net.
  /// blog's live scan (2) and a superseded one (1); notes' scan (3). Live
  /// references by kind, each count different: current domain matched 5,
  /// old domain matched 1, own domain unmatched 2, third party 3.
  ///
  ///   a0 (r2)  blog posts/a.md#L3, #L9, posts/b.md#L1 (html); notes n.md#L4
  ///   a1 (b2)  blog posts/a.md#L5 on old.example.net
  ///   a2 (r2)  notes notes/n.md#L2; blog posts/c.md#L1 in scan 1 (dead)
  ///   a3       never referenced
  ///   —        img.example.com/blog/missing.png ×2, elsewhere.example.org ×3
  private func withFixture(_ body: (DatabasePool, IDs) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<4 {
      try seedAsset(
        database, index: index, uploadedAt: "2026-08-20T12:0\(index):00Z",
        projectSlug: index == 2 ? "notes" : "blog")
    }
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          VALUES
            (2, 'b2', 's3', 'https://s3.example.net', 'pics', 'auto',
             'https://cdn.example.net', 'backend.b2', '{}',
             '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO backend_prefix_history (backend_id, url_prefix, retired_at)
          VALUES (2, 'https://old.example.net', '2026-08-10T00:00:00Z');
          UPDATE asset SET backend_id = 2 WHERE key = 'blog/asset-1.png';
          INSERT INTO scan (id, project_id, started_at, finished_at) VALUES
            (1, 1, '2026-08-19T00:00:00Z', '2026-08-19T00:00:00Z'),
            (2, 1, '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z'),
            (3, 2, '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z');
          UPDATE project SET last_scan_id = 2 WHERE slug = 'blog';
          UPDATE project SET last_scan_id = 3 WHERE slug = 'notes';
          """)
      let references: [(String, String?, String, String, String, Int)] = [
        ("blog", "blog/asset-0.png", "https://img.example.com/blog/asset-0.png", "posts/a.md#L3", "markdown", 2),
        ("blog", "blog/asset-0.png", "https://img.example.com/blog/asset-0.png", "posts/a.md#L9", "markdown", 2),
        ("blog", "blog/asset-0.png", "https://img.example.com/blog/asset-0.png", "posts/b.md#L1", "html", 2),
        ("blog", "blog/asset-1.png", "https://old.example.net/blog/asset-1.png", "posts/a.md#L5", "markdown", 2),
        ("blog", nil, "https://img.example.com/blog/missing.png", "posts/a.md#L11", "markdown", 2),
        ("blog", nil, "https://img.example.com/blog/missing.png", "posts/b.md#L6", "markdown", 2),
        ("blog", nil, "https://elsewhere.example.org/x.png", "posts/a.md#L7", "markdown", 2),
        ("blog", nil, "https://elsewhere.example.org/y.png", "posts/b.md#L8", "markdown", 2),
        ("notes", nil, "https://elsewhere.example.org/z.png", "notes/n.md#L9", "markdown", 3),
        ("blog", "notes/asset-2.png", "https://img.example.com/notes/asset-2.png", "posts/c.md#L1", "markdown", 1),
        ("notes", "notes/asset-2.png", "https://img.example.com/notes/asset-2.png", "notes/n.md#L2", "markdown", 3),
        ("notes", "blog/asset-0.png", "https://img.example.com/blog/asset-0.png", "notes/n.md#L4", "markdown", 3),
      ]
      for (slug, key, url, source, kind, scan) in references {
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            SELECT p.id, (SELECT id FROM asset WHERE key = ?), ?, ?, ?,
              '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z', ?
            FROM project p WHERE p.slug = ?
            """,
          arguments: [key, url, source, kind, scan, slug])
      }
    }
    let ids = try await database.read { db in
      try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, key FROM asset").map {
          ($0["key"] as String, $0["id"] as Int64)
        })
    }
    try await body(
      database,
      IDs(
        a0: try #require(ids["blog/asset-0.png"]), a1: try #require(ids["blog/asset-1.png"]),
        a2: try #require(ids["notes/asset-2.png"]), a3: try #require(ids["blog/asset-3.png"])))
  }

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-thumbs-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  private func until(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}

extension GalleryModel.Row {
  fileprivate var usageFile: String? {
    if case let .reference(reference) = usage { return reference.file }
    return nil
  }

  fileprivate var usageUses: Int? {
    if case let .image(uses, _, _) = usage { return uses }
    return nil
  }
}
