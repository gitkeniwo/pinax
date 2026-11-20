import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Table mode, through what the app installs and hosts:
///
/// 1. **Make Bigger / Make Smaller** are the items in the app's own commands
///    body (`SizeMenuItems`), ⌘+ and ⌘−; each moves the current mode's
///    ladder one rung — grid columns in the grid, row height in the table —
///    never the other one, and grays at its ladder's end.
/// 2. **The toolbar slider** in table mode drives the same row rung.
/// 3. **The two rungs persist apart**, through the shell's writeback.
/// 4. **The hosted table's rows are the rung's height.**
/// 5. **The hosted table's month sections are the grid's**, month by month,
///    only in upload-date order with months on.
/// 6. **Columns**: Kind is the grid chip's short name; Uploaded is wide
///    enough for a date and a time.
///
/// Fixtures are off the defaults: grid 3 columns (default 4), rows 60 pt
/// (default 44), upload date oldest first (default newest first), and the
/// month switch is turned off and on (default on). No test opens a menu:
/// the items are read from the commands' view values and their
/// actions called; the slider is a plain `NSSlider` sent its own action.
@MainActor
@Suite(.serialized) struct TableGridPatchTests {
  private struct Fixture {
    let app: PinaxAppModel
    let gallery: GalleryModel
    let defaults: UserDefaults
    let database: DatabasePool
    let directory: URL
  }

  /// Seven assets over three months, and the two rungs stored off their
  /// defaults before launch — where the app reads them from.
  private func makeFixture() async throws -> Fixture {
    let (database, directory) = try makeUITestDatabase()
    let dates = [
      "2026-06-10T08:00:00Z",
      "2026-07-03T08:00:00Z", "2026-07-20T08:00:00Z",
      "2026-08-01T08:00:00Z", "2026-08-09T08:00:00Z", "2026-08-15T08:00:00Z",
      "2026-08-28T08:00:00Z",
    ]
    for (index, date) in dates.enumerated() {
      try seedAsset(database, index: index, uploadedAt: date)
    }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-s19d-\(UUID().uuidString)"))
    defaults.set(3, forKey: "pinax.grid.columns")
    defaults.set(60.0, forKey: "pinax.table.rowHeight")
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    await gallery.loadInitialData()
    #expect(gallery.gridColumns == 3 && GridZoom.defaultColumns != 3)
    #expect(gallery.tableRowHeight == 60 && DesignMetrics.table.defaultRowHeight != 60)
    return Fixture(
      app: app, gallery: gallery, defaults: defaults, database: database, directory: directory)
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
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
    await spin(0.3)
  }

  // MARK: - Reading the menu items without a menu

  /// One `Button` of a commands view: its title, shortcut, whether it is
  /// enabled, and its action.
  private struct Item {
    let title: String
    let shortcut: KeyboardShortcut?
    let isEnabled: Bool
    let action: @MainActor () -> Void
  }

  /// Walks a view value for its buttons, carrying the shortcut and the
  /// `.disabled` transform that wrap each one.
  private func items(in view: Any) -> [Item] {
    var found: [Item] = []
    func walk(_ value: Any, shortcut: KeyboardShortcut?, enabled: Bool) {
      let mirror = Mirror(reflecting: value)
      let typeName = String(describing: type(of: value))
      if typeName.hasPrefix("Button<") {
        let title = mirror.descendant("label", "storage", "anyTextStorage", "key")
          .flatMap { Mirror(reflecting: $0).descendant("key") as? String } ?? "?"
        if let action = mirror.descendant("action", "closure") as? @MainActor () -> Void {
          found.append(Item(title: title, shortcut: shortcut, isEnabled: enabled, action: action))
        }
        return
      }
      var shortcut = shortcut
      var enabled = enabled
      if typeName.hasPrefix("ModifiedContent<") {
        let modifier = mirror.descendant("modifier")
        if let value = modifier.flatMap({ Mirror(reflecting: $0).descendant("value") })
          as? KeyboardShortcut?, let value
        {
          shortcut = value
        }
        if let transform = modifier.flatMap({ Mirror(reflecting: $0).descendant("transform") })
          as? (inout Bool) -> Void
        {
          transform(&enabled)
        }
        if let content = mirror.descendant("content") {
          walk(content, shortcut: shortcut, enabled: enabled)
        }
        return
      }
      for child in mirror.children {
        walk(child.value, shortcut: shortcut, enabled: enabled)
      }
    }
    walk(view, shortcut: nil, enabled: true)
    return found
  }

