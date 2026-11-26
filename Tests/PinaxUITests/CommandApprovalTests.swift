import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

@MainActor
@Suite struct CommandApprovalTests {
  private static let command = ProjectSource(
    label: "cms", command: "export-usage", workingDirectory: "/work/site")

  @Test("An approval covers one project's label, command and directory; any change asks again")
  func approvalCoversExactlyWhatWasShown() throws {
    let (defaults, remove) = try makeScanDefaults()
    defer { remove() }
    let store = CommandApprovalStore(defaults: defaults)
    let source = Self.command
    #expect(!store.isApproved(project: "blog", source: source))
    store.approve(project: "blog", source: source)
    #expect(store.isApproved(project: "blog", source: source))
    #expect(CommandApprovalStore(defaults: defaults).isApproved(project: "blog", source: source))
    #expect(store.policy.allows(source, in: "blog"))
    #expect(!store.policy.allows(source, in: "notes"))

    var changed = source
    changed.command = "export-usage --all"
    #expect(!store.isApproved(project: "blog", source: changed))
    changed = source
    changed.workingDirectory = "/work/other"
    #expect(!store.isApproved(project: "blog", source: changed))
    changed = source
    changed.label = "cms-2"
    #expect(!store.isApproved(project: "blog", source: changed))

    store.approve(project: "notes", source: source)
    store.revokeAll(project: "blog")
    #expect(!store.isApproved(project: "blog", source: source))
    #expect(store.isApproved(project: "notes", source: source))
  }

  @Test("Scan Now stops at a command not yet allowed; Cancel runs nothing, Run allows it and scans")
  func manualScanAsks() async throws {
    let fixture = try Fixture([Self.command])
    defer { fixture.remove() }
    let model = fixture.model

    await model.scanNow(projects: ["blog"], presenter: .gallery)
    let expected = PendingCommandApproval(
      project: "blog", label: "cms", command: "export-usage", workingDirectory: "/work/site")
    #expect(model.pendingCommandApproval == expected)
    #expect(model.isCommandApprovalPresented(by: .gallery))
    #expect(!model.isCommandApprovalPresented(by: .settings))
    #expect(model.scanActivity == nil)
    #expect(fixture.runner.requests.isEmpty)

    model.cancelCommand()
    #expect(model.pendingCommandApproval == nil)
    await model.confirmCommand()
    #expect(fixture.runner.requests.isEmpty)
    #expect(!fixture.approvals.isApproved(project: "blog", source: Self.command))

    await model.scanNow(projects: ["blog"], presenter: .settings)
    await model.confirmCommand()
    #expect(model.pendingCommandApproval == nil)
    #expect(fixture.approvals.isApproved(project: "blog", source: Self.command))
    #expect(fixture.runner.requests.map(\.command) == ["export-usage"])
    #expect(model.scanActivity == .finished(project: "blog", references: 1))
  }

  @Test("With two commands, each is asked for and nothing runs until both are allowed")
  func everyCommandIsAsked() async throws {
    let second = ProjectSource(label: "shop", command: "export-shop", workingDirectory: "/work/shop")
    let fixture = try Fixture([Self.command, second])
    defer { fixture.remove() }
    await fixture.model.scanNow(projects: ["blog"], presenter: .settings)
    #expect(fixture.model.pendingCommandApproval?.label == "cms")
    await fixture.model.confirmCommand()
    #expect(fixture.model.pendingCommandApproval?.label == "shop")
    #expect(fixture.runner.requests.isEmpty)
    await fixture.model.confirmCommand()
    #expect(fixture.runner.requests.map(\.label) == ["cms", "shop"])
  }

  @Test("An automatic scan runs no command not yet allowed and asks nothing")
  func automaticScanNeverAsks() async throws {
    let fixture = try Fixture([Self.command])
    defer { fixture.remove() }
    await fixture.model.scanAutomatically(project: "blog", reason: .schedule)
    #expect(fixture.model.scanActivity == .commandNeedsApproval(project: "blog", label: "cms"))
    #expect(
      fixture.model.scanActivity?.text == "blog: command “cms” needs confirmation. Open Settings…")
    #expect(fixture.model.pendingCommandApproval == nil)
    #expect(fixture.runner.requests.isEmpty)

