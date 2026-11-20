import Foundation
import GRDB
import Testing

@testable import CatalogCore

/// Prepare / apply of `external_migrate`. A temporary
/// catalog, source folder and download cache; the fetcher, the bucket and
/// git are stubs, and every host is `.invalid`. Serialized: a migration
/// holds a process-wide gate.
private let prefix = "https://img.pinax.invalid"
private let png = Data(
  base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
/// A PNG whose sha256 differs per tag.
private func image(_ tag: UInt8) -> Data { png + Data([tag]) }
private func jpeg(_ tag: UInt8) -> Data { Data([0xff, 0xd8, 0xff, 0xe0, tag]) }
private let october = Date(timeIntervalSince1970: 1_793_404_800)  // 2026-10-31
private let november = Date(timeIntervalSince1970: 1_793_491_200)  // 2026-11-01

private final class MigrationFixture {
  let directory: URL
  let database: CatalogDatabasePool
  let git = MigrationGit()
  let fetcher = MigrationFetcher()
  let bucket = MigrationBucket()
  let cacheRoot: URL
  let backupRoot: URL
  let site: URL

  init(template: String? = nil) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-migrate-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    site = directory.appendingPathComponent("site", isDirectory: true)
    cacheRoot = directory.appendingPathComponent("cache", isDirectory: true)
    backupRoot = directory.appendingPathComponent("backups", isDirectory: true)
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://storage.pinax.invalid", bucket: "images", region: "auto",
      urlPrefix: prefix, keychainReference: "backend.r2", to: database)
    _ = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "", backendSlug: "r2", to: database)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: site.path)], in: database)
    if let template {
      try database.write { db in
        try db.execute(sql: "UPDATE project SET key_template = ?", arguments: [template])
      }
    }
  }

  func write(_ file: String, _ text: String) throws {
    try Data(text.utf8).write(to: site.appendingPathComponent(file))
  }

  func read(_ file: String) throws -> String {
    try String(contentsOf: site.appendingPathComponent(file), encoding: .utf8)
  }

  /// Writes `file` with one Markdown image per URL, then scans.
  func refer(_ file: String, _ urls: [String]) throws {
    try write(file, urls.map { "![](\($0))\n" }.joined())
    try scan()
  }

  func scan() throws {
    let scan = try UsageScanner.scan(project: "blog", in: database)
    _ = try CatalogUsage.sync(scan.document, project: "blog", in: database)
  }

  func prepare(
    _ urls: [String], now: Date = october,
    cancellation: ExternalMigrationCancellation = ExternalMigrationCancellation()
  ) async throws -> ExternalMigrationResult {
    try await ExternalMigration.prepare(
      targets: [ExternalMigrationTarget(project: "blog", urls: urls)], database: database, fetcher: fetcher,
      git: git, cacheRoot: cacheRoot, now: now, cancellation: cancellation)
  }

  func apply(
    _ runID: Int64, allowed: Set<String> = [], now: Date = october,
    cancellation: ExternalMigrationCancellation = ExternalMigrationCancellation()
  ) async throws -> ExternalMigrationResult {
    try await ExternalMigration.apply(
      fromRun: runID, allowedSources: allowed, database: database, uploader: bucket, verifier: bucket, git: git,
      cacheRoot: cacheRoot, backupRoot: backupRoot, now: now, cancellation: cancellation)
  }

  func assets() throws -> [Asset] {
    try database.read { try Asset.order(Column("id")).fetchAll($0) }
  }

  func otherDomainURLs() async throws -> [String] {
    try await CatalogUsage.externalReferences(project: "blog", in: database).references
      .filter { $0.domain == .other }.map(\.rawURL)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class MigrationGit: GitStatusProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [String: SourceGitStatus] = [:]

  func set(_ status: SourceGitStatus, for path: String) {
    lock.withLock { statuses[path] = status }
  }

  func status(of root: URL) -> SourceGitStatus {
    lock.withLock { statuses[root.path] ?? .clean }
  }
}

