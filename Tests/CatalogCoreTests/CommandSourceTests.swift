import Foundation
import GRDB
import Testing

@testable import CatalogCore

private let prefix = "https://img.example.com"
private let retired = "https://old.example.com"

/// A temporary catalog with project `blog`, a folder source folder `site`
/// and a scripts folder. Everything lives under one temporary directory.
private struct Fixture {
  let directory: URL
  let database: DatabasePool
  var site: URL { directory.appendingPathComponent("site", isDirectory: true) }
  var scripts: URL { directory.appendingPathComponent("scripts", isDirectory: true) }

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-command-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    for name in ["site", "scripts"] {
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://storage.example.com", bucket: "images", region: "auto",
      urlPrefix: retired, keychainReference: "backend.r2", to: database)
    _ = try CatalogConfiguration.setBackendURLPrefix(slug: "r2", urlPrefix: prefix, in: database)
    _ = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "", backendSlug: "r2", to: database)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }

  var folder: ProjectSource { ProjectSource(label: "site", path: site.path) }
  var command: ProjectSource {
    ProjectSource(label: "cms", command: "export-usage", workingDirectory: scripts.path)
  }

  func setSources(_ sources: [ProjectSource]) throws {
    try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
  }

  func write(_ name: String, _ text: String, in folder: URL) throws {
    try Data(text.utf8).write(to: folder.appendingPathComponent(name))
  }

  func meta() throws -> String {
    try database.read { db in
      try String.fetchOne(db, sql: "SELECT meta FROM project WHERE slug = 'blog'") ?? ""
    }
  }

  func setMeta(_ meta: String) throws {
    try database.write { db in
      try db.execute(sql: "UPDATE project SET meta = ? WHERE slug = 'blog'", arguments: [meta])
    }
  }

  func lastScanID() throws -> Int64? {
    try database.read { db in
      try Int64.fetchOne(db, sql: "SELECT last_scan_id FROM project WHERE slug = 'blog'")
    }
  }

  /// Runs a script written into `scripts`, with `/bin/sh` so that no
  /// shell setup of this machine's user is involved.
  func run(
    _ script: String, timeout: TimeInterval = 30, maximumOutput: Int = 1 << 20,
    environment: [String: String] = [:]
  ) throws -> Data {
    try write("run.sh", script, in: scripts)
    return try ShellCommandRunner(shell: "/bin/sh", timeout: timeout, maximumOutput: maximumOutput)
      .run(
        CommandSourceRequest(
          label: "cms", command: "/bin/sh ./run.sh", workingDirectory: scripts.path,
          environment: environment))
  }
}

private final class FakeRunner: CommandSourceRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [CommandSourceRequest] = []
  let result: Result<Data, CommandSourceError>

  init(_ output: String) { result = .success(Data(output.utf8)) }
  init(failing error: CommandSourceError) { result = .failure(error) }

  var requests: [CommandSourceRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func run(_ request: CommandSourceRequest) throws -> Data {
    lock.lock()
    recorded.append(request)
    lock.unlock()
    return try result.get()
  }
}

private struct CleanGit: GitStatusProviding {
  func status(of root: URL) -> SourceGitStatus { .clean }
}

private let output = """
  {"schema": 1, "source_rev": "v42", "refs": [
    {"raw_url": "https://img.example.com/a.png", "source_ref": "posts/hello", "kind": "markdown"},
    {"raw_url": "https://old.example.com/no-extension", "source_ref": "posts/hello"},
    {"raw_url": "https://img.example.com/a.png", "source_ref": "posts/hello", "kind": "markdown"},
    {"raw_url": "https://docs.example.org/guide/", "source_ref": "posts/hello"}
  ]}
  """

@Suite struct CommandSourceTests {
  // MARK: - Stored settings

