import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// After a curation action takes the selected images off the surface, the
/// selection hands off; when they stay, it does not move; Edit ▸ Delete
/// Permanently… is always in the menu. No
/// remote call: every image deleted here is a PicGo import (catalog only),
/// and the deleter's remote throws and counts.
@MainActor
@Suite struct SelectionHandOffTests {
  nonisolated static func sha(_ index: Int) -> String { String(format: "%064x", index + 1) }

  final class RemoteCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
  }

  struct Fixture {
    let model: GalleryModel
    let database: DatabasePool
    let directory: URL
    let remoteCalls: RemoteCalls
  }

  /// `count` images, index i uploaded on day i + 1: the grid shows them
  /// newest first, so the display order is count − 1 … 0. `archived` start
  /// archived, as PicGo imports (Delete removes their rows only).
  func makeFixture(count: Int = 5, archived: Set<Int> = []) throws -> Fixture {
    let (database, directory) = try makeUITestDatabase()
    for index in 0..<count {
      try seedAsset(
        database, index: index,
        uploadedAt: String(
          format: "2026-08-%02dT%02d:%02d:00Z", 1 + index / 96, index % 96 / 4, index % 4 * 15),
        key: "blog/\(index).png")
    }
    try database.write { db in
      try db.execute(sql: "UPDATE backend SET endpoint = 'https://t28.invalid' WHERE id = 1")
      for index in archived {
        try db.execute(
          sql: """
            UPDATE asset SET state = 'archived', meta = '{\"imported_from\":\"picgo\"}'
            WHERE sha256 = ?
            """, arguments: [Self.sha(index)])
      }
    }
    let calls = RemoteCalls()
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let originals = OriginalImageCache(
      cacheDirectory: directory.appendingPathComponent("originals", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      deleter: DeletingCatalog(database: database) { _ in
        calls.record()
        throw URLError(.cannotFindHost)
      },
      thumbnails: thumbnails,
      quickLook: QuickLookController(thumbnails: thumbnails, originals: originals))
    model.currentEvent = { nil }
    model.shareCacheFolder = directory.appendingPathComponent("share", isDirectory: true)
    return Fixture(model: model, database: database, directory: directory, remoteCalls: calls)
  }

  func show(_ selection: SidebarSelection, _ model: GalleryModel) async {
    model.select(selection, in: SidebarModel.navigator(for: selection))
    await model.reload()
  }

  func rowID(_ index: Int, _ model: GalleryModel) throws -> Int64 {
    try #require(model.rows.first { $0.item.asset.sha256 == Self.sha(index) }?.id)
  }

  /// The selection as image indices, and what the inspector shows.
  func selected(_ model: GalleryModel) -> Set<Int> {
    Set(
      model.rows.filter { model.selectedIDs.contains($0.id) }.compactMap { row in
        Int(row.item.asset.sha256, radix: 16).map { $0 - 1 }
      })
  }

  func inspected(_ model: GalleryModel) -> String? {
    model.selectedDetails?.item.asset.sha256
  }

  // MARK: - The pure hand-off

  @Test("Hand-off: the row after the last removed, else before it; nil when nothing is left")
  func handOffFunction() {
    let order: [Int64] = [10, 20, 30, 40, 50]
    #expect(GalleryModel.handOff(order: order, removed: [30]) == 40, "middle: the next")
    #expect(GalleryModel.handOff(order: order, removed: [50]) == 40, "end: the one before")
    #expect(GalleryModel.handOff(order: order, removed: [10]) == 20, "start: the next")
    #expect(
      GalleryModel.handOff(order: order, removed: [20, 40]) == 50,
      "not contiguous: after the last removed")
    #expect(
      GalleryModel.handOff(order: order, removed: [20, 50]) == 40,
      "not contiguous, last at the end: the nearest kept before it")
    #expect(
      GalleryModel.handOff(order: order, removed: [40, 50]) == 30,
      "a run at the end: before the run")
    #expect(GalleryModel.handOff(order: order, removed: Set(order)) == nil, "all removed")
    #expect(GalleryModel.handOff(order: order, removed: [99]) == nil, "removed not shown")
    #expect(GalleryModel.handOff(order: [], removed: [10]) == nil)
  }

  // MARK: - Hand-off, model paths

  @Test("⌘⌫ archives one at a time: the next takes the selection and the inspector, the last hands back")
  func archiveRepeatedly() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await show(.all, model)
    // Display order 4 3 2 1 0.
    model.select(model.rows[2])
    #expect(selected(model) == [2])

    await model.archiveOrPutBackFromCommand()
    #expect(model.pendingArchive == nil, "one unreferenced image goes at once")
    #expect(selected(model) == [1])
    #expect(inspected(model) == Self.sha(1))
    let next = try rowID(1, model)
    #expect(model.selectionAnchor == next)

    await model.archiveOrPutBackFromCommand()
    #expect(selected(model) == [0])
    await model.archiveOrPutBackFromCommand()
    #expect(selected(model) == [3], "the last row went: the one before takes over")
    #expect(inspected(model) == Self.sha(3))
    await model.archiveOrPutBackFromCommand()
    await model.archiveOrPutBackFromCommand()
    #expect(model.rows.isEmpty)
    #expect(model.selectedIDs.isEmpty, "the surface is empty: nothing selected")
    #expect(model.selectionAnchor == nil)
    #expect(inspected(model) == nil)
  }

  /// The cursor moves with the hand-off, so ← → walk on from
  /// the image that took over — not from the first row.
  @Test("After a hand-off, ← and → walk on from the image that took over")
  func arrowsWalkOnFromTheHandOff() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await show(.all, model)
    // Display order 4 3 2 1 0; archiving 2 leaves 4 3 1 0 with 1 selected.
    model.select(model.rows[2])
    await model.archiveOrPutBackFromCommand()
    #expect(selected(model) == [1])
    #expect(model.selectionCursor == (try rowID(1, model)))

    _ = model.moveSelection(.right)
    #expect(selected(model) == [0], "→ from the hand-off, not from the first row")
    _ = model.moveSelection(.left)
    _ = model.moveSelection(.left)
    #expect(selected(model) == [3])

    // The last row going hands back to the one before; ← walks on from it.
    model.select(try #require(model.rows.last))  // 0
    await model.archiveOrPutBackFromCommand()
    #expect(selected(model) == [1])
    _ = model.moveSelection(.left)
    #expect(selected(model) == [3], "← from the hand-off, not from the first row")
  }

  @Test("Archive through the confirmation: a referenced image, and a scattered batch")
  func archiveConfirmed() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    try seedLiveUsage(f.database, projectSlug: "blog", sha256: Self.sha(2), count: 1)
    await model.loadInitialData()
    await show(.all, model)

    model.select(model.rows[2])
    await model.archiveOrPutBackFromCommand()
    let single = try #require(model.pendingArchive, "live usage asks")
    #expect(selected(model) == [2], "asking moves nothing")
    await model.confirmArchive(single)
    #expect(selected(model) == [1])
    #expect(inspected(model) == Self.sha(1))

    // 4 3 1 0 left; 3 and 0 selected.
    model.selectedIDs = [try rowID(3, model), try rowID(0, model)]
    await model.archiveOrPutBackFromCommand()
    let batch = try #require(model.pendingArchive)
    await model.confirmArchive(batch)
    #expect(selected(model) == [1], "after the last removed is nothing: the one before it")
  }

  @Test("Archived: ⌘⌫ puts back one at a time and the next takes over")
  func putBackRepeatedly() async throws {
    let f = try makeFixture(archived: [0, 1, 2, 3, 4])
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await show(.archived, model)
    model.select(model.rows[1])
    #expect(selected(model) == [3])

    await model.archiveOrPutBackFromCommand()
    #expect(selected(model) == [2])
    #expect(inspected(model) == Self.sha(2))
    await model.archiveOrPutBackFromCommand()
    #expect(selected(model) == [1])
    #expect(model.canDeleteSelectionPermanently, "⌥⌘⌫ is ready for the next one")
  }

  @Test("Archived: ⌥⌘⌫ then Delete, again and again; nothing reaches a bucket")
  func deleteRepeatedly() async throws {
    let f = try makeFixture(archived: [0, 1, 2, 3, 4])
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await show(.archived, model)
    model.select(model.rows[2])

    await model.deletePermanentlyFromCommand()
    await model.confirmDeletion(try #require(model.pendingDeletion))
    #expect(selected(model) == [1])
    #expect(inspected(model) == Self.sha(1))
    #expect(model.canDeleteSelectionPermanently)

    await model.deletePermanentlyFromCommand()
    await model.confirmDeletion(try #require(model.pendingDeletion))
    #expect(selected(model) == [0])
    await model.deletePermanentlyFromCommand()
    await model.confirmDeletion(try #require(model.pendingDeletion))
    #expect(selected(model) == [3])
    #expect(model.rows.count == 2)
    #expect(f.remoteCalls.value == 0)
  }

  // MARK: - Selection that stays

  @Test("Past 100, the rest stay selected after the delete — exactly them")
  func overLimitKeepsTheRest() async throws {
    let f = try makeFixture(count: 105, archived: Set(0..<105))
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await show(.archived, model)
    #expect(model.rows.count == 105)
    model.selectAllLoaded()
    await model.deletePermanentlyFromCommand()
    let pending = try #require(model.pendingDeletion)
    #expect(pending.imageCount == 100)

    await model.confirmDeletion(pending)
    // Newest first: 104 … 5 went, 4 … 0 are left and still selected.
    #expect(model.rows.count == 5)
    #expect(selected(model) == [0, 1, 2, 3, 4])
    #expect(model.selectedIDs == Set(model.rows.map(\.id)))
    #expect(f.remoteCalls.value == 0)
  }

  @Test("Favorite and label leave the selection alone; so does Remove from <project> on Archived")
  func stayingImagesKeepTheSelection() async throws {
    let f = try makeFixture(archived: [3, 4])
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    try await f.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO asset_project (asset_id, project_id, added_at)
          SELECT a.id, 2, '2026-08-02T00:00:00Z' FROM asset a WHERE a.sha256 IN (?, ?)
          """, arguments: [Self.sha(3), Self.sha(4)])
    }
    await model.loadInitialData()
    await show(.all, model)
    // 2 1 0 shown; 2 and 0 selected.
    model.selectedIDs = [try rowID(2, model), try rowID(0, model)]
    let before = model.selectedIDs
    await model.toggleFavoriteFromCommand()
    #expect(model.selectedIDs == before)
    await model.toggleLabel(.red, for: try #require(model.selectionTargetIfAny))
    #expect(model.selectedIDs == before)

    // Archived is not scoped to the current project: removing the pair
    // from Blog keeps both on screen, and selected.
    model.currentProjectSlug = "blog"
    await show(.archived, model)
    model.selectedIDs = [try rowID(4, model), try rowID(3, model)]
    let archived = model.selectedIDs
    await model.deletePermanentlyFromCommand()
    let pending = try #require(model.pendingDeletion)
    #expect(pending.defaultButton == .removeFromProject)
    await model.confirmRemoveFromProject(pending)
    #expect(model.rows.count == 2)
    #expect(model.selectedIDs == archived)
    #expect(f.remoteCalls.value == 0)
  }

  // MARK: - Delete Permanently… in the menu

  @Test("Edit ▸ Delete Permanently… is always drawn: disabled off Archived, with ⌥⌘⌫")
  func menuItemAlwaysThere() async throws {
    let f = try makeFixture(archived: [4])
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    let isItem: (Any) -> Bool = { "\($0)".contains("\"Delete Permanently…\"") }
    let shortcut = KeyboardShortcut(.delete, modifiers: [.option, .command])

    let none = PinaxCommands.deleteItems(nil).body
    #expect(buttonShortcut(in: none, label: isItem) == shortcut, "no window: still there")
    #expect(buttonIsEnabled(in: none, label: isItem) == false)

    await show(.all, model)
    model.select(model.rows[0])
    let off = PinaxCommands.deleteItems(model).body
    #expect(buttonShortcut(in: off, label: isItem) == shortcut)
    #expect(buttonIsEnabled(in: off, label: isItem) == false)

    await show(.archived, model)
    model.select(model.rows[0])
    let on = PinaxCommands.deleteItems(model).body
    #expect(buttonShortcut(in: on, label: isItem) == shortcut)
    #expect(buttonIsEnabled(in: on, label: isItem) == true)
    // Right-click keeps it on Archived only.
    #expect(model.showsDeletePermanently)
  }
}
