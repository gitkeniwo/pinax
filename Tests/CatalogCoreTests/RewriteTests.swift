import CatalogCore
import Foundation
import GRDB
import Testing

/// The rewrite engine. Every fixture and expected byte is
/// written out by hand; git is a stub except in `RewriteGitTests`.
private let old = "https://img.old.com"
private let new = "https://img.new.com/blog"
private let domainMove = RewriteRule.prefix(from: old, to: new)

/// A temporary folder holding source folders; removed by `remove()`.
private struct Workspace {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-rewrite-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func source(_ label: String, include: [String] = []) -> ProjectSource {
    ProjectSource(label: label, path: directory.appendingPathComponent(label).path, include: include)
  }

  func url(_ path: String) -> URL { directory.appendingPathComponent(path) }

  func write(_ path: String, _ text: String) throws { try write(path, Data(text.utf8)) }

  func write(_ path: String, _ data: Data) throws {
    let url = url(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  func read(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Git status by source folder path; anything not set is clean.
private final class StubGit: GitStatusProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [String: SourceGitStatus] = [:]

  func set(_ status: SourceGitStatus, for source: ProjectSource) {
    lock.lock()
    defer { lock.unlock() }
    statuses[URL(fileURLWithPath: source.path, isDirectory: true).path] = status
  }

  func status(of root: URL) -> SourceGitStatus {
    lock.lock()
    defer { lock.unlock() }
    return statuses[root.path] ?? .clean
  }
}

private func plan(
  _ sources: [ProjectSource], _ rules: [RewriteRule] = [domainMove], git: GitStatusProviding = StubGit()
) throws -> RewritePlan {
  try RewritePlanner.plan(project: "blog", sources: sources, rules: rules, git: git)
}

// MARK: - Rules

@Suite struct RewriteRuleTests {
  @Test("urlSpans: range and literal are the text as written; url is decoded")
  func spans() {
    let line = #"a <https://x.com/a b.png> "https://x.com/?a=1&amp;b=2" https://x.com/c.png."#[...]
    let spans = UsageScanner.urlSpans(in: line)
    #expect(spans.map(\.literal) == [
      "https://x.com/a b.png", "https://x.com/?a=1&amp;b=2", "https://x.com/c.png",
    ])
    #expect(spans.map(\.url) == [
      "https://x.com/a b.png", "https://x.com/?a=1&b=2", "https://x.com/c.png",
    ])
    #expect(spans.map(\.angled) == [true, false, false])
    #expect(spans.map { String(line[$0.range]) } == spans.map(\.literal))
    #expect(UsageScanner.urls(in: line) == spans.map(\.url))
  }

  @Test("prefix: boundary at `/`, scheme and host ignore case, path does not, rest carried")
  func prefix() {
    let rule = RewriteRule.prefix(from: "https://cdn.a.com/", to: "https://b.com/x/")
    #expect(rule.rewrite("https://cdn.a.com/p/q.png?w=6#f") == "https://b.com/x/p/q.png?w=6#f")
    #expect(rule.rewrite("HTTPS://CDN.A.COM/Q.png") == "https://b.com/x/Q.png")
    #expect(rule.rewrite("https://cdn.a.com.evil/x") == nil)
    #expect(rule.rewrite("https://cdn.a.com") == nil)
    #expect(rule.rewrite("https://cdn.a.com/") == "https://b.com/x/")
    let path = RewriteRule.prefix(from: "https://a.com/Img", to: "https://b.com")
    #expect(path.rewrite("https://a.com/img/x.png") == nil)
    #expect(path.rewrite("https://a.com/Img/x.png") == "https://b.com/x.png")
  }

  @Test("exact matches the whole decoded URL; exact beats prefix; longest prefix wins")
  func precedence() {
    let rules: [RewriteRule] = [
      .prefix(from: "https://a.com", to: "https://b.com"),
      .prefix(from: "https://a.com/deep", to: "https://c.com"),
      .exact(from: "https://a.com/deep/x.png?w=1", to: "https://d.com/x.png"),
    ]
    func match(_ url: String) -> String? {
      RewriteRules.match(url, in: rules).map { "\($0.index) \($0.url)" }
    }
    #expect(RewriteRules.validate(rules) == [])
    #expect(match("https://a.com/deep/x.png?w=1") == "2 https://d.com/x.png")
    #expect(match("https://a.com/deep/x.png") == "1 https://c.com/x.png")
    #expect(match("https://a.com/x.png") == "0 https://b.com/x.png")
    #expect(match("https://a.com/deep/x.png?w=2") == "1 https://c.com/x.png?w=2")
    #expect(match("https://e.com/x.png") == nil)
  }

  @Test("validation: empty, duplicate, unchanged, not http(s), chained")
  func validation() {
    #expect(RewriteRules.validate([]) == [.empty])
    #expect(
      RewriteRules.validate([
        .prefix(from: "https://a.com/", to: "https://b.com"),
        .prefix(from: "HTTPS://A.com", to: "https://c.com"),
      ]) == [.duplicateFrom("HTTPS://A.com")])
    #expect(
      RewriteRules.validate([.prefix(from: "https://a.com", to: "https://A.COM/")])
        == [.unchanged(index: 0)])
    #expect(
      RewriteRules.validate([.exact(from: "ftp://a.com/x", to: "/x")])
        == [.notHTTPURL(index: 0, url: "ftp://a.com/x"), .notHTTPURL(index: 0, url: "/x")])
    #expect(
      RewriteRules.validate([.prefix(from: "https://a.com?x=1", to: "https://b.com")])
        == [.notHTTPURL(index: 0, url: "https://a.com?x=1")])
    // a → b, b → c: one pass would not finish.
    #expect(
      RewriteRules.validate([
        .prefix(from: "https://a.com", to: "https://b.com"),
        .prefix(from: "https://b.com", to: "https://c.com"),
      ]) == [.chained(index: 0, by: 1)])
    // A prefix writing under its own `from`.
    #expect(
      RewriteRules.validate([.prefix(from: "https://a.com", to: "https://a.com/v2")])
        == [.chained(index: 0, by: 0)])
    #expect(
      RewriteRules.validate([.prefix(from: "https://a.com/v2", to: "https://a.com")])
        == [.chained(index: 0, by: 0)])
    #expect(
      RewriteRules.validate([
        .exact(from: "https://x.com/1.png", to: "https://a.com/1.png"),
        .prefix(from: "https://a.com", to: "https://b.com"),
      ]) == [.chained(index: 0, by: 1)])
    #expect(
      RewriteRules.validate([
        .prefix(from: "https://a.com", to: "https://b.com"),
        .exact(from: "https://b.com/1.png", to: "https://c.com/1.png"),
      ]) == [.chained(index: 0, by: 1)])
    #expect(throws: RewritePlanError.invalidRules([.empty])) {
      try RewritePlanner.plan(project: "p", sources: [], rules: [], git: StubGit())
    }
  }
}

