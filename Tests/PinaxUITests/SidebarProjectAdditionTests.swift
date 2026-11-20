import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing

@MainActor
@Suite struct SidebarProjectAdditionTests {
  /// Projects live in the collections navigator; the `+` in the section
  /// header is there with them.
  private func collectionsSections(_ model: GalleryModel) -> [SidebarSection] {
    model.navigator = .collections
    return model.sidebarSections
  }

  @Test("Settings and sidebar additions present only at their initiating entry")
  func additionPresentationIsIsolatedByInitiator() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: database))
    settings.load()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(),
      projectSettings: settings)
    await model.loadInitialData()
    let before = try tableDump(database)

    let projectsSection = try #require(
      collectionsSections(model).first { $0.id == "projects" })
    #expect(projectsSection.action == .addProject)

    settings.beginAddition()
    #expect(settings.isAdditionPresented(by: .settings))
    #expect(!model.isProjectAdditionPresented)
    settings.updateAdditionDraft {
      $0.slug = "settings-cancelled"
      $0.name = "Settings Cancelled"
      $0.backendSlug = "r2"
    }
    settings.cancelAddition()
    #expect(try tableDump(database) == before)

    model.beginProjectAddition()
    #expect(model.isProjectAdditionPresented)
    #expect(!settings.isAdditionPresented(by: .settings))
    model.updateProjectAdditionDraft {
      $0.slug = "sidebar-cancelled"
      $0.name = "Sidebar Cancelled"
      $0.backendSlug = "r2"
    }
    model.cancelProjectAddition()
    #expect(try tableDump(database) == before)
  }

  @Test("Settings submission refreshes sidebar sections and selects the project")
  func settingsSubmissionRefreshesSidebarAndSelection() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: database))
    settings.load()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(),
      projectSettings: settings)
    await model.loadInitialData()

    let projectsSection = try #require(
      collectionsSections(model).first { $0.id == "projects" })
    #expect(projectsSection.action == .addProject)

    settings.beginAddition()
    settings.updateAdditionDraft {
      $0.slug = "settings-docs"
      $0.name = "Settings Docs"
      $0.keyPrefix = "settings/documentation"
      $0.backendSlug = "r2"
    }
    await settings.submitAddition()

    let refreshedSection = try #require(
      collectionsSections(model).first { $0.id == "projects" })
    #expect(
      refreshedSection.entries.contains {
        $0.selection == .project("settings-docs")
      })
    #expect(model.sidebarSelection == .project("settings-docs"))
  }

  @Test("Sidebar addition stores the selected backend, refreshes sections, and selects the project")
  func additionCommitsSelectedBackendAndRefreshesSelection() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          VALUES
            (2, 'archive', 's3', 'https://archive.example.com', 'archive', 'eu-west-1',
             'https://cdn.example.com', 'backend.archive', '{}',
             '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z')
          """)
    }

    let settings = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: database))
    settings.load()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(),
      projectSettings: settings)
    await model.loadInitialData()

    let projectsSection = try #require(
      collectionsSections(model).first { $0.id == "projects" })
    #expect(projectsSection.action == .addProject)
    #expect(model.projectAdditionAvailability == .available)

    model.beginProjectAddition()
    model.updateProjectAdditionDraft {
      $0.slug = "docs"
      $0.name = "Docs"
      $0.keyPrefix = "documentation"
      $0.backendSlug = "archive"
    }
    #expect(model.canSubmitProjectAddition)
    await model.submitProjectAddition()

    let storedProjects = try CatalogConfiguration.projects(in: database)
    #expect(storedProjects.count == 3)
    let stored = try #require(storedProjects.first { $0.slug == "docs" })
    #expect(stored.backendID == 2)
    let refreshedSection = try #require(
      collectionsSections(model).first { $0.id == "projects" })
    #expect(refreshedSection.entries.contains { $0.selection == .project("docs") })
    #expect(model.sidebarSelection == .project("docs"))
  }

  @Test("Cancelling sidebar addition leaves the full catalog rows unchanged")
  func cancellationWritesNothing() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: database))
    settings.load()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(),
      projectSettings: settings)
    await model.loadInitialData()
    let before = try tableDump(database)

    model.beginProjectAddition()
    model.updateProjectAdditionDraft {
      $0.slug = "cancelled"
      $0.name = "Cancelled"
      $0.keyPrefix = "discarded"
      $0.backendSlug = "r2"
    }
    model.cancelProjectAddition()

    #expect(model.projectAdditionDraft == nil)
    #expect(try tableDump(database) == before)
  }

  @Test("Sidebar entry explains the backend prerequisite without opening the form")
  func additionRequiresBackend() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await database.write { db in
      try db.execute(sql: "DELETE FROM project")
      try db.execute(sql: "DELETE FROM backend")
    }
    let settings = ProjectSettingsModel(
      store: CatalogProjectSettingsStore(database: database))
    settings.load()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(),
      projectSettings: settings)
    await model.loadInitialData()

    let projectsSection = try #require(
      collectionsSections(model).first { $0.id == "projects" })
    // Positive control: the model exposes the entry even in the unavailable state.
    #expect(projectsSection.action == .addProject)
    #expect(
      model.projectAdditionAvailability
        == .unavailable(ProjectSettingsModel.backendRequiredMessage))

    model.beginProjectAddition()

    #expect(model.projectAdditionDraft == nil)
    #expect(model.projectAdditionMessage == ProjectSettingsModel.backendRequiredMessage)
  }

  private func tableDump(_ database: DatabasePool) throws -> String {
    try database.read { db in
      let projects = try Row.fetchAll(db, sql: "SELECT * FROM project ORDER BY id")
        .map(\.description)
      let backends = try Row.fetchAll(db, sql: "SELECT * FROM backend ORDER BY id")
        .map(\.description)
      return "projects:\n" + projects.joined(separator: "\n")
        + "\nbackends:\n" + backends.joined(separator: "\n")
    }
  }
}
