import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

@MainActor
@Suite struct AutoScanTests {
  // MARK: - One line

  @Test("Automatic scans during a manual one wait, and one project waits only once")
  func automaticWaitsInLine() async {
    let scanner = GatedSynchronizer()
    let model = UsageSyncModel(synchronizer: scanner) { nil }
    let manual = Task { await model.scanNow(projects: ["blog"], presenter: .gallery) }
    await eventually { scanner.scans == ["blog"] }

    var asked = 0
    let automatic = (0..<3).map { _ in
      Task {
        asked += 1
        await model.scanAutomatically(project: "blog", reason: .watch)
      }
    }
    await eventually { asked == 3 }
    #expect(model.lengthOfLine == 2, "the running scan and one waiting")
    #expect(scanner.scans == ["blog"], "one at a time")

    scanner.release()
    await eventually { scanner.scans.count == 2 }
    #expect(model.isSyncing)
    scanner.release()
    await manual.value
    for task in automatic { await task.value }
    #expect(scanner.scans == ["blog", "blog"])
    #expect(!model.isSyncing)
  }

  @Test("Changes during an automatic scan bring exactly one more")
  func oneMoreAfterARunningAutomaticScan() async {
    let scanner = GatedSynchronizer()
    let model = UsageSyncModel(synchronizer: scanner) { nil }
    let first = Task { await model.scanAutomatically(project: "blog", reason: .watch) }
    await eventually { scanner.scans.count == 1 }
    var asked = 0
    let more = (0..<2).map { _ in
      Task {
        asked += 1
        await model.scanAutomatically(project: "blog", reason: .watch)
      }
    }
    await eventually { asked == 2 }
    scanner.holds = false
    await first.value
    for task in more { await task.value }
    #expect(scanner.scans == ["blog", "blog"])
  }

  @Test("Scan Now during an automatic scan is not dropped; asking twice for the waiting one joins it")
  func manualWaitsForAutomatic() async {
    let scanner = GatedSynchronizer()
    let model = UsageSyncModel(synchronizer: scanner) { nil }
    let automatic = Task { await model.scanAutomatically(project: "blog", reason: .schedule) }
    await eventually { scanner.scans == ["blog"] }
    var asked = 0
    let clicks = (0..<2).map { _ in
      Task {
        asked += 1
        await model.scanNow(projects: ["notes"], presenter: .settings)
      }
    }
    await eventually { asked == 2 }
    #expect(scanner.scans == ["blog"])
    scanner.holds = false
    await automatic.value
    for click in clicks { await click.value }
    #expect(scanner.scans == ["blog", "notes"])
    #expect(model.emptyScanPresenter == .settings)
  }

  @Test("Confirming an empty scan while an automatic one runs is not dropped")
  func confirmationWaitsForAutomatic() async {
    let scanner = GatedSynchronizer()
    scanner.holds = false
    scanner.error = UsageCatalogError.emptyScanRejected(previousFoundCount: 4)
    let model = UsageSyncModel(synchronizer: scanner) { nil }
    await model.scanNow(projects: ["blog"], presenter: .gallery)
    #expect(model.requiresEmptyScanConfirmation)

    scanner.error = nil
    scanner.holds = true
    scanner.release()
    let automatic = Task { await model.scanAutomatically(project: "notes", reason: .watch) }
    await eventually { scanner.scans.count == 2 }
    var asked = false
    let confirm = Task {
      asked = true
      await model.confirmEmptyScan()
    }
    await eventually { asked }
    scanner.holds = false
    await automatic.value
    await confirm.value
    #expect(scanner.scans == ["blog", "notes", "blog"])
    #expect(scanner.allowEmpty == [false, false, true])
  }

  // MARK: - Never asking

