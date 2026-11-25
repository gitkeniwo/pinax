import Foundation
import GRDB
import Testing

@testable import CatalogCore

/// Compression on the upload path: what is stored, what is sent, and when an
/// earlier upload is reused instead.
@Suite struct UploadCompressionTests {
  /// A 2400×1600 photo-like PNG: compresses to a much smaller JPEG.
  private static let photoPNG: Data = {
    let image = try! CompressionFixtures.photo(width: 2400, height: 1600)
    return try! CompressionFixtures.png(image)
  }()

  @Test("A compressed upload stores the copy's hash, the original's hash, header, key and meta")
  func compressedUpload() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let url = try fixture.write(Self.photoPNG, as: "Summit photo.png")
    let pipeline = fixture.pipeline()

    let planned = try await pipeline.upload(
      fileURL: url, dryRun: true, date: fixture.date, compression: .default)
    #expect(planned.key.hasSuffix(".jpg"))
    #expect(planned.compression != nil)
    #expect(try fixture.assets().isEmpty)
    #expect(fixture.uploader.requests.isEmpty)

    let outcome = try await pipeline.upload(fileURL: url, date: fixture.date, compression: .default)
    let request = try #require(fixture.uploader.requests.first)
    let sourceSHA256 = Hashing.sha256(of: Self.photoPNG)
    #expect(fixture.uploader.requests.count == 1)
    #expect(request.data.count < Self.photoPNG.count / 2)
    #expect(outcome.sha256 == Hashing.sha256(of: request.data))
    #expect(request.sha256 == outcome.sha256)
    #expect(request.metadata["sha256"] == outcome.sha256)
    #expect(request.metadata["source-sha256"] == sourceSHA256)
    #expect(request.metadata["width"] == "2048")
    #expect(request.mime == "image/jpeg")
    #expect(outcome.key == planned.key)
    #expect(outcome.key == "blog/202608/summit-photo-\(outcome.sha256.prefix(12)).jpg")
    #expect(outcome.originalFilename == "Summit photo.png")
    #expect(outcome.width == 2048)
    #expect((1365...1366).contains(outcome.height ?? 0))
    #expect(!outcome.deduplicated)
    let facts = try #require(outcome.compression)
    #expect(facts.options == .default)
    #expect(facts.sourceSHA256 == sourceSHA256)
    #expect(facts.sourceByteSize == Int64(Self.photoPNG.count))
    #expect(facts.sourceWidth == 2400)
    #expect(facts.sourceHeight == 1600)
    #expect(facts.sourceMime == "image/png")
    #expect(facts.formatChanged)

