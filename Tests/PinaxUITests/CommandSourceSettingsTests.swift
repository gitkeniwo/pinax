import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Command sources in Settings ▸ Projects: adding and editing them, Test Run,
/// the confirmation's two buttons, the automatic-scan switches and the last
/// scan's line. Everything but the value-only tests goes through the app
/// model's own wiring; no menu or sheet is opened.
@MainActor
@Suite struct CommandSourceSettingsTests {
  @Test("+ offers Add Folder… and Add Command…, and a new command is stored at its first Set")
  func addMenuAndDraft() async throws {
    let fixture = try await Fixture(chosenFolder: "/work/site")
    defer { fixture.remove() }
    let settings = fixture.settings

    let items = try fixture.addMenu()
    #expect(items.map(\.title) == ["Add Folder…", "Add Command…"])
    try #require(items.last).action()
    let draft = try #require(settings.commandDraft)
    #expect(draft.project == "blog")
    #expect(draft.source == ProjectSource(label: "command", command: "", workingDirectory: ""))
    #expect(try fixture.stored().sources == [])

    var fields = CommandSourceFields(draft.source)
    fields.command = "export-usage"
    #expect(!CommandSourceEditor.canSet(fields, source: draft.source, isNew: true))
    fields.workingDirectory = "/work/site"
    #expect(CommandSourceEditor.canSet(fields, source: draft.source, isNew: true))

    // A refused Set keeps the draft to be corrected.
    var bad = fields
    bad.label = "my cms"
    #expect(settings.saveCommandSource(bad, replacing: nil, inProject: "blog") == nil)
    #expect(settings.saveError != nil)
    #expect(settings.commandDraft != nil)
    #expect(try fixture.stored().sources == [])

    let saved = try #require(settings.saveCommandSource(fields, replacing: nil, inProject: "blog"))
    #expect(saved == Self.command)
    #expect(settings.commandDraft == nil)
    #expect(try fixture.stored().sources == [Self.command])
    #expect(!CommandSourceEditor.canSet(CommandSourceFields(saved), source: saved, isNew: false))

    // The next one takes the next free label.
    try #require(try fixture.addMenu().last).action()
    #expect(settings.commandDraft?.source.label == "command-2")
    settings.discardCommandDraft()
    #expect(try fixture.stored().sources == [Self.command])

    try #require(try fixture.addMenu().first).action()
    #expect(try fixture.stored().sources.map(\.label) == ["command", "site"])
  }

  @Test("A command row says where it runs, and Locate… moves that folder only")
  func commandRow() async throws {
    let fixture = try await Fixture([Self.command], chosenRunFolder: "/work/moved")
    defer { fixture.remove() }
    #expect(SourceRowView.symbol(for: .command) == "terminal.fill")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let source = ProjectSource(
      label: "cms", command: "export-usage", workingDirectory: "\(home)/site")
    #expect(SourceRowView.runsInText(source) == "in ~/site")
    #expect(SourceRowView.help(for: source) == "export-usage\nin \(home)/site")

