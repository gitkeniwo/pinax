import CatalogCore
import Foundation
import GRDB
import ImageIO
import PinaxUI
import Testing

@Suite struct UploadCatalogTests {
  @Test("A dedupe hit makes zero network calls and links the project")
  func dedupeHitsCatalogBeforeNetwork() async throws {
    try await withUploadDatabase { database in
      let jpeg = try #require(makeJPEGData())
      let sha256 = Hashing.sha256(of: jpeg)
      let file = try writeTempFile(jpeg)
      defer { try? FileManager.default.removeItem(at: file) }
      try seedAssetRow(database, sha256: sha256, key: "blog/existing.jpg")

      let catalog = UploadCatalog(
        database: database,
        credentialsLoader: { _ in BackendCredentials(accessKeyID: "key", secretAccessKey: "secret") },
        uploaderFactory: { _, _ in UnreachableUploader() }
      )

      let outcome = try await catalog.upload(file, projectSlug: "blog")
      #expect(outcome.deduplicated)
      #expect(outcome.sha256 == sha256)
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "blog") == 1)
    }
  }

  @Test("A fresh upload stores the asset and links the chosen project")
  func freshUploadStoresAsset() async throws {
    try await withUploadDatabase { database in
      let jpeg = try #require(makeJPEGData())
      let file = try writeTempFile(jpeg)
      defer { try? FileManager.default.removeItem(at: file) }
      let uploader = RecordingUploader()

      let catalog = UploadCatalog(
        database: database,
        credentialsLoader: { _ in BackendCredentials(accessKeyID: "key", secretAccessKey: "secret") },
        uploaderFactory: { _, _ in uploader }
      )

      let outcome = try await catalog.upload(file, projectSlug: "notes")
      #expect(!outcome.deduplicated)
      #expect(outcome.mime == "image/jpeg")
      #expect(outcome.url.hasPrefix("https://img.example.com/"))
      #expect(uploader.uploadedKeys.count == 1)

      let stored = try await database.read { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM asset WHERE sha256 = ?", arguments: [outcome.sha256])
      }
      #expect(stored == 1)
      #expect(try membershipCount(database, sha256: outcome.sha256, projectSlug: "notes") == 1)
    }
  }

  @Test("Backend resolution mirrors the CLI: project backend, else the sole backend")
  func backendResolution() async throws {
    try await withUploadDatabase { database in
      try await database.write { db in
        try db.execute(
          sql: """
            INSERT INTO backend
              (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
               created_at, updated_at)
            VALUES
              (2, 'b2', 's3', 'https://other.example.com', 'images', 'auto',
               'https://other.example.com', 'backend.b2', '{}',
               '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
            """)
      }

      let catalog = UploadCatalog(
        database: database,
        credentialsLoader: { _ in BackendCredentials(accessKeyID: "key", secretAccessKey: "secret") },
        uploaderFactory: { _, _ in UnreachableUploader() }
      )

      // The project's own backend wins even with two configured.
      let project = try #require(catalog.projects().first(where: { $0.slug == "blog" }))
      #expect(project.backendID == 1)

      // With no project and two backends, nothing can be resolved.
      await #expect(throws: UploadCatalogError.backendUnresolved) {
        _ = try await catalog.upload(
          URL(fileURLWithPath: "/tmp/anything.png"), projectSlug: nil)
      }

      // A missing project is refused by name, before any credential work.
      await #expect(throws: CatalogConfigurationError.projectNotFound("nope")) {
        _ = try await catalog.upload(
          URL(fileURLWithPath: "/tmp/anything.png"), projectSlug: "nope")
      }
    }
  }

  @Test("Missing credentials are a per-item error, not a crash")
  func missingCredentials() async throws {
    try await withUploadDatabase { database in
      let catalog = UploadCatalog(
        database: database,
        credentialsLoader: { _ in nil },
        uploaderFactory: { _, _ in UnreachableUploader() }
      )
      await #expect(throws: UploadCatalogError.missingCredentials("r2")) {
        _ = try await catalog.upload(
          URL(fileURLWithPath: "/tmp/anything.png"), projectSlug: "blog")
      }
    }
  }

  @Test("moveAsset covers link, unlink, and move")
  func moveAssetDirections() async throws {
    try await withUploadDatabase { database in
      let sha256 = String(repeating: "77", count: 32)
      try seedAssetRow(database, sha256: sha256, key: "blog/movable.jpg")
      let catalog = UploadCatalog(database: database)

      // Link into blog from nowhere.
      try await catalog.moveAsset(sha256: sha256, fromProject: nil, toProject: "blog")
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "blog") == 1)

      // Move blog → notes.
      try await catalog.moveAsset(sha256: sha256, fromProject: "blog", toProject: "notes")
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "blog") == 0)
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "notes") == 1)

      // Unlink entirely.
      try await catalog.moveAsset(sha256: sha256, fromProject: "notes", toProject: nil)
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "notes") == 0)
    }
  }

  @Test("Moving away from a still-referenced project is refused whole")
  func moveRefusesLiveUsage() async throws {
    try await withUploadDatabase { database in
      let sha256 = String(repeating: "66", count: 32)
      try seedAssetRow(database, sha256: sha256, key: "blog/keep.jpg")
      try await database.write { db in
        try db.execute(
          sql: """
            INSERT INTO asset_project (asset_id, project_id, added_at)
            SELECT a.id, p.id, '2026-08-22T00:00:00Z' FROM asset a, project p
            WHERE a.sha256 = ? AND p.slug = 'blog'
            """,
          arguments: [sha256])
      }
      try seedLiveUsage(database, projectSlug: "blog", sha256: sha256, count: 2)

      let catalog = UploadCatalog(database: database)
      await #expect(
        throws: AssetCatalogError.unlinkBlockedByLiveUsage(project: "blog", liveCount: 2)
      ) {
        try await catalog.moveAsset(
          sha256: sha256, fromProject: "blog", toProject: "notes", confirmed: false)
      }
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "blog") == 1)
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "notes") == 0)

      try await catalog.moveAsset(
        sha256: sha256, fromProject: "blog", toProject: "notes", confirmed: true)
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "blog") == 0)
      #expect(try membershipCount(database, sha256: sha256, projectSlug: "notes") == 1)
    }
  }

  @Test("Compression is passed only when the project's switch is on; No Project never compresses")
  func compressionFollowsProjectSwitch() async throws {
    try await withUploadDatabase { database in
      let photo = try #require(makeNoisyJPEGData(width: 1200, height: 900))
      let file = try writeTempFile(photo)
      defer { try? FileManager.default.removeItem(at: file) }
      let uploader = RecordingUploader()
      let catalog = UploadCatalog(
        database: database,
        credentialsLoader: { _ in BackendCredentials(accessKeyID: "key", secretAccessKey: "secret") },
        uploaderFactory: { _, _ in uploader }
      )
      try CatalogConfiguration.setCompression(slug: "blog", in: database) {
        $0.isEnabled = true
        $0.options.longestEdge = 600
      }
      // Stored options behind a switch that is off change nothing.
      try CatalogConfiguration.setCompression(slug: "notes", in: database) {
        $0.isEnabled = false
        $0.options.longestEdge = 600
      }

      for slug in ["notes", nil] {
        let prepared = try await catalog.prepare(file, projectSlug: slug)
        #expect(prepared.compression == nil, "\(slug ?? "No Project")")
      }

      let prepared = try await catalog.prepare(file, projectSlug: "blog")
      let compression = try #require(prepared.compression)
      #expect(prepared.projectSlug == "blog")
      #expect(compression.options.longestEdge == 600)
      #expect(compression.sourceByteSize == Int64(photo.count))
      #expect(compression.sourceWidth == 1200)
      #expect(compression.width == 600)
      #expect(compression.byteSize < compression.sourceByteSize)
      #expect(uploader.uploadedKeys.isEmpty, "preparing sends nothing")

      let outcome = try await catalog.upload(prepared, useOriginal: false)
      #expect(outcome.byteSize == compression.byteSize)
      #expect(outcome.width == 600)
      #expect(outcome.compression?.sourceByteSize == Int64(photo.count))
      #expect(uploader.uploadedKeys.count == 1)
      #expect(try Data(contentsOf: file) == photo, "the dropped file is left as it was")
    }
  }

  @Test("useOriginal sends the file as it is, and the composed upload follows the switch")
  func originalAndComposedUploads() async throws {
    try await withUploadDatabase { database in
      let catalog = UploadCatalog(
        database: database,
        credentialsLoader: { _ in BackendCredentials(accessKeyID: "key", secretAccessKey: "secret") },
        uploaderFactory: { _, _ in RecordingUploader() }
      )
      try CatalogConfiguration.setCompression(slug: "blog", in: database) {
        $0.isEnabled = true
        $0.options.longestEdge = 600
      }
      let first = try #require(makeNoisyJPEGData(width: 1200, height: 900))
      let second = try #require(makeNoisyJPEGData(width: 1000, height: 800))
      let firstFile = try writeTempFile(first)
      let secondFile = try writeTempFile(second)
      defer {
        try? FileManager.default.removeItem(at: firstFile)
        try? FileManager.default.removeItem(at: secondFile)
      }

      let original = try await catalog.upload(
        catalog.prepare(firstFile, projectSlug: "blog"), useOriginal: true)
      #expect(original.byteSize == Int64(first.count))
      #expect(original.compression == nil)

      let composed = try await catalog.upload(secondFile, projectSlug: "blog")
      #expect(composed.width == 600)
      #expect(composed.compression?.sourceByteSize == Int64(second.count))
    }
  }

  @Test("A drop another service prepared is refused")
  func foreignPreparedDropRefused() async throws {
    try await withUploadDatabase { database in
      let catalog = UploadCatalog(database: database)
      let foreign = PreparedDrop(
        fileURL: URL(fileURLWithPath: "/nonexistent/a.jpg"), projectSlug: nil)
      await #expect(throws: UploadCatalogError.notPrepared) {
        try await catalog.upload(foreign, useOriginal: false)
      }
    }
  }

  // MARK: - Helpers

  /// A JPEG of grey noise: large for its size, so a smaller copy saves far
  /// more than the compressor asks for.
  private func makeNoisyJPEGData(width: Int, height: Int) -> Data? {
    var generator = SystemRandomNumberGenerator()
    var pixels = (0..<(width * height)).map { _ in UInt8.random(in: 0...255, using: &generator) }
    let image = pixels.withUnsafeMutableBytes { buffer in
      CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
    }
    let data = NSMutableData()
    guard let image,
      let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  private func withUploadDatabase(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(database)
  }

  private func writeTempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-upload-\(UUID().uuidString).jpg")
    try data.write(to: url, options: .atomic)
    return url
  }

  private func seedAssetRow(_ database: DatabasePool, sha256: String, key: String) throws {
    try database.write { db in
      var asset = Asset(
        sha256: sha256,
        backendID: 1,
        key: key,
        byteSize: 1,
        width: 64,
        height: 48,
        mime: "image/jpeg",
        originalFilename: key,
        uploadedAt: "2026-08-22T00:00:00Z",
        createdAt: "2026-08-22T00:00:00Z",
        updatedAt: "2026-08-22T00:00:00Z"
      )
      try asset.insert(db)
    }
  }

  private func membershipCount(
    _ database: DatabasePool, sha256: String, projectSlug: String
  ) throws -> Int {
    try database.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM asset_project ap
          JOIN asset a ON a.id = ap.asset_id
          JOIN project p ON p.id = ap.project_id
          WHERE a.sha256 = ? AND p.slug = ?
          """,
        arguments: [sha256, projectSlug]) ?? 0
    }
  }
}

/// Any call is a test failure: the dedupe path must consult the catalog
/// before the uploader is ever touched.
private struct UnreachableUploader: Uploader {
  func upload(_ request: UploadRequest) async throws -> UploadResult {
    Issue.record("uploader must not be called (\(request.key))")
    throw S3UploaderError.invalidResponse
  }

  func exists(key: String) async throws -> Bool {
    false
  }
}

private final class RecordingUploader: Uploader, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String] = []

  func upload(_ request: UploadRequest) async throws -> UploadResult {
    lock.withLock { keys.append(request.key) }
    return UploadResult(key: request.key, etag: "etag")
  }

  func exists(key: String) async throws -> Bool {
    false
  }

  var uploadedKeys: [String] {
    lock.withLock { keys }
  }
}
