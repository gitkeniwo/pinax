import Foundation
import GRDB
@testable import CatalogCore
import PinaxUI
import Testing

/// A catalog last migrated by an older build — v1 only, as every catalog
/// made before the archive column is — must come out of the app's opener with the newest
/// schema: the app is an implicit `migrate`, like every CLI command.
@MainActor
@Suite struct AppOpenMigratesTests {
  private func makeV1Catalog() throws -> (url: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-open-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("catalog.sqlite")
    let old = try Database.open(at: url)
    try Database.migrator.migrate(old, upTo: "v1_initial")
    #expect(try old.read { try $0.tableExists("asset_label") } == false, "fixture is v1")
    return (url, directory)
  }

  @Test("The app's opener migrates a v1 catalog to the newest schema")
  func appOpenerMigrates() throws {
    let (url, directory) = try makeV1Catalog()
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try PinaxAppModel.openCatalog(at: url)
    #expect(try database.read { try $0.tableExists("asset_label") })
    let applied = try database.read { try Database.migrator.appliedMigrations($0) }
    #expect(applied == ["v1_initial", "v2_favorite_label", "v3_pending_deletion", "v4_project_key_template", "v5_run", "v6_asset_source_sha256"])
    // The query from the report: the label summaries now run.
    _ = try database.read { db in
      try Row.fetchAll(db, sql: "SELECT label, COUNT(*) FROM asset_label GROUP BY label")
    }
  }

  /// The wiring, not just the helper. `PinaxAppModel()`
  /// with no opener is what the app constructs; its default must migrate.
  /// `PINAX_DB` points every opener — the right one or a regression to a
  /// bare `Database.open()` — at a temporary v1 catalog, so the user's real
  /// catalog is never opened; the guard below refuses to start otherwise.
  @Test("PinaxAppModel's default opener migrates a v1 catalog")
  func defaultOpenerMigrates() async throws {
    let (url, directory) = try makeV1Catalog()
    defer { try? FileManager.default.removeItem(at: directory) }
    let previous = ProcessInfo.processInfo.environment["PINAX_DB"]
    setenv("PINAX_DB", url.path, 1)
    defer {
      if let previous { setenv("PINAX_DB", previous, 1) } else { unsetenv("PINAX_DB") }
    }
    try #require(DBLocation.locate().path == url.standardizedFileURL.path)
    let defaults = try #require(
      UserDefaults(suiteName: "pinaxui-open-migrates-\(UUID().uuidString)"))

    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults)
    await app.start()
    #expect(app.openError == nil)
    #expect(app.gallery != nil)

    let reopened = try Database.open(at: url)
    let applied = try await reopened.read { try Database.migrator.appliedMigrations($0) }
    #expect(applied == ["v1_initial", "v2_favorite_label", "v3_pending_deletion", "v4_project_key_template", "v5_run", "v6_asset_source_sha256"])
    #expect(try await reopened.read { try $0.tableExists("asset_label") })
  }
}