    #expect(fixture.settings.chooseRunDirectory(startingAt: "/work/site") == "/work/moved")
    fixture.settings.locateSource(label: "command", inProject: "blog")
    #expect(
      try fixture.stored().sources
        == [ProjectSource(label: "command", command: "export-usage", workingDirectory: "/work/moved")])
  }

  @Test("Test Run asks first, then runs only that command and keeps nothing it read")
  func testRunAsksThenRunsOneSource() async throws {
    let other = ProjectSource(label: "shop", command: "export-shop", workingDirectory: "/work/shop")
    let fixture = try await Fixture([Self.command, other])
    defer { fixture.remove() }
    let usageSync = fixture.usageSync
    let fields = CommandSourceFields(Self.command)

    fixture.settings.runCommandTest(fields, label: "command", inProject: "blog")
    await eventually { usageSync.pendingCommandApproval != nil }
    #expect(usageSync.pendingCommandApproval?.label == "command")
    #expect(usageSync.isCommandApprovalPresented(by: .settings))
    #expect(!usageSync.isCommandApprovalPresented(by: .gallery))
    #expect(fixture.runner.requests.isEmpty)

    await usageSync.confirmCommand()
    #expect(fixture.runner.requests.map(\.command) == ["export-usage"])
    let test = try #require(fixture.settings.commandTest(of: Self.command, inProject: "blog"))
    guard case .succeeded(references: 1, _) = test.outcome else {
      Issue.record("\(test.outcome)")
      return
    }
    #expect(try fixture.scanCount() == 0)
    #expect(usageSync.scanActivity == nil)

    // Allowed once, it runs without asking.
    fixture.settings.runCommandTest(fields, label: "command", inProject: "blog")
    await eventually { fixture.runner.requests.count == 2 }
    #expect(usageSync.pendingCommandApproval == nil)
  }

  @Test("Test Run Sets what was typed first, asks about that, and Cancel runs nothing")
  func testRunSetsFirst() async throws {
    let fixture = try await Fixture([Self.command])
    defer { fixture.remove() }
    fixture.approvals.approve(project: "blog", source: Self.command)
    var fields = CommandSourceFields(Self.command)
    fields.command = "export-usage --all"

    let ran = try #require(
      fixture.settings.runCommandTest(fields, label: "command", inProject: "blog"))
    #expect(try fixture.stored().sources == [ran])
    #expect(ran.command == "export-usage --all")
    await eventually { fixture.usageSync.pendingCommandApproval != nil }
    #expect(fixture.usageSync.pendingCommandApproval?.command == "export-usage --all")

    fixture.usageSync.cancelCommand()
    await fixture.usageSync.confirmCommand()
    #expect(fixture.runner.requests.isEmpty)
    #expect(!fixture.approvals.isApproved(project: "blog", source: ran))

    // Fields the catalog refuses run nothing.
    fields.label = "my cms"
    #expect(fixture.settings.runCommandTest(fields, label: "command", inProject: "blog") == nil)
    #expect(fixture.usageSync.pendingCommandApproval == nil)
  }

  @Test("A test run's result reads as references and seconds, or one line of the failure")
  func testRunResults() async throws {
    #expect(
      CommandTest(source: Self.command, outcome: .succeeded(references: 42, seconds: 1.3)).text
        == "42 references · 1.3 s")
    #expect(
      CommandTest(source: Self.command, outcome: .succeeded(references: 1, seconds: 0.04)).text
        == "1 reference · 0.0 s")

    let fixture = try await Fixture([Self.command])
    defer { fixture.remove() }
    fixture.approvals.approve(project: "blog", source: Self.command)
    fixture.runner.failure = .commandFailed(
      label: "command", status: 1,
      stderrTail: "at load (export.js:3)\nCannot find module 'contentful'\n")
    await fixture.usageSync.testCommand(project: "blog", source: Self.command, presenter: .settings)
    let failed = try #require(fixture.settings.commandTest(of: Self.command, inProject: "blog"))
    #expect(failed.text == "Exited with status 1: Cannot find module 'contentful'")
    #expect(CommandTestResult.help(failed).contains("at load (export.js:3)"))

    fixture.runner.failure = .commandFailed(label: "command", status: 2, stderrTail: "")
    await fixture.usageSync.testCommand(project: "blog", source: Self.command, presenter: .settings)
    #expect(
      fixture.settings.commandTest(of: Self.command, inProject: "blog")?.text
        == "Exited with status 2")

    fixture.runner.failure = .commandTimedOut(label: "command", seconds: 120)
    await fixture.usageSync.testCommand(project: "blog", source: Self.command, presenter: .settings)
    let timedOut = try #require(
      fixture.settings.commandTest(of: Self.command, inProject: "blog"))
    #expect(timedOut.text == "Did not finish within 120 seconds.")
    #expect(CommandTestResult.help(timedOut) == "Did not finish within 120 seconds.")
    #expect(CommandTestResult.lineLimit(timedOut) == 2)

    // A result is of the command as it ran.
    var edited = Self.command
    edited.command = "export-usage --all"
    #expect(fixture.settings.commandTest(of: edited, inProject: "blog") == nil)
  }

  @Test("A failure beside Test Run says what went wrong without naming the source")
  func failureWording() {
    let wording: [(CommandSourceError, String, String)] = [
      (
        .commandNotAllowed(label: "cms"),
        "The command has not been allowed to run.", "The command has not been allowed to run."
      ),
      (
        .workingDirectoryNotFound(label: "cms", path: "/work/gone"),
        "Working directory not found: /work/gone", "Working directory not found: /work/gone"
      ),
      (
        .commandFailed(label: "cms", status: 1, stderrTail: "first\nlast\n"),
        "Exited with status 1: last", "Exited with status 1\nfirst\nlast\n"
      ),
      (
        .commandTimedOut(label: "cms", seconds: 120),
        "Did not finish within 120 seconds.", "Did not finish within 120 seconds."
      ),
      (
        .commandOutputTooLarge(label: "cms"),
        "Printed too much output.", "Printed too much output."
      ),
      (
        .commandOutputInvalid(label: "cms", field: "refs"),
        "Output is invalid at 'refs'.", "Output is invalid at 'refs'."
      ),
    ]
    for (error, line, detail) in wording {
      #expect(CommandTest.failure(error) == .failed(line: line, detail: detail))
    }
    // The command line's words are as they were.
    #expect(
      CommandSourceError.commandOutputInvalid(label: "cms", field: "refs").description
        == "Source 'cms' command output is invalid at 'refs'.")
  }

  @Test("Both windows carry the confirmation, and each shows only what it asked for")
  func eachWindowPresentsItsOwn() async throws {
    let fixture = try await Fixture([Self.command])
    defer { fixture.remove() }
    await fixture.app.start()
    let gallery = collectViews(
      GalleryRootView(app: fixture.app).body, as: CommandApprovalConfirmation.self)
    #expect(gallery.map(\.presenter) == [.gallery])
    let window = collectViews(
      PinaxSettingsView(preferences: fixture.app.preferences, app: fixture.app).body,
      as: CommandApprovalConfirmation.self)
    #expect(window.map(\.presenter) == [.settings])
    for confirmation in gallery + window {
      #expect(confirmation.model === fixture.usageSync)
    }

    let usageSync = fixture.usageSync
    let fromGallery = CommandApprovalConfirmation.item(usageSync, presenter: .gallery)
    let fromSettings = CommandApprovalConfirmation.item(usageSync, presenter: .settings)
    await usageSync.scanNow(projects: ["blog"], presenter: .gallery)
    #expect(fromGallery.wrappedValue?.command == "export-usage")
    #expect(fromSettings.wrappedValue == nil)
  }

  @Test("Run allows what the sheet showed, even if the sheet closes first; the next command stays asked")
  func sheetButtons() async throws {
    let second = ProjectSource(label: "shop", command: "export-shop", workingDirectory: "/work/shop")
    let fixture = try await Fixture([Self.command, second])
    defer { fixture.remove() }
    let usageSync = fixture.usageSync
    let item = CommandApprovalConfirmation.item(usageSync, presenter: .gallery)

    await usageSync.scanNow(projects: ["blog"], presenter: .gallery)
    let first = try #require(item.wrappedValue)
    #expect(CommandApprovalSheet.directoryLine(first) == "in /work/site")
    let sheet = CommandApprovalConfirmation.sheet(first, model: usageSync)
    // SwiftUI may write the dismissal before the button's work starts.
    item.wrappedValue = nil
    sheet.run()
    await eventually { usageSync.pendingCommandApproval?.label == "shop" }
    #expect(fixture.approvals.isApproved(project: "blog", source: Self.command))
    // The first sheet's late dismissal leaves the second question standing.
    item.wrappedValue = nil
    #expect(usageSync.pendingCommandApproval?.label == "shop")

    // A Run for the sheet already answered allows nothing.
    await usageSync.confirmCommand(first)
    #expect(!fixture.approvals.isApproved(project: "blog", source: second))

    let next = try #require(item.wrappedValue)
    CommandApprovalConfirmation.sheet(next, model: usageSync).cancel()
    #expect(usageSync.pendingCommandApproval == nil)
    #expect(fixture.runner.requests.isEmpty)
    #expect(try fixture.scanCount() == 0)
  }

  @Test("The automation switches write meta.autoScan and wait for a first source")
  func automationGroup() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    #expect(!(try fixture.automation()).isEnabled)

    try CatalogConfiguration.setProjectSources(
      slug: "blog", [Self.command], in: fixture.database)
    fixture.settings.load()
    let group = try fixture.automation()
    #expect(group.isEnabled)
    #expect(!group.watch.wrappedValue)
    #expect(group.schedule.wrappedValue == .off)

    group.watch.wrappedValue = true
    #expect(try fixture.stored().autoScan == ProjectAutoScan(watch: true, schedule: .off))
    try fixture.automation().schedule.wrappedValue = .hourly
    #expect(try fixture.stored().autoScan == ProjectAutoScan(watch: true, schedule: .hourly))
    #expect(try fixture.automation().watch.wrappedValue)
    #expect(
      ProjectAutoScan.Schedule.allCases.map(ProjectAutomationGroup.title)
        == ["Off", "Hourly", "Daily"])
  }

  @Test("The last scan's line says automatic only while the latest scan is an automatic one")
  func automaticLastScan() async throws {
    let fixture = try await Fixture([Self.command])
    defer { fixture.remove() }
    fixture.approvals.approve(project: "blog", source: Self.command)
    let usageSync = fixture.usageSync
    let row = { try #require(fixture.settings.snapshot?.rows.first { $0.slug == "blog" }) }
    let line = {
      let row = try row()
      return ProjectSourcesSection.scanLine(
        for: row, automatic: fixture.settings.lastScanWasAutomatic(row),
        now: try #require(row.lastScanAt.flatMap(ISO8601DateFormatter().date(from:)))
          .addingTimeInterval(120),
        locale: Locale(identifier: "en_US"))
    }

    await usageSync.scanAutomatically(project: "blog", reason: .schedule)
    await eventually { (try? row().lastScanAt) != nil }
    #expect(try line() == "Scanned 2 minutes ago · automatic")
    // Kept on this Mac, past a relaunch.
    #expect(AutomaticScanMarks(defaults: fixture.defaults).scanID(project: "blog") == (try row().lastScanID))

    // One that fails leaves the line as it was.
    fixture.runner.failure = .commandTimedOut(label: "command", seconds: 60)
    await usageSync.scanAutomatically(project: "blog", reason: .schedule)
    fixture.settings.load()
    #expect(try line() == "Scanned 2 minutes ago · automatic")

    fixture.runner.failure = nil
    let before = try row().lastScanID
    await usageSync.scanNow(projects: ["blog"], presenter: .settings)
    await eventually { (try? row().lastScanID) != before }
    #expect(try line() == "Scanned 2 minutes ago")
  }

  // MARK: - Helpers

  private static let command = ProjectSource(
    label: "command", command: "export-usage", workingDirectory: "/work/site")

  /// An app on a catalog and preferences of its own, whose commands run
  /// nothing.
  @MainActor
  private struct Fixture {
    let database: DatabasePool
    let directory: URL
    let defaults: UserDefaults
    let removeDefaults: () -> Void
    let runner = CountingCommandRunner()
    let app: PinaxAppModel
    let settings: ProjectSettingsModel
    let usageSync: UsageSyncModel
    var approvals: CommandApprovalStore { app.commandApprovals }

    init(
      _ sources: [ProjectSource] = [], chosenFolder: String? = nil,
      chosenRunFolder: String? = nil
    ) async throws {
      (database, directory) = try makeUITestDatabase()
      (defaults, removeDefaults) = try makeScanDefaults()
      try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
      app = PinaxAppModel(
        dockIcon: inertDockIcon, defaults: defaults,
        databaseOpener: { [database] in database },
        commandRunner: runner, scanClock: ManualScanClock(),
        wakeNotifications: NotificationCenter(),
        chooseSourceFolder: { _ in chosenFolder.map { URL(fileURLWithPath: $0) } },
        chooseRunFolder: { _ in chosenRunFolder.map { URL(fileURLWithPath: $0) } })
      await app.start()
      settings = try #require(app.projectSettings)
      settings.load()
      usageSync = try #require(app.usageSync)
    }

    func stored() throws -> ProjectSettings {
      try CatalogConfiguration.projectSettings(slug: "blog", in: database)
    }

    func scanCount() throws -> Int {
      try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM scan") ?? -1 }
    }

    private func section() throws -> ProjectSourcesSection {
      ProjectSourcesSection(
        row: try #require(settings.snapshot?.rows.first { $0.slug == "blog" }),
        model: settings, isScanning: false)
    }

    func addMenu() throws -> [SettingsAddMenuItem] {
      let bars = collectViews(try section().body, as: SettingsAddRemoveButtons.self)
      return try #require(bars.first).addMenu
    }

    func automation() throws -> ProjectAutomationGroup {
      let groups = collectViews(try section().body, as: ProjectAutomationGroup.self)
      return try #require(groups.first)
    }

    func remove() {
      removeDefaults()
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
