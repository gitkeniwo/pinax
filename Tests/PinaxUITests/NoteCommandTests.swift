import CatalogCore
import Foundation
import PinaxUI
import Testing
@testable import pinax

/// CLI and GUI are two front ends over
/// one note field and one CatalogAssets mutation path. The property is
/// bidirectional visibility, not merely successful command execution.
@Suite struct NoteCommandTests {
  @Test("CLI and GUI notes round-trip in both directions")
  func notesRoundTripAcrossFrontEnds() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(
      database, index: 0, uploadedAt: "2026-08-01T00:00:00Z",
      projectSlug: "blog")
    let identifier = String(format: "%064x", 1)
    let reader = ReadOnlyCatalog(database: database)
    let editor = EditableCatalog(database: database)

    try NoteCommandOperations.set("written by CLI", for: identifier, in: database)
    #expect(try await reader.details(identifier).item.asset.note == "written by CLI")

    try await editor.setNote("written by GUI", for: identifier)
    #expect(try NoteCommandOperations.show(for: identifier, in: database) == "written by GUI")

    try NoteCommandOperations.clear(for: identifier, in: database)
    #expect(try await reader.details(identifier).item.asset.note == nil)
    #expect(try NoteCommandOperations.show(for: identifier, in: database) == "")
  }
}
