import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `pinax restore` is `CatalogBackups.restore`
/// plus the two follow-ups. The credential lookup is a fake; no Keychain.
@Suite struct RestoreCommandTests {
  @Test("CLI restore fills the empty catalog and counts both follow-ups")
  func restoreCommand() throws {
    let (source, sourceDirectory) = try makeRestoreFollowUpSource()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let file = sourceDirectory.appendingPathComponent("backup.json")
    try JSONEncoder().encode(try CatalogBackups.create(from: source)).write(to: file)

    let (target, targetDirectory) = try makeEmptyRestoreTarget()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }
    var lookedUp: [String] = []
    let output = try RestoreCommandOperations.restore(
      file: file, into: target,
      credentialExists: { reference in
        lookedUp.append(reference)
        return reference == "backend.r2"
      })

    #expect(try CatalogBackups.counts(in: target) == CatalogBackups.counts(in: source))
    #expect(output.contains("asset\t3\n"))
    #expect(output.contains("project\t2\n"))
    #expect(output.contains("Backends without credentials on this Mac: 1 (b2)"))
    #expect(output.contains("Projects whose source folders are not on this Mac: 1 (notes)"))
    #expect(lookedUp.sorted() == ["backend.b2", "backend.r2"])

    // A second restore into the now-filled catalog is refused, unchanged.
    #expect(throws: CatalogRestoreError.self) {
      try RestoreCommandOperations.restore(
        file: file, into: target, credentialExists: { _ in true })
    }
    #expect(try CatalogBackups.counts(in: target) == CatalogBackups.counts(in: source))
  }
}

/// Two backends (one without credentials under the fake lookup), project
/// `blog` whose source folder exists, project `notes` whose folder does not.
func makeRestoreFollowUpSource() throws -> (database: DatabasePool, directory: URL) {
  let (database, directory) = try makeUITestDatabase()
  let present = directory.appendingPathComponent("site", isDirectory: true)
  try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
  let missing = directory.appendingPathComponent("gone", isDirectory: true).path
  for index in 0..<3 {
    try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
  }
  try database.write { db in
    try db.execute(
      sql: """
        INSERT INTO backend
          (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
           created_at, updated_at)
        VALUES
          (2, 'b2', 's3', 'https://b2.example.com', 'pics', 'auto',
           'https://pics.example.com', 'backend.b2', '{}',
           '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        UPDATE project SET meta = ? WHERE slug = 'blog';
        UPDATE project SET meta = ? WHERE slug = 'notes';
        """,
      arguments: [
        #"{"sources":[{"label":"site","path":"\#(present.path)"}]}"#,
        #"{"sources":[{"label":"gone","path":"\#(missing)"}]}"#,
      ])
  }
  return (database, directory)
}

func makeEmptyRestoreTarget() throws -> (database: DatabasePool, directory: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("pinax-restore-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  return (database, directory)
}
