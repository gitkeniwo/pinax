import ArgumentParser
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

@testable import pinax

/// Usage not tracked. `blog` tracked and scanned
/// twice, `notes` tracked and never scanned, and four not-tracked projects
/// (`social`, `press`, `wire`, `desk`) — and the asset combinations that
/// matter, every set worked out by hand below.
@MainActor
@Suite("Usage not tracked")
struct UsageNotTrackedTests {
  /// Asset index → key (`seedAsset` keys are `<project>/asset-<index>.png`).
  ///  0  in social, press and wire                    → untracked
  ///  1  in blog and social, unused in blog's scans    → candidate
  ///  2  in no project                                 → candidate
  ///  3  only in notes (never scanned)                 → candidate, Not yet scanned
  ///  4  in blog and desk, used in blog                → neither
  ///  5  in blog, social and press, used in blog       → neither
  ///  6  in notes (never scanned) and social           → candidate, Not yet scanned
  ///     (a tracked project's verdict stands)
  ///
  /// The counts are chosen to be pairwise different in both states the tests
  /// reach, so a number read off the wrong set cannot coincide:
  ///
  ///                         untracked assets  untrackedProjects  notTrackedProjects
  ///   as seeded                    1                 3                  4
  ///   notes → Not Tracked          3                 4                  5
  ///
  /// (`desk` has only asset 4, which `blog` also has, so it is in no
  /// untracked asset's projects; asset 0 is in three not-tracked projects.)
  static func withFixture(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO project
            (id, slug, name, key_prefix, backend_id, last_scan_id, created_at, updated_at)
          VALUES (3, 'social', 'Social', 'social', 1, NULL,
                  '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
                 (4, 'press', 'Press', 'press', 1, NULL,
                  '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
                 (5, 'wire', 'Wire', 'wire', 1, NULL,
                  '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
                 (6, 'desk', 'Desk', 'desk', 1, NULL,
                  '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z')
          """)
    }
    for slug in ["social", "press", "wire", "desk"] {
      try CatalogConfiguration.setUsageTracking(slug: slug, .notTracked, in: database)
    }
    let homes: [String?] = ["social", "blog", nil, "notes", "blog", "blog", "notes"]
    for (index, project) in homes.enumerated() {
      try seedAsset(
        database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z",
        projectSlug: project)
    }
    try await database.write { db in
      // (asset key, project id): social 3, press 4, wire 5, desk 6.
      let memberships: [(String, Int)] = [
        ("blog/asset-1.png", 3), ("blog/asset-5.png", 3), ("blog/asset-5.png", 4),
        ("social/asset-0.png", 4), ("social/asset-0.png", 5),
        ("blog/asset-4.png", 6), ("notes/asset-6.png", 3),
      ]
      for (key, projectID) in memberships {
        try db.execute(
          sql: """
            INSERT INTO asset_project (asset_id, project_id, added_at)
            SELECT a.id, ?, '2026-08-01T00:00:00Z' FROM asset a WHERE a.key = ?
            """,
          arguments: [projectID, key])
      }
    }
    let document = UsageDocument(
      project: "blog",
      refs: [4, 5].map {
        UsageReference(
          rawURL: "https://img.example.com/blog/asset-\($0).png", sourceReference: "post.md")
      })
    for second in [0, 60] {
      _ = try CatalogUsage.sync(
        document, project: "blog", in: database,
        now: Date(timeIntervalSince1970: 1_787_184_000 + Double(second)))
    }
    try await body(database)
  }

  static func keys(_ items: [CatalogAssetItem]) -> [String] { items.map(\.asset.key) }

  @Test("Candidates only in not-tracked projects move to untracked; not-tracked projects are never under-scanned")
  func report() async throws {
    try await Self.withFixture { database in
      let all = try await CatalogUsage.orphans(in: database)
      #expect(Self.keys(all.assets) == [
        "blog/asset-1.png", "x/asset-2.png", "notes/asset-3.png", "notes/asset-6.png",
      ])
      #expect(Self.keys(all.untracked) == ["social/asset-0.png"])
      #expect(all.unscannedProjects == ["notes"])
      #expect(all.notTrackedProjects == ["desk", "press", "social", "wire"])
      #expect(all.untrackedProjects == ["press", "social", "wire"])
      // 1, 3 and 4: no two of the three numbers the UI and the CLI print
      // may be the same.
      let counts: [Int] = [
        all.untracked.count, all.untrackedProjects.count, all.notTrackedProjects.count,
      ]
      #expect(counts == [1, 3, 4])

      // Scoped to the not-tracked project: its only-there asset is
      // untracked; those also in tracked `blog` stay candidates, and the
      // scope ignores blog's usage as it always has, so 5 is one too; 6 is
      // also in tracked notes.
      let social = try await CatalogUsage.orphans(project: "social", in: database)
      #expect(Self.keys(social.assets) == [
        "blog/asset-1.png", "blog/asset-5.png", "notes/asset-6.png",
      ])
      #expect(Self.keys(social.untracked) == ["social/asset-0.png"])
      #expect(social.unscannedProjects.isEmpty)

      let blog = try await CatalogUsage.orphans(project: "blog", in: database)
      #expect(Self.keys(blog.assets) == ["blog/asset-1.png"])
      #expect(blog.untracked.isEmpty)
      #expect(blog.notTrackedProjects.isEmpty)
    }
  }

  @Test("A not-tracked project with a source still scans, and its live usage reads back")
  func notTrackedStillScans() async throws {
    try await Self.withFixture { database in
      let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinax-social-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: source) }
      try "![](https://img.example.com/social/asset-0.png)\n".write(
        to: source.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)
      try CatalogConfiguration.setProjectSources(
        slug: "social", [ProjectSource(label: "posts", path: source.path)], in: database)

      let scan = try UsageScanner.scan(project: "social", in: database)
      _ = try CatalogUsage.sync(scan.document, project: "social", in: database)
      let live = try await CatalogUsage.liveUsage(project: "social", in: database)
      #expect(live.references.map(\.sourceReference) == ["posts/post.md#L1"])
      #expect(live.scannedProjects == ["social"])
      // Used now, so no longer counted as untracked; tracking is unchanged.
      #expect(try await CatalogUsage.orphans(in: database).untracked.isEmpty)
      #expect(
        try CatalogConfiguration.projectSettings(slug: "social", in: database).usageTracking
          == .notTracked)
    }
  }

  private func orphans(_ arguments: [String]) throws -> OrphansCommand {
    try #require(try Pinax.parseAsRoot(["orphans"] + arguments) as? OrphansCommand)
  }

  @Test("pinax orphans ends with the not-tracked line; it is absent when N is 0")
  func commandLine() async throws {
    try await Self.withFixture { database in
      let all = try orphans([]).output(in: database)
      #expect(
        all.notes
          == "WARNING: orphan results are a lower bound. Do not use this list as proof that remote objects are unused.\n"
          + "Fewer than 2 completed scans: notes\n")
      #expect(
        all.table
          == "SHA256\tKEY\tURL\n"
          + "000000000000\tblog/asset-1.png\thttps://img.example.com/blog/asset-1.png\n"
          + "000000000000\tx/asset-2.png\thttps://img.example.com/x/asset-2.png\n"
          + "000000000000\tnotes/asset-3.png\thttps://img.example.com/notes/asset-3.png\n"
          + "000000000000\tnotes/asset-6.png\thttps://img.example.com/notes/asset-6.png\n")
      #expect(all.trailer == "1 assets only in not-tracked projects: press, social, wire\n")

      #expect(try orphans(["--project", "blog"]).output(in: database).trailer == "")
    }
  }

  // MARK: - Settings ▸ Projects and the Orphans surface, through the app

  private func start(_ database: DatabasePool) async throws -> PinaxAppModel {
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try #require(UserDefaults(suiteName: "pinaxui-t08-\(UUID().uuidString)")),
      databaseOpener: { database },
      chooseSourceFolder: { _ in nil })
    await app.start()
    return app
  }

  /// A cap, not a delay: a loaded parallel run starved a 5 s one, so it is
  /// generous; a passing run leaves as soon as the condition holds.
  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(20)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func showOrphans(_ gallery: GalleryModel) async {
    gallery.select(.orphans, in: SidebarModel.navigator(for: .orphans))
    await gallery.reload()
    await waitUntil { gallery.orphanReport != nil }
  }

  /// The Details lines the Orphans header draws, read off `OrphanView`.
  private func orphanDetailLines(_ gallery: GalleryModel) -> [String] {
    collectViews(
      OrphanView(model: gallery), as: ReportHeader<EmptyView, OpenMaintenanceButton?>.self
    ).flatMap { $0.details.flatMap(\.lines) }
  }

  @Test("Orphans hides the untracked asset, says so in Details, and Not yet scanned holds only the never-scanned tracked project's")
  func orphanSurface() async throws {
    try await Self.withFixture { database in
      let app = try await start(database)
      let gallery = try #require(app.gallery)
      await showOrphans(gallery)
      let report = try #require(gallery.orphanReport)
      let split = ReportHeaderModel.splitOrphans(report, health: gallery.orphanHealth)
      #expect(Self.keys(split.scanned) == ["blog/asset-1.png", "x/asset-2.png"])
      // 6 is also in not-tracked social, which says nothing: notes, which
      // has never been scanned, decides.
      #expect(Self.keys(split.notYetScanned) == ["notes/asset-3.png", "notes/asset-6.png"])
      #expect(gallery.orphanHealth.map(\.slug) == ["blog", "notes"])
      let lines = orphanDetailLines(gallery)
      #expect(lines.contains("1 asset in not-tracked projects is not listed."))
      #expect(!lines.contains("Social: no usage scan has ever completed, so all of its assets may appear here."))
      #expect(lines.contains("Notes: no usage scan has ever completed, so all of its assets may appear here."))
    }
  }

  @Test("Scoped to the never-scanned tracked project, an asset also in a not-tracked project (outside the scope) still waits in Not yet scanned")
  func notYetScannedInScope() async throws {
    try await Self.withFixture { database in
      let app = try await start(database)
      let gallery = try #require(app.gallery)
      gallery.currentProjectSlug = "notes"
      await showOrphans(gallery)
      let report = try #require(gallery.orphanReport)
      // social is not in this scope's not-tracked projects, but 6 is in it.
      #expect(report.notTrackedProjects.isEmpty)
      #expect(report.projectSlugs[try #require(report.assets.last?.asset.id)] == ["notes", "social"])
      #expect(Self.keys(report.assets) == ["notes/asset-3.png", "notes/asset-6.png"])
      let split = ReportHeaderModel.splitOrphans(report, health: gallery.orphanHealth)
      #expect(Self.keys(split.scanned).isEmpty)
      #expect(Self.keys(split.notYetScanned) == ["notes/asset-3.png", "notes/asset-6.png"])
    }
  }

  @Test("Settings ▸ Projects' Usage picker writes meta.usageTracking, and Orphans re-reads through the app's own hook")
  func usagePicker() async throws {
    try await Self.withFixture { database in
      #expect(
        ProjectUsageTrackingSection.note == "Untracked images never count as orphans.")
      let app = try await start(database)
      let gallery = try #require(app.gallery)
      let settings = try #require(app.projectSettings)
      settings.load()
      let rows = try #require(settings.snapshot?.rows)
      // By name: Blog, Desk, Notes, Press, Social, Wire.
      #expect(rows.map(\.usageTracking) == [
        .tracked, .notTracked, .tracked, .notTracked, .notTracked, .notTracked,
      ])
      await showOrphans(gallery)
      #expect(gallery.orphanReport?.unscannedProjects == ["notes"])

      let notes = try #require(rows.first { $0.slug == "notes" })
      let editor = ProjectEditorView(row: notes, backendSlugs: ["r2"], model: settings)
      let picker = try #require(collectViews(editor, as: ProjectUsageTrackingSection.self).first)
      #expect(picker.selection.wrappedValue == .tracked)
      picker.selection.wrappedValue = .notTracked

      #expect(
        try CatalogConfiguration.projectSettings(slug: "notes", in: database).usageTracking
          == .notTracked)
      #expect(settings.snapshot?.rows.first { $0.slug == "notes" }?.usageTracking == .notTracked)
      await waitUntil { gallery.orphanReport?.unscannedProjects.isEmpty == true }
      #expect(gallery.orphanReport?.unscannedProjects == [])
      let report = try #require(gallery.orphanReport)
      #expect(
        Self.keys(report.untracked)
          == ["social/asset-0.png", "notes/asset-3.png", "notes/asset-6.png"])
      // 3, 4 and 5 this time.
      let counts: [Int] = [
        report.untracked.count, report.untrackedProjects.count, report.notTrackedProjects.count,
      ]
      #expect(counts == [3, 4, 5])
      #expect(orphanDetailLines(gallery).contains("3 assets in not-tracked projects are not listed."))
    }
  }

  @Test("The Usage page still shows a not-tracked project's scanned references")
  func usagePageShowsNotTracked() async throws {
    try await Self.withFixture { database in
      let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinax-social-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: source) }
      try "![](https://img.example.com/social/asset-0.png)\n".write(
        to: source.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)
      try CatalogConfiguration.setProjectSources(
        slug: "social", [ProjectSource(label: "posts", path: source.path)], in: database)
      let app = try await start(database)
      let gallery = try #require(app.gallery)
      #expect(gallery.sourcedProjects.contains("social"))
      gallery.onScanNow?(["social"])
      let usageSync = try #require(app.usageSync)
      await waitUntil { usageSync.result != nil && !usageSync.isSyncing }
      #expect(usageSync.result?.foundCount == 1)

      gallery.usagePage = .images
      gallery.select(.usage, in: SidebarModel.navigator(for: .usage))
      await gallery.reload()
      await waitUntil { !gallery.rows.isEmpty }
      #expect(Set(gallery.rows.map(\.item.asset.key)) == ["social/asset-0.png", "blog/asset-4.png", "blog/asset-5.png"])
    }
  }
}
