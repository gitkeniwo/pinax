import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// Old domains, the CLI half: `--diff` against
/// `RewriteRuns.diff(ofRun:)`, Already broken by `old_reason`, the Links
/// column, `--from`. Real parser, temporary catalog, stub git and check.
@Suite struct OldDomainCommandTests {
  private let old = "https://img.example.com"
  private let legacy = "https://legacy.example.com"
  private let new = "https://cdn.example.net"

  private func parse<T: ParsableCommand>(_ arguments: [String], as: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }

  /// The fixture catalog (backend `r2` at `old`, old domain `legacy`) with
  /// project `blog`'s source `site` holding `post.md`: two refs on `old`,
  /// one on `legacy`; scanned.
  private func setUp() throws -> (DatabasePool, URL, URL) {
    let (database, directory) = try makeUITestDatabase()
    let site = directory.appendingPathComponent("site", isDirectory: true).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    try Data("![a](\(old)/blog/a.png)\n\n![b](\(old)/blog/b.png)\n\n![c](\(legacy)/blog/c.png)\n".utf8)
      .write(to: site.appendingPathComponent("post.md"))
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: site.path)], in: database)
    try CatalogConfiguration.addOldDomain(legacy, backendSlug: "r2", in: database)
    let scan = try UsageScanner.scan(project: "blog", in: database)
    _ = try CatalogUsage.sync(scan.document, project: "blog", in: database)
    return (database, directory, site)
  }

  /// The `--diff` part of a preview table: everything after the summary line.
  private func diffPart(_ stdout: String) throws -> String {
    let lines = stdout.components(separatedBy: "\n")
    let summary = try #require(lines.firstIndex { $0.hasPrefix("Summary: ") })
    return lines[(summary + 1)...].joined(separator: "\n") + "\n"
  }

  @Test("diff(ofRun:) of a rewrite and of a domain_migrate preview is --diff word for word")
  func diffOfRun() async throws {
    let (database, directory, _) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = StubRewriteGit()

    let rewrite = try await parse(
      ["rewrite", "--project", "blog", "--from-prefix", old, "--to-prefix", new, "--diff"], as: RewriteCommand.self
    ).perform(in: database, git: git, verifier: StubRewriteVerifier())
    let rewriteDiff = try RewriteRuns.diff(ofRun: 1, in: database, git: git)
    #expect(rewriteDiff.contains("+![a](\(new)/blog/a.png)"))
    #expect(try diffPart(rewrite.stdout) == rewriteDiff)

    let move = try await parse(
      ["backend", "migrate-domain", "--backend", "r2", "--to", new, "--project", "blog", "--diff"],
      as: BackendMigrateDomain.self
    ).perform(in: database, git: git, verifier: StubRewriteVerifier())
    let moveDiff = try RewriteRuns.diff(ofRun: 2, in: database, git: git)
    #expect(moveDiff.contains("+![c](\(new)/blog/c.png)"))
    #expect(try diffPart(move.stdout) == moveDiff)
    #expect(throws: RewriteRunError.runNotFound(9)) { try RewriteRuns.diff(ofRun: 9, in: database, git: git) }
  }

  @Test("Already broken groups by old_reason; without one, by the new URL's reason")
  func alreadyBrokenByOldReason() async throws {
    let (database, directory, _) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let verifier = StubRewriteVerifier(results: [
      "\(new)/blog/a.png": .unreachable(reason: "Fetch failed for \(new)/blog/a.png: timed out"),
      "\(new)/blog/b.png": .unreachable(reason: "Fetch failed for \(new)/blog/b.png: timed out"),
      "\(old)/blog/a.png": .unreachable(reason: "Fetch failed for \(old)/blog/a.png: 404"),
      "\(old)/blog/b.png": .unreachable(reason: "Fetch failed for \(old)/blog/b.png: 404"),
    ])
    let table = try await parse(
      ["backend", "migrate-domain", "--backend", "r2", "--to", new, "--project", "blog", "--keep-old-domains"],
      as: BackendMigrateDomain.self
    ).perform(in: database, git: StubRewriteGit(), verifier: verifier)
    let lines = table.stdout.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex(of: "Already broken (also fails on the old URL)"))
    #expect(lines[start + 1] == "  Couldn’t fetch: Fetch failed: 404 · 2 new URLs")

    // A run recorded before old_reason: the new URL's cause.
    var event = TargetVerifiedEvent(
      url: "\(new)/x.png", expectedSHA256: nil, verification: .unreachable(reason: "timed out"), oldReason: "gone")
    #expect(event.oldCause == "gone")
    event.oldReason = nil
    #expect(event.oldCause == "timed out")
  }

  @Test("old-domain ls has a Links column and JSON links; set-prefix and migrate refuse another backend's domain")
  func links() throws {
    let (database, directory, _) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let table = try parse(["backend", "old-domain", "ls", "r2"], as: BackendOldDomainList.self)
    #expect(try table.output(in: database) == "\(legacy)\t1\n")
    let json = try parse(["backend", "old-domain", "ls", "r2", "--format", "json"], as: BackendOldDomainList.self)
    let document = try #require(
      try JSONSerialization.jsonObject(with: Data(try json.output(in: database).utf8)) as? [String: Any])
    #expect(document["schema"] as? String == "pinax.old-domains.v1")
    #expect((document["current"] as? [String: Any])?["links"] as? Int == 2)
    let olds = try #require(document["old_domains"] as? [[String: Any]])
    #expect(olds.count == 1 && olds[0]["prefix"] as? String == legacy && olds[0]["links"] as? Int == 1)
    #expect(RewriteExit.code(for: CatalogConfigurationError.domainOfOtherBackend(prefix: "x", backend: "y")) == 64)
  }

  @Test("--from moves only that old domain's links to the current prefix; --to current needs --from")
  func fromFlag() async throws {
    let (database, directory, site) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = StubRewriteGit()
    func message(_ arguments: [String]) -> (String, Int32) {
      do {
        _ = try Pinax.parseAsRoot(["backend", "migrate-domain"] + arguments)
        return ("parsed", 0)
      } catch {
        return (Pinax.message(for: error), Pinax.exitCode(for: error).rawValue)
      }
    }
    #expect(message(["--apply", "--from-run", "1", "--from", legacy]).1 == 64)
    #expect(message(["--backend", "r2", "--to", new, "--from", legacy, "--keep-old-domains"]).1 == 64)
    await #expect(throws: DomainMigrationError.sameAsCurrent(old)) {
      _ = try await parse(["backend", "migrate-domain", "--backend", "r2", "--to", old], as: BackendMigrateDomain.self)
        .perform(in: database, git: git, verifier: StubRewriteVerifier())
    }
    #expect(RewriteExit.code(for: DomainMigrationError.notAnOldDomain("x", backend: "r2")) == 64)

    let preview = try await parse(
      ["backend", "migrate-domain", "--backend", "r2", "--to", old, "--from", legacy + "/"],
      as: BackendMigrateDomain.self
    ).perform(in: database, git: git, verifier: StubRewriteVerifier())
    let lines = preview.stdout.components(separatedBy: "\n")
    #expect(lines[1] == "Prefix stays \(old); moves links on \(legacy) to it on apply.")
    #expect(lines.contains("  blog/site/post.md\t1 ref"))
    let applied = try await parse(["backend", "migrate-domain", "--apply", "--from-run", "1"], as: BackendMigrateDomain.self)
      .perform(in: database, git: git, backupRoot: directory.appendingPathComponent("b"))
    #expect(applied.exitCode == 0)
    #expect(try String(contentsOf: site.appendingPathComponent("post.md"), encoding: .utf8)
      == "![a](\(old)/blog/a.png)\n\n![b](\(old)/blog/b.png)\n\n![c](\(old)/blog/c.png)\n")
    #expect(try CatalogConfiguration.rewriteMap(backendSlug: "r2", in: database).current == old)
    let table = try parse(["backend", "old-domain", "ls", "r2"], as: BackendOldDomainList.self)
    #expect(try table.output(in: database) == "\(legacy)\t0\n")
  }
}
