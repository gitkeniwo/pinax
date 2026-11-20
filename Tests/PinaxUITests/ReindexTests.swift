import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

@MainActor
@Suite struct ReindexTests {
  @Test("Reindex is disabled with a specific explanation when credentials are absent")
  func missingCredentialsDisableReindex() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = Keychain(service: "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)")
    let model = BackendsModel(
      reader: CatalogBackendsReader(database: database, keychain: keychain),
      reindexer: CatalogReindexRunner(
        database: database, keychain: keychain,
        inventoryFactory: { _, _ in TestObjectInventory(summaries: [], heads: [:]) }))

    await model.load()

    #expect(model.details?.credentialsConfigured == false)
    #expect(!model.canRunReindex)
    #expect(BackendReindexControls.missingCredentialsText == "Set credentials first.")
  }

  @Test("Production reindex keeps dry runs read-only and applied counts match catalog changes")
  func dryRunThenApply() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 30, uploadedAt: "2026-08-24T10:00:00Z")
    let service = "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)"
    let keychain = Keychain(service: service)
    try keychain.store(
      BackendCredentials(accessKeyID: "test-access", secretAccessKey: "test-secret"),
      for: "backend.r2")
    defer { try? keychain.delete(for: "backend.r2") }

    let existingHash = String(format: "%064x", 31)
    let newHash = String(repeating: "c", count: 64)
    let inventory = TestObjectInventory(
      summaries: [
        S3ObjectSummary(key: "blog/existing-copy.png", byteSize: 1030),
        S3ObjectSummary(key: "blog/recovered.png", byteSize: 2048),
        S3ObjectSummary(key: "legacy.png", byteSize: 64),
      ],
      heads: [
        "blog/existing-copy.png": validHead(
          key: "blog/existing-copy.png", sha256: existingHash, filename: "existing.png"),
        "blog/recovered.png": validHead(
          key: "blog/recovered.png", sha256: newHash, filename: "recovered.png"),
        "legacy.png": S3ObjectHead(
          key: "legacy.png", byteSize: 64, mime: "image/png", lastModified: nil,
          metadata: [:]),
      ])
    let runner = CatalogReindexRunner(
      database: database,
      keychain: keychain,
      inventoryFactory: { _, _ in inventory })
    let model = BackendsModel(
      reader: CatalogBackendsReader(database: database, keychain: keychain),
      reindexer: runner)
    await model.load()
    #expect(model.canRunReindex)
    #expect(!model.canApplyReindex)
    let beforeDump = try catalogTableDump(database)
    let beforeAssets = try assetCount(database)

    await model.runReindexDryRun()

    let dryRun = try #require(model.reindexDryRunResult)
    assertCounts(dryRun, dryRun: true)
    #expect(try catalogTableDump(database) == beforeDump)
    #expect(try assetCount(database) == beforeAssets)
    #expect(model.canApplyReindex)

    await model.applyReindex()

    let applied = try #require(model.reindexAppliedResult)
    assertCounts(applied, dryRun: false)
    #expect(model.reindexDryRunResult == nil)
    #expect(!model.canApplyReindex)
    #expect(try assetCount(database) - beforeAssets == applied.reconstructed)
    let recovered = try await database.read { db in
      try Asset.filter(Column("sha256") == newHash).fetchOne(db)
    }
    #expect(recovered?.key == "blog/recovered.png")
  }

  private func assertCounts(_ result: ReindexResult, dryRun: Bool) {
    #expect(result.dryRun == dryRun)
    #expect(result.scanned == 3)
    #expect(result.reconstructed == 1)
    #expect(result.existing == 1)
    #expect(
      result.missingMetadata == [
        ReindexMissingMetadata(
          key: "legacy.png", missing: ["sha256", "orig-filename", "width", "height"])
      ])
  }

  private func validHead(
    key: String, sha256: String, filename: String
  ) -> S3ObjectHead {
    S3ObjectHead(
      key: key,
      byteSize: 2048,
      mime: "image/png",
      lastModified: "2026-08-24T12:00:00Z",
      metadata: [
        "sha256": sha256,
        "orig-filename": MetadataValueCodec.encode(filename),
        "width": "800",
        "height": "600",
      ])
  }

  private func assetCount(_ database: DatabasePool) throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
    }
  }

  private func catalogTableDump(_ database: DatabasePool) throws -> String {
    try database.read { db in
      let tables = [
        "backend", "backend_prefix_history", "project", "asset", "asset_project",
        "tag", "asset_tag", "scan", "usage",
      ]
      return try tables.map { table in
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
          .map(\.description)
        return "\(table):\n" + rows.joined(separator: "\n")
      }.joined(separator: "\n")
    }
  }

}

private struct TestObjectInventory: ObjectInventory {
  enum InventoryError: Error {
    case missingHead(String)
  }

  let summaries: [S3ObjectSummary]
  let heads: [String: S3ObjectHead]

  func listObjects() async throws -> [S3ObjectSummary] {
    summaries
  }

  func headObject(key: String) async throws -> S3ObjectHead {
    guard let head = heads[key] else { throw InventoryError.missingHead(key) }
    return head
  }
}
