import CatalogCore
import Foundation
import GRDB
import Testing

/// Run records and the preview → apply orchestrator. Git is
/// a stub; a repository is an empty `.git` folder, which is all
/// `changed_files_by_repo` looks for.
private let old = "https://img.old.com"
private let new = "https://img.new.com"
private let move = RewriteRule.prefix(from: old, to: new)
private let shaA = String(repeating: "a", count: 64)

/// A temporary catalog with backend `r2` (prefix `old`), asset `2024/a.png`
/// and project `blog` whose source `site` lives in `repo/site` (a git
/// repository) and `notes` in `loose/notes` (outside git).
private struct Fixture {
  let directory: URL
  let database: DatabasePool
  let git = StubGit()

  init(projects: [String] = ["blog"]) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-runs-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
    database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://storage.example.com", bucket: "images", region: "auto",
      urlPrefix: old, keychainReference: "backend.r2", to: database)
    for slug in projects {
      _ = try CatalogConfiguration.addProject(
        slug: slug, name: slug, keyPrefix: "", backendSlug: "r2", to: database)
      try CatalogConfiguration.setProjectSources(
        slug: slug, [source("site", in: slug), source("notes", in: slug)], in: database)
    }
    try database.write { db in
      _ = try Asset(
        sha256: shaA, backendID: 1, key: "2024/a.png", byteSize: 1, mime: "image/png",
        uploadedAt: "2024-01-01T00:00:00Z", createdAt: "2024-01-01T00:00:00Z",
        updatedAt: "2024-01-01T00:00:00Z"
      ).insertAndFetch(db)
    }
  }

  func source(_ label: String, in project: String = "blog") -> ProjectSource {
    let folder = label == "site" ? "repo/\(project)-site" : "loose/\(project)-notes"
    let url = directory.appendingPathComponent(folder, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return ProjectSource(label: label, path: url.path)
  }

  func path(_ label: String, _ file: String, in project: String = "blog") -> String {
    (source(label, in: project).path as NSString).appendingPathComponent(file)
  }

  func write(_ label: String, _ file: String, _ text: String, in project: String = "blog") throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path(label, file, in: project)))
  }

  func read(_ label: String, _ file: String, in project: String = "blog") throws -> String {
    try String(contentsOfFile: path(label, file, in: project), encoding: .utf8)
  }

  func rows(_ sql: String) throws -> [Row] {
    try database.read { try Row.fetchAll($0, sql: sql) }
  }

  func tableExists(_ name: String) throws -> Bool {
    try database.read { try $0.tableExists(name) }
  }

  func runCount() throws -> Int {
    try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM run") ?? 0 }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Git status by source path, `.clean` by default; `onStatus` runs on
/// every call with the call's number.
private final class StubGit: GitStatusProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [String: SourceGitStatus] = [:]
  private var calls = 0
  var onStatus: ((Int) -> Void)?

  func set(_ status: SourceGitStatus, for source: ProjectSource) {
    lock.lock()
    defer { lock.unlock() }
    statuses[source.path] = status
  }

  func status(of root: URL) -> SourceGitStatus {
    lock.lock()
    calls += 1
    let call = calls
    let status = statuses[root.path] ?? .clean
    lock.unlock()
    onStatus?(call)
    return status
  }
}

private struct StubVerifier: RewriteTargetVerifying {
  let results: [String: TargetVerification]

  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    results[url] ?? .ok(sha256: expectedSHA256 ?? "")
  }
}

private func types(_ events: [RunEventRecord]) -> [String] { events.map(\.event.type) }