  private func sizeItems(_ gallery: GalleryModel) throws -> (bigger: Item, smaller: Item) {
    let found = items(in: PinaxCommands.sizeItems(gallery).body)
    #expect(found.map(\.title) == ["Make Bigger", "Make Smaller"])
    return (try #require(found.first), try #require(found.last))
  }

  // MARK: - 1 + 3. The menu items and the two rungs

  @Test("Make Bigger and Make Smaller are the app's items, move only the current mode's rung, gray at its end, and persist apart")
  func makeBiggerAndSmaller() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery

    // The commands body the app installs carries these items, not a copy
    // (the `CommandGroup` closure is out of reach; its content type is not).
    let installed = String(reflecting: type(of: PinaxCommands(app: fixture.app).body))
    #expect(installed.contains("PinaxUI.SizeMenuItems"))

    var (bigger, smaller) = try sizeItems(gallery)
    #expect(bigger.shortcut == KeyboardShortcut("+", modifiers: .command))
    #expect(smaller.shortcut == KeyboardShortcut("-", modifiers: .command))

    // Grid: columns move, the row rung stays.
    #expect(gallery.viewMode == .grid)
    bigger.action()
    #expect(gallery.gridColumns == 2 && gallery.tableRowHeight == 60)
    (bigger, smaller) = try sizeItems(gallery)
    #expect(!bigger.isEnabled && smaller.isEnabled, "2 columns is the grid's big end")
    smaller.action()
    smaller.action()
    #expect(gallery.gridColumns == 4 && gallery.tableRowHeight == 60)

    // Table: the row rung moves, the columns stay.
    gallery.viewMode = .table
    (bigger, smaller) = try sizeItems(gallery)
    #expect(bigger.isEnabled && smaller.isEnabled)
    smaller.action()
    #expect(gallery.tableRowHeight == 44 && gallery.gridColumns == 4)
    bigger.action()
    bigger.action()
    #expect(gallery.tableRowHeight == 80 && gallery.gridColumns == 4)
    (bigger, smaller) = try sizeItems(gallery)
    #expect(!bigger.isEnabled && smaller.isEnabled, "80 pt is the table's big end")
    for _ in 0..<DesignMetrics.table.rowHeights.count { try sizeItems(gallery).smaller.action() }
    #expect(gallery.tableRowHeight == DesignMetrics.table.rowHeights.first)
    (bigger, smaller) = try sizeItems(gallery)
    #expect(bigger.isEnabled && !smaller.isEnabled, "28 pt is the table's small end")
    bigger.action()
    #expect(gallery.tableRowHeight == 36 && gallery.gridColumns == 4)

    // Stored apart, read apart at the next launch.
    #expect(fixture.defaults.object(forKey: "pinax.grid.columns") as? Int == 4)
    #expect(fixture.defaults.object(forKey: "pinax.table.rowHeight") as? Double == 36)
    let next = PinaxAppModel(dockIcon: inertDockIcon, defaults: fixture.defaults, databaseOpener: { fixture.database })
    await next.start()
    let reopened = try #require(next.gallery)
    #expect(reopened.gridColumns == 4 && reopened.tableRowHeight == 36)
  }

  // MARK: - 2. The toolbar slider

  private func slider(in view: NSView) -> NSSlider? {
    if let slider = view as? NSSlider { return slider }
    for subview in view.subviews {
      if let found = slider(in: subview) { return found }
    }
    return nil
  }

