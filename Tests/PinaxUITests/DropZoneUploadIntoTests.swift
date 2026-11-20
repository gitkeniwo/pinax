import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Settings ▸ Drop Zone ▸ Upload into and Size, through the app's own
/// wiring (`PinaxAppModel.start()` builds the zone, its controller and the
/// link between the zone's project and the current project). Each test has its own UserDefaults
/// suite and a temporary catalog; the panel is shown with Show Drop Zone's
/// reveal, never by a drag, and no click is synthesized.
///
/// Serialized: the panels are real windows (LayoutStabilityTests).
@MainActor
@Suite(.serialized) struct DropZoneUploadIntoTests {
  // MARK: - Property 8: Upload into

  @Test("A fixed project is where each appearance starts; the panel's choice never reaches the current project; No Project likewise; back to Current Project mirrors again; kept across a restart")
  func fixedTarget() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()
    defaults.set("blog", forKey: "pinax.currentProject")
    let app = try await start(database, defaults)
    let zone = try #require(app.dropZone).model
    defer { app.dropZone?.setEnabled(false) }
    #expect(app.preferences.dropZoneUploadInto == .currentProject)

    app.preferences.dropZoneUploadInto = .project("notes")
    #expect(defaults.string(forKey: "pinax.dropZone.uploadInto") == "project:notes")
    await appear(zone)
    #expect(zone.selectedProjectSlug == "notes")
    #expect(app.preferences.currentProjectSlug == "blog")

    // The panel's picker changes this appearance only.
    zone.selectedProjectSlug = nil
    #expect(app.preferences.currentProjectSlug == "blog")
    #expect(defaults.string(forKey: "pinax.currentProject") == "blog")
    // The main window's choice does not reach the open panel either.
    app.preferences.currentProjectSlug = nil
    #expect(zone.selectedProjectSlug == nil)
    app.preferences.currentProjectSlug = "blog"
    #expect(zone.selectedProjectSlug == nil)

    // Next appearance: the fixed project again.
    await disappear(zone)
    await appear(zone)
    #expect(zone.selectedProjectSlug == "notes")

    // No Project, likewise.
    app.preferences.dropZoneUploadInto = .noProject
    await disappear(zone)
    await appear(zone)
    #expect(zone.selectedProjectSlug == nil)
    zone.selectedProjectSlug = "notes"
    #expect(app.preferences.currentProjectSlug == "blog")

    // Back to Current Project: mirrored at once, both ways.
    app.preferences.dropZoneUploadInto = .currentProject
    #expect(zone.selectedProjectSlug == "blog")
    zone.selectedProjectSlug = "notes"
    #expect(app.preferences.currentProjectSlug == "notes")
    app.preferences.currentProjectSlug = "blog"
    #expect(zone.selectedProjectSlug == "blog")

