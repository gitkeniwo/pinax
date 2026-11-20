import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing

@MainActor
@Suite struct BackupTests {
  @Test("Production backup decodes with exact core table counts and leaves the catalog unchanged")
  func decodedCountsAndReadOnlyCatalog() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 20, uploadedAt: "2026-08-24T10:00:00Z")
    try seedAsset(database, index: 21, uploadedAt: "2026-08-24T11:00:00Z")
    let before = try catalogTableDump(database)
    let output = directory.appendingPathComponent("catalog-backup.json")
    let writer = CatalogBackupWriter(
      database: database, generatedAt: Date(timeIntervalSince1970: 1_777_000_000))
    let today = Date(timeIntervalSince1970: 1_791_331_200)  // 2026-10-07T00:00Z
    let model = BackupModel(creator: writer, today: { today }) { defaultFilename in
      #expect(defaultFilename == BackupModel.defaultFilename(for: today))
      return output
    }

    await model.create()

    let data = try Data(contentsOf: output)
    #expect(data.last == 0x0A)
    let backup = try JSONDecoder().decode(CatalogBackup.self, from: data)
    let storedCounts = try await database.read { db in
      (
        assets: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0,
        projects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") ?? 0,
        backends: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backend") ?? 0
      )
    }
    #expect(backup.tables.assets.count == storedCounts.assets)
    #expect(backup.tables.projects.count == storedCounts.projects)
    #expect(backup.tables.backends.count == storedCounts.backends)
    #expect(model.notice?.contains("\(storedCounts.assets) assets") == true)
    #expect(model.notice?.contains("\(storedCounts.projects) projects") == true)
    #expect(model.notice?.contains("\(storedCounts.backends) backends") == true)
    #expect(try catalogTableDump(database) == before)
  }

  @Test("Save Backup…'s default name carries the local date")
  func datedDefaultFilename() {
    // 2026-10-07 23:30 in Berlin is 21:30 UTC; in Tokyo it is already the 8th.
    var components = DateComponents()
    (components.year, components.month, components.day) = (2026, 10, 7)
    (components.hour, components.minute) = (21, 30)
    components.timeZone = TimeZone(identifier: "UTC")
    let date = Calendar(identifier: .gregorian).date(from: components)!
    #expect(
      BackupModel.defaultFilename(for: date, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        == "pinax-backup-2026-10-07.json")
    #expect(
      BackupModel.defaultFilename(for: date, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        == "pinax-backup-2026-10-08.json")
    #expect(
      BackupModel.defaultFilename(for: date, timeZone: TimeZone(identifier: "UTC")!)
        == "pinax-backup-2026-10-07.json")
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
