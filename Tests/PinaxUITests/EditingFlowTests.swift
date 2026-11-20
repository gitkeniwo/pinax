import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing

@MainActor
@Suite struct EditingFlowTests {
  private func makeModel(_ database: DatabasePool, editable: Bool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: editable ? EditableCatalog(database: database) : nil,
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-edit-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  @Test("Adding and removing tags through the model updates details and sidebar counts")
  func tagEditing() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
      let model = makeModel(database, editable: true)
      await model.loadInitialData()

      guard let row = model.rows.first else {
        Issue.record("no rows")
        return
      }
      model.select(row)
      await waitForDetails(model)
      #expect(model.selectedDetails?.tags.isEmpty == true)

      await model.addTag("hero")
      #expect(model.selectedDetails?.tags == ["hero"])
      #expect(model.tags.map(\.name) == ["hero"])
      #expect(model.tags.first?.assetCount == 1)

      await model.addTag("hero")
      #expect(model.selectedDetails?.tags == ["hero"])

      await model.removeTag("hero")
      #expect(model.selectedDetails?.tags.isEmpty == true)
      #expect(model.tags.isEmpty)
    }
  }

  @Test("saveNote persists the draft; whitespace clears the note")
  func noteEditing() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
      let model = makeModel(database, editable: true)
      await model.loadInitialData()
      guard let row = model.rows.first else {
        Issue.record("no rows")
        return
      }
      model.select(row)
      await waitForDetails(model)

      model.noteDraft = "hero shot for the blog post"
      await model.saveNote()
      #expect(model.selectedDetails?.item.asset.note == "hero shot for the blog post")

      model.noteDraft = "   "
      await model.saveNote()
      #expect(model.selectedDetails?.item.asset.note == nil)
    }
  }

  @Test("Project membership toggles update details, sidebar counts, and scoped months")
  func membershipEditing() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", projectSlug: nil)
      let model = makeModel(database, editable: true)
      await model.loadInitialData()
      guard let row = model.rows.first else {
        Issue.record("no rows")
        return
      }
      model.select(row)
      await waitForDetails(model)

      #expect(model.selectedDetails?.projects.isEmpty == true)

      await model.setProjectMembership(true, slug: "blog")
      #expect(model.selectedDetails?.projects.map(\.slug) == ["blog"])
      let blog = try #require(model.projects.first(where: { $0.slug == "blog" }))
      #expect(blog.assetCount == 1)

      await model.setProjectMembership(false, slug: "blog")
      #expect(model.selectedDetails?.projects.isEmpty == true)

      var query = AssetQuery()
      query.project = "blog"
      let months = try await CatalogAssets.availableMonths(in: database, matching: query)
      #expect(months.isEmpty)
    }
  }

  @Test("Inspector live usage is per asset, not the project-wide summary")
  func perAssetLiveUsage() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
      try seedAsset(database, index: 1, uploadedAt: "2026-08-20T12:30:00Z")
      let referencedSHA = String(format: "%064x", 1)
      try seedLiveUsage(database, projectSlug: "blog", sha256: referencedSHA, count: 2)

      let model = makeModel(database, editable: true)
      await model.loadInitialData()

      // The sidebar summary counts the whole project; the inspector's labels and
      // unlink guard must instead read the per-asset counts in selectedDetails.
      let blog = try #require(model.projects.first(where: { $0.slug == "blog" }))
      #expect(blog.liveUsageCount == 2)

      guard
        let referenced = model.rows.first(where: { $0.item.asset.sha256 == referencedSHA }),
        let unreferenced = model.rows.first(where: { $0.item.asset.sha256 != referencedSHA })
      else {
        Issue.record("seeded rows missing")
        return
      }

      model.select(referenced)
      await waitForDetails(model, expectingKey: referencedSHA)
      #expect(model.selectedDetails?.projects.first?.liveUsageCount == 2)

      model.select(unreferenced)
      await waitForDetails(model, expectingKey: unreferenced.item.asset.sha256)
      #expect(model.selectedDetails?.projects.first?.liveUsageCount == 0)
    }
  }

  @Test("Without an editor, edit calls are inert no-ops")
  func readOnlyModeIsInert() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
      let model = makeModel(database, editable: false)
      await model.loadInitialData()
      guard let row = model.rows.first else {
        Issue.record("no rows")
        return
      }
      model.select(row)
      await waitForDetails(model)

      await model.addTag("should-not-stick")
      #expect(model.selectedDetails?.tags.isEmpty == true)
      #expect(model.editor == nil)
    }
  }

  @Test("An unrelated edit does not clobber an in-progress note draft")
  func noteDraftSurvivesUnrelatedEdits() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", tag: "hero")
      let model = makeModel(database, editable: true)
      await model.loadInitialData()
      guard let row = model.rows.first else {
        Issue.record("no rows")
        return
      }
      model.select(row)
      await waitForDetails(model)

      model.noteDraft = "half-written caption…"
      await model.removeTag("hero")

      #expect(model.selectedDetails?.tags.isEmpty == true)
      #expect(model.noteDraft == "half-written caption…")

      // Selecting a different asset still refreshes the draft from storage.
      try seedAsset(database, index: 1, uploadedAt: "2026-08-21T12:00:00Z")
      await model.reload()
      if let other = model.rows.first(where: { $0.id != row.id }) {
        let otherSHA = other.item.asset.sha256
        model.select(other)
        await waitForDetails(model, expectingKey: otherSHA)
        #expect(model.noteDraft == "")
      } else {
        Issue.record("second row missing")
      }
    }
  }

  @Test("Rapid successive edits are serialised, not dropped")
  func concurrentEditsAreSerialised() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z", projectSlug: nil)
      let model = makeModel(database, editable: true)
      await model.loadInitialData()
      guard let row = model.rows.first else {
        Issue.record("no rows")
        return
      }
      model.select(row)
      await waitForDetails(model)

      async let first: Void = model.setProjectMembership(true, slug: "blog")
      async let second: Void = model.setProjectMembership(true, slug: "notes")
      _ = await (first, second)

      let slugs = model.selectedDetails?.projects.map(\.slug) ?? []
      #expect(Set(slugs) == Set(["blog", "notes"]))
    }
  }

  private func waitForDetails(_ model: GalleryModel, expectingKey key: String? = nil) async {
    for _ in 0..<50 {
      if let details = model.selectedDetails,
        key == nil || details.item.asset.sha256 == key
      {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func withTempDatabase(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(database)
  }
}
