import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing

/// The Projects settings pane's model. The property that matters here is
/// that displaying never writes, not "the rows appear": *displaying* the pane —
/// constructing it, loading its snapshot, loading it again — must leave the
/// catalog byte-identical, and every mutation must be traceable to an
/// explicit commit through `CatalogConfiguration`.
@MainActor
@Suite struct ProjectSettingsModelTests {

  @Test("The snapshot resolves backend slugs and marks inherit as nil")
  func snapshotResolvesBackendSlugs() throws {
    try withSettingsDatabase { database in
      let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
      model.load()

      let snapshot = try #require(model.snapshot)
      #expect(snapshot.rows.map(\.slug) == ["blog", "notes"])
      #expect(snapshot.rows.map(\.backendSlug) == ["r2", "r2"])
      #expect(snapshot.backendSlugs == ["r2"])
      #expect(model.saveError == nil)
    }
  }

  /// Display never writes, as a testable property: two full `load()`s — the pane
  /// being opened and refreshed — leave every `project` and `backend` row
  /// byte-identical, `updated_at` included. A settings pane that mutated as
  /// a side effect of display would fail exactly here — provided the dump
  /// actually carries whole rows, which its sibling test below proves.
  @Test("Displaying the pane mutates nothing")
  func displayingMutatesNothing() throws {
    try withSettingsDatabase { database in
      let before = try tableDump(database)

      let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
      model.load()
      model.load()

      #expect(model.snapshot != nil)
      #expect(try tableDump(database) == before)
    }
  }

  /// The instrument of `displayingMutatesNothing`, proved against itself:
  /// an earlier dump used `String.fetchAll`, which reads only each
  /// row's **first column** — a display path that renamed every project and
  /// rewrote every `updated_at` passed it. The dump must carry real column
  /// values, and a real write through the store seam must move it.
  @Test("The full-row dump detects a display-time write")
  func fullRowDumpDetectsAMutatingDisplay() throws {
    try withSettingsDatabase { database in
      let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
      model.load()
      let before = try tableDump(database)

      // Not a list of ids: names, slugs, and prefixes are all in there.
      #expect(before.contains("Blog"))
      #expect(before.contains("notes"))

      // A write made as if display had mutated the row — the exact shape
      // `displayingMutatesNothing` stands guard against.
      try CatalogProjectSettingsStore(database: database).setKeyPrefix(
        "hijacked", projectSlug: "blog")

      let after = try tableDump(database)
      #expect(after != before)
      #expect(after.contains("hijacked"))
    }
  }

  @Test("Committing a key prefix writes through setProject and normalizes")
  func keyPrefixCommitWritesThrough() throws {
    try withSettingsDatabase { database in
      let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
      model.load()

      model.setKeyPrefix("/drafts//published/", forProject: "blog")

      #expect(model.saveError == nil)
      let row = try #require(model.snapshot?.rows.first { $0.slug == "blog" })
      #expect(row.keyPrefix == "drafts/published")
      // The stored row, read straight through CatalogConfiguration, matches
      // what the pane now shows — the pane adds no interpretation of its own.
      let stored = try #require(CatalogConfiguration.projects(in: database).first { $0.slug == "blog" })
      #expect(stored.keyPrefix == "drafts/published")
      // The other project is untouched by the commit.
      let notes = try #require(CatalogConfiguration.projects(in: database).first { $0.slug == "notes" })
      #expect(notes.keyPrefix == "notes")
    }
  }

  /// The picker's "inherit / none" choice must write a real NULL, not merely
  /// stop resolving: `setProject`'s nil backendSlug means "unchanged", so the
  /// store routes nil through `clearProjectBackend`.
  @Test("Choosing inherit writes NULL, choosing a backend writes the id")
  func backendCommitsRoundTrip() throws {
    try withSettingsDatabase { database in
      let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
      model.load()

      model.setBackend(slug: nil, forProject: "blog")
      #expect(model.saveError == nil)
      var stored = try #require(CatalogConfiguration.projects(in: database).first { $0.slug == "blog" })
      #expect(stored.backendID == nil)
      #expect(model.snapshot?.rows.first { $0.slug == "blog" }?.backendSlug == nil)

      model.setBackend(slug: "r2", forProject: "blog")
      stored = try #require(CatalogConfiguration.projects(in: database).first { $0.slug == "blog" })
      #expect(stored.backendID == 1)
      #expect(model.snapshot?.rows.first { $0.slug == "blog" }?.backendSlug == "r2")
    }
  }

