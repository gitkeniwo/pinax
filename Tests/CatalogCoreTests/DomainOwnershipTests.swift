import CatalogCore
import Foundation
import GRDB
import Testing

/// A domain belongs to one backend; the
/// key-prefix tree is per backend, with each backend's total.
@Suite struct DomainOwnershipTests {
  private struct Stub: RewriteTargetVerifying {
    func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification { .ok(sha256: "x") }
  }

  /// Backends `r2` (`img.r2.com`, old `old.r2.com`) and `s3` (`img.s3.com`,
  /// old `old.s3.com`); `assets` are `(backend id, key)`.
  private func makeDatabase(assets: [(Int64, String)] = []) throws -> (DatabasePool, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-owner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    for slug in ["r2", "s3"] {
      _ = try CatalogConfiguration.addBackend(
        slug: slug, endpoint: "https://storage.example.com", bucket: slug, region: "auto",
        urlPrefix: "https://img.\(slug).com", keychainReference: "backend.\(slug)", to: database)
      try CatalogConfiguration.addOldDomain("https://old.\(slug).com", backendSlug: slug, in: database)
    }
    try database.write { db in
      for (index, (backend, key)) in assets.enumerated() {
        _ = try Asset(
          sha256: String(format: "%064x", index + 1), backendID: backend, key: key, byteSize: 1,
          mime: "image/png", uploadedAt: "2024-01-01T00:00:00Z", createdAt: "2024-01-01T00:00:00Z",
          updatedAt: "2024-01-01T00:00:00Z"
        ).insertAndFetch(db)
      }
    }
    return (database, directory)
  }

  @Test("Add old domain, set prefix and migrate refuse another backend's current or old domain; same backend as before")
  func oneBackendPerDomain() async throws {
    let (database, directory) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (value, stored) in [("https://IMG.s3.com", "https://IMG.s3.com"), ("https://old.s3.com/", "https://old.s3.com")] {
      let refusal = CatalogConfigurationError.domainOfOtherBackend(prefix: stored, backend: "s3")
      #expect(throws: refusal) { try CatalogConfiguration.addOldDomain(value, backendSlug: "r2", in: database) }
      #expect(throws: refusal) { _ = try CatalogConfiguration.setBackendURLPrefix(slug: "r2", urlPrefix: value, in: database) }
      await #expect(throws: refusal) {
        _ = try await DomainMigration.preview(
          backend: "r2", to: value, projects: ["x"], verifier: Stub(), database: database)
      }
    }
    #expect(refusalText() == "'https://old.s3.com' is already a domain of backend 's3'. A domain belongs to one backend.")
    #expect(try CatalogConfiguration.rewriteMap(backendSlug: "r2", in: database)
      == RewriteMap(current: "https://img.r2.com", retired: ["https://old.r2.com"]))

    // Within one backend nothing changed: re-adding is a no-op, switching
    // to an old domain and back works.
    try CatalogConfiguration.addOldDomain("https://old.r2.com", backendSlug: "r2", in: database)
    _ = try CatalogConfiguration.setBackendURLPrefix(slug: "r2", urlPrefix: "https://old.r2.com", in: database)
    _ = try CatalogConfiguration.setBackendURLPrefix(slug: "r2", urlPrefix: "https://img.r2.com", in: database)
    #expect(try CatalogConfiguration.rewriteMap(backendSlug: "r2", in: database).current == "https://img.r2.com")
  }

  private func refusalText() -> String {
    CatalogConfigurationError.domainOfOtherBackend(prefix: "https://old.s3.com", backend: "s3").description
  }

  @Test("Two backends' 202409 folders stay apart; each backend's total")
  func keyPrefixPerBackend() throws {
    let (database, directory) = try makeDatabase(assets: [
      (1, "202409/a.png"), (1, "202409/b.png"), (1, "2025/c.png"),
      (2, "202409/x.png"), (2, "202409/sub/y.png"),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    func level(_ prefix: String?, _ backend: Int64) throws -> [String] {
      try CatalogAssets.keyPrefixChildren(under: prefix, backendID: backend, in: database)
        .map { "\($0.segment) \($0.assetCount) \($0.hasSubPrefixes)" }
    }
    #expect(try level(nil, 1) == ["202409 2 false", "2025 1 false"])
    #expect(try level(nil, 2) == ["202409 2 true"])
    #expect(try level("202409", 1) == [])
    #expect(try level("202409", 2) == ["sub 1 false"])
    #expect(try CatalogAssets.backendAssetTotals(in: database).map { "\($0.backendID) \($0.slug) \($0.assetCount)" }
      == ["1 r2 3", "2 s3 2"])
    _ = try CatalogConfiguration.addBackend(
      slug: "b2", endpoint: "https://storage.example.com", bucket: "b2", region: "auto",
      urlPrefix: "https://img.b2.com", keychainReference: "backend.b2", to: database)
    #expect(try CatalogAssets.backendAssetTotals(in: database).map(\.assetCount) == [3, 2, 0])
  }
}
