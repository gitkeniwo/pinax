import AppKit
@testable import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Domains, model and AppKit layer: the one diff view,
/// the log's ⌘A and a run's Copy Log, the Switch help, the scan after a
/// Switch or an added Old domain (through the app's own wiring), one link
/// count everywhere, the Domain column's sort. No menu, popover, sheet or
/// modal is opened and nothing is clicked.
@MainActor @Suite(.serialized) struct DomainsDiffLogTests {
  private static let current = "https://img.example.com"
  private static let old = "https://pub-old.r2.dev"

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
  }

  /// `r2` with Old domain pub-old; `blog`'s a.md links to asset-0 on the
  /// Current, to gone.png (not in the catalog) on the Current, and to
  /// gone-too.png on pub-old. `blog` has a source; `notes` has none.
  private func withCatalog(_ body: (DatabasePool, URL) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try """
    ![a](https://img.example.com/blog/asset-0.png)
    ![b](HTTPS://IMG.Example.com/blog/gone.png)
    ![c](https://pub-old.r2.dev/blog/gone-too.png)

    """.write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: source.path)], in: database)
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    _ = try CatalogConfiguration.addOldDomain(Self.old, backendSlug: "r2", in: database)
    let scan = try UsageScanner.scan(project: "blog", in: database)
    _ = try CatalogUsage.sync(scan.document, project: "blog", in: database)
    try await body(database, directory)
  }

  // MARK: - Show Changes…

  @Test("Show Changes… is a read-only, selectable, unwrapped monospaced NSTextView that takes a long diff at once")
  func changesTextView() throws {
    let line = "+![s](https://img.gitkeniwo.dpdns.org/2024/some/long/path/screenshot \(String(repeating: "x", count: 120)).png)\n"
    let text = String(repeating: "--- a/site/post.md\n+++ b/site/post.md\n@@ -1,3 +1,3 @@\n" + line, count: 600)
    let started = Date()
    let host = NSHostingView(rootView: ReadOnlyTextView(text: text).frame(width: 600, height: 400))
    host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    host.layoutSubtreeIfNeeded()
    let textView = try #require(Self.firstTextView(in: host))
    #expect(Date().timeIntervalSince(started) < 1, "a 2,400-line diff is in view within a second")
    #expect(textView.string == text)
    #expect(!textView.isEditable && textView.isSelectable && !textView.isRichText)
    #expect(textView.font?.isFixedPitch == true)
    #expect(textView.textContainer?.widthTracksTextView == false, "lines do not wrap")
    #expect(textView.enclosingScrollView?.hasHorizontalScroller == true)
  }

  private static func firstTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
      if let found = firstTextView(in: subview) { return found }
    }
    return nil
  }

  // MARK: - The log

  @Test("⌘A selects every row the view shows, ⌘C copies them; a run row's Copy Log copies that run without selecting it")
  func logSelectAllAndRunCopyLog() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let params = RewriteRunParams(targets: [RewriteRunTarget(project: "blog", rules: [])])
    func run(dryRun: Bool) throws -> Int64 {
      let id = try RunLog.start(kind: .rewrite, dryRun: dryRun, params: params, in: database)
      _ = try RunLog.append(.runStarted(params), to: id, in: database)
      _ = try RunLog.append(.runFinished(RewriteRunSummary()), to: id, in: database)
      try RunLog.finish(id, state: .finished, summary: RewriteRunSummary(), in: database)
      return id
    }
    let first = try run(dryRun: true)
    let second = try run(dryRun: false)

    let model = ActivityPanelModel(reader: ReadOnlyCatalog(database: database))
    var copied: [String] = []
    model.copy = { copied.append($0) }
    model.selectedRunID = second
    await model.refresh()
    #expect(model.events.count >= 2)

    for view in ActivityLogView.allCases {
      model.logView = view
      model.clearLineSelection()
      model.selectAllLines()
      #expect(model.selectedLines == Set(model.events.map(\.seq)), "\(view)")
      model.copySelectedLines()
      #expect(copied.last == model.lineText(Set(model.events.map(\.seq))), "\(view): every row")
      #expect(copied.last?.components(separatedBy: "\n").count == model.events.count)
    }

    // The other run, as the bar's Copy Log would copy it once selected.
    model.logView = .events
    await model.copyLog(ofRun: first)
    #expect(model.selectedRunID == second, "the row is not selected")
    let copiedFirst = copied.last
    model.selectedRunID = first
    await model.refresh()
    #expect(copiedFirst == model.logText)
    #expect(copiedFirst?.isEmpty == false)
  }

  // MARK: - Switch's help

  @Test("Switch's help is two sentences, and the sheet keeps one short line")
  func switchHelp() {
    let help = BackendDomainsSection.switchHelp
    #expect(help.hasPrefix("Pinax only changes which domain it uses for new links."))
    #expect(help.components(separatedBy: ". ").count == 2)
    #expect(BackendDomainsSection.switchNote == "The current domain joins Old domains.")
  }

  // MARK: - Scan after Switch and Add Old Domain

  @Test("Switch and Add Old Domain scan the projects that upload to the backend, through the app's wiring; Remove does not")
  func scanAfterSwitchAndAdd() async throws {
    try await withCatalog { database, _ in
      let recorder = DomainScanRecorder()
      let app = PinaxAppModel(
        dockIcon: inertDockIcon,
        defaults: try #require(UserDefaults(suiteName: "pinaxui-d4a-\(UUID().uuidString)")),
        databaseOpener: { database }, usageSynchronizer: { _ in recorder }, chooseSourceFolder: { _ in nil })
      await app.start()
      let backends = try #require(app.backends)
      let usageSync = try #require(app.usageSync)
      await backends.load()
      await backends.select("r2")

      backends.beginSwitch()
      backends.updateSwitchDraft("https://img2.example.com")
      await backends.submitSwitch()
      #expect(backends.switchError == nil)
      await waitUntil { recorder.scans.count == 1 && !usageSync.isSyncing }
      #expect(recorder.scans == ["blog"], "blog uploads to r2 and has a source; notes has none")

      await backends.addOldDomain("https://legacy.example.com")
      #expect(backends.oldDomainError == nil)
      await waitUntil { recorder.scans.count == 2 && !usageSync.isSyncing }
      #expect(recorder.scans == ["blog", "blog"])

      await backends.removeOldDomain("https://legacy.example.com")
      #expect(backends.oldDomainError == nil)
      try await Task.sleep(for: .milliseconds(100))
      #expect(recorder.scans.count == 2, "a Remove does not scan")
    }
  }

  @Test("The targets are the projects with sources whose upload backend is the one changed")
  func scanTargets() {
    func row(_ slug: String, backend: String?, sourced: Bool) -> ProjectSettingsRow {
      ProjectSettingsRow(
        id: 1, slug: slug, name: slug, keyPrefix: "", backendSlug: backend,
        sources: sourced ? [ProjectSource(label: "s", path: "/tmp/x")] : [], lastScanAt: nil,
        referenceCount: 0, usageTracking: .tracked, keyTemplate: nil)
    }
    let one = ProjectSettingsSnapshot(
      rows: [row("blog", backend: nil, sourced: true), row("notes", backend: nil, sourced: false)],
      backendSlugs: ["r2"])
    #expect(one.scanTargets(uploadingTo: "r2") == ["blog"], "the one backend, inherited")
    let two = ProjectSettingsSnapshot(
      rows: [row("blog", backend: "r2", sourced: true), row("docs", backend: "b2", sourced: true),
             row("loose", backend: nil, sourced: true)],
      backendSlugs: ["b2", "r2"])
    #expect(two.scanTargets(uploadingTo: "r2") == ["blog"])
    #expect(two.scanTargets(uploadingTo: "b2") == ["docs"])
  }

  // MARK: - One count

  @Test("Settings, the move sheet's projects and Usage's menu count the same links, in the catalog or not")
  func oneCount() async throws {
    try await withCatalog { database, _ in
      let counts = try CatalogConfiguration.domainLinkCounts(backendSlug: "r2", in: database)
      #expect(counts.current.links == 2 && counts.old.map(\.links) == [1])

      let migrator = CatalogDomainMigrator(database: database)
      let sheet = try await migrator.projects(backend: "r2", prefixes: [Self.current, Self.old], includeResolved: true)
      #expect(sheet == [DomainMoveProject(slug: "blog", links: 3)])
      let flowB = try await migrator.projects(backend: "r2", prefixes: [Self.old], includeResolved: false)
      #expect(flowB == [DomainMoveProject(slug: "blog", links: 1)])

      let gallery = GalleryModel(
        catalog: ReadOnlyCatalog(database: database),
        thumbnails: ThumbnailCache(
          cacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pinaxui-d4a-\(UUID().uuidString)"),
          fetcher: { _ in throw URLError(.unsupportedURL) }),
        domainMigrator: migrator)
      await gallery.loadInitialData()
      gallery.select(.usage, in: .reports)
      await gallery.reload()
      #expect(gallery.usageDomainSections.first?.items.map(\.links) == [2, 1])

      // pub-old's one link is to an image not in the catalog: an empty
      // list, the sentence, and the move still offered.
      gallery.usageDomain = Self.old
      await waitUntil { gallery.usageBrowser?.domain == Self.old && !gallery.isLoadingPage }
      #expect(gallery.usageBrowser?.images.isEmpty == true)
      let item = try #require(gallery.usageDomainItem)
      #expect(!item.isUnused)
      #expect(UsageDomainEmptyView.notInCatalog(item.links) == "1 link points to an image not in the catalog.")
      #expect(UsageDomainEmptyView.notInCatalog(3) == "3 links point to images not in the catalog.")
      #expect(gallery.usageMoveTitle == "Move 1 Link to Current…")
    }
  }

  // MARK: - Domain column

  @Test("The Domain column sorts by the Domain field; the grid's menus leave it out")
  func domainColumnSort() {
    let comparator = AssetTableView.comparator(.domain)
    let field = AssetSort.Field.allCases.first { AssetTableView.comparator($0).keyPath == comparator.keyPath }
    #expect(field == .domain)
    #expect(AssetSort.Field.menuCases == [.uploadedAt, .name, .byteSize, .kind, .source])
  }
}

private final class DomainScanRecorder: UsageSyncing, @unchecked Sendable {
  private let lock = NSLock()
  private var _scans: [String] = []
  var scans: [String] { lock.withLock { _scans } }

  func projects() async throws -> [String] { ["blog", "notes"] }

  func sync(documentAt source: URL, project: String, allowEmpty: Bool) async throws -> UsageSyncResult {
    UsageSyncResult(scanID: 0, foundCount: 0)
  }

  func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome {
    lock.withLock { _scans.append(project) }
    return UsageScanOutcome(sync: UsageSyncResult(scanID: 0, foundCount: 0), files: 0, skipped: 0)
  }
}