  @Test("Folder sources are written back byte for byte")
  func folderMetaUnchanged() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let stored =
      #"{"other":1,"sources":[{"exclude":["drafts/**"],"include":[],"label":"site","path":"/Users/someone/site"}],"usageTracking":"tracked"}"#
    try fixture.setMeta(stored)
    let sources = ProjectSettings(meta: stored).sources
    #expect(sources.map(\.kind) == [.folder])
    try fixture.setSources(sources)
    #expect(try fixture.meta() == stored)
  }

  @Test("A command source round trips in its fixed shape, trimmed and standardized")
  func commandRoundTrip() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setSources([
      ProjectSource(
        label: "cms", command: "  node export.mjs \n", workingDirectory: "/Users/someone/blog/")
    ])
    #expect(
      try fixture.meta()
        == #"{"sources":[{"command":"node export.mjs","kind":"command","label":"cms","workingDirectory":"/Users/someone/blog"}]}"#
    )
    #expect(
      ProjectSettings(meta: try fixture.meta()).sources == [
        ProjectSource(
          label: "cms", command: "node export.mjs", workingDirectory: "/Users/someone/blog")
      ])
  }

  @Test("An unknown kind reads the whole list as no sources")
  func unknownKind() {
    let meta = #"{"sources":[{"label":"a","path":"/a"},{"kind":"feed","label":"b","path":"/b"}]}"#
    #expect(ProjectSettings(meta: meta).sources.isEmpty)
  }

  @Test("autoScan is off when missing or unreadable, and round trips")
  func autoScan() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sources = #""sources":[{"label":"a","path":"/a"}]"#
    for bad in [
      "", #","autoScan":true"#, #","autoScan":{"watch":true,"schedule":"weekly"}"#,
      #","autoScan":{"watch":1,"schedule":"daily"}"#, #","autoScan":{"watch":true}"#,
    ] {
      let settings = ProjectSettings(meta: "{\(sources)\(bad)}")
      #expect(settings.autoScan == .off, "\(bad)")
      #expect(settings.sources.count == 1)
    }
    try fixture.setMeta(#"{"x":1}"#)
    let value = ProjectAutoScan(watch: true, schedule: .hourly)
    let written = try CatalogConfiguration.setAutoScan(slug: "blog", value, in: fixture.database)
    #expect(written.autoScan == value)
    #expect(try fixture.meta() == #"{"autoScan":{"schedule":"hourly","watch":true},"x":1}"#)
  }

  @Test("Bad command sources are refused")
  func validation() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(throws: CatalogConfigurationError.duplicateSourceLabel("site")) {
      try fixture.setSources([
        fixture.folder, ProjectSource(label: "site", command: "x", workingDirectory: "/tmp"),
      ])
    }
    #expect(throws: CatalogConfigurationError.emptySourceCommand(label: "cms")) {
      try fixture.setSources([
        ProjectSource(label: "cms", command: " \n ", workingDirectory: "/tmp")
      ])
    }
    #expect(throws: CatalogConfigurationError.sourceCommandTooLong(label: "cms")) {
      try fixture.setSources([
        ProjectSource(
          label: "cms", command: String(repeating: "a", count: 4097), workingDirectory: "/tmp")
      ])
    }
    #expect(throws: CatalogConfigurationError.relativeWorkingDirectory("blog")) {
      try fixture.setSources([ProjectSource(label: "cms", command: "x", workingDirectory: "blog")])
    }
    #expect(try fixture.meta() == "{}")
  }

  // MARK: - Running

  @Test("The runner returns standard output, in the working directory, with the added variables")
  func runnerSuccess() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let data = try fixture.run(
      #"pwd -P; printf '%s|%s|%s' "$PINAX_PROJECT" "$PINAX_SOURCE" "$PINAX_URL_PREFIXES"; cat"#,
      environment: [
        "PINAX_PROJECT": "blog", "PINAX_SOURCE": "cms", "PINAX_URL_PREFIXES": "a\nb",
      ])
    // `/var` is a link to `/private/var`, which Foundation's own resolving hides.
    let resolved = try #require(realpath(fixture.scripts.path, nil))
    defer { free(resolved) }
    #expect(
      String(decoding: data, as: UTF8.self) == "\(String(cString: resolved))\nblog|cms|a\nb")
  }

  @Test("A failing command reports its status and the end of standard error")
  func runnerFailure() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect {
      try fixture.run(
        "i=0; while [ $i -lt 500 ]; do echo 'noise noise noise' >&2; i=$((i+1)); done\n"
          + "echo 'the last line' >&2; exit 1")
    } throws: { error in
      guard case let CommandSourceError.commandFailed(label, status, tail) = error else {
        return false
      }
      return label == "cms" && status == 1 && tail.hasSuffix("the last line")
        && tail.utf8.count <= ShellCommandRunner.errorTailLength
    }
  }

  @Test("A command out of time is ended with its whole process group")
  func runnerTimeout() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pidFile = fixture.scripts.appendingPathComponent("child.pid")
    #expect(throws: CommandSourceError.commandTimedOut(label: "cms", seconds: 1)) {
      try fixture.run("sleep 5 &\necho $! > child.pid\nwait", timeout: 1)
    }
    let pid = try #require(
      Int32(
        String(contentsOf: pidFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    // The orphan is reaped by launchd a moment after it ends.
    var alive = true
    for _ in 0..<50 where alive {
      alive = kill(pid, 0) == 0
      if alive { usleep(20_000) }
    }
    #expect(!alive)
    if alive { kill(pid, SIGKILL) }
  }

  @Test("A command that ignores SIGTERM is killed")
  func runnerIgnoredTerminate() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let start = Date()
    #expect(throws: CommandSourceError.commandTimedOut(label: "cms", seconds: 1)) {
      try fixture.run("trap '' TERM\nsleep 20", timeout: 1)
    }
    #expect(Date().timeIntervalSince(start) < 10)
  }

  @Test("Too much output ends the command")
  func runnerTooLarge() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(throws: CommandSourceError.commandOutputTooLarge(label: "cms")) {
      try fixture.run("while :; do echo 0123456789012345678901234567890; done", maximumOutput: 1024)
    }
  }

  @Test("A missing working directory is reported before anything runs")
  func runnerMissingDirectory() throws {
    #expect(throws: CommandSourceError.workingDirectoryNotFound(label: "cms", path: "/no/such")) {
      try ShellCommandRunner(shell: "/bin/sh").run(
        CommandSourceRequest(label: "cms", command: "true", workingDirectory: "/no/such"))
    }
  }

  @Test(
    "Output outside the contract names the field",
    arguments: [
      ("not json", "document"), (#"{"refs":[]}"#, "schema"), (#"{"schema":2,"refs":[]}"#, "schema"),
      (#"{"schema":1,"project":"other","refs":[]}"#, "project"), (#"{"schema":1}"#, "refs"),
      (#"{"schema":1,"source_rev":3,"refs":[]}"#, "source_rev"),
      (#"{"schema":1,"refs":[{"source_ref":"a"}]}"#, "refs[0].raw_url"),
      (#"{"schema":1,"refs":[{"raw_url":"u","source_ref":""}]}"#, "refs[0].source_ref"),
      (#"{"schema":1,"refs":[{"raw_url":"u","source_ref":"/a"}]}"#, "refs[0].source_ref"),
      (#"{"schema":1,"refs":[{"raw_url":"u","source_ref":"a","kind":1}]}"#, "refs[0].kind"),
    ])
  func invalidOutput(text: String, field: String) {
    #expect(throws: CommandSourceError.commandOutputInvalid(label: "cms", field: field)) {
      try CommandSourceOutput.parse(Data(text.utf8), label: "cms", project: "blog")
    }
  }

  @Test("A document made for usage sync is accepted as it is")
  func usageSyncDocument() throws {
    let document = UsageDocument(
      project: "blog", sourceRevision: "abc", coverage: ["x/*"],
      refs: [UsageReference(rawURL: "u", sourceReference: "a", kind: "html")])
    let parsed = try CommandSourceOutput.parse(
      JSONEncoder().encode(document), label: "cms", project: "blog")
    #expect(parsed.references == document.refs)
    #expect(parsed.sourceRevision == "abc")
  }

  // MARK: - Scanning

  @Test("Folder and command references merge into one document")
  func mergedScan() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("a.md", "![x](https://img.example.com/b.png)\n", in: fixture.site)
    try fixture.setSources([fixture.folder, fixture.command])
    let runner = FakeRunner(output)
    let scan = try UsageScanner.scan(
      project: "blog", in: fixture.database, commands: .allow, runner: runner)
    #expect(
      scan.document.refs == [
        UsageReference(
          rawURL: "\(prefix)/a.png", sourceReference: "cms/posts/hello", kind: "markdown"),
        UsageReference(
          rawURL: "\(retired)/no-extension", sourceReference: "cms/posts/hello", kind: "text"),
        UsageReference(
          rawURL: "\(prefix)/b.png", sourceReference: "site/a.md#L1", kind: "markdown"),
      ])
    #expect(scan.document.coverage.last == "cms/*")
    #expect(scan.document.sourceRevision == "cms:v42")
    #expect(scan.files == 1)
    #expect(
      runner.requests == [
        CommandSourceRequest(
          label: "cms", command: "export-usage", workingDirectory: fixture.scripts.path,
          environment: [
            "PINAX_PROJECT": "blog", "PINAX_SOURCE": "cms",
            "PINAX_URL_PREFIXES": "\(prefix)\n\(retired)",
          ])
      ])
  }

  @Test("By default no command runs and the catalog is left alone")
  func defaultDenies() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setSources([fixture.command])
    let runner = FakeRunner(output)
    #expect(throws: CommandSourceError.commandNotAllowed(label: "cms")) {
      let scan = try UsageScanner.scan(project: "blog", in: fixture.database, runner: runner)
      _ = try CatalogUsage.sync(scan.document, project: "blog", in: fixture.database)
    }
    #expect(runner.requests.isEmpty)
    #expect(try fixture.lastScanID() == nil)
  }

  @Test("One command that is not allowed keeps the others from running")
  func oneDenied() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setSources([
      fixture.command,
      ProjectSource(label: "other", command: "other", workingDirectory: fixture.scripts.path),
    ])
    let runner = FakeRunner(output)
    #expect(throws: CommandSourceError.commandNotAllowed(label: "other")) {
      try UsageScanner.scan(
        project: "blog", in: fixture.database,
        commands: CommandSourcePolicy { $0.label == "cms" }, runner: runner)
    }
    #expect(runner.requests.isEmpty)
  }

  @Test("A failed command keeps the previous scan as the latest")
  func failureKeepsPreviousScan() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setSources([fixture.command])
    let first = try UsageScanner.scan(
      project: "blog", in: fixture.database, commands: .allow, runner: FakeRunner(output))
    let synced = try CatalogUsage.sync(first.document, project: "blog", in: fixture.database)
    let failure = CommandSourceError.commandFailed(label: "cms", status: 1, stderrTail: "boom")
    #expect(throws: failure) {
      let scan = try UsageScanner.scan(
        project: "blog", in: fixture.database, commands: .allow,
        runner: FakeRunner(failing: failure))
      _ = try CatalogUsage.sync(scan.document, project: "blog", in: fixture.database)
    }
    #expect(try fixture.lastScanID() == synced.scanID)
  }

  // MARK: - Rewriting

  @Test("A rewrite writes folder sources only, and its rescan follows the policy", arguments: [false, true])
  func rewrite(allowed: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("a.md", "![x](\(retired)/a.png)\n", in: fixture.site)
    try fixture.setSources([fixture.folder, fixture.command])
    let preview = try await RewriteRuns.preview(
      targets: [
        RewriteRunTarget(project: "blog", rules: [.prefix(from: retired, to: prefix)])
      ],
      database: fixture.database, git: CleanGit())
    #expect(preview.plans.flatMap(\.sources).map(\.label) == ["site"])
    #expect(preview.plans.flatMap(\.files).map(\.sourceLabel) == ["site"])

    let runner = FakeRunner(output)
    let backups = fixture.directory.appendingPathComponent("backups")
    let result =
      allowed
      ? try RewriteRuns.apply(
        fromRun: preview.runID, allowedSources: [], database: fixture.database, git: CleanGit(),
        backupRoot: backups, commands: .allow, runner: runner)
      : try RewriteRuns.apply(
        fromRun: preview.runID, allowedSources: [], database: fixture.database, git: CleanGit(),
        backupRoot: backups, runner: runner)
    #expect(result.summary.written == 1)
    #expect(runner.requests.count == (allowed ? 1 : 0))
    let rescans = try RunLog.events(of: result.runID, in: fixture.database).compactMap {
      record -> String? in
      switch record.event {
      case .rescanFinished: return "finished"
      case let .rescanFailed(event): return event.error
      default: return nil
      }
    }
    #expect(
      rescans
        == [
          allowed
            ? "finished" : CommandSourceError.commandNotAllowed(label: "cms").description
        ])
  }
}
