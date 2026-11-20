import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// The usage and orphan surfaces. The views are thin; everything worth
/// pinning lives here — scan-health derivation, report segmentation, and the
/// gallery model's selection-driven loading.
@MainActor
@Suite struct UsageOrphanViewsTests {
  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-thumbs-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  @Test("OrphanScanHealth classifies never-scanned, under-scanned, and scanned projects")
  func scanHealthClassification() {
    let projects = [
      ProjectSummary(
        slug: "notes", name: "Notes", assetCount: 3, liveUsageCount: 0, lastScanAt: nil),
      ProjectSummary(
        slug: "blog", name: "Blog", assetCount: 5, liveUsageCount: 4,
        lastScanAt: "2026-08-20T13:00:00Z"),
      ProjectSummary(
        slug: "docs", name: "Docs", assetCount: 2, liveUsageCount: 2,
        lastScanAt: "2026-08-21T09:00:00Z"),
    ]
    let health = OrphanScanHealth.assess(
      projects: projects, underScannedSlugs: ["notes", "blog"])
    #expect(health.map(\.slug) == ["blog", "docs", "notes"])
    #expect(health[0].status == .underScanned)
    #expect(health[0].lastScanAt == "2026-08-20T13:00:00Z")
    #expect(health[1].status == .scanned)
    #expect(health[2].status == .neverScanned)
    #expect(health[2].lastScanAt == nil)
  }

  @Test("Orphan selection loads the report and derives scan health from summaries")
  func orphanSelectionLoadsReport() async throws {
    try await withTempDatabase { database in
      // Live-used, unused, and in a never-scanned project respectively.
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
      try seedAsset(database, index: 1, uploadedAt: "2026-08-20T12:01:00Z")
      try seedAsset(database, index: 2, uploadedAt: "2026-08-20T12:02:00Z", projectSlug: "notes")
      try seedLiveUsage(database, projectSlug: "blog", sha256: String(format: "%064x", 1), count: 1)

      let model = makeModel(database)
      await model.loadInitialData()
      model.sidebarSelection = .orphans
      await model.reload()

      let report = try #require(model.orphanReport)
      // The notes asset appears orphaned only because notes was never scanned —
      // exactly the false positive the caveat header must explain.
      #expect(report.assets.map(\.asset.key) == ["blog/asset-1.png", "notes/asset-2.png"])
      let statuses = Dictionary(
        uniqueKeysWithValues: model.orphanHealth.map { ($0.slug, $0.status) })
      // blog has exactly one completed scan (the minimum is two).
      #expect(statuses["blog"] == .underScanned)
      #expect(statuses["notes"] == .neverScanned)
      #expect(model.canLoadMore == false)

      model.sidebarSelection = .all
      await model.reload()
      #expect(model.orphanReport == nil)
      #expect(model.rows.count == 3)
    }
  }

  @Test("Selecting an orphan loads inspector details through the fallback path")
  func orphanSelectionDetails() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
      let model = makeModel(database)
      await model.loadInitialData()
      model.sidebarSelection = .orphans
      await model.reload()
      let report = try #require(model.orphanReport)
      #expect(report.assets.count == 1)

      let row = GalleryModel.Row(report.assets[0])
      model.select(row)
      for _ in 0..<50 where model.selectedDetails == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      let details = try #require(model.selectedDetails)
      #expect(details.item.asset.key == "blog/asset-0.png")
    }
  }

  @Test("Usage selection loads the latest scan's matched references; the external one is Externals'")
  func usageSelectionLoadsReport() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
      let document = UsageDocument(
        project: "blog",
        refs: [
          UsageReference(
            rawURL: "https://img.example.com/blog/asset-0.png", sourceReference: "posts/hello.md"),
          UsageReference(
            rawURL: "https://cdn.other.example.com/cover.png", sourceReference: "posts/hello.md"),
        ]
      )
      _ = try CatalogUsage.sync(document, project: "blog", in: database)

      let model = makeModel(database)
      await model.loadInitialData()
      model.currentProjectSlug = "blog"
      model.sidebarSelection = .usage
      await model.reload()

      let browser = try #require(model.usageBrowser)
      #expect(browser.usage.scannedProjects == ["blog"])
      #expect(browser.usage.references.count == 1)
      let matched = try #require(browser.images.first)
      #expect(browser.usage.assets[matched.assetID]?.asset.key == "blog/asset-0.png")

      // The sidebar aggregate the usage row displays agrees with the report.
      let blog = try #require(model.projects.first { $0.slug == "blog" })
      #expect(blog.liveUsageCount == 2)
    }
  }

  @Test("A never-scanned project yields an explicit unknown-usage report, not an error")
  func usageWithoutScan() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", projectSlug: "notes")
      let model = makeModel(database)
      await model.loadInitialData()
      model.currentProjectSlug = "notes"
      model.sidebarSelection = .usage
      await model.reload()

      let browser = try #require(model.usageBrowser)
      #expect(browser.usage.scannedProjects.isEmpty)
      #expect(browser.usage.references.isEmpty)
      #expect(model.errorMessage == nil)
    }
  }

  @Test("An unknown usage project surfaces the error instead of a stale report")
  func usageUnknownProject() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
      let model = makeModel(database)
      await model.loadInitialData()
      model.currentProjectSlug = "ghost"
      model.sidebarSelection = .usage
      await model.reload()

      #expect(model.errorMessage != nil)
      #expect(model.usageBrowser == nil)
    }
  }

  @Test("Externals project filtering changes the reader argument and an empty result is an empty state")
  func externalsFilteringAndEmptyState() async {
    let reader = RecordingExternalUsageReader()
    let externals = ExternalsModel(reader: reader)

    await externals.load()
    await externals.selectProject("blog")
    await externals.selectProject("notes")

    #expect(reader.calls.count == 3)
    #expect(reader.calls[0] == nil)
    #expect(reader.calls[1] == "blog")
    #expect(reader.calls[2] == "notes")
    #expect(externals.items?.isEmpty == true)
    #expect(externals.loadError == nil)
    #expect(externals.presentation == .empty)
    // The empty externals report's words come from `EmptyStates`.
    #expect(EmptyStates.text(for: .noExternalReferences).title == "No External References")
  }

  private func withTempDatabase(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(database)
  }
}

private final class RecordingExternalUsageReader: ExternalUsageReading, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCalls: [String?] = []

  var calls: [String?] {
    lock.withLock { recordedCalls }
  }

  func externalReferences(project: String?) async throws -> ExternalReferenceSet {
    lock.withLock { recordedCalls.append(project) }
    return ExternalReferenceSet(references: [], projectSources: [:])
  }
}
