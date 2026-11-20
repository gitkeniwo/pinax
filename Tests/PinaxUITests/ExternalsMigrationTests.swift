import AppKit
@testable import CatalogCore
import Foundation
@testable import PinaxUI
import Testing

/// The Migrate entries, the preparation in the
/// status bar, the confirmation sheet, Review…, Stop, the result and the
/// rows it leaves, and the Migrated copy. The migration core is stubbed; the activity slot
/// is the gallery's own, as the app wires it.
@MainActor
@Suite struct ExternalsMigrationTests {
  nonisolated static let imgurA = "https://i.imgur.com/a.png"
  nonisolated static let imgurB = "https://i.imgur.com/b.png"
  nonisolated static let amazon = "https://m.media-amazon.com/images/x.jpg"

  static func row(
    _ source: String, _ url: String, domain: ExternalDomain = .other, project: String = "astro"
  ) -> ExternalReference {
    ExternalReference(
      projectSlug: project, sourceReference: source, rawURL: url, kind: "markdown", domain: domain,
      match: domain == .yours
        ? ExternalDomainMatch(backendSlug: "r2", prefix: "https://img.pinax.invalid", isCurrent: true) : nil)
  }

  static let rows: [ExternalReference] = [
    row("posts/a.md#L1", imgurA),
    row("posts/b.md#L4", imgurA),
    row("posts/b.md#L9", imgurB),
    row("posts/c.md#L2", amazon),
    row("posts/d.md#L3", "https://img.pinax.invalid/blog/own.png", domain: .yours),
  ]

  private struct StaticExternals: ExternalUsageReading {
    let rows: [ExternalReference]
    func externalReferences(project: String?) async throws -> ExternalReferenceSet {
      ExternalReferenceSet(references: rows, projectSources: [:])
    }
  }

  final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    func wait() async {
      while !lock.withLock({ isOpen }) { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
  }

  /// The migration core as the model sees it: prepare reports one download and waits;
  /// apply uploads images one at a time, checking the stop between them.
  final class StubMigrator: ExternalsMigrating, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    var busyElsewhere = false
    var preparation = ExternalsMigrationTests.preparation()
    var prepareGate: Gate?
    var applyGate: Gate?
    var applyImages = 3
    var applyError: Error?
    var applyResult: ExternalMigrationResult?
    private(set) var preparedTargets: [[ExternalMigrationTarget]] = []
    private(set) var allowed: [Set<String>] = []
    private(set) var uploaded = 0

    var isRunning: Bool { lock.withLock { running || busyElsewhere } }

    func prepare(
      targets: [ExternalMigrationTarget], cancellation: ExternalMigrationCancellation,
      progress: @escaping @Sendable (ExternalMigrationProgress) -> Void
    ) async throws -> ExternalMigrationPreparation {
      lock.withLock { running = true; preparedTargets.append(targets) }
      defer { lock.withLock { running = false } }
      let total = Set(targets.flatMap(\.urls)).count
      progress(ExternalMigrationProgress(phase: .download, done: 1, total: total, host: "i.imgur.com"))
      await prepareGate?.wait()
      if cancellation.isCancelled {
        return ExternalMigrationPreparation(
          result: ExternalMigrationResult(
            runID: preparation.result.runID, state: .cancelled, summary: RewriteRunSummary(), events: []),
          bucket: nil)
      }
      return preparation
    }

    func apply(
      fromRun runID: Int64, allowedSources: Set<String>, cancellation: ExternalMigrationCancellation,
      progress: @escaping @Sendable (ExternalMigrationProgress) -> Void
    ) async throws -> ExternalMigrationResult {
      lock.withLock { running = true; allowed.append(allowedSources) }
      defer { lock.withLock { running = false } }
      if let applyError { throw applyError }
      for index in 1...applyImages {
        lock.withLock { uploaded = index }
        progress(ExternalMigrationProgress(phase: .upload, done: index, total: applyImages, host: "i.imgur.com"))
        if index == 1 { await applyGate?.wait() }
        // The core checks the stop between two images.
        if cancellation.isCancelled, index < applyImages {
          var summary = RewriteRunSummary()
          var migration = ExternalMigrationSummary()
          migration.migratable = .init(images: applyImages, links: applyImages)
          migration.uploaded = .init(images: index, links: index)
          migration.stoppedAfter = index
          summary.migration = migration
          return ExternalMigrationResult(runID: 8, state: .cancelled, summary: summary, events: [])
        }
      }
      return applyResult ?? ExternalMigrationResult(
        runID: 8, state: .finished, summary: RewriteRunSummary(), events: [])
    }

    func diff(ofRun runID: Int64) async throws -> String { "--- a/astro-blog/posts/a.md\n" }

    private(set) var discarded: [Int64] = []
    func discardPreparation(ofRun runID: Int64) { lock.withLock { discarded.append(runID) } }
  }