// MARK: - Planning

@Suite struct RewritePlannerTests {
  @Test("Edits are spliced by byte: BOM, CRLF, &amp;, <…> and no final newline survive")
  func bytes() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let source = workspace.source("site")
    try workspace.write(
      "site/a.md",
      "\u{FEFF}![a](https://img.old.com/a.png)\r\n"
        + "x <https://img.old.com/b c.png> y\r\n"
        + #"<img src="https://img.old.com/c.png?w=1&amp;h=2">"# + "\r\n"
        + "last https://IMG.OLD.COM/d.png")
    let result = try plan([source])
    let file = try #require(result.files.first)
    #expect(result.files.count == 1)
    #expect(file.path == "a.md")
    #expect(
      file.newContent
        == Data(
          ("\u{FEFF}![a](https://img.new.com/blog/a.png)\r\n"
            + "x <https://img.new.com/blog/b c.png> y\r\n"
            + #"<img src="https://img.new.com/blog/c.png?w=1&amp;h=2">"# + "\r\n"
            + "last https://img.new.com/blog/d.png").utf8))
    #expect(file.edits.map(\.line) == [1, 2, 3, 4])
    #expect(file.edits.map(\.column) == [7, 4, 11, 6])
    #expect(file.edits[2].oldText == "https://img.old.com/c.png?w=1&amp;h=2")
    #expect(file.edits[2].newText == "https://img.new.com/blog/c.png?w=1&amp;h=2")
    #expect(file.originalSHA256 == Hashing.sha256(of: try workspace.read("site/a.md")))
    #expect(result.summary.edits == 4)
    #expect(result.summary.files == 1)
    #expect(result.summary.editsByRule == [4])
    #expect(result.targets.map(\.url) == [
      "https://img.new.com/blog/a.png", "https://img.new.com/blog/b c.png",
      "https://img.new.com/blog/c.png?w=1&h=2", "https://img.new.com/blog/d.png",
    ])
  }

  @Test("not_utf8 files get no edits; unsafe_target spots are left alone")
  func skips() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let source = workspace.source("site")
    var latin = Data("https://img.old.com/z.png caf".utf8)
    latin.append(contentsOf: [0xE9, 0x0A])
    try workspace.write("site/latin.md", latin)
    try workspace.write(
      "site/b.md", "see https://img.old.com/x/e.png now\n[e](<https://img.old.com/x/e.png>)\n")
    // The new URL ends in `.`: bare, the scanner would read it without the dot.
    // The exact rule wins over the prefix even where it cannot be written.
    let rules: [RewriteRule] = [
      .exact(from: "https://img.old.com/x/e.png", to: "https://c.com/e."), domainMove,
    ]
    let result = try plan([source], rules)
    #expect(result.files.map(\.path) == ["b.md", "latin.md"])
    let b = result.files[0]
    #expect(b.edits.map(\.line) == [2])
    #expect(b.skips.map(\.reason) == [.unsafeTarget])
    #expect(b.skips.map(\.line) == [1])
    #expect(b.newContent == Data("see https://img.old.com/x/e.png now\n[e](<https://c.com/e.>)\n".utf8))
    let latinFile = result.files[1]
    #expect(latinFile.edits.isEmpty)
    #expect(latinFile.newContent == nil)
    #expect(latinFile.skips.map(\.reason) == [.notUTF8])
    #expect(result.summary.files == 1)
    #expect(result.summary.skippedByReason == [.notUTF8: 1, .unsafeTarget: 1])

    let paren = try plan(
      [source], [.exact(from: "https://img.old.com/x/e.png", to: "https://c.com/e)")])
    #expect(paren.files[0].skips.map(\.line) == [1])
    #expect(paren.files[0].edits.isEmpty == false)
  }

  @Test("Walks like the scan; counts protocol-relative URLs without changing them")
  func walkAndProtocolRelative() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let source = workspace.source("site")
    try workspace.write(
      "site/p.html",
      #"<img src="//img.old.com/p.png"> <img src="//IMG.old.com/q.png"> https://img.old.com/r.png"#
        + "\n")
    try workspace.write("site/.hidden/x.md", "https://img.old.com/h.png\n")
    try workspace.write("site/node_modules/x.md", "https://img.old.com/n.png\n")
    try workspace.write("site/notes.txt", "https://img.old.com/t.png\n")
    try workspace.write("outside.md", "https://img.old.com/o.png\n")
    try FileManager.default.createSymbolicLink(
      at: workspace.url("site/link.md"), withDestinationURL: workspace.url("outside.md"))
    let result = try plan([source])
    #expect(result.files.map(\.path) == ["p.html"])
    #expect(result.files[0].edits.map(\.oldText) == ["https://img.old.com/r.png"])
    #expect(result.summary.protocolRelative == 2)
    #expect(
      result.protocolRelative == [
        ProtocolRelativeHit(sourceLabel: "site", path: "p.html", line: 1, host: "img.old.com"),
        ProtocolRelativeHit(sourceLabel: "site", path: "p.html", line: 1, host: "img.old.com"),
      ])
  }

  @Test("Sources carry their git status; a missing folder fails the plan")
  func sources() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let site = workspace.source("site")
    let docs = workspace.source("docs")
    try workspace.write("site/a.md", "https://img.old.com/a.png\n")
    try workspace.write("docs/a.md", "nothing\n")
    let git = StubGit()
    git.set(.dirty(paths: ["a.md"]), for: docs)
    let result = try plan([site, docs], git: git)
    #expect(result.sources.map(\.git) == [.clean, .dirty(paths: ["a.md"])])
    #expect(result.sources.map(\.label) == ["site", "docs"])
    #expect(throws: UsageScanError.sourceNotFound(label: "gone", path: workspace.source("gone").path)) {
      try plan([workspace.source("gone")])
    }
  }

  @Test("Through the catalog: targets carry the sha256 of the asset the old URL names")
  func catalogTargets() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let database = try Database.open(at: workspace.url("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://storage.example.com", bucket: "images", region: "auto",
      urlPrefix: old, keychainReference: "backend.r2", to: database)
    _ = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "", backendSlug: "r2", to: database)
    let site = workspace.source("site")
    try CatalogConfiguration.setProjectSources(slug: "blog", [site], in: database)
    try database.write { db in
      _ = try Asset(
        sha256: String(repeating: "a", count: 64), backendID: 1, key: "2024/a.png", byteSize: 1,
        mime: "image/png", uploadedAt: "2024-01-01T00:00:00Z", createdAt: "2024-01-01T00:00:00Z",
        updatedAt: "2024-01-01T00:00:00Z"
      ).insertAndFetch(db)
    }
    try workspace.write("site/a.md", "https://img.old.com/2024/a.png https://img.old.com/2024/b.png\n")
    let result = try RewritePlanner.plan(
      project: "blog", rules: [domainMove], database: database, git: StubGit())
    #expect(
      result.targets == [
        RewriteTarget(
          url: "https://img.new.com/blog/2024/a.png", expectedSHA256: String(repeating: "a", count: 64),
          oldURLs: ["https://img.old.com/2024/a.png"]),
        RewriteTarget(
          url: "https://img.new.com/blog/2024/b.png", expectedSHA256: nil,
          oldURLs: ["https://img.old.com/2024/b.png"]),
      ])
  }

  @Test("Unified diff: git's hunk headers, context 3, no-newline marker")
  func diff() {
    #expect(RewriteDiff.unified(label: "s", path: "p", old: "a\n", new: "a\n") == "")
    #expect(
      RewriteDiff.unified(label: "site", path: "posts/a.md", old: "a\nb\nc\n", new: "a\nB\nc\n")
        == "--- a/site/posts/a.md\n+++ b/site/posts/a.md\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")
    #expect(
      RewriteDiff.unified(label: "s", path: "p", old: "x", new: "y")
        == "--- a/s/p\n+++ b/s/p\n@@ -1 +1 @@\n-x\n\\ No newline at end of file\n+y\n"
        + "\\ No newline at end of file\n")
    #expect(
      RewriteDiff.unified(label: "s", path: "p", old: "a\n", new: "a\nb\n")
        == "--- a/s/p\n+++ b/s/p\n@@ -1 +1,2 @@\n a\n+b\n")
    let ten = (1...10).map { "\($0)\n" }.joined()
    let changed = ten.replacingOccurrences(of: "1\n", with: "one\n", options: .anchored)
      .replacingOccurrences(of: "10\n", with: "ten\n")
    #expect(
      RewriteDiff.unified(label: "s", path: "p", old: ten, new: changed)
        == "--- a/s/p\n+++ b/s/p\n@@ -1,4 +1,4 @@\n-1\n+one\n 2\n 3\n 4\n"
        + "@@ -7,4 +7,4 @@\n 7\n 8\n 9\n-10\n+ten\n")
    #expect(
      RewriteDiff.unified(label: "s", path: "p", old: ten, new: changed, context: 0)
        == "--- a/s/p\n+++ b/s/p\n@@ -1 +1 @@\n-1\n+one\n@@ -10 +10 @@\n-10\n+ten\n")
  }
}

