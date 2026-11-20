@testable import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// The Domains list, flows A–D, the one lock, the
/// sheet and the activity bar, Usage's domain menu, the Catalog roots and
/// Links use. The checks run through a stub `DomainMigrating`; nothing
/// reaches the network. Every expected value is written out by hand.
@MainActor @Suite struct DomainsTests {
  // MARK: - Fixtures

  /// A gate a stubbed check waits on, so a test can look at it mid-way.
  final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.withLock { opened } }
    func open() { lock.withLock { opened = true } }
  }

  final class StubMigrator: DomainMigrating, @unchecked Sendable {
    struct Preview: Equatable {
      let backend: String
      let to: String
      let from: [String]
      let projects: [String]
      let keepOldDomains: Bool
    }

    private let lock = NSLock()
    private var _previews: [Preview] = []
    private var _applied: [(Int64, Set<String>)] = []
    var previews: [Preview] { lock.withLock { _previews } }
    var applied: [(Int64, Set<String>)] { lock.withLock { _applied } }

    var projectList: [DomainMoveProject] = [
      DomainMoveProject(slug: "blog", links: 3), DomainMoveProject(slug: "notes", links: 1),
    ]
    var review: DomainMigrationReview = DomainsTests.review()
    var gate: Gate?
    var progress: [RewritePreviewProgress] = [
      .init(phase: .plan, done: 0, total: 2), .init(phase: .plan, done: 1, total: 2),
      .init(phase: .check, done: 1, total: 4), .init(phase: .check, done: 4, total: 4),
    ]
    var phases: [RewriteApplyPhase] = [.changingPrefix, .rewriting(files: 2), .rescanning(project: "blog")]
    var applyError: Error?
    var written = 2
    var diffText = "--- a/posts/a.md\n"

    func projects(backend: String, prefixes: [String], includeResolved: Bool) async throws -> [DomainMoveProject] {
      projectList
    }

    func preview(
      backend: String, to: String, from: [String], projects: [String], keepOldDomains: Bool,
      cancellation: ExternalMigrationCancellation,
      progress report: @escaping @Sendable (RewritePreviewProgress) -> Void
    ) async throws -> RewritePreviewResult {
      lock.withLock {
        _previews.append(Preview(backend: backend, to: to, from: from, projects: projects, keepOldDomains: keepOldDomains))
      }
      for step in progress { report(step) }
      if let gate {
        while !gate.isOpen && !cancellation.isCancelled { try await Task.sleep(for: .milliseconds(2)) }
      }
      var result = RewritePreviewResult(
        runID: review.runID, plans: [], verifications: [:], events: [], summary: RewriteRunSummary())
      if cancellation.isCancelled { result.state = .cancelled }
      return result
    }

    func review(runID: Int64) async throws -> DomainMigrationReview { review }

    func apply(
      fromRun runID: Int64, allowedSources: Set<String>,
      phase: @escaping @Sendable (RewriteApplyPhase) -> Void
    ) async throws -> RewriteApplyResult {
      lock.withLock { _applied.append((runID, allowedSources)) }
      if let applyError { throw applyError }
      for step in phases { phase(step) }
      return RewriteApplyResult(
        runID: runID + 1, fromRunID: runID, results: [], summary: RewriteRunSummary(written: written))
    }

    func diff(ofRun runID: Int64) async throws -> String { diffText }
  }

  nonisolated static let current = "https://img.example.com"
  nonisolated static let old = "https://pub-old.r2.dev"

  nonisolated static func review(
    to: String = "https://img2.example.com", keepPrefix: Bool = false, oldDomains: [String] = [old],
    projects: [DomainMigrationReview.ProjectCount] = [.init(project: "blog", files: 2, edits: 3)],
    failed: [DomainMigrationReview.FailedCheck] = [],
    broken: [DomainMigrationReview.BrokenLink] = [],
    sources: [DomainMigrationReview.Source] = []
  ) -> DomainMigrationReview {
    DomainMigrationReview(
      runID: 7, state: .finished, backend: "r2", from: current, to: to, oldDomains: oldDomains,
      keepPrefix: keepPrefix, projects: projects, verified: 2, fetchedOnly: 1, failed: failed,
      alreadyBroken: broken, sources: sources, appliedRunID: nil)
  }

  nonisolated static let backend = DomainBackend(id: 1, slug: "r2", current: current, oldDomains: [old], assetCount: 1)

  private func model(_ stub: StubMigrator, lock: MigrationLock? = nil) -> (DomainMigrationModel, [String]) {
    let model = DomainMigrationModel(migrator: stub, lock: lock ?? MigrationLock())
    model.backends = { [Self.backend, DomainBackend(id: 2, slug: "b2", current: "https://cdn.other.org")] }
    return (model, [])
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
  }

  /// `r2` with Old domain pub-old.r2.dev and a third, unused one; `blog`'s
  /// a.md links twice to the Current domain and once to pub-old.
  private func withCatalog(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try """
    ![a](https://img.example.com/blog/asset-0.png)
    ![b](https://img.example.com/blog/gone.png)
    ![c](https://pub-old.r2.dev/blog/asset-0.png)

    """.write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: source.path)], in: database)
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    _ = try CatalogConfiguration.addOldDomain(Self.old, backendSlug: "r2", in: database)
    _ = try CatalogConfiguration.addOldDomain("https://unused.example.net", backendSlug: "r2", in: database)
    let scan = try UsageScanner.scan(project: "blog", in: database)
    _ = try CatalogUsage.sync(scan.document, project: "blog", in: database)
    try await body(database)
  }

  private func insertSecondBackend(_ database: DatabasePool, folder: String = "blog") throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta, created_at, updated_at)
          VALUES (2, 'b2', 's3', 'https://s3.example.org', 'pics', 'auto', 'https://cdn.other.org',
                  'backend.b2', '{}', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          """)
      for index in 0..<2 {
        var asset = Asset(
          sha256: String(format: "%064x", 900 + index), backendID: 2, key: "\(folder)/b2-\(index).png",
          byteSize: 10, width: 1, height: 1, mime: "image/png", originalFilename: "b2-\(index).png",
          meta: "{}", uploadedAt: "2026-08-03T00:00:00Z", createdAt: "2026-08-03T00:00:00Z",
          updatedAt: "2026-08-03T00:00:00Z")
        try asset.insert(db)
      }
    }
  }

  private func gallery(_ database: DatabasePool, migrator: DomainMigrating? = StubMigrator()) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-d2-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }),
      domainMigrator: migrator)
  }

  // MARK: - Settings: the Domains list

  @Test("Domains: Current first with its links, then each Old one; none linked reads Unused")
  func domainRows() async throws {
    try await withCatalog { database in
      let model = BackendsModel(reader: CatalogBackendsReader(database: database, keychain: Keychain(service: "pinax-test-\(UUID())")))
      await model.load()
      let rows = model.domainRows
      #expect(rows.map(\.host) == ["img.example.com", "pub-old.r2.dev", "unused.example.net"])
      #expect(rows.map(\.isCurrent) == [true, false, false])
      #expect(rows.map(\.linksText) == ["2 links", "1 link", "Unused"])
      #expect(rows.map(\.moveTitle) == [nil, "Move 1 Link to Current…", nil])
    }
  }

  @Test("The one lock greys both migrations' entries, whichever holds it")
  func oneLock() async throws {
    let lock = MigrationLock()
    let backends = BackendsModel(reader: StubBackends())
    backends.migrationLock = lock
    backends.onMoveToNewDomain = { _ in }
    let externals = ExternalsModel(reader: NoExternals(), migrationLock: lock)
    #expect(backends.canMove && !externals.isMigrationBusy)

    #expect(lock.take(.externals))
    #expect(!backends.canMove && backends.moveHelp == "A migration is already running")
    let (domain, _) = model(StubMigrator(), lock: lock)
    await domain.beginNewDomain(backend: "r2")
    #expect(domain.sheet == nil, "a domain move does not start while Externals migrates")
    #expect(!lock.take(.domain))
    lock.release(.externals)

    #expect(lock.take(.domain))
    #expect(externals.isMigrationBusy, "Externals greys while a domain move runs")
    #expect(!backends.canMove)
    lock.release(.domain)
    #expect(!externals.isMigrationBusy && backends.canMove)
  }

  @Test("Add Old Domain (C) is inline; another backend's prefix is refused under the field")
  func addOldDomainInline() async throws {
    try await withCatalog { database in
      try insertSecondBackend(database)
      let model = BackendsModel(reader: CatalogBackendsReader(database: database, keychain: Keychain(service: "pinax-test-\(UUID())")))
      await model.load()
      await model.select("r2")
      model.beginOldDomainAddition()
      #expect(model.oldDomainDraft == "" && !model.canSubmitOldDomain)
      model.updateOldDomainDraft("https://cdn.other.org")
      await model.submitOldDomain()
      #expect(model.oldDomainError == "Already belongs to the backend b2.")
      #expect(model.oldDomainDraft == "https://cdn.other.org", "the field stays with the error")

      model.updateOldDomainDraft("https://legacy.example.com/")
      #expect(model.oldDomainError == nil)
      await model.submitOldDomain()
      #expect(model.oldDomainDraft == nil)
      #expect(model.domainRows.map(\.host).last == "legacy.example.com")
      #expect(model.domainRows.last?.linksText == "Unused")
    }
  }

  @Test("Switch Without Rewriting (D): the old Current joins Old domains, and back again")
  func switchWithoutRewriting() async throws {
    try await withCatalog { database in
      let model = BackendsModel(reader: CatalogBackendsReader(database: database, keychain: Keychain(service: "pinax-test-\(UUID())")))
      await model.load()
      var changed = 0
      model.onDomainsChanged = { changed += 1 }
      model.beginSwitch()
      model.updateSwitchDraft("https://img.example.com/")
      #expect(!model.canSubmitSwitch, "the Current itself")
      model.updateSwitchDraft("https://img2.example.com")
      #expect(model.canSubmitSwitch)
      await model.submitSwitch()
      #expect(model.switchDraft == nil && model.switchError == nil)
      #expect(model.details?.urlPrefix == "https://img2.example.com")
      #expect(model.domainRows.map(\.host).contains("img.example.com"))
      #expect(changed == 1)

      // Back to a domain that is Old now.
      model.beginSwitch()
      model.updateSwitchDraft("https://img.example.com")
      await model.submitSwitch()
      #expect(model.switchError == nil)
      #expect(model.details?.urlPrefix == "https://img.example.com")
      #expect(model.domainRows.filter { $0.host == "img.example.com" }.count == 1)
    }
  }

  @Test("Projects ▸ Storage: Links use is the upload backend's Current")
  func linksUse() {
    let row = { (backend: String?) in
      ProjectSettingsRow(
        id: 1, slug: "blog", name: "Blog", keyPrefix: "blog", backendSlug: backend)
    }
    let one = ProjectSettingsSnapshot(rows: [], backendSlugs: ["r2"], backendPrefixes: ["r2": Self.current])
    #expect(one.linksPrefix(for: row(nil)) == Self.current, "inherits the one backend")
    let two = ProjectSettingsSnapshot(
      rows: [], backendSlugs: ["r2", "b2"], backendPrefixes: ["r2": Self.current, "b2": "https://cdn.other.org"])
    #expect(two.linksPrefix(for: row("b2")) == "https://cdn.other.org")
    #expect(two.linksPrefix(for: row(nil)) == nil, "inherit with two: no single answer")
  }

  // MARK: - Flow A: the form

  @Test("Move to New Domain: Usage on the Current, every project ticked, To checked")
  func formDefaultsAndValidation() async {
    let stub = StubMigrator()
    let (model, _) = model(stub)
    var shown: [String] = []
    model.onShowUsage = { shown.append($0) }
    await model.beginNewDomain(backend: "r2")
    #expect(shown == [Self.current])
    #expect(model.sheet == .form)
    let form = try! #require(model.form)
    #expect(form.fromHost == "img.example.com")
    #expect(form.alsoMoveOld && form.showsOldDomainsSwitch)
    #expect(form.selected == ["blog", "notes"])
    #expect(!form.canCheck, "To is empty")

    for (value, error) in [
      ("https://img.example.com/", "the Current"), ("https://cdn.other.org", "another backend's"),
    ] {
      model.setTo(value)
      await model.validateTo()
      #expect(model.form?.error != nil, "\(error)")
      #expect(model.form?.canCheck == false)
    }
    model.setTo("https://img2.example.com/")
    await model.validateTo()
    #expect(model.form?.error == nil && model.form?.canCheck == true)

    model.setProject("notes", selected: false)
    await model.checkLinks()
    #expect(
      stub.previews == [
        .init(backend: "r2", to: "https://img2.example.com", from: [], projects: ["blog"], keepOldDomains: false)
      ])
    #expect(model.request?.links == 3)
  }

  // MARK: - Checking

  @Test("Checking: progress only grows; the sheet turns into the result in place")
  func checkingInPlace() async {
    let stub = StubMigrator()
    let gate = Gate()
    stub.gate = gate
    let (model, _) = model(stub)
    var fractions: [Double] = []
    model.onProgress = { if case let .checking(checking, _)? = model.status { fractions.append(checking.fraction) } }
    await model.beginNewDomain(backend: "r2")
    model.setTo("https://img2.example.com")
    let task = Task { await model.checkLinks() }
    await waitUntil { model.checking.fraction == 1 }
    #expect(model.sheet == .checking)
    #expect(model.checking.text == "Checking 4 of 4 links")
    #expect(model.status?.item.text == "Checking 4 of 4 links · img2.example.com")
    #expect(model.lock.owner == .domain)
    gate.open()
    await task.value
    #expect(fractions == fractions.sorted())
    #expect(model.sheet == .result)
    #expect(model.status == .ready(runID: 7, links: 3))
    #expect(model.lock.owner == nil)
  }

  @Test("Continue in Background: the bar keeps it, Ready, Review… reopens; ✕ discards")
  func continueInBackground() async {
    let stub = StubMigrator()
    let gate = Gate()
    stub.gate = gate
    let (model, _) = model(stub)
    await model.beginNewDomain(backend: "r2")
    model.setTo("https://img2.example.com")
    let task = Task { await model.checkLinks() }
    await waitUntil { model.status?.isRunning == true && model.checking.fraction == 1 }
    model.continueInBackground()
    #expect(model.sheet == nil)
    #expect(model.status?.item.cancelHelp != nil)
    gate.open()
    await task.value
    #expect(model.sheet == nil, "the result waits in the bar")
    #expect(model.status?.item.text == "Ready to move 3 links")
    #expect(model.status?.item.link == .review)
    model.reviewAgain()
    #expect(model.sheet == .result)
    model.dismissSheet()
    model.stopOrDiscard()
    #expect(model.status == nil && model.summary == nil)
  }

  @Test("Cancel while checking: back to Idle, the lock free")
  func cancelChecking() async {
    let stub = StubMigrator()
    stub.gate = Gate()
    let (model, _) = model(stub)
    await model.beginNewDomain(backend: "r2")
    model.setTo("https://img2.example.com")
    let task = Task { await model.checkLinks() }
    await waitUntil { model.checking.fraction == 1 }
    model.dismissSheet()
    await task.value
    #expect(model.status == nil && model.sheet == nil)
    #expect(model.lock.owner == nil)
  }

  // MARK: - The result

  @Test("The result's titles: failed, prefix only, a move; groups cut at five")
  func summaries() {
    let failed = (0..<7).map {
      DomainMigrationReview.FailedCheck(url: "https://img2.example.com/\($0).png", result: .mismatch, reason: "Different image")
    }
    let withFailures = DomainMoveSummary(Self.review(failed: failed))
    #expect(withFailures.title == "7 Links Failed the Check")
    #expect(withFailures.failedGroups.map(\.reason) == ["Different image"])
    #expect(withFailures.failedGroups.first?.shownURLs.count == 5)
    #expect(withFailures.failedGroups.first?.more == "and 2 more")

    let prefixOnly = DomainMoveSummary(Self.review(projects: [.init(project: "blog", files: 0, edits: 0)]))
    #expect(prefixOnly.title == "Change the Prefix Only?")
    #expect(prefixOnly.moveTitle == "Change Prefix")

    let move = DomainMoveSummary(
      Self.review(broken: [.init(url: "https://img.example.com/gone.png", oldReason: "HTTP 404")]))
    #expect(move.title == "Move 3 Links to img2.example.com?")
    #expect(move.lines.map(\.value) == ["2 files · 1 project", "img.example.com → img2.example.com", "Moved too · 1"])
    #expect(move.brokenGroups.map(\.reason) == ["HTTP 404 on the old domain"])
  }

  @Test("An unclean source blocks Move until Write anyway is ticked")
  func sources() async {
    let stub = StubMigrator()
    stub.review = Self.review(sources: [.init(project: "blog", label: "site", status: .dirty, reason: "2 paths")])
    let (model, _) = model(stub)
    await model.beginMoveToCurrent(backend: "r2", oldDomain: Self.old, links: 1)
    #expect(model.summary?.sources.map(\.text) == ["blog/site has uncommitted changes"])
    #expect(!model.isMoveEnabled)
    model.setSource("blog/site", allowed: true)
    #expect(model.isMoveEnabled)
    await model.confirm()
    #expect(stub.applied.map(\.1) == [["blog/site"]])
  }

  // MARK: - Flow B and the apply

  @Test("Move N Links to Current: Usage on that Old domain, straight to checking, prefix unchanged")
  func flowB() async {
    let stub = StubMigrator()
    stub.review = Self.review(to: Self.current, keepPrefix: true)
    stub.phases = [.rewriting(files: 2), .rescanning(project: "blog")]
    let (model, _) = model(stub)
    var shown: [String] = []
    model.onShowUsage = { shown.append($0) }
    await model.beginMoveToCurrent(backend: "r2", oldDomain: Self.old, links: 3)
    #expect(shown == [Self.old])
    #expect(model.form == nil, "no form in flow B")
    #expect(
      stub.previews == [.init(backend: "r2", to: Self.current, from: [Self.old], projects: [], keepOldDomains: false)])
    #expect(model.summary?.lines[1].value == "Unchanged · img.example.com")
    var statuses: [DomainMigrationStatus] = []
    model.onProgress = { model.status.map { statuses.append($0) } }
    await model.confirm()
    #expect(!statuses.contains(.changingPrefix))
    #expect(statuses.first == .rewriting(files: 2))
  }

  @Test("Apply: prefix, rewrite, rescan in the bar, then the result; onFinished refreshes")
  func applyPhases() async {
    let stub = StubMigrator()
    let (model, _) = model(stub)
    var finished = 0
    model.onFinished = { finished += 1 }
    await model.beginMoveToCurrent(backend: "r2", oldDomain: Self.old, links: 3)
    var statuses: [DomainMigrationStatus] = []
    model.onProgress = { model.status.map { statuses.append($0) } }
    await model.confirm()
    #expect(
      statuses.prefix(4) == [.changingPrefix, .changingPrefix, .rewriting(files: 2), .rescanning(project: "blog")])
    #expect(model.status?.item.text == "Moved 3 links · 2 files")
    #expect(model.status?.item.link == .changedFiles)
    #expect(finished == 1)
    #expect(model.lock.owner == nil)
  }

  @Test("A refused apply reopens the result with the reason; Move greys until checked again")
  func refusal() async {
    let stub = StubMigrator()
    stub.applyError = DomainMigrationError.prefixMoved(backend: "r2", preview: Self.current, current: "https://x.example.com")
    let (model, _) = model(stub)
    await model.beginMoveToCurrent(backend: "r2", oldDomain: Self.old)
    model.dismissSheet()
    await model.confirm()
    #expect(model.sheet == .result)
    #expect(model.refusal?.message == "The backend’s prefix changed since the check. Nothing was changed. Check again.")
    #expect(!model.isMoveEnabled)
    #expect(model.status == .ready(runID: 7, links: 3))
    await model.checkAgain()
    #expect(model.refusal == nil && model.isMoveEnabled)
    #expect(stub.previews.count == 2)
  }

  // MARK: - The activity bar and panel

  @Test("The bar's migration slot shows the domain move; ✕ and Review… reach it")
  func activitySlot() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    let stub = StubMigrator()
    let gallery = gallery(database, migrator: stub)
    await gallery.loadInitialData()
    let domain = try #require(gallery.domainMigration)
    await domain.beginMoveToCurrent(backend: "r2", oldDomain: Self.old, links: 3)
    #expect(gallery.usageDomain == Self.old)
    #expect(gallery.sidebarSelection == .usage)
    domain.dismissSheet()
    #expect(gallery.activity.currentSource == .migration)
    #expect(gallery.activity.current?.text == "Ready to move 3 links")
    gallery.activity.perform(.review)
    #expect(domain.sheet == .result)
    domain.dismissSheet()
    gallery.activity.cancelCurrent()
    #expect(domain.status == nil)
  }

  @Test("The panel's Show Changes… covers rewrite and domain_migrate previews")
  func panelShowChanges() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let params = CatalogCore.RewriteRunParams(targets: [])
    let preview = try RunLog.start(kind: .domainMigrate, dryRun: true, params: params, in: database)
    try RunLog.append(
      .filePlanned(FilePlannedEvent(project: "blog", source: "site", path: "a.md", sha256: "x", edits: 1, editsDigest: "d")),
      to: preview, in: database)
    try RunLog.finish(preview, state: .finished, summary: RewriteRunSummary(files: 1), in: database)

    let panel = ActivityPanelModel(reader: ReadOnlyCatalog(database: database))
    #expect(!panel.canShowChanges)
    var diffed: [Int64] = []
    panel.rewriteDiff = { diffed.append($0); return "--- a/a.md\n" }
    panel.selectedRunID = preview
    await panel.refresh()
    #expect(panel.canShowChanges)
    await panel.showChanges()
    #expect(diffed == [preview])
    #expect(panel.changesDiff == "--- a/a.md\n")

    let gallery = gallery(database)
    #expect(gallery.activityPanel.rewriteDiff != nil, "the gallery wires its migrator's diff")
  }

  // MARK: - Usage

  @Test("Usage's domain menu: a section per backend, Old ones offer the move, a gone one resets")
  func usageMenu() async throws {
    try await withCatalog { database in
      let gallery = gallery(database)
      await gallery.loadInitialData()
      gallery.select(.usage, in: .reports)
      await gallery.reload()
      let sections = gallery.usageDomainSections
      #expect(sections.map(\.backend) == ["r2"])
      #expect(sections[0].items.map(\.host) == ["img.example.com", "pub-old.r2.dev", "unused.example.net"])
      // gone.png is not in the library but counts, as in Settings.
      #expect(sections[0].items.map(\.links) == [2, 1, 0])
      #expect(gallery.usageAllDomainsLinks == 2)
      #expect(gallery.usageMoveTitle == nil, "All Domains")

      // The choice reloads Usage itself; the newest load wins.
      gallery.usageDomain = Self.old
      await waitUntil { gallery.usageBrowser?.domain == Self.old && !gallery.isLoadingPage }
      #expect(gallery.usageBrowser?.totalReferenceCount == 1)
      #expect(
        gallery.usageBrowser?.files.flatMap(\.occurrences).count == 1, "only pub-old's link is listed")
      #expect(gallery.usageMoveTitle == "Move 1 Link to Current…")
      gallery.usageDomain = Self.current
      #expect(gallery.usageMoveTitle == nil, "the Current has nothing to move")

      gallery.usageDomain = "https://unused.example.net"
      _ = try CatalogConfiguration.removeOldDomain("https://unused.example.net", backendSlug: "r2", in: database)
      await gallery.refreshDomainBackends()
      #expect(gallery.usageDomain == nil, "a removed domain goes back to All Domains")
    }
  }

  // MARK: - Catalog roots

  @Test("Storage: one root per backend named by its slug; same folder names stay apart")
  func catalogRoots() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z", key: "blog/a.png")
    try insertSecondBackend(database)
    let gallery = gallery(database)
    await gallery.loadInitialData()
    let catalog = try #require(gallery.sidebarSections.first { $0.id == "catalog" })
    // The root's square is its folders' 18, so their tree lines meet its middle.
    #expect(SidebarEntrySquare.size(for: .backendRoot).side == SidebarEntrySquare.size(for: .catalog).side)
    // By slug, as Settings lists them.
    // The slug, the bucket after it, the Current
    // prefix in the tooltip.
    #expect(catalog.entries.map(\.label) == ["b2", "r2"])
    #expect(catalog.entries.map(\.detail) == ["pics", "images"])
    #expect(catalog.entries.map(\.help) == ["pics · https://cdn.other.org", "images · https://img.example.com"])
    #expect(catalog.entries.map(\.count) == [2, 1])
    #expect(catalog.entries.map { $0.children.map(\.selection) } == [
      [.keyPrefix("blog", backend: "b2")], [.keyPrefix("blog", backend: "r2")],
    ])
    #expect(catalog.entries.map { $0.children.map(\.count) } == [[2], [1]])

    gallery.select(.keyPrefix("blog", backend: "b2"), in: .library)
    await gallery.reload()
    #expect(gallery.totalCount == 2, "b2's blog only")
    gallery.select(.backend("r2"), in: .library)
    await gallery.reload()
    #expect(gallery.totalCount == 1)

    _ = try CatalogConfiguration.setBackendURLPrefix(slug: "r2", urlPrefix: "https://img2.example.com", in: database)
    await gallery.refreshDomainBackends()
    // A domain move changes the tooltip, never the row's name.
    let moved = try #require(gallery.sidebarSections.first { $0.id == "catalog" })
    #expect(moved.entries.map(\.label) == ["b2", "r2"])
    #expect(moved.entries.map(\.help) == ["pics · https://cdn.other.org", "images · https://img2.example.com"])
  }

  // MARK: - Table

  @Test("Domain column: outside Usage it is the user's (hidden by default); an image shows its Current host")
  func domainColumn() async throws {
    #expect(AssetTableView.visibleUsageColumns(selection: .all, currentProjectSlug: nil).isEmpty)
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    let gallery = gallery(database, migrator: nil)
    await gallery.loadInitialData()
    await gallery.reload()
    let row = try #require(gallery.rows.first)
    #expect(AssetTableView.domain(row) == "img.example.com")
    #expect(AssetTableView.domainHelp(row) == "r2")
  }
}

private struct NoExternals: ExternalUsageReading {
  func externalReferences(project: String?) async throws -> ExternalReferenceSet {
    ExternalReferenceSet(references: [], projectSources: [:])
  }
}

private struct StubBackends: BackendsReading {
  func backends() async throws -> [BackendListRow] { [] }
  func backend(slug: String) async throws -> BackendDetails { throw CancellationError() }
}
