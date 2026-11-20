import CatalogCore
import Foundation
import GRDB
import Testing

/// Domain migration — check, change the prefix,
/// rewrite every project, rescan. Git and the target check are stubs.
private let current = "https://img.old.com"
private let legacy = "https://legacy.example.com"
private let new = "https://cdn.new.net"

/// A temporary catalog with backend `r2` (prefix `current`, old domain
/// `legacy`), assets `2024/a.png` and `2024/b.png`, and projects `blog` and
/// `docs`, each with source `site`, scanned once. `blog/post.md` uses both
/// domains; `docs/index.md` uses the current one and a key not in the
/// catalog. Project `other` has no usage of `r2`.
private struct Fixture {
  let directory: URL
  let database: DatabasePool
  let git = StubGit()

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-domain-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://storage.example.com", bucket: "images", region: "auto",
      urlPrefix: current, keychainReference: "backend.r2", to: database)
    try CatalogConfiguration.addOldDomain(legacy, backendSlug: "r2", in: database)
    try database.write { db in
      for (index, key) in ["2024/a.png", "2024/b.png"].enumerated() {
        _ = try Asset(
          sha256: String(repeating: "\(index + 1)", count: 64), backendID: 1, key: key, byteSize: 1,
          mime: "image/png", uploadedAt: "2024-01-01T00:00:00Z", createdAt: "2024-01-01T00:00:00Z",
          updatedAt: "2024-01-01T00:00:00Z"
        ).insertAndFetch(db)
      }
    }
    for slug in ["blog", "docs", "other"] {
      _ = try CatalogConfiguration.addProject(
        slug: slug, name: slug, keyPrefix: "", backendSlug: "r2", to: database)
      try CatalogConfiguration.setProjectSources(slug: slug, [source(slug)], in: database)
    }
    try write("blog", "post.md", "![a](\(current)/2024/a.png)\n![b](\(legacy)/2024/b.png)\n")
    try write("docs", "index.md", "![a](\(current)/2024/a.png)\n![m](\(current)/2024/missing.png)\n")
    try write("other", "readme.md", "![x](https://elsewhere.com/x.png)\n")
    for slug in ["blog", "docs", "other"] { try rescan(slug) }
  }

  func source(_ project: String) -> ProjectSource {
    let url = directory.appendingPathComponent("\(project)-site", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return ProjectSource(label: "site", path: url.path)
  }

  func write(_ project: String, _ file: String, _ text: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: source(project).path).appendingPathComponent(file))
  }

  func read(_ project: String, _ file: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: source(project).path).appendingPathComponent(file), encoding: .utf8)
  }

  func rescan(_ project: String) throws {
    let scan = try UsageScanner.scan(project: project, in: database)
    _ = try CatalogUsage.sync(scan.document, project: project, in: database)
  }

  func prefix() throws -> String { try CatalogConfiguration.rewriteMap(backendSlug: "r2", in: database).current }
  func oldDomains() throws -> [String] { try CatalogConfiguration.oldDomains(backendSlug: "r2", in: database) }

  /// `project source_ref → asset_id` for the usage rows of each project's
  /// latest scan, and their raw URLs. Older rows stay: `sync` never deletes.
  func usage() throws -> (assets: [String], urls: [String]) {
    let rows = try database.read {
      try Row.fetchAll(
        $0,
        sql: """
          SELECT p.slug, u.source_ref, u.asset_id, u.raw_url FROM usage u
          JOIN project p ON p.id = u.project_id WHERE u.last_scan_id = p.last_scan_id ORDER BY p.slug, u.source_ref, u.raw_url
          """)
    }
    return (
      rows.map { "\($0["slug"] as String) \($0["source_ref"] as String) → \(($0["asset_id"] as Int64?).map(String.init) ?? "nil")" }.sorted(),
      rows.map { $0["raw_url"] as String })
  }

  func runCount() throws -> Int {
    try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM run") ?? 0 }
  }

  func preview(
    projects: [String] = [], keepOldDomains: Bool = false, to: String = new,
    results: [String: TargetVerification] = [:]
  ) async throws -> RewritePreviewResult {
    try await DomainMigration.preview(
      backend: "r2", to: to, projects: projects, keepOldDomains: keepOldDomains,
      verifier: StubVerifier(results: results), database: database, git: git)
  }

  func apply(_ runID: Int64, allowing: Set<String> = []) throws -> RewriteApplyResult {
    try DomainMigration.apply(
      fromRun: runID, allowedSources: allowing, database: database, git: git,
      backupRoot: directory.appendingPathComponent("backups"))
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Git status by source path, `.clean` by default.
private final class StubGit: GitStatusProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [String: SourceGitStatus] = [:]

  func set(_ status: SourceGitStatus, for source: ProjectSource) {
    lock.lock()
    defer { lock.unlock() }
    statuses[source.path] = status
  }

  func status(of root: URL) -> SourceGitStatus {
    lock.lock()
    defer { lock.unlock() }
    return statuses[root.path] ?? .clean
  }
}

