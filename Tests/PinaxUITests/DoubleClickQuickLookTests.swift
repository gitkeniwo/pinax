import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// A double-click opens Quick Look — on a grid
/// cell (ungrouped, by month, Orphans) and on a table row. The cells keep
/// their one tap gesture; what a click does is `GalleryModel.cellClick` of
/// the click's own event. Each grid's tap closure is the one its app view
/// declares (read through `Mirror`), fed an `NSEvent` that is built, never
/// posted, through the model's `currentEvent` seam; the table's is its
/// `primaryAction`. Quick Look is a fake panel. No click is synthesized.
@MainActor
@Suite(.serialized) struct DoubleClickQuickLookTests {
  private struct Fixture {
    let model: GalleryModel
    let panel: FakeQuickLookPanel
  }

  /// Six assets, ids 1–3 uploaded in July, 4–6 in August: shown newest
  /// first, so display order (6 … 1) is not id order. A seventh, from June,
  /// is referenced by blog's one completed scan, so Orphans lists the six
  /// and not the library's seven.
  private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
    _ = NSApplication.shared
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<6 {
      let month = index < 3 ? "07" : "08"
      try seedAsset(database, index: index, uploadedAt: "2026-\(month)-0\(index + 1)T00:00:00Z")
    }
    try seedAsset(database, index: 6, uploadedAt: "2026-06-01T00:00:00Z")
    try seedLiveUsage(
      database, projectSlug: "blog", sha256: String(format: "%064x", 7), count: 1)
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let panel = FakeQuickLookPanel()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: thumbnails,
      quickLook: QuickLookController(
        thumbnails: thumbnails,
        originals: OriginalImageCache(
          cacheDirectory: directory.appendingPathComponent("originals", isDirectory: true),
          fetcher: { _ in throw URLError(.unsupportedURL) }),
        placeholderDirectory: directory.appendingPathComponent("placeholders", isDirectory: true),
        panel: { panel }))
    await model.loadInitialData()
    try await body(Fixture(model: model, panel: panel))
  }

  /// A mouse-up as AppKit would hand the tap: built, not posted.
  private func click(_ count: Int, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(
      with: .leftMouseUp, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
  }

  // MARK: - 1. The pure function

  @Test("Click count and modifiers decide the selection action and whether Quick Look opens")
  func cellClickFunction() {
    typealias C = GalleryModel.CellClick
    for count in [1, 2, 3] {
      let opens = count >= 2
      #expect(GalleryModel.cellClick(clickCount: count, modifiers: []) == C(mode: .replace, opensQuickLook: opens))
      #expect(GalleryModel.cellClick(clickCount: count, modifiers: [.capsLock, .numericPad])
        == C(mode: .replace, opensQuickLook: opens))
      #expect(GalleryModel.cellClick(clickCount: count, modifiers: .command) == C(mode: .toggle, opensQuickLook: false))
      #expect(GalleryModel.cellClick(clickCount: count, modifiers: .shift) == C(mode: .extend, opensQuickLook: false))
      #expect(GalleryModel.cellClick(clickCount: count, modifiers: [.shift, .command])
        == C(mode: .extend, opensQuickLook: false))
    }
    #expect(GalleryModel.cellClick(clickCount: 0, modifiers: []) == C(mode: .replace, opensQuickLook: false))
  }

  // MARK: - 2. The grids' own tap closures

  /// Each cell's tap closure, by row id, as the view declares it.
  private func taps(in view: Any) -> [Int64: () -> Void] {
    var found: [Int64: () -> Void] = [:]
    func cells(_ value: Any) {
      if let rows = value as? GridRowsForEach {
        for (id, cell) in rows.cells() {
          let ended = firstView(in: cell, typePrefix: "CallbacksGesture<EndedCallbacks<()>>")
            .flatMap { Mirror(reflecting: $0).descendant("callbacks", "ended") }
          if let ended = ended as? @MainActor (()) -> Void {
            found[id] = { MainActor.assumeIsolated { ended(()) } }
          } else if let ended = ended as? (()) -> Void {
            found[id] = { ended(()) }
          }
        }
        return
      }
      if let months = value as? GridMonthsForEach {
        months.sections().forEach(cells)
        return
      }
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .class { return }
      mirror.children.forEach { cells($0.value) }
    }
    cells(view)
    return found
  }

  private func press(_ taps: [Int64: () -> Void], _ id: Int64) throws {
    let tap = try #require(taps[id], "no tap on cell \(id)")
    tap()
  }

  /// The double-click contract on one grid, through its tap closures.
  private func check(
    _ fixture: Fixture, rows: [GalleryModel.Row], taps: [Int64: () -> Void]
  ) async throws {
    let model = fixture.model
    let order = rows.map(\.id)
    #expect(Set(taps.keys) == Set(order), "every cell has a tap: \(taps.keys.sorted()) vs \(order)")
    // Not the first cell and not the selected one: Quick Look must stand on
    // the double-clicked cell, not on the surface's first row or the old
    // selection.
    let target = order[3]
    let other = order[1]
    var event = click(1)
    model.currentEvent = { event }
    try press(taps, other)
    model.select(rows[4], mode: .toggle)
    #expect(model.selectedIDs == [other, order[4]])
    #expect(!fixture.panel.isVisible, "a single click does not open Quick Look")

    // A double-click is the tap twice, the second with clickCount 2: the
    // same selection as one click, and the panel open on that cell.
    try press(taps, target)
    event = click(2)
    try press(taps, target)
    #expect(model.selectedIDs == [target], "the double-click selects as the single click did")
    #expect(fixture.panel.isVisible, "a double-click opens Quick Look")
    #expect(fixture.panel.currentPreviewItemIndex == 3, "on the double-clicked cell")
    // The item the panel shows, not only its index — a list
    // handed over in another order keeps the index and shows another image.
    let name = try #require(rows[3].item.asset.originalFilename)
    let shown = fixture.panel.currentItem?.previewItemTitle.flatMap { $0 } ?? "nil"
    #expect(shown.hasPrefix(name), "the panel shows \(shown), the double-clicked cell is \(name)")

    // Again on the open panel: it stays open — opening is not toggling.
    try press(taps, target)
    #expect(fixture.panel.isVisible)
    #expect(fixture.panel.closingSourceFrames.isEmpty, "the double-click never closes the panel")

    // ⌘ or ⇧ with the double-click: the selection action only. From an
    // empty selection, so ⌘ leaves exactly one row selected — with two, the
    // panel has no single row to open on and a wrong `cellClick` would hide.
    fixture.panel.close()
    for _ in 0..<100 where fixture.panel.isVisible {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!fixture.panel.isVisible)
    model.clearSelection()
    event = click(2, .command)
    try press(taps, other)
    #expect(model.selectedIDs == [other], "⌘ toggles")
    #expect(!fixture.panel.isVisible, "⌘ with a double-click does not open Quick Look")
    event = click(2, .shift)
    try press(taps, order[5])
    #expect(model.selectedIDs == Set(order[1...5]), "⇧ extends from the anchor")
    #expect(!fixture.panel.isVisible, "a modified double-click does not open Quick Look")
  }

  @Test("Ungrouped grid: the cells' own tap opens Quick Look on a double-click")
  func flatGrid() async throws {
    try await withFixture { fixture in
      fixture.model.groupsByMonth = false
      #expect(!fixture.model.groupsRowsByMonth)
      try await check(
        fixture, rows: fixture.model.rows, taps: taps(in: AssetGridView(model: fixture.model).body))
    }
  }

  @Test("Month-grouped grid: the same, through its sections")
  func groupedGrid() async throws {
    try await withFixture { fixture in
      fixture.model.groupsByMonth = true
      #expect(fixture.model.groupedRows.count == 3)
      try await check(
        fixture, rows: fixture.model.groupedRows.flatMap(\.rows),
        taps: taps(in: AssetGridView(model: fixture.model).body))
    }
  }

  @Test("Orphans: the same, through the orphan grid's cells")
  func orphanGrid() async throws {
    try await withFixture { fixture in
      fixture.model.select(.orphans, in: SidebarModel.navigator(for: .orphans))
      await fixture.model.reload()
      let report = try #require(fixture.model.orphanReport)
      #expect(report.assets.count == 6)
      try await check(
        fixture, rows: report.assets.map(GalleryModel.Row.init),
        taps: taps(in: OrphanView(model: fixture.model).body))
    }
  }

  // MARK: - 3. The table's primary action

  @Test("Table: the row double-click (primaryAction) opens Quick Look on the selection, never closes it")
  func tablePrimaryAction() async throws {
    try await withFixture { fixture in
      let model = fixture.model
      let action = firstView(
        in: AssetTableView(model: model).body, typePrefix: "SelectionActionModifier<"
      ).flatMap { Mirror(reflecting: $0).descendant("action") }
      let primary = try #require(action as? Optional<(Set<Int64>) -> Void>).flatMap { $0 }
      let open = try #require(primary, "the table declares no primaryAction")
      // `Table` selects the double-clicked row itself before the action.
      let target = model.rows[3]
      model.selectedIDs = [target.id]
      open([target.id])
      #expect(fixture.panel.isVisible)
      #expect(fixture.panel.currentPreviewItemIndex == 3)
      open([target.id])
      #expect(fixture.panel.isVisible)
      #expect(fixture.panel.closingSourceFrames.isEmpty, "the double-click never closes the panel")
    }
  }
}

private protocol GridRowsForEach { func cells() -> [(Int64, Any)] }
extension ForEach: GridRowsForEach where Data == [GalleryModel.Row] {
  fileprivate func cells() -> [(Int64, Any)] { data.map { ($0.id, content($0)) } }
}

private protocol GridMonthsForEach { func sections() -> [Any] }
extension ForEach: GridMonthsForEach where Data == [(month: String, rows: [GalleryModel.Row])] {
  fileprivate func sections() -> [Any] { data.map { content($0) } }
}
