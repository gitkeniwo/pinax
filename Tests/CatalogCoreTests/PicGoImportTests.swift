import CatalogCore
import CryptoKit
import Foundation
import GRDB
import ImageIO
import CoreGraphics
import Testing
import UniformTypeIdentifiers

/// The PicGo import. The properties under test are idempotence, and that no
/// sha256 is ever synthesised — not "rows appeared". The fixture is a
/// synthetic 4-record gallery built by hand; a real gallery store, which
/// embeds credentials, never enters the repo.
@Suite struct PicGoImportTests {
  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/picgo-gallery.json")

  // MARK: - Gzip sniffing

  @Test("Gzip-compressed and plain stores yield identical records")
  func gzipSniffing() throws {
    let plain = try Data(contentsOf: Self.fixtureURL)
    let plainRecords = try PicGoGallery.records(data: plain)

    // Minimal header (FLG = 0), exactly what Node's zlib.gzipSync emits.
    let compressed = Self.gzip(plain)
    let compressedRecords = try PicGoGallery.records(data: compressed)
    #expect(compressedRecords == plainRecords)

    // A header carrying FNAME, to pin the optional-field skipping.
    let named = Self.gzip(plain, fileName: "picgo.db")
    #expect(try PicGoGallery.records(data: named) == plainRecords)

    #expect(plainRecords.count == 4)
    #expect(plainRecords[0].fileName == "screenshot-one.png")
    #expect(plainRecords[0].url == "https://img.example.com/202511/screenshot-one.png")
    #expect(plainRecords[0].width == 800)
    #expect(plainRecords[0].createdAtMilliseconds == 1_762_987_109_000)
  }

