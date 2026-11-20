import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// The current project — one preference that the Project
/// menu and the drop zone read and write, and that scopes the reports and
/// Scan Now. Everything goes through the app's own wiring
/// (`PinaxAppModel.start()`, `PinaxCommands`); no menu is opened and
/// nothing is clicked. Each test has its own UserDefaults suite and a
/// temporary catalog.
@MainActor
@Suite struct CurrentProjectTests {
  // MARK: - Property 1: one value

  @Test("The Project menu, the drop zone and the title-area picker read and write the one preference, through the app's wiring")
  func oneValue() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: defaults, databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await app.start()
    let gallery = try #require(app.gallery)
    let zone = try #require(app.dropZone).model
    let commands = PinaxCommands(app: app)

    // Starts on All Projects everywhere.
    #expect(commands.projectItems.current == nil)
    #expect(zone.selectedProjectSlug == nil)
    #expect(gallery.currentProjectSlug == nil)
    #expect(commands.projectItems.scanTitle == "Scan All")
    #expect(commands.projectItems.projects.map(\.slug) == ["blog", "notes"])

    // The menu writes; the drop zone, the reports and the stored key follow.
    commands.projectItems.current = "notes"
    #expect(app.preferences.currentProjectSlug == "notes")
    #expect(defaults.string(forKey: "pinax.currentProject") == "notes")
    #expect(zone.selectedProjectSlug == "notes")
    #expect(gallery.currentProjectSlug == "notes")
    #expect(gallery.externals.selectedProjectSlug == "notes")
    #expect(commands.projectItems.scanTitle == "Scan Now")

    // The drop zone writes; the menu reads it back.
    zone.selectedProjectSlug = "blog"
    #expect(commands.projectItems.current == "blog")
    #expect(defaults.string(forKey: "pinax.currentProject") == "blog")
    #expect(gallery.currentProjectSlug == "blog")
    #expect(gallery.externals.selectedProjectSlug == "blog")

