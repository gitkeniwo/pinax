import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// The Library navigator's
/// Catalog group — a key-prefix tree loaded one level at a time, each
/// level queried once.
@MainActor
@Suite struct CatalogTreeTests {
  private func makeModel() throws -> (GalleryModel, URL) {
    let (model, _, directory) = try makeModel(keys: [
      "blog/202603/a.png", "blog/202603/b.png", "blog/202604/c.png", "notes/x.png",
    ])
    return (model, directory)
  }

  private func makeModel(
    keys: [String], archived: Set<String> = []
  ) throws -> (GalleryModel, DatabasePool, URL) {
    let (database, directory) = try makeUITestDatabase()
    for (index, key) in keys.enumerated() {
      try seedAsset(
        database, index: index, uploadedAt: "2026-03-0\(index + 1)T00:00:00Z", key: key)
    }
    for key in archived {
      try setState("archived", of: key, in: database)
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-catalog-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    return (model, database, directory)
  }

  private func setState(_ state: String, of key: String, in database: DatabasePool) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE asset SET state = ?, updated_at = ? WHERE key = ?",
        arguments: [state, "2026-09-23T00:00:00Z", key])
    }
  }

  private func level(_ model: GalleryModel, _ prefix: String?) -> [String] {
    (model.folderChildren[r2: prefix] ?? []).map { "\($0.segment):\($0.assetCount)" }
  }

  // MARK: - Levels load once

  @Test("Every prefix's children are queried once, however often its row opens")
  func eachPrefixIsQueriedOnce() async throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    await model.loadInitialData()
    #expect(model.folderChildrenFetchCount == 1, "the root, at launch")
    #expect(level(model, nil) == ["blog:3", "notes:1"])

    // Opened three times in a row and twice at once: one query.
    await model.loadFolderChildren(under: "blog")
    await model.loadFolderChildren(under: "blog")
    await model.loadFolderChildren(under: "blog")
    async let first: Void = model.loadFolderChildren(under: "notes")
    async let second: Void = model.loadFolderChildren(under: "notes")
    _ = await (first, second)
    #expect(model.folderChildrenFetchCount == 3, "root + blog + notes")
    #expect(level(model, "blog") == ["202603:2", "202604:1"])
    #expect(level(model, "notes") == [], "files only: fetched, and empty")

    // The root again, and a level that was already cached: no query.
    await model.loadFolderChildren(under: nil)
    await model.loadFolderChildren(under: "notes")
    #expect(model.folderChildrenFetchCount == 3)
    await model.loadFolderChildren(under: "blog/202603")
    #expect(model.folderChildrenFetchCount == 4)
  }

  @Test("Selecting a prefix loads exactly the assets under it, ungrouped")
  func prefixSelectionFiltersTheGrid() async throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.loadInitialData()

    model.select(.keyPrefix("blog/202603"), in: .library)
    #expect(model.makeQuery().keyPrefix == "blog/202603")
    await model.reload()
    #expect(model.rows.map(\.item.asset.key).sorted() == ["blog/202603/a.png", "blog/202603/b.png"])
    #expect(!model.groupsRowsByMonth, "the Catalog rows do not group")
  }

  // MARK: - Counts

  /// Opens every level of the Catalog tree, then selects each prefix row
  /// and reads the grid's total for it — `totalCount`, the status bar's
  /// count of `makeQuery()`. Returns how many rows were checked and every
  /// row whose number is not its grid's.
  private func rowsAgainstTheGrid(
    _ model: GalleryModel
  ) async -> (checked: Int, mismatches: [String]) {
    var frontier: [String?] = [nil]
    var rows: [(path: String, count: Int)] = []
    while let parent = frontier.popLast() {
      await model.loadFolderChildren(under: parent)
      for child in model.folderChildren[r2: parent] ?? [] {
        let path = parent.map { "\($0)/\(child.segment)" } ?? child.segment
        rows.append((path, child.assetCount))
        frontier.append(path)
      }
    }
    var mismatches: [String] = []
    for row in rows.sorted(by: { $0.path < $1.path }) {
      model.select(.keyPrefix(row.path), in: .library)
      await model.reload()
      if model.totalCount != row.count {
        mismatches.append("\(row.path): row \(row.count), grid \(model.totalCount ?? -1)")
      }
    }
    return (rows.count, mismatches)
  }

  @Test("Every Catalog row's number is the total of the grid it opens onto")
  func rowCountsAreGridTotals() async throws {
    // A pair of prefixes that differ only in case, and an archived image.
    let (model, _, directory) = try makeModel(
      keys: [
        "blog/202603/a.png", "blog/202603/b.png", "blog/202604/c.png", "blog/top.png",
        "Blog/202603/d.png", "blog_x/e.png", "notes/x.png",
      ],
      archived: ["blog/202604/c.png"])
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.loadInitialData()

    // The archived c.png has left every default grid, so it
    // has left the counts too — and blog/202604, holding nothing else, is
    // no longer a row.
    #expect(level(model, nil) == ["Blog:1", "blog:3", "blog_x:1", "notes:1"])
    let result = await rowsAgainstTheGrid(model)
    // Blog, blog, blog_x, notes, Blog/202603, blog/202603.
    #expect(result.checked == 6)
    #expect(result.mismatches == [])
  }

  /// The catalog changes under a running app — an archive, an upload (the
  /// drop zone's path: `loadInitialData`), a delete — and the counts
  /// still match after each, with no relaunch. Levels load once alongside it:
  /// one refetch per loaded level when the data moves, none when it
  /// does not.
  @Test("Catalog counts follow an archive, an upload and a delete without a relaunch")
  func countsFollowTheCatalog() async throws {
    let (model, database, directory) = try makeModel(keys: [
      "blog/202603/a.png", "blog/202603/b.png", "blog/202604/c.png", "notes/x.png",
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.loadInitialData()
    var result = await rowsAgainstTheGrid(model)
    #expect(result.checked == 4 && result.mismatches == [], "before any change")

    func step(_ name: String, _ change: () throws -> Void, via load: () async -> Void) async throws {
      try change()
      let levels = model.folderChildren.count
      let before = model.folderChildrenFetchCount
      await load()
      #expect(model.folderChildrenFetchCount == before + levels, "\(name): one refetch per level")
      await model.reload()
      #expect(model.folderChildrenFetchCount == before + levels, "\(name): same data, no refetch")
      result = await rowsAgainstTheGrid(model)
      #expect(result.mismatches == [], "after \(name)")
    }

    try await step("archive", { try setState("archived", of: "blog/202603/a.png", in: database) }) {
      await model.reload()
    }
    try await step(
      "upload",
      {
        try seedAsset(
          database, index: 10, uploadedAt: "2026-09-23T00:00:00Z", key: "blog/202609/u.png")
      }
    ) { await model.loadInitialData() }
    // The archived a.png is out of blog/202603's count.
    #expect(level(model, "blog") == ["202603:1", "202604:1", "202609:1"])
    try await step("delete", {
      try database.write { db in
        try db.execute(sql: "DELETE FROM asset WHERE key = ?", arguments: ["blog/202604/c.png"])
      }
    }) { await model.reload() }
    #expect(level(model, nil) == ["blog:2", "notes:1"])
    #expect(level(model, "blog") == ["202603:1", "202609:1"])
  }

  // MARK: - Selection

  /// The Catalog rows the sidebar draws right now, by path.
  private func catalogRows(_ model: GalleryModel) -> [String: SidebarEntry] {
    let entries = SidebarModel.sections(
      navigator: .library, projects: [], tags: [], months: [],
      folderChildren: model.folderChildren, catalogRoots: model.domainBackends.map(CatalogRoot.init)
    ).flatMap(\.entries).flatMap(\.flattened)
    var rows: [String: SidebarEntry] = [:]
    for entry in entries {
      if case let .keyPrefix(path, _) = entry.selection { rows[path] = entry }
    }
    return rows
  }

  /// A row shows a disclosure triangle iff some key below it has another
  /// `/` — judged on every row before it is ever opened, then its level is
  /// opened and must grow a row. Root: `202511` holds files only (the
  /// reported case), `blog` holds only sub-prefixes, `notes` holds both;
  /// one level down, `blog/202603` and `notes/drafts` hold files only.
  @Test("A prefix row shows a disclosure triangle iff it has a sub-prefix, before it opens")
  func disclosureTriangleDoesNotLie() async throws {
    let keys = [
      "202511/a.png", "202511/b.png",
      "blog/202603/a.png", "blog/202604/b.png",
      "notes/x.png", "notes/drafts/y.png",
    ]
    let (model, _, directory) = try makeModel(keys: keys)
    defer { try? FileManager.default.removeItem(at: directory) }
    func hasSubPrefix(_ path: String) -> Bool {
      keys.contains { $0.hasPrefix(path + "/") && $0.dropFirst(path.count + 1).contains("/") }
    }

    await model.loadInitialData()
    var judged: Set<String> = []
    var opened = 0
    while let (path, entry) = catalogRows(model).first(where: { !judged.contains($0.key) }) {
      judged.insert(path)
      #expect(entry.isExpandable == hasSubPrefix(path), "\(path), unopened")
      guard entry.isExpandable else { continue }
      await model.loadFolderChildren(under: path)
      opened += 1
      #expect(!(catalogRows(model)[path]?.children.isEmpty ?? true), "\(path) opened onto nothing")
    }
    #expect(judged == ["202511", "blog", "blog/202603", "blog/202604", "notes", "notes/drafts"])
    #expect(opened == 2, "blog and notes")
    #expect(model.folderChildrenFetchCount == 1 + opened, "the root, then each once")
  }

  // MARK: - The hosted outline

  /// The tree grows inside one outline when a level loads — the kind of
  /// change that once left a ghost row behind (there, a whole tree
  /// swapped). The outline's integrity is checked after the insertion,
  /// and the new rows select both ways.
  @Test("Opening a prefix loads its level into the outline; its rows select both ways")
  func openingAPrefixInTheOutline() async throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.loadInitialData()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(until: { self.sidebarOutline(in: window.contentView)?.numberOfRows == 10 })
    let outline = try #require(sidebarOutline(in: window.contentView), "no sidebar outline")

    // Library header, All Assets, Recent, Favorites, Archived, Storage
    // header, the backend's root (open from the start), blog, notes, and
    // the Projects shortcut — shown by default, closed, so
    // its header alone.
    #expect(outline.numberOfRows == 10)
    #expect(model.folderChildrenFetchCount == 1)

    // The row opens by its square; the new level sits
    // flat in the outline, indented by the row itself.
    await clickSidebarSquare(row: 7, depth: 1, in: outline, window: window)
    await spin(until: { outline.numberOfRows == 12 })
    #expect(outline.numberOfRows == 12, "blog › 202603, 202604")
    #expect(model.folderChildrenFetchCount == 2)
    // Past the outline's own expand animation, which moves row views.
    await spin(0.5)
    expectIntact(outline)

    outline.selectRowIndexes(IndexSet(integer: 8), byExtendingSelection: false)
    await spin(until: { model.sidebarSelection == .keyPrefix("blog/202603") })
    #expect(model.sidebarSelection == .keyPrefix("blog/202603"))
    model.sidebarSelection = .keyPrefix("blog/202604")
    await spin(until: { outline.selectedRow == 9 })
    #expect(outline.selectedRow == 9)

    // Closing and reopening the row does not query again.
    await clickSidebarSquare(row: 7, depth: 1, in: outline, window: window)
    await spin(until: { outline.numberOfRows == 10 })
    await clickSidebarSquare(row: 7, depth: 1, in: outline, window: window)
    await spin(until: { outline.numberOfRows == 12 })
    #expect(model.folderChildrenFetchCount == 2)
    await spin(0.5)
    expectIntact(outline)
  }

  /// No row view that belongs to no row, and every visible row view where
  /// its row is — the check `LayoutStabilityTests` makes after a navigator switch.
  private func expectIntact(_ outline: NSOutlineView) {
    var views: [NSTableRowView] = []
    outline.enumerateAvailableRowViews { rowView, _ in views.append(rowView) }
    let visible = outline.subviews.compactMap { $0 as? NSTableRowView }.filter { !$0.isHidden }
    #expect(visible.allSatisfy { outline.row(for: $0) >= 0 }, "a row view that belongs to no row")
    for rowView in views {
      let row = outline.row(for: rowView)
      #expect(rowView.frame == outline.rect(ofRow: row), "row \(row)")
    }
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func spin(until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
  }

  private func sidebarOutline(in view: NSView?) -> NSOutlineView? {
    guard let view else { return nil }
    var stack: [NSView] = [view]
    while let next = stack.popLast() {
      if let outline = next as? NSOutlineView { return outline }
      stack.append(contentsOf: next.subviews)
    }
    return nil
  }
}
