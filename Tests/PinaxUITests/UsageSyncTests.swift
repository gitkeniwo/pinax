import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing

@MainActor
@Suite struct UsageSyncTests {
  @Test("Empty usage scans require confirmation, write once, and report core counts")
  func emptyScanConfirmation() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let previous = UsageDocument(
      project: "blog",
      refs: [
        UsageReference(
          rawURL: "https://img.example.com/blog/known.png",
          sourceReference: "posts/known.md")
      ])
    _ = try CatalogUsage.sync(previous, project: "blog", in: database)
    let source = directory.appendingPathComponent("empty-usage.json")
    try JSONEncoder().encode(UsageDocument(project: "blog", refs: [])).write(to: source)
    let synchronizer = CatalogUsageSynchronizer(database: database)
    let model = UsageSyncModel(synchronizer: synchronizer) { source }
    await model.loadProjects()
    model.selectedProject = "blog"
    let before = try scanCount(database)

    await model.chooseAndSync()

    #expect(model.requiresEmptyScanConfirmation)
    #expect(try scanCount(database) == before)
    #expect(model.result == nil)
    model.cancelEmptyScan()
    #expect(try scanCount(database) == before)

    await model.chooseAndSync()
    await model.confirmEmptyScan()

    let result = try #require(model.result)
    #expect(result.foundCount == 0)
    #expect(result.scanID > 0)
    #expect(try scanCount(database) == before + 1)
    let stored: Row? = try database.read { db in
      try Row.fetchOne(db, sql: "SELECT id, found_count FROM scan ORDER BY id DESC")
    }
    #expect(stored?["id"] as Int64? == result.scanID)
    #expect(stored?["found_count"] as Int? == result.foundCount)
  }

  @Test("Usage document validation errors remain specific")
  func validationErrorsRemainSpecific() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }

    let mismatch = directory.appendingPathComponent("mismatch.json")
    try JSONEncoder().encode(UsageDocument(project: "notes", refs: [])).write(to: mismatch)
    let mismatchModel = UsageSyncModel(
      synchronizer: CatalogUsageSynchronizer(database: database), chooseSource: { mismatch })
    await mismatchModel.loadProjects()
    mismatchModel.selectedProject = "blog"
    await mismatchModel.chooseAndSync()
    #expect(
      mismatchModel.errorMessage
        == UsageCatalogError.projectMismatch(expected: "blog", actual: "notes").description)

    let schema = directory.appendingPathComponent("schema.json")
    try Data(#"{"schema":2,"project":"blog","refs":[]}"#.utf8).write(to: schema)
    let schemaModel = UsageSyncModel(
      synchronizer: CatalogUsageSynchronizer(database: database), chooseSource: { schema })
    await schemaModel.loadProjects()
    schemaModel.selectedProject = "blog"
    await schemaModel.chooseAndSync()
    #expect(schemaModel.errorMessage == UsageCatalogError.unsupportedSchema(2).description)

    let invalid = directory.appendingPathComponent("invalid.json")
    try Data(#"{"schema":1,"refs":[]}"#.utf8).write(to: invalid)
    let invalidModel = UsageSyncModel(
      synchronizer: CatalogUsageSynchronizer(database: database), chooseSource: { invalid })
    await invalidModel.loadProjects()
    invalidModel.selectedProject = "blog"
    await invalidModel.chooseAndSync()
    #expect(
      invalidModel.errorMessage == UsageCatalogError.invalidDocumentField("project").description)
  }

  private func scanCount(_ database: DatabasePool) throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan") ?? 0
    }
  }
}
