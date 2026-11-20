import AppKit
import CatalogCore
import Foundation
import SwiftUI
@testable import PinaxUI
import Testing

/// The panel's glass, its appearance and its
/// layout, measured on the panel `DropZoneController` itself builds — the
/// one the app installs — with preferences in an isolated UserDefaults
/// suite. No click is synthesized and no menu is opened.
///
/// Serialized: hosted windows do not survive interleaving at suspension
/// points (LayoutStabilityTests).
@MainActor
@Suite(.serialized) struct DropZoneLookTests {
  typealias Part = DropZoneLayoutKey.Part

  // MARK: - Property 1: behind-window glass

  @Test("The panel's lowest layer is a behind-window, always-active effect view; no thin material")
  func behindWindowGlass() async throws {
    let (controller, _, _) = try makeController()
    controller.model.revealOnDemand()
    await waitUntil { controller.panelContentView != nil }
    let content = try #require(controller.panelContentView)
    if GlassSupport.panelUsesBehindWindowMaterial {
      let glass = try #require(content.subviews.first as? NSVisualEffectView, "\(content.subviews)")
      #expect(glass.blendingMode == .behindWindow)
      #expect(glass.state == .active)
      #expect(glass.maskImage != nil)
      #expect(glass.frame == content.bounds)
      #expect(glass.autoresizingMask.contains([.width, .height]))
    }
    // The old fallback lived in the panel's glass modifier.
    for file in ["DropZone/DropZoneView.swift", "DropZone/ShelfCellView.swift", "Style/GlassBackground.swift"] {
      let source = try String(contentsOf: Self.source(file), encoding: .utf8)
      #expect(!source.contains(".thinMaterial"), "\(file)")
    }
    controller.setEnabled(false)
  }

  // MARK: - Property 2: appearance

  @Test("Light and Dark force the panel's appearance, Match System leaves it nil; the app's is untouched")
  func appearance() async throws {
    let (controller, preferences, _) = try makeController()
    let appAppearance = NSApplication.shared.appearance
    #expect(preferences.dropZoneAppearance == .system)
    controller.model.revealOnDemand()
    await waitUntil { controller.panelWindow != nil }
    let panel = try #require(controller.panelWindow)
    #expect(panel.appearance == nil)

    preferences.dropZoneAppearance = .light
    await waitUntil { panel.appearance != nil }
    #expect(panel.appearance?.name == .aqua)
    #expect(panel.effectiveAppearance.name == .aqua)

    preferences.dropZoneAppearance = .dark
    await waitUntil { panel.appearance?.name == .darkAqua }
    #expect(panel.appearance?.name == .darkAqua)
    #expect(panel.effectiveAppearance.name == .darkAqua)

    preferences.dropZoneAppearance = .system
    await waitUntil { panel.appearance == nil }
    #expect(panel.appearance == nil)
    #expect(NSApplication.shared.appearance == appAppearance)
    controller.setEnabled(false)
  }

  @Test("The look survives a restart")
  func lookPersists() throws {
    let defaults = try makeDefaults()
    let preferences = PreferencesStore(defaults: defaults)
    #expect(preferences.dropZoneLayout == .list)
    preferences.dropZoneAppearance = .dark
    preferences.dropZoneLayout = .shelf
    let reopened = PreferencesStore(defaults: defaults)
    #expect(reopened.dropZoneAppearance == .dark)
    #expect(reopened.dropZoneLayout == .shelf)
    #expect(defaults.string(forKey: "pinax.dropZone.appearance") == "dark")
    #expect(defaults.string(forKey: "pinax.dropZone.layout") == "shelf")
  }

  // MARK: - Property 3: layout

