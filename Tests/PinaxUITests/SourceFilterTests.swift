import CatalogCore
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import PinaxUI

/// The Source filter lists all five sources with
/// their counts, Other Imports only when it has any; the sort menu's Show
/// section and the find strip's popup write one filter; and the app's
/// Info.plist allows `http://` loads.
@MainActor
@Suite(.serialized) struct SourceFilterTests {
  static let picgoMeta = #"{"imported_from":"picgo"}"#
  static let migratedMeta = #"{"source_url":"https://old.pinax.invalid/a.png"}"#
  static let otherMeta = #"{"imported_from":"hexo"}"#

  /// 1 Pinax, 1 PicGo, 3 migrated, plus `others` Other Imports.
  private func seed(_ database: DatabasePool, others: Int) throws {
    var rows: [(String, String)] = [
      ("pinax.png", "{}"),
      ("picgo.png", Self.picgoMeta),
      ("migrated-1.png", Self.migratedMeta),
      ("migrated-2.png", Self.migratedMeta),
      ("migrated-3.png", Self.migratedMeta),
    ]
    for index in 0..<others { rows.append(("other-\(index).png", Self.otherMeta)) }
    for (index, row) in rows.enumerated() {
      try seedAsset(
        database, index: index, uploadedAt: "2026-08-0\(index % 9 + 1)T10:00:00Z",
        origFilename: row.0, meta: row.1)
    }
  }

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-sourcem7-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  private func loaded(others: Int) async throws -> (GalleryModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    try seed(database, others: others)
    let model = makeModel(database)
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    await model.refreshSourceCounts()
    return (model, directory)
  }

  private func names(_ model: GalleryModel) -> Set<String> {
    Set(model.rows.compactMap(\.item.asset.originalFilename))
  }

  @Test("Migrated and Other Imports: counts, items and filtered rows")
  func fiveSources() async throws {
    let (model, directory) = try await loaded(others: 2)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(
      model.sourceCounts
        == GalleryModel.SourceCounts(
          all: 7, pinax: 1, picgo: 1, bucket: 0, migrated: 3, otherImport: 2))
    #expect(
      SourceFilterItems.entries(model.sourceCounts, selected: nil).map(\.title) == [
        "All Sources (7)", "Uploaded by Pinax (1)", "PicGo (1)", "Bucket (0)",
        "Migrated (3)", "Other Imports (2)",
      ])

    model.sourceFilter = .migrated
    await model.reload()
    #expect(names(model) == ["migrated-1.png", "migrated-2.png", "migrated-3.png"])
    #expect(
      WindowTitle.countSentence(
        totalCount: model.totalCount, unfilteredTotalCount: model.unfilteredTotalCount,
        rowsCount: model.rows.count) == "3 of 7 assets")

    model.sourceFilter = .otherImport
    await model.reload()
    #expect(names(model) == ["other-0.png", "other-1.png"])
  }

  @Test("Other Imports is not listed at zero; the other sources always are")
  func otherImportsHiddenAtZero() async throws {
    let (model, directory) = try await loaded(others: 0)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.sourceCounts.otherImport == 0)
    #expect(
      SourceFilterItems.entries(model.sourceCounts, selected: nil).map(\.source) == [
        nil, .pinax, .picgo, .bucket, .migrated,
      ])
    // Chosen while it had rows, it stays listed so the picker holds a
    // listed value.
    #expect(
      SourceFilterItems.entries(model.sourceCounts, selected: .otherImport).last?.source
        == .otherImport)
  }

  @Test("The sort menu's Show section and the find strip's popup write one filter")
  func oneFilter() async throws {
    let (model, directory) = try await loaded(others: 1)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(!GalleryView(model: model).showsFilterBar)

    JumpBar(model: model).sourceFilterItems.source = .migrated
    #expect(model.sourceFilter == .migrated)
    #expect(FindStrip(model: model).sourceItems.source == .migrated)
    // Set from the menu, the filter is visible: the strip comes up showing it.
    #expect(GalleryView(model: model).showsFilterBar)
    await model.reload()
    #expect(model.rows.count == 3)

    FindStrip(model: model).sourceItems.source = .picgo
    #expect(JumpBar(model: model).sourceFilterItems.source == .picgo)
    FindStrip(model: model).sourceItems.source = nil
    #expect(model.sourceFilter == nil)
    #expect(!GalleryView(model: model).showsFilterBar)
  }

  @Test("The Show section applies on asset lists, not on the report pages")
  func appliesHere() {
    #expect(SourceFilterItems.applies(to: .all))
    #expect(SourceFilterItems.applies(to: .project("astro")))
    for report in [GalleryModel.SidebarSelection.overview, .orphans, .externals, .usage] {
      #expect(!SourceFilterItems.applies(to: report))
    }
  }

  @Test("The app's Info.plist allows arbitrary loads, merged with the generated one")
  func appTransportSecurity() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    let app = root.appendingPathComponent("PinaxApp")
    let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
    let plist = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
    #expect(ats["NSAllowsArbitraryLoads"] as? Bool == true)

    let project = try String(
      contentsOf: app.appendingPathComponent("PinaxApp.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    #expect(project.components(separatedBy: "INFOPLIST_FILE = Info.plist;").count - 1 == 2)
    #expect(project.components(separatedBy: "GENERATE_INFOPLIST_FILE = YES;").count - 1 == 2)
  }
}
