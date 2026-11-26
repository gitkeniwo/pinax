import CatalogCore
import Foundation
import GRDB
import Testing

/// `pinax show`, run as the built binary: the whole table, and the JSON
/// fields for curation and provenance.
@Suite struct AssetShowCommandTests {
  private func withFixture(_ body: (URL) throws -> Void) throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(
      database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", tag: "cats",
      meta: #"{"imported_from":"picgo"}"#)
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", projectSlug: nil)
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE asset SET favorite = 1 WHERE id = 1;
          INSERT INTO asset_label (asset_id, label) VALUES (1, 'blue'), (1, 'red');
          """)
    }
    try body(directory)
  }

  private func table(_ index: Int, in directory: URL) throws -> String {
    let result = try CLIProcess.run(["show", String(format: "%064x", index)], in: directory)
    #expect(result.status == 0, "\(result.stderr)")
    return result.stdout
  }

  @Test("favorite and labels follow pinned, labels in Finder's order")
  func tableLines() throws {
    try withFixture { directory in
      let curated = try table(1, in: directory)
      #expect(curated.contains("\npinned: false\nfavorite: true\nlabels: red,blue\nnote: \n"))
      let plain = try table(2, in: directory)
      #expect(plain.contains("\npinned: false\nfavorite: false\nlabels: \nnote: \n"))
      #expect(plain.hasSuffix("\ntags: \nprojects: none\n"))
    }
  }

  @Test("JSON has favorite, labels, and source")
  func json() throws {
    try withFixture { directory in
      func asset(_ index: Int) throws -> [String: Any] {
        let result = try CLIProcess.run(
          ["show", String(format: "%064x", index), "--format", "json"], in: directory)
        #expect(result.status == 0, "\(result.stderr)")
        let root = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return try #require((root as? [String: Any])?["asset"] as? [String: Any])
      }
      let curated = try asset(1)
      #expect(curated["favorite"] as? Bool == true)
      #expect(curated["labels"] as? [String] == ["red", "blue"])
      #expect(curated["source"] as? String == "picgo")
      let plain = try asset(2)
      #expect(plain["favorite"] as? Bool == false)
      #expect(plain["labels"] as? [String] == [])
      #expect(plain["source"] as? String == "pinax")
    }
  }
}
