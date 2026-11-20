import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing

@testable import pinax

/// `pinax externals migrate` through the real
/// parser on a temporary catalog, source folder and download cache. The
/// fetcher, the bucket and git are stubs; every other host is `.invalid`.
/// Serialized, and apart from ExternalMigrationTests: a migration holds a
/// process-wide gate.
@Suite(.serialized, .migrationGate) struct ExternalsMigrateCommandTests {
  private static let png = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
  private static func image(_ tag: UInt8) -> Data { png + Data([tag]) }
  private static let october = Date(timeIntervalSince1970: 1_793_404_800)  // 2026-10-31

  private let one = "https://a.invalid/one.png"
  private let two = "https://a.invalid/two.png"
  private let other = "https://b.invalid/pic.png"
  private let gone = "https://c.invalid/gone.jpg"

  private final class Fixture {
    let database: DatabasePool
    let directory: URL
    let site: URL
    let cacheRoot: URL
    let backupRoot: URL
    let fetcher = MigrateStubFetcher()
    let bucket = MigrateStubBucket()
    let git = MigrateStubGit()
    let stderr = MigrateLines()

    init(files: [String: [String]]) throws {
      (database, directory) = try makeUITestDatabase()
      site = directory.appendingPathComponent("site", isDirectory: true).resolvingSymlinksInPath()
      cacheRoot = directory.appendingPathComponent("cache", isDirectory: true)
      backupRoot = directory.appendingPathComponent("backups", isDirectory: true)
      try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
      try CatalogConfiguration.setProjectSources(
        slug: "blog", [ProjectSource(label: "site", path: site.path)], in: database)
      for (file, urls) in files {
        try Data(urls.map { "![](\($0))\n" }.joined().utf8).write(to: site.appendingPathComponent(file))
      }
      let scan = try UsageScanner.scan(project: "blog", in: database)
      _ = try CatalogUsage.sync(scan.document, project: "blog", in: database)
    }

    func read(_ file: String) throws -> String {
      try String(contentsOf: site.appendingPathComponent(file), encoding: .utf8)
    }

    func run(_ arguments: [String]) async throws -> RewriteCommandOutput {
      let command = try #require(
        try Pinax.parseAsRoot(["externals", "migrate"] + arguments) as? ExternalsMigrateCommand)
      let bucket = bucket
      let stderr = stderr
      return try await command.perform(
        in: database, fetcher: fetcher, uploader: { _ in bucket }, verifier: bucket, git: git,
        cacheRoot: cacheRoot, backupRoot: backupRoot, now: ExternalsMigrateCommandTests.october,
        log: { stderr.append($0) })
    }

    /// The status `RewriteExit.finish` would exit with.
    func status(_ arguments: [String]) async -> Int32? {
      do {
        return try await run(arguments).exitCode
      } catch {
        return RewriteExit.code(for: error)
      }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
  }

  private func fixture() throws -> Fixture {
    let fixture = try Fixture(files: ["post.md": [one, two, other], "about.md": [gone, one]])
    fixture.fetcher.serve(one, Self.image(1))
    fixture.fetcher.serve(two, Self.image(2))
    fixture.fetcher.serve(other, Self.image(3), mime: "application/octet-stream")
    return fixture
  }

  private func runID(_ output: RewriteCommandOutput) throws -> String {
    let first = try #require(output.stdout.split(separator: "\n").first)
    return try #require(first.split(separator: " ").dropFirst(2).first.map(String.init))
  }

  @Test("Argument errors exit 64: no --all, something to migrate, --apply takes only the run")
  func arguments() {
    func message(_ arguments: [String]) -> (String, Int32) {
      do {
        _ = try Pinax.parseAsRoot(["externals", "migrate"] + arguments)
        return ("parsed", 0)
      } catch {
        return (Pinax.message(for: error), Pinax.exitCode(for: error).rawValue)
      }
    }
    #expect(message(["--project", "blog", "--all"]).1 == 64)
    #expect(message(["--project", "blog"]) == ("Name what to migrate: --host HOST or --url URL, each repeatable.", 64))
    #expect(message(["--host", "a.invalid"]) == ("Give --project SLUG.", 64))
    #expect(message(["--apply"]) == ("--apply needs --from-run ID, the number of the preparation to apply.", 64))
    #expect(message(["--apply", "--from-run", "3", "--host", "a.invalid"]).0.hasPrefix("--apply takes the project"))
    #expect(message(["--project", "blog", "--host", "a.invalid", "--from-run", "3"]) == ("--from-run only goes with --apply.", 64))
    #expect(message(["--project", "blog", "--host", "a.invalid", "--allow-source", "blog/site"]).1 == 64)
    #expect(message(["--apply", "--from-run", "3", "--allow-source", "site"]).1 == 64)
    #expect(message(["--apply", "--from-run", "3", "--allow-source", "blog/site"]) == ("parsed", 0))
    let parsed = try? Pinax.parseAsRoot(
      ["externals", "migrate", "--project", "blog", "--host", "a.invalid", "--url", other, "--host", "c.invalid"])
    let command = parsed as? ExternalsMigrateCommand
    #expect(command?.hosts == ["a.invalid", "c.invalid"])
    #expect(command?.urls == [other])
  }

