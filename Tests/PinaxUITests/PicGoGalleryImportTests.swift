import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

@MainActor
@Suite struct PicGoGalleryImportTests {
  @Test("Production PicGo import keeps previews read-only and reports every outcome")
  func dryRunThenImport() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("picgo.db")
    let alternateSource = directory.appendingPathComponent("alternate.db")
    let sentinel = "SENTINEL-PICGO-CONFIG-SECRET"
    let gallery = """
      {
        "gallery": [
          {
            "fileName": "one.png",
            "url": "https://img.example.com/gallery/one.png",
            "width": 10,
            "height": 20,
            "createdAt": 1760000000000
          },
          {
            "fileName": "one-copy.png",
            "url": "https://img.example.com/gallery/one.png",
            "width": 10,
            "height": 20,
            "createdAt": 1760000000000
          },
          {
            "fileName": "elsewhere.png",
            "url": "https://elsewhere.example.com/elsewhere.png",
            "createdAt": 1760000000000
          }
        ],
        "config": { "secret": "\(sentinel)", "bucket": "must-not-be-read" }
      }
      """
    try Data(gallery.utf8).write(to: source)
    try Data(gallery.utf8).write(to: alternateSource)
    _ = try CatalogConfiguration.addBackend(
      slug: "archive", endpoint: "https://storage.example.com", bucket: "archive",
      region: "auto", urlPrefix: "https://archive.example.com",
      keychainReference: "backend.archive", to: database)

    let runner = CatalogPicGoGalleryImporter(
      database: database,
      fetcher: TestPublicObjectFetcher(data: Data("one-image".utf8)))
    var chosenSource: URL? = alternateSource
    let model = BackendsModel(
      reader: CatalogBackendsReader(
        database: database,
        keychain: Keychain(service: "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)")),
      picGoImporter: runner,
      picGoSourceURL: source,
      choosePicGoSource: { _ in chosenSource })
    await model.load()
    await model.select("r2")
    let beforeDump = try catalogTableDump(database)
    let beforeAssets = try assetCount(database)

    await model.runPicGoDryRun()

    let preview = try #require(model.picGoDryRunResult)
    assertCounts(preview, dryRun: true)
    #expect(try catalogTableDump(database) == beforeDump)
    #expect(try assetCount(database) == beforeAssets)
    #expect(model.canApplyPicGoImport)
    #expect(String(describing: preview).contains(sentinel) == false)
    #expect(try catalogTableDump(database).contains(sentinel) == false)

    model.choosePicGoGallery()
    #expect(model.picGoSourceURL == alternateSource)
    #expect(model.picGoDryRunResult == nil)
    #expect(!model.canApplyPicGoImport)

    chosenSource = nil
    await model.runPicGoDryRun()
    #expect(model.canApplyPicGoImport)
    await model.select("archive")
    #expect(model.picGoDryRunResult == nil)
    #expect(!model.canApplyPicGoImport)

    await model.select("r2")
    await model.runPicGoDryRun()
    await model.applyPicGoImport()

    let applied = try #require(model.picGoAppliedResult)
    assertCounts(applied, dryRun: false)
    #expect(try assetCount(database) - beforeAssets == applied.imported)
    #expect(model.picGoDryRunResult == nil)
    #expect(!model.canApplyPicGoImport)

    let host = NSHostingView(
      rootView: BackendsSettingsContent(model: model).environment(\.settingsDefaults, islandTestDefaults()))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 470)
    host.layoutSubtreeIfNeeded()
    let text = renderedText(in: host)
    #expect(text.contains("Records read: 3"))
    #expect(text.contains("Distinct keys: 1"))
    #expect(text.contains("Imported: 1"))
    #expect(text.contains("Already present: 0"))
    #expect(text.contains("Duplicate source records: 1"))
    #expect(text.contains("Imported via retired prefix: 0"))
    #expect(text.contains("Skipped: 1"))
    #expect(text.contains(PicGoSkipReason.prefixMismatch))
    #expect(text.contains("https://elsewhere.example.com/elsewhere.png"))
    #expect(text.contains(sentinel) == false)
  }

  private func assertCounts(_ result: PicGoImportResult, dryRun: Bool) {
    #expect(result.dryRun == dryRun)
    #expect(result.recordsRead == 3)
    #expect(result.distinctKeys == 1)
    #expect(result.imported == 1)
    #expect(result.alreadyPresent == 0)
    #expect(result.duplicateSourceRecords == 1)
    #expect(result.importedViaRetiredPrefix == 0)
    #expect(result.skipped.count == 1)
    #expect(result.skipped.first?.reason == PicGoSkipReason.prefixMismatch)
    #expect(result.skipped.first?.url == "https://elsewhere.example.com/elsewhere.png")
    #expect(result.imported + result.skipped.count < result.recordsRead)
  }

  private func assetCount(_ database: DatabasePool) throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
    }
  }

  private func renderedText(in view: NSView) -> String {
    var values: [String] = []
    if let field = view as? NSTextField, !field.stringValue.isEmpty {
      values.append(field.stringValue)
    }
    for child in view.subviews {
      values.append(renderedText(in: child))
    }
    return values.joined(separator: "\n")
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

private struct TestPublicObjectFetcher: PublicObjectFetching {
  let data: Data

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    (data, "image/png", Int64(data.count))
  }
}