private struct StubVerifier: RewriteTargetVerifying {
  let results: [String: TargetVerification]

  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    results[url] ?? .ok(sha256: expectedSHA256 ?? "fetched")
  }
}

@Suite struct DomainMigrationTests {
  @Test("Rules: old domains by default; --keep-old-domains only the current prefix; a new prefix that is an old domain gets no rule")
  func rules() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }

    let both = try await fixture.preview()
    #expect(both.plans.map(\.project) == ["blog", "docs"])
    #expect(both.plans[0].rules == [.prefix(from: current, to: new), .prefix(from: legacy, to: new)])
    #expect(both.summary.edits == 4)
    #expect(try fixture.read("blog", "post.md").contains(current))

    let keep = try await fixture.preview(keepOldDomains: true)
    #expect(keep.plans[0].rules == [.prefix(from: current, to: new)])
    #expect(keep.summary.edits == 3)
    guard case let .runStarted(params)? = keep.events.first else { Issue.record("no run_started"); return }
    #expect(params.domain == DomainMigrationParams(
      backend: "r2", from: current, to: new, oldDomains: [], keepOldDomains: true))

    // Back to the old domain: it would chain onto itself, so it has no rule.
    let back = try await fixture.preview(to: legacy + "/")
    #expect(back.plans[0].rules == [.prefix(from: current, to: legacy)])
    #expect(back.summary.edits == 3)
    #expect(RewriteRules.validate(back.plans[0].rules).isEmpty)

    #expect(try fixture.prefix() == current)
    #expect(try fixture.oldDomains() == [legacy])
  }

  @Test("Projects: every project whose usage resolves to the backend; --project narrows; bad domains refused")
  func projectsAndDomains() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(
      try DomainMigration.referencingProjects(backendSlug: "r2", prefixes: [current], in: fixture.database)
        == ["blog", "docs"])
    let narrow = try await fixture.preview(projects: ["docs"])
    #expect(narrow.plans.map(\.project) == ["docs"])
    await #expect(throws: DomainMigrationError.sameAsCurrent(current)) {
      _ = try await fixture.preview(to: "https://IMG.old.com/")
    }
    await #expect(throws: DomainMigrationError.invalidDomain("ftp://x.com")) {
      _ = try await fixture.preview(to: "ftp://x.com")
    }
    #expect(try fixture.runCount() == 1)
  }

  @Test("Every new URL checked; not in the catalog counted apart; params carry the backend slug")
  func preview() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let result = try await fixture.preview()
    #expect(Set(result.verifications.keys) == [
      "\(new)/2024/a.png", "\(new)/2024/b.png", "\(new)/2024/missing.png",
    ])
    #expect(result.summary.verified == ["ok": 3])
    #expect(result.summary.notInCatalog == 1)
    let run = try #require(try RunLog.run(result.runID, in: fixture.database))
    #expect(run.kind == .domainMigrate && run.dryRun && run.backendID == 1)
    let params = try #require(try JSONSerialization.jsonObject(with: Data(run.params.utf8)) as? [String: Any])
    let domain = try #require(params["domain"] as? [String: Any])
    #expect(domain["backend"] as? String == "r2")
    #expect(domain["old_domains"] as? [String] == [legacy])
  }

  @Test("A mismatch or unreachable check refuses the whole apply; the prefix stays")
  func checkRefuses() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let before = try fixture.read("blog", "post.md")
    for (verification, result) in [
      (TargetVerification.mismatch(expected: "1", actual: "9"), "mismatch"),
      (.unreachable(reason: "404"), "unreachable"),
    ] {
      let preview = try await fixture.preview(results: ["\(new)/2024/b.png": verification])
      let runs = try fixture.runCount()
      #expect(throws: DomainMigrationError.targetsNotVerified(
        runID: preview.runID, ["\(new)/2024/b.png (\(result))"])) {
        _ = try fixture.apply(preview.runID)
      }
      #expect(try fixture.runCount() == runs)
      #expect(try fixture.prefix() == current)
      #expect(try fixture.oldDomains() == [legacy])
      #expect(try fixture.read("blog", "post.md") == before)
    }
  }

  @Test("One project's source not allowed refuses the whole apply; the prefix stays, no project written")
  func sourceRefuses() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    fixture.git.set(.dirty(paths: ["index.md"]), for: fixture.source("docs"))
    let preview = try await fixture.preview()
    #expect(throws: RewriteRunError.sourcesNotAllowed(["docs/site (uncommitted changes (1))"])) {
      _ = try fixture.apply(preview.runID)
    }
    #expect(try fixture.prefix() == current)
    #expect(try fixture.read("blog", "post.md").contains(current))
    #expect(try fixture.runCount() == 1)

    // A plain rewrite apply can't write a domain move past its checks.
    #expect(throws: RewriteRunError.notAPreview(preview.runID, reason: "it is a domain_migrate run")) {
      _ = try RewriteRuns.apply(fromRun: preview.runID, allowedSources: ["docs/site"], database: fixture.database, git: fixture.git)
    }
    let applied = try fixture.apply(preview.runID, allowing: ["docs/site"])
    #expect(applied.summary.written == 2)
  }

  @Test("Apply: prefix changed and the old one an old domain; usage points at the same assets; again, nothing to change")
  func apply() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let before = try fixture.usage()
    let preview = try await fixture.preview()
    let result = try fixture.apply(preview.runID)

    #expect(try fixture.prefix() == new)
    #expect(Set(try fixture.oldDomains()) == [current, legacy])
    #expect(try fixture.read("blog", "post.md") == "![a](\(new)/2024/a.png)\n![b](\(new)/2024/b.png)\n")
    #expect(try fixture.read("docs", "index.md") == "![a](\(new)/2024/a.png)\n![m](\(new)/2024/missing.png)\n")
    #expect(result.summary.written == 2)

    let events = try RunLog.events(of: result.runID, in: fixture.database).map(\.event)
    let types = events.map(\.type)
    let changed = try #require(types.firstIndex(of: "prefix_changed"))
    #expect(changed < (types.firstIndex(of: "file_written") ?? 0))
    #expect(events[changed] == .prefixChanged(PrefixChangedEvent(backend: "r2", from: current, to: new)))
    #expect(types.filter { $0 == "rescan_finished" }.count == 2)
    let run = try #require(try RunLog.run(result.runID, in: fixture.database))
    #expect(run.kind == .domainMigrate && run.fromRunID == preview.runID)
    #expect(run.params.contains("\"backend\":\"r2\""))

    let after = try fixture.usage()
    #expect(after.assets == before.assets)
    #expect(before.urls.contains { $0.hasPrefix(legacy) })
    #expect(after.urls.filter { !$0.hasPrefix("https://elsewhere.com") }.allSatisfy { $0.hasPrefix(new + "/") })

    // The same rules again: nothing left to change; the new prefix is current.
    for target in preview.plans {
      let again = try RewritePlanner.plan(
        project: target.project, rules: target.rules, database: fixture.database, git: fixture.git)
      #expect(again.summary.edits == 0)
    }
    await #expect(throws: DomainMigrationError.sameAsCurrent(new)) { _ = try await fixture.preview() }
  }

  @Test("The prefix moved since the preview: refused, nothing written")
  func prefixMoved() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let preview = try await fixture.preview()
    _ = try CatalogConfiguration.setBackendURLPrefix(slug: "r2", urlPrefix: "https://third.com", in: fixture.database)
    #expect(throws: DomainMigrationError.prefixMoved(backend: "r2", preview: current, current: "https://third.com")) {
      _ = try fixture.apply(preview.runID)
    }
    #expect(try fixture.read("blog", "post.md").contains(current))
  }
}