  @Test("A host or URL not in Other Domains is 64 and lists the project's hosts; an unknown project is 66")
  func unknownTargets() async throws {
    let fixture = try fixture()
    defer { fixture.remove() }
    do {
      _ = try await fixture.run(["--project", "blog", "--host", "a.invalid", "--host", "z.invalid", "--url", "https://y.invalid/x.png"])
      Issue.record("prepared")
    } catch {
      #expect(RewriteExit.code(for: error) == 64)
      #expect(
        String(describing: error)
          == "Not in blog’s Other Domains: z.invalid, https://y.invalid/x.png.\nHosts there: a.invalid, b.invalid, c.invalid.")
    }
    #expect(fixture.fetcher.total == 0)
    #expect(await fixture.status(["--project", "nope", "--host", "a.invalid"]) == 66)
  }

  @Test("Preparation table: run line, hosts with tips, summary rows, skipped; --host and --url mix")
  func prepareTable() async throws {
    let fixture = try fixture()
    defer { fixture.remove() }
    fixture.git.status = .dirty(paths: ["post.md"])
    let before = try fixture.read("post.md")
    let output = try await fixture.run(
      ["--project", "blog", "--host", "A.invalid", "--host", "c.invalid", "--url", other, "--url", one])
    #expect(output.exitCode == 0)
    #expect(try fixture.read("post.md") == before)
    #expect(fixture.bucket.uploads == 0)
    #expect(fixture.fetcher.total == 4)
    let id = try runID(output)
    let lines = output.stdout.components(separatedBy: "\n")
    #expect(lines[0] == "Prepared run \(id) — pinax externals migrate --apply --from-run \(id) to migrate.")
    #expect(lines[1] == "Hosts")
    #expect(lines[2] == "  a.invalid · 3 links")
    #expect(lines.contains("  b.invalid · 1 link · Type read from the image"))
    #expect(lines.contains("  c.invalid · 1 link · 404 · skipped"))
    #expect(lines.contains("Summary"))
    #expect(lines.contains { $0.hasPrefix("  Upload\t3 images · 4 links · ") })
    #expect(lines.contains("  Already in library\t0 images · 0 links"))
    #expect(lines.contains("  Skipped\t1 image · 1 link"))
    #expect(lines.contains("  Files to change\tblog/site · 2 files"))
    #expect(lines.contains("  Bucket\tr2 · images"))
    #expect(lines.contains { $0.hasPrefix("  New keys\t") })
    #expect(lines.contains("Sources"))
    #expect(lines.contains("  blog/site has 1 uncommitted change — to write it, add --allow-source blog/site"))
    #expect(lines.contains { $0.hasPrefix("  Skipped c.invalid/") })
    #expect(fixture.stderr.lines.contains { $0.hasPrefix("Downloading ") })
  }

  @Test("Apply exits 0 and rewrites, printing one line per image on stderr; 69 when the bucket refuses")
  func applyClean() async throws {
    let fixture = try fixture()
    defer { fixture.remove() }
    let id = try runID(try await fixture.run(["--project", "blog", "--host", "a.invalid"]))
    let output = try await fixture.run(["--apply", "--from-run", id])
    #expect(output.exitCode == 0)
    #expect(fixture.bucket.uploads == 2)
    #expect(!(try fixture.read("post.md")).contains(one))
    #expect((try fixture.read("about.md")).contains(gone))
    let lines = output.stdout.components(separatedBy: "\n")
    #expect(lines[0].hasPrefix("Run ") && lines[0].contains("from preparation \(id) · finished — Finished · uploaded 2"))
    #expect(lines.contains("Changed files"))
    #expect(fixture.stderr.lines.filter { $0.hasPrefix("Uploaded ") }.count == 2)

    let again = try runID(try await fixture.run(["--project", "blog", "--url", other]))
    fixture.bucket.failStatus = 403
    #expect(await fixture.status(["--apply", "--from-run", again]) == 69)
  }

  @Test("Apply exits 1 when an image fails its check, and 77 when refused before any upload")
  func applyFailures() async throws {
    let fixture = try fixture()
    defer { fixture.remove() }
    let id = try runID(try await fixture.run(["--project", "blog", "--host", "a.invalid"]))
    fixture.git.status = .dirty(paths: ["post.md"])
    #expect(await fixture.status(["--apply", "--from-run", id]) == 77)
    #expect(fixture.bucket.uploads == 0)
    do {
      _ = try await fixture.run(["--apply", "--from-run", id])
    } catch {
      #expect(
        String(describing: error)
          == "Sources that are not clean must be allowed; nothing was uploaded. Run again with --allow-source blog/site:\n  blog/site (uncommitted changes (1))")
    }
    #expect(
      ExternalsMigrateCommand.listing("H:", (1...7).map(String.init))
        == "H:\n  1\n  2\n  3\n  4\n  5\n  … and 2 more")
    #expect(await fixture.status(["--apply", "--from-run", "999"]) == 66)

    fixture.bucket.brokenSuffix = "two"
    let output = try await fixture.run(["--apply", "--from-run", id, "--allow-source", "blog/site"])
    #expect(output.exitCode == 1)
    #expect(fixture.stderr.lines.contains { $0.contains("doesn’t load") })

    // A used preparation's downloads are gone: refused.
    #expect(await fixture.status(["--apply", "--from-run", id]) == 77)
  }

  @Test("JSON carries the schema, the run and the migration summary")
  func json() async throws {
    let fixture = try fixture()
    defer { fixture.remove() }
    let prepared = try await fixture.run(["--project", "blog", "--host", "a.invalid", "--host", "c.invalid", "--format", "json"])
    let document = try #require(
      try JSONSerialization.jsonObject(with: Data(prepared.stdout.utf8)) as? [String: Any])
    #expect(document["schema"] as? String == "pinax.externals.migrate.v1")
    #expect(document["dry_run"] as? Bool == true)
    #expect(document["backend"] as? String == "r2")
    #expect((document["planned"] as? [Any])?.count == 2)
    #expect((document["skipped"] as? [Any])?.count == 1)
    let summary = try #require(document["summary"] as? [String: Any])
    let migration = try #require(summary["migration"] as? [String: Any])
    #expect((migration["migratable"] as? [String: Any])?["images"] as? Int == 2)
    let id = try #require(document["run_id"] as? Int)

    let applied = try await fixture.run(["--apply", "--from-run", "\(id)", "--format", "json"])
    let result = try #require(try JSONSerialization.jsonObject(with: Data(applied.stdout.utf8)) as? [String: Any])
    #expect(result["schema"] as? String == "pinax.externals.migrate.v1")
    #expect(result["from_run_id"] as? Int == id)
    #expect(result["dry_run"] as? Bool == false)
    #expect(result["state"] as? String == "finished")
    #expect((result["uploaded"] as? [Any])?.count == 2)
    for key in ["reused", "upload_failed", "verify_failed", "key_changed", "summary"] {
      #expect(result[key] != nil, "\(key)")
    }
  }
}