  @Test("An automatic empty scan changes nothing, asks nothing and says so on the status bar")
  func automaticEmptyScanOnlyReports() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("blog-src", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let post = source.appendingPathComponent("post.md")
    try "![a](https://img.example.com/blog/asset-0.png)\n".write(
      to: post, atomically: true, encoding: .utf8)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "src", path: source.path)], in: database)
    let model = UsageSyncModel(synchronizer: CatalogUsageSynchronizer(database: database)) { nil }
    var completed = 0
    model.onScanCompleted = { completed += 1 }

    await model.scanAutomatically(project: "blog", reason: .watch)
    #expect(model.scanActivity == .finished(project: "blog", references: 1))
    #expect(completed == 1)
    #expect(model.result == nil, "the Maintenance page's result is the user's own")

    try "nothing\n".write(to: post, atomically: true, encoding: .utf8)
    await model.scanAutomatically(project: "blog", reason: .watch)
    #expect(model.scanActivity == .emptyScanHeld(project: "blog", previousFoundCount: 1))
    #expect(
      model.scanActivity?.text
        == "blog found nothing where the last scan found 1. Scan Now to accept.")
    #expect(model.scanActivity?.isFailure == true)
    #expect(!model.requiresEmptyScanConfirmation)
    #expect(completed == 1)
    let summary = try await CatalogConfiguration.projectSummaries(in: database)
    #expect(summary.first { $0.slug == "blog" }?.liveUsageCount == 1)
  }

  @Test("An automatic failure is only a status line; a command's failure says what the command did")
  func failuresReachTheStatusBar() async {
    let scanner = GatedSynchronizer()
    scanner.holds = false
    let failure = CommandSourceError.commandFailed(label: "cms", status: 2, stderrTail: "boom")
    scanner.error = failure
    let model = UsageSyncModel(synchronizer: scanner) { nil }

    await model.scanAutomatically(project: "blog", reason: .schedule)
    #expect(model.scanActivity == .failed("blog: \(failure.description)"))
    #expect(model.errorMessage == nil)
    #expect(!model.requiresEmptyScanConfirmation)
    #expect(model.pendingCommandApproval == nil)

    await model.scanNow(projects: ["blog"], presenter: .settings)
    #expect(model.scanActivity == .failed(failure.description))
  }

  // MARK: - The app's own wiring

  @Test("The app schedules and watches from launch, through its own wiring")
  func appWiring() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("blog-src", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "src", path: source.path)], in: database)
    try CatalogConfiguration.setAutoScan(
      slug: "blog", ProjectAutoScan(schedule: .hourly), in: database)
    let (defaults, remove) = try makeScanDefaults()
    defer { remove() }
    let clock = ManualScanClock()
    let wake = NotificationCenter()
    let scanner = GatedSynchronizer()
    scanner.holds = false
    let app = PinaxAppModel(
      dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database },
      usageSynchronizer: { _ in scanner }, scanClock: clock, wakeNotifications: wake,
      chooseSourceFolder: { _ in nil })
    await app.start()
    let usageSync = try #require(app.usageSync)
    let engine = try #require(app.autoScan)
    await eventually { scanner.scans.count == 1 && !usageSync.isSyncing }

    // Asleep past the interval: the wake alone makes it up, once.
    clock.sleep(for: 5 * 3600)
    wake.post(name: NSWorkspace.didWakeNotification, object: nil)
    await eventually { scanner.scans.count == 2 && !usageSync.isSyncing }
    clock.advance(by: 10 * 60)
    #expect(!usageSync.isSyncing)
    #expect(scanner.scans.count == 2)

    // Turned on elsewhere: reading the Projects page again watches the folder.
    #expect(engine.watcher.watched.isEmpty)
    try CatalogConfiguration.setAutoScan(slug: "blog", ProjectAutoScan(watch: true), in: database)
    try #require(app.projectSettings).load()
    #expect(engine.watcher.watched.map(\.label) == ["src"])
    try "x".write(
      to: source.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)
    await eventually { engine.watcher.isPending(project: "blog") }
    clock.advance(by: ScanDebouncer.longestWait)
    await eventually { scanner.scans.count == 3 && !usageSync.isSyncing }

    // A folder that goes is said on the status bar.
    try FileManager.default.removeItem(at: source)
    await eventually {
      usageSync.scanActivity
        == .failed("blog: \(UsageScanError.sourceNotFound(label: "src", path: source.path).description)")
    }
    #expect(engine.watcher.watched.isEmpty)
    #expect(scanner.scans.count == 3)
  }
}
