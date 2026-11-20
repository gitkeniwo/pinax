import AppKit
import CatalogCore
import GRDB
import PinaxUI
import Testing

@MainActor
@Suite(.serialized) struct AssetContextMenuTests {
  @Test("A context-menu edit targets the right-clicked cell, not the prior selection")
  func editTargetsContextCell() async throws {
    try await withModel { model, database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", projectSlug: nil)
      try seedAsset(database, index: 1, uploadedAt: "2026-08-20T12:01:00Z", projectSlug: nil)
      await model.loadInitialData()

      let a = try #require(model.rows.first { $0.item.asset.sha256 == String(format: "%064x", 1) })
      let b = try #require(model.rows.first { $0.item.asset.sha256 == String(format: "%064x", 2) })
      model.select(a)
      await waitForDetails(model, identifier: a.item.asset.sha256)

      // Positive control: the model says this cell really has the action the
      // test is about; no rendered Button/text introspection is involved.
      let items = model.contextMenuItems(for: b)
      let target = try #require(items.compactMap { item -> GalleryModel.ContextMenuTarget? in
        guard case let .addTag(target) = item else { return nil }
        return target
      }.first)
      #expect(items.contains { $0.id == "addTag" })

      // Drive the same explicit-target action the menu's submit button uses.
      await model.addTag("right-click-target", to: target)
      #expect(model.selectedIdentifier == b.item.asset.sha256)

      let aDetails = try await model.catalog.details(a.item.asset.sha256)
      let bDetails = try await model.catalog.details(b.item.asset.sha256)
      #expect(aDetails.tags.isEmpty)
      #expect(bDetails.tags == ["right-click-target"])
    }
  }

  @Test("Copy URL copies the cell's public URL and writes no catalog row")
  func copyURLIsReadOnly() async throws {
    try await withModel { model, database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", projectSlug: nil)
      await model.loadInitialData()
      let row = try #require(model.rows.first)

      // Positive control for the action whose pasteboard consequence follows.
      let items = model.contextMenuItems(for: row)
      let target = try #require(items.compactMap { item -> GalleryModel.ContextMenuTarget? in
        guard case let .copyURL(target) = item else { return nil }
        return target
      }.first)
      #expect(items.contains { $0.id == "copyURL" })
      let before = try tableDump(database)
      let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("PinaxAssetContextMenuTests-\(UUID().uuidString)"))

      model.copyURL(for: target, to: pasteboard)

      #expect(pasteboard.string(forType: .string) == row.item.url)
      #expect(try tableDump(database) == before)
    }
  }

  @Test("Add to Project lists catalog projects and existing membership is idempotent")
  func projectDestinationsAndMembership() async throws {
    try await withModel { model, database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", projectSlug: nil)
      try seedAsset(database, index: 1, uploadedAt: "2026-08-20T12:01:00Z")
      await model.loadInitialData()
      let selected = try #require(
        model.rows.first { $0.item.asset.sha256 == String(format: "%064x", 1) })
      let row = try #require(
        model.rows.first { $0.item.asset.sha256 == String(format: "%064x", 2) })
      model.select(selected)
      await waitForDetails(model, identifier: selected.item.asset.sha256)

      // Real ordering: initial loading published this row with its menu data;
      // the right-clicked row itself has never been selected.
      #expect(model.selectedIdentifier == selected.item.asset.sha256)

      let items = model.contextMenuItems(for: row)
      let projectItem = try #require(items.compactMap { item -> (
        GalleryModel.ContextMenuTarget, [GalleryModel.ContextMenuProject]
      )? in
        guard case let .addToProject(target, projects) = item else { return nil }
        return (target, projects)
      }.first)
      let (target, destinations) = projectItem
      // Positive control plus the complete catalog-derived submenu contract.
      #expect(items.contains { $0.id == "copyURL" })
      #expect(destinations.map(\.slug) == ["blog", "notes"])
      #expect(destinations.first { $0.slug == "blog" }?.isMember == true)
      #expect(destinations.first { $0.slug == "notes" }?.isMember == false)

      let beforeExistingAddition = try tableDump(database)
      await model.setProjectMembership(true, slug: "blog", for: target)
      #expect(try tableDump(database) == beforeExistingAddition)

      await model.setProjectMembership(true, slug: "notes", for: target)
      #expect(Set(model.selectedDetails?.projects.map(\.slug) ?? []) == Set(["blog", "notes"]))
    }
  }

  @Test("The four-item model menu exists for regular, Recent, and Orphans grids")
  func menuExistsForEveryGridSource() async throws {
    try await withModel { model, database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", projectSlug: nil)
      await model.loadInitialData()
      let row = try #require(model.rows.first)
      let expectedIDs = [
        "copyURL", "copyAs", "downloadOriginal", "addTag", "addToProject", "editNote",
        "favorite", "label", "archive",
      ]

      for selection in [
        GalleryModel.SidebarSelection.all,
        .recent,
        .orphans,
      ] {
        model.sidebarSelection = selection
        let items = model.contextMenuItems(for: row)
        // Copy URL is the positive control for each source. The exact list is
        // also the negative assertion: no delete/remove/move/bulk case exists.
        #expect(items.contains { $0.id == "copyURL" })
        #expect(items.map(\.id) == expectedIDs)
      }
    }
  }

  private func withModel(
    _ body: (GalleryModel, DatabasePool) async throws -> Void
  ) async throws {
    let (database, directory) = try makeUITestDatabase()
    let cacheDirectory = directory.appendingPathComponent("thumbnails", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: cacheDirectory,
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    try await body(model, database)
  }

  private func waitForDetails(_ model: GalleryModel, identifier: String) async {
    for _ in 0..<100 {
      if model.selectedDetails?.item.asset.sha256 == identifier { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  /// Every column of every catalog table. Sorting complete row descriptions
  /// makes the dump stable while preserving duplicates and all scalar values.
  private func tableDump(_ database: DatabasePool) throws -> String {
    try database.read { db in
      let tableNames = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
          ORDER BY name
          """
      )
      return try tableNames.map { tableName in
        let quoted = "\"" + tableName.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(quoted)")
          .map(\.description)
          .sorted()
        return tableName + ":\n" + rows.joined(separator: "\n")
      }.joined(separator: "\n")
    }
  }
}