  @Test("List stacks cards on one left edge; Shelf puts two side by side and wraps the third; switching is live")
  func layout() async throws {
    let (controller, preferences, model) = try makeController()
    model.drop(fileURLs: ["a", "b", "c"].map { URL(fileURLWithPath: "/pinax-look/\($0).png") })
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    await waitUntil { controller.panelWindow != nil }
    let ids = model.cards.map(\.id)
    func read() -> [CGRect] {
      ids.compactMap { controller.viewState.layoutFrames[Part(card: $0, role: .card)] }
    }
    // Wait for all three cards in the layout asked for, not for a fixed
    // 0.4 s (measured red in parallel full runs: the Shelf frames read while
    // the List layout was still on screen).
    func stacked(_ f: [CGRect]) -> Bool {
      f.count == 3 && Set(f.map { ($0.minX * 2).rounded() }).count == 1
        && f[0].maxY <= f[1].minY && f[1].maxY <= f[2].minY
    }
    func shelved(_ f: [CGRect]) -> Bool {
      f.count == 3 && abs(f[0].minY - f[1].minY) < 0.5 && f[1].minX > f[0].maxX
        && abs(f[2].minX - f[0].minX) < 0.5 && f[2].minY >= f[0].maxY
    }
    func cards(_ settled: ([CGRect]) -> Bool) async -> [CGRect] {
      await spin(until: { settled(read()) })
      return read()
    }

    let list = await cards(stacked)
    #expect(list.count == 3, "\(list)")
    #expect(Set(list.map { ($0.minX * 2).rounded() }).count == 1, "\(list)")
    #expect(list[0].maxY <= list[1].minY && list[1].maxY <= list[2].minY, "\(list)")

    preferences.dropZoneLayout = .shelf
    let shelf = await cards(shelved)
    #expect(shelf.count == 3, "\(shelf)")
    #expect(abs(shelf[0].minY - shelf[1].minY) < 0.5, "\(shelf)")
    #expect(shelf[1].minX > shelf[0].maxX, "\(shelf)")
    #expect(abs(shelf[2].minX - shelf[0].minX) < 0.5, "\(shelf)")
    #expect(shelf[2].minY >= shelf[0].maxY, "\(shelf)")

    preferences.dropZoneLayout = .list
    let back = await cards(stacked)
    #expect(back.count == 3 && back[0].maxY <= back[1].minY, "\(back)")
    controller.setEnabled(false)
  }

  // MARK: - Helpers

  static func source(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PinaxUITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // the package root
      .appendingPathComponent("Sources/PinaxUI/\(name)")
  }

  private func makeController() throws -> (DropZoneController, PreferencesStore, DropZoneModel) {
    let thumbnails = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-look-\(UUID().uuidString)", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let model = DropZoneModel(service: LookUploadService(), thumbnails: thumbnails)
    model.copiesURLsAutomatically = false
    model.loadProjects()
    let preferences = PreferencesStore(defaults: try makeDefaults())
    let controller = DropZoneController(model: model, preferences: preferences)
    return (controller, preferences, model)
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-look-\(UUID().uuidString)"))
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

  /// Pumps like `spin` until `condition` holds, then one more segment so
  /// the update the condition reflects is laid out — or until `timeout`,
  /// when the caller's assertions fail on what was read. A condition, not
  /// a delay: the parallel full run starves the main thread, and a fixed
  /// 0.4 s measurably read layouts and loads that had not landed yet.
  private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    pumpRunLoop(until: Date().addingTimeInterval(0.05))
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

/// Every upload lands at once; nothing leaves the process.
private final class LookUploadService: DropZoneService, @unchecked Sendable {
  func projects() throws -> [Project] {
    [
      Project(
        slug: "blog", name: "Blog", keyPrefix: "blog", backendID: 1,
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z")
    ]
  }

  func upload(_ fileURL: URL, projectSlug: String?) async throws -> UploadOutcome {
    let name = fileURL.lastPathComponent
    return UploadOutcome(
      sha256: String(repeating: "0c", count: 32), key: "blog/\(name)",
      url: "https://img.example.com/blog/\(name)", mime: "image/png", originalFilename: name,
      byteSize: 1234, width: 800, height: 600, uploadedAt: "2026-08-22T00:00:00Z",
      deduplicated: false, dryRun: false)
  }

  func moveAsset(sha256: String, fromProject: String?, toProject: String?, confirmed: Bool) async throws {}
}