  @Test("The toolbar slider drives the table's row rung in the table and the grid's columns in the grid")
  func sliderFollowsTheMode() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GridToolbarControls(model: gallery))
    window.orderFront(nil)
    defer { window.orderOut(nil) }

    gallery.viewMode = .table
    await spin(0.5)
    let slider = try #require(window.contentView.flatMap(slider(in:)))
    #expect(slider.isEnabled, "table mode: the slider is live")
    let rungs = Double(DesignMetrics.table.rowHeights.count - 1)
    let sixty = try #require(DesignMetrics.table.rowHeights.firstIndex(of: 60))
    #expect(abs(slider.doubleValue * rungs - Double(sixty)) < 0.001, "the knob shows the row rung")

    // The knob to the top rung: the row rung moves, the columns do not.
    slider.doubleValue = 1
    _ = slider.sendAction(slider.action, to: slider.target)
    await spin(0.3)
    #expect(gallery.tableRowHeight == 80 && gallery.gridColumns == 3)

    // The same slider in the grid is the column rung again.
    gallery.viewMode = .grid
    await spin(0.3)
    let gridRungs = Double(GridZoom.columns.count - 1)
    #expect(abs(slider.doubleValue * gridRungs - GridZoom.sliderPosition(for: 3)) < 0.001)
    slider.doubleValue = GridZoom.sliderPosition(for: 5) / gridRungs
    _ = slider.sendAction(slider.action, to: slider.target)
    await spin(0.3)
    #expect(gallery.gridColumns == 5 && gallery.tableRowHeight == 80)
  }

  // MARK: - 4 + 5. The hosted table

  private func assetTable(in view: NSView) -> NSOutlineView? {
    var stack: [NSView] = [view]
    while let next = stack.popLast() {
      if let table = next as? NSOutlineView, table.tableColumns.count > 1 { return table }
      stack.append(contentsOf: next.subviews)
    }
    return nil
  }

  /// The table as drawn: `nil` for a month row, else the asset's URL as
  /// the row's own drag writer carries it (the default format is URL).
  private func drawnRows(_ table: NSOutlineView) -> [String?] {
    (0..<table.numberOfRows).map { index in
      if table.rowView(atRow: index, makeIfNecessary: true)?.isGroupRowStyle == true {
        return nil
      }
      guard
        let writer = table.dataSource?.outlineView?(
          table, pasteboardWriterForItem: table.item(atRow: index) as Any)
      else { return "?" }
      let board = NSPasteboard(name: NSPasteboard.Name("pinax-s19d-\(UUID().uuidString)"))
      defer { board.releaseGlobally() }
      board.clearContents()
      board.writeObjects([writer])
      return board.string(forType: .URL) ?? "?"
    }
  }

  /// The grid's sections as the table should draw them.
  private func expectedRows(_ gallery: GalleryModel) -> [String?] {
    guard gallery.groupsRowsByMonth else { return gallery.rows.map { $0.item.url } }
    return gallery.groupedRows.flatMap { group in [nil] + group.rows.map { $0.item.url } }
  }

  private func hostTable(_ gallery: GalleryModel) async throws -> (NSWindow, NSOutlineView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: gallery))
    window.makeKeyAndOrderFront(nil)
    gallery.viewMode = .table
    await spin(until: { self.assetTable(in: window.contentView!) != nil })
    let content = try #require(window.contentView)
    let table = try #require(assetTable(in: content))
    return (window, table)
  }

  @Test("The hosted table's month sections are the grid's, only in upload-date order with months on")
  func tableSectionsAreTheGrids() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    let (window, table) = try await hostTable(gallery)
    defer { window.orderOut(nil) }

    // Oldest first, not the default order: June, July, August.
    let oldestFirst = AssetSort(field: .uploadedAt, direction: .ascending)
    #expect(oldestFirst != AssetSort())
    PinaxCommands(app: fixture.app).sortItems.sort = oldestFirst
    await spin(until: { gallery.rows.first?.item.asset.uploadedAt.hasPrefix("2026-06") == true })
    #expect(gallery.groupsRowsByMonth)
    #expect(gallery.groupedRows.map(\.month) == ["2026-06", "2026-07", "2026-08"])
    #expect(gallery.groupedRows.map(\.rows.count) == [1, 2, 4])
    var drawn = drawnRows(table)
    #expect(drawn == expectedRows(gallery), "\(drawn)")
    #expect(drawn.filter { $0 == nil }.count == 3)

    // The month switch off (not the default): one run, no month rows.
    gallery.groupsByMonth = false
    await spin(0.5)
    drawn = drawnRows(table)
    #expect(!drawn.contains(nil) && drawn == expectedRows(gallery), "\(drawn)")
    #expect(drawn.count == 7)

    // Back on, but a name order: months would scatter, so no sections.
    gallery.groupsByMonth = true
    PinaxCommands(app: fixture.app).sortItems.sort = AssetSort(field: .name, direction: .descending)
    await spin(until: { gallery.sort.field == .name && !gallery.groupsRowsByMonth })
    drawn = drawnRows(table)
    #expect(!drawn.contains(nil) && drawn == expectedRows(gallery), "\(drawn)")
  }

  @Test("The selection plate's row indexes count each month header")
  func selectionPlateIndexes() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    gallery.groupsByMonth = false
    gallery.selectedIDs = [gallery.rows[2].id]
    #expect(AssetTableView.selectedRowIndexes(in: gallery) == IndexSet([2]))

    // Grouped by month: a header row sits before each month's rows.
    gallery.groupsByMonth = true
    #expect(gallery.showsRowsByMonth)
    let second = try #require(gallery.groupedRows.dropFirst().first?.rows.first)
    gallery.selectedIDs = [second.id]
    var expected = 0
    for group in gallery.groupedRows {
      expected += 1
      if group.rows.contains(where: { $0.id == second.id }) { break }
      expected += group.rows.count
    }
    #expect(AssetTableView.selectedRowIndexes(in: gallery) == IndexSet([expected]))
  }

  @Test("The hosted table's rows are the row rung's height, at every rung")
  func tableRowsFollowTheRung() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    gallery.groupsByMonth = false
    let (window, table) = try await hostTable(gallery)
    defer { window.orderOut(nil) }

    /// Automatic row heights are measured as the row views are made.
    func heights() -> Set<CGFloat> {
      for index in 0..<table.numberOfRows { _ = table.rowView(atRow: index, makeIfNecessary: true) }
      window.layoutIfNeeded()
      return Set((0..<table.numberOfRows).map { table.rect(ofRow: $0).height })
    }
    await spin(0.3)
    #expect(heights() == [60], "the stored rung, not the default")
    let thumbnailColumn = try #require(table.tableColumns.first)
    #expect(thumbnailColumn.width == 60)

    for height in DesignMetrics.table.rowHeights {
      gallery.setTableRowHeight(height)
      await spin(0.4)
      #expect(heights() == [height], "rung \(height)")
      #expect(thumbnailColumn.width == height, "rung \(height)")
    }
  }

  // MARK: - 6. Columns

  @Test("Kind is the grid chip's short name, and Uploaded fits a date and a time")
  func columns() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    let row = try #require(gallery.rows.first)
    #expect(AssetTableView.kind(row) == "PNG")
    #expect(AssetTableView.kind(row) != PinaxFormat.kind(mime: row.item.asset.mime))

    let (window, table) = try await hostTable(gallery)
    defer { window.orderOut(nil) }
    let uploaded = try #require(table.tableColumns.first { $0.title == "Uploaded" })
    // Every month's date and time, in the column's font (body, monospaced
    // digits), measured here on its own.
    let body = NSFont.preferredFont(forTextStyle: .body)
    let font = NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
    let widest = (1...12).map { month in
      (PinaxFormat.date(String(format: "2026-%02d-15T12:00:00Z", month), style: .dayTime)
        as NSString).size(withAttributes: [.font: font]).width
    }.max() ?? 0
    #expect(widest > 100, "a date and a time: \(widest)")
    #expect(widest == AssetTableView.widestUploadedText)
    #expect(uploaded.minWidth == AssetTableView.uploadedColumnWidth)
    // Squeezed to its minimum, the width a cell's content gets — the drawn
    // cell view's own frame — still holds the widest date.
    uploaded.width = uploaded.minWidth
    window.layoutIfNeeded()
    await spin(0.3)
    let column = try #require(table.tableColumns.firstIndex(of: uploaded))
    let assetRow = try #require((0..<table.numberOfRows).first {
      table.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle == false
    })
    let cell = try #require(table.view(atColumn: column, row: assetRow, makeIfNecessary: true))
    // SwiftUI's inset inside the cell is not readable (the text is not an
    // AppKit view); 8 pt a side is assumed, and the rest is an eyeball item.
    #expect(
      cell.frame.width >= widest + 2 * DesignMetrics.spacing.s,
      "cell \(cell.frame.width) vs date \(widest)")
  }
}