// MARK: - Applying

@Suite struct RewriteApplierTests {
  private func setUp() throws -> (Workspace, ProjectSource, ProjectSource, StubGit) {
    let workspace = try Workspace()
    let site = workspace.source("site")
    let docs = workspace.source("docs")
    try workspace.write("site/a.md", "https://img.old.com/a.png\n")
    try workspace.write("site/b.md", "x https://img.old.com/b.png\n")
    try workspace.write("docs/c.md", "https://img.old.com/c.png")
    return (workspace, site, docs, StubGit())
  }

  @Test("An unclean source not allowed refuses the whole run; status is taken again at apply")
  func refusal() throws {
    let (workspace, site, docs, git) = try setUp()
    defer { workspace.remove() }
    let result = try plan([site, docs], git: git)
    let backups = workspace.url("backups")
    git.set(.notGit, for: docs)
    #expect(
      throws: RewriteApplyError.sourcesNotAllowed([
        RewriteSourceState(label: "docs", path: docs.path, git: .notGit)
      ])
    ) {
      try RewriteApplier.apply(
        plan: result, allowedSources: [], backupRoot: backups, runID: "1", git: git)
    }
    #expect(try workspace.read("site/a.md") == Data("https://img.old.com/a.png\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: backups.path))
  }

  @Test("Allowed unclean sources are backed up; clean ones are not; mode bits kept; idempotent")
  func write() throws {
    let (workspace, site, docs, git) = try setUp()
    defer { workspace.remove() }
    git.set(.dirty(paths: ["c.md"]), for: docs)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o640], ofItemAtPath: workspace.url("site/a.md").path)
    let result = try plan([site, docs], git: git)
    let backups = workspace.url("backups")
    let written = try RewriteApplier.apply(
      plan: result, allowedSources: ["docs"], backupRoot: backups, runID: "7", git: git)
    let backupPath = backups.appendingPathComponent("7/docs/c.md").path
    #expect(
      written == [
        RewriteFileResult(
          sourceLabel: "site", path: "a.md",
          outcome: .written(
            beforeSHA256: Hashing.sha256(of: Data("https://img.old.com/a.png\n".utf8)),
            afterSHA256: Hashing.sha256(of: Data("https://img.new.com/blog/a.png\n".utf8)),
            edits: 1, backupPath: nil)),
        RewriteFileResult(
          sourceLabel: "site", path: "b.md",
          outcome: .written(
            beforeSHA256: result.files[1].originalSHA256,
            afterSHA256: Hashing.sha256(of: Data("x https://img.new.com/blog/b.png\n".utf8)),
            edits: 1, backupPath: nil)),
        RewriteFileResult(
          sourceLabel: "docs", path: "c.md",
          outcome: .written(
            beforeSHA256: result.files[2].originalSHA256,
            afterSHA256: Hashing.sha256(of: Data("https://img.new.com/blog/c.png".utf8)),
            edits: 1, backupPath: backupPath)),
      ])
    #expect(try workspace.read("docs/c.md") == Data("https://img.new.com/blog/c.png".utf8))
    #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == Data("https://img.old.com/c.png".utf8))
    #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent("7/site").path))
    let mode = try FileManager.default.attributesOfItem(atPath: workspace.url("site/a.md").path)[
      .posixPermissions] as? Int
    #expect(mode == 0o640)
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.url("site").path).sorted() == ["a.md", "b.md"])

    let again = try plan([site, docs], git: git)
    #expect(again.summary.edits == 0)
    #expect(again.files.isEmpty)
  }

  @Test("A file changed since the plan, or now a symbolic link, is skipped; the rest are written")
  func skips() throws {
    let (workspace, site, docs, git) = try setUp()
    defer { workspace.remove() }
    let result = try plan([site, docs], git: git)
    try workspace.write("site/a.md", "https://img.old.com/a.png edited\n")
    try FileManager.default.removeItem(at: workspace.url("site/b.md"))
    try workspace.write("elsewhere.md", "https://img.old.com/b.png\n")
    try FileManager.default.createSymbolicLink(
      at: workspace.url("site/b.md"), withDestinationURL: workspace.url("elsewhere.md"))
    let outcomes = try RewriteApplier.apply(
      plan: result, allowedSources: [], backupRoot: workspace.url("backups"), runID: "1", git: git
    ).map(\.outcome)
    #expect(outcomes.count == 3)
    #expect(outcomes[0] == .skipped(.changedSincePlan))
    #expect(outcomes[1] == .skipped(.symlink))
    if case .written = outcomes[2] {} else { Issue.record("docs/c.md not written: \(outcomes[2])") }
    #expect(try workspace.read("site/a.md") == Data("https://img.old.com/a.png edited\n".utf8))
    #expect(try workspace.read("elsewhere.md") == Data("https://img.old.com/b.png\n".utf8))
  }
}

