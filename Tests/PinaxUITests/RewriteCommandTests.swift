import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `pinax rewrite` and `pinax runs` through the real
/// parser on a temporary catalog and a temporary source folder. Git and the
/// target check are stubs.
@Suite struct RewriteCommandTests {
  private let old = "https://img.example.com"
  private let new = "https://cdn.example.net"

  private func parse<T: ParsableCommand>(_ arguments: [String], as: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }

  /// The fixture catalog with project `blog` given source `site` holding
  /// `post.md` (two refs) and `about.md` (none).
  private func setUp() throws -> (DatabasePool, URL, URL) {
    let (database, directory) = try makeUITestDatabase()
    let site = directory.appendingPathComponent("site", isDirectory: true).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    try Data("![a](\(old)/blog/a.png)\n\n![b](\(old)/blog/b.png)\n".utf8)
      .write(to: site.appendingPathComponent("post.md"))
    try Data("plain\n".utf8).write(to: site.appendingPathComponent("about.md"))
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: site.path)], in: database)
    return (database, directory, site)
  }

  private func preview(
    _ extra: [String] = [], in database: DatabasePool, git: GitStatusProviding = StubRewriteGit(),
    verifier: RewriteTargetVerifying = StubRewriteVerifier()
  ) async throws -> RewriteCommandOutput {
    try await parse(
      ["rewrite", "--project", "blog", "--from-prefix", old, "--to-prefix", new] + extra,
      as: RewriteCommand.self
    ).perform(in: database, git: git, verifier: verifier)
  }

  @Test("Argument errors: --apply needs --from-run and takes nothing else; preview needs rules")
  func arguments() {
    func message(_ arguments: [String]) -> (String, Int32) {
      do {
        _ = try Pinax.parseAsRoot(arguments)
        return ("parsed", 0)
      } catch {
        return (Pinax.message(for: error), Pinax.exitCode(for: error).rawValue)
      }
    }
    #expect(message(["rewrite", "--apply"]) == ("--apply needs --from-run ID, the number of the preview to write.", 64))
    #expect(message(["rewrite", "--apply", "--from-run", "3", "--project", "blog"]).0.hasPrefix("--apply takes the project and rules from the preview run"))
    #expect(message(["rewrite", "--apply", "--from-run", "3", "--from-prefix", old, "--to-prefix", new]).1 == 64)
    #expect(message(["rewrite", "--project", "blog"]) == ("Give --map FILE, or --from-prefix URL --to-prefix URL.", 64))
    #expect(message(["rewrite", "--project", "blog", "--from-prefix", old]) == ("Give --from-prefix and --to-prefix together.", 64))
    #expect(message(["rewrite", "--from-prefix", old, "--to-prefix", new]) == ("Give --project SLUG.", 64))
    #expect(message(["rewrite", "--project", "blog", "--map", "m.json", "--from-run", "2"]) == ("--from-run only goes with --apply.", 64))
    #expect(message(["rewrite", "--apply", "--from-run", "2", "--allow-source", "site"]) == ("--allow-source takes PROJECT/LABEL, not “site”.", 64))
    #expect(message(["rewrite", "--project", "blog", "--map", "m.json", "--diff", "--format", "json"]) == ("--diff prints text; use it with --format table.", 64))
    #expect(message(["rewrite", "--apply", "--from-run", "2", "--allow-source", "blog/site"]) == ("parsed", 0))
    #expect(message(["runs"]) == ("parsed", 0))
    #expect((try? Pinax.parseAsRoot(["runs"])) is RunsListCommand)
  }

  @Test("Preview table, --diff, JSON; nothing written; then apply writes and runs lists both")
  func previewThenApply() async throws {
    let (database, directory, site) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = StubRewriteGit()
    git.statuses[site.path] = .notGit

    let table = try await preview(["--diff"], in: database, git: git)
    let lines = table.stdout.components(separatedBy: "\n")
    #expect(table.exitCode == 0)
    #expect(lines[0] == "Preview run 1 — pinax rewrite --apply --from-run 1 to write.")
    #expect(lines[1...5] == [
      "Sources",
      "  blog/site isn’t in git — to write it, add --allow-source blog/site",
      "Files",
      "  blog/site/post.md\t2 refs",
      "Summary: 1 file, 2 refs to rewrite.",
    ])
    #expect(lines.contains("--- a/site/post.md"))
    #expect(lines.contains("-![a](\(old)/blog/a.png)"))
    #expect(lines.contains("+![b](\(new)/blog/b.png)"))
    #expect(try String(contentsOf: site.appendingPathComponent("post.md"), encoding: .utf8).contains(old))

    let json = try await preview(["--format", "json"], in: database, git: git)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    #expect(object["schema"] as? String == "pinax.rewrite.v1")
    #expect(object["run_id"] as? Int == 2)
    #expect(object["dry_run"] as? Bool == true)
    #expect((object["files"] as? [[String: Any]])?.first?["edits_digest"] is String)

    // Not allowed: refused, nothing written.
    let refused = try parse(["rewrite", "--apply", "--from-run", "1"], as: RewriteCommand.self)
    await #expect(throws: RewriteRunError.self) {
      try await refused.perform(in: database, git: git, backupRoot: directory.appendingPathComponent("b"))
    }
    #expect(try String(contentsOf: site.appendingPathComponent("post.md"), encoding: .utf8).contains(old))

    let apply = try parse(
      ["rewrite", "--apply", "--from-run", "1", "--allow-source", "blog/site"], as: RewriteCommand.self)
    let applied = try await apply.perform(in: database, git: git, backupRoot: directory.appendingPathComponent("b"))
    #expect(applied.exitCode == 0)
    #expect(
      applied.stdout.components(separatedBy: "\n") == [
        "Run 3 wrote 1 file from preview 1.",
        "  Rewrote post.md · 2 refs",
        "  Rescanned blog · 2 refs in 2 files",
        "Changed files",
        "  not in git · 1 file",
      ])
    #expect(
      try String(contentsOf: site.appendingPathComponent("post.md"), encoding: .utf8)
        == "![a](\(new)/blog/a.png)\n\n![b](\(new)/blog/b.png)\n")

    let ls = try parse(["runs", "ls", "--limit", "2"], as: RunsListCommand.self).perform(in: database)
    let rows = ls.stdout.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
    #expect(rows.count == 3)
    #expect(rows[0] == ["ID", "KIND", "MODE", "STATE", "STARTED", "FROM"])
    #expect(rows[1][0] == "3" && rows[1][2] == "apply" && rows[1][3] == "finished" && rows[1][5] == "1")
    #expect(rows[2][0] == "2" && rows[2][2] == "preview")
    let lsJSON = try parse(["runs", "--format", "json"], as: RunsListCommand.self).perform(in: database)
    let runs = try #require(try JSONSerialization.jsonObject(with: Data(lsJSON.stdout.utf8)) as? [String: Any])
    #expect(runs["schema"] as? String == "pinax.runs.v1")
    #expect((runs["runs"] as? [Any])?.count == 3)

    let show = try parse(["runs", "show", "3"], as: RunsShowCommand.self).perform(in: database)
    let shown = show.stdout.components(separatedBy: "\n")
    #expect(shown[0] == "Run 3 · rewrite · apply · finished · from run 1")
    #expect(shown.contains("3\tinfo\tRewrote post.md · 2 refs"))
    #expect(shown.last == "5\tinfo\tFinished · wrote 1 file")

    let jsonl = try parse(["runs", "show", "3", "--format", "jsonl"], as: RunsShowCommand.self)
      .perform(in: database)
    let events = try jsonl.stdout.components(separatedBy: "\n").map {
      try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    #expect(events.count == 5)
    #expect(events.allSatisfy { Set($0.keys) == ["seq", "at", "level", "type", "data"] })
    #expect(events.map { $0["type"] as? String } == [
      "run_started", "source_status", "file_written", "rescan_finished", "run_finished",
    ])
  }

  @Test("Exit codes: 66 missing run / project / map, 64 bad rules, 77 refusals, 69 / 77 from the check, 1 changed file")
  func exitCodes() async throws {
    let (database, directory, site) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    func code(_ body: () async throws -> RewriteCommandOutput) async -> Int32? {
      do {
        return try await body().exitCode
      } catch {
        return RewriteExit.code(for: error)
      }
    }
    let backups = directory.appendingPathComponent("b")
    #expect(await code { try await parse(["rewrite", "--apply", "--from-run", "99"], as: RewriteCommand.self).perform(in: database, git: StubRewriteGit()) } == 66)
    #expect(await code { try parse(["runs", "show", "99"], as: RunsShowCommand.self).perform(in: database) } == 66)
    #expect(await code { try await parse(["rewrite", "--project", "nope", "--from-prefix", old, "--to-prefix", new], as: RewriteCommand.self).perform(in: database, git: StubRewriteGit()) } == 66)
    let missingMap = directory.appendingPathComponent("missing.json").path
    #expect(await code { try await parse(["rewrite", "--project", "blog", "--map", missingMap], as: RewriteCommand.self).perform(in: database) } == 66)
    let map = directory.appendingPathComponent("map.json")
    try Data(#"[{"match": "exact", "from": "https://a.com/x.png", "to": "https://a.com/x.png"}]"#.utf8).write(to: map)
    #expect(await code { try await parse(["rewrite", "--project", "blog", "--map", map.path], as: RewriteCommand.self).perform(in: database, git: StubRewriteGit()) } == 64)
    try Data(#"[{"match": "glob", "from": "a", "to": "b"}]"#.utf8).write(to: map)
    #expect(await code { try await parse(["rewrite", "--project", "blog", "--map", map.path], as: RewriteCommand.self).perform(in: database, git: StubRewriteGit()) } == 64)

    // The check: unreachable 69, a mismatch (even with an unreachable) 77.
    let a = "\(new)/blog/a.png"
    let b = "\(new)/blog/b.png"
    #expect(await code { try await preview(["--verify"], in: database, verifier: StubRewriteVerifier(results: [a: .unreachable(reason: "404")])) } == 69)
    #expect(await code { try await preview(["--verify"], in: database, verifier: StubRewriteVerifier(results: [a: .unreachable(reason: "404"), b: .mismatch(expected: "x", actual: "y")])) } == 77)
    #expect(await code { try await preview(["--verify"], in: database) } == 0)

    // Refusals: unclean source not allowed, then the file changing since.
    let git = StubRewriteGit()
    git.statuses[site.path] = .dirty(paths: ["post.md"])
    let base = try await preview(in: database, git: git)
    let runID = try #require(base.stdout.split(separator: " ").dropFirst(2).first.flatMap { Int($0) })
    #expect(await code { try await parse(["rewrite", "--apply", "--from-run", "\(runID)"], as: RewriteCommand.self).perform(in: database, git: git, backupRoot: backups) } == 77)
    try Data("![a](\(old)/blog/a.png)\n".utf8).write(to: site.appendingPathComponent("post.md"))
    #expect(await code { try await parse(["rewrite", "--apply", "--from-run", "\(runID)", "--allow-source", "blog/site"], as: RewriteCommand.self).perform(in: database, git: git, backupRoot: backups) } == 77)

    // A file that changes between the re-plan and the write: written run, exit 1.
    let fresh = try await preview(in: database, git: StubRewriteGit())
    let freshID = try #require(fresh.stdout.split(separator: " ").dropFirst(2).first.flatMap { Int($0) })
    let racing = StubRewriteGit()
    let post = site.appendingPathComponent("post.md")
    // Re-plan (1), allowed check (2), the applier's own (3): right before writing.
    racing.onStatus = { call in if call == 3 { try? Data("changed\n".utf8).write(to: post) } }
    #expect(await code { try await parse(["rewrite", "--apply", "--from-run", "\(freshID)"], as: RewriteCommand.self).perform(in: database, git: racing, backupRoot: backups) } == 1)
  }

  @Test("Failed checks: grouped by cause, 5 URLs then “and N more”, the first line says apply is refused; JSON and runs show stay per URL")
  func failedChecks() async throws {
    let (database, directory, site) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let post = site.appendingPathComponent("post.md")
    let original = (0..<8).map { "![x\($0)](\(old)/blog/x\($0).png)\n" }.joined()
    try Data(original.utf8).write(to: post)
    let urls = (0..<8).map { "\(new)/blog/x\($0).png" }
    var results: [String: TargetVerification] = [:]
    for url in urls.prefix(7) { results[url] = .unreachable(reason: "Fetch failed for \(url): offline") }
    results[urls[7]] = .mismatch(expected: "e", actual: "a")
    let verifier = StubRewriteVerifier(results: results)

    let table = try await preview(["--verify"], in: database, verifier: verifier)
    let lines = table.stdout.components(separatedBy: "\n")
    #expect(table.exitCode == 77)
    #expect(lines[0] == "Preview run 1 — 8 new URLs failed the check; apply is refused.")
    let start = try #require(lines.firstIndex(of: "Failed checks"))
    var expected: [String] = ["  Couldn’t fetch: Fetch failed: offline · 7 new URLs"]
    expected += urls.prefix(5).map { "    \($0)" }
    expected += ["    … and 2 more", "  Serves a different file · 1 new URL", "    \(urls[7])"]
    expected.append(
      "Summary: 1 file, 8 refs to rewrite; 8 new URLs failed the check; 8 new URLs not in the catalog, only fetched.")
    #expect(Array(lines[(start + 1)...].prefix(10)) == expected)
    #expect(!table.stdout.contains("Checked "))

    let one = try await preview(
      ["--verify"], in: database, verifier: StubRewriteVerifier(results: [urls[0]: .unreachable(reason: "404")]))
    #expect(one.stdout.hasPrefix("Preview run 2 — 1 new URL failed the check; apply is refused.\n"))

    // The apply is refused: nothing written, no run recorded.
    let apply = try parse(["rewrite", "--apply", "--from-run", "1"], as: RewriteCommand.self)
    await #expect(throws: RewriteRunError.targetsNotVerified(
      runID: 1, urls.prefix(7).map { "\($0) (unreachable)" } + ["\(urls[7]) (mismatch)"])
    ) {
      try await apply.perform(in: database, git: StubRewriteGit(), backupRoot: directory.appendingPathComponent("b"))
    }
    #expect(RewriteExit.code(for: RewriteRunError.targetsNotVerified(runID: 1, [])) == 77)
    #expect(try String(contentsOf: post, encoding: .utf8) == original)
    #expect(try RunLog.runs(in: database).count == 2)

    // JSON: one entry per URL, the reason as the fetcher gave it.
    let json = try await preview(["--verify", "--format", "json"], in: database, verifier: verifier)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    #expect(Set(object.keys) == ["schema", "run_id", "dry_run", "sources", "files", "skipped", "protocol_relative", "verified", "summary"])
    let verified = try #require(object["verified"] as? [[String: Any]])
    #expect(verified.count == 8)
    let first = try #require(verified.first { $0["url"] as? String == urls[0] })
    #expect(Set(first.keys) == ["url", "result", "reason"])
    #expect(first["reason"] as? String == "Fetch failed for \(urls[0]): offline")

    // runs show: one line per check, each URL once.
    let show = try parse(["runs", "show", "1"], as: RunsShowCommand.self).perform(in: database)
    let checks = show.stdout.components(separatedBy: "\n").filter { $0.contains("\(new)/blog/x") }
    #expect(checks.count == 8)
    #expect(checks.contains { $0.hasSuffix("\tCouldn’t fetch \(urls[0]) — Fetch failed: offline") })
    #expect(checks.allSatisfy { $0.components(separatedBy: "\(new)/blog/x").count == 2 })
  }

  @Test("New and old URL both fail → already broken, a warning; apply writes as usual")
  func alreadyBroken() async throws {
    let (database, directory, site) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let post = site.appendingPathComponent("post.md")
    let verifier = RecordingRewriteVerifier(results: [
      "\(new)/blog/b.png": .unreachable(reason: "Fetch failed for \(new)/blog/b.png: 404"),
      "\(old)/blog/b.png": .unreachable(reason: "Fetch failed for \(old)/blog/b.png: 404"),
    ])

    let table = try await preview(["--verify"], in: database, verifier: verifier)
    let lines = table.stdout.components(separatedBy: "\n")
    #expect(table.exitCode == 0)
    #expect(lines[0] == "Preview run 1 — pinax rewrite --apply --from-run 1 to write.")
    #expect(!lines.contains("Failed checks"))
    let start = try #require(lines.firstIndex(of: "Already broken (also fails on the old URL)"))
    #expect(Array(lines[(start + 1)...].prefix(3)) == [
      "  Couldn’t fetch: Fetch failed: 404 · 1 new URL",
      "    \(new)/blog/b.png",
      "Summary: 1 file, 2 refs to rewrite; every new URL checked; 1 new URL already broken; 2 new URLs not in the catalog, only fetched.",
    ])

    let json = try await preview(["--verify", "--format", "json"], in: database, verifier: verifier)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    let verified = try #require(object["verified"] as? [[String: Any]])
    let broken = try #require(verified.first { $0["url"] as? String == "\(new)/blog/b.png" })
    #expect(Set(broken.keys) == ["url", "result", "reason", "old_reason"])
    #expect(broken["result"] as? String == "already_broken")
    #expect(broken["old_reason"] as? String == "Fetch failed for \(old)/blog/b.png: 404")
    #expect((object["summary"] as? [String: Any])?["verified"] as? [String: Int] == ["ok": 1, "already_broken": 1])
    let show = try parse(["runs", "show", "1"], as: RunsShowCommand.self).perform(in: database)
    #expect(show.stdout.contains("\(new)/blog/b.png was already broken — the old URL fails too"))

    let applied = try await parse(["rewrite", "--apply", "--from-run", "1"], as: RewriteCommand.self)
      .perform(in: database, git: StubRewriteGit(), backupRoot: directory.appendingPathComponent("b"))
    #expect(applied.exitCode == 0)
    #expect(try String(contentsOf: post, encoding: .utf8) == "![a](\(new)/blog/a.png)\n\n![b](\(new)/blog/b.png)\n")
  }

  @Test("Old URL fetches → still a failed check, apply refused; a catalog asset’s old URL is never fetched")
  func notAlreadyBroken() async throws {
    let (database, directory, site) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-01-01T00:00:00Z", key: "blog/a.png")
    let post = site.appendingPathComponent("post.md")
    let original = try Data(contentsOf: post)
    let verifier = RecordingRewriteVerifier(results: [
      "\(new)/blog/a.png": .unreachable(reason: "404"),
      "\(old)/blog/a.png": .unreachable(reason: "404"),
      "\(new)/blog/b.png": .unreachable(reason: "404"),
    ])

    let table = try await preview(["--verify"], in: database, verifier: verifier)
    #expect(table.exitCode == 69)
    #expect(table.stdout.hasPrefix("Preview run 1 — 2 new URLs failed the check; apply is refused.\n"))
    #expect(!table.stdout.contains("Already broken"))
    #expect(verifier.calls.contains("\(old)/blog/b.png"))
    #expect(!verifier.calls.contains("\(old)/blog/a.png"))

    let apply = try parse(["rewrite", "--apply", "--from-run", "1"], as: RewriteCommand.self)
    await #expect(throws: RewriteRunError.targetsNotVerified(
      runID: 1, ["\(new)/blog/a.png (unreachable)", "\(new)/blog/b.png (unreachable)"])
    ) {
      try await apply.perform(in: database, git: StubRewriteGit(), backupRoot: directory.appendingPathComponent("b"))
    }
    #expect(try Data(contentsOf: post) == original)
  }

  @Test("A refusal lists at most 5 URLs, then “and N more” and runs show")
  func refusalTruncated() {
    let urls = (0..<7).map { "https://x/\($0).png (unreachable)" }
    let lines = RewriteRunError.targetsNotVerified(runID: 4, urls).description.components(separatedBy: "\n")
    #expect(lines == ["Preview run 4 has new URLs that failed the check; nothing was written:"]
      + urls.prefix(5).map { "  \($0)" }
      + ["  … and 2 more — pinax runs show 4 lists them all."])
    let migration = DomainMigrationError.targetsNotVerified(runID: 4, urls).description.components(separatedBy: "\n")
    #expect(migration.count == 7 && migration.last == lines.last)
    #expect(RewriteRunError.targetsNotVerified(runID: 4, Array(urls.prefix(5))).description.components(separatedBy: "\n").count == 6)
  }

  @Test("RewriteExit.finish turns a classified error or a nonzero status into ExitCode")
  func finish() async {
    await #expect(throws: ExitCode(77)) {
      try await RewriteExit.finish { throw RewriteRunError.sourcesNotAllowed(["blog/site (not in git)"]) }
    }
    await #expect(throws: ExitCode(1)) {
      try await RewriteExit.finish { RewriteCommandOutput(stdout: "", exitCode: 1) }
    }
    await #expect(throws: Never.self) {
      try await RewriteExit.finish { RewriteCommandOutput(stdout: "") }
    }
  }
}

final class StubRewriteGit: GitStatusProviding, @unchecked Sendable {
  var statuses: [String: SourceGitStatus] = [:]
  var onStatus: ((Int) -> Void)?
  private var calls = 0
  private let lock = NSLock()

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

struct StubRewriteVerifier: RewriteTargetVerifying {
  var results: [String: TargetVerification] = [:]

  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    results[url] ?? .ok(sha256: expectedSHA256 ?? "")
  }
}

/// Answers like `StubRewriteVerifier` and records every URL asked.
final class RecordingRewriteVerifier: RewriteTargetVerifying, @unchecked Sendable {
  let results: [String: TargetVerification]
  private var asked: [String] = []
  private let lock = NSLock()

  init(results: [String: TargetVerification]) { self.results = results }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return asked
  }

  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    lock.withLock { asked.append(url) }
    return results[url] ?? .ok(sha256: expectedSHA256 ?? "")
  }
}
