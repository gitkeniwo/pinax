import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// The Projects page's Sources group and the one Scan
/// Now. Every folder is under the test's temporary directory; the folder
/// chooser is a script and never opens a panel; no menu, popover, sheet or
/// modal is opened and nothing is clicked.
@MainActor
@Suite struct ScanNowTests {
  // MARK: - Property 1: Sources edits reach meta and read back

  @Test("+, field edits, Locate… and − write meta through the model, and a reopened catalog reads the same")
  func sourcesRoundTrip() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.path
    for folder in ["one/site", "two/site", "three/moved"] {
      try FileManager.default.createDirectory(
        atPath: root + "/" + folder, withIntermediateDirectories: true)
    }
    // A key the pane does not own, which every write must keep.
    try await database.write { db in
      try db.execute(sql: #"UPDATE project SET meta = '{"keep":1}' WHERE slug = 'blog'"#)
    }
    var chosen: [URL?] = [
      URL(fileURLWithPath: root + "/one/site"),
      URL(fileURLWithPath: root + "/two/site"),
      nil,
      URL(fileURLWithPath: root + "/three/moved"),
    ]
    var asked: [String?] = []
    let model = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: database),
      chooseFolder: { start in
        asked.append(start)
        return chosen.removeFirst()
      })
    model.load()

    model.addSource(toProject: "blog")
    model.addSource(toProject: "blog")
    model.addSource(toProject: "blog")  // chooser cancelled: nothing written
    #expect(model.saveError == nil)
    #expect(
      try meta(database, "blog")
        == #"{"keep":1,"sources":[{"exclude":[],"include":[],"label":"site","path":"\#(root)/one/site"},{"exclude":[],"include":[],"label":"site-2","path":"\#(root)/two/site"}]}"#
    )

    model.updateSource(
      label: "site-2", inProject: "blog", newLabel: "docs",
      include: " src/**/*.md ,, *.astro", exclude: "drafts/**")
    // The default include, typed back as shown, stores as empty.
    model.updateSource(
      label: "site", inProject: "blog", newLabel: "site",
      include: ProjectSource.defaultInclude.joined(separator: ", "), exclude: "")
    model.locateSource(label: "docs", inProject: "blog")
    #expect(asked == [nil, nil, nil, "\(root)/two/site"], "Locate… starts at the old path")
    model.removeSource(label: "site", fromProject: "blog")
    #expect(model.saveError == nil)

    let expected = [
      ProjectSource(
        label: "docs", path: "\(root)/three/moved", include: ["src/**/*.md", "*.astro"],
        exclude: ["drafts/**"])
    ]
    let stored = try #require(try meta(database, "blog"))
    #expect(ProjectSettings(meta: stored).sources == expected)
    let object = try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any]
    #expect(object?["keep"] as? Int == 1, "the unrelated key survives every write")
    #expect(model.snapshot?.rows.first { $0.slug == "blog" }?.sources == expected)

    // Reopened: a new pool on the same file, a new model.
    let reopened = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    let again = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: reopened), chooseFolder: { _ in nil })
    again.load()
    #expect(again.snapshot?.rows.first { $0.slug == "blog" }?.sources == expected)
    #expect(again.snapshot?.rows.first { $0.slug == "notes" }?.sources == [])
  }

  @Test("Setting a source's fields as the editor shows them keeps the commas inside braces")
  func shownFieldsRoundTrip() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let custom = ["content/**/*.{md,mdx}", "{pages,layouts}/*.astro"]
    let excluded = ["**/*.{test,spec}.tsx", "drafts/**"]
    try CatalogConfiguration.setProjectSources(
      slug: "blog",
      [
        ProjectSource(label: "plain", path: directory.path),
        ProjectSource(label: "custom", path: directory.path, include: custom, exclude: excluded),
      ], in: database)
    let model = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: database), chooseFolder: { _ in nil })
    model.load()

    // Only the label changes; the other fields hold what the editor fills in.
    for source in try #require(model.snapshot?.rows.first { $0.slug == "blog" }).sources {
      model.updateSource(
        label: source.label, inProject: "blog", newLabel: source.label + "-renamed",
        include: source.effectiveInclude.joined(separator: ", "),
        exclude: source.exclude.joined(separator: ", "))
    }

    #expect(model.saveError == nil)
    #expect(
      try CatalogConfiguration.projectSettings(slug: "blog", in: database).sources == [
        ProjectSource(label: "plain-renamed", path: directory.path),
        ProjectSource(
          label: "custom-renamed", path: directory.path, include: custom, exclude: excluded),
      ])
    // As in the glob matcher, a `{` that is never closed is a literal.
    #expect(ProjectSettingsModel.patterns("a{, b ,") == ["a{", "b"])
  }

  // MARK: - Property 2: every Scan Now entry reaches the one method

  @Test("The Projects page and both reports' empty states and the Usage header each reach scanNow once, through the app's own closures")
  func everyEntryReachesScanNow() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      atPath: directory.path + "/blog-src", withIntermediateDirectories: true)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "src", path: directory.path + "/blog-src")],
      in: database)
    // An asset in blog and no scan anywhere: Orphans shows Usage Unknown.
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    let recorder = RecordingSynchronizer()
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try makeDefaults(), databaseOpener: { database },
      usageSynchronizer: { _ in recorder }, chooseSourceFolder: { _ in nil })
    await app.start()
    let gallery = try #require(app.gallery)
    let usageSync = try #require(app.usageSync)

    // Projects page: the pane as the Settings window builds it.
    // One Scan Now, met once per settings card container the page sits in (stored and
    // in its body); the recorder below counts the scan it starts.
    let projectsPane = scanNowActions(in: ProjectsSettingsPane(app: app))
    #expect(!projectsPane.isEmpty)
    projectsPane.first?()
    await waitUntil { recorder.scans.count == 1 && !usageSync.isSyncing }
    #expect(usageSync.emptyScanPresenter == .settings)

    // Usage report, No Completed Scan.
    gallery.currentProjectSlug = "blog"
    await load(gallery, .usage) { gallery.usageBrowser?.usage.projectSources.keys.first == "blog" }
    #expect(gallery.usageBrowser?.usage.scannedProjects.isEmpty == true)
    let usage = scanNowActions(in: UsageView(model: gallery))
    #expect(usage.count == 1)
    usage.first?()
    await waitUntil { recorder.scans.count == 2 && !usageSync.isSyncing }
    #expect(usageSync.emptyScanPresenter == .gallery)

    // Orphans, Usage Unknown.
    await load(gallery, .orphans) { gallery.orphanReport != nil }
    let orphans = scanNowActions(in: OrphanView(model: gallery))
    #expect(orphans.count == 1)
    orphans.first?()
    await waitUntil { recorder.scans.count == 3 && !usageSync.isSyncing }

    // Project ▸ Scan Now, the menu item as PinaxCommands builds it,
    // with blog current.
    let commands = PinaxCommands(app: app)
    commands.projectItems.current = "blog"
    await waitUntil { gallery.currentProjectSlug == "blog" }
    let menu = commands.projectItems
    #expect(menu.scanTitle == "Scan Now")
    #expect(menu.canScan)
    menu.scanNow()
    await waitUntil { recorder.scans.count == 4 && !usageSync.isSyncing }
    #expect(usageSync.emptyScanPresenter == .gallery)

    // The Usage header's icon Scan Now, standing once blog has live
    // references (the empty state, and its button, are gone).
    try seedLiveUsage(database, projectSlug: "blog", sha256: String(format: "%064x", 1), count: 1)
    await load(gallery, .usage) { gallery.usageBrowser?.usage.references.count == 1 }
    let header = scanNowActions(in: UsageView(model: gallery))
    #expect(header.count == 1)
    header.first?()
    await waitUntil { recorder.scans.count == 5 && !usageSync.isSyncing }
    #expect(usageSync.emptyScanPresenter == .gallery)

    #expect(recorder.scans == ["blog", "blog", "blog", "blog", "blog"])
    #expect(recorder.documentSyncs == 0)
  }

  @Test("Without sources the reports offer Add Source…, which turns Settings to Projects with the project selected")
  func addSourceOpensProjects() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = RecordingSynchronizer()
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try makeDefaults(), databaseOpener: { database },
      usageSynchronizer: { _ in recorder }, chooseSourceFolder: { _ in nil })
    await app.start()
    let gallery = try #require(app.gallery)
    let settings = try #require(app.projectSettings)

    gallery.currentProjectSlug = "notes"
    await load(gallery, .usage) { gallery.usageBrowser?.usage.projectSources.keys.first == "notes" }
    let usage = UsageView(model: gallery)
    #expect(scanNowActions(in: usage).isEmpty)
    let links = settingsLinks(in: usage)
    #expect(links.map(\.title) == ["Add Source…"])
    #expect(app.settingsTab == .general)
    links.first?.action()
    #expect(app.settingsTab == .projects)
    #expect(settings.requestedSlug == "notes")
    #expect(recorder.scans.isEmpty)
    #expect(
      EmptyStates.text(for: .noCompletedScan(project: "Notes", hasSources: false)).description
        == "Add a source folder for Notes to scan it.")
  }

  // MARK: - A source added in Settings turns the report's button

  @Test("Adding a source in Settings turns Add Source… into Scan Now in the open report, and removing it turns it back")
  func sourcesChangeTurnsTheReportButton() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = directory.appendingPathComponent("blog-src", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    let recorder = RecordingSynchronizer()
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try makeDefaults(), databaseOpener: { database },
      usageSynchronizer: { _ in recorder }, chooseSourceFolder: { _ in folder })
    await app.start()
    let gallery = try #require(app.gallery)
    let settings = try #require(app.projectSettings)
    settings.load()  // what the Projects page's .task does when it opens

    // The main window shows Usage and Orphans for blog, which has no source.
    gallery.currentProjectSlug = "blog"
    await load(gallery, .usage) { gallery.usageBrowser?.usage.projectSources.keys.first == "blog" }
    func usageButtons() -> (scan: Int, links: [String]) {
      let view = UsageView(model: gallery)
      return (scanNowActions(in: view).count, settingsLinks(in: view).map(\.title))
    }
    #expect(usageButtons().scan == 0)
    #expect(usageButtons().links == ["Add Source…"])

    // Settings ▸ Projects ▸ +, through the model the app installed. The
    // report is not reloaded; only the app's own callback can tell it.
    settings.addSource(toProject: "blog")
    #expect(settings.saveError == nil)
    await waitUntil { gallery.sourcedProjects.contains("blog") }
    #expect(usageButtons().scan == 1)
    #expect(usageButtons().links == [])

    // − removes the only source: back to Add Source….
    settings.removeSource(label: "blog-src", fromProject: "blog")
    await waitUntil { !gallery.sourcedProjects.contains("blog") }
    #expect(usageButtons().scan == 0)
    #expect(usageButtons().links == ["Add Source…"])

    // Orphans' Usage Unknown follows the same value.
    settings.addSource(toProject: "blog")
    await load(gallery, .orphans) { gallery.orphanReport != nil }
    #expect(scanNowActions(in: OrphanView(model: gallery)).count == 1)
    settings.removeSource(label: "blog-src", fromProject: "blog")
    await waitUntil { !gallery.sourcedProjects.contains("blog") }
    #expect(scanNowActions(in: OrphanView(model: gallery)).isEmpty)
    #expect(settingsLinks(in: OrphanView(model: gallery)).map(\.title) == ["Add Source…"])
    #expect(recorder.scans.isEmpty)
  }

  // MARK: - Property 3: Orphans gets the new scan without a restart

  @Test("After Scan Now, the Orphans model shows the new scans' result in the same app")
  func orphansRefreshAfterScan() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("blog-src", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    // asset-0 is referenced, asset-1 is not.
    try "![a](https://img.example.com/blog/asset-0.png)\n".write(
      to: source.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "src", path: source.path)], in: database)
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-03T00:00:00Z")
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try makeDefaults(), databaseOpener: { database },
      chooseSourceFolder: { _ in nil })
    await app.start()
    let gallery = try #require(app.gallery)
    let usageSync = try #require(app.usageSync)

    await load(gallery, .orphans) { gallery.orphanReport != nil }
    #expect(
      ReportHeaderModel.compose(
        orphanCandidates: gallery.orphanReport?.assets.count, health: gallery.orphanHealth,
        projects: gallery.projects
      ).content == .usageUnknown(projectNames: ["Blog"]))

    // Two scans: orphans need two completed scans to count a project.
    for expected in 1...2 {
      gallery.onScanNow?(["blog"])
      await waitUntil { usageSync.result?.scanID == Int64(expected) && !usageSync.isSyncing }
      #expect(usageSync.result?.foundCount == 1, "scan \(expected)")
    }
    await waitUntil { gallery.orphanReport?.unscannedProjects.contains("blog") == false }
    #expect(gallery.orphanReport?.assets.map(\.asset.key) == ["blog/asset-1.png"])
    #expect(gallery.orphanReport?.unscannedProjects == ["notes"], "notes has no sources")
    #expect(gallery.usageScanActivity == .finished(project: "blog", references: 1))
  }

  // MARK: - Property 4: a missing folder's row

  @Test("A source whose folder is gone shows Locate… in its row; a present one does not")
  func missingFolderShowsLocate() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      atPath: directory.path + "/here", withIntermediateDirectories: true)
    let model = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: database), chooseFolder: { _ in nil })
    let present = ProjectSource(label: "here", path: directory.path + "/here")
    let gone = ProjectSource(label: "gone", path: directory.path + "/gone")
    try CatalogConfiguration.setProjectSources(slug: "blog", [present], in: database)
    try CatalogConfiguration.setProjectSources(slug: "notes", [present, gone], in: database)
    model.load()
    let rows = try #require(model.snapshot?.rows)

    #expect(try await locateButtons(model, try #require(rows.first { $0.slug == "blog" })) == 0)
    #expect(try await locateButtons(model, try #require(rows.first { $0.slug == "notes" })) == 1)
    #expect(ProjectSettingsModel.scanStatus(for: rows[0]) == "Never scanned")
  }

  @Test("The status line's words")
  func scanStatusWords() {
    let row = ProjectSettingsRow(
      id: 1, slug: "astro", name: "Astro", keyPrefix: "", backendSlug: nil,
      lastScanAt: "2026-10-01T09:00:00Z", referenceCount: 312)
    let now = ISO8601DateFormatter().date(from: "2026-10-03T09:00:00Z")!
    #expect(
      ProjectSettingsModel.scanStatus(for: row, now: now, locale: Locale(identifier: "en_US"))
        == "Last scan 2 days ago · 312 references")
    #expect(UsageScanActivity.running(project: "astro", files: 120).text == "Scanning astro… 120 files")
  }

  // MARK: - Helpers

  private func meta(_ database: DatabasePool, _ slug: String) throws -> String? {
    try database.read { db in
      try String.fetchOne(db, sql: "SELECT meta FROM project WHERE slug = ?", arguments: [slug])
    }
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-scan-now-\(UUID().uuidString)"))
  }

  private func load(
    _ gallery: GalleryModel, _ selection: GalleryModel.SidebarSelection,
    until loaded: () -> Bool
  ) async {
    gallery.select(selection, in: SidebarModel.navigator(for: selection))
    await gallery.reload()
    let deadline = Date().addingTimeInterval(5)
    while !loaded(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// The Scan Now buttons a view builds, as the closures they carry. The
  /// walk reads stored values with Mirror and, for PinaxUI's own views,
  /// their `body`; nothing is rendered or clicked.
  private func scanNowActions(in view: some View) -> [() -> Void] {
    collectViews(view, as: ScanNowButton.self).map(\.action)
  }

  private func settingsLinks(in view: some View) -> [ProjectSettingsLinkButton] {
    collectViews(view, as: ProjectSettingsLinkButton.self)
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  /// The Locate… buttons a hosted Sources group draws for `row`: its
  /// buttons, less the same group's for a row whose folders are all there
  /// (+, −, Scan Now are in both).
  private func locateButtons(_ model: ProjectSettingsModel, _ row: ProjectSettingsRow) async throws
    -> Int
  {
    let present = ProjectSettingsRow(
      id: row.id, slug: row.slug, name: row.name, keyPrefix: row.keyPrefix,
      backendSlug: row.backendSlug,
      sources: row.sources.filter { ProjectSettingsModel.folderExists($0.path) })
    let drawn = try await buttons(model, row)
    let base = try await buttons(model, present)
    // The cells say the same thing without hosting.
    let cells = row.sources.map {
      SourcePathCell(source: $0, exists: ProjectSettingsModel.folderExists($0.path), locate: {})
    }
    #expect(cells.filter(\.showsLocate).count == drawn - base)
    return drawn - base
  }

  private func buttons(_ model: ProjectSettingsModel, _ row: ProjectSettingsRow) async throws -> Int {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: DesignMetrics.settings.detailWidth, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    let controller = NSHostingController(
      rootView: ProjectSourcesSection(row: row, model: model, isScanning: false))
    controller.sizingOptions = []
    window.contentViewController = controller
    window.setContentSize(NSSize(width: DesignMetrics.settings.detailWidth, height: 500))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    // SwiftUI's buttons draw as untitled AppKit buttons.
    func count(in view: NSView) -> Int {
      view.subviews.reduce(view is NSButton ? 1 : 0) { $0 + count(in: $1) }
    }
    return count(in: try #require(window.contentView))
  }
}

/// Records every scan and document sync; writes nothing.
private final class RecordingSynchronizer: UsageSyncing, @unchecked Sendable {
  private let lock = NSLock()
  private var _scans: [String] = []
  private var _documentSyncs = 0

  var scans: [String] { lock.withLock { _scans } }
  var documentSyncs: Int { lock.withLock { _documentSyncs } }

  func projects() async throws -> [String] { ["blog", "notes"] }

  func sync(documentAt source: URL, project: String, allowEmpty: Bool) async throws
    -> UsageSyncResult
  {
    lock.withLock { _documentSyncs += 1 }
    return UsageSyncResult(scanID: 0, foundCount: 0)
  }

  func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome {
    lock.withLock { _scans.append(project) }
    return UsageScanOutcome(sync: UsageSyncResult(scanID: 0, foundCount: 0), files: 0, skipped: 0)
  }
}