/// Collects values from a `@Sendable` callback.
private final class Recorder<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [T] = []

  func append(_ value: T) { lock.withLock { stored.append(value) } }
  var items: [T] { lock.withLock { stored } }
}

/// Progress and cancel, the review, link counts, and moving old domains
/// onto the current prefix. Same fixture and stubs as above.
@Suite struct DomainMigrationD1Tests {
  @Test("Progress — plan per project, then every check including the old-URL second check; monotone, ends at the total")
  func progress() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let recorder = Recorder<RewritePreviewProgress>()
    let result = try await DomainMigration.preview(
      backend: "r2", to: new,
      verifier: StubVerifier(results: [
        "\(new)/2024/missing.png": .unreachable(reason: "404"),
        "\(current)/2024/missing.png": .unreachable(reason: "404"),
      ]),
      database: fixture.database, git: fixture.git, progress: { recorder.append($0) })
    #expect(result.state == .finished)
    let plan = recorder.items.filter { $0.phase == .plan }
    #expect(plan == [.init(phase: .plan, done: 1, total: 2), .init(phase: .plan, done: 2, total: 2)])
    let check = recorder.items.filter { $0.phase == .check }
    #expect(check.map(\.done) == [1, 2, 3, 4])
    #expect(zip(check, check.dropFirst()).allSatisfy { $0.total <= $1.total })
    #expect(check.last?.total == 4)
    #expect(result.summary.verified == ["ok": 2, "already_broken": 1])
  }

  @Test("Cancel after the first check — run cancelled, events kept, apply refused, prefix and files unchanged")
  func cancel() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("docs", "more.md", (0..<12).map { "![m](\(current)/2024/m\($0).png)\n" }.joined())
    try fixture.rescan("docs")
    let before = try ["post.md"].map { try fixture.read("blog", $0) } + ["index.md", "more.md"].map { try fixture.read("docs", $0) }
    let cancellation = ExternalMigrationCancellation()
    let result = try await DomainMigration.preview(
      backend: "r2", to: new, verifier: StubVerifier(results: [:]), database: fixture.database, git: fixture.git,
      cancellation: cancellation,
      progress: { if $0.phase == .check && $0.done == 1 { cancellation.cancel() } })
    #expect(result.state == .cancelled)
    let run = try #require(try RunLog.run(result.runID, in: fixture.database))
    #expect(run.state == .cancelled)
    let events = try RunLog.events(of: result.runID, in: fixture.database).map(\.event)
    let checked = events.filter { if case .targetVerified = $0 { true } else { false } }.count
    #expect(checked >= 1 && checked <= RewriteTargetCheck.maximumConcurrency)
    #expect(events.contains { if case .filePlanned = $0 { true } else { false } })
    #expect(events.contains {
      if case let .migrationStopped(stop) = $0 { stop.phase == "check" && stop.total == 15 } else { false }
    })
    #expect(throws: RewriteRunError.notAPreview(result.runID, reason: "the preview is cancelled")) {
      _ = try fixture.apply(result.runID)
    }
    #expect(try fixture.prefix() == current)
    let after = try ["post.md"].map { try fixture.read("blog", $0) } + ["index.md", "more.md"].map { try fixture.read("docs", $0) }
    #expect(after == before)
  }

  @Test("The review from the run alone — counts, failures, already broken, per project, sources, applied")
  func review() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    fixture.git.set(.dirty(paths: ["post.md"]), for: fixture.source("blog"))
    let first = try await fixture.preview(results: [
      "\(new)/2024/b.png": .mismatch(expected: "x", actual: "y"),
      "\(new)/2024/missing.png": .unreachable(reason: "timed out"),
      "\(current)/2024/missing.png": .unreachable(reason: "404"),
    ])
    let review = try DomainMigrationReview.load(runID: first.runID, in: fixture.database)
    #expect(review.state == .finished && !review.applied && !review.keepPrefix)
    #expect((review.backend, review.from, review.to, review.oldDomains) == ("r2", current, new, [legacy]))
    #expect(review.projects == [
      .init(project: "blog", files: 1, edits: 2), .init(project: "docs", files: 1, edits: 2),
    ])
    #expect((review.verified, review.fetchedOnly) == (1, 0))
    #expect(review.failed == [.init(url: "\(new)/2024/b.png", result: .mismatch, reason: "serves a different file")])
    #expect(review.alreadyBroken == [.init(url: "\(new)/2024/missing.png", oldReason: "404")])
    #expect(review.sources.map { "\($0.project)/\($0.label) \($0.isClean) \($0.reason ?? "-")" }
      == ["blog/site false uncommitted changes (1)", "docs/site true -"])

    let keep = try await fixture.preview(keepOldDomains: true)
    var kept = try DomainMigrationReview.load(runID: keep.runID, in: fixture.database)
    #expect(kept.oldDomains == [] && (kept.verified, kept.fetchedOnly) == (1, 1) && kept.failed.isEmpty)
    let applied = try fixture.apply(keep.runID, allowing: ["blog/site"])
    kept = try DomainMigrationReview.load(runID: keep.runID, in: fixture.database)
    #expect(kept.appliedRunID == applied.runID)
    #expect(throws: DomainMigrationReview.LoadError.notADomainPreview(applied.runID)) {
      try DomainMigrationReview.load(runID: applied.runID, in: fixture.database)
    }
  }

  @Test("Links per domain — current and old; after a move with old domains 0; with --keep-old-domains not")
  func linkCounts() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let counts = try CatalogConfiguration.domainLinkCounts(backendSlug: "r2", in: fixture.database)
    #expect(counts.current == .init(prefix: current, links: 3))
    #expect(counts.old == [.init(prefix: legacy, links: 1)])

    _ = try fixture.apply(try await fixture.preview().runID)
    let moved = try CatalogConfiguration.domainLinkCounts(backendSlug: "r2", in: fixture.database)
    #expect(moved.current == .init(prefix: new, links: 4))
    #expect(moved.old == [.init(prefix: legacy, links: 0), .init(prefix: current, links: 0)])

    let other = try Fixture()
    defer { other.remove() }
    _ = try other.apply(try await other.preview(keepOldDomains: true).runID)
    let kept = try CatalogConfiguration.domainLinkCounts(backendSlug: "r2", in: other.database)
    #expect(kept.current.links == 3)
    #expect(kept.old == [.init(prefix: legacy, links: 1), .init(prefix: current, links: 0)])
  }

  @Test("Old domains onto the current prefix — only the named old domain moves to the current prefix; prefix kept, no prefix_changed; refusals")
  func flowB() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let older = "https://older.example.com"
    try CatalogConfiguration.addOldDomain(older, backendSlug: "r2", in: fixture.database)
    try fixture.write("docs", "old.md", "![o](\(older)/2024/a.png)\n")
    try fixture.rescan("docs")

    await #expect(throws: DomainMigrationError.sameAsCurrent(current)) {
      _ = try await DomainMigration.preview(
        backend: "r2", to: current, verifier: StubVerifier(results: [:]), database: fixture.database, git: fixture.git)
    }
    for bad in ["https://nope.example.com", current] {
      await #expect(throws: DomainMigrationError.notAnOldDomain(bad, backend: "r2")) {
        _ = try await DomainMigration.preview(
          backend: "r2", to: current, from: [bad], verifier: StubVerifier(results: [:]),
          database: fixture.database, git: fixture.git)
      }
    }
    // Flow A narrowed by --from: the current prefix and only `older`.
    let narrowed = try await DomainMigration.preview(
      backend: "r2", to: new, from: [older], verifier: StubVerifier(results: [:]),
      database: fixture.database, git: fixture.git)
    #expect(narrowed.plans[0].rules == [.prefix(from: current, to: new), .prefix(from: older, to: new)])

    let preview = try await DomainMigration.preview(
      backend: "r2", to: current + "/", from: ["https://LEGACY.example.com"], verifier: StubVerifier(results: [:]),
      database: fixture.database, git: fixture.git)
    #expect(preview.plans.map(\.project) == ["blog"])
    #expect(preview.plans[0].rules == [.prefix(from: legacy, to: current)])
    guard case let .runStarted(params)? = preview.events.first else { Issue.record("no run_started"); return }
    #expect(params.domain == DomainMigrationParams(
      backend: "r2", from: current, to: current, oldDomains: [legacy], keepOldDomains: false, keepPrefix: true))

    let applied = try fixture.apply(preview.runID)
    #expect(try fixture.read("blog", "post.md") == "![a](\(current)/2024/a.png)\n![b](\(current)/2024/b.png)\n")
    #expect(try fixture.read("docs", "old.md") == "![o](\(older)/2024/a.png)\n")
    #expect(try fixture.prefix() == current)
    #expect(try fixture.oldDomains() == [legacy, older])
    let events = try RunLog.events(of: applied.runID, in: fixture.database).map(\.event)
    #expect(!events.contains { if case .prefixChanged = $0 { true } else { false } })
    #expect(events.contains { if case .fileWritten = $0 { true } else { false } })
  }
}

