import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// Usage, the Files page and its list:
///
/// 1. Files is the page Usage opens on, first in the switch.
/// 2. The file list sorts by name, the files' dates on disk or references,
///    each in two directions; a file without the date goes last.
/// 3. A group header's segment narrows the list to that folder, a group
///    collapses, and ↑ ↓ walk only the files that show.
/// 4. Images' grid is one section per file in the list's order, an image in
///    two files standing in both; its table stays one row per image.
/// 5. The jump bar's section header and Usage's file segment are links.
/// 6. The list's divider drags within its bounds.
@MainActor
@Suite struct UsageFilesTests {
  /// blog, one completed scan:
  ///
  ///   a0  posts/alpha.md L3, posts/2024/old.md L1
  ///   a1  posts/alpha.md L7, drafts/zeta.md L2, drafts/zeta.md L8
  ///   a2  posts/2024/old.md L4
  private func withFixture(_ body: (GalleryModel) async throws -> Void) async throws {
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
        (0, "posts/alpha.md#L3"), (0, "posts/2024/old.md#L1"), (1, "posts/alpha.md#L7"),
        (1, "drafts/zeta.md#L2"), (1, "drafts/zeta.md#L8"), (2, "posts/2024/old.md#L4"),
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
    model.select(.usage, in: .reports)
    await model.reload()
    #expect(model.usageBrowser != nil)
    try await body(model)
  }

