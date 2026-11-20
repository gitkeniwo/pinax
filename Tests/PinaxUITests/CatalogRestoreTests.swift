import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// The GUI's restore, through the app's own
/// wiring (`PinaxAppModel.start()`, the views' named actions). The panels
/// and the credential lookup are the injected closures: no panel, sheet or
/// menu opens, and no Keychain is read. Temporary catalogs and defaults
/// suites only.
@MainActor
@Suite struct CatalogRestoreTests {
  /// The injected backup chooser: counts its calls, hands back `file`.
  final class PanelLog {
    var calls = 0
    var file: URL?
    var savePanelNames: [String] = []
    /// Where the injected save panel saves; nil is Cancel.
    var saveTo: URL?
    func choose() -> URL? {
      calls += 1
      return file
    }
  }

  private func makeApp(
    _ database: DatabasePool, panel: PanelLog, defaults: UserDefaults,
    usageSynchronizer: (any UsageSyncing)? = nil
  ) -> PinaxAppModel {
    PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: defaults, databaseOpener: { database },
      usageSynchronizer: { usageSynchronizer ?? CatalogUsageSynchronizer(database: $0) },
      chooseSourceFolder: { _ in nil },
      chooseBackupFile: { panel.choose() },
      chooseBackupDestination: { name in
        panel.savePanelNames.append(name)
        return panel.saveTo
      },
      credentialExists: { $0 == "backend.r2" })
  }

  private func makeDefaults() throws -> (UserDefaults, String) {
    let name = "pinaxui-restore-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
  }

  /// A backup of `makeRestoreFollowUpSource` (3 assets, `blog` and `notes`,
  /// backends r2 and b2), written into `directory`.
  private func writeBackup(in directory: URL) throws -> URL {
    let (source, sourceDirectory) = try makeRestoreFollowUpSource()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    // `blog`'s source folder must outlive the source catalog: point it at
    // one under the target's directory.
    let site = directory.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    try source.write { db in
      try db.execute(
        sql: "UPDATE project SET meta = ? WHERE slug = 'blog'",
        arguments: [#"{"sources":[{"label":"site","path":"\#(site.path)"}]}"#])
    }
    let file = directory.appendingPathComponent("pinax-backup-2026-10-07.json")
    try JSONEncoder().encode(try CatalogBackups.create(from: source)).write(to: file)
    return file
  }

  @Test("Settings' Restore from Backup… is the backup model's one restore, through the one panel closure")
  func settingsEntry() async throws {
    let (database, directory) = try makeEmptyRestoreTarget()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    let backup = try #require(app.backup)

    #expect(backup.isCatalogEmpty == true)
    #expect(app.isCatalogEmpty == true)
    #expect(backup.canRestore)
    #expect(!backup.canExport)
    let section = BackupSection(model: backup)
    #expect(!section.restoreDisabled)

    await section.restoreAction()
    #expect(panel.calls == 1)
    #expect(backup.restorePresenter == .settings)
    // The panel was cancelled: nothing pending, nothing written.
    #expect(backup.pendingRestore == nil)
    #expect(try CatalogBackups.counts(in: database).isEmpty)
  }

  @Test("The empty state, File ▸ Import and Settings each call the one restore once, through the one panel closure")
  func threeEntriesOneAction() async throws {
    let (database, directory) = try makeEmptyRestoreTarget()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    let backup = try #require(app.backup)
    let gallery = try #require(app.gallery)
    let emptyState = NoAssetsState(model: gallery)
    let menu = PinaxCommands(app: app).backupItems

    #expect(emptyState.showsRestore)
    #expect(menu.canImport)
    #expect(!menu.canExport)

    await emptyState.restoreAction()
    #expect(panel.calls == 1)
    #expect(backup.restorePresenter == .gallery)

    await BackupSection(model: backup).restoreAction()
    #expect(panel.calls == 2)
    #expect(backup.restorePresenter == .settings)

    await menu.importBackup()
    #expect(panel.calls == 3)
    #expect(backup.restorePresenter == .gallery)
    #expect(panel.savePanelNames.isEmpty)
    #expect(try CatalogBackups.counts(in: database).isEmpty)
  }

  @Test("replace: a catalog with anything in it — every entry is on, Replace… asks again, Save and Replace… saves the old catalog first")
  func replaceSavesFirst() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    panel.file = try writeBackup(in: directory)
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    let backup = try #require(app.backup)
    let gallery = try #require(app.gallery)
    let current = try CatalogBackups.counts(in: database)
    #expect(!current.isEmpty)

    #expect(backup.isCatalogEmpty == false)
    #expect(backup.canRestore)
    #expect(!BackupSection(model: backup).restoreDisabled)
    #expect(!NoAssetsState(model: gallery).showsRestore)
    let menu = PinaxCommands(app: app).backupItems
    #expect(menu.canImport)
    #expect(menu.canExport)

    await menu.importBackup()
    #expect(panel.calls == 1)
    let preview = try #require(backup.pendingRestore)
    #expect(preview.replacing == current)
    #expect(backup.isConfirmationPresented(by: .gallery))
    let sheet = RestoreConfirmationSheet(preview: preview, cancel: {}, restore: {})
    #expect(sheet.title == "Replace Catalog with Backup?")
    #expect(sheet.restoreTitle == "Replace…")
    #expect(sheet.summary.contains("This replaces everything in the current catalog"))

    // Replace… is the first question; nothing is written yet.
    await backup.confirmRestore()
    #expect(backup.restoreStep == .offerSave)
    #expect(backup.isConfirmationPresented(by: .gallery))
    #expect(try CatalogBackups.counts(in: database) == current)

    // A cancelled save panel replaces nothing.
    await backup.saveThenReplace()
    #expect(panel.savePanelNames == [BackupModel.beforeRestoreFilename(for: Date())])
    #expect(backup.restoreStep == .offerSave)
    #expect(try CatalogBackups.counts(in: database) == current)
    #expect(app.catalogRestoreReloads == 0)

    let saved = directory.appendingPathComponent("before.json")
    panel.saveTo = saved
    await backup.saveThenReplace()
    let old = try CatalogBackups.decode(try Data(contentsOf: saved))
    #expect(CatalogTableCounts(old.tables) == current)
    #expect(try CatalogBackups.counts(in: database).assets == 3)
    #expect(try CatalogBackups.counts(in: database).projects == 2)
    #expect(app.catalogRestoreReloads == 1)
    #expect(gallery.rows.count == 3)
    #expect(backup.restoredOutcome != nil)
    #expect(backup.pendingRestore == nil)
    #expect(backup.restoreStep == .confirm)
  }

  @Test("replace: a backup that fails to save replaces nothing — the second question stays up and says why, and nothing reloads")
  func replaceSaveFailureReplacesNothing() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    panel.file = try writeBackup(in: directory)
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    let backup = try #require(app.backup)
    let before = try CatalogBackups.create(from: database, now: Date(timeIntervalSince1970: 0))

    await PinaxCommands(app: app).backupItems.importBackup()
    await backup.confirmRestore()
    #expect(backup.restoreStep == .offerSave)
    // The app's own writer, told to save into a folder that is not there.
    let unsaved = directory.appendingPathComponent("missing", isDirectory: true)
      .appendingPathComponent("before.json")
    panel.saveTo = unsaved
    var expected: String?
    do { try Data().write(to: unsaved, options: .atomic) } catch {
      expected = UserFacingErrorMessage.resolve(error)
    }
    await backup.saveThenReplace()

    #expect(panel.savePanelNames == [BackupModel.beforeRestoreFilename(for: Date())])
    #expect(!FileManager.default.fileExists(atPath: unsaved.path))
    let after = try CatalogBackups.create(from: database, now: Date(timeIntervalSince1970: 0))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(after) == encoder.encode(before))
    #expect(backup.restoreStep == .offerSave)
    #expect(backup.isConfirmationPresented(by: .gallery))
    #expect(backup.pendingRestore != nil)
    #expect(expected != nil)
    #expect(backup.saveBeforeReplacingError == expected)
    #expect(backup.restoredOutcome == nil)
    #expect(app.catalogRestoreReloads == 0)
    #expect(!backup.isCreating)
  }

  @Test("replace: Replace Without Saving replaces with no save panel; Cancel at either question writes nothing")
  func replaceWithoutSaving() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    panel.file = try writeBackup(in: directory)
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    let backup = try #require(app.backup)
    let current = try CatalogBackups.counts(in: database)

    await BackupSection(model: backup).restoreAction()
    backup.cancelRestore()
    #expect(backup.pendingRestore == nil)
    await BackupSection(model: backup).restoreAction()
    await backup.confirmRestore()
    #expect(backup.restoreStep == .offerSave)
    backup.cancelRestore()
    #expect(backup.restoreStep == .confirm)
    // Replace Without Saving does nothing unless the second question is up.
    await backup.replaceWithoutSaving()
    #expect(try CatalogBackups.counts(in: database) == current)
    #expect(app.catalogRestoreReloads == 0)

    await BackupSection(model: backup).restoreAction()
    await backup.confirmRestore()
    await backup.replaceWithoutSaving()
    #expect(panel.calls == 3)
    #expect(panel.savePanelNames.isEmpty)
    #expect(try CatalogBackups.counts(in: database).assets == 3)
    #expect(app.catalogRestoreReloads == 1)
    #expect(backup.isOutcomePresented(by: .settings))
  }

  @Test("replace: while uploads or usage scans run, Restore says so and opens no panel")
  func busyRefuses() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let panel = PanelLog()
    let model = BackupModel(
      creator: CatalogBackupWriter(database: database),
      restorer: CatalogRestorer(database: database, credentialExists: { _ in true }),
      chooseBackupFile: { panel.choose() },
      isBusy: { true },
      chooseDestination: { _ in nil })
    await model.beginRestore(presenter: .settings)
    #expect(panel.calls == 0)
    #expect(model.restoreError == "Wait for uploads and usage scans to finish, then restore.")
    #expect(model.isErrorPresented(by: .settings))
  }

  /// The three Restore entries, each tried while `busy`: every one refuses,
  /// says why, and opens no panel.
  private func expectEntriesRefuse(
    _ app: PinaxAppModel, panel: PanelLog, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let backup = try #require(app.backup, sourceLocation: sourceLocation)
    let gallery = try #require(app.gallery, sourceLocation: sourceLocation)
    let entries: [(BackupPresenter, () async -> Void)] = [
      (.gallery, NoAssetsState(model: gallery).restoreAction),
      (.gallery, PinaxCommands(app: app).backupItems.importBackup),
      (.settings, BackupSection(model: backup).restoreAction),
    ]
    for (presenter, entry) in entries {
      await entry()
      #expect(panel.calls == 0, sourceLocation: sourceLocation)
      #expect(
        backup.restoreError == "Wait for uploads and usage scans to finish, then restore.",
        sourceLocation: sourceLocation)
      #expect(backup.isErrorPresented(by: presenter), sourceLocation: sourceLocation)
      #expect(backup.pendingRestore == nil, sourceLocation: sourceLocation)
      backup.dismissRestoreError()
    }
  }

  @Test("replace: while a usage scan runs, the app's own busy check refuses all three entries; once it ends they open the panel")
  func busyWhileScanning() async throws {
    let (database, directory) = try makeEmptyRestoreTarget()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    let scanner = HeldScanSynchronizer()
    let app = makeApp(database, panel: panel, defaults: defaults, usageSynchronizer: scanner)
    await app.start()
    let usageSync = try #require(app.usageSync)

    let scan = Task { await usageSync.scanNow(projects: ["blog"], presenter: .gallery) }
    await waitUntil { scanner.isScanning }
    #expect(usageSync.isSyncing)
    try await expectEntriesRefuse(app, panel: panel)

    scanner.release()
    await scan.value
    #expect(!usageSync.isSyncing)
    await BackupSection(model: try #require(app.backup)).restoreAction()
    #expect(panel.calls == 1)
  }

  @Test("replace: while the drop zone has an upload in flight, the app's own busy check refuses all three entries; once it settles they open the panel")
  func busyWhileUploading() async throws {
    let (empty, directory) = try makeEmptyRestoreTarget()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The same catalog, opened with a statement hook that parks the upload's
    // first read (its project list, off the main thread) until released: the
    // card stays pending for as long as the test needs, with no network.
    let hold = StatementHold(matching: #"FROM "project" ORDER BY "slug""#)
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.foreignKeysEnabled = true
    configuration.journalMode = .wal
    configuration.prepareDatabase { db in
      db.trace(options: .statement) { event in
        if case let .statement(statement) = event { hold.passing(statement.sql) }
      }
    }
    let database = try DatabasePool(path: empty.path, configuration: configuration)
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    let zone = try #require(app.dropZone?.model)

    hold.arm()
    // An empty catalog has no backend: once released, the upload fails
    // before any credential lookup or request.
    zone.drop(fileURLs: [directory.appendingPathComponent("pinax-busy.png")])
    await waitUntil { hold.isHolding }
    #expect(hold.isHolding)
    #expect(zone.cards.contains { $0.phase.isPending })
    try await expectEntriesRefuse(app, panel: panel)

    hold.release()
    await waitUntil { zone.cards.allSatisfy { !$0.phase.isPending } }
    #expect(zone.cards.allSatisfy { !$0.phase.isPending })
    await BackupSection(model: try #require(app.backup)).restoreAction()
    #expect(panel.calls == 1)
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("File ▸ Export is Settings' Save Backup…: the one save panel, today's name")
  func exportIsSaveBackup() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    await PinaxCommands(app: app).backupItems.exportBackup()
    #expect(panel.savePanelNames == [BackupModel.defaultFilename(for: Date())])
    #expect(panel.savePanelNames.first?.hasPrefix("pinax-backup-2") == true)
  }

  @Test("Confirm → restored without a restart: one reload, readers see the catalog, follow-ups counted")
  func restoreReloadsOnce() async throws {
    let (database, directory) = try makeEmptyRestoreTarget()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let panel = PanelLog()
    panel.file = try writeBackup(in: directory)
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    let backup = try #require(app.backup)
    let gallery = try #require(app.gallery)
    #expect(gallery.rows.isEmpty)

    await backup.beginRestore(presenter: .settings)
    let preview = try #require(backup.pendingRestore)
    #expect(backup.isConfirmationPresented(by: .settings))
    #expect(!backup.isConfirmationPresented(by: .gallery))
    #expect(preview.fileName == "pinax-backup-2026-10-07.json")
    #expect(preview.counts.assets == 3)
    #expect(preview.replacing == nil)
    let sheet = RestoreConfirmationSheet(preview: preview, cancel: {}, restore: {})
    #expect(sheet.rows.first { $0.label == "Projects" }?.value == "2 · blog, notes")
    #expect(sheet.rows.first { $0.label == "Backends" }?.value == "2 · r2, b2")
    #expect(sheet.summary.hasPrefix("pinax-backup-2026-10-07.json, saved "))
    #expect(sheet.title == "Restore Catalog from Backup?")
    #expect(app.catalogRestoreReloads == 0)
    #expect(try CatalogBackups.counts(in: database).isEmpty)

    // An empty catalog asks once: Restore restores.
    await backup.confirmRestore()
    #expect(app.catalogRestoreReloads == 1)
    #expect(backup.restoreError == nil)
    #expect(backup.isCatalogEmpty == false)
    #expect(app.isCatalogEmpty == false)
    #expect(backup.canRestore)
    #expect(!gallery.showsCatalogRestore)
    #expect(PinaxCommands(app: app).backupItems.canImport)
    #expect(PinaxCommands(app: app).backupItems.canExport)
    #expect(gallery.rows.count == 3)
    #expect(gallery.projects.map(\.slug).sorted() == ["blog", "notes"])
    #expect(try CatalogBackups.counts(in: database).assets == 3)

    let outcome = try #require(backup.restoredOutcome)
    #expect(backup.isOutcomePresented(by: .settings))
    #expect(outcome.followUps.backendsWithoutCredentials == ["b2"])
    #expect(outcome.followUps.projectsWithMissingSources.map(\.projectSlug) == ["notes"])
    let restored = CatalogRestoredSheet(outcome: outcome, openBackends: { _ in }, locate: { _ in }, done: {})
    #expect(restored.summary == "3 assets, 2 projects, 2 backends.")
    #expect(restored.followUps.map(\.action) == [.openBackends("b2"), .locate("notes")])

    // The follow-ups' buttons land on the right Settings page.
    app.showBackendSettings(slug: "b2")
    #expect(app.settingsTab == .backends)
    app.showProjectSettings(slug: "notes")
    #expect(app.settingsTab == .projects)
    #expect(app.projectSettings?.requestedSlug == "notes")
  }

  @Test("A newer or unreadable backup is refused before any confirmation, and nothing reloads")
  func versionErrorSkipsConfirmation() async throws {
    let (database, directory) = try makeEmptyRestoreTarget()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, suite) = try makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let good = try JSONSerialization.jsonObject(
      with: Data(contentsOf: try writeBackup(in: directory)))
    var newer = try #require(good as? [String: Any])
    newer["migrations"] = ["v1_initial", "v2_favorite_label", "v9_from_the_future"]
    let newerFile = directory.appendingPathComponent("newer.json")
    try JSONSerialization.data(withJSONObject: newer).write(to: newerFile)
    let junkFile = directory.appendingPathComponent("junk.json")
    try Data("{\"hello\": 1}".utf8).write(to: junkFile)

    let panel = PanelLog()
    let app = makeApp(database, panel: panel, defaults: defaults)
    await app.start()
    let backup = try #require(app.backup)

    panel.file = newerFile
    await backup.beginRestore(presenter: .gallery)
    #expect(backup.pendingRestore == nil)
    #expect(!backup.isConfirmationPresented(by: .gallery))
    #expect(backup.isErrorPresented(by: .gallery))
    #expect(backup.restoreError?.contains("newer version of Pinax") == true)
    backup.dismissRestoreError()

    panel.file = junkFile
    await backup.beginRestore(presenter: .settings)
    #expect(backup.pendingRestore == nil)
    #expect(backup.isErrorPresented(by: .settings))
    #expect(backup.restoreError == "This file is not a Pinax catalog backup, or it is damaged.")

    #expect(panel.calls == 2)
    #expect(app.catalogRestoreReloads == 0)
    #expect(try CatalogBackups.counts(in: database).isEmpty)
    #expect(backup.canRestore)
  }
}

/// A usage synchronizer whose scan runs until the test releases it.
private final class HeldScanSynchronizer: UsageSyncing, @unchecked Sendable {
  private let lock = NSLock()
  private var scanning = false
  private var released = false

  var isScanning: Bool { lock.withLock { scanning } }
  func release() { lock.withLock { released = true } }

  func projects() async throws -> [String] { ["blog"] }

  func sync(documentAt source: URL, project: String, allowEmpty: Bool) async throws
    -> UsageSyncResult
  {
    UsageSyncResult(scanID: 0, foundCount: 0)
  }

  func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome {
    lock.withLock { scanning = true }
    while !lock.withLock({ released }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    return UsageScanOutcome(sync: UsageSyncResult(scanID: 0, foundCount: 0), files: 0, skipped: 0)
  }
}

/// Once armed, parks the first statement off the main thread whose SQL
/// contains `fragment` until `release()` (or 10 s, so a miss cannot hang the
/// run). The main thread is never parked.
private final class StatementHold: @unchecked Sendable {
  private let fragment: String
  private let lock = NSLock()
  private var armed = false
  private var holding = false
  private let gate = DispatchSemaphore(value: 0)

  init(matching fragment: String) { self.fragment = fragment }

  var isHolding: Bool { lock.withLock { holding } }
  func arm() { lock.withLock { armed = true } }
  func release() { gate.signal() }

  func passing(_ sql: String) {
    guard !Thread.isMainThread, sql.contains(fragment) else { return }
    let park: Bool = lock.withLock {
      guard armed else { return false }
      armed = false
      holding = true
      return true
    }
    guard park else { return }
    _ = gate.wait(timeout: .now() + 10)
    lock.withLock { holding = false }
  }
}
