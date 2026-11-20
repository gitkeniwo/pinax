import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

@testable import pinax

/// Model layer of the status bar's activity slot
/// and the activity panel. Runs are written with `RunLog` into a temporary
/// catalog; the panel reads them through `ReadOnlyCatalog`, as the app does.
@MainActor
@Suite(.serialized) struct ActivityPanelTests {
  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-activity-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  /// Local noon today: "Today" and "Yesterday" hold whatever the clock says.
  private var noon: Date {
    Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
  }

  private func migrationParams(_ project: String) -> ExternalMigrationParams {
    ExternalMigrationParams(targets: [ExternalMigrationTarget(project: project, urls: [])], backend: "r2")
  }

  // MARK: Slot

  @Test("The slot shows the newest activity, +N for the others running, a result until the next one")
  func slotNewestBadgeAndResult() {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let center = ActivityCenter(now: { clock })
    center.report(.running("Downloading 1 of 3"), from: .download)
    #expect(center.current?.text == "Downloading 1 of 3")
    #expect(center.badge == nil)

    center.report(.running("Scanning astro… 3 files"), from: .scan)
    #expect(center.current?.text == "Scanning astro… 3 files")
    #expect(center.badge?.text == "+1")
    #expect(center.badge?.help == "Download")

    // Progress on the older one does not take the slot back.
    center.report(.running("Downloading 2 of 3"), from: .download)
    #expect(center.current?.text == "Scanning astro… 3 files")

    // Finished, the newest still holds the slot; the download is still +1.
    center.report(ActivityItem(text: "Scanned astro: 9 references", phase: .finished), from: .scan)
    #expect(center.current?.text == "Scanned astro: 9 references")
    #expect(center.badge?.text == "+1")
    center.report(nil, from: .download)
    #expect(center.badge == nil)

    // Idle: the result with its age, a minute at a time.
    clock += 125
    #expect(center.displayText(now: clock) == "Scanned astro: 9 references · 2 min ago")
    #expect(ActivityCenter.age(since: clock, now: clock + 20) == "just now")
    #expect(ActivityCenter.age(since: clock, now: clock + 3 * 3600) == "3 hr ago")

    // A failure that merely appears does not clear it…
    center.report(ActivityItem(text: "Couldn’t open a.png", phase: .failed), from: .quickLook)
    #expect(center.current?.text == "Couldn’t open a.png")
    center.report(nil, from: .quickLook)
    #expect(center.current?.text == "Scanned astro: 9 references")

    // …the next activity does, even one that ends with no sentence.
    center.report(.running("Uploading a.png…"), from: .upload)
    #expect(center.current?.text == "Uploading a.png…")
    #expect(center.badge == nil, "a result is not counted in +N")
    center.report(nil, from: .upload)
    #expect(center.current == nil)
  }

  @Test("Every state carries its own glyph's button; the gallery's sources feed the slot")
  func statesAndSources() async throws {
    #expect(ActivityItem.running("x", fraction: 0.5, cancel: "Cancel").shownLink == nil)
    #expect(ActivityItem(text: "Migrated 49 links", phase: .finished).shownLink == nil)
    #expect(ActivityItem(text: "Ready to migrate 49 links", phase: .ready).shownLink == .review)
    #expect(ActivityItem(text: "w", phase: .warnings, runID: 3).shownLink == .changedFiles)
    #expect(ActivityItem(text: "w", phase: .warnings).shownLink == nil)
    #expect(ActivityItem(text: "s", phase: .failed, runID: 3).shownLink == .showLog)
    #expect(ActivityItem(text: "s", phase: .failed).shownLink == nil)
    #expect(
      [ActivityLink.review, .changedFiles, .showLog].map(\.title) == ["Review…", "Changed Files", "Show Log"])

    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(database)

    // The app's wiring, not a copy: the gallery's own published state.
    model.uploadProgress = "Uploading a.png…"
    #expect(GalleryStatusBar(model: model).activityText == "Uploading a.png…")
    model.externals.previewActivity = ExternalPreviewActivity(completed: 2, total: 4, host: "i.imgur.com")
    #expect(GalleryStatusBar(model: model).activityText == "Loading previews 2 of 4 · i.imgur.com")
    #expect(model.activity.current?.phase == .running(fraction: 0.5, cancel: "Stop loading"))
    #expect(model.activity.badge?.help == "Upload")

