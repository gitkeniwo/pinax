import CatalogCore
import Foundation
import GRDB
import Testing

/// The asset source — classification, the query
/// filter, and the Inspector's description. Temporary catalogs only; every
/// host is `.invalid`.
@Suite struct AssetSourceTests {
  // MARK: - Classification (two keys only)

  @Test(
    "Each meta shape classifies by imported_from, then source_url",
    arguments: [
      (#"{"imported_from":"picgo"}"#, AssetSource.picgo),
      (#"{"imported_from":"externals"}"#, .bucket),
      (#"{"imported_from":"bucket"}"#, .bucket),
      (#"{"imported_from":"hexo"}"#, .otherImport),
      (#"{"imported_from":"externals","source_url":"https://old.pinax.invalid/a.png"}"#, .bucket),
      (#"{"source_url":"https://old.pinax.invalid/a.png"}"#, .migrated),
      (#"{"imported_from":"","source_url":"https://old.pinax.invalid/a.png"}"#, .migrated),
      ("{}", .pinax),
      ("", .pinax),
      (#"{"imported_from":"picgo""#, .pinax),
      ("[]", .pinax),
      (#"{"imported_from":7}"#, .pinax),
    ])
  func classification(meta: String, expected: AssetSource) {
    #expect(AssetSource.of(meta: meta) == expected)
  }

  @Test("No meta at all is a Pinax upload")
  func missingMeta() {
    #expect(AssetSource.of(meta: nil) == .pinax)
  }

  // MARK: - Filter

  /// One row per shape the classifier knows, including bad JSON.
  static let fixtureMetas = [
    "{}",
    #"{"imported_from":"picgo"}"#,
    #"{"imported_from":"picgo"}"#,
    #"{"imported_from":"externals"}"#,
    #"{"imported_from":"externals","source_url":"https://img.pinax.invalid/b.png"}"#,
    #"{"imported_from":"bucket"}"#,
    #"{"imported_from":"hexo"}"#,
    #"{"source_url":"https://old.pinax.invalid/m.png"}"#,
    "not json",
    #"{"imported_from":""}"#,
    "[1]",
  ]

  @Test("Every single source and every combination returns exactly what the classifier says")
  func filterMatchesClassifier() throws {
    try withSourceCatalog { database in
      let all = try database.read { db in try Asset.fetchAll(db) }
      #expect(all.count == Self.fixtureMetas.count)
      let cases = AssetSource.allCases
      // Every non-empty subset of the five sources.
      for mask in 1..<(1 << cases.count) {
        let chosen = Set(cases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
        var query = AssetQuery()
        query.sources = chosen
        query.limit = 1000
        let page = try CatalogAssets.page(query, in: database)
        let got = Set(page.items.compactMap(\.asset.id))
        let want = Set(all.filter { chosen.contains(AssetSource.of(meta: $0.meta)) }.compactMap(\.id))
        #expect(got == want, "sources \(chosen.map(\.rawValue).sorted())")
        #expect(try CatalogAssets.count(query, in: database) == want.count)
      }
      // Each source on its own has the fixture's expected size.
      func count(_ source: AssetSource) throws -> Int {
        var query = AssetQuery()
        query.sources = [source]
        return try CatalogAssets.count(query, in: database)
      }
      #expect(try count(.pinax) == 4)
      #expect(try count(.picgo) == 2)
      #expect(try count(.bucket) == 3)
      #expect(try count(.otherImport) == 1)
      #expect(try count(.migrated) == 1)
      // No sources is no filter.
      #expect(try CatalogAssets.count(AssetQuery(), in: database) == Self.fixtureMetas.count)
    }
  }

  @Test("The source filter combines with the other conditions and pages by cursor")
  func filterCombinesAndPages() throws {
    try withSourceCatalog { database in
      var query = AssetQuery()
      query.sources = [.picgo, .bucket]
      query.search = "a"
      query.limit = 2
      var seen: [Int64] = []
      var cursor: AssetCursor?
      repeat {
        query.after = cursor
        let page = try CatalogAssets.page(query, in: database)
        seen += page.items.compactMap(\.asset.id)
        cursor = page.next
      } while cursor != nil
      let all = try database.read { db in try Asset.fetchAll(db) }
      let want = all.filter {
        [.picgo, .bucket].contains(AssetSource.of(meta: $0.meta)) && $0.key.contains("a")
      }.compactMap(\.id)
      #expect(Set(seen) == Set(want))
      #expect(seen.count == want.count)
    }
  }

  // MARK: - Description (Inspector Source row)

  static let backend = Backend(
    id: 1, slug: "r2", kind: "s3", endpoint: "https://s3.pinax.invalid", bucket: "images",
    urlPrefix: "https://img.pinax.invalid", keychainRef: "", createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z")

  static func asset(meta: String) -> Asset {
    Asset(
      id: 1, sha256: String(repeating: "a", count: 64), backendID: 1, key: "2020/a.png",
      byteSize: 1, mime: "image/png", meta: meta, uploadedAt: "2020-05-01T00:00:00Z",
      createdAt: "2026-10-14T17:55:02Z", updatedAt: "2026-10-14T17:55:02Z")
  }

  @Test("A recorded source_url names its own host")
  func descriptionWithSourceURL() {
    let description = AssetSourceDescription(
      asset: Self.asset(
        meta: #"{"imported_from":"externals","source_url":"https://img.pinax.invalid/2020/a.png"}"#),
      backend: Self.backend)
    #expect(description.source == .bucket)
    #expect(description.title == "Imported from your bucket")
    #expect(description.domain == "img.pinax.invalid")
    #expect(description.addedAt == "2026-10-14T17:55:02Z")
    #expect(
      description.text(date: "14 Oct 2026")
        == "Imported from your bucket · img.pinax.invalid · 14 Oct 2026")
  }

  @Test("Without source_url the domain falls back to the backend's current prefix")
  func descriptionFallsBackToPrefix() {
    let bucket = AssetSourceDescription(
      asset: Self.asset(meta: #"{"imported_from":"externals"}"#), backend: Self.backend)
    #expect(bucket.domain == "img.pinax.invalid")
    #expect(bucket.text(date: "D") == "Imported from your bucket · img.pinax.invalid · D")
    let picgo = AssetSourceDescription(
      asset: Self.asset(meta: #"{"imported_from":"picgo"}"#), backend: Self.backend)
    #expect(picgo.title == "Imported from PicGo")
    #expect(picgo.text(date: "D") == "Imported from PicGo · D")
    let pinax = AssetSourceDescription(asset: Self.asset(meta: "{}"), backend: Self.backend)
    #expect(pinax.source == .pinax)
    #expect(pinax.title == "Uploaded by Pinax")
    #expect(pinax.text(date: "D") == "Uploaded by Pinax · D")
    let broken = AssetSourceDescription(asset: Self.asset(meta: "{oops"), backend: Self.backend)
    #expect(broken.text(date: "D") == "Uploaded by Pinax · D")
  }

  @Test("An asset claimed through a retired domain names that domain, not the current prefix")
  func descriptionViaOldDomain() {
    let description = AssetSourceDescription(
      asset: Self.asset(
        meta: #"{"imported_from":"externals","source_url":"https://old.pinax.invalid/2019/c.png"}"#),
      backend: Self.backend)
    #expect(description.domain == "old.pinax.invalid")
    #expect(
      description.text(date: "D") == "Imported from your bucket · old.pinax.invalid · D")
  }

  // MARK: - Fixture

  private func withSourceCatalog(_ body: (DatabasePool) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    try database.write { db in
      var backend = Self.backend
      backend.id = nil
      try backend.insert(db)
      for (index, meta) in Self.fixtureMetas.enumerated() {
        let name = index.isMultiple(of: 2) ? "a\(index).png" : "z\(index).png"
        _ = try Asset(
          sha256: Hashing.sha256(of: Data(name.utf8)), backendID: 1, key: "2020/\(name)",
          byteSize: 1, mime: "image/png", meta: meta,
          uploadedAt: "2020-01-\(String(format: "%02d", index + 1))T00:00:00Z",
          createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"
        ).insertAndFetch(db)
      }
    }
    try body(database)
  }
}