private final class MigrationFetcher: PublicObjectFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [String: Result<PublicObject, Error>] = [:]
  private var counts: [String: Int] = [:]
  var onFetch: (@Sendable (Int) -> Void)?

  func serve(_ url: String, _ data: Data, mime: String? = "image/png") {
    lock.withLock { responses[url] = .success(PublicObject(data: data, mime: mime, contentLength: nil)) }
  }

  func fail(_ url: String, _ error: Error) {
    lock.withLock { responses[url] = .failure(error) }
  }

  func count(_ url: String) -> Int { lock.withLock { counts[url] ?? 0 } }

  var total: Int { lock.withLock { counts.values.reduce(0, +) } }

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    let object = try await fetchObject(url)
    return (object.data, object.mime, object.contentLength)
  }

  func fetchObject(_ url: URL) async throws -> PublicObject {
    let (response, total): (Result<PublicObject, Error>?, Int) = lock.withLock {
      counts[url.absoluteString, default: 0] += 1
      return (responses[url.absoluteString], counts.values.reduce(0, +))
    }
    onFetch?(total)
    guard let response else { throw PublicObjectFetchError.notFound(url) }
    return try response.get()
  }
}

/// The bucket: keeps what is uploaded and serves it back to the check.
private final class MigrationBucket: Uploader, RewriteTargetVerifying, @unchecked Sendable {
  private let lock = NSLock()
  private var objects: [String: Data] = [:]
  private(set) var requests: [UploadRequest] = []
  var failStatus: Int?
  var broken: Set<String> = []
  var onUpload: (@Sendable (Int) -> Void)?

  var uploads: Int { lock.withLock { requests.count } }

  func upload(_ request: UploadRequest) async throws -> UploadResult {
    let count: Int = try lock.withLock {
      requests.append(request)
      if let failStatus { throw S3UploaderError.http(statusCode: failStatus, body: "refused") }
      objects[request.key] = request.data
      return requests.count
    }
    onUpload?(count)
    return UploadResult(key: request.key, etag: "stub")
  }

  func exists(key: String) async throws -> Bool { lock.withLock { objects[key] != nil } }

  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    let data: Data? = lock.withLock {
      broken.contains(url) ? nil : objects[String(url.dropFirst(prefix.count + 1))]
    }
    guard let data else { return .unreachable(reason: "HTTP 404") }
    let sha = Hashing.sha256(of: data)
    if let expectedSHA256, expectedSHA256 != sha { return .mismatch(expected: expectedSHA256, actual: sha) }
    return .ok(sha256: sha)
  }
}

private func planned(_ result: ExternalMigrationResult) -> [String: MigrationPlannedEvent] {
  var events: [String: MigrationPlannedEvent] = [:]
  for case let .migrationPlanned(event) in result.events { events[event.url] = event }
  return events
}

@Suite(.serialized, .migrationGate) struct ExternalMigrationTests {
  // MARK: - Pure rules

  @Test("The host tip table")
  func hostTips() {
    #expect(ExternalMigration.hostTip(host: "pub-2fc18c.r2.dev") == "Your other bucket")
    #expect(ExternalMigration.hostTip(host: "upload.wikimedia.org") == "Usually asks for attribution")
    #expect(ExternalMigration.hostTip(host: "en.wikipedia.org") == "Usually asks for attribution")
    #expect(ExternalMigration.hostTip(host: "i.imgur.com") == nil)
  }

  @Test("-{hash} goes before the last .{ext}, at the end without one, nowhere with {hash}")
  func migrationTemplates() {
    #expect(ExternalMigration.migrationTemplate("{year}/{name}.{ext}") == "{year}/{name}-{hash}.{ext}")
    #expect(ExternalMigration.migrationTemplate("{name}.{ext}.{ext}") == "{name}.{ext}-{hash}.{ext}")
    #expect(ExternalMigration.migrationTemplate("{year}/{name}") == "{year}/{name}-{hash}")
    #expect(ExternalMigration.migrationTemplate(KeyTemplate.defaultTemplate) == KeyTemplate.defaultTemplate)
  }

