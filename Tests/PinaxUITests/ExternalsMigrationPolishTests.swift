import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Externals migration polish: the log's rows select and copy, the panel's sizes clamp, Changed Files for a
/// preview and an apply, Ready's Discard, and no Migrate N… in the toolbar.
@MainActor
@Suite(.serialized) struct ExternalsMigrationPolishTests {
  private typealias Stub = ExternalsMigrationTests.StubMigrator

  private struct StaticExternals: ExternalUsageReading {
    let rows: [ExternalReference]
    func externalReferences(project: String?) async throws -> ExternalReferenceSet {
      ExternalReferenceSet(references: rows, projectSources: [:])
    }
  }

  private func gallery(_ migrator: Stub?, database: DatabasePool? = nil) throws -> GalleryModel {
    let database = try database ?? makeUITestDatabase().0
    return GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-m4b-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }),
      externalReader: StaticExternals(rows: ExternalsMigrationTests.rows), externalsMigrator: migrator)
  }

  private func otherIDs(_ url: String, _ model: ExternalsModel) -> Set<ExternalReference.ID> {
    Set((model.items ?? []).filter { $0.rawURL == url && $0.domain == .other }.map(\.id))
  }

  /// A run with three events: started, one file planned, finished.
  private func logRun(_ database: DatabasePool) throws -> Int64 {
    let runID = try RunLog.start(
      kind: .rewrite, dryRun: false,
      params: RewriteRunParams(targets: [RewriteRunTarget(project: "blog", rules: [])]), in: database)
    try RunLog.append(.runStarted(RewriteRunParams(targets: [])), to: runID, in: database)
    try RunLog.append(
      .fileSkipped(FileSkippedEvent(project: "blog", source: "site", path: "a.md", reason: "changed_since_plan")),
      to: runID, in: database)
    try RunLog.append(.rescanFinished(RescanFinishedEvent(project: "blog", refs: 3, files: 2)), to: runID, in: database)
    try RunLog.finish(runID, state: .finished, summary: RewriteRunSummary(written: 1), in: database)
    return runID
  }

  // MARK: Selecting and copying log rows

  @Test("Log rows: click selects one, ⌘ adds and removes, ⇧ ranges; ⌘C copies `time  line` in order")
  func selectAndCopyEvents() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try logRun(database)
    let panel = ActivityPanelModel(reader: ReadOnlyCatalog(database: database))
    var copied: [String] = []
    panel.copy = { copied.append($0) }
    await panel.refresh()
    let seqs = panel.visibleEvents.map(\.seq)
    try #require(seqs.count == 3)

    panel.copySelectedLines()
    #expect(copied.isEmpty, "nothing selected copies nothing")

    panel.clickLine(seqs[2])
    panel.clickLine(seqs[0], toggling: true)
    #expect(panel.selectedLines == [seqs[0], seqs[2]])
    panel.copySelectedLines()
    let lines = panel.visibleEvents.map { "\(ActivityPanelModel.eventTime($0.at))  \($0.event.summaryLine)" }
    #expect(copied.last == [lines[0], lines[2]].joined(separator: "\n"), "view order, not click order")
    #expect(copied.last?.contains("  Skipped a.md") == false)

    panel.clickLine(seqs[0], toggling: true)
    #expect(panel.selectedLines == [seqs[2]])
    panel.clickLine(seqs[2], extending: true)
    #expect(panel.selectedLines == Set(seqs), "⇧ from the last clicked row (seqs[0])")
    panel.clickLine(seqs[1])
    #expect(panel.selectedLines == [seqs[1]], "a plain click selects just that row")

    // The row's Copy: the selection when the row is in it, else that row.
    panel.copyLines(from: seqs[1])
    #expect(copied.last == lines[1])
    panel.copyLines(from: seqs[0])
    #expect(copied.last == lines[0])
    #expect(panel.selectedLines == [seqs[1]])
  }

  @Test("Raw rows select and copy their JSONL lines; a new run clears the selection")
  func selectAndCopyRaw() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try logRun(database)
    let panel = ActivityPanelModel(reader: ReadOnlyCatalog(database: database))
    var copied: [String] = []
    panel.copy = { copied.append($0) }
    await panel.refresh()
    panel.logView = .raw
    let rows = panel.rawRows
    panel.clickLine(rows[0].seq)
    panel.clickLine(rows[1].seq, extending: true)
    panel.copySelectedLines()
    #expect(copied.last == rows[0].line + "\n" + rows[1].line)
    #expect(panel.selectedLineText == panel.rawLines.prefix(2).joined(separator: "\n"))

    let second = try logRun(database)
    await panel.refresh()
    panel.selectedRunID = second
    #expect(panel.selectedLines.isEmpty)
    #expect(first != second)
  }

  // MARK: Sizes

  @Test("The panel's height clamps to 160…60 % of the window; the run list keeps 180 and the log 280")
  func layoutClamps() {
    #expect(ActivityPanelModel.defaultHeight == 340)
    #expect(ActivityPanelModel.clampedHeight(340, windowHeight: 800) == 340)
    #expect(ActivityPanelModel.clampedHeight(100, windowHeight: 800) == 160)
    #expect(ActivityPanelModel.clampedHeight(700, windowHeight: 800) == 480)
    #expect(ActivityPanelModel.clampedHeight(340, windowHeight: 200) == 160, "a short window still gets the minimum")
    #expect(ActivityPanelModel.defaultRunListWidth == 240)
    #expect(ActivityPanelModel.clampedRunListWidth(100, panelWidth: 900) == 180)
    #expect(ActivityPanelModel.clampedRunListWidth(800, panelWidth: 900) == 620)
    #expect(ActivityPanelModel.clampedRunListWidth(300, panelWidth: 900) == 300)
    // Narrower than 180 + 280, the two share it 180 : 280.
    #expect(ActivityPanelModel.clampedRunListWidth(240, panelWidth: 338) == 132)
  }

  // MARK: Changed Files

  @Test("Changed Files: a preview lists its planned files with Show Changes…; an apply its changed ones; none greys")
  func changedFilesForPreviewAndApply() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let params = ExternalMigrationParams(
      targets: [ExternalMigrationTarget(project: "astro", urls: [ExternalsMigrationTests.imgurA])], backend: "r2")
    let preview = try RunLog.start(kind: .externalMigrate, dryRun: true, params: params, in: database)
    for path in ["posts/b.md", "posts/a.md", "posts/b.md"] {
      try RunLog.append(
        .filePlanned(
          FilePlannedEvent(project: "astro", source: "astro-blog", path: path, sha256: "x", edits: 1, editsDigest: "d")),
        to: preview, in: database)
    }
    try RunLog.finish(preview, state: .finished, summary: RewriteRunSummary(files: 2), in: database)
    let empty = try RunLog.start(kind: .externalMigrate, dryRun: true, params: params, in: database)
    try RunLog.finish(empty, state: .finished, summary: RewriteRunSummary(), in: database)
    var applied = RewriteRunSummary(files: 1, written: 1)
    applied.changedFilesByRepo = ["/repo": ["posts/a.md"]]
    let apply = try RunLog.start(kind: .externalMigrate, dryRun: false, params: params, in: database)
    try RunLog.finish(apply, state: .finished, summary: applied, in: database)

    let panel = ActivityPanelModel(reader: ReadOnlyCatalog(database: database))
    var diffed: [Int64] = []
    panel.diff = { diffed.append($0); return "--- a/posts/a.md\n" }
    await panel.refresh()

    panel.selectedRunID = preview
    await panel.refresh()
    #expect(panel.isPreviewSelected)
    #expect(panel.changedFiles.map(\.title) == ["astro · astro-blog"])
    #expect(panel.changedFiles.first?.paths == ["posts/b.md", "posts/a.md"], "event order, once each")
    #expect(panel.changedFileURLs.isEmpty, "planned paths are relative: no Reveal")
    #expect(panel.canShowChanges)
    panel.showsChangedFiles = true
    await panel.showChanges()
    #expect(diffed == [preview])
    #expect(panel.changesDiff == "--- a/posts/a.md\n")
    #expect(!panel.showsChangedFiles, "the popover gives way to the sheet")

    panel.selectedRunID = empty
    await panel.refresh()
    #expect(panel.changedFiles.isEmpty, "nothing planned: the button greys")
    #expect(!panel.canShowChanges)
    #expect(panel.changesDiff == nil, "another run drops the diff")

    panel.selectedRunID = apply
    await panel.refresh()
    #expect(!panel.isPreviewSelected)
    #expect(panel.changedFiles.map(\.root) == ["/repo"])
    #expect(panel.changedFileURLs.map(\.path) == ["/repo/posts/a.md"])
    #expect(!panel.canShowChanges, "Show Changes… is a preview's")
  }

  @Test("The gallery hands its migrator's diff to the panel; read-only has none")
  func galleryWiresPanelDiff() throws {
    #expect(try gallery(Stub()).activityPanel.diff != nil)
    #expect(try gallery(nil).activityPanel.diff == nil)
  }

  // MARK: Discard

  @Test("Ready's grey ✕ is Discard: the slot goes Idle and the preparation's downloads go")
  func discardReady() async throws {
    let stub = Stub()
    let gallery = try gallery(stub)
    let model = gallery.externals
    await model.load()
    model.domain = .other
    model.selection = otherIDs(ExternalsMigrationTests.imgurA, model)
    await model.migrateSelection()
    model.dismissMigrationSheet()
    #expect(gallery.activity.current?.phase == .ready)
    #expect(gallery.activity.current?.cancelHelp == "Discard")

    gallery.activity.cancelCurrent()
    #expect(stub.discarded == [7])
    #expect(model.migrationStatus == nil)
    #expect(model.migrationConfirmation == nil)
    #expect(gallery.activity.current == nil, "back to Idle")
    model.reviewMigration()
    #expect(!model.isMigrationSheetPresented, "nothing left to review")
  }

  @Test("The app's migrator deletes the run's download folder and keeps the run")
  func migratorDiscardKeepsRun() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheRoot = directory.appendingPathComponent("migrate-downloads", isDirectory: true)
    let runID = try RunLog.start(
      kind: .externalMigrate, dryRun: true,
      params: ExternalMigrationParams(targets: [], backend: "r2"), in: database)
    try RunLog.finish(runID, state: .finished, summary: RewriteRunSummary(), in: database)
    let runCache = cacheRoot.appendingPathComponent(String(runID), isDirectory: true)
    let other = cacheRoot.appendingPathComponent(String(runID + 1), isDirectory: true)
    for folder in [runCache, other] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("x".utf8).write(to: folder.appendingPathComponent("blob"))
    }
    CatalogExternalsMigrator(database: database, credentialsLoader: { _ in nil }, cacheRoot: cacheRoot)
      .discardPreparation(ofRun: runID)
    #expect(!FileManager.default.fileExists(atPath: runCache.path))
    #expect(FileManager.default.fileExists(atPath: other.path), "only this run's downloads")
    #expect(try RunLog.run(runID, in: database) != nil, "the run stays in the panel's list")
  }

  // MARK: Toolbar

  nonisolated private func pump(until date: Date) { RunLoop.main.run(until: date) }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pump(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  @Test("Selecting Other Domains rows adds no Migrate item and keeps the inspector toggle")
  func toolbarHasNoMigrate() async throws {
    let model = try gallery(Stub())
    await model.loadInitialData()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: GalleryView(model: model))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    model.select(.externals, in: .reports)
    await spin(0.8)
    // After the page's own load, which opens on Your Domains.
    model.externals.domain = .other
    await spin(0.5)
    let toolbar = try #require(window.toolbar)
    let before = toolbar.items.map(\.itemIdentifier.rawValue)
    #expect(toolbar.items.contains { $0.itemIdentifier == .toggleInspector })

    model.externals.selection = otherIDs(ExternalsMigrationTests.imgurA, model.externals)
    #expect(model.externals.selectionMigrationCount == 1)
    await spin(0.8)
    #expect(toolbar.items.map(\.itemIdentifier.rawValue) == before)
    #expect(!toolbar.items.contains { $0.label.contains("Migrate") || $0.paletteLabel.contains("Migrate") })
    #expect(toolbar.items.contains { $0.itemIdentifier == .toggleInspector })
  }
}
