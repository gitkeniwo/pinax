import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Project rows open onto their source folders and
/// files, the Tags header's `+`, the Time tab's default open year, and the
/// tab bar's icons and names.
@MainActor
@Suite struct SidebarProjectRowsTests {
  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-s2-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  private func until(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// Blog: three assets; a0 twice in a.md and once in b.md, a1 in a.md,
  /// a2 in src/pages/index.astro. Notes has no references.
  private func seed(_ database: DatabasePool) throws -> [Int64] {
    for index in 0..<3 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
    }
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO scan (id, project_id, started_at, finished_at)
          VALUES (1, 1, '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z');
          UPDATE project SET last_scan_id = 1 WHERE slug = 'blog';
          """)
      let references: [(Int, String)] = [
        (0, "src/content/blog/a.md#L1"), (0, "src/content/blog/a.md#L5"),
        (1, "src/content/blog/a.md#L3"), (0, "src/content/blog/b.md#L2"),
        (2, "src/pages/index.astro#L4"),
      ]
      for (index, source) in references {
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            SELECT 1, a.id, 'https://img.example.com/' || a.key, ?, 'markdown',
              '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z', 1
            FROM asset a WHERE a.key = ?
            """,
          arguments: [source, "blog/asset-\(index).png"])
      }
    }
    return try database.read { db in
      try (0..<3).map { index in
        try #require(
          try Int64.fetchOne(
            db, sql: "SELECT id FROM asset WHERE key = ?", arguments: ["blog/asset-\(index).png"]))
      }
    }
  }

  private func collections(_ model: GalleryModel) -> [SidebarSection] {
    SidebarModel.sections(
      navigator: .collections, projects: model.projects, tags: model.tags, months: [],
      folderChildren: [:], projectFolders: model.projectFolders)
  }

  // MARK: - Item 1: project rows open to folders and files

  @Test("Project rows: lazy first load, merged folders, files, distinct-image counts, the row's own count kept")
  func projectRows() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try seed(database)
    let model = makeModel(database)
    await model.loadInitialData()
    model.navigator = .collections

    let before = try #require(collections(model).first { $0.id == "projects" })
    let blog = try #require(before.entries.first { $0.selection == .project("blog") })
    let notes = try #require(before.entries.first { $0.selection == .project("notes") })
    #expect(blog.expandsLazily && blog.children.isEmpty, "opens, nothing fetched yet")
    #expect(!notes.isExpandable, "no references: a plain row")
    #expect(model.projectUsageFetchCount == 0, "nothing until the row opens")

    var expanded: Set<String> = []
    SidebarDisclosure.setExpanded(true, entry: blog, expandedRows: &expanded, model: model)
    await until { model.projectFolders["blog"] != nil }
    #expect(expanded.contains(blog.id))
    #expect(model.projectUsageFetchCount == 1)
    await model.loadProjectFolders("blog")
    #expect(model.projectUsageFetchCount == 1, "a loaded project is read once")

    let after = try #require(
      collections(model).first { $0.id == "projects" }?.entries.first { $0.selection == .project("blog") })
    #expect(after.count == 3, "the project row still counts its members")
    #expect(after.countHelp == "Assets in this project")
    #expect(after.children.map(\.label) == ["src/content/blog", "src/pages"])
    #expect(after.children.map(\.count) == [2, 1], "distinct images, not references")
    let blogFolder = after.children[0]
    #expect(blogFolder.selection == .projectFolder("blog", directory: "src/content/blog"))
    #expect(blogFolder.children.map(\.label) == ["a.md", "b.md"])
    #expect(blogFolder.children.map(\.count) == [2, 1])
    #expect(blogFolder.children.map(\.systemImage) == ["doc.text.fill", "doc.text.fill"])
    #expect(blogFolder.children.allSatisfy { !$0.isExpandable })

    // The Library tab's Projects shortcut keeps leaves.
    let shortcut = SidebarModel.sections(
      navigator: .library, projects: model.projects, tags: [], months: [], folderChildren: [:],
      libraryShortcuts: [.projects], projectFolders: model.projectFolders
    ).first { $0.id == "projects" }
    #expect(shortcut?.entries.allSatisfy { !$0.isExpandable } == true)
  }

  @Test("Selecting a folder or file shows the images it uses; the jump bar walks Projects › project › folder › file")
  func projectSourceSelection() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ids = try seed(database)
    let model = makeModel(database)
    await model.loadInitialData()
    model.navigator = .collections

    let file = SidebarSelection.projectFile("blog", path: "src/content/blog/a.md")
    model.sidebarSelection = file
    await model.reload()
    await until { model.rows.map(\.id) == [ids[0], ids[1]] }
    #expect(model.rows.map(\.id) == [ids[0], ids[1]], "a0 once, though used twice")
    #expect(model.shownSelection == file)
    #expect(model.totalCount == 2)

    model.sidebarSelection = .projectFolder("blog", directory: "src/content/blog")
    await model.reload()
    #expect(Set(model.rows.map(\.id)) == [ids[0], ids[1]])
    #expect(model.rows.count == 2)
    model.sidebarSelection = .projectFolder("blog", directory: "src/pages")
    await model.reload()
    #expect(model.rows.map(\.id) == [ids[2]])

    let path = JumpBar.components(
      selection: file, navigator: .collections, projects: model.projects, tags: [], months: [],
      folderChildren: [:], projectFolders: model.projectFolders, selectedName: nil
    ).map(\.label)
    #expect(path == ["Projects", "Blog", "src/content/blog", "a.md"])
    #expect(
      WindowTitle.compose(selection: file, projects: model.projects, currentProjectSlug: nil).title
        == "a.md")

    // Every row of the tab maps back to it, and ids stay unique.
    let rows = collections(model).flatMap(\.entries).flatMap(\.flattened)
    #expect(rows.contains { $0.selection == file })
    for row in rows {
      #expect(SidebarModel.navigator(for: row.selection) == .collections, "\(row.id)")
    }
    #expect(Set(rows.map(\.id)).count == rows.count)
  }

  // MARK: - Item 2: Tags header +

  @Test("Tags: no No Tags row, a + on the header with or without tags; + opens Add Tag on the selection")
  func tagsHeader() async throws {
    let empty = try #require(
      SidebarModel.sections(
        navigator: .collections, projects: [], tags: [], months: [], folderChildren: [:]
      ).first { $0.id == "tags" })
    #expect(empty.entries.isEmpty)
    #expect(empty.action == .addTag)
    let some = try #require(
      SidebarModel.sections(
        navigator: .collections, projects: [], tags: [TagSummary(name: "cats", assetCount: 2)],
        months: [], folderChildren: [:]
      ).first { $0.id == "tags" })
    #expect(some.action == .addTag)
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PinaxUI/Sidebar/SidebarView.swift"),
      encoding: .utf8)
    #expect(!source.contains("Text(\"No Tags\")"))

    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ids = try seed(database)
    let model = makeModel(database)
    await model.loadInitialData()
    #expect(!model.canBeginTagAddition, "nothing selected, nothing to tag")
    model.beginTagAddition()
    #expect(model.contextEditor == nil)
    model.selectedIDs = [ids[1]]
    #expect(model.canBeginTagAddition)
    model.beginTagAddition()
    #expect(model.contextEditor?.kind == .tag)
    #expect(model.contextEditor?.anchor == ids[1])
  }

  // MARK: - Item 3: Time tab's default open year

  @Test("Time: the current year opens by default, else the newest; a closed year is not reopened")
  func timeDefault() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6)))
    let withCurrent: [(month: String, count: Int)] = [("2026-01", 8), ("2025-06", 219), ("2024-03", 41)]
    #expect(SidebarModel.defaultOpenYear(months: withCurrent, now: now, calendar: calendar) == "2026")
    let older: [(month: String, count: Int)] = [("2025-06", 219), ("2024-03", 41)]
    #expect(SidebarModel.defaultOpenYear(months: older, now: now, calendar: calendar) == "2025")
    #expect(SidebarModel.defaultOpenYear(months: [], now: now, calendar: calendar) == nil)

    let id = SidebarModel.rowID(for: .year("2026"), in: .time)
    var seeded: Set<String> = []
    var expanded: Set<String> = []
    SidebarDisclosure.seed([id], seeded: &seeded, expanded: &expanded)
    #expect(expanded == [id])
    expanded.remove(id)  // the user closes it
    SidebarDisclosure.seed([id], seeded: &seeded, expanded: &expanded)
    #expect(expanded.isEmpty, "the user's choice stands")
  }

  @Test("The model offers the Time tab's default year row")
  func timeDefaultRow() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try seed(database)
    let model = makeModel(database)
    await model.loadInitialData()
    let year = try #require(SidebarModel.defaultOpenYear(months: model.availableMonths))
    #expect(model.timeDefaultOpenRowID == "time:year:\(year)")
    let row = SidebarModel.sections(
      navigator: .time, projects: [], tags: [], months: model.availableMonths, folderChildren: [:]
    ).flatMap(\.entries).first { $0.id == model.timeDefaultOpenRowID }
    #expect(row?.children.isEmpty == false, "it opens onto months")
  }

  // MARK: - Item 4: tab icons and names

  @Test("Tabs: four symbols that resolve, four names")
  func tabs() {
    #expect(
      SidebarNavigator.allCases.map(\.systemImage)
        == ["folder", "calendar", "square.stack.fill", "chart.bar.fill"])
    #expect(
      SidebarNavigator.allCases.map(\.title) == ["Library", "Time", "Projects and Tags", "Reports"])
    for navigator in SidebarNavigator.allCases {
      #expect(NSImage(systemSymbolName: navigator.systemImage, accessibilityDescription: nil) != nil)
    }
    // The jump bar's first segment stays the section's name.
    #expect(
      JumpBar.components(
        selection: .project("blog"), navigator: .collections,
        projects: [ProjectSummary(slug: "blog", name: "Blog", assetCount: 1, liveUsageCount: 0, lastScanAt: nil)],
        tags: [], months: [], folderChildren: [:], selectedName: nil
      ).first?.label == "Projects")
  }
}
