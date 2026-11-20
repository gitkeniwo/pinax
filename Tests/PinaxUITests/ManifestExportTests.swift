import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing

@MainActor
@Suite struct ManifestExportTests {
  @Test("Manifest export cancellation writes no file; commit matches CLI bytes and leaves the catalog unchanged")
  func cancellationBytesAndReadOnlyCatalog() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(
      database, index: 9, uploadedAt: "2026-08-24T12:00:00Z", projectSlug: "blog")
    let generatedAt = Date(timeIntervalSince1970: 1_777_000_000)
    let exporter = CatalogManifestExporter(database: database, generatedAt: generatedAt)
    let cancelledURL = directory.appendingPathComponent("cancelled.json")
    let before = try catalogTableDump(database)
    let cancelled = ManifestExportModel(exporter: exporter) { defaultFilename in
      #expect(defaultFilename == "blog-manifest.json")
      return nil
    }

    await cancelled.export(project: "blog")
    #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))
    #expect(try catalogTableDump(database) == before)

    let output = directory.appendingPathComponent("blog-manifest.json")
    let committed = ManifestExportModel(exporter: exporter) { _ in output }
    await committed.export(project: "blog")

    let manifest = try CatalogManifest.export(
      project: "blog", from: database, generatedAt: generatedAt)
    let expected = Data((try manifest.json() + "\n").utf8)
    #expect(try Data(contentsOf: output) == expected)
    #expect(committed.notice?.contains("1 assets") == true)
    #expect(committed.notice?.contains("\(expected.count) bytes") == true)
    #expect(try catalogTableDump(database) == before)
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
