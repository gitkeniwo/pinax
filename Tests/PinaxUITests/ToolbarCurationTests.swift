import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Toolbar ♥ and Share. Properties:
///
/// 1. The toolbar ♥ follows the selection — filled only when every selected
///    item is a favourite — and a click favourites all of them, through the
///    curation model call: the click, Edit ▸ Favorite and the `.` key read and write
///    one state, so each sees what the others did.
/// 2. Share hands the system share menu the originals: the files' bytes hash
///    to the catalog's sha256 (fake fetcher, Download Original's path), an item whose fetch
///    fails is left out with its sentence in the status bar, nothing lands in
///    the Downloads folder, and a cached original is not fetched again.
///
/// Both are driven by clicking the rendered toolbar buttons in a hosted
/// window (`performClick`), so a toolbar that bypassed the model's path, or
/// dropped or hid a button, turns these red.
@MainActor
@Suite(.serialized) struct ToolbarCurationTests {
  final class CountingFetcher: PublicObjectFetching, @unchecked Sendable {
    let objects: [String: Data]
    private let lock = NSLock()
    private var names: [String] = []

    init(objects: [String: Data]) { self.objects = objects }

    var requests: [String] { lock.withLock { names } }

    func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
      lock.withLock { names.append(url.lastPathComponent) }
      guard let data = objects[url.lastPathComponent] else {
        throw PublicObjectFetchError.notFound(url)
      }
      return (data, "image/png", Int64(data.count))
    }
  }

  private struct Fixture {
    let model: GalleryModel
    let database: DatabasePool
    let directory: URL
    let fetcher: CountingFetcher
    let window: NSWindow
  }

  /// Three assets whose sha256 is their fake bytes' real hash; asset-1 is
  /// missing from the fake store. Grid order: asset-2, asset-1, asset-0.
  private func makeFixture() async throws -> Fixture {
    let (database, directory) = try makeUITestDatabase()
    var objects: [String: Data] = [:]
    for index in 0..<3 {
      try seedAsset(
        database, index: index, uploadedAt: String(format: "2026-08-20T12:%02d:00Z", index))
      let data = Data("original \(index)".utf8)
      try await database.write { db in
        try db.execute(
          sql: "UPDATE asset SET sha256 = ? WHERE key = ?",
          arguments: [Hashing.sha256(of: data), "blog/asset-\(index).png"])
      }
      if index != 1 { objects["asset-\(index).png"] = data }
    }
    let fetcher = CountingFetcher(objects: objects)
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    model.downloader = OriginalDownloader(fetcher: fetcher)
    model.downloadFolder = directory.appendingPathComponent("Downloads", isDirectory: true)
    model.shareCacheFolder = directory.appendingPathComponent("share", isDirectory: true)
    model.revealDownloads = { _ in Issue.record("Share revealed a download") }
    await model.loadInitialData()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    await spin(0.8)
    return Fixture(
      model: model, database: database, directory: directory, fetcher: fetcher, window: window)
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

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<100 where !condition() {
      await spin(0.05)
    }
  }

  /// The toolbar item whose label starts with `label`, and the AppKit button
  /// SwiftUI renders inside it.
  private func toolbarButton(_ label: String, in window: NSWindow) -> (NSToolbarItem, NSButton)? {
    for item in window.toolbar?.items ?? [] where item.label.hasPrefix(label) {
      var stack = item.view.map { [$0] } ?? []
      while let view = stack.popLast() {
        if let button = view as? NSButton { return (item, button) }
        stack.append(contentsOf: view.subviews)
      }
    }
    return nil
  }

  private func row(_ index: Int, _ model: GalleryModel) throws -> GalleryModel.Row {
    try #require(model.rows.first { $0.item.asset.key == "blog/asset-\(index).png" })
  }

  private func favoriteKeys(_ database: DatabasePool) throws -> [String] {
    try database.read { db in
      try String.fetchAll(db, sql: "SELECT key FROM asset WHERE favorite = 1 ORDER BY key")
    }
  }

  // MARK: - ♥

  @Test("The toolbar ♥ follows the selection and toggles it through the curation call")
  func favoriteFollowsSelection() async throws {
    let fixture = try await makeFixture()
    let (model, window) = (fixture.model, fixture.window)
    defer {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    let heart = try #require(toolbarButton("Favorite", in: window)).1
    #expect(!heart.isEnabled, "no selection: greyed in place")

    let a = try row(0, model)
    let b = try row(2, model)
    model.select(a)
    await spin(0.2)
    #expect(heart.isEnabled)
    #expect(FavoriteToolbarButton(model: model).symbol == "heart")

    heart.performClick(nil)
    await waitUntil { model.selectionIsFavorite }
    #expect(try favoriteKeys(fixture.database) == ["blog/asset-0.png"])
    #expect(model.rows.first { $0.id == a.id }?.isFavorite == true)
    #expect(FavoriteToolbarButton(model: model).symbol == "heart.fill")
    await spin(0.2)
    #expect(toolbarButton("Unfavorite", in: window) != nil, "the rendered item follows")

    // Mixed: one favourite, one not — hollow. One click favourites both.
    model.select(b, mode: .toggle)
    await spin(0.2)
    #expect(!model.selectionIsFavorite)
    #expect(FavoriteToolbarButton(model: model).symbol == "heart")
    #expect(toolbarButton("Favorite", in: window) != nil)
    heart.performClick(nil)
    await waitUntil { model.selectionIsFavorite }
    #expect(try favoriteKeys(fixture.database) == ["blog/asset-0.png", "blog/asset-2.png"])
    #expect(FavoriteToolbarButton(model: model).symbol == "heart.fill")

    // Edit ▸ Favorite / `.` — the menu's call — and the toolbar see each other.
    await model.toggleFavoriteFromCommand()
    await spin(0.2)
    #expect(try favoriteKeys(fixture.database) == [])
    #expect(FavoriteToolbarButton(model: model).symbol == "heart")
    #expect(toolbarButton("Favorite", in: window) != nil)
  }

  // MARK: - Share

  @Test("Share hands over the originals, leaves failures out, and skips Downloads")
  func shareHandsOverOriginals() async throws {
    let fixture = try await makeFixture()
    let (model, window) = (fixture.model, fixture.window)
    defer {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    var shared: [[URL]] = []
    model.presentShare = { shared.append($0) }
    let share = try #require(toolbarButton("Share", in: window)).1
    #expect(!share.isEnabled, "no selection: greyed in place")

    model.selectAllLoaded()
    await spin(0.2)
    #expect(share.isEnabled)
    share.performClick(nil)
    await waitUntil { shared.count == 1 }

    let files = try #require(shared.first)
    #expect(files.map(\.lastPathComponent) == ["asset-2.png", "asset-0.png"], "grid order")
    for file in files {
      let bytes = try Data(contentsOf: file)
      let key = "blog/\(file.lastPathComponent)"
      let catalogSHA = try await fixture.database.read { db in
        try String.fetchOne(db, sql: "SELECT sha256 FROM asset WHERE key = ?", arguments: [key])
      }
      #expect(Hashing.sha256(of: bytes) == catalogSHA, "\(key)")
    }
    let expected = "Couldn't download 1 of 3 — asset-1.png: it no longer exists (HTTP 404)"
    #expect(model.downloadError == expected)
    #expect(GalleryStatusBar(model: model).activityText == expected)
    #expect(!FileManager.default.fileExists(atPath: model.downloadFolder.path))

    // A second Share fetches only what is not cached — the failed one.
    share.performClick(nil)
    await waitUntil { shared.count == 2 }
    #expect(shared.last == files)
    #expect(fixture.fetcher.requests == ["asset-2.png", "asset-1.png", "asset-0.png", "asset-1.png"])
  }

  /// Photos' switcher (Years / Months / All Photos) is a segmented control
  /// of words; with images SwiftUI's toolbar draws loose icon buttons.
  @Test("View mode is a segmented control of titles, like Photos' switcher")
  func viewModeIsTitledSegments() async throws {
    let fixture = try await makeFixture()
    defer {
      fixture.window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    var segmented: NSSegmentedControl?
    var stack = (fixture.window.toolbar?.items ?? []).compactMap(\.view)
    while segmented == nil, let view = stack.popLast() {
      segmented = view as? NSSegmentedControl
      stack.append(contentsOf: view.subviews)
    }
    let control = try #require(segmented)
    #expect((0..<control.segmentCount).map { control.label(forSegment: $0) } == ["Grid", "Table"])
    #expect((0..<control.segmentCount).allSatisfy { control.image(forSegment: $0) == nil })
  }

  @Test("Every toolbar symbol D adds exists")
  func toolbarSymbolsExist() {
    for name in ["heart", "heart.fill", ShareToolbarButton.symbol] {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  // MARK: - greyed in place on the report surfaces

  @Test("♥ and Share grey out in place on the report surfaces")
  func reportSurfacesGreyOut() async throws {
    let fixture = try await makeFixture()
    let (model, window) = (fixture.model, fixture.window)
    defer {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    model.select(try row(0, model))
    await spin(0.2)
    let count = window.toolbar?.items.count
    // Usage is not one of them: its images are the
    // library's rows.
    for surface in [SidebarSelection.orphans, .externals] {
      model.select(surface, in: SidebarModel.navigator(for: surface))
      await spin(0.3)
      // Orphans lists selectable assets, so a selection can stand there and
      // only the surface can be what greys them — the control says it does.
      if surface == .orphans {
        await waitUntil { model.orphanReport != nil }
        let orphan = try #require(model.orphanReport?.assets.first)
        model.selectedIDs = [try #require(orphan.asset.id)]
        await spin(0.2)
        #expect(model.canCurateSelection && model.canShareSelection, "control")
      }
      let heart = try #require(toolbarButton("Favorite", in: window), "\(surface)").1
      let share = try #require(toolbarButton("Share", in: window), "\(surface)").1
      #expect(!heart.isEnabled, "\(surface)")
      #expect(!share.isEnabled, "\(surface)")
      #expect(window.toolbar?.items.count == count, "\(surface)")
    }
  }
}