/// One rule for a link on a domain — scheme
/// and host ignore case, the path does not — in every count and in the
/// rewrite; links to images not in the catalog count; the Domain sort.
@Suite struct DomainLinksD4aTests {
  @Test("The rule: scheme and host ignore case, the path and the `/` after the prefix do not")
  func rule() {
    #expect(DomainLinks.isUnder("HTTPS://IMG.Old.com/2024/a.png", prefix: current))
    #expect(DomainLinks.isUnder("https://img.old.com/2024/A.png", prefix: current + "/"))
    #expect(!DomainLinks.isUnder("https://img.old.com", prefix: current))
    #expect(!DomainLinks.isUnder("https://img.old.community/a.png", prefix: current))
    #expect(DomainLinks.isUnder("https://x.org/Pics/a.png", prefix: "https://X.org/Pics"))
    #expect(!DomainLinks.isUnder("https://x.org/pics/a.png", prefix: "https://x.org/Pics"))
  }

  @Test("HTTPS://IMG.Old.com counts under img.old.com and is rewritten; …/A.png and …/a.png stay two images")
  func caseInCountsAndRewrite() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write(
      "blog", "post.md",
      "![a](\(current)/2024/a.png)\n![b](\(legacy)/2024/b.png)\n![c](HTTPS://IMG.Old.com/2024/a.png)\n![d](\(current)/2024/A.png)\n")
    try fixture.write("other", "readme.md", "![x](HTTPS://IMG.OLD.COM/2024/zzz.png)\n")
    try fixture.rescan("blog")
    try fixture.rescan("other")