  private func until(_ condition: () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private static let alpha = "blog\u{0}posts/alpha.md"
  private static let old = "blog\u{0}posts/2024/old.md"
  private static let zeta = "blog\u{0}drafts/zeta.md"

  private static func day(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  @Test("Usage opens on Files, the switch's first segment")
  func filesIsTheDefault() async throws {
    #expect(UsagePage.allCases.first == .files)
    try await withFixture { model in
      #expect(model.usagePage == .files)
      // The list's first file: blog › drafts comes before blog › posts.
      #expect(model.usageVisibleFiles.map(\.name) == ["zeta.md", "alpha.md", "old.md"])
      #expect(model.usageSelectedFileID == Self.zeta)
      #expect(model.rows.map(\.usage) == [.line(2), .line(8)])
    }
  }

  @Test("The list sorts by name, date modified or created, or references; a file without the date goes last")
  func sorting() async throws {
    try await withFixture { model in
      let browser = try #require(model.usageBrowser)
      let dates: [UsageFile.ID: UsageFileDates] = [
        Self.alpha: UsageFileDates(created: Self.day("2024-01-01T00:00:00Z"), modified: Self.day("2026-03-01T00:00:00Z")),
        Self.old: UsageFileDates(created: Self.day("2025-01-01T00:00:00Z"), modified: Self.day("2025-06-01T00:00:00Z")),
      ]
      func order(_ sort: UsageFileSort) -> [String] {
        browser.sortedFiles(by: sort, dates: dates).map(\.name)
      }
      #expect(UsageFileSort.standard == UsageFileSort(field: .modified, ascending: false))
      #expect(order(.standard) == ["alpha.md", "old.md", "zeta.md"])
      #expect(order(UsageFileSort(field: .modified, ascending: true)) == ["old.md", "alpha.md", "zeta.md"])
      #expect(order(.picking(.created)) == ["old.md", "alpha.md", "zeta.md"])
      #expect(order(.picking(.name)) == ["alpha.md", "old.md", "zeta.md"])
      #expect(order(UsageFileSort(field: .name, ascending: false)) == ["zeta.md", "old.md", "alpha.md"])
      // References: two each, so ties go by name.
      #expect(order(.picking(.references)) == ["alpha.md", "old.md", "zeta.md"])
      #expect(UsageFileSortField.modified.directionLabels.descending == "Newest First")

      // The row's date follows the field; the header writes "Modified …".
      let locale = Locale(identifier: "en_US")
      #expect(UsageFileList.rowDate(dates[Self.alpha], sort: .modified, locale: locale) == "Mar 1, 2026")
      #expect(UsageFileList.rowDate(dates[Self.alpha], sort: .created, locale: locale) == "Jan 1, 2024")
      #expect(UsageFileList.rowDate(nil, sort: .modified, locale: locale) == nil)
      let file = try #require(browser.files.first { $0.id == Self.alpha })
      #expect(
        UsageFilesView.headerDetail(file, dates: dates[Self.alpha], locale: locale)
          == "Modified Mar 1, 2026 · 2 images · 2 refs")
    }
  }

  @Test("A segment narrows the list to its folder; a collapsed group hides its files from the list and from ↑ ↓")
  func foldersAndKeys() async throws {
    try await withFixture { model in
      model.usageFileSort = .picking(.name)
      let groups = model.usageFileListGroups
      #expect(groups.map(\.title) == ["blog › drafts", "blog › posts", "blog › posts › 2024"])
      let posts2024 = try #require(groups.last)
      #expect(posts2024.segments.map(\.label) == ["blog", "posts", "2024"])

      // "posts": the folder and the one under it; zeta leaves the list.
      model.usageFolderScope = posts2024.segments[1].scope
      #expect(model.usageFileListGroups.map(\.title) == ["blog › posts", "blog › posts › 2024"])
      #expect(model.usageVisibleFiles.map(\.name) == ["alpha.md", "old.md"])
      // "2024": the selection, not in it, moves to its first file.
      model.usageFolderScope = posts2024.segments[2].scope
      #expect(model.usageSelectedFileID == Self.old)
      model.usageFolderScope = nil

      // ↑ ↓ walk what shows and stop at the ends.
      model.usageSelectedFileID = Self.zeta
      model.moveUsageFileSelection(by: -1)
      #expect(model.usageSelectedFileID == Self.zeta)
      model.moveUsageFileSelection(by: 1)
      #expect(model.usageSelectedFileID == Self.alpha)
      model.toggleUsageGroup(posts2024.id)
      #expect(!model.usageVisibleFiles.contains { $0.id == Self.old })
      model.moveUsageFileSelection(by: 1)
      #expect(model.usageSelectedFileID == Self.alpha)
      model.toggleUsageGroup(posts2024.id)
      model.moveUsageFileSelection(by: 1)
      #expect(model.usageSelectedFileID == Self.old)

      // Ungrouped, every file in scope shows, in the list's order.
      model.usageGroupsByFolder = false
      #expect(model.usageVisibleFiles.map(\.name) == ["alpha.md", "old.md", "zeta.md"])
    }
  }

  @Test("Images' grid: one section per file in the list's order, an image in two files in both; the table stays by image")
  func imagesBySection() async throws {
    try await withFixture { model in
      model.usageFileSort = .picking(.name)
      model.usagePage = .images
      await until { model.rows.first?.usageSection != nil }
      #expect(model.showsUsageFileSections && model.showsRowSections)
      // The list's order: blog › drafts, blog › posts, blog › posts › 2024.
      #expect(model.groupedRows.map(\.month) == [Self.zeta, Self.alpha, Self.old])
      #expect(model.groupedRows.map { $0.rows.map(\.usageSection?.line) } == [[2], [3, 7], [1, 4]])
      // a1 under zeta and alpha, a0 under alpha and old: the later cells
      // have ids of their own and are not "same as above".
      #expect(Set(model.rows.map(\.id)).count == model.rows.count)
      #expect(model.rows.filter { $0.id < 0 }.count == 2)
      #expect(model.rows.allSatisfy { !$0.repeatsPreviousImage })

      // Ungrouped, the sort alone orders the sections.
      model.usageGroupsByFolder = false
      #expect(model.groupedRows.map(\.month) == [Self.alpha, Self.old, Self.zeta])
      model.usageFileSort = UsageFileSort(field: .name, ascending: false)
      #expect(model.groupedRows.map(\.month) == [Self.zeta, Self.old, Self.alpha])

      // The table: one row per image, no sections.
      model.viewMode = .table
      #expect(!model.showsRowSections)
      #expect(model.rows.count == 3 && model.rows.allSatisfy { $0.usageSection == nil })
      model.viewMode = .grid
      #expect(model.rows.count == 5)
    }
  }

  @Test("The jump bar: a section header goes to its first place; Usage's file segment opens the file on Files")
  func jumpBarLinks() async throws {
    try await withFixture { model in
      let path = JumpBar.components(
        selection: .usage, navigator: .reports, projects: model.projects, tags: [], months: [],
        folderChildren: [:], usageFileName: "alpha.md", selectedName: "asset-0.png")
      #expect(path.first?.target == .selection(.overview))
      #expect(path.map(\.label).suffix(2) == ["alpha.md", "asset-0.png"])
      #expect(path.first { $0.id == "usageFile" }?.target == .usageFile)
      // Off Usage, no file segment.
      let library = JumpBar.components(
        selection: .all, navigator: .library, projects: [], tags: [], months: [],
        folderChildren: [:], usageFileName: "alpha.md", selectedName: nil)
      #expect(!library.contains { $0.id == "usageFile" })

      // From an Images cell under zeta: Files, zeta selected, no image.
      model.usageFileSort = .picking(.name)
      model.usagePage = .images
      await until { model.rows.first?.usageSection != nil }
      let cell = try #require(model.rows.first { $0.usageSection?.fileID == Self.zeta })
      model.select(cell, mode: .replace)
      #expect(model.usageContextFile?.id == Self.zeta)
      model.openUsageContextFile()
      await until { model.usagePage == .files && model.rows.first?.usage == .line(2) }
      #expect(model.usageSelectedFileID == Self.zeta)
      #expect(model.selectedIDs.isEmpty)
    }
  }

  @Test("The divider keeps the list between 180 and 420")
  func dividerBounds() {
    #expect(UsageListDivider.clamped(100) == DesignMetrics.usageRevision.listMinWidth)
    #expect(UsageListDivider.clamped(300) == 300)
    #expect(UsageListDivider.clamped(900) == DesignMetrics.usageRevision.listMaxWidth)
  }
}