@Suite struct RunLogTests {
  @Test("v5_run creates both tables; backups leave them out and restore leaves them alone")
  func migrationAndBackups() async throws {
    let source = try Fixture()
    defer { source.remove() }
    #expect(try source.tableExists("run") && source.tableExists("run_event"))
    let backup = try CatalogBackups.create(from: source.database)
    #expect(backup.migrations.contains("v5_run"))
    let encoded = String(decoding: try JSONEncoder().encode(backup), as: UTF8.self)
    #expect(!encoded.contains("\"run"))

    // A catalog with its own runs takes the backup with `replace`; its runs
    // stay exactly as they were.
    let target = try Fixture()
    defer { target.remove() }
    try target.write("site", "a.md", "\(old)/2024/a.png\n")
    _ = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move])], database: target.database,
      git: target.git)
    let before = (try target.rows("SELECT * FROM run"), try target.rows("SELECT * FROM run_event"))
    #expect(before.0.count == 1 && before.1.count > 3)
    try CatalogBackups.replace(
      backup, into: target.database, confirmed: try CatalogBackups.counts(in: target.database))
    let after = (try target.rows("SELECT * FROM run"), try target.rows("SELECT * FROM run_event"))
    #expect(after.0 == before.0)
    #expect(after.1 == before.1)
  }

  @Test("Every event survives type + data and Codable; JSONL has the five keys")
  func eventCoding() throws {
    let events: [RunEvent] = [
      .runStarted(RewriteRunParams(targets: [RewriteRunTarget(project: "blog", rules: [move, .exact(from: "https://x.com/a?w=1", to: "https://y.com/a")])], allowedSources: ["blog/notes"], verify: true)),
      .sourceStatus(SourceStatusEvent(project: "blog", source: "site", git: .dirty(paths: ["a.md"]))),
      .sourceStatus(SourceStatusEvent(project: "blog", source: "site", git: .unknown(reason: "timeout"))),
      .filePlanned(FilePlannedEvent(project: "blog", source: "site", path: "a.md", sha256: shaA, edits: 2, editsDigest: "d")),
      .editSkipped(EditSkippedEvent(project: "blog", source: "site", path: "a.md", line: 3, reason: "unsafe_target")),
      .protocolRelativeFound(ProtocolRelativeEvent(project: "blog", source: "site", path: "a.md", host: "img.old.com", count: 2)),
      .targetVerified(TargetVerifiedEvent(url: "\(new)/a.png", expectedSHA256: shaA, verification: .mismatch(expected: shaA, actual: "b"))),
      .targetVerified(TargetVerifiedEvent(url: "\(new)/b.png", expectedSHA256: nil, verification: .unreachable(reason: "404"))),
      .prefixChanged(PrefixChangedEvent(backend: "r2", from: old, to: new)),
      .fileWritten(FileWrittenEvent(project: "blog", source: "site", path: "a.md", beforeSHA256: shaA, afterSHA256: "b", edits: 2, backupPath: "/b/a.md")),
      .fileSkipped(FileSkippedEvent(project: "blog", source: "site", path: "a.md", reason: "symlink")),
      .fileFailed(FileFailedEvent(project: "blog", source: "site", path: "a.md", error: "disk full")),
      .rescanFinished(RescanFinishedEvent(project: "blog", refs: 4, files: 2)),
      .rescanFailed(RescanFailedEvent(project: "blog", error: "boom")),
      .runFinished(RewriteRunSummary(files: 1, edits: 2, skippedEdits: ["unsafe_target": 1], written: 1, errors: 0, changedFilesByRepo: ["/r": ["a.md"], "null": ["b.md"]])),
    ]
    for event in events {
      #expect(try RunEvent(type: event.type, data: try event.dataJSON()) == event)
      #expect(try JSONDecoder().decode(RunEvent.self, from: JSONEncoder().encode(event)) == event)
    }
    let record = RunEventRecord(
      seq: 7, at: "2026-10-29T12:00:00.000Z", level: .warning,
      event: .fileSkipped(FileSkippedEvent(project: "blog", source: "site", path: "notes.md", reason: "changed_since_plan")))
    #expect(
      record.jsonLine
        == #"{"at":"2026-10-29T12:00:00.000Z","data":{"path":"notes.md","project":"blog","reason":"changed_since_plan","source":"site"},"level":"warning","seq":7,"type":"file_skipped"}"#)
    #expect(
      try events.last!.dataJSON().contains(#""changed_files_by_repo":{"/r":["a.md"],"null":["b.md"]}"#))
  }

  @Test("summaryLine reads as expected; each event has its level")
  func linesAndLevels() {
    let written = RunEvent.fileWritten(FileWrittenEvent(
      project: "blog", source: "site", path: "2025-12-31-change-bike-inner-tube.md", beforeSHA256: "a",
      afterSHA256: "b", edits: 10, backupPath: nil))
    #expect(written.summaryLine == "Rewrote 2025-12-31-change-bike-inner-tube.md · 10 refs")
    let skipped = RunEvent.fileSkipped(FileSkippedEvent(
      project: "blog", source: "site", path: "notes.md", reason: "changed_since_plan"))
    #expect(skipped.summaryLine == "Skipped notes.md — changed since the preview")
    #expect(written.level == .info)
    #expect(skipped.level == .warning)
    #expect(RunEvent.sourceStatus(SourceStatusEvent(project: "b", source: "s", git: .clean)).level == .info)
    #expect(RunEvent.sourceStatus(SourceStatusEvent(project: "b", source: "s", git: .notGit)).level == .warning)
    #expect(RunEvent.targetVerified(TargetVerifiedEvent(url: "u", expectedSHA256: nil, verification: .ok(sha256: "a"))).level == .info)
    #expect(RunEvent.targetVerified(TargetVerifiedEvent(url: "u", expectedSHA256: nil, verification: .unreachable(reason: "x"))).level == .error)
    #expect(RunEvent.runFinished(RewriteRunSummary(errors: 0)).level == .info)
    #expect(RunEvent.runFinished(RewriteRunSummary(errors: 1)).level == .error)
  }

  @Test("A running run whose process is gone is marked interrupted when listed")
  func interrupted() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let alive = try RunLog.start(kind: .rewrite, dryRun: true, params: ["x": 1], in: fixture.database)
    let dead = try RunLog.start(kind: .rewrite, dryRun: true, params: ["x": 1], in: fixture.database)
    try fixture.database.write { db in
      try db.execute(sql: "UPDATE run SET pid = 999999 WHERE id = ?", arguments: [dead])
    }
    let runs = try RunLog.runs(in: fixture.database, processExists: { $0 != 999999 })
    #expect(runs.first { $0.id == alive }?.state == .running)
    #expect(runs.first { $0.id == dead }?.state == .interrupted)
    // Stored, not just reported.
    #expect(try RunLog.run(dead, in: fixture.database, processExists: { _ in true })?.state == .interrupted)
    // Our own pid is alive with the real check.
    #expect(try RunLog.run(alive, in: fixture.database)?.state == .running)
  }
}

