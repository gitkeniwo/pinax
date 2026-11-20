import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Selection, the model half. Properties, not outcomes:
///
/// 1. Selection changes never restart the query: `reloadToken` does not carry
///    the selection (`ReadOnlyCatalog` is concrete, so
///    there is no seam to count `page` calls through a fake).
/// 3. A right-click outside the selection targets that cell alone and
///    selects only it; inside a selection of two or more it targets the set.
/// 4. ⇧ extends from `selectionAnchor`: A, ⌘C, ⇧E is A + C…E, not A…E.
/// 5. `selectedID` is nil while two or more rows are selected, so the
///    inspector's single-item details are not loaded.
@MainActor
@Suite(.serialized) struct SelectionModelTests {
  // MARK: - 1. Selection is not a query

  @Test("No selection change moves the reload token or the query")
  func selectionIsNotAQueryInput() async throws {
    try await withModel(count: 4) { model, _ in
      let view = GalleryView(model: model)
      let token = view.reloadToken
      let query = model.makeQuery()
      let rows = model.rows
      #expect(rows.count == 4)

      model.select(rows[0], mode: .replace)
      #expect(view.reloadToken == token)
      model.select(rows[2], mode: .toggle)
      #expect(view.reloadToken == token)
      model.select(rows[3], mode: .extend)
      #expect(view.reloadToken == token)
      model.selectAllLoaded()
      #expect(model.selectedIDs.count == 4)
      #expect(view.reloadToken == token)
      model.clearSelection()
      #expect(view.reloadToken == token)
      #expect(model.makeQuery() == query)
    }
  }

  // MARK: - 3. Right-click target