  @Test("File names drop the query, decode, and take the sniffed type's extension")
  func filenames() {
    #expect(ExternalMigration.filename(for: "https://h.invalid/a/%E5%9B%BE.png?w=440", mime: "image/png") == "图.png")
    #expect(ExternalMigration.filename(for: "https://h.invalid/img?id=3", mime: "image/jpeg") == "img.jpg")
    #expect(ExternalMigration.filename(for: "https://h.invalid/x.png", mime: "image/jpeg") == "x.jpg")
    #expect(ExternalMigration.filename(for: "https://h.invalid/show.php", mime: "image/gif") == "show.php.gif")
    #expect(ExternalMigration.filename(for: "https://h.invalid/a.JPEG", mime: "image/jpeg") == "a.JPEG")
    #expect(ExternalMigration.filename(for: "https://h.invalid/", mime: "image/png") == "image.png")
  }

  // MARK: - Prepare

  @Test("Each URL downloads once; broken links and non-images are skipped and left as they were")
  func downloadsOnceAndSkips() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let good = "https://a.invalid/one.png"
    let gone = "https://m.invalid/p/x.jpg"
    let page = "https://b.invalid/page.png"
    fixture.fetcher.serve(good, image(1))
    fixture.fetcher.fail(gone, PublicObjectFetchError.notFound(URL(string: gone)!))
    fixture.fetcher.serve(page, Data("<html></html>".utf8), mime: "text/html")
    try fixture.write("b.md", "![](\(good))\n")
    try fixture.refer("a.md", [good, gone, page, good])

    let prepared = try await fixture.prepare([good, gone, good, page])
    #expect(prepared.state == .finished)
    #expect(fixture.fetcher.count(good) == 1)
    #expect(fixture.fetcher.count(gone) == 1)
    let failures = prepared.events.compactMap { event -> DownloadFailedEvent? in
      if case let .downloadFailed(failure) = event { return failure } else { return nil }
    }
    #expect(Set(failures.map(\.url)) == [gone, page])
    #expect(failures.first { $0.url == gone }?.reason == .httpStatus)
    #expect(failures.first { $0.url == gone }?.status == 404)
    #expect(failures.first { $0.url == page }?.reason == .notImage)
    let migration = try #require(prepared.summary.migration)
    #expect(migration.migratable == .init(images: 1, links: 3))
    #expect(migration.skipped == .init(images: 2, links: 2))
    #expect(migration.hosts.first { $0.host == "m.invalid" }?.tips == ["404 · skipped"])
    #expect(migration.files == [.init(project: "blog", source: "site", files: 2, edits: 3)])
    #expect(planned(prepared).keys.sorted() == [good])

