import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Dragging out of the grid and the table. Properties:
///
/// 1. The provider's type set is a pure function of the member count —
///    text and a URL for one asset, text alone for several — and never a
///    file.
/// 2. The dragged text is ⌘C's text in the default format, character for
///    character (one renderer), one line per asset in grid order; a drag
///    started outside the selection carries that asset alone; neither
///    changes the selection nor fetches an original.
/// 3. The hosted grid puts the drag on every cell, next to the context menu.
/// 4. The hosted table's outline view hands out the same text, the first
///    selected row carrying the whole selection and the others nothing.
///
/// No test starts a drag session or opens a menu: the table's
/// writers are asked for directly and written to a private pasteboard.
@MainActor
@Suite(.serialized) struct DragOutTests {
  /// Records every fetch of an original; a drag must make none.
  final class CountingFetcher: PublicObjectFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var fetched: [URL] = []
    var urls: [URL] { lock.withLock { fetched } }

    func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
      lock.withLock { fetched.append(url) }
      throw URLError(.notConnectedToInternet)
    }
  }

  /// Not the factory URL, so a drag that only gives the URL cannot pass by
  /// coincidence; every placeholder that differs per asset is in it.
  private let blogFormat = CopyFormat(
    name: "Blog", template: "{filename} → ![{name}]({url}) {width}x{height}")

  private func line(_ index: Int) -> String {
    "asset-\(index).png → ![asset-\(index)](https://img.example.com/blog/asset-\(index).png) 800x600"
  }

  private struct Fixture {
    let app: PinaxAppModel
    let gallery: GalleryModel
    let directory: URL
  }

  /// Four assets, newest first in the grid: asset-3, asset-2, asset-1,
  /// asset-0. The default format is set where the user sets it.
  private func makeFixture() async throws -> Fixture {
    let (database, directory) = try makeUITestDatabase()
    for index in 0..<4 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
    }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-drag-tests-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    app.preferences.copyFormats.append(blogFormat)
    app.preferences.defaultCopyFormatID = blogFormat.id
    await gallery.loadInitialData()
    #expect(gallery.defaultCopyFormat == blogFormat, "the preference reaches the gallery")
    #expect(gallery.rows.map(\.item.asset.originalFilename) == [
      "asset-3.png", "asset-2.png", "asset-1.png", "asset-0.png",
    ])
    return Fixture(app: app, gallery: gallery, directory: directory)
  }

  private func spin(until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private func load(_ type: UTType, from provider: NSItemProvider) async throws -> String? {
    guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
        if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: error ?? URLError(.unknown))
        }
      }
    }
    if type == .url {
      return URL(dataRepresentation: data, relativeTo: nil)?.absoluteString
    }
    return String(data: data, encoding: .utf8)
  }

  private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("pinax-drag-tests-\(UUID().uuidString)"))
  }

  // MARK: - 1. The type set

  @Test("The drag's types are a pure function of the member count and never a file")
  func typeSet() {
    let one = AssetDrag.itemProvider(text: "a", urls: ["https://img.example.com/a.png"])
    let two = AssetDrag.itemProvider(
      text: "a\nb", urls: ["https://img.example.com/a.png", "https://img.example.com/b.png"])
    #expect(AssetDrag.typeIdentifiers(memberCount: 1) == ["public.utf8-plain-text", "public.url"])
    #expect(AssetDrag.typeIdentifiers(memberCount: 2) == ["public.utf8-plain-text"])
    #expect(one.registeredTypeIdentifiers == AssetDrag.typeIdentifiers(memberCount: 1))
    #expect(two.registeredTypeIdentifiers == AssetDrag.typeIdentifiers(memberCount: 2))
  }

  // MARK: - 2. The text is ⌘C's

  @Test("A drag carries ⌘C's text in grid order, leaves the selection alone and fetches nothing")
  func dragTextIsCopyText() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    let fetcher = CountingFetcher()
    gallery.downloader = OriginalDownloader(fetcher: fetcher)

    // Selected against grid order: asset-0 first, then asset-2.
    let rows = gallery.rows
    gallery.select(rows[3], mode: .replace)
    gallery.select(rows[1], mode: .toggle)
    let selection = gallery.selectedIDs

    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    gallery.copySelectionInDefaultFormat(to: pasteboard)
    let copied = try #require(pasteboard.string(forType: .string))
    #expect(copied == [line(2), line(0)].joined(separator: "\n"))

    // Started on either selected cell: the whole selection, as ⌘C wrote it.
    for start in [rows[1], rows[3]] {
      let provider = try #require(gallery.dragItemProvider(for: start))
      #expect(provider.registeredTypeIdentifiers == AssetDrag.typeIdentifiers(memberCount: 2))
      #expect(try await load(.utf8PlainText, from: provider) == copied)
      #expect(gallery.selectedIDs == selection)
    }

    // Started on a cell outside the selection: that asset alone.
    let single = try #require(gallery.dragItemProvider(for: rows[2]))
    #expect(single.registeredTypeIdentifiers == AssetDrag.typeIdentifiers(memberCount: 1))
    #expect(try await load(.utf8PlainText, from: single) == line(1))
    #expect(try await load(.url, from: single) == "https://img.example.com/blog/asset-1.png")
    #expect(gallery.selectedIDs == selection, "a drag never selects")
    #expect(fetcher.urls.isEmpty, "no original is fetched")
  }

  // MARK: - 3. The hosted grid

  @Test("The hosted grid puts the drag on every cell, after the context menu")
  func gridWiring() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(
      rootView: GalleryView(model: fixture.gallery))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    #expect(fixture.gallery.viewMode == .grid)

    // SwiftUI leaves nothing to ask a hosted `.onDrag` without starting a
    // session (measured: identical view tree and no dragged types with and
    // without it), so the grid's own view type is read: every cell branch
    // is `AssetGridCell` … context menu, then the drag.
    let type = String(reflecting: Swift.type(of: AssetGridView(model: fixture.gallery).body))
    let cells = type.components(separatedBy: "PinaxUI.AssetGridCell").count - 1
    let dragged = type.components(separatedBy: "AssetContextMenuModifier>, SwiftUI._DraggingModifier>")
      .count - 1
    #expect(cells > 0)
    #expect(dragged == cells, "\(dragged) of \(cells) cell branches drag")
  }

  // MARK: - 4. The hosted table

  private func assetTable(in view: NSView) -> NSOutlineView? {
    var stack: [NSView] = [view]
    while let next = stack.popLast() {
      if let table = next as? NSOutlineView, table.tableColumns.count > 1 { return table }
      stack.append(contentsOf: next.subviews)
    }
    return nil
  }

  @Test("The hosted table hands out ⌘C's text once, from the first selected row, and URLs for single rows")
  func tableWiring() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    let rows = gallery.rows
    gallery.select(rows[3], mode: .replace)
    gallery.select(rows[1], mode: .toggle)
    let selection = gallery.selectedIDs
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    gallery.copySelectionInDefaultFormat(to: pasteboard)
    let copied = try #require(pasteboard.string(forType: .string))

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: gallery))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    gallery.viewMode = .table
    await spin(until: { self.assetTable(in: window.contentView!) != nil })
    let content = try #require(window.contentView)
    let table = try #require(assetTable(in: content))
    let dataSource = try #require(table.dataSource)
    // Upload-date order with months on (the defaults) puts August's
    // month row above the four assets; it is not an asset row.
    let assetRows = (0..<table.numberOfRows).filter {
      table.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle == false
    }
    #expect(table.numberOfRows == 5)
    #expect(assetRows == [1, 2, 3, 4])

    // What the outline view would put on the drag pasteboard, row by row.
    var carried: [(text: String?, url: String?)?] = []
    for index in assetRows {
      guard
        let writer = dataSource.outlineView?(
          table, pasteboardWriterForItem: table.item(atRow: index) as Any)
      else {
        carried.append(nil)
        continue
      }
      let board = privatePasteboard()
      board.clearContents()
      board.writeObjects([writer])
      carried.append((board.string(forType: .string), board.string(forType: .URL)))
      board.releaseGlobally()
    }
    #expect(carried[0]?.text == line(3) && carried[0]?.url?.hasSuffix("asset-3.png") == true)
    #expect(carried[1]?.text == copied && carried[1]?.url == nil, "first selected row: all of it")
    #expect(carried[2]?.text == line(1) && carried[2]?.url?.hasSuffix("asset-1.png") == true)
    #expect(carried[3] == nil, "the other selected row carries nothing")
    #expect(gallery.selectedIDs == selection)
  }
}