    // The title-area picker's row writes; the menu, the drop zone and
    // the reports read it back — and the picker reads what the menu wrote.
    await gallery.loadInitialData()
    try #require(ProjectPickerTests.row("Notes", gallery)).choose()
    #expect(commands.projectItems.current == "notes")
    #expect(defaults.string(forKey: "pinax.currentProject") == "notes")
    #expect(zone.selectedProjectSlug == "notes")
    #expect(gallery.currentProjectSlug == "notes")
    commands.projectItems.current = "blog"
    #expect(
      ProjectPickerTests.sections(ProjectPickerView(model: gallery)).first?.map(\.row.slug)
        == ["blog"])

    // Back to All Projects from the menu.
    commands.projectItems.current = nil
    #expect(zone.selectedProjectSlug == nil)
    #expect(gallery.currentProjectSlug == nil)
    #expect(defaults.object(forKey: "pinax.currentProject") == nil)
  }

  // MARK: - Property 2: kept, vanished, migrated

  @Test("The choice survives a restart; a deleted project reads as All Projects; the drop zone's old key migrates")
  func keptAcrossRestart() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Kept.
    let kept = try makeDefaults()
    let first = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: kept, databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await first.start()
    PinaxCommands(app: first).projectItems.current = "notes"
    let second = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: kept, databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await second.start()
    #expect(PinaxCommands(app: second).projectItems.current == "notes")
    #expect(try #require(second.dropZone).model.selectedProjectSlug == "notes")
    #expect(try #require(second.gallery).currentProjectSlug == "notes")

    // A project that is gone.
    let vanished = try makeDefaults()
    vanished.set("ghost", forKey: "pinax.currentProject")
    let third = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: vanished, databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await third.start()
    #expect(PinaxCommands(app: third).projectItems.current == nil)
    #expect(try #require(third.dropZone).model.selectedProjectSlug == nil)
    #expect(try #require(third.gallery).currentProjectSlug == nil)

    // The drop zone's old key, once.
    let legacy = try makeDefaults()
    legacy.set("blog", forKey: "pinax.dropZone.projectSlug")
    let fourth = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: legacy, databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await fourth.start()
    #expect(PinaxCommands(app: fourth).projectItems.current == "blog")
    #expect(try #require(fourth.dropZone).model.selectedProjectSlug == "blog")
    #expect(legacy.string(forKey: "pinax.currentProject") == "blog")
    #expect(legacy.object(forKey: "pinax.dropZone.projectSlug") == nil)
    // Once: All Projects chosen afterwards is not overwritten by the old key.
    PinaxCommands(app: fourth).projectItems.current = nil
    let fifth = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: legacy, databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await fifth.start()
    #expect(PinaxCommands(app: fifth).projectItems.current == nil)
  }

  // MARK: - Property 3: the reports are scoped

  @Test("Orphans under each project differ from each other and from All Projects")
  func orphansAreScoped() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 2, uploadedAt: "2026-08-03T00:00:00Z", projectSlug: "notes")
    try seedAsset(database, index: 3, uploadedAt: "2026-08-04T00:00:00Z", projectSlug: nil)
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try makeDefaults(), databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await app.start()
    let gallery = try #require(app.gallery)
    let commands = PinaxCommands(app: app)

    gallery.select(.orphans, in: .reports)
    func orphans(_ project: String?) async -> Set<String> {
      commands.projectItems.current = project
      // The change starts its own reload; wait for the newest to land.
      await gallery.reload()
      await waitUntil { !gallery.isLoadingPage }
      return Set(gallery.orphanReport?.assets.map(\.asset.key) ?? [])
    }
    let global = await orphans(nil)
    let blog = await orphans("blog")
    let notes = await orphans("notes")

    #expect(global.count == 4, "\(global)")
    #expect(blog.count == 2, "\(blog)")
    #expect(notes.count == 1, "\(notes)")
    #expect(blog != notes)
    #expect(blog != global)
    #expect(notes != global)
    #expect(blog.isSubset(of: global) && notes.isSubset(of: global))
  }

  // MARK: - Scan All

  @Test("Scan All under All Projects scans every project with sources, then lists each failure")
  func scanAllListsFailures() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for slug in ["blog", "notes"] {
      try FileManager.default.createDirectory(
        atPath: directory.path + "/\(slug)-src", withIntermediateDirectories: true)
      try CatalogConfiguration.setProjectSources(
        slug: slug, [ProjectSource(label: "src", path: directory.path + "/\(slug)-src")],
        in: database)
    }
    // blog, scanned first, fails; notes must still be scanned.
    let recorder = FailingSynchronizer(failing: ["blog"])
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try makeDefaults(), databaseOpener: { database },
      usageSynchronizer: { _ in recorder }, chooseSourceFolder: { _ in nil })
    await app.start()
    let usageSync = try #require(app.usageSync)
    let gallery = try #require(app.gallery)
    await waitUntil { gallery.sourcedProjects == ["blog", "notes"] }

    let menu = PinaxCommands(app: app).projectItems
    #expect(menu.scanTitle == "Scan All")
    #expect(menu.canScan)
    menu.scanNow()
    await waitUntil { recorder.scans.count == 2 && !usageSync.isSyncing }

    #expect(recorder.scans == ["blog", "notes"])
    let activity = try #require(usageSync.scanActivity)
    guard case let .summary(projects, failures) = activity else {
      Issue.record("\(activity)")
      return
    }
    #expect(projects == 2)
    #expect(failures.map(\.project) == ["blog"])
    #expect(activity.isFailure)
    #expect(activity.text.hasPrefix("Scanned 1 of 2 projects · Failed: blog: "), "\(activity.text)")

    // An empty scan is listed too, with no confirmation left waiting.
    recorder.rejectingEmpty = ["notes"]
    menu.scanNow()
    await waitUntil { recorder.scans.count == 4 && !usageSync.isSyncing }
    #expect(recorder.scans == ["blog", "notes", "blog", "notes"])
    #expect(!usageSync.requiresEmptyScanConfirmation)
    #expect(
      usageSync.scanActivity?.text
        == "Scanned 0 of 2 projects · Failed: blog: no sources readable; "
        + "notes: found nothing where the last scan found 7; scan it alone to accept")
  }

  // MARK: - Helpers

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-current-project-\(UUID().uuidString)"))
  }

  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}

private struct ScanFailure: LocalizedError {
  var errorDescription: String? { "no sources readable" }
}

/// Records every scan; throws for the projects it was told to fail.
private final class FailingSynchronizer: UsageSyncing, @unchecked Sendable {
  private let lock = NSLock()
  private let failing: Set<String>
  private var _scans: [String] = []
  private var _rejectingEmpty: Set<String> = []

  init(failing: Set<String>) { self.failing = failing }

  var scans: [String] { lock.withLock { _scans } }
  /// Projects whose scan comes back empty after one that found 7.
  var rejectingEmpty: Set<String> {
    get { lock.withLock { _rejectingEmpty } }
    set { lock.withLock { _rejectingEmpty = newValue } }
  }

  func projects() async throws -> [String] { ["blog", "notes"] }

  func sync(documentAt source: URL, project: String, allowEmpty: Bool) async throws
    -> UsageSyncResult
  {
    UsageSyncResult(scanID: 0, foundCount: 0)
  }

  func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome {
    lock.withLock { _scans.append(project) }
    if failing.contains(project) { throw ScanFailure() }
    if rejectingEmpty.contains(project) { throw UsageCatalogError.emptyScanRejected(previousFoundCount: 7) }
    return UsageScanOutcome(sync: UsageSyncResult(scanID: 0, foundCount: 3), files: 1, skipped: 0)
  }
}