  /// A confirmation with distinct numbers: 47 to upload, 2 reused, 1 broken, 21 files,
  /// one dirty source.
  nonisolated static func preparation(migratable: Int = 47, reused: Int = 2) -> ExternalMigrationPreparation {
    var migration = ExternalMigrationSummary()
    migration.migratable = .init(images: migratable, links: migratable)
    migration.reused = .init(images: reused, links: reused)
    migration.skipped = .init(images: 1, links: 1)
    migration.bytes = 18_600_000
    migration.files = [.init(project: "astro", source: "astro-blog", files: 21, edits: 49)]
    migration.sampleKeys = ["202610/a-3fa9c2e1.png"]
    migration.hosts = [
      .init(host: "i.imgur.com", links: 48, urls: 48, tips: []),
      .init(host: "upload.wikimedia.org", links: 1, urls: 1, tips: ["Usually asks for attribution"]),
      .init(host: "m.media-amazon.com", links: 1, urls: 1, tips: ["404 · skipped"]),
    ]
    var summary = RewriteRunSummary()
    summary.migration = migration
    let events: [RunEvent] = [
      .sourceStatus(SourceStatusEvent(project: "astro", source: "astro-blog", git: .dirty(paths: ["x.md"]))),
      .downloadFailed(DownloadFailedEvent(url: amazon, host: "m.media-amazon.com", reason: .httpStatus, status: 404)),
    ]
    return ExternalMigrationPreparation(
      result: ExternalMigrationResult(runID: 7, state: .finished, summary: summary, events: events),
      bucket: "image-hosting", storageKind: "r2")
  }

