import AppKit
import CatalogCore
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// Sort order. Properties, not outcomes:
///
/// 1. **One order.** View ▸ Sort By (`PinaxCommands.sortItems`, over the
///    store), the jump bar's sort menu (`JumpBar.sortItems`, over the
///    gallery) and the table's column headers (the hosted `NSTableView`'s
///    sort descriptors) are one value: a write in any one is the value the
///    other two show, and it reaches the hosted gallery's query through the
///    reload token — the grid and the table show the new first page.
/// 2. **Changing the order does not change the selection.**
/// 3. **Month sections only in upload-date order.**
/// 4. **The order survives a relaunch**, through the app's own preference
///    path.
///
/// The fixture is 130 rows (more than the 120-row page), and its upload
/// time, name, size and kind orders are four different permutations of the
/// id order — so no order here equals the id order or the default order by
/// accident, and the biggest asset is not on the default first page:
/// sorting the loaded page instead of querying would show the wrong row
/// first.
@MainActor
@Suite(.serialized) struct GallerySortTests {
  private struct Seed {
    let id: Int64
    let uploadedAt: String
    let name: String
    let size: Int64
    let mime: String
  }

  private static let mimes = ["image/png", "image/jpeg", "image/gif", "image/webp"]

  /// Index `i` is id `i + 1`. Each column is its own permutation of 0..<130
  /// (multipliers coprime with 130); names alternate case so only a NOCASE
  /// order puts them in `q` order.
  private func seed(_ database: DatabasePool) throws -> [Seed] {
    let count = 130
    var seeds: [Seed] = []
    let base = try #require(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    for i in 0..<count {
      let hours = (i * 37) % count * 12
      let uploadedAt = ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(hours) * 3600))
      let q = (i * 53 + 7) % count
      let name = (q.isMultiple(of: 2) ? "Photo-" : "photo-") + String(format: "%03d.png", q)
      let size = Int64((i * 71 + 129) % count * 1000 + 500)
      let mime = Self.mimes[(i * 3) % 4]
      try seedAsset(database, index: i, uploadedAt: uploadedAt, origFilename: name)
      try database.write { db in
        try db.execute(
          sql: "UPDATE asset SET byte_size = ?, mime = ? WHERE id = ?",
          arguments: [size, mime, i + 1])
      }
      seeds.append(Seed(id: Int64(i + 1), uploadedAt: uploadedAt, name: name, size: size, mime: mime))
    }
    return seeds
  }

  /// The expected order, computed here from the seeds rather than read
  /// from the query: primary key, then id, both in the sort's direction.
  private func expected(_ seeds: [Seed], _ sort: AssetSort) -> [Int64] {
    let ascending = seeds.sorted { a, b in
      switch sort.field {
      case .uploadedAt: return (a.uploadedAt, a.id) < (b.uploadedAt, b.id)
      case .name: return (a.name.lowercased(), a.id) < (b.name.lowercased(), b.id)
      case .byteSize: return (a.size, a.id) < (b.size, b.id)
      case .kind: return (a.mime, a.id) < (b.mime, b.id)
      // No seed carries a source: all Pinax, so the id decides.
      case .source: return a.id < b.id
      // One backend: every seed has the same domain, so the id decides.
      case .domain: return a.id < b.id
      }
    }.map(\.id)
    return sort.direction == .ascending ? ascending : ascending.reversed()
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

  /// Parallel full runs starve the main thread, so the cap is generous;
  /// a passing run never waits for it.
  private func spin(until condition: () -> Bool, timeout: TimeInterval = 15) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-sort-tests-\(UUID().uuidString)"))
  }

  /// The gallery's table (the sidebar is a one-column source list).
  private func assetTable(in view: NSView) -> NSTableView? {
    var stack: [NSView] = [view]
    while let next = stack.popLast() {
      if let table = next as? NSTableView, table.tableColumns.count > 1 { return table }
      stack.append(contentsOf: next.subviews)
    }
    return nil
  }

  @Test("View ▸ Sort By, the jump bar and the table headers are one order; the hosted gallery shows it and keeps the selection")
  func oneOrderEverywhere() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let seeds = try seed(database)
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: try makeDefaults(), databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: gallery))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    await spin(until: { gallery.rows.count == 120 })

    // The fixture is not a coincidence: the default first page is neither
    // the id order nor any of the orders below, and the biggest asset is
    // not on it.
    let byDate = expected(seeds, AssetSort())
    let idOrder = seeds.map(\.id)
    #expect(gallery.rows.map(\.id) == Array(byDate.prefix(120)))
    #expect(byDate != idOrder && byDate != idOrder.reversed())
    let biggest = try #require(seeds.max { $0.size < $1.size }).id
    #expect(!byDate.prefix(120).contains(biggest))
    #expect(gallery.groupsRowsByMonth)

    try #require(gallery.rows.count == 120, "the first page never loaded: \(gallery.rows.count) rows")

    // A selection of two rows, one of them the anchor.
    let first = gallery.rows[3]
    let second = gallery.rows[40]
    gallery.select(first, mode: .replace)
    gallery.select(second, mode: .toggle)
    let selection = gallery.selectedIDs
    let anchor = gallery.selectionAnchor
    #expect(selection == [first.id, second.id])

    // The three entry points, each the one the app installs.
    let viewMenu = PinaxCommands(app: app).sortItems.$sort
    let jumpBar = JumpBar(model: gallery).sortItems.$sort
    let headers = AssetTableView(model: gallery).sortOrder

    func expectEverywhere(_ sort: AssetSort, _ note: Comment) async {
      await spin(until: { gallery.rows.map(\.id) == Array(expected(seeds, sort).prefix(120)) })
      #expect(gallery.rows.map(\.id) == Array(expected(seeds, sort).prefix(120)), note)
      #expect(viewMenu.wrappedValue == sort, note)
      #expect(jumpBar.wrappedValue == sort, note)
      #expect(app.preferences.gallerySort == sort, note)
      #expect(
        headers.wrappedValue.first?.keyPath == AssetTableView.comparator(sort.field).keyPath, note)
      #expect(
        headers.wrappedValue.first?.order == (sort.direction == .ascending ? .forward : .reverse),
        note)
      #expect(gallery.selectedIDs == selection, note)
      #expect(gallery.selectionAnchor == anchor, note)
      #expect(gallery.groupsByMonth, note)
      #expect(gallery.groupsRowsByMonth == (sort.field == .uploadedAt), note)
    }

    // View ▸ Sort By.
    let byName = AssetSort(field: .name, direction: .ascending)
    #expect(expected(seeds, byName) != idOrder && expected(seeds, byName) != byDate)
    viewMenu.wrappedValue = byName
    await expectEverywhere(byName, "View ▸ Sort By → name ascending")

    // The jump bar's sort menu.
    let byKind = AssetSort(field: .kind, direction: .descending)
    #expect(expected(seeds, byKind) != idOrder.reversed() && expected(seeds, byKind) != byDate)
    jumpBar.wrappedValue = byKind
    await expectEverywhere(byKind, "jump bar → kind descending")

    // A header click in the hosted table: the column's own sort descriptor,
    // reversed, as AppKit sets it on the second click.
    gallery.viewMode = .table
    await spin(until: { self.assetTable(in: window.contentView!) != nil })
    let content = try #require(window.contentView)
    let table = try #require(assetTable(in: content))
    #expect(
      table.tableColumns.filter { !$0.isHidden }.map(\.title)
        == ["", "Name", "Kind", "Size", "Dimensions", "Uploaded", "Source", "Key"])
    #expect(
      table.tableColumns.filter { $0.sortDescriptorPrototype != nil }.map(\.title)
        == ["Name", "Kind", "Domain", "Size", "Uploaded", "Source"], "Domain sorts")
    let sizeColumn = try #require(table.tableColumns.first { $0.title == "Size" })
    let prototype = try #require(sizeColumn.sortDescriptorPrototype)
    table.sortDescriptors = [try #require(prototype.reversedSortDescriptor as? NSSortDescriptor)]
    let bySize = AssetSort(field: .byteSize, direction: .descending)
    await expectEverywhere(bySize, "table header → size descending")
    #expect(gallery.rows.first?.id == biggest, "the library's biggest, not the page's")

    // Every sortable header writes its own field and the clicked direction,
    // not only Size, and not only descending (the default direction): from
    // size descending, each column's prototype writes ascending.
    #expect(gallery.sort.direction == .descending)
    let headerFields: [(String, AssetSort.Field)] = [
      ("Name", .name), ("Kind", .kind), ("Size", .byteSize), ("Uploaded", .uploadedAt),
      ("Source", .source),
    ]
    for (title, field) in headerFields {
      let column = try #require(table.tableColumns.first { $0.title == title })
      let prototype = try #require(column.sortDescriptorPrototype)
      #expect(prototype.ascending, "header \(title)")
      table.sortDescriptors = [prototype]
      let written = AssetSort(field: field, direction: .ascending)
      await spin(until: { gallery.sort == written })
      #expect(gallery.sort == written, "header \(title)")
    }

    // Back to upload date, oldest first: month sections return.
    let byDateAscending = AssetSort(field: .uploadedAt, direction: .ascending)
    viewMenu.wrappedValue = byDateAscending
    await expectEverywhere(byDateAscending, "View ▸ Sort By → date ascending")
    // The hosted header's arrow moved with it: SwiftUI keys the table's
    // sort descriptor by the column's identifier (measured).
    let uploadedColumn = try #require(table.tableColumns.first { $0.title == "Uploaded" })
    #expect(table.sortDescriptors.map(\.key) == [uploadedColumn.identifier.rawValue])
    #expect(table.sortDescriptors.map(\.ascending) == [true])
    #expect(
      gallery.groupedRows.map(\.month) == gallery.groupedRows.map(\.month).sorted(),
      "sections run oldest first")
  }

  @Test("The order survives a relaunch, and a stored value that is not one reads as the default")
  func orderPersists() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let seeds = try seed(database)
    let defaults = try makeDefaults()

    let first = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await first.start()
    #expect(try #require(first.gallery).sort == AssetSort())
    let bySize = AssetSort(field: .byteSize, direction: .ascending)
    PinaxCommands(app: first).sortItems.sort = bySize
    #expect(defaults.string(forKey: "pinax.gallery.sort") == "byteSize.ascending")

    // Next launch: the gallery opens in the stored order and queries it.
    let second = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await second.start()
    let gallery = try #require(second.gallery)
    #expect(gallery.sort == bySize)
    #expect(PinaxCommands(app: second).sortItems.sort == bySize)
    await gallery.reload()
    #expect(gallery.rows.map(\.id) == Array(expected(seeds, bySize).prefix(120)))
    #expect(!gallery.groupsRowsByMonth)

    defaults.set("byteSize.sideways", forKey: "pinax.gallery.sort")
    #expect(PreferencesStore(defaults: defaults).gallerySort == AssetSort())
  }
}