    // A restart keeps the choice.
    app.preferences.dropZoneUploadInto = .project("notes")
    let reopened = PreferencesStore(defaults: defaults)
    #expect(reopened.dropZoneUploadInto == .project("notes"))
  }

  @Test("A fixed project that is deleted behaves as Current Project")
  func deletedFixedProject() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()
    defaults.set("blog", forKey: "pinax.currentProject")
    defaults.set("project:notes", forKey: "pinax.dropZone.uploadInto")
    let app = try await start(database, defaults)
    let zone = try #require(app.dropZone).model
    defer { app.dropZone?.setEnabled(false) }
    await appear(zone)
    #expect(zone.selectedProjectSlug == "notes")

    _ = try await database.write { db in
      try db.execute(sql: "DELETE FROM project WHERE slug = 'notes'")
    }
    zone.loadProjects()
    #expect(zone.projects.map(\.slug) == ["blog"])
    // Mirrors the current project again, and the current project is intact.
    #expect(zone.selectedProjectSlug == "blog")
    #expect(app.preferences.currentProjectSlug == "blog")
    // Mirrored both ways, and on the next appearance.
    zone.selectedProjectSlug = nil
    #expect(app.preferences.currentProjectSlug == nil)
    app.preferences.currentProjectSlug = "blog"
    #expect(zone.selectedProjectSlug == "blog")
    await disappear(zone)
    await appear(zone)
    #expect(zone.selectedProjectSlug == "blog")

    // Settings shows what it means.
    let pane = DropZoneSettingsPane(preferences: app.preferences, projects: zone.projects)
    #expect(pane.uploadIntoChoice == .currentProject)
  }

  // MARK: - Property 9: Size

  @Test("Width and Height size the panel and the SwiftUI root; out-of-range values clamp; Reset is 340 × 420; kept across a restart")
  func sizeFromPreferences() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()
    let app = try await start(database, defaults)
    let controller = try #require(app.dropZone)
    defer { controller.setEnabled(false) }
    let preferences = app.preferences
    #expect(preferences.dropZoneSize == CGSize(width: 340, height: 420))

    preferences.setDropZoneSize(CGSize(width: 1000, height: 100))
    #expect(preferences.dropZoneSize == CGSize(width: 560, height: 320))
    preferences.setDropZoneSize(CGSize(width: 10, height: 5000))
    #expect(preferences.dropZoneSize == CGSize(width: 280, height: 800))
    preferences.resetDropZoneSize()
    #expect(preferences.dropZoneSize == CGSize(width: 340, height: 420))

    let size = CGSize(width: 480, height: 600)
    preferences.setDropZoneSize(size)
    #expect(defaults.double(forKey: "pinax.dropZone.width") == 480)
    #expect(defaults.double(forKey: "pinax.dropZone.height") == 600)
    defaults.set(9999.0, forKey: "pinax.dropZone.height")
    #expect(PreferencesStore(defaults: defaults).dropZoneSize == CGSize(width: 480, height: 800))
    defaults.set(600.0, forKey: "pinax.dropZone.height")

    controller.model.revealOnDemand()
    await waitUntil { controller.panelWindow?.isVisible == true }
    let panel = try #require(controller.panelWindow)
    #expect(panel.contentLayoutRect.size == size)
    #expect(await rootSize(controller) == size)

    // Live: a new size while the panel is up.
    let smaller = CGSize(width: 300, height: 360)
    preferences.setDropZoneSize(smaller)
    await waitUntil { panel.contentLayoutRect.size == smaller }
    #expect(panel.contentLayoutRect.size == smaller)
    #expect(await rootSize(controller) == smaller)
    #expect(controller.viewState.panelSize == smaller)
  }

  @Test("The size a resize ends at is written back, clamped; the corner and screen re-placement hold at that size")
  func resizeWritesBack() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = try await start(database, try makeDefaults())
    let controller = try #require(app.dropZone)
    defer { controller.setEnabled(false) }
    let preferences = app.preferences
    controller.model.revealOnDemand()
    await waitUntil { controller.panelWindow?.isVisible == true }
    let panel = try #require(controller.panelWindow)

    // The edge's live resize, as AppKit ends it. Settled when the panel
    // has been placed twice since: once by the resize's end, once by the
    // preferences change it wrote.
    func endResize(at size: CGSize) async {
      let placed = controller.placementRecomputations
      panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
      NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: panel)
      await waitUntil { controller.placementRecomputations >= placed + 2 }
    }
    await endResize(at: CGSize(width: 470, height: 380))
    #expect(preferences.dropZoneSize == CGSize(width: 470, height: 380))
    #expect(panel.contentLayoutRect.size == CGSize(width: 470, height: 380))

    await endResize(at: CGSize(width: 200, height: 900))
    await waitUntil { preferences.dropZoneSize == CGSize(width: 280, height: 800) }
    #expect(preferences.dropZoneSize == CGSize(width: 280, height: 800))
    await waitUntil { panel.contentLayoutRect.size == CGSize(width: 280, height: 800) }
    #expect(panel.contentLayoutRect.size == CGSize(width: 280, height: 800))

    // Placement at a non-default size: the corner, then a screen change.
    let size = CGSize(width: 480, height: 600)
    preferences.setDropZoneSize(size)
    await waitUntil { panel.contentLayoutRect.size == size }
    let visible = try #require(panel.screen ?? NSScreen.main).visibleFrame
    var before = controller.placementRecomputations
    preferences.dropZoneCorner = .topRight
    await waitUntil { controller.placementRecomputations > before }
    let frame = try #require(controller.panelFrame)
    #expect(frame.size == size)
    #expect(abs(frame.maxX - (visible.maxX - 24)) < 1, "\(frame) in \(visible)")
    #expect(abs(frame.maxY - (visible.maxY - 24)) < 1, "\(frame) in \(visible)")
    before = controller.placementRecomputations
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    await waitUntil { controller.placementRecomputations > before }
    let placed = try #require(controller.panelFrame)
    #expect(placed.minX >= visible.minX - 1 && placed.maxX <= visible.maxX + 1, "\(placed)")
    #expect(placed.minY >= visible.minY - 1 && placed.maxY <= visible.maxY + 1, "\(placed)")
  }

  // MARK: - Helpers

  private func start(_ database: DatabasePool, _ defaults: UserDefaults) async throws -> PinaxAppModel {
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: defaults, databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await app.start()
    return app
  }

  private func appear(_ zone: DropZoneModel) async {
    zone.revealOnDemand()
    await waitUntil { zone.isWindowVisible }
  }

  private func disappear(_ zone: DropZoneModel) async {
    zone.dismiss()
    await waitUntil { !zone.isWindowVisible }
  }

  /// The SwiftUI root's size, as the panel the app hosts laid it out.
  private func rootSize(_ controller: DropZoneController) async -> CGSize? {
    await spin(0.4)
    return controller.viewState.layoutFrames[DropZoneLayoutKey.Part(card: nil, role: .panel)]?.size
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-upload-into-\(UUID().uuidString)"))
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
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.02))
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}
