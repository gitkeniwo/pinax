import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// The toolbar's items are stable in count and position under every
/// navigator. Measured before the fix:
/// Usage ▸ Files' `HSplitView` coming or going made SwiftUI re-sync the
/// window's toolbar, removing the inspector toggle and the flexible space
/// the mount appends, which the mount then appended again.
@MainActor
@Suite(.serialized) struct ToolbarStabilityTests {
  nonisolated private func pump(until date: Date) { RunLoop.main.run(until: date) }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pump(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  @Test("No toolbar item is removed, and the items keep their order, across Usage, Orphans and both Externals views")
  func toolbarIsStableAcrossReportSwitches() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    try seedLiveUsage(database, projectSlug: "blog", sha256: String(format: "%064x", 1), count: 2)
    // One reference on each half of Externals, in blog's live scan.
    try await database.write { db in
      for url in ["https://img.example.com/blog/missing.png", "https://elsewhere.example.org/x.png"] {
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, first_seen, last_seen, last_scan_id)
            SELECT id, NULL, ?, 'posts/a.md#L1', '2026-08-20T13:00:00Z', '2026-08-20T13:00:00Z',
              last_scan_id
            FROM project WHERE slug = 'blog'
            """,
          arguments: [url])
      }
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-thumbs-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await model.loadInitialData()
    model.currentProjectSlug = "blog"
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    model.select(.usage, in: .reports)
    model.usagePage = .images
    await spin(1.0)
    let toolbar = try #require(window.toolbar)
    try #require(toolbar.items.contains { $0.itemIdentifier == .toggleInspector })

    var removed: [String] = []
    let observer = NotificationCenter.default.addObserver(
      forName: NSToolbar.didRemoveItemNotification, object: toolbar, queue: nil
    ) { note in
      let item = note.userInfo?["item"] as? NSToolbarItem
      removed.append(item?.itemIdentifier.rawValue ?? "?")
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    func identifiers() -> [String] { toolbar.items.map(\.itemIdentifier.rawValue) }

    let steps: [(String, () -> Void)] = [
      ("Usage Images → Files", { model.usagePage = .files }),
      ("Usage Files → Images", { model.usagePage = .images }),
      ("Usage → Orphans", { model.select(.orphans, in: .reports) }),
      ("Orphans → Usage Images", { model.select(.usage, in: .reports) }),
      ("Usage → Orphans", { model.usagePage = .files; model.select(.orphans, in: .reports) }),
      ("Orphans → Usage Files", { model.select(.usage, in: .reports) }),
      ("Usage → Externals Grid", { model.select(.externals, in: .reports) }),
      ("Externals Grid → List", { model.surfaceViewMode = .table }),
      ("Externals List → Grid", { model.surfaceViewMode = .grid }),
      ("Externals → Usage", { model.select(.usage, in: .reports) }),
    ]
    // Per step: what NSToolbar removed, and any change of identifiers.
    var removals: [String: [String]] = [:]
    var reorders: [String: [String]] = [:]
    for (name, step) in steps {
      let before = identifiers()
      removed = []
      step()
      await spin(0.8)
      if !removed.isEmpty { removals[name] = removed }
      if identifiers() != before { reorders[name] = identifiers() }
    }
    #expect(removals == [:])
    #expect(reorders == [:])
    // The steps did reach the surfaces they name.
    #expect(model.sidebarSelection == .usage && model.usagePage == .files)
    #expect(model.externals.count(.yours) == 1 && model.externals.count(.other) == 1)
  }
}