    let asset = try #require(try fixture.assets().first)
    #expect(asset.sha256 == outcome.sha256)
    #expect(asset.sourceSHA256 == sourceSHA256)
    #expect(asset.mime == "image/jpeg")
    #expect(asset.byteSize == Int64(request.data.count))
    #expect(UploadCompressionFacts(asset: asset) == facts)
    let meta = try #require(
      try JSONSerialization.jsonObject(with: Data(asset.meta.utf8)) as? [String: Any])
    let record = try #require(meta["compression"] as? [String: Any])
    #expect(record["fingerprint"] as? String == "e2048-qhigh-m1")
    #expect(record["source_bytes"] as? Int == Self.photoPNG.count)
    #expect(record["source_mime"] as? String == "image/png")
  }

  @Test("compression facts merge into meta that already has keys")
  func metaMerges() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let url = try fixture.write(Self.photoPNG, as: "photo.png")

    let outcome = try await fixture.pipeline().upload(
      fileURL: url, date: fixture.date, sourceURL: "https://old.example.org/photo.png",
      compression: .default)

    let asset = try #require(try fixture.assets().first)
    let meta = try #require(
      try JSONSerialization.jsonObject(with: Data(asset.meta.utf8)) as? [String: Any])
    #expect(meta["source_url"] as? String == "https://old.example.org/photo.png")
    #expect(meta["compression"] != nil)
    #expect(AssetSource.of(meta: asset.meta) != .pinax)
    #expect(outcome.compression != nil)
  }

  @Test("An original already stored as is is reused, and not compressed")
  func reusesStoredOriginal() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let url = try fixture.write(Self.photoPNG, as: "photo.png")
    let pipeline = fixture.pipeline()
    let original = try await pipeline.upload(fileURL: url, date: fixture.date)

    let prepared = try await pipeline.prepare(fileURL: url, compression: .default)
    #expect(prepared.isDuplicate)
    #expect(prepared.compression == nil)
    let again = try await pipeline.upload(prepared, useOriginal: false, date: fixture.date)

    #expect(again.deduplicated)
    #expect(again.sha256 == original.sha256)
    #expect(again.compression == nil)
    #expect(fixture.uploader.requests.count == 1)
    #expect(try fixture.assets().count == 1)
  }

  @Test("A copy made with the same options is reused without compressing again")
  func reusesCompressedCopy() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let url = try fixture.write(Self.photoPNG, as: "photo.png")
    let first = try await fixture.pipeline().upload(
      fileURL: url, date: fixture.date, compression: .default)

    // Another project: the reused asset is linked to it.
    let other = try fixture.addProject("notes")
    let pipeline = fixture.pipeline(project: other)
    let prepared = try await pipeline.prepare(fileURL: url, compression: .default)
    guard case .compressedCopy(let match) = prepared.match else {
      Issue.record("Expected a match on the original's hash, got \(String(describing: prepared.match))")
      return
    }
    #expect(match.sha256 == first.sha256)
    #expect(prepared.compression == nil)
    let second = try await pipeline.upload(prepared, useOriginal: false, date: fixture.date)

    #expect(second.deduplicated)
    #expect(second.sha256 == first.sha256)
    #expect(second.compression == first.compression)
    #expect(fixture.uploader.requests.count == 1)
    #expect(try fixture.assets().count == 1)
    #expect(try fixture.projectLinks() == 2)
  }

  @Test("Other options make a new copy")
  func otherOptionsUploadAgain() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let url = try fixture.write(Self.photoPNG, as: "photo.png")
    let pipeline = fixture.pipeline()
    let first = try await pipeline.upload(fileURL: url, date: fixture.date, compression: .default)

    let smaller = CompressionOptions(longestEdge: 1600, quality: .medium)
    let second = try await pipeline.upload(fileURL: url, date: fixture.date, compression: smaller)

    #expect(!second.deduplicated)
    #expect(second.sha256 != first.sha256)
    #expect(second.width == 1600)
    #expect(second.compression?.options == smaller)
    #expect(fixture.uploader.requests.count == 2)
    let assets = try fixture.assets()
    #expect(assets.count == 2)
    #expect(Set(assets.compactMap(\.sourceSHA256)) == [Hashing.sha256(of: Self.photoPNG)])
  }

  @Test("useOriginal sends the original's bytes, even when a compressed copy exists")
  func useOriginal() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let url = try fixture.write(Self.photoPNG, as: "photo.png")
    let pipeline = fixture.pipeline()
    _ = try await pipeline.upload(fileURL: url, date: fixture.date, compression: .default)

    let prepared = try await pipeline.prepare(fileURL: url, compression: .default)
    let outcome = try await pipeline.upload(prepared, useOriginal: true, date: fixture.date)

    let sourceSHA256 = Hashing.sha256(of: Self.photoPNG)
    #expect(!outcome.deduplicated)
    #expect(outcome.sha256 == sourceSHA256)
    #expect(outcome.key.hasSuffix(".png"))
    #expect(outcome.compression == nil)
    let request = try #require(fixture.uploader.requests.last)
    #expect(request.data == Self.photoPNG)
    #expect(request.metadata["source-sha256"] == nil)
    let stored = try #require(try fixture.assets().first { $0.sha256 == sourceSHA256 })
    #expect(stored.sourceSHA256 == nil)
    #expect(stored.meta == "{}")
  }

  @Test("A compressed copy whose bytes are already stored is reused")
  func compressedBytesAlreadyStored() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let copy = try #require(
      ImageCompressor.compress(Self.photoPNG, options: .default).compressedImage)
    let copyURL = try fixture.write(copy.data, as: "copy.jpg")
    let pipeline = fixture.pipeline()
    let stored = try await pipeline.upload(fileURL: copyURL, date: fixture.date)

    let url = try fixture.write(Self.photoPNG, as: "photo.png")
    let outcome = try await pipeline.upload(fileURL: url, date: fixture.date, compression: .default)

    #expect(outcome.deduplicated)
    #expect(outcome.sha256 == stored.sha256)
    #expect(outcome.compression?.sourceSHA256 == Hashing.sha256(of: Self.photoPNG))
    #expect(fixture.uploader.requests.count == 1)
    #expect(try fixture.assets().count == 1)
  }

  @Test("An image the compressor skips is uploaded as the original")
  func skippedImageUploadsOriginal() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let tiny = try CompressionFixtures.png(try CompressionFixtures.photo(width: 40, height: 30))
    let url = try fixture.write(tiny, as: "tiny.png")
    let pipeline = fixture.pipeline()

    let prepared = try await pipeline.prepare(fileURL: url, compression: .default)
    #expect(prepared.compression?.skipReason == .notSmaller)
    let outcome = try await pipeline.upload(prepared, useOriginal: false, date: fixture.date)

    #expect(outcome.sha256 == Hashing.sha256(of: tiny))
    #expect(outcome.key.hasSuffix(".png"))
    #expect(outcome.compression == nil)
    #expect(try fixture.assets().first?.sourceSHA256 == nil)
  }

  @Test("Concurrent compressed uploads of one file send it once")
  func concurrentCompressedUploads() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let url = try fixture.write(Self.photoPNG, as: "photo.png")
    let pipeline = fixture.pipeline()

    async let first = pipeline.upload(fileURL: url, date: fixture.date, compression: .default)
    async let second = pipeline.upload(fileURL: url, date: fixture.date, compression: .default)
    let outcomes = try await [first, second]

    #expect(outcomes[0].sha256 == outcomes[1].sha256)
    #expect(fixture.uploader.requests.count == 1)
    #expect(try fixture.assets().count == 1)
  }

  // MARK: - Schema

  @Test("The migration adds the nullable column and its index; older rows read as originals")
  func migrationUpgradesOldCatalog() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrator.migrate(database, upTo: "v5_run")
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref,
            meta, created_at, updated_at)
          VALUES (1, 'r2', 's3', 'https://s.example.com', 'b', 'auto', 'https://i.example.com',
            'backend.r2', '{}', 't', 't');
          INSERT INTO asset (sha256, backend_id, key, byte_size, mime, meta, uploaded_at,
            created_at, updated_at)
          VALUES ('aa', 1, 'old.png', 1, 'image/png', '{}', 't', 't', 't');
          """)
    }

    try Database.migrate(database)

    try database.read { db in
      let columns = try db.columns(in: "asset")
      let column = try #require(columns.first { $0.name == "source_sha256" })
      #expect(!column.isNotNull)
      let indexes = try db.indexes(on: "asset")
      let index = try #require(indexes.first { $0.name == "ix_asset_backend_source_sha" })
      #expect(index.columns == ["backend_id", "source_sha256"])
      #expect(!index.isUnique)
      let asset = try #require(try Asset.fetchOne(db))
      #expect(asset.sourceSHA256 == nil)
      #expect(try Database.migrator.appliedMigrations(db).last == "v6_asset_source_sha256")
    }
  }

  @Test("Backups carry the original's hash, and older backups restore without it")
  func backupsCarrySourceHash() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let url = try fixture.write(Self.photoPNG, as: "photo.png")
    _ = try await fixture.pipeline().upload(fileURL: url, date: fixture.date, compression: .default)
    let backup = try CatalogBackups.create(from: fixture.database)
    #expect(backup.migrations.last == "v6_asset_source_sha256")

    let target = try CompressionFixture(empty: true)
    defer { target.remove() }
    try CatalogBackups.restore(backup, into: target.database)
    #expect(try target.assets().first?.sourceSHA256 == Hashing.sha256(of: Self.photoPNG))

    // The same backup as an older app wrote it: no column, no migration.
    var object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
    object["migrations"] = (object["migrations"] as? [String])?.dropLast().map { $0 }
    var tables = try #require(object["tables"] as? [String: Any])
    tables["assets"] = (tables["assets"] as? [[String: Any]])?.map { row in
      var row = row
      row["source_sha256"] = nil
      return row
    }
    object["tables"] = tables
    let older = try CatalogBackups.decode(try JSONSerialization.data(withJSONObject: object))
    let third = try CompressionFixture(empty: true)
    defer { third.remove() }
    try CatalogBackups.restore(older, into: third.database)
    let restored = try #require(try third.assets().first)
    #expect(restored.sourceSHA256 == nil)
  }

  @Test("reindex fills the original's hash from the header, for new and existing rows")
  func reindexFillsSourceHash() async throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let source = String(repeating: "a", count: 64)
    let stored = String(repeating: "b", count: 64)
    let existingSHA = String(repeating: "c", count: 64)
    try await fixture.database.write { db in
      var asset = Asset(
        sha256: existingSHA, backendID: fixture.backend.id!, key: "blog/known.jpg", byteSize: 5,
        mime: "image/jpeg", uploadedAt: "t", createdAt: "t", updatedAt: "t")
      try asset.insert(db)
    }
    func head(_ key: String, _ sha: String, source: String?) -> S3ObjectHead {
      var metadata = ["sha256": sha, "orig-filename": "photo.png", "width": "8", "height": "6"]
      metadata["source-sha256"] = source
      return S3ObjectHead(
        key: key, byteSize: 5, mime: "image/jpeg", lastModified: nil, metadata: metadata)
    }
    let inventory = FixedInventory(heads: [
      head("blog/new.jpg", stored, source: source),
      head("blog/known.jpg", existingSHA, source: source),
      head("blog/plain.jpg", String(repeating: "d", count: 64), source: "not-a-hash"),
    ])

    let result = try await CatalogReindex.run(
      backend: fixture.backend, inventory: inventory, database: fixture.database)

    #expect(result.reconstructed == 2)
    #expect(result.existing == 1)
    let assets = Dictionary(uniqueKeysWithValues: try fixture.assets().map { ($0.key, $0) })
    #expect(assets["blog/new.jpg"]?.sourceSHA256 == source)
    #expect(assets["blog/known.jpg"]?.sourceSHA256 == source)
    #expect(assets["blog/plain.jpg"]?.sourceSHA256 == nil)
  }
}

/// `project.meta`'s `compression` key, read tolerantly and written in place.
@Suite struct ProjectCompressionSettingsTests {
  @Test("A missing or malformed compression key reads as off with the default options")
  func tolerantDefaults() {
    for meta in ["", "[]", "{}", #"{"compression": 3}"#, #"{"compression": "on"}"#] {
      let settings = ProjectSettings(meta: meta)
      #expect(settings.compression == ProjectCompression())
      #expect(!settings.compression.isEnabled)
      #expect(settings.compression.options == .default)
      #expect(settings.compression.effectiveOptions == nil)
    }
  }

  @Test("Each field reads on its own; a wrong type falls back to that field's default")
  func fieldByField() {
    let full = ProjectSettings(
      meta: #"{"compression": {"enabled": true, "longestEdge": null, "quality": "small", "removeMetadata": false}}"#)
    #expect(full.compression.isEnabled)
    #expect(full.compression.options == CompressionOptions(longestEdge: nil, quality: .small, removesMetadata: false))
    #expect(full.compression.effectiveOptions == full.compression.options)

    let wrong = ProjectSettings(
      meta: #"{"compression": {"enabled": "yes", "longestEdge": -5, "quality": "huge", "removeMetadata": "no"}}"#)
    #expect(wrong.compression == ProjectCompression())

    let partial = ProjectSettings(meta: #"{"compression": {"enabled": true, "longestEdge": 1600}}"#)
    #expect(partial.compression.options == CompressionOptions(longestEdge: 1600))
  }

  @Test("setCompression writes one key and keeps the others")
  func writeKeepsOtherKeys() throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    try CatalogConfiguration.setUsageTracking(slug: "blog", .notTracked, in: fixture.database)

    let settings = try CatalogConfiguration.setCompression(slug: "blog", in: fixture.database) {
      $0.isEnabled = true
      $0.options.longestEdge = nil
      $0.options.quality = .medium
    }

    #expect(settings.usageTracking == .notTracked)
    #expect(settings.compression.isEnabled)
    #expect(settings.compression.options == CompressionOptions(longestEdge: nil, quality: .medium))
    let reread = try CatalogConfiguration.projectSettings(slug: "blog", in: fixture.database)
    #expect(reread == settings)

    let off = try CatalogConfiguration.setCompression(slug: "blog", in: fixture.database) {
      $0.isEnabled = false
    }
    #expect(off.compression.options == settings.compression.options)
    #expect(throws: CatalogConfigurationError.self) {
      try CatalogConfiguration.setCompression(slug: "nope", in: fixture.database) { _ in }
    }
  }

  @Test("A choice follows the project, or forces compression on or off")
  func choiceResolves() throws {
    let fixture = try CompressionFixture()
    defer { fixture.remove() }
    let plain = fixture.project
    try CatalogConfiguration.setCompression(slug: "blog", in: fixture.database) {
      $0.isEnabled = true
      $0.options.quality = .small
    }
    let enabled = try #require(try CatalogConfiguration.projects(in: fixture.database).first)
    let small = CompressionOptions(quality: .small)

    #expect(CompressionChoice.project.options(for: nil) == nil)
    #expect(CompressionChoice.project.options(for: plain) == nil)
    #expect(CompressionChoice.project.options(for: enabled) == small)
    #expect(CompressionChoice.on.options(for: nil) == .default)
    #expect(CompressionChoice.on.options(for: plain) == .default)
    #expect(CompressionChoice.on.options(for: enabled) == small)
    #expect(CompressionChoice.off.options(for: enabled) == nil)
  }
}

private struct FixedInventory: ObjectInventory {
  let heads: [S3ObjectHead]

  func listObjects() async throws -> [S3ObjectSummary] {
    heads.map { S3ObjectSummary(key: $0.key, byteSize: $0.byteSize) }
  }

  func headObject(key: String) async throws -> S3ObjectHead {
    try #require(heads.first { $0.key == key })
  }
}

private final class CompressionFixture {
  let directory: URL
  let database: CatalogDatabasePool
  let backend: Backend
  let project: Project
  let uploader = RecordingUploader()
  let date = Date(timeIntervalSince1970: 1_787_184_000)

  init(empty: Bool = false) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    guard !empty else {
      backend = Backend(
        slug: "-", kind: "s3", endpoint: "", bucket: "", region: "", urlPrefix: "",
        keychainRef: "", createdAt: "", updatedAt: "")
      project = Project(slug: "-", name: "-", createdAt: "", updatedAt: "")
      return
    }
    backend = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://storage.example.com", bucket: "images", region: "auto",
      urlPrefix: "https://img.example.com", keychainReference: "backend.r2", to: database,
      now: date)
    project = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "blog", backendSlug: "r2", to: database, now: date)
  }

  func addProject(_ slug: String) throws -> Project {
    try CatalogConfiguration.addProject(
      slug: slug, name: slug, keyPrefix: slug, backendSlug: "r2", to: database, now: date)
  }

  func pipeline(project: Project? = nil) -> UploadPipeline {
    UploadPipeline(
      database: database, uploader: uploader, backend: backend, project: project ?? self.project)
  }

  func write(_ data: Data, as name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  func assets() throws -> [Asset] {
    try database.read { try Asset.order(Column("id")).fetchAll($0) }
  }

  func projectLinks() throws -> Int {
    try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset_project")! }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
