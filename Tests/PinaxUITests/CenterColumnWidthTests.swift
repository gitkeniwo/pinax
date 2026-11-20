import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// At the smallest window with both side columns open,
/// nothing in the centre column is wider than the column. Measured before
/// the fix (900 pt window, sidebar 220): the column was 378 pt (x 221…599)
/// and its content laid out at 516 pt (x 152…668), centred and clipped —
/// the scope bar's segments, ⓘ and capsule; the activity panel at 470 pt
/// (its bottom bar's fixed 240 pt Filter).
@MainActor
@Suite(.serialized) struct CenterColumnWidthTests {
  private struct StaticExternals: ExternalUsageReading {
    let rows: [ExternalReference]
    func externalReferences(project: String?) async throws -> ExternalReferenceSet {
      ExternalReferenceSet(references: rows, projectSources: [:])
    }
  }

  nonisolated private func pump(until date: Date) { RunLoop.main.run(until: date) }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pump(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// The split view holding the sidebar and the centre column.
  private func sidebarSplit(in window: NSWindow) -> NSSplitView? {
    var stack: [NSView] = [window.contentView].compactMap { $0 }
    while let view = stack.popLast() {
      if let split = view as? NSSplitView, split.arrangedSubviews.count == 2,
        split.arrangedSubviews[0].frame.width <= GalleryWidthBudget.sidebarMax
      {
        return split
      }
      stack.append(contentsOf: view.subviews)
    }
    return nil
  }

  /// Views in `pane` (not inside a list row, which its clip view crops)
  /// reaching past the pane's edges, in window coordinates.
  private func overflowing(in pane: NSView) -> [String] {
    let bounds = pane.convert(pane.bounds, to: nil)
    var found: [String] = []
    var stack: [NSView] = pane.subviews
    while let view = stack.popLast() {
      if view is NSTableRowView || view.isHidden { continue }
      let frame = view.convert(view.bounds, to: nil)
      if frame.width > 0, frame.minX < bounds.minX - 0.5 || frame.maxX > bounds.maxX + 0.5 {
        found.append("\(type(of: view)) \(Int(frame.minX))…\(Int(frame.maxX)) in \(Int(bounds.minX))…\(Int(bounds.maxX))")
      }
      stack.append(contentsOf: view.subviews)
    }
    return found
  }

  @Test(
    "At the minimum window with both side columns and the panel open, the centre column's content fits it",
    arguments: [(GalleryModel.ViewMode.grid, CGFloat(220)), (.grid, 260), (.table, 220), (.table, 260)])
  func centreContentFits(mode: GalleryModel.ViewMode, sidebar: CGFloat) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-centre-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }),
      externalReader: StaticExternals(rows: ExternalsMigrationTests.rows),
      externalsMigrator: ExternalsMigrationTests.StubMigrator())
    await model.loadInitialData()
    model.showsInspector = true
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: GalleryWidthBudget.windowMinWidth, height: 720),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    model.select(.externals, in: .reports)
    await spin(0.8)
    // The scope's first load picks the half (Your Domains, unless empty);
    // set the user's half only after it, or a late load resets it.
    let loadDeadline = Date().addingTimeInterval(10)
    while model.externals.items == nil || model.externals.isLoading, Date() < loadDeadline {
      await spin(0.1)
    }
    try #require(model.externals.items != nil)
    // The reported case: Other Domains, Group: Used In, the panel open.
    model.externals.domain = .other
    model.externals.groupsByFile = true
    model.externals.viewMode = mode
    model.isActivityPanelOpen = true
    let split = try #require(sidebarSplit(in: window))
    split.setPosition(sidebar, ofDividerAt: 0)
    await spin(1.0)

    #expect(window.frame.width == GalleryWidthBudget.windowMinWidth)
    #expect(model.externals.viewMode == mode && model.externals.domain == .other)
    let pane = split.arrangedSubviews[1]
    #expect(split.arrangedSubviews[0].frame.width == sidebar)
    #expect(overflowing(in: pane) == [])
  }

  @Test("A narrow table drops Used In, and a reference row then fits its width")
  func narrowTableRowFits() {
    #expect(ExternalsView.showsUsedIn(tableWidth: 0))
    #expect(ExternalsView.showsUsedIn(tableWidth: 460))
    #expect(!ExternalsView.showsUsedIn(tableWidth: 338))
    // The narrowest table: the 338 pt column less the rows' 8 pt insets.
    let width: CGFloat = 322
    func rowWidth(showsUsedIn: Bool) -> CGFloat {
      let row = ExternalListRow(row: ExternalsMigrationTests.rows[0], state: nil)
        .environment(\.externalsShowsUsedIn, showsUsedIn)
      return NSHostingController(rootView: row)
        .sizeThatFits(in: CGSize(width: width, height: 100)).width
    }
    #expect(rowWidth(showsUsedIn: true) > width, "with Used In the row is wider than the table")
    #expect(rowWidth(showsUsedIn: false) <= width)
  }
}