  /// Assembles a real gzip container by hand: 10-byte header, raw deflate via
  /// the same Compression API the importer decompresses with, 8-byte CRC32 +
  /// ISIZE trailer. This is the container shape measured from the real store.
  private static func gzip(_ data: Data, fileName: String? = nil) -> Data {
    let bytes = [UInt8](data)
    var out: [UInt8] = [0x1f, 0x8b, 0x08]
    out.append(fileName != nil ? 0x08 : 0x00)
    out.append(contentsOf: [0, 0, 0, 0])  // mtime
    out.append(contentsOf: [0x00, 0x03])  // XFL, OS = unix
    if let fileName {
      out.append(contentsOf: Array(fileName.utf8) + [0])
    }
    let deflate = try! (data as NSData).compressed(using: .zlib) as Data
    out.append(contentsOf: [UInt8](deflate))
    withUnsafeBytes(of: crc32(bytes).littleEndian) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(truncatingIfNeeded: bytes.count).littleEndian) {
      out.append(contentsOf: $0)
    }
    return Data(out)
  }

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var value = UInt32(index)
      for _ in 0..<8 {
        value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1
      }
      table[index] = value
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }

  // MARK: - Import behaviour

  @Test("Duplicate source records collapse to one asset and are counted")
  func duplicatesCollapse() async throws {
    try await withImportCatalog { database, backend, fetcher in
      let result = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      #expect(result.recordsRead == 4)
      #expect(result.distinctKeys == 3)
      #expect(result.duplicateSourceRecords == 1)
      #expect(result.imported == 3)
      #expect(result.skipped.isEmpty)
      #expect(result.dryRun == false)
    }
  }

  @Test("sha256 comes from the fetched bytes, never from the record")
  func sha256IsMeasured() async throws {
    try await withImportCatalog { database, backend, fetcher in
      _ = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      for asset in try assets(database) {
        let data = try #require(fetcher.payloads[asset.key])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(asset.sha256 == digest)
        #expect(asset.meta == "{\"imported_from\":\"picgo\"}")
      }
    }
  }

  @Test("A URL under no current or retired prefix is skipped, not guessed")
  func prefixMismatchSkipped() async throws {
    try await withImportCatalog { database, backend, fetcher in
      let records = [
        PicGoGalleryRecord(
          fileName: "alien.png",
          url: "https://cdn.elsewhere.example.com/alien.png",
          width: 10, height: 10, createdAtMilliseconds: 1_762_987_109_000)
      ]
      let result = try await PicGoGalleryImporter.importGallery(
        records: records, backend: backend, in: database, fetcher: fetcher)
      #expect(result.imported == 0)
      #expect(result.skipped.count == 1)
      #expect(result.skipped[0].reason == PicGoSkipReason.prefixMismatch)
      #expect(try assets(database).isEmpty)
    }
  }

  @Test("A retired prefix still identifies the object and is reported as used")
  func retiredPrefixImported() async throws {
    try await withImportCatalog { database, backend, fetcher in
      try await database.write { db in
        try db.execute(
          sql: "INSERT INTO backend_prefix_history (backend_id, url_prefix, retired_at) VALUES (?, ?, ?)",
          arguments: [backend.id ?? 0, "https://old-img.example.com", "2026-01-01T00:00:00Z"])
      }
      let records = [
        PicGoGalleryRecord(
          fileName: "legacy.png",
          url: "https://old-img.example.com/202511/legacy.png",
          width: 800, height: 600, createdAtMilliseconds: 1_762_987_109_000)
      ]
      let result = try await PicGoGalleryImporter.importGallery(
        records: records, backend: backend, in: database, fetcher: fetcher)
      #expect(result.imported == 1)
      #expect(result.importedViaRetiredPrefix == 1)
      #expect(try assets(database).count == 1)
    }
  }

  @Test("Running the import twice inserts nothing the second time")
  func idempotentSecondRun() async throws {
    try await withImportCatalog { database, backend, fetcher in
      let first = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      #expect(first.imported == 3)
      let rowsAfterFirst = try assetRows(database)

      let second = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      #expect(second.imported == 0)
      #expect(second.alreadyPresent == 3)
      // The second pass must not even fetch — every key is already known.
      #expect(fetcher.fetchCount == 3)

      let rowsAfterSecond = try assetRows(database)
      #expect(rowsAfterSecond == rowsAfterFirst)
    }
  }

  @Test("A dry run reports what would be imported and writes nothing")
  func dryRunWritesNothing() async throws {
    try await withImportCatalog { database, backend, fetcher in
      let result = try await PicGoGalleryImporter.importGallery(
        records: try PicGoGallery.records(contentsOf: Self.fixtureURL),
        backend: backend, in: database, fetcher: fetcher, dryRun: true)
      #expect(result.imported == 3)
      #expect(result.dryRun == true)
      #expect(try assets(database).isEmpty)
    }
  }

  @Test("One failing fetch does not abort the others and appears in skipped")
  func fetchFailureIsolation() async throws {
    try await withImportCatalog { database, backend, fetcher in
      fetcher.failURL("https://img.example.com/202511/photo-two.jpg")
      let result = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      #expect(result.imported == 2)
      #expect(result.skipped.count == 1)
      #expect(result.skipped[0].reason == PicGoSkipReason.notFound)
      #expect(try assets(database).count == 2)
    }
  }

  @Test("A 403 and a 404 produce different skip reasons")
  func forbiddenVersusNotFound() async throws {
    try await withImportCatalog { database, backend, fetcher in
      fetcher.failURL(
        "https://img.example.com/202511/screenshot-one.png",
        error: .forbidden(URL(string: "https://img.example.com/202511/screenshot-one.png")!))
      fetcher.failURL(
        "https://img.example.com/202511/photo-two.jpg",
        error: .notFound(URL(string: "https://img.example.com/202511/photo-two.jpg")!))
      let result = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      let reasons = Dictionary(
        uniqueKeysWithValues: result.skipped.map { ($0.url, $0.reason) })
      #expect(
        reasons["https://img.example.com/202511/screenshot-one.png"] == PicGoSkipReason.forbidden)
      #expect(reasons["https://img.example.com/202511/photo-two.jpg"] == PicGoSkipReason.notFound)
      #expect(result.imported == 1)
    }
  }

  @Test("A content-length mismatch is skipped rather than trusted")
  func lengthMismatchSkipped() async throws {
    try await withImportCatalog { database, backend, fetcher in
      fetcher.overrideContentLength(
        "https://img.example.com/202511/photo-two.jpg", contentLength: 99_999)
      let result = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      #expect(result.imported == 2)
      #expect(result.skipped[0].reason == PicGoSkipReason.lengthMismatch)
    }
  }

  @Test("Missing dimensions fall back to probing the fetched bytes")
  func dimensionsProbedFromBytes() async throws {
    try await withImportCatalog { database, backend, fetcher in
      let records = [
        PicGoGalleryRecord(
          fileName: "probed.png", url: "https://img.example.com/202511/screenshot-one.png",
          width: 0, height: nil, createdAtMilliseconds: 1_762_987_109_000)
      ]
      _ = try await PicGoGalleryImporter.importGallery(
        records: records, backend: backend, in: database, fetcher: fetcher)
      let rows = try assets(database)
      #expect(rows.count == 1)
      #expect(rows[0].width == 800)
      #expect(rows[0].height == 600)
    }
  }

  @Test("uploaded_at is createdAt converted to ISO-8601 UTC")
  func uploadedAtFromCreatedAt() async throws {
    try await withImportCatalog { database, backend, fetcher in
      _ = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      let expected = ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: 1_762_987_109))
      let asset = try #require(
        try assets(database).first { $0.key == "202511/screenshot-one.png" })
      #expect(asset.uploadedAt == expected)
    }
  }

  // MARK: - Backfill

  @Test("Backfill plans via HEAD, and apply writes back what HEAD reported")
  func backfillPreservesHeadFacts() async throws {
    try await withImportCatalog { database, backend, fetcher in
      _ = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      let assets = try PicGoBackfill.assets(for: backend, in: database)
      // One object already carries a Cache-Control; the others do not.
      let inventory = StubInventory { key in
        S3ObjectHead(
          key: key, byteSize: 0, mime: "image/jpeg", lastModified: nil,
          metadata: ["orig-filename": "stale"],
          cacheControl: key.hasSuffix("photo-two.jpg") ? "public, max-age=60" : nil)
      }
      let plan = try await PicGoBackfill.plan(assets: assets, inventory: inventory)
      #expect(plan.matchingKeys.isEmpty)
      #expect(plan.candidates.count == 3)

      let uploader = RecordingUploader()
      let result = try await PicGoBackfill.apply(
        plan: plan, backend: backend, uploader: uploader, fetcher: fetcher)
      #expect(result.backfilled == 3)
      #expect(result.skippedMatching == 0)
      #expect(result.failed.isEmpty)

      #expect(uploader.requests.count == 3)
      for request in uploader.requests {
        #expect(request.mime == "image/jpeg")  // preserved verbatim
        #expect(request.metadata["sha256"] != nil)
        #expect(request.metadata["orig-filename"] != nil)
        #expect(request.metadata["width"] != nil)
        if request.key.hasSuffix("photo-two.jpg") {
          // HEAD reported one — written back unchanged.
          #expect(request.cacheControl == "public, max-age=60")
        } else {
          // HEAD reported none — the immutable policy applies.
          #expect(request.cacheControl == S3Uploader.immutableCacheControl)
        }
      }
    }
  }

  @Test("Two keys carrying identical bytes import once, not into a constraint error")
  func batchDuplicateContentCollapses() async throws {
    try await withImportCatalog { database, backend, _ in
      // A fetcher deliberately outside ScriptedFetcher, which generates
      // per-key content and therefore cannot reach this branch.
      let shared = ScriptedFetcher.pngPayload(width: 64, height: 48, seed: "one-upload")
      let fetcher = FixedPayloadFetcher(payload: shared)
      let records = [
        PicGoGalleryRecord(
          fileName: "a.png", url: "https://img.example.com/202511/a-1.png",
          width: 64, height: 48, createdAtMilliseconds: 1_762_987_109_000),
        PicGoGalleryRecord(
          fileName: "a.png", url: "https://img.example.com/202512/a-2.png",
          width: 64, height: 48, createdAtMilliseconds: 1_765_665_509_000),
      ]
      let result = try await PicGoGalleryImporter.importGallery(
        records: records, backend: backend, in: database, fetcher: fetcher)
      #expect(result.imported == 1)
      #expect(result.alreadyPresent == 1)
      #expect(result.skipped.isEmpty)
      #expect(try assets(database).count == 1)
    }
  }

  @Test("Only R2-family endpoints backfill without an ACL-reset acknowledgement")
  func aclResetAcknowledgement() {
    let r2 = Backend(
      slug: "r2", kind: "s3",
      endpoint: "https://acct.r2.cloudflarestorage.com", bucket: "b",
      region: "auto", urlPrefix: "https://img.example.com", keychainRef: "",
      createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    let aws = Backend(
      slug: "aws", kind: "s3",
      endpoint: "https://s3.eu-west-1.amazonaws.com", bucket: "b",
      region: "eu-west-1", urlPrefix: "https://img.example.com", keychainRef: "",
      createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    #expect(!PicGoBackfill.requiresACLResetAcknowledgement(r2))
    #expect(PicGoBackfill.requiresACLResetAcknowledgement(aws))
  }

  @Test("Objects already carrying a matching sha256 are skipped, not rewritten")
  func backfillResumesPastMatching() async throws {
    try await withImportCatalog { database, backend, fetcher in
      _ = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      let assets = try PicGoBackfill.assets(for: backend, in: database)
      let inventory = StubInventory { key in
        S3ObjectHead(
          key: key, byteSize: 0, mime: "image/png", lastModified: nil,
          metadata: ["sha256": assets.first(where: { $0.key == key })?.sha256 ?? ""],
          cacheControl: nil)
      }
      let plan = try await PicGoBackfill.plan(assets: assets, inventory: inventory)
      #expect(plan.matchingKeys.count == 3)
      #expect(plan.candidates.isEmpty)

      let uploader = RecordingUploader()
      let result = try await PicGoBackfill.apply(
        plan: plan, backend: backend, uploader: uploader, fetcher: fetcher)
      #expect(result.backfilled == 0)
      #expect(result.skippedMatching == 3)
      #expect(uploader.requests.isEmpty)
    }
  }

  @Test("Backfill never writes metadata onto bytes that are not the asset")
  func backfillRefusesContentMismatch() async throws {
    try await withImportCatalog { database, backend, fetcher in
      _ = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      let assets = try PicGoBackfill.assets(for: backend, in: database)
      let inventory = StubInventory { key in
        S3ObjectHead(
          key: key, byteSize: 0, mime: "image/png", lastModified: nil,
          metadata: [:], cacheControl: nil)
      }
      let plan = try await PicGoBackfill.plan(assets: assets, inventory: inventory)
      // Serve different bytes than the object the catalog hashed.
      fetcher.failURL(
        "https://img.example.com/202511/photo-two.jpg",
        error: .failed(
          URL(string: "https://img.example.com/202511/photo-two.jpg")!, detail: "garbled"))
      let uploader = RecordingUploader()
      let result = try await PicGoBackfill.apply(
        plan: plan, backend: backend, uploader: uploader, fetcher: fetcher)
      #expect(result.backfilled == 2)
      #expect(result.failed.count == 1)
      #expect(result.failed[0].key == "202511/photo-two.jpg")
      #expect(uploader.requests.count == 2)
    }
  }

  @Test("A dry-run backfill counts the writes but performs none")
  func backfillDryRun() async throws {
    try await withImportCatalog { database, backend, fetcher in
      _ = try await importFixture(database: database, backend: backend, fetcher: fetcher)
      let assets = try PicGoBackfill.assets(for: backend, in: database)
      let inventory = StubInventory { key in
        S3ObjectHead(
          key: key, byteSize: 0, mime: "image/png", lastModified: nil,
          metadata: [:], cacheControl: nil)
      }
      let plan = try await PicGoBackfill.plan(assets: assets, inventory: inventory)
      let uploader = RecordingUploader()
      let result = try await PicGoBackfill.apply(
        plan: plan, backend: backend, uploader: uploader, fetcher: fetcher, dryRun: true)
      #expect(result.backfilled == 3)
      #expect(result.dryRun == true)
      #expect(uploader.requests.isEmpty)
    }
  }

  // MARK: - Read-only backends

  @Test("doctor treats a credential-less backend as informational")
  func doctorCredentialLessIsInfo() throws {
    try withImportCatalog { database, _, _ in
      let report = try CatalogDoctor.run(
        database: database,
        databaseURL: URL(fileURLWithPath: "/tmp/never-opened.sqlite"),
        credentialExists: { _ in true })
      let check = try #require(report.checks.first { $0.name == "backend-credentials" })
      #expect(check.status == .info)
      #expect(check.detail.contains("read-only"))
    }
  }

  @Test("attachKeychainReference fills an empty reference and keeps a set one")
  func attachReference() throws {
    try withImportCatalog { database, backend, _ in
      let attached = try CatalogConfiguration.attachKeychainReference(
        slug: backend.slug, reference: "backend.r2", in: database)
      #expect(attached.keychainRef == "backend.r2")
      let again = try CatalogConfiguration.attachKeychainReference(
        slug: backend.slug, reference: "backend.other", in: database)
      #expect(again.keychainRef == "backend.r2")
    }
  }

  // MARK: - Fixtures and doubles

  private func importFixture(
    database: CatalogDatabasePool,
    backend: Backend,
    fetcher: ScriptedFetcher
  ) async throws -> PicGoImportResult {
    try await PicGoGalleryImporter.importGallery(
      records: try PicGoGallery.records(contentsOf: Self.fixtureURL),
      backend: backend,
      in: database,
      fetcher: fetcher)
  }

  private func assets(_ database: CatalogDatabasePool) throws -> [Asset] {
    try database.read { db in
      try Asset.order(Column("key")).fetchAll(db)
    }
  }

  /// A canonical per-row dump, so "the table is byte-identical" is an
  /// `==` on plain strings rather than a hand-rolled dictionary compare.
  private func assetRows(_ database: CatalogDatabasePool) throws -> [String] {
    try assets(database).map { asset in
      [
        asset.sha256, asset.key, String(asset.byteSize),
        asset.width.map(String.init) ?? "NULL", asset.height.map(String.init) ?? "NULL",
        asset.mime, asset.originalFilename ?? "NULL", asset.meta,
        asset.uploadedAt, asset.createdAt, asset.updatedAt,
      ].joined(separator: "\t")
    }
  }

  private func withImportCatalog(
    _ body: (CatalogDatabasePool, Backend, ScriptedFetcher) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    let backend = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://storage.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://img.example.com",
      keychainReference: "",
      to: database)
    let fetcher = ScriptedFetcher()
    try await body(database, backend, fetcher)
  }

  // Overload for the synchronous doctor/configuration tests.
  private func withImportCatalog(
    _ body: (CatalogDatabasePool, Backend, ScriptedFetcher) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    let backend = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://storage.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://img.example.com",
      keychainReference: "",
      to: database)
    try body(database, backend, ScriptedFetcher())
  }
}

