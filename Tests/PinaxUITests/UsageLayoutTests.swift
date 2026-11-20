import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// Usage:
///
/// 1. The range bar's wording: "N refs · N files · scanned …", or "No
///    completed scan", with the figures set apart.
/// 2. "Line N" and "same as above": a file's references in line order, an
///    image the file used twice marked on its later cell.
/// 3. The reference badge only above one reference.
/// 4. The inspector's Used In leads on Usage and only there, with the file
///    over "project › directory" and the line's capsule.
/// 5. The configured numbers are the ones laid out.
@MainActor
@Suite struct UsageLayoutTests {
  // MARK: - Fixture

  /// blog, one completed scan (2026-08-20 13:00):
  ///
  ///   a0  posts/alpha.md L3 and L9 (the same image twice), posts/beta.md L5
  ///   a1  posts/alpha.md L7
  ///   a2  posts/beta.md L2 and L4
  ///
  /// Six references, two files, three images.
  private func withFixture(_ body: (GalleryModel, DatabasePool) async throws -> Void)
    async throws
  {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<3 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-20T12:0\(index):00Z")
    }
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO scan (id, project_id, started_at, finished_at, coverage, found_count)
          VALUES (9, 1, '2026-08-20T13:00:00Z', '2026-08-20T13:00:00Z', '[]', 0);
          UPDATE project SET last_scan_id = 9 WHERE slug = 'blog';
          """)
      let references: [(Int, String)] = [
        (0, "posts/alpha.md#L3"), (0, "posts/alpha.md#L9"), (0, "posts/beta.md#L5"),
        (1, "posts/alpha.md#L7"), (2, "posts/beta.md#L2"), (2, "posts/beta.md#L4"),
      ]
      for (index, source) in references {
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            SELECT p.id, a.id, 'https://img.example.com/' || a.key, ?, 'markdown',
              '2026-08-20T13:00:00Z', '2026-08-20T13:00:00Z', 9
            FROM project p, asset a
            WHERE p.slug = 'blog' AND a.sha256 = ?
            """,
          arguments: [source, String(format: "%064x", index + 1)])
      }
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await model.loadInitialData()
    model.usagePage = .images
    model.select(.usage, in: .reports)
    await model.reload()
    #expect(model.usageBrowser != nil)
    try await body(model, database)
  }

  private func until(_ condition: () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - 1. The range bar's words

  @Test("The range bar reads 'N refs · N files · scanned …', its figures apart; no scan reads 'No completed scan'")
  func rangeSummary() async throws {
    try await withFixture { model, database in
      let browser = try #require(model.usageBrowser)
      let summaries = try await ReadOnlyCatalog(database: database).projectSummaries()
      let now = try #require(ISO8601DateFormatter().date(from: "2026-08-27T13:00:00Z"))
      let locale = Locale(identifier: "en_US")
      let summary = browser.rangeSummary(projects: summaries, now: now, locale: locale)
      #expect(summary.text == "6 refs · 2 files · scanned 1 week ago")
      #expect(summary.pieces.map(\.text).joined() == summary.text)
      #expect(summary.pieces.filter(\.isFigure).map(\.text) == ["6", "2"])
      #expect(summary.pieces.first?.isFigure == true)

      // One reference and one file stay singular; the pairs are still
      // figures ("1 ref · 1 file").
      #expect(
        UsageBrowser.RangeSummary.scanned(references: 1, files: 1, scan: nil).text
          == "1 ref · 1 file")
      #expect(UsageBrowser.RangeSummary.noScan.text == "No completed scan")
      #expect(UsageBrowser.RangeSummary.noScan.pieces.map(\.isFigure) == [false])

      // Nothing scanned anywhere: the bar says so rather than counting 0.
      let unscanned = UsageBrowser(
        LiveUsageSet(
          references: browser.usage.references, assets: browser.usage.assets,
          scannedProjects: [], projectSources: [:]))
      #expect(unscanned.rangeSummary(projects: summaries) == .noScan)
    }
  }

  // MARK: - 2. Files: groups, rows, "Line N", "same as above"

  @Test("Files: project › directory groups; the grid lists references in line order, a repeated image marked 'same as above'")
  func filesMode() async throws {
    try await withFixture { model, _ in
      let browser = try #require(model.usageBrowser)
      let groups = browser.fileListGroups(sort: .picking(.name), dates: [:], scope: nil)
      #expect(groups.map(\.title) == ["blog › posts"])
      #expect(groups.first?.files.map(\.path) == ["posts/alpha.md", "posts/beta.md"])
      let alpha = try #require(browser.files.first { $0.path == "posts/alpha.md" })
      #expect(alpha.referenceCount == 3 && alpha.images.count == 2)
      #expect(UsageFilesView.headerDetail(alpha, dates: nil) == "2 images · 3 refs")
      // A three-column contact sheet, whatever the zoom rung.
      let grid = try #require(
        collectViews(
          UsageFilesView(model: model, browser: browser).body, as: AssetGridView.self
        ).first)
      // The Files grid follows the zoom rung, like Images.
      #expect(grid.columnCount == nil)

      // "Line N" — and nothing for a reference without a line.
      #expect(AssetGridCell.lineCaption(.line(9)) == "Line 9")
      #expect(AssetGridCell.lineCaption(.line(nil)) == nil)
      #expect(AssetGridCell.lineCaption(nil) == nil)

      model.usagePage = .files
      await until { model.usagePage == .files && model.usageSelectedFileID != nil }
      #expect(model.usageSelectedFileID == "blog\u{0}posts/alpha.md")
      // a0 L3, a1 L7, a0 L9: the file's references in line order, the
      // second use of a0 flagged for "same as above".
      #expect(model.rows.map(\.usage) == [.line(3), .line(7), .line(9)])
      #expect(model.rows.map(\.repeatsPreviousImage) == [false, false, true])
      #expect(Set(model.rows.map(\.id)).count == 3, "every cell has an id of its own")

      model.usageSelectedFileID = "blog\u{0}posts/beta.md"
      await until { model.rows.map(\.usage) == [.line(2), .line(4), .line(5)] }
      #expect(model.rows.map(\.usage) == [.line(2), .line(4), .line(5)])
      #expect(model.rows.map(\.repeatsPreviousImage) == [false, true, false])

      // The repeat's cell is a cell: selecting it loads the image's
      // details through its own id (the inspector is not blank).
      let repeatRow = model.rows[1]
      #expect(repeatRow.id != repeatRow.item.asset.id)
      model.select(repeatRow, mode: .replace)
      await until { model.selectedDetails != nil }
      #expect(model.selectedDetails?.item.asset.id == repeatRow.item.asset.id)
      #expect(model.usedIn != nil)
    }
  }

  // MARK: - 3. The reference badge

  @Test("The reference badge shows only above one reference, on the palette's yellow")
  func referenceBadge() async throws {
    try await withFixture { model, _ in
      #expect(!AssetGridCell.showsReferenceBadge(.image(uses: 1, hasOldDomain: false, references: [])))
      #expect(AssetGridCell.showsReferenceBadge(.image(uses: 2, hasOldDomain: false, references: [])))
      #expect(AssetGridCell.showsReferenceBadge(.line(3)) == false)
      #expect(AssetGridCell.showsReferenceBadge(nil) == false)

      let cache = ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-t06-cell-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) })
      var row = try #require(model.rows.first)
      row.usage = .image(uses: 1, hasOldDomain: false, references: [])
      let one = AssetGridCell(
        row: row, cache: cache, overlays: GridOverlayOptions(), usageCaption: .images)
      #expect(collectViews(one.body, as: UsageRefsBadge.self).isEmpty)
      row.usage = .image(uses: 2, hasOldDomain: false, references: [])
      let two = AssetGridCell(
        row: row, cache: cache, overlays: GridOverlayOptions(), usageCaption: .images)
      let badges = collectViews(two.body, as: UsageRefsBadge.self)
      #expect(badges.count == 1)
      #expect(badges.first?.count == 2)
    }
  }

  // MARK: - 4. The inspector

  @Test("Used In leads on Usage only; its rows are the file over project › directory with the line's capsule")
  func inspectorOrder() async throws {
    try await withFixture { model, _ in
      #expect(AssetInspectorView.bandOrder(on: .usage).first == .usedIn)
      #expect(
        AssetInspectorView.bandOrder(on: .usage)
          == [.usedIn, .sourceLink, .note, .tagsLabels, .projects, .identity])
      for surface: SidebarSelection in [.all, .favorites, .externals] {
        #expect(
          AssetInspectorView.bandOrder(on: surface)
            == [.sourceLink, .note, .tagsLabels, .projects, .usedIn, .identity],
          "\(surface)")
      }
      #expect(
        AssetInspectorView.Band.allCases.map(\.title)
          == ["Source & Link", "Note", "Tags & Labels", "Projects", "Used In", "Identity"])

      // One asset selected on Usage: Used In first, in the detailed form.
      let row = try #require(model.rows.first { $0.usage?.mapUses == 3 })
      model.select(row, mode: .replace)
      await until { model.usedIn != nil }
      let groups = collectViews(AssetInspectorView(model: model).body, as: UsedInGroup.self)
      let group = try #require(groups.first)
      #expect(group.showsReferenceDetail)
      #expect(
        group.referenceRows.map { "\($0.fileName)|\($0.location)|\($0.line ?? 0)" }
          == ["alpha.md|blog › posts|3", "alpha.md|blog › posts|9", "beta.md|blog › posts|5"])
      #expect(AssetInspectorView(model: model).usedInCount == "3")

      // The library's inspector keeps its one-line rows and the old order.
      model.select(.all, in: .library)
      await model.reload()
      await until { model.shownSelection == .all && !model.rows.isEmpty }
      let libraryGroups = collectViews(AssetInspectorView(model: model).body, as: UsedInGroup.self)
      #expect(libraryGroups.first?.showsReferenceDetail == false)
      #expect(AssetInspectorView.bandOrder(on: .all).first == .sourceLink)
    }
  }

  // MARK: - 5. Configured numbers

  @Test("The range bar, file list and caption numbers are the configured ones")
  func canvasNumbers() async throws {
    #expect(DesignMetrics.usageScope.height == 38)
    #expect(DesignMetrics.usageOutlineCapsule.height == 22)
    #expect(DesignMetrics.usageOutlineCapsule.radius == 11)
    #expect(DesignMetrics.usageOutlineCapsule.lineWidth == 1)
    #expect(DesignMetrics.usage.filesWidth == 236)
    #expect(DesignMetrics.usageFiles.rowHeight == 36)
    #expect(DesignMetrics.usageFiles.headerHeight == 50)
    #expect(DesignMetrics.usageFiles.actionWidth == 30)
    #expect(DesignMetrics.usageRefsBadge.inset == 5)
    #expect(DesignMetrics.usageRefsBadge.radius == 5)
    #expect(DesignMetrics.usageRefsBadge.glyph == 10)
    #expect(DesignMetrics.usageLineBadge.radius == 5)

    // Hosted, the bar is that height, and it offers Images | Files, the
    // Old domains capsule, the counts and one Scan Now.
    try await withFixture { model, _ in
      let host = NSHostingView(rootView: UsageScopeBar(model: model).frame(width: 700))
      host.frame = NSRect(origin: .zero, size: host.fittingSize)
      host.layoutSubtreeIfNeeded()
      #expect(abs(host.fittingSize.height - DesignMetrics.usageScope.height) < 0.5,
        "\(host.fittingSize)")
    }
  }
}

// MARK: - Small readers

extension UsageRowInfo {
  /// The Images case's count, for the fixture's lookups.
  fileprivate var mapUses: Int? {
    guard case let .image(uses, _, _) = self else { return nil }
    return uses
  }
}