final class MigrateLines: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  func append(_ line: String) { lock.withLock { stored.append(line) } }
  var lines: [String] { lock.withLock { stored } }
}

final class MigrateStubGit: GitStatusProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var stored = SourceGitStatus.clean
  var status: SourceGitStatus {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
  func status(of root: URL) -> SourceGitStatus { status }
}

final class MigrateStubFetcher: PublicObjectFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [String: PublicObject] = [:]
  private var counts = 0

  func serve(_ url: String, _ data: Data, mime: String? = "image/png") {
    lock.withLock { responses[url] = PublicObject(data: data, mime: mime, contentLength: nil) }
  }

  var total: Int { lock.withLock { counts } }

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    let object = try await fetchObject(url)
    return (object.data, object.mime, object.contentLength)
  }

  func fetchObject(_ url: URL) async throws -> PublicObject {
    let response = lock.withLock {
      counts += 1
      return responses[url.absoluteString]
    }
    guard let response else { throw PublicObjectFetchError.notFound(url) }
    return response
  }
}

/// Keeps uploads and serves them back to the check; `img.example.com` is
/// the fixture backend's prefix.
final class MigrateStubBucket: Uploader, RewriteTargetVerifying, @unchecked Sendable {
  private let lock = NSLock()
  private var objects: [String: Data] = [:]
  private var count = 0
  private var status: Int?
  private var broken: String?

  var uploads: Int { lock.withLock { count } }
  var failStatus: Int? {
    get { lock.withLock { status } }
    set { lock.withLock { status = newValue } }
  }
  /// New URLs containing this fail the check.
  var brokenSuffix: String? {
    get { lock.withLock { broken } }
    set { lock.withLock { broken = newValue } }
  }

  func upload(_ request: UploadRequest) async throws -> UploadResult {
    try lock.withLock {
      count += 1
      if let status { throw S3UploaderError.http(statusCode: status, body: "refused") }
      objects[request.key] = request.data
    }
    return UploadResult(key: request.key, etag: "stub")
  }

  func exists(key: String) async throws -> Bool { lock.withLock { objects[key] != nil } }

  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    let data: Data? = lock.withLock {
      if let broken, url.contains(broken) { return nil }
      return objects[String(url.dropFirst("https://img.example.com/".count))]
    }
    guard let data else { return .unreachable(reason: "HTTP 404") }
    let sha = Hashing.sha256(of: data)
    if let expectedSHA256, expectedSHA256 != sha { return .mismatch(expected: expectedSHA256, actual: sha) }
    return .ok(sha256: sha)
  }
}