  @Test("Right-click outside the selection targets and selects only that cell")
  func rightClickOutsideSelection() async throws {
    try await withModel(count: 4) { model, _ in
      let rows = model.rows
      model.select(rows[0], mode: .replace)
      model.select(rows[1], mode: .toggle)
      #expect(model.selectedIDs == [rows[0].id, rows[1].id])

      let target = try #require(copyTarget(model.contextMenuItems(for: rows[2])))
      guard case let .row(row) = target else {
        Issue.record("expected a single-row target, got \(target)")
        return
      }
      #expect(row.rowID == rows[2].id)

      let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("PinaxSelectionModelTests-\(UUID().uuidString)"))
      model.copyURL(for: target, to: pasteboard)
      #expect(model.selectedIDs == [rows[2].id])
      #expect(pasteboard.string(forType: .string) == rows[2].item.url)
    }
  }

  @Test("Right-click inside a multi-selection targets the whole selection")
  func rightClickInsideSelection() async throws {
    try await withModel(count: 4) { model, _ in
      let rows = model.rows
      model.select(rows[0], mode: .replace)
      model.select(rows[2], mode: .toggle)
      let selection: Set<Int64> = [rows[0].id, rows[2].id]

      let items = model.contextMenuItems(for: rows[2])
      // The menu's item set is untouched by the selection.
      #expect(items.map(\.id) == [
        "copyURL", "copyAs", "downloadOriginal", "addTag", "addToProject", "editNote",
        "favorite", "label", "archive",
      ])
      let target = try #require(copyTarget(items))
      #expect(target == .selection([rows[0].id, rows[2].id]))

      await model.addTag("both", to: target)
      #expect(model.selectedIDs == selection)
      for row in rows {
        let tags = try await model.catalog.details(row.item.asset.sha256).tags
        #expect(tags == (selection.contains(row.id) ? ["both"] : []), "\(row.id)")
      }
    }
  }

  // MARK: - 4. Shift extends from the anchor

  @Test("Shift-extend ranges from the anchor, keeping earlier toggles")
  func extendRangesFromAnchor() async throws {
    try await withModel(count: 5) { model, _ in
      let rows = model.rows  // display order: A B C D E
      model.select(rows[0], mode: .replace)
      model.select(rows[2], mode: .toggle)
      #expect(model.selectionAnchor == rows[2].id)
      model.select(rows[4], mode: .extend)

      #expect(model.selectedIDs == Set([0, 2, 3, 4].map { rows[$0].id }))
      #expect(model.selectionAnchor == rows[2].id)
    }
  }

  // MARK: - 5. No details for a multi-selection

  @Test("selectedID is nil under multi-selection and no single details load")
  func multiSelectionLoadsNoDetails() async throws {
    try await withModel(count: 3) { model, _ in
      let rows = model.rows
      model.select(rows[0], mode: .replace)
      #expect(model.selectedID == rows[0].id)
      // Positive control: the single path really loads details.
      await waitUntil { model.selectedDetails?.item.asset.id == rows[0].id }
      #expect(model.selectedDetails != nil)

      model.select(rows[1], mode: .toggle)
      #expect(model.selectedID == nil)
      await waitUntil { model.selectedDetails == nil }
      try? await Task.sleep(nanoseconds: 100_000_000)
      #expect(model.selectedDetails == nil)
      #expect(model.selectedIdentifier == nil)

      let bytes = rows[0].item.asset.byteSize + rows[1].item.asset.byteSize
      #expect(
        GalleryStatusBar(model: model).selectionSummary
          == "2 selected · \(PinaxFormat.fileSize(bytes))")
    }
  }

  // MARK: - 2. Plain click

  @Test("A page append leaves the selection and its anchor exactly as they were")
  func pageAppendKeepsSelection() async throws {
    try await withModel(count: 130) { model, _ in
      let rows = model.rows
      #expect(rows.count == 120)
      #expect(model.canLoadMore)
      model.select(rows[3], mode: .replace)
      model.select(rows[7], mode: .toggle)
      model.select(rows[119], mode: .toggle)
      let selected = model.selectedIDs
      let anchor = model.selectionAnchor

      await model.loadNextPage()
      #expect(model.rows.count == 130)
      #expect(model.selectedIDs == selected)
      #expect(model.selectionAnchor == anchor)

      // The anchor still ranges into the appended rows.
      model.select(model.rows[121], mode: .extend)
      #expect(model.selectedIDs == selected.union(model.rows[119...121].map(\.id)))
    }
  }

  // MARK: - Click modifiers

  @Test("A cell click maps ⇧ to extend, ⌘ to toggle, nothing to replace")
  func clickModifiers() {
    #expect(AssetGridView.selectionMode(for: []) == .replace)
    #expect(AssetGridView.selectionMode(for: .command) == .toggle)
    #expect(AssetGridView.selectionMode(for: .shift) == .extend)
    #expect(AssetGridView.selectionMode(for: [.shift, .command]) == .extend)
    // Caps Lock and the like do not turn a plain click into anything else.
    #expect(AssetGridView.selectionMode(for: [.capsLock, .numericPad]) == .replace)
  }

  // MARK: - Bulk unlink confirmation

  @Test("Unchecking a project for a multi-selection asks once, titled with the count")
  func bulkUnlinkConfirms() async throws {
    try await withModel(count: 3, projectSlug: "blog") { model, database in
      let rows = model.rows
      // One member has live usage; without confirmation it would refuse and
      // the other would silently leave the project.
      try seedLiveUsage(
        database, projectSlug: "blog", sha256: rows[0].item.asset.sha256, count: 2)
      model.select(rows[0], mode: .replace)
      model.select(rows[1], mode: .toggle)
      #expect(model.selectionMembership(ofProject: "blog") == true)

      await model.setProjectMembershipForSelection(false, slug: "blog")
      let pending = try #require(model.pendingSelectionUnlink)
      #expect(pending.title == "Remove 2 items from “Blog”?")
      #expect(pending.confirmLabel
        == "Remove anyway — the images will disappear from this project's manifest")
      #expect(try memberCount(database, slug: "blog") == 3)

      model.cancelSelectionUnlink()
      #expect(model.pendingSelectionUnlink == nil)
      #expect(try memberCount(database, slug: "blog") == 3)

      await model.setProjectMembershipForSelection(false, slug: "blog")
      let asked = try #require(model.pendingSelectionUnlink)
      // As the dialog does: dismissal clears the pending value first.
      model.cancelSelectionUnlink()
      await model.confirmSelectionUnlink(asked)
      #expect(model.pendingSelectionUnlink == nil)
      #expect(try memberCount(database, slug: "blog") == 1)
      #expect(model.selectionMembership(ofProject: "blog") == false)

      // Checking acts at once, without asking.
      await model.setProjectMembershipForSelection(true, slug: "blog")
      #expect(model.pendingSelectionUnlink == nil)
      #expect(model.selectionMembership(ofProject: "blog") == true)
    }
  }

  // MARK: - Helpers

  private func memberCount(_ database: DatabasePool, slug: String) throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM asset_project
        JOIN project ON project.id = asset_project.project_id
        WHERE project.slug = ?
        """, arguments: [slug]) ?? 0
    }
  }

  private func copyTarget(
    _ items: [GalleryModel.ContextMenuItem]
  ) -> GalleryModel.ContextMenuTarget? {
    items.compactMap { item -> GalleryModel.ContextMenuTarget? in
      guard case let .copyURL(target) = item else { return nil }
      return target
    }.first
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func withModel(
    count: Int, projectSlug: String? = nil,
    _ body: (GalleryModel, DatabasePool) async throws -> Void
  ) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<count {
      try seedAsset(
        database, index: index,
        uploadedAt: String(format: "2026-08-20T%02d:%02d:00Z", 12 - index / 60, 59 - index % 60),
        projectSlug: projectSlug)
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    try await body(model, database)
  }
}