  private func gallery(_ migrator: StubMigrator?) throws -> GalleryModel {
    let (database, _) = try makeUITestDatabase()
    return GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-migrate-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }),
      externalReader: StaticExternals(rows: Self.rows), externalsMigrator: migrator)
  }

  private func loaded(_ migrator: StubMigrator?) async throws -> (GalleryModel, ExternalsModel) {
    let gallery = try gallery(migrator)
    let model = gallery.externals
    await model.load()
    model.domain = .other
    return (gallery, model)
  }

  private func until(seconds: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func ids(_ urls: Set<String>, _ model: ExternalsModel) -> Set<ExternalReference.ID> {
    Set((model.items ?? []).filter { urls.contains($0.rawURL) && $0.domain == .other }.map(\.id))
  }

  /// Prepared, the sheet up, ready.
  private func prepared(_ migrator: StubMigrator) async throws -> (GalleryModel, ExternalsModel) {
    let (gallery, model) = try await loaded(migrator)
    model.selection = ids([Self.imgurA], model)
    await model.migrateSelection()
    return (gallery, model)
  }

  // MARK: - Entries

  @Test("Entries: Other Domains only, N distinct URLs, none with a Your Domains row or read-only")
  func entries() async throws {
    let migrator = StubMigrator()
    let (_, model) = try await loaded(migrator)
    model.selection = ids([Self.imgurA, Self.imgurB], model)
    // Three rows, two URLs.
    #expect(model.rows(model.selection).count == 3)
    #expect(model.selectionMigrationCount == 2)
    #expect(ExternalsModel.migrateShortTitle(2) == "Migrate 2…")
    #expect(ExternalsModel.migrateInspectorTitle(2) == "Migrate 2 to Bucket…")
    let menu = model.menuItems(for: model.selection)
    let titles = menu.map(\.title)
    let migrateIndex = try #require(titles.firstIndex(of: "Migrate to Bucket…"))
    #expect(titles[migrateIndex - 1] == "Load Previews")
    #expect(model.isEnabled(menu[migrateIndex]))
    #expect(ExternalMenuButtons.dividesAfter(menu[migrateIndex], in: menu))
    // A group: its distinct URLs.
    let imgur = try #require(model.groups.first { $0.host == "i.imgur.com" })
    #expect(model.migrationURLs(imgur.rows).count == 2)
    // No entry with nothing selected.
    model.selection = []
    #expect(model.selectionMigrationCount == 0)

    // A Your Domains row among them: no entry.
    let mixed = Self.rows.filter { $0.rawURL == Self.imgurA || $0.domain == .yours }
    #expect(model.migrationURLs(mixed).isEmpty)
    // A read-only gallery has none.
    let (_, readOnly) = try await loaded(nil)
    readOnly.selection = ids([Self.imgurA], readOnly)
    #expect(readOnly.selectionMigrationCount == 0)
    #expect(!readOnly.menuItems(for: readOnly.selection).map(\.title).contains("Migrate to Bucket…"))
  }

  @Test("Entries grey while a migration runs, here or elsewhere in the process")
  func entriesGreyWhileRunning() async throws {
    let migrator = StubMigrator()
    let (_, model) = try await loaded(migrator)
    model.selection = ids([Self.imgurA], model)
    let item = try #require(model.menuItems(for: model.selection).first { $0.title == "Migrate to Bucket…" })
    migrator.busyElsewhere = true
    #expect(model.isMigrationBusy)
    #expect(!model.isEnabled(item))
    #expect(ExternalsModel.migrationBusyHelp == "A migration is already running")
    // A greyed entry does nothing.
    await model.migrateSelection()
    #expect(migrator.preparedTargets.isEmpty)
    migrator.busyElsewhere = false
    #expect(model.isEnabled(item))
  }

  // MARK: - Preparing

  @Test("Preparing shows in the slot with ✕; cancelling leaves nothing and goes back to Idle")
  func prepareCancel() async throws {
    let migrator = StubMigrator()
    let gate = Gate()
    migrator.prepareGate = gate
    let (gallery, model) = try await loaded(migrator)
    model.selection = ids([Self.imgurA, Self.imgurB], model)
    let task = Task { await model.migrateSelection() }
    await until { gallery.activity.current?.text.contains("downloaded 1") == true }
    #expect(gallery.activity.current?.text == "Preparing · downloaded 1 of 2 · i.imgur.com")
    #expect(gallery.activity.current?.phase == .running(fraction: 0.5, cancel: "Cancel"))
    #expect(model.isMigrationBusy)
    // The slot's ✕, through the handler the gallery registered.
    gallery.activity.cancelCurrent()
    gate.open()
    await task.value
    #expect(model.migrationStatus == nil)
    #expect(gallery.activity.current == nil)
    #expect(!model.isMigrationSheetPresented)
    #expect(model.migrationConfirmation == nil)
    #expect(migrator.preparedTargets == [[ExternalMigrationTarget(project: "astro", urls: [Self.imgurA, Self.imgurB])]])
  }

  // MARK: - The sheet

  @Test("The sheet's title, rows and hosts come from the preparation's summary and events")
  func sheetValues() async throws {
    let (_, model) = try await prepared(StubMigrator())
    #expect(model.isMigrationSheetPresented)
    let sheet = try #require(model.migrationConfirmation)
    #expect(sheet.title == "Migrate 49 Links to Your Bucket?")
    #expect(sheet.lines.map(\.label) == [
      "Upload", "Already in library", "Skipped", "Files to change", "Bucket", "New keys",
    ])
    let values = Dictionary(uniqueKeysWithValues: sheet.lines.map { ($0.label, $0) })
    #expect(values["Upload"]?.value == "47 images · " + ByteCountFormatter.string(fromByteCount: 18_600_000, countStyle: .file))
    #expect(values["Already in library"]?.value == "2")
    #expect(values["Already in library"]?.detail == "Links will point to the copy you have")
    #expect(values["Skipped"]?.value == "1 broken link")
    #expect(values["Skipped"]?.detail == "m.media-amazon.com · 404 — left as is")
    #expect(values["Skipped"]?.isWarning == true)
    #expect(values["Files to change"]?.value == "21 files · astro-blog")
    #expect(values["Bucket"]?.value == "image-hosting")
    #expect(values["Bucket"]?.tag == "R2")
    #expect(values["New keys"]?.value == "202610/a-3fa9c2e1.png")
    #expect(values["New keys"]?.isMonospaced == true)
    #expect(values["New keys"]?.detail == "Your key template · dated today")
    #expect(sheet.hostsTitle == "FROM 3 HOSTS")
    #expect(sheet.hosts.map(\.links) == [48, 1, 1])
    #expect(sheet.hosts[1].tip == "Usually asks for attribution")
    #expect(sheet.hosts[2].isWarning)
    #expect(!sheet.hosts[1].isWarning)
    #expect(sheet.migrateTitle == "Migrate 49 Links")
    #expect(sheet.sources.map(\.id) == ["astro/astro-blog"])
    #expect(sheet.sources[0].text == "astro-blog has uncommitted changes.")
  }

  @Test("An unclean source starts unticked and greys Migrate until ticked")
  func uncleanSourceGate() async throws {
    let migrator = StubMigrator()
    let (_, model) = try await prepared(migrator)
    #expect(model.migrationAllowedSources.isEmpty)
    #expect(!model.isMigrateEnabled)
    await model.confirmMigration()
    #expect(migrator.allowed.isEmpty)
    model.setMigrationSource("astro/astro-blog", allowed: true)
    #expect(model.isMigrateEnabled)
    await model.confirmMigration()
    #expect(migrator.allowed == [["astro/astro-blog"]])
  }

  @Test("Nothing migratable: Nothing to Migrate, greyed, no Skipped row without skips")
  func nothingToMigrate() async throws {
    let migrator = StubMigrator()
    migrator.preparation = Self.preparation(migratable: 0, reused: 0)
    let (_, model) = try await prepared(migrator)
    let sheet = try #require(model.migrationConfirmation)
    #expect(sheet.migrateTitle == "Nothing to Migrate")
    model.setMigrationSource("astro/astro-blog", allowed: true)
    #expect(!model.isMigrateEnabled)
    var clean = Self.preparation()
    clean.result = ExternalMigrationResult(
      runID: 7, state: .finished,
      summary: {
        var summary = clean.result.summary
        summary.migration?.skipped = .init()
        return summary
      }(), events: [])
    #expect(!ExternalMigrationConfirmation.make(clean).lines.map(\.label).contains("Skipped"))
  }

  @Test("Closed, the slot shows Ready with Review…, which reopens the sheet")
  func reviewAfterClose() async throws {
    let (gallery, model) = try await prepared(StubMigrator())
    model.dismissMigrationSheet()
    #expect(!model.isMigrationSheetPresented)
    #expect(model.migrationConfirmation != nil)
    #expect(gallery.activity.current?.text == "Ready to migrate 49 links")
    #expect(gallery.activity.current?.shownLink == .review)
    gallery.activity.perform(.review)
    #expect(model.isMigrationSheetPresented)
    // Show Changes…: the diff in a nested sheet.
    await model.showMigrationChanges()
    #expect(model.migrationDiff == "--- a/astro-blog/posts/a.md\n")
    model.closeMigrationChanges()
    #expect(model.migrationDiff == nil)
  }

  @Test("A refused apply brings the sheet back with the reason and Prepare Again")
  func refusal() async throws {
    let migrator = StubMigrator()
    migrator.applyError = RewriteRunError.planChanged(runID: 7, differences: ["astro/astro-blog/a.md"])
    let (gallery, model) = try await prepared(migrator)
    model.setMigrationSource("astro/astro-blog", allowed: true)
    await model.confirmMigration()
    #expect(model.isMigrationSheetPresented)
    let refusal = try #require(model.migrationRefusal)
    #expect(refusal.needsPreparing)
    #expect(refusal.message.contains("Nothing was uploaded"))
    #expect(!model.isMigrateEnabled)
    #expect(gallery.activity.current?.text == "Ready to migrate 49 links")
    await model.prepareMigrationAgain()
    #expect(migrator.preparedTargets.count == 2)
    #expect(model.migrationRefusal == nil)
    let sources = try #require(
      ExternalMigrationRefusal.make(RewriteRunError.sourcesNotAllowed(["astro/astro-blog (dirty)"])))
    #expect(!sources.needsPreparing)
  }

  // MARK: - After Migrate

  @Test("Stop lands between two images: Stopping hides ✕, the result says Stopped")
  func stopBetweenImages() async throws {
    let migrator = StubMigrator()
    let gate = Gate()
    migrator.applyGate = gate
    let (gallery, model) = try await prepared(migrator)
    model.setMigrationSource("astro/astro-blog", allowed: true)
    let task = Task { await model.confirmMigration() }
    await until { gallery.activity.current?.text.hasPrefix("Uploading 1 of 3") == true }
    #expect(!model.isMigrationSheetPresented)
    #expect(gallery.activity.current?.text == "Uploading 1 of 3 · i.imgur.com")
    #expect(
      gallery.activity.current?.phase == .running(fraction: 1.0 / 3.0, cancel: "Stop after this image"))
    gallery.activity.cancelCurrent()
    #expect(gallery.activity.current?.phase == .running(fraction: 1.0 / 3.0, cancel: nil))
    gate.open()
    await task.value
    #expect(migrator.uploaded == 1)
    let item = try #require(gallery.activity.current)
    #expect(item.text == "Stopped after 1 of 3 images · nothing rewritten")
    #expect(item.phase == .failed)
    #expect(item.shownLink == .showLog)
    #expect(item.runID == 8)
  }

  @Test("Done with warnings: the slot's sentence, Changed Files, and each row left says why")
  func finishedWithFailures() async throws {
    let migrator = StubMigrator()
    migrator.applyImages = 1
    var summary = RewriteRunSummary(written: 21)
    var migration = ExternalMigrationSummary()
    migration.uploaded = .init(images: 46, links: 46)
    migration.reused = .init(images: 2, links: 2)
    migration.skipped = .init(images: 1, links: 1)
    migration.failed = .init(images: 1, links: 1)
    summary.migration = migration
    migrator.applyResult = ExternalMigrationResult(
      runID: 8, state: .finished, summary: summary,
      events: [.uploadFailed(UploadFailedEvent(url: Self.imgurB, error: "HTTP 500", fatal: false))])
    let (gallery, model) = try await prepared(migrator)
    model.setMigrationSource("astro/astro-blog", allowed: true)
    await model.confirmMigration()
    let item = try #require(gallery.activity.current)
    #expect(item.text == "Migrated 46 · 2 reused · 1 skipped · 1 failed")
    #expect(item.phase == .warnings)
    #expect(item.shownLink == .changedFiles)
    #expect(model.migrationConfirmation == nil)
    let failed = try #require(model.items?.first { $0.rawURL == Self.imgurB })
    #expect(model.migrationFailure(failed)?.status == "Upload failed")
    #expect(model.migrationFailure(failed)?.explanation.isEmpty == false)
    let broken = try #require(model.items?.first { $0.rawURL == Self.amazon })
    #expect(model.migrationFailure(broken)?.status == "404 · skipped")
    let migrated = try #require(model.items?.first { $0.rawURL == Self.imgurA })
    #expect(model.migrationFailure(migrated) == nil)
    // Not shared with import's.
    #expect(model.importFailures.isEmpty)
  }

  @Test("A clean finish is Done; a backend failure is Failed with Show Log")
  func doneAndFailed() {
    var summary = RewriteRunSummary(written: 3)
    var migration = ExternalMigrationSummary()
    migration.uploaded = .init(images: 3, links: 4)
    summary.migration = migration
    let done = ExternalMigrationStatus.result(
      ExternalMigrationResult(runID: 1, state: .finished, summary: summary, events: [])).item
    #expect(done.text == "Migrated 3")
    #expect(done.phase == .finished)
    #expect(done.shownLink == .changedFiles)
    let failed = ExternalMigrationStatus.result(
      ExternalMigrationResult(runID: 2, state: .failed, summary: summary, events: [])).item
    #expect(failed.text == "Migration failed · nothing rewritten")
    #expect(failed.phase == .failed)
    #expect(failed.shownLink == .showLog)
  }

  // MARK: - Copy

  @Test("Migrated: the caption's short name and the Source row's Migrated from <host>")
  func migratedCopy() throws {
    let source = "https://upload.wikimedia.org/wikipedia/en/e/e9/x.png"
    let asset = Asset(
      id: 1, sha256: String(repeating: "a", count: 64), backendID: 1, key: "202610/x.png",
      byteSize: 1, mime: "image/png", meta: #"{"source_url":"\#(source)"}"#,
      uploadedAt: "2026-10-30T00:00:00Z", createdAt: "2026-10-30T00:00:00Z",
      updatedAt: "2026-10-30T00:00:00Z")
    let backend = Backend(
      id: 1, slug: "r2", kind: "s3", endpoint: "https://s3.pinax.invalid", bucket: "image-hosting",
      urlPrefix: "https://img.pinax.invalid", keychainRef: "", createdAt: "2026-01-01T00:00:00Z",
      updatedAt: "2026-01-01T00:00:00Z")
    let description = AssetSourceDescription(asset: asset, backend: backend)
    #expect(description.source == .migrated)
    #expect(description.title == "Migrated from upload.wikimedia.org")
    #expect(description.text(date: "D") == "Migrated from upload.wikimedia.org · D")
    #expect(description.originalURL?.absoluteString == source)
    #expect(SourceCaption.name(of: .migrated) == "Migrated")
    #expect(SourceCaption.tint(of: .migrated) == .migrated)
    let caption = try #require(
      SourceCaption.make(style: .dot, source: .migrated, tier: .large, showsFilename: true))
    #expect(caption.text == "Migrated")
    #expect(NSImage(systemSymbolName: ExternalsView.migrateSymbol, accessibilityDescription: nil) != nil)
    #expect(NSImage(systemSymbolName: SourceCaption.icon(of: .migrated) ?? "", accessibilityDescription: nil) != nil)
  }
}