// MARK: - Test doubles

/// Serves deterministic PNG payloads per URL key, with scriptable failures.
/// The PNG is generated in-process; no network, no bundled image.
final class ScriptedFetcher: PublicObjectFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var failures: [String: PublicObjectFetchError] = [:]
  private var lengthOverrides: [String: Int64] = [:]
  private(set) var payloads: [String: Data] = [:]
  private(set) var fetchCount = 0

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    let declared: Int64
    let data: Data
    do {
      (data, declared) = try Self.withLock(lock) {
        if let error = failures[url.absoluteString] {
          throw error
        }
        fetchCount += 1
        let key = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let payload = payloads[key] ?? {
          // Content must differ per object: the catalog's identity is
          // (backend, sha256), and identical payloads would violate it.
          let generated = Self.pngData(width: 800, height: 600, seed: key)
          payloads[key] = generated
          return generated
        }()
        return (payload, lengthOverrides[url.absoluteString] ?? Int64(payload.count))
      }
    } catch let error as PublicObjectFetchError {
      throw error
    }
    return (data, "image/png", declared)
  }

  private static func withLock<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  func failURL(_ absolute: String, error: PublicObjectFetchError? = nil) {
    lock.lock()
    defer { lock.unlock() }
    failures[absolute] =
      error
      ?? .notFound(URL(string: absolute)!)
  }

  func overrideContentLength(_ absolute: String, contentLength: Int64) {
    lock.lock()
    defer { lock.unlock() }
    lengthOverrides[absolute] = contentLength
  }

  static func pngPayload(width: Int, height: Int, seed: String) -> Data {
    pngData(width: width, height: height, seed: seed)
  }

  private static func pngData(width: Int, height: Int, seed: String) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let digest = SHA256.hash(data: Data(seed.utf8))
    let bytes = Array(digest.prefix(6))
    context.setFillColor(
      CGColor(
        red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
        blue: CGFloat(bytes[2]) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Two pixels of the seed's tail so sibling keys can never collide in bytes.
    for offset in stride(from: 0, to: width, by: max(1, width / 8)) {
      context.setFillColor(
        CGColor(
          red: CGFloat(bytes[3]) / 255, green: CGFloat(bytes[4]) / 255,
          blue: CGFloat(bytes[5]) / 255, alpha: 1))
      context.fill(CGRect(x: offset, y: 0, width: 2, height: height))
    }
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
  }
}

/// Serves one fixed payload for every URL — the shape ScriptedFetcher is
/// designed never to produce, and exactly what a re-uploaded PicGo image
/// looks like (same bytes, different key).
struct FixedPayloadFetcher: PublicObjectFetching {
  let payload: Data

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    (payload, "image/png", Int64(payload.count))
  }
}

struct StubInventory: ObjectInventory {
  let head: @Sendable (String) -> S3ObjectHead

  func listObjects() async throws -> [S3ObjectSummary] { [] }

  func headObject(key: String) async throws -> S3ObjectHead { head(key) }
}

final class RecordingUploader: Uploader, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [UploadRequest] = []

  func upload(_ request: UploadRequest) async throws -> UploadResult {
    Self.withLock(lock) {
      requests.append(request)
    }
    return UploadResult(key: request.key, etag: nil)
  }

  private static func withLock(_ lock: NSLock, _ body: () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body()
  }

  func exists(key: String) async throws -> Bool { false }
}