    // The grey ✕ is the page's own stop: nothing in flight, so the batch
    // ends at once and the slot shows its result.
    model.activity.cancelCurrent()
    #expect(model.externals.previewActivity?.isFinished == true)
    #expect(model.activity.current?.phase == .finished)

    model.usageScanActivity = .failed("Couldn’t read astro")
    #expect(model.activity.current?.phase == .failed)
    #expect(model.activity.current?.shownLink == nil, "no run, no Show Log")

    // Show Log opens this window's panel on the run.
    let runID = try RunLog.start(kind: .externalMigrate, dryRun: false, params: migrationParams("astro"), in: database)
    model.activity.report(
      ActivityItem(text: "Stopped at 18 of 47", phase: .failed, runID: runID), from: .migration)
    #expect(!model.isActivityPanelOpen)
    model.activity.perform(.showLog)
    #expect(model.isActivityPanelOpen)
    #expect(model.activityPanel.isOpen)
    #expect(model.activityPanel.selectedRunID == runID)
    model.toggleActivityPanel()
    #expect(!model.activityPanel.isOpen)
    #expect(PinaxCommands.activityPanelTitle(isOpen: false) == "Show Activity Panel")
    #expect(PinaxCommands.activityPanelTitle(isOpen: true) == "Hide Activity Panel")
  }

  // MARK: Run list

  @Test("Runs are named from kind and project and grouped Today, Yesterday, then by date")
  func runNamesAndGroups() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let noon = noon
    let summary = RewriteRunSummary()
    let domain = RewriteRunParams(
      targets: [],
      domain: DomainMigrationParams(
        backend: "r2", from: "https://a.example", to: "https://b.example", oldDomains: [], keepOldDomains: false))
    let moved = try RunLog.start(
      kind: .domainMigrate, dryRun: false, params: domain, in: database, now: noon - 3 * 86_400)
    try RunLog.finish(moved, state: .finished, summary: summary, in: database)
    let rewrite = try RunLog.start(
      kind: .rewrite, dryRun: true,
      params: RewriteRunParams(targets: [RewriteRunTarget(project: "blog", rules: [])]), in: database,
      now: noon - 86_400)
    try RunLog.finish(rewrite, state: .finished, summary: summary, in: database)
    let cancelled = try RunLog.start(
      kind: .externalMigrate, dryRun: true, params: migrationParams("astro"), in: database, now: noon - 600)
    try RunLog.finish(cancelled, state: .cancelled, summary: summary, in: database)
    let live = try RunLog.start(
      kind: .externalMigrate, dryRun: false, params: migrationParams("astro"), in: database, now: noon - 60)

    let runs = try RunLog.listedRuns(in: database, processExists: { _ in false })
    let groups = ActivityPanelModel.groups(runs, now: noon)
    #expect(groups.map(\.title) == ["Today", "Yesterday", ActivityPanelModel.format(noon - 3 * 86_400, "d MMM")])
    #expect(
      groups.flatMap(\.rows).map(\.name)
        == ["Migrate · astro", "Migrate · astro · cancelled", "Rewrite · blog · preview", "Domain move · r2"])
    // No dash; the action word apart from the rest.
    #expect(groups.flatMap(\.rows).map(\.name).allSatisfy { !$0.contains("—") })
    #expect(groups[0].rows[1].action == "Migrate")
    #expect(groups[0].rows[1].subject == "astro · cancelled")
    #expect(groups.first?.rows.first?.time == "11:59")
    // A run whose process is gone reads as interrupted, without writing:
    // the table still says running.
    #expect(runs.first?.state == .interrupted)
    #expect(try RunLog.run(live, in: database, processExists: { _ in true })?.state == .running)
  }

  // MARK: Log

  @Test("Warnings only, Filter, and Raw word for word as `runs show --format jsonl`")
  func logFiltersAndRaw() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runID = try RunLog.start(
      kind: .rewrite, dryRun: false,
      params: RewriteRunParams(targets: [RewriteRunTarget(project: "blog", rules: [])]), in: database)
    try RunLog.append(.runStarted(RewriteRunParams(targets: [])), to: runID, in: database)
    try RunLog.append(
      .fileSkipped(FileSkippedEvent(project: "blog", source: "site", path: "a.md", reason: "changed_since_plan")),
      to: runID, in: database)
    try RunLog.append(.rescanFinished(RescanFinishedEvent(project: "blog", refs: 3, files: 2)), to: runID, in: database)
    try RunLog.finish(runID, state: .finished, summary: RewriteRunSummary(written: 1), in: database)

    let panel = ActivityPanelModel(reader: ReadOnlyCatalog(database: database))
    var copied: [String] = []
    panel.copy = { copied.append($0) }
    await panel.refresh()
    #expect(panel.selectedRunID == runID, "the newest run is selected")
    #expect(panel.events.count == 3)

    panel.logView = .raw
    let jsonl = try #require(try Pinax.parseAsRoot(["runs", "show", String(runID), "--format", "jsonl"]) as? RunsShowCommand)
      .perform(in: database).stdout
    #expect(panel.logText == jsonl)
    panel.copyLog()
    #expect(copied == [jsonl])

    panel.logView = .events
    panel.warningsOnly = true
    #expect(panel.visibleEvents.map(\.event.type) == ["file_skipped"])
    #expect(panel.logText == "Skipped a.md — changed since the preview")
    panel.warningsOnly = false
    panel.filter = "rescanned"
    #expect(panel.visibleEvents.map(\.event.type) == ["rescan_finished"])
    panel.logView = .raw
    panel.filter = "file_skipped"
    #expect(panel.rawLines.count == 1)
    #expect(panel.rawLines.first?.contains("\"a.md\"") == true)
  }

  @Test("The header's counts and the changed files come from the run's summary")
  func talliesAndChangedFiles() async throws {
    var migration = ExternalMigrationSummary()
    migration.uploaded = .init(images: 47, links: 47)
    migration.reused = .init(images: 2, links: 2)
    migration.skipped = .init(images: 1, links: 1)
    var migrated = RewriteRunSummary(files: 21, written: 21)
    migrated.migration = migration
    #expect(
      ActivityPanelModel.tallies(kind: .externalMigrate, summary: migrated)
        == [.init(kind: .uploaded, count: 47), .init(kind: .reused, count: 2),
          .init(kind: .skipped, count: 1), .init(kind: .filesChanged, count: 21)])
    let rewritten = RewriteRunSummary(
      files: 4, written: 3, skippedFiles: ["changed_since_plan": 1], failed: 0)
    #expect(
      ActivityPanelModel.tallies(kind: .rewrite, summary: rewritten)
        == [.init(kind: .filesChanged, count: 3), .init(kind: .skipped, count: 1), .init(kind: .failed, count: 0)])

    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    var changed = rewritten
    changed.changedFilesByRepo = ["/repo": ["b.md", "a.md"], RewriteRunSummary.notInGitKey: ["x.md"]]
    let runID = try RunLog.start(kind: .rewrite, dryRun: false, params: RewriteRunParams(targets: []), in: database)
    try RunLog.finish(runID, state: .finished, summary: changed, in: database)
    let panel = ActivityPanelModel(reader: ReadOnlyCatalog(database: database))
    var revealed: [URL] = []
    panel.reveal = { revealed = $0 }
    await panel.refresh()
    #expect(panel.tallies.first == .init(kind: .filesChanged, count: 3))
    #expect(panel.groups.first?.rows.first?.hasWarnings == true, "a skipped file is the orange !")
    #expect(panel.changedFiles.map(\.root) == ["/repo", nil])
    panel.revealChangedFiles()
    #expect(revealed.map(\.path) == ["/repo/a.md", "/repo/b.md"])
  }

  // MARK: Polling

  final class CountingReader: RunLogReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func runs(limit: Int) async throws -> [RunRecord] {
      lock.withLock { _calls += 1 }
      return []
    }

    func runEvents(of runID: Int64, after seq: Int) async throws -> [RunEventRecord] { [] }
  }

  private func wait(_ seconds: Double) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
  }

  @Test("The panel polls only while it is open")
  func pollsOnlyWhileOpen() async throws {
    let reader = CountingReader()
    let panel = ActivityPanelModel(reader: reader, pollInterval: .milliseconds(10))
    await wait(0.1)
    #expect(reader.calls == 0)

    panel.setOpen(true)
    let deadline = Date().addingTimeInterval(5)
    while reader.calls < 3, Date() < deadline { await wait(0.01) }
    #expect(reader.calls >= 3)

    panel.setOpen(false)
    await wait(0.05)
    let settled = reader.calls
    await wait(0.15)
    #expect(reader.calls == settled)

    // The window's switch is what opens and closes it.
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(database)
    #expect(!model.activityPanel.isOpen)
    model.toggleActivityPanel()
    #expect(model.activityPanel.isOpen)
    model.toggleActivityPanel()
    #expect(!model.activityPanel.isOpen)
  }
}