// MARK: - Git status with a real git

@Suite struct RewriteGitTests {
  private func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "-c", "user.name=t", "-c", "user.email=t@example.com"]
      + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "git \(arguments)")
  }

  @Test("No .git anywhere up: notGit, without starting a process")
  func notGit() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    // A git that does not exist would report unknown if it were started.
    let provider = GitStatusProvider(gitPath: "/nonexistent/git")
    #expect(provider.status(of: workspace.directory) == .notGit)
    try FileManager.default.createDirectory(
      at: workspace.url(".git"), withIntermediateDirectories: true)
    if case .unknown = provider.status(of: workspace.directory) {} else {
      Issue.record("expected unknown")
    }
  }

  @Test("A temporary repository: clean, then dirty only for changes under the source")
  func realGit() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let repository = workspace.directory
    let site = repository.appendingPathComponent("site")
    try workspace.write("site/a.md", "a\n")
    try workspace.write("site/b.md", "b\n")
    try workspace.write("other.md", "o\n")
    try git(["init", "-q"], in: repository)
    try git(["add", "."], in: repository)
    try git(["commit", "-q", "-m", "init"], in: repository)
    let provider = GitStatusProvider()
    #expect(provider.status(of: site) == .clean)
    try workspace.write("other.md", "changed\n")
    #expect(provider.status(of: site) == .clean)
    try workspace.write("site/a.md", "changed\n")
    try workspace.write("site/new.md", "new\n")
    try git(["mv", "site/b.md", "site/c.md"], in: repository)
    guard case let .dirty(paths) = provider.status(of: site) else {
      Issue.record("expected dirty")
      return
    }
    #expect(Set(paths) == ["site/a.md", "site/c.md", "site/new.md"])
  }
}