    fixture.approvals.approve(project: "blog", source: Self.command)
    await fixture.model.scanAutomatically(project: "blog", reason: .schedule)
    #expect(fixture.runner.requests.count == 1)
  }

  @Test("Scan All lists a command not yet allowed among the failures")
  func scanAllListsIt() async throws {
    let fixture = try Fixture([Self.command])
    defer { fixture.remove() }
    await fixture.model.scanNow(projects: ["blog", "notes"], presenter: .gallery)
    guard case let .summary(_, failures) = fixture.model.scanActivity else {
      Issue.record("\(String(describing: fixture.model.scanActivity))")
      return
    }
    #expect(
      failures.first { $0.project == "blog" }?.message
        == CommandSourceError.commandNotAllowed(label: "cms").description)
    #expect(fixture.model.pendingCommandApproval == nil)
  }

  @Test("The app's scans and both applies' rescans ask the same approvals")
  func appWiring() async throws {
    let fixture = try Fixture([Self.command])
    defer { fixture.remove() }
    let app = PinaxAppModel(
      dockIcon: inertDockIcon, defaults: fixture.defaults,
      databaseOpener: { [database = fixture.database] in database },
      commandRunner: fixture.runner, scanClock: ManualScanClock(),
      wakeNotifications: NotificationCenter(), chooseSourceFolder: { _ in nil })
    await app.start()
    let usageSync = try #require(app.usageSync)
    let gallery = try #require(app.gallery)
    let domain = try #require(gallery.domainMigration?.migrator as? CatalogDomainMigrator)
    let externals = try #require(gallery.externals.migrator as? CatalogExternalsMigrator)
    #expect(!domain.commands.allows(Self.command, in: "blog"))
    #expect(!externals.commands.allows(Self.command, in: "blog"))

    await usageSync.scanNow(projects: ["blog"], presenter: .gallery)
    #expect(usageSync.pendingCommandApproval?.label == "cms")
    await usageSync.confirmCommand()
    #expect(fixture.runner.requests.count == 1)
    #expect(domain.commands.allows(Self.command, in: "blog"))
    #expect(externals.commands.allows(Self.command, in: "blog"))
  }

  @Test("A domain move's rescan runs the allowed command")
  func domainMoveRescanRunsAllowedCommands() async throws {
    let fixture = try Fixture([])
    defer { fixture.remove() }
    let site = fixture.directory.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    try "![a](https://img.example.com/blog/asset-0.png)\n".write(
      to: site.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: site.path), Self.command],
      in: fixture.database)
    try seedAsset(fixture.database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    fixture.approvals.approve(project: "blog", source: Self.command)
    let migrator = CatalogDomainMigrator(
      database: fixture.database, verifier: AlwaysThere(), git: AlwaysClean(),
      commands: fixture.approvals.policy, runner: fixture.runner)

    let preview = try await migrator.preview(
      backend: "r2", to: "https://cdn.example.com", from: [],
      projects: ["blog"], keepOldDomains: false, cancellation: ExternalMigrationCancellation(),
      progress: { _ in })
    _ = try await migrator.apply(fromRun: preview.runID, allowedSources: [], phase: { _ in })

    #expect(fixture.runner.requests.map(\.label) == ["cms"])
    let kinds = try RunLog.events(of: preview.runID + 1, in: fixture.database).map {
      String(describing: $0.event)
    }
    #expect(kinds.contains { $0.hasPrefix("rescanFinished") }, "\(kinds)")
  }

  // MARK: - Helpers

  @MainActor
  private struct Fixture {
    let database: DatabasePool
    let directory: URL
    let defaults: UserDefaults
    let removeDefaults: () -> Void
    let approvals: CommandApprovalStore
    let runner = CountingCommandRunner()
    let model: UsageSyncModel

    init(_ sources: [ProjectSource]) throws {
      (database, directory) = try makeUITestDatabase()
      (defaults, removeDefaults) = try makeScanDefaults()
      approvals = CommandApprovalStore(defaults: defaults)
      try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
      model = UsageSyncModel(
        synchronizer: CatalogUsageSynchronizer(
          database: database, approvals: approvals, runner: runner),
        approvals: approvals, chooseSource: { nil })
    }

    func remove() {
      removeDefaults()
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

private struct AlwaysThere: RewriteTargetVerifying {
  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    .ok(sha256: expectedSHA256 ?? "fetched")
  }
}

private struct AlwaysClean: GitStatusProviding {
  func status(of root: URL) -> SourceGitStatus { .clean }
}