  @Test("A failed commit surfaces its error and leaves the snapshot consistent")
  func failedCommitSurfacesError() throws {
    try withSettingsDatabase { database in
      let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
      model.load()
      let before = model.snapshot

      model.setBackend(slug: "ghost", forProject: "blog")

      #expect(model.saveError == "Backend 'ghost' does not exist.")
      // The pane keeps showing the last good read; the row never entered a
      // half-written state.
      #expect(model.snapshot == before)

      // A later valid commit clears the error.
      model.setKeyPrefix("published", forProject: "blog")
      #expect(model.saveError == nil)
    }
  }

  /// Associated values on an arbitrary
  /// Error are private implementation data, not user-facing prose.
  @Test("Error presentation never reflects sensitive associated values")
  func errorPresentationDoesNotReflectAssociatedValues() {
    let model = ProjectSettingsModel(store: SecretFailingSettingsStore())

    model.load()

    #expect(model.saveError != nil)
    #expect(model.saveError?.contains("SHOULD-NOT-APPEAR") == false)
  }

  @Test("Cancelling project addition writes nothing; submitting re-reads the normalized row")
  func projectAdditionCancelAndCommit() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CatalogProjectSettingsStore(database: database)
    let model = ProjectSettingsModel(store: store)
    model.load()
    let before = try #require(model.snapshot)

    model.beginAddition()
    model.updateAdditionDraft {
      $0.slug = "docs"
      $0.name = "Docs"
      $0.keyPrefix = "/drafts//published/"
      $0.backendSlug = "r2"
    }
    model.cancelAddition()

    #expect(try store.snapshot() == before)
    #expect(model.additionDraft == nil)

    model.beginAddition()
    model.updateAdditionDraft {
      $0.slug = "docs"
      $0.name = "Docs"
      $0.keyPrefix = "/drafts//published/"
      $0.backendSlug = "r2"
    }
    await model.submitAddition()

    let displayed = try #require(model.snapshot?.rows.first { $0.slug == "docs" })
    #expect(displayed.keyPrefix == "drafts/published")
    let stored = try #require(
      CatalogConfiguration.projects(in: database).first { $0.slug == "docs" })
    #expect(stored.keyPrefix == "drafts/published")
    #expect(model.additionDraft == nil)
    #expect(model.saveError == nil)
  }

  @Test("Project addition is unavailable and explained when there is no backend")
  func projectAdditionRequiresBackend() throws {
    try withSettingsDatabase { database in
      try database.write { db in
        try db.execute(sql: "DELETE FROM project")
        try db.execute(sql: "DELETE FROM backend")
      }
      let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
      model.load()

      #expect(!model.canBeginAddition)
      model.beginAddition()
      #expect(model.additionDraft == nil)
      #expect(ProjectSettingsModel.backendRequiredMessage.contains("Add a backend"))
    }
  }

  // MARK: - Helpers

  private func withSettingsDatabase(
    _ body: (DatabasePool) throws -> Void
  ) throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(database)
  }

  /// Every column of `project` and `backend`, in storage order. `Row`'s
  /// description renders the whole row; scalar `fetchAll` would read only
  /// the first column, which is how a bad write once got past the dump.
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

private struct SecretFailingSettingsStore: ProjectSettingsStore {
  struct SecretError: Error {
    let secret: String
  }

  func snapshot() throws -> ProjectSettingsSnapshot {
    throw SecretError(secret: "SHOULD-NOT-APPEAR")
  }

  func setKeyPrefix(_ keyPrefix: String, projectSlug: String) throws {}
  func setKeyTemplate(_ change: KeyTemplateChange, projectSlug: String) throws {}
  func setBackend(slug: String?, projectSlug: String) throws {}
  func setSources(_ sources: [ProjectSource], projectSlug: String) throws {}
  func setUsageTracking(_ tracking: UsageTracking, projectSlug: String) throws {}
  func setAutoScan(_ autoScan: ProjectAutoScan, projectSlug: String) throws {}
  func addProject(_ draft: NewProjectDraft) async throws -> ProjectSettingsSnapshot {
    throw SecretError(secret: "SHOULD-NOT-APPEAR")
  }
}