@Suite struct RewriteRunsTests {
  @Test("Preview: a finished dry run with source, file, skip and protocol-relative events")
  func preview() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("site", "a.md", "![](\(old)/2024/a.png) [x](\(old)/2024/b.png).\n//img.old.com/c.png\n")
    try fixture.write("site", "b.md", "nothing here\n")
    fixture.git.set(.notGit, for: fixture.source("notes"))
    let result = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move])], database: fixture.database,
      git: fixture.git)
    let run = try #require(try RunLog.run(result.runID, in: fixture.database))
    #expect(run.dryRun && run.state == .finished && run.fromRunID == nil && run.finishedAt != nil)
    let events = try RunLog.events(of: result.runID, in: fixture.database)
    #expect(events.map(\.event) == result.events)
    #expect(events.map(\.seq) == Array(1...events.count))
    #expect(
      types(events) == [
        "run_started", "source_status", "source_status", "file_planned", "protocol_relative_found",
        "run_finished",
      ])
    #expect(events[2].level == .warning)
    guard case let .filePlanned(planned) = events[3].event else { return }
    let file = try #require(result.plans[0].files.first)
    #expect(planned.path == "a.md" && planned.edits == 2 && planned.sha256 == file.originalSHA256)
    #expect(planned.editsDigest == RewriteRuns.editsDigest(file.edits))
    #expect(result.summary == RewriteRunSummary(files: 1, edits: 2, protocolRelative: 1))
    let stored = try JSONDecoder().decode(RewriteRunSummary.self, from: Data(try #require(run.summary).utf8))
    #expect(stored == result.summary)
    #expect(try fixture.read("site", "a.md").contains(old))
  }

  @Test("Preview --verify: one target_verified per new URL; a mismatch makes the run an error")
  func previewVerify() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("site", "a.md", "\(old)/2024/a.png \(old)/2024/b.png \(old)/2024/a.png\n")
    let verifier = StubVerifier(results: [
      "\(new)/2024/a.png": .mismatch(expected: shaA, actual: "f"),
      "\(new)/2024/b.png": .unreachable(reason: "404"),
    ])
    let result = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move])], verifier: verifier,
      database: fixture.database, git: fixture.git)
    let verified = result.events.compactMap { event -> TargetVerifiedEvent? in
      if case let .targetVerified(value) = event { return value } else { return nil }
    }
    #expect(verified.map(\.url) == ["\(new)/2024/a.png", "\(new)/2024/b.png"])
    #expect(verified[0].expectedSHA256 == shaA && verified[0].result == .mismatch)
    #expect(verified[1].result == .unreachable && verified[1].reason == "404")
    #expect(result.summary.verified == ["mismatch": 1, "unreachable": 1])
    #expect(result.summary.errors == 2)
    #expect(result.events.last?.level == .error)
  }

  @Test("Apply: writes, rescans, records changed_files_by_repo; re-preview finds nothing")
  func apply() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("site", "a.md", "\(old)/2024/a.png and \(old)/2024/a.png\n")
    try fixture.write("notes", "n.md", "\(old)/2024/b.png\n")
    fixture.git.set(.notGit, for: fixture.source("notes"))
    let preview = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move])], database: fixture.database,
      git: fixture.git)
    let backups = fixture.directory.appendingPathComponent("backups")
    let result = try RewriteRuns.apply(
      fromRun: preview.runID, allowedSources: ["blog/notes"], database: fixture.database,
      git: fixture.git, backupRoot: backups)
    #expect(try fixture.read("site", "a.md") == "\(new)/2024/a.png and \(new)/2024/a.png\n")
    #expect(try fixture.read("notes", "n.md") == "\(new)/2024/b.png\n")
    // Only the allowed unclean source is backed up, under the run's id.
    let backup = backups.appendingPathComponent("\(result.runID)/notes/n.md")
    #expect(try String(contentsOf: backup, encoding: .utf8) == "\(old)/2024/b.png\n")
    #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent("\(result.runID)/site").path))

    let run = try #require(try RunLog.run(result.runID, in: fixture.database))
    #expect(!run.dryRun && run.fromRunID == preview.runID && run.state == .finished)
    let events = try RunLog.events(of: result.runID, in: fixture.database)
    #expect(
      types(events) == [
        "run_started", "source_status", "source_status", "file_written", "file_written",
        "rescan_finished", "run_finished",
      ])
    guard case let .runStarted(params) = events[0].event else { return }
    #expect(params.allowedSources == ["blog/notes"])
    guard case let .rescanFinished(rescan) = events[5].event else { return }
    // The scan counts a URL repeated in one file once.
    #expect(rescan == RescanFinishedEvent(project: "blog", refs: 2, files: 2))
    let repository = fixture.directory.appendingPathComponent("repo").path
    #expect(result.summary.changedFilesByRepo == [repository: ["blog-site/a.md"], "null": ["n.md"]])
    #expect(result.summary.written == 2 && result.summary.failed == 0 && result.summary.errors == 0)

    // The rescan went through `CatalogUsage.sync`: usage now holds the new URLs.
    let report = try await CatalogUsage.report(project: "blog", in: fixture.database)
    #expect(Set(report.items.map(\.rawURL)) == ["\(new)/2024/a.png", "\(new)/2024/b.png"])

    let again = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move])], database: fixture.database,
      git: fixture.git)
    #expect(again.summary.edits == 0)
  }

  @Test("Apply: the base run must exist and be a finished preview")
  func baseRun() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("site", "a.md", "\(old)/2024/a.png\n")
    #expect(throws: RewriteRunError.runNotFound(42)) {
      try RewriteRuns.apply(fromRun: 42, allowedSources: [], database: fixture.database, git: fixture.git)
    }
    let preview = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move])], database: fixture.database,
      git: fixture.git)
    let applied = try RewriteRuns.apply(
      fromRun: preview.runID, allowedSources: [], database: fixture.database, git: fixture.git,
      backupRoot: fixture.directory.appendingPathComponent("b"))
    #expect(throws: RewriteRunError.notAPreview(applied.runID, reason: "it is not a preview")) {
      try RewriteRuns.apply(fromRun: applied.runID, allowedSources: [], database: fixture.database, git: fixture.git)
    }
    let running = try RunLog.start(kind: .rewrite, dryRun: true, params: RewriteRunParams(targets: []), in: fixture.database)
    #expect(throws: RewriteRunError.notAPreview(running, reason: "the preview is running")) {
      try RewriteRuns.apply(fromRun: running, allowedSources: [], database: fixture.database, git: fixture.git)
    }
    #expect(throws: RewriteRunError.notAPreview(preview.runID, reason: "it is a rewrite run")) {
      try RewriteRuns.apply(
        fromRun: preview.runID, allowedSources: [], kind: .domainMigrate, database: fixture.database,
        git: fixture.git)
    }
  }

  @Test("Apply: a changed file or a new file with edits refuses the whole apply")
  func planChanged() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("site", "a.md", "\(old)/2024/a.png\n")
    try fixture.write("site", "b.md", "\(old)/2024/b.png\n")
    let preview = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move])], database: fixture.database,
      git: fixture.git)
    try fixture.write("site", "a.md", "\(old)/2024/a.png edited\n")
    try fixture.write("site", "c.md", "\(old)/2024/c.png\n")
    let runs = try fixture.runCount()
    #expect(
      throws: RewriteRunError.planChanged(
        runID: preview.runID, differences: ["blog/site/a.md: file changed", "blog/site/c.md: new edits"])
    ) {
      try RewriteRuns.apply(fromRun: preview.runID, allowedSources: [], database: fixture.database, git: fixture.git)
    }
    #expect(try fixture.read("site", "b.md") == "\(old)/2024/b.png\n")
    #expect(try fixture.runCount() == runs)
  }

  @Test("Apply: an unclean source not allowed in any project refuses every project")
  func notAllowed() async throws {
    let fixture = try Fixture(projects: ["blog", "docs"])
    defer { fixture.remove() }
    try fixture.write("site", "a.md", "\(old)/2024/a.png\n")
    try fixture.write("site", "d.md", "\(old)/2024/a.png\n", in: "docs")
    fixture.git.set(.dirty(paths: ["d.md"]), for: fixture.source("site", in: "docs"))
    let preview = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move]), RewriteRunTarget(project: "docs", rules: [move])],
      database: fixture.database, git: fixture.git)
    let runs = try fixture.runCount()
    #expect(throws: RewriteRunError.sourcesNotAllowed(["docs/site (uncommitted changes (1))"])) {
      try RewriteRuns.apply(fromRun: preview.runID, allowedSources: [], database: fixture.database, git: fixture.git)
    }
    #expect(throws: RewriteRunError.unknownSources(["docs/nope"])) {
      try RewriteRuns.apply(
        fromRun: preview.runID, allowedSources: ["docs/nope"], database: fixture.database, git: fixture.git)
    }
    #expect(try fixture.read("site", "a.md") == "\(old)/2024/a.png\n")
    #expect(try fixture.runCount() == runs)
    let applied = try RewriteRuns.apply(
      fromRun: preview.runID, allowedSources: ["docs/site"], database: fixture.database, git: fixture.git,
      backupRoot: fixture.directory.appendingPathComponent("b"))
    #expect(applied.summary.written == 2)
  }

  @Test("A file changed while applying is skipped, logged, and the rest still written")
  func changedWhileApplying() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("site", "a.md", "\(old)/2024/a.png\n")
    try fixture.write("site", "b.md", "\(old)/2024/b.png\n")
    let preview = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: "blog", rules: [move])], database: fixture.database,
      git: fixture.git)
    // Status calls: the preview's 2, then the apply's re-plan (2), allowed
    // check (1) and the applier's own (6th): right before it writes.
    let path = fixture.path("site", "a.md")
    fixture.git.onStatus = { call in
      if call == 6 { try? Data("changed\n".utf8).write(to: URL(fileURLWithPath: path)) }
    }
    let result = try RewriteRuns.apply(
      fromRun: preview.runID, allowedSources: [], database: fixture.database, git: fixture.git,
      backupRoot: fixture.directory.appendingPathComponent("b"))
    #expect(try fixture.read("site", "a.md") == "changed\n")
    #expect(try fixture.read("site", "b.md") == "\(new)/2024/b.png\n")
    #expect(result.summary.skippedFiles == ["changed_since_plan": 1])
    let events = try RunLog.events(of: result.runID, in: fixture.database)
    #expect(events.contains { $0.event.summaryLine == "Skipped a.md — changed since the preview" })
  }
}