// MARK: - Target verification

private struct StubFetcher: PublicObjectFetching {
  let objects: [String: Data]

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    guard let data = objects[url.absoluteString] else { throw PublicObjectFetchError.notFound(url) }
    return (data, "image/png", Int64(data.count))
  }
}

private actor InFlight {
  var now = 0
  var most = 0
  func enter() {
    now += 1
    most = max(most, now)
  }
  func leave() { now -= 1 }
}

private struct SlowVerifier: RewriteTargetVerifying {
  let inFlight: InFlight

  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    await inFlight.enter()
    try? await Task.sleep(nanoseconds: 20_000_000)
    await inFlight.leave()
    return .ok(sha256: url)
  }
}

@Suite struct RewriteTargetTests {
  @Test("Verifier: ok, ok without expectation, mismatch, unreachable")
  func verifier() async {
    let png = Data("png".utf8)
    let sha = Hashing.sha256(of: png)
    let verifier = PublicTargetVerifier(fetcher: StubFetcher(objects: ["https://b.com/a.png": png]))
    #expect(await verifier.verify("https://b.com/a.png", expectedSHA256: sha) == .ok(sha256: sha))
    #expect(await verifier.verify("https://b.com/a.png", expectedSHA256: nil) == .ok(sha256: sha))
    #expect(
      await verifier.verify("https://b.com/a.png", expectedSHA256: "f")
        == .mismatch(expected: "f", actual: sha))
    #expect(
      await verifier.verify("https://b.com/gone.png", expectedSHA256: nil)
        == .unreachable(
          reason: PublicObjectFetchError.notFound(URL(string: "https://b.com/gone.png")!).description))
  }

  @Test("Checks every target, at most 4 at a time")
  func concurrency() async {
    let inFlight = InFlight()
    let targets = (1...12).map { RewriteTarget(url: "https://b.com/\($0).png", expectedSHA256: nil) }
    let results = await RewriteTargetCheck.verify(targets, with: SlowVerifier(inFlight: inFlight))
    #expect(results.count == 12)
    #expect(results["https://b.com/3.png"] == .ok(sha256: "https://b.com/3.png"))
    #expect(await inFlight.most == 4)
  }
}
