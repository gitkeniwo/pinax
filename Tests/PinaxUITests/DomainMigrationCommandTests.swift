import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `pinax backend migrate-domain` through the real
/// parser on a temporary catalog and a temporary source folder. Git and the
/// target check are stubs.
@Suite struct DomainMigrationCommandTests {
  private let old = "https://img.example.com"
  private let new = "https://cdn.example.net"

  private func parse(_ arguments: [String]) throws -> BackendMigrateDomain {
    try #require(try Pinax.parseAsRoot(["backend", "migrate-domain"] + arguments) as? BackendMigrateDomain)
  }

  /// The fixture catalog (backend `r2` at `old`) with project `blog` given
  /// source `site` holding `post.md` (two refs).
  private func setUp() throws -> (DatabasePool, URL, URL) {
    let (database, directory) = try makeUITestDatabase()
    let site = directory.appendingPathComponent("site", isDirectory: true).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    try Data("![a](\(old)/blog/a.png)\n\n![b](\(old)/blog/b.png)\n".utf8)
      .write(to: site.appendingPathComponent("post.md"))
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: site.path)], in: database)
    return (database, directory, site)
  }

  @Test("Argument errors: --apply takes only --from-run and --allow-source; preview needs --backend and --to")
  func arguments() {
    func message(_ arguments: [String]) -> (String, Int32) {
      do {
        _ = try Pinax.parseAsRoot(["backend", "migrate-domain"] + arguments)
        return ("parsed", 0)
      } catch {
        return (Pinax.message(for: error), Pinax.exitCode(for: error).rawValue)
      }
    }
    #expect(message(["--apply"]) == ("--apply needs --from-run ID, the number of the preview to write.", 64))
    #expect(message(["--apply", "--from-run", "1", "--backend", "r2"]).0.hasPrefix("--apply takes the backend, domain and projects"))
    #expect(message(["--backend", "r2"]) == ("Give --backend SLUG and --to URL.", 64))
    #expect(message(["--backend", "r2", "--to", new, "--from-run", "1"]) == ("--from-run only goes with --apply.", 64))
    #expect(message(["--backend", "r2", "--to", new, "--diff", "--format", "json"]).1 == 64)
    #expect(message(["--backend", "r2", "--to", new, "--project", "blog", "--project", "notes", "--keep-old-domains"]) == ("parsed", 0))
    #expect(message(["--apply", "--from-run", "1", "--allow-source", "blog/site"]) == ("parsed", 0))
  }

  @Test("Preview names the move and exits 77 on a mismatch; apply changes the prefix, writes, and logs it")
  func previewThenApply() async throws {
    let (database, directory, site) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = StubRewriteGit()
    let backups = directory.appendingPathComponent("b")

    let bad = try await parse(["--backend", "r2", "--to", new, "--project", "blog"]).perform(
      in: database, git: git,
      verifier: StubRewriteVerifier(results: ["\(new)/blog/a.png": .mismatch(expected: "", actual: "f")]))
    #expect(bad.exitCode == 77)
    let badLines = bad.stdout.components(separatedBy: "\n")
    #expect(badLines[0] == "Preview run 1 — 1 new URL failed the check; apply is refused.")
    let failed = try #require(badLines.firstIndex(of: "Failed checks"))
    #expect(Array(badLines[(failed + 1)...].prefix(2)) == ["  Serves a different file · 1 new URL", "    \(new)/blog/a.png"])
    #expect(!bad.stdout.contains("Checked "))
    let refused = try parse(["--apply", "--from-run", "1"])
    await #expect(throws: DomainMigrationError.self) {
      try await refused.perform(in: database, git: git, backupRoot: backups)
    }
    #expect(RewriteExit.code(for: DomainMigrationError.targetsNotVerified(runID: 1, [])) == 77)
    #expect(RewriteExit.code(for: CatalogConfigurationError.backendNotFound("x")) == 66)
    #expect(try CatalogConfiguration.rewriteMap(backendSlug: "r2", in: database).current == old)

    let table = try await parse(["--backend", "r2", "--to", new + "/", "--project", "blog", "--diff"])
      .perform(in: database, git: git, verifier: StubRewriteVerifier())
    let lines = table.stdout.components(separatedBy: "\n")
    #expect(table.exitCode == 0)
    #expect(lines[0] == "Preview run 2 — pinax backend migrate-domain --apply --from-run 2 to write.")
    #expect(lines[1] == "Prefix \(old) → \(new) on apply.")
    #expect(lines.contains("  blog/site/post.md\t2 refs"))
    #expect(lines.contains(
      "Summary: 1 file, 2 refs to rewrite; every new URL checked; 2 new URLs not in the catalog, only fetched."))
    #expect(lines.contains("+![b](\(new)/blog/b.png)"))

    let applied = try await parse(["--apply", "--from-run", "2"]).perform(in: database, git: git, backupRoot: backups)
    #expect(applied.exitCode == 0)
    #expect(Array(applied.stdout.components(separatedBy: "\n").prefix(3)) == [
      "Run 3 wrote 1 file from preview 2.",
      "  Changed r2’s URL prefix to \(new)",
      "  Rewrote post.md · 2 refs",
    ])
    #expect(try String(contentsOf: site.appendingPathComponent("post.md"), encoding: .utf8)
      == "![a](\(new)/blog/a.png)\n\n![b](\(new)/blog/b.png)\n")
    #expect(try CatalogConfiguration.rewriteMap(backendSlug: "r2", in: database).current == new)
    #expect(try CatalogConfiguration.oldDomains(backendSlug: "r2", in: database) == [old])

    let show = try parse(["runs", "show", "3"], as: RunsShowCommand.self).perform(in: database)
    #expect(show.stdout.hasPrefix("Run 3 · domain_migrate · apply · finished · from run 2"))
    #expect(show.stdout.contains("Started moving r2 to \(new) · blog · 1 rule"))
  }

  @Test("An already broken URL doesn’t block the move; apply changes the prefix and writes")
  func alreadyBroken() async throws {
    let (database, directory, site) = try setUp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = StubRewriteGit()
    let verifier = StubRewriteVerifier(results: [
      "\(new)/blog/b.png": .unreachable(reason: "404"), "\(old)/blog/b.png": .unreachable(reason: "404"),
    ])
    let table = try await parse(["--backend", "r2", "--to", new, "--project", "blog"])
      .perform(in: database, git: git, verifier: verifier)
    let lines = table.stdout.components(separatedBy: "\n")
    #expect(table.exitCode == 0)
    #expect(lines[0] == "Preview run 1 — pinax backend migrate-domain --apply --from-run 1 to write.")
    let start = try #require(lines.firstIndex(of: "Already broken (also fails on the old URL)"))
    #expect(Array(lines[(start + 1)...].prefix(2)) == ["  Couldn’t fetch: 404 · 1 new URL", "    \(new)/blog/b.png"])

    let applied = try await parse(["--apply", "--from-run", "1"])
      .perform(in: database, git: git, backupRoot: directory.appendingPathComponent("b"))
    #expect(applied.exitCode == 0)
    #expect(try String(contentsOf: site.appendingPathComponent("post.md"), encoding: .utf8)
      == "![a](\(new)/blog/a.png)\n\n![b](\(new)/blog/b.png)\n")
    #expect(try CatalogConfiguration.rewriteMap(backendSlug: "r2", in: database).current == new)
  }

  private func parse<T: ParsableCommand>(_ arguments: [String], as: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }
}
