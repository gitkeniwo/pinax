import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Property: switching the navigator, or
/// between a library surface and a report surface, never takes the window
/// subtitle through the empty string — AppKit draws an empty subtitle as
/// one centred line, so the title jumps. While the new surface's line is
/// unknown the previous one stays.
///
/// The window is a real hosted `GalleryView`; `NSWindow.subtitle` is
/// recorded by KVO, so every value AppKit was handed is seen, not only the
/// one left at the end. The subtitle is the current project, so the
/// different lines come from switching the project.
@MainActor
@Suite(.serialized) struct WindowSubtitleTests {
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

  /// What `GalleryView` composes for the current surface — empty while its
  /// line is unknown.
  private func composed(_ model: GalleryModel) -> String {
    WindowTitle.compose(
      selection: model.sidebarSelection, projects: model.projects,
      currentProjectSlug: model.currentProjectSlug
    ).subtitle
  }

  /// Spins until the surface's own line has arrived and reached the window.
  private func settle(_ model: GalleryModel, _ window: NSWindow) async {
    await spin(0.2)
    for _ in 0..<100 where composed(model).isEmpty || window.subtitle != composed(model) {
      await spin(0.05)
    }
  }

  @Test("The subtitle never passes through the empty string")
  func subtitleNeverBlanks() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<3 {
      try seedAsset(
        database, index: index, uploadedAt: String(format: "2026-08-20T12:%02d:00Z", index))
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await model.loadInitialData()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    window.contentViewController = NSHostingController(rootView: GalleryView(model: model))
    // Not key: the subtitle does not need focus, and suites run side by
    // side with ones that do.
    window.orderFront(nil)
    await settle(model, window)

    var seen: [String] = []
    let observation = window.observe(\.subtitle, options: [.initial, .new]) { _, change in
      MainActor.assumeIsolated { seen.append(change.newValue ?? "<nil>") }
    }
    defer { observation.invalidate() }

    // The sidebar's navigator icons write `navigator` (SidebarNavigatorPicker);
    // its leaf rows go through `select(_:in:)`.
    for navigator in [SidebarNavigator.time, .collections, .reports, .library] {
      model.navigator = navigator
      await settle(model, window)
    }
    for (surface, navigator) in [
      (SidebarSelection.usage, SidebarNavigator.reports), (.all, .library),
    ] {
      model.select(surface, in: navigator)
      await settle(model, window)
    }
    // Report to report, Externals' first visit so its line is not loaded
    // yet: the line kept meanwhile is Usage's, the one just shown — not an
    // older one (every library surface here reads "3 assets", so a value
    // remembered once would pass the check above).
    model.select(.usage, in: .reports)
    model.currentProjectSlug = "blog"
    await settle(model, window)
    let usageLine = window.subtitle
    let mark = seen.endIndex
    model.select(.externals, in: .reports)
    await settle(model, window)
    #expect(
      Set(seen[mark...]).isSubset(of: [usageLine, window.subtitle]),
      "\(usageLine) → \(seen[mark...])")
    model.currentProjectSlug = nil
    await settle(model, window)
    model.select(.all, in: .library)
    await settle(model, window)

    // Control: the switches did reach the window, with different lines.
    #expect(Set(seen.filter { !$0.isEmpty }).count >= 2, "\(seen)")
    let firstFilled = seen.firstIndex { !$0.isEmpty } ?? seen.endIndex
    let lastFilled = seen.lastIndex { !$0.isEmpty } ?? seen.startIndex
    if firstFilled < lastFilled {
      let between = seen[firstFilled...lastFilled]
      #expect(!between.contains(""), "\(seen)")
    }
    #expect(window.subtitle == "All Projects", "\(seen)")
    #expect(seen.contains(model.projects.first { $0.slug == "blog" }?.name ?? "?"), "\(seen)")
  }
}
