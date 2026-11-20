import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// The table's rows carry the grid's context menu, with the grid's
/// targets — a right-click outside the selection acts on that row
/// alone and selects it; inside a selection of two or more, on the whole
/// selection. Read through the app's own `AssetTableView`: its rows are
/// built from the `ForEach` the view declares (flat and month-grouped), and
/// each row's menu is the `AssetContextMenuItems` its `TableRow` stores. No
/// menu is opened.
@MainActor
@Suite(.serialized) struct TableContextMenuTests {
  /// Six assets, ids 1–3 uploaded in July, 4–6 in August. The table shows
  /// newest first, so display order is 6, 5, 4, 3, 2, 1 — not id order.
  private func withModel(_ body: (GalleryModel) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<6 {
      let month = index < 3 ? "07" : "08"
      try seedAsset(database, index: index, uploadedAt: "2026-\(month)-0\(index + 1)T00:00:00Z")
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await model.loadInitialData()
    try await body(model)
  }

  /// The rows the app's table declares, flat or through its month sections.
  private func tableRows(_ model: GalleryModel) -> [AssetTableRow] {
    let body = AssetTableView(model: model).body
    if let sections = firstView(in: body, typePrefix: "ForEach<") as? TableSectionsForEach {
      return sections.sections().flatMap { section in
        (firstView(in: section.tableRowBody, typePrefix: "ForEach<") as? TableRowsForEach)?
          .tableRows() ?? []
      }
    }
    return (firstView(in: body, typePrefix: "ForEach<") as? TableRowsForEach)?.tableRows() ?? []
  }

  /// The menu a row's `TableRow` stores, as its items and their views.
  private func menu(_ row: AssetTableRow) -> MenuForEach? {
    guard let items = firstView(in: row.tableRowBody, typePrefix: "AssetContextMenuItems")
      as? AssetContextMenuItems
    else { return nil }
    return firstView(in: items.body, typePrefix: "ForEach<") as? MenuForEach
  }

  private func target(_ menu: MenuForEach?) -> GalleryModel.ContextMenuTarget? {
    guard case let .copyURL(target)? = menu?.menuItems().first else { return nil }
    return target
  }

  private func row(_ id: Int64, in rows: [AssetTableRow]) throws -> AssetTableRow {
    try #require(rows.first { $0.row.id == id }, "no table row \(id)")
  }

  /// Presses the menu's Add Tag… as the app's view declares it: the action
  /// selects the target, the way every item's does.
  private func pressAddTag(_ menu: MenuForEach?) {
    let action = menu?.views().lazy.compactMap { view in
      buttonAction(in: view) { label in
        "\(Mirror(reflecting: label).descendant("storage", "anyTextStorage", "key") ?? "")"
          .contains("Add Tag")
      }
    }.first
    #expect(action != nil, "Add Tag… not found in the row's menu")
    action?()
  }

  private func check(_ model: GalleryModel) throws {
    let rows = tableRows(model)
    #expect(rows.map(\.row.id) == [6, 5, 4, 3, 2, 1])
    // Add Tag… and Edit Note… open the gallery's editor, whose popover
    // hangs on each row's Name cell (ContextEditorPopoverTests).

    // Nothing selected: every row's menu is its own.
    model.clearSelection()
    for row in rows {
      guard case let .row(target)? = target(menu(row)) else {
        Issue.record("row \(row.row.id): no single-row target")
        continue
      }
      #expect(target.rowID == row.row.id)
    }

    // Outside a selection of two: that row alone, and the action selects it.
    model.selectedIDs = [6, 5]
    let outside = menu(try row(3, in: rows))
    guard case let .row(single)? = target(outside) else {
      Issue.record("expected a single-row target, got \(String(describing: target(outside)))")
      return
    }
    #expect(single.rowID == 3)
    pressAddTag(outside)
    #expect(model.selectedIDs == [3])

    // Inside a selection: the whole selection, in display order (5, 4, 2 —
    // neither id order nor the order it was clicked in), and the selection
    // stands.
    model.select(rows[1].row, mode: .replace)
    model.select(rows[4].row, mode: .toggle)
    model.select(rows[2].row, mode: .toggle)
    #expect(model.selectedIDs == [5, 2, 4])
    let inside = menu(try row(2, in: rows))
    #expect(target(inside) == .selection([5, 4, 2]))
    pressAddTag(inside)
    #expect(model.selectedIDs == [5, 2, 4])
  }

  @Test("Table rows carry the grid's context menu and its targets")
  func flatTable() async throws {
    try await withModel { model in
      model.groupsByMonth = false
      #expect(!model.groupsRowsByMonth)
      try check(model)
    }
  }

  @Test("Month-grouped table rows carry the same menu and targets")
  func groupedTable() async throws {
    try await withModel { model in
      model.groupsByMonth = true
      #expect(model.groupsRowsByMonth)
      #expect(model.groupedRows.count == 2)
      try check(model)
    }
  }
}

private protocol TableRowsForEach { func tableRows() -> [AssetTableRow] }
extension ForEach: TableRowsForEach where Content == AssetTableRow {
  fileprivate func tableRows() -> [AssetTableRow] { data.map { content($0) } }
}

private protocol TableSectionsForEach { func sections() -> [AssetTableSection] }
extension ForEach: TableSectionsForEach where Content == AssetTableSection {
  fileprivate func sections() -> [AssetTableSection] { data.map { content($0) } }
}

private protocol MenuForEach {
  func menuItems() -> [GalleryModel.ContextMenuItem]
  func views() -> [Any]
}
extension ForEach: MenuForEach where Data == [GalleryModel.ContextMenuItem] {
  fileprivate func menuItems() -> [GalleryModel.ContextMenuItem] { data }
  fileprivate func views() -> [Any] { data.map { content($0) } }
}