    let applied = try await fixture.apply(prepared.runID)
    #expect(applied.state == .finished)
    let text = try fixture.read("a.md")
    #expect(text.contains(gone) && text.contains(page) && !text.contains(good))
    #expect(fixture.bucket.uploads == 1)
  }

  @Test("An octet-stream image is typed from its bytes; the name loses its query and gains .jpg")
  func sniffsOctetStream() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let url = "https://5b0988e595225.cdn.sohucs.invalid/images/%E5%9B%BE?w=1"
    fixture.fetcher.serve(url, jpeg(1), mime: "application/octet-stream")
    try fixture.refer("a.md", [url])

    let prepared = try await fixture.prepare([url])
    let download = try #require(prepared.events.compactMap { event -> DownloadFinishedEvent? in
      if case let .downloadFinished(value) = event { return value } else { return nil }
    }.first)
    #expect(download.mime == "image/jpeg")
    #expect(download.sniffed)
    #expect(download.filename == "图.jpg")
    #expect(FileManager.default.fileExists(atPath: download.cachePath))
    #expect(download.cachePath.hasPrefix(fixture.cacheRoot.appendingPathComponent("\(prepared.runID)/1").path))
    #expect(prepared.summary.migration?.hosts.first?.tips == ["Type read from the image"])
  }

  @Test("Bytes the catalog already has are reused: no upload, the reference goes to that asset")
  func reusesExistingAsset() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let url = "https://i.imgur.invalid/uwDy0lb.png"
    fixture.fetcher.serve(url, image(7))
    try await fixture.database.write { db in
      _ = try Asset(
        sha256: Hashing.sha256(of: image(7)), backendID: 1, key: "old/flaming.png", byteSize: 70,
        mime: "image/png", uploadedAt: "2024-01-01T00:00:00Z", createdAt: "2024-01-01T00:00:00Z",
        updatedAt: "2024-01-01T00:00:00Z"
      ).insertAndFetch(db)
    }
    try fixture.refer("a.md", [url])

    let prepared = try await fixture.prepare([url])
    #expect(planned(prepared)[url]?.reusedAssetID == 1)
    #expect(prepared.summary.migration?.reused == .init(images: 1, links: 1))
    let applied = try await fixture.apply(prepared.runID)
    #expect(fixture.bucket.uploads == 0)
    #expect(applied.events.contains(.assetReused(AssetReusedEvent(url: url, assetID: 1, newURL: "\(prefix)/old/flaming.png"))))
    #expect(try fixture.read("a.md") == "![](\(prefix)/old/flaming.png)\n")
  }

  @Test(
    "Keys always carry the hash; the project's template is left alone",
    arguments: ["{year}{month}/{name}.{ext}", "{year}{month}/{hash}.{ext}"])
  func keysCarryHash(template: String) async throws {
    let fixture = try MigrationFixture(template: template)
    defer { fixture.remove() }
    let url = "https://a.invalid/photo.png"
    fixture.fetcher.serve(url, image(2))
    try fixture.refer("a.md", [url])

    let prepared = try await fixture.prepare([url])
    let expected = try KeyTemplate.render(
      template: ExternalMigration.migrationTemplate(template), keyPrefix: "", originalFilename: "photo.png",
      sha256: Hashing.sha256(of: image(2)), fileExtension: "png", date: october)
    #expect(planned(prepared)[url]?.key == expected)
    #expect(expected.hasPrefix("202610/"))
    let stored = try await fixture.database.read { db in try String.fetchOne(db, sql: "SELECT key_template FROM project") }
    #expect(stored == template)
    _ = try await fixture.apply(prepared.runID)
    #expect(try fixture.assets().map(\.key) == [expected])
  }

  @Test("Cancelling a preparation deletes its downloads and ends it cancelled")
  func cancelPreparation() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let urls = (1...8).map { "https://a.invalid/\($0).png" }
    for (index, url) in urls.enumerated() { fixture.fetcher.serve(url, image(UInt8(index))) }
    try fixture.refer("a.md", urls)
    let cancellation = ExternalMigrationCancellation()
    fixture.fetcher.onFetch = { count in if count == 2 { cancellation.cancel() } }

    let prepared = try await fixture.prepare(urls, cancellation: cancellation)
    #expect(prepared.state == .cancelled)
    #expect(fixture.fetcher.total < urls.count)
    #expect(!FileManager.default.fileExists(atPath: fixture.cacheRoot.appendingPathComponent("\(prepared.runID)").path))
    #expect(try RunLog.run(prepared.runID, in: fixture.database)?.state == .cancelled)
    #expect(prepared.events.contains { if case .migrationStopped = $0 { return true } else { return false } })
  }

  @Test("A new preparation deletes earlier preparations' downloads")
  func newPreparationClearsOldCache() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let url = "https://a.invalid/1.png"
    fixture.fetcher.serve(url, image(1))
    try fixture.refer("a.md", [url])
    let first = try await fixture.prepare([url])
    let second = try await fixture.prepare([url])
    let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.cacheRoot.path)
    #expect(entries == ["\(second.runID)"])
    await #expect(throws: ExternalMigrationError.self) { try await fixture.apply(first.runID) }
  }

  // MARK: - Apply

  @Test("Uploads record the source URL on the object and the asset, never imported_from")
  func recordsProvenance() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let url = "https://upload.wikimedia.invalid/thumb/a/440px-Flips.png?x=1"
    fixture.fetcher.serve(url, image(3))
    try fixture.refer("a.md", [url])

    let prepared = try await fixture.prepare([url])
    let applied = try await fixture.apply(prepared.runID, now: october)
    #expect(applied.state == .finished)
    let request = try #require(fixture.bucket.requests.first)
    #expect(request.metadata["source-url"] == "https://upload.wikimedia.invalid/thumb/a/440px-Flips.png")
    let asset = try #require(try fixture.assets().first)
    let provenance = AssetProvenance(meta: asset.meta)
    #expect(provenance.sourceURL == "https://upload.wikimedia.invalid/thumb/a/440px-Flips.png")
    #expect(provenance.importedFrom == nil)
    #expect(AssetSource.of(meta: asset.meta) == .migrated)
    #expect(asset.uploadedAt.hasPrefix("2026-10-31"))
    #expect(applied.summary.migration?.newAssetIDs == [asset.id!])
    #expect(applied.summary.changedFilesByRepo == [RewriteRunSummary.notInGitKey: ["a.md"]])
    // The downloads are gone once the apply has run.
    #expect(!FileManager.default.fileExists(atPath: fixture.cacheRoot.appendingPathComponent("\(prepared.runID)").path))
  }

  @Test("An unclean source not allowed, or a file changed since: nothing is uploaded")
  func gatesBeforeUpload() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let url = "https://a.invalid/1.png"
    fixture.fetcher.serve(url, image(1))
    try fixture.refer("a.md", [url])
    let prepared = try await fixture.prepare([url])

    fixture.git.set(.dirty(paths: ["a.md"]), for: fixture.site.path)
    await #expect(throws: RewriteRunError.sourcesNotAllowed(["blog/site (uncommitted changes (1))"])) {
      try await fixture.apply(prepared.runID)
    }
    #expect(fixture.bucket.uploads == 0)

    fixture.git.set(.clean, for: fixture.site.path)
    try fixture.write("a.md", "![](\(url))\nmore\n")
    await #expect(throws: RewriteRunError.self) { try await fixture.apply(prepared.runID) }
    #expect(fixture.bucket.uploads == 0)
    #expect(try fixture.assets().isEmpty)
    #expect(try RunLog.runs(in: fixture.database).count == 1)
  }

  @Test("Missing downloads refuse the apply")
  func missingCacheRefuses() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let url = "https://a.invalid/1.png"
    fixture.fetcher.serve(url, image(1))
    try fixture.refer("a.md", [url])
    let prepared = try await fixture.prepare([url])
    try FileManager.default.removeItem(at: fixture.cacheRoot.appendingPathComponent("\(prepared.runID)"))

    await #expect(throws: ExternalMigrationError.cacheInvalid(runID: prepared.runID, ["\(url) (download missing)"])) {
      try await fixture.apply(prepared.runID)
    }
    #expect(fixture.bucket.uploads == 0)
  }

  @Test("Stopped after k images: k assets, nothing rewritten, cancelled; preparing again reuses them")
  func stopAfterK() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let urls = (1...3).map { "https://a.invalid/\($0).png" }
    for (index, url) in urls.enumerated() { fixture.fetcher.serve(url, image(UInt8(index + 10))) }
    try fixture.refer("a.md", urls)
    let before = try fixture.read("a.md")
    let prepared = try await fixture.prepare(urls)
    let cancellation = ExternalMigrationCancellation()
    fixture.bucket.onUpload = { count in if count == 1 { cancellation.cancel() } }

    let applied = try await fixture.apply(prepared.runID, cancellation: cancellation)
    #expect(applied.state == .cancelled)
    #expect(try fixture.assets().count == 1)
    #expect(try fixture.read("a.md") == before)
    #expect(applied.events.contains(.migrationStopped(MigrationStoppedEvent(done: 1, total: 3, phase: "upload"))))
    #expect(applied.summary.migration?.stoppedAfter == 1)

    let again = try await fixture.prepare(urls)
    #expect(again.summary.migration?.reused.images == 1)
    #expect(planned(again)[urls[0]]?.reusedAssetID != nil)
  }

  @Test("A 403 from the bucket fails the run and rewrites nothing")
  func backendErrorStops() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let urls = ["https://a.invalid/1.png", "https://a.invalid/2.png"]
    fixture.fetcher.serve(urls[0], image(1))
    fixture.fetcher.serve(urls[1], image(2))
    try fixture.refer("a.md", urls)
    let before = try fixture.read("a.md")
    let prepared = try await fixture.prepare(urls)
    fixture.bucket.failStatus = 403

    let applied = try await fixture.apply(prepared.runID)
    #expect(applied.state == .failed)
    #expect(fixture.bucket.uploads == 1)
    #expect(try fixture.read("a.md") == before)
    let failure = applied.events.compactMap { event -> UploadFailedEvent? in
      if case let .uploadFailed(value) = event { return value } else { return nil }
    }
    #expect(failure.map(\.fatal) == [true])
    #expect(RunEvent.uploadFailed(failure[0]).summaryLine == "Couldn’t upload 1.png — the bucket refused it (403)")
  }

  @Test("One image failing its check is left as is; the others are rewritten")
  func verifyFailureSkipsOne() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let urls = ["https://a.invalid/1.png", "https://a.invalid/2.png"]
    fixture.fetcher.serve(urls[0], image(1))
    fixture.fetcher.serve(urls[1], image(2))
    try fixture.refer("a.md", urls)
    let prepared = try await fixture.prepare(urls)
    let plans = planned(prepared)
    fixture.bucket.broken = [plans[urls[0]]!.newURL]

    let applied = try await fixture.apply(prepared.runID)
    #expect(applied.state == .finished)
    #expect(try fixture.read("a.md") == "![](\(urls[0]))\n![](\(plans[urls[1]]!.newURL))\n")
    #expect(try fixture.assets().count == 2)
    #expect(applied.summary.migration?.failed == .init(images: 1, links: 1))
    #expect(applied.summary.migration?.uploaded == .init(images: 1, links: 1))
  }

  @Test("Applying in the next month changes the key; the rewrite uses the real URL")
  func crossMonthKeyChange() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let url = "https://a.invalid/photo.png"
    fixture.fetcher.serve(url, image(4))
    try fixture.refer("a.md", [url])
    let prepared = try await fixture.prepare([url], now: october)
    let plannedKey = try #require(planned(prepared)[url]?.key)
    #expect(plannedKey.hasPrefix("202610/"))

    let applied = try await fixture.apply(prepared.runID, now: november)
    let asset = try #require(try fixture.assets().first)
    #expect(asset.key.hasPrefix("202611/"))
    #expect(applied.events.contains(.keyChanged(KeyChangedEvent(url: url, plannedKey: plannedKey, key: asset.key))))
    #expect(try fixture.read("a.md") == "![](\(prefix)/\(asset.key))\n")
  }

  @Test("After the rescan the migrated URLs are gone from Other Domains")
  func rescanClearsOtherDomains() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let good = "https://a.invalid/1.png?w=10"
    let gone = "https://m.invalid/x.png"
    fixture.fetcher.serve(good, image(1))
    try fixture.refer("a.md", [good, gone])
    #expect(Set(try await fixture.otherDomainURLs()) == [good, gone])

    let prepared = try await fixture.prepare([good, gone])
    let applied = try await fixture.apply(prepared.runID)
    #expect(applied.events.contains { if case .rescanFinished = $0 { return true } else { return false } })
    #expect(try await fixture.otherDomainURLs() == [gone])
  }

  // MARK: - Events

  @Test("Every new event has its summary line and survives a JSONL round trip")
  func eventsRoundTrip() throws {
    let url = "https://i.imgur.invalid/uwDy0lb.png?w=1"
    var summary = RewriteRunSummary(files: 2, edits: 3)
    var migration = ExternalMigrationSummary()
    migration.migratable = .init(images: 44, links: 47)
    migration.reused = .init(images: 2, links: 2)
    migration.skipped = .init(images: 1, links: 1)
    migration.hosts = [.init(host: "upload.wikimedia.org", links: 4, urls: 4, tips: ["Usually asks for attribution"])]
    migration.sampleKeys = ["202610/uwDy0lb-3fa9c2e1.png"]
    summary.migration = migration
    let cases: [(RunEvent, String)] = [
      (.migrationStarted(MigrationStartedEvent(
        targets: [.init(project: "astro", urls: 47, links: 49, hosts: 9)], backend: "r2", hosts: 9)),
       "Started — 49 links from 9 hosts"),
      (.downloadFinished(DownloadFinishedEvent(
        url: url, host: "i.imgur.invalid", sha256: "ab", bytes: 412_000, mime: "image/png", filename: "uwDy0lb.png",
        sniffed: false, cachePath: "/c/1/uwDy0lb.png")),
       "Downloaded uwDy0lb.png · 412 KB"),
      (.downloadFailed(DownloadFailedEvent(
        url: "https://m.media-amazon.invalid/images/I/x.jpg", host: "m.media-amazon.invalid", reason: .httpStatus,
        status: 404)),
       "Skipped m.media-amazon.invalid/…/x.jpg — 404, left as is"),
      (.migrationPlanned(MigrationPlannedEvent(
        url: url, sha256: "ab", key: "202610/uwDy0lb-3fa9c2e1.png", newURL: "\(prefix)/202610/uwDy0lb-3fa9c2e1.png",
        project: "astro", filename: "uwDy0lb.png")),
       "Will upload uwDy0lb.png → 202610/uwDy0lb-3fa9c2e1.png"),
      (.migrationPlanned(MigrationPlannedEvent(
        url: url, sha256: "ab", key: "old/a.png", newURL: "\(prefix)/old/a.png", reusedAssetID: 3)),
       "Will reuse uwDy0lb.png — already in the library"),
      (.uploadFinished(UploadFinishedEvent(
        url: url, key: "202610/uwDy0lb-3fa9c2e1.png", newURL: "\(prefix)/202610/uwDy0lb-3fa9c2e1.png", assetID: 9,
        bytes: 412_000)),
       "Uploaded uwDy0lb.png → 202610/uwDy0lb-3fa9c2e1.png"),
      (.assetReused(AssetReusedEvent(url: "https://h.invalid/TheFlamingLips.jpg", assetID: 3, newURL: "\(prefix)/a.jpg")),
       "Reused TheFlamingLips.jpg — already in the library"),
      (.uploadFailed(UploadFailedEvent(url: url, error: "S3 returned HTTP 403", fatal: true, status: 403)),
       "Couldn’t upload uwDy0lb.png — the bucket refused it (403)"),
      (.verifyFailed(VerifyFailedEvent(url: url, newURL: "\(prefix)/k.png", reason: "HTTP 404")),
       "New link for uwDy0lb.png doesn’t load — not rewritten"),
      (.keyChanged(KeyChangedEvent(url: url, plannedKey: "202610/a.png", key: "202611/a.png")),
       "Key for uwDy0lb.png changed to 202611/a.png"),
      (.migrationStopped(MigrationStoppedEvent(done: 18, total: 47, phase: "upload")),
       "Stopped after 18 of 47 images"),
      (.runFinished(summary), "Ready · 44 images to upload, 2 reused, 1 skipped"),
    ]
    for (event, line) in cases {
      #expect(event.summaryLine == line)
      let record = RunEventRecord(seq: 1, at: "2026-10-30T00:00:00.000Z", level: event.level, event: event)
      let decoded = try JSONDecoder().decode(RunEvent.self, from: Data(record.jsonLine.utf8))
      #expect(decoded == event)
      #expect(try RunEvent(type: event.type, data: event.dataJSON()) == event)
    }
    #expect(RunEvent.downloadFailed(DownloadFailedEvent(url: url, host: "h", reason: .notImage)).level == .warning)
    #expect(RunEvent.uploadFailed(UploadFailedEvent(url: url, error: "x", fatal: false)).level == .error)
    #expect(RunEvent.verifyFailed(VerifyFailedEvent(url: url, newURL: url, reason: "x")).level == .error)
    #expect(RunEvent.keyChanged(KeyChangedEvent(url: url, plannedKey: "a", key: "b")).level == .warning)
  }
}