    let counts = try CatalogConfiguration.domainLinkCounts(backendSlug: "r2", in: fixture.database)
    // blog 3 (a, C, A), docs 2 (a and missing, not in the catalog), other 1.
    #expect(counts.current.links == 6)
    #expect(counts.old.map(\.links) == [1])
    #expect(
      try DomainLinks.countsByProject(prefixes: [current, legacy], in: fixture.database)
        == ["blog": 4, "docs": 2, "other": 1])
    #expect(try DomainLinks.counts(prefixes: [current], project: "docs", in: fixture.database) == [current: 2])
    #expect(
      try DomainMigration.referencingProjects(
        backendSlug: "r2", prefixes: [current], includeResolved: false, in: fixture.database)
        == ["blog", "docs", "other"])

    // Counted is rewritten: 6 + 1 links, 7 edits.
    let preview = try await fixture.preview()
    #expect(preview.summary.edits == counts.current.links + counts.old[0].links)
    _ = try fixture.apply(preview.runID)
    let post = try fixture.read("blog", "post.md")
    #expect(post == "![a](\(new)/2024/a.png)\n![b](\(new)/2024/b.png)\n![c](\(new)/2024/a.png)\n![d](\(new)/2024/A.png)\n")
    #expect(try fixture.read("other", "readme.md") == "![x](\(new)/2024/zzz.png)\n")
  }

  @Test("…/A.png and …/a.png are two different images")
  func pathCase() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("blog", "post.md", "![a](\(current)/2024/a.png)\n![d](\(current)/2024/A.png)\n")
    try fixture.rescan("blog")
    let rows = try fixture.database.read {
      try Row.fetchAll(
        $0,
        sql: """
          SELECT u.raw_url, u.asset_id FROM usage u JOIN project p ON p.id = u.project_id
          WHERE p.slug = 'blog' AND u.last_scan_id = p.last_scan_id ORDER BY u.raw_url
          """)
    }
    #expect(rows.map { $0["raw_url"] as String } == ["\(current)/2024/A.png", "\(current)/2024/a.png"])
    #expect(rows.map { $0["asset_id"] as Int64? } == [nil, 1])
  }

  @Test("Domain sort: by the backend's Current host, ties by id, paged the same both ways")
  func domainSort() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try CatalogConfiguration.addBackend(
      slug: "b2", endpoint: "https://storage.example.com", bucket: "other", region: "auto",
      urlPrefix: "https://AAA.example.org", keychainReference: "backend.b2", to: fixture.database)
    try fixture.database.write { db in
      _ = try Asset(
        sha256: String(repeating: "9", count: 64), backendID: 2, key: "2024/z.png", byteSize: 1,
        mime: "image/png", uploadedAt: "2024-01-01T00:00:00Z", createdAt: "2024-01-01T00:00:00Z",
        updatedAt: "2024-01-01T00:00:00Z"
      ).insertAndFetch(db)
    }
    func keys(_ direction: AssetSort.Direction, limit: Int) throws -> [String] {
      var query = AssetQuery()
      query.sort = AssetSort(field: .domain, direction: direction)
      query.limit = limit
      var result: [String] = []
      while true {
        let page = try CatalogAssets.page(query, in: fixture.database)
        result += page.items.map(\.asset.key)
        guard let next = page.next else { return result }
        query.after = next
      }
    }
    #expect(try keys(.ascending, limit: 100) == ["2024/z.png", "2024/a.png", "2024/b.png"])
    #expect(try keys(.ascending, limit: 1) == ["2024/z.png", "2024/a.png", "2024/b.png"])
    #expect(try keys(.descending, limit: 1) == ["2024/b.png", "2024/a.png", "2024/z.png"])
    #expect(!AssetSort.Field.menuCases.contains(.domain))
  }
}
