import CatalogCore
import Foundation
import GRDB
import Testing

/// `pinax tag ls` and `pinax label ls`, run as the built binary: counts are
/// of active assets, and a name only archived assets carry is not listed.
@Suite struct SummaryCommandTests {
  private func withFixture(_ body: (URL) throws -> Void) throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", tag: "zoo")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", tag: "zoo")
    try seedAsset(database, index: 2, uploadedAt: "2026-08-03T00:00:00Z", tag: "cats")
    try seedAsset(database, index: 3, uploadedAt: "2026-08-04T00:00:00Z", tag: "gone")
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE asset SET state = 'archived' WHERE id = 4;
          INSERT INTO asset_label (asset_id, label)
          VALUES (1, 'blue'), (2, 'blue'), (3, 'red'), (4, 'red'), (4, 'gray');
          """)
    }
    try body(directory)
  }

  private func output(_ arguments: [String], in directory: URL) throws -> String {
    let result = try CLIProcess.run(arguments, in: directory)
    #expect(result.status == 0, "\(result.stderr)")
    #expect(result.stderr.isEmpty)
    return result.stdout
  }

  private func document(_ arguments: [String], in directory: URL) throws -> NSDictionary {
    let text = try output(arguments + ["--format", "json"], in: directory)
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
  }

  @Test("tag ls, by name")
  func tags() throws {
    try withFixture { directory in
      try #expect(output(["tag", "ls"], in: directory) == "NAME\tCOUNT\ncats\t1\nzoo\t2\n")
      let expected: [String: Any] = [
        "schema": "pinax.tags.v1",
        "tags": [["name": "cats", "count": 1], ["name": "zoo", "count": 2]] as [[String: Any]],
      ]
      try #expect(document(["tag", "ls"], in: directory) == expected as NSDictionary)
    }
  }

  @Test("label ls, in Finder's order")
  func labels() throws {
    try withFixture { directory in
      try #expect(output(["label", "ls"], in: directory) == "NAME\tCOUNT\nred\t1\nblue\t2\n")
      let expected: [String: Any] = [
        "schema": "pinax.labels.v1",
        "labels": [["name": "red", "count": 1], ["name": "blue", "count": 2]] as [[String: Any]],
      ]
      try #expect(document(["label", "ls"], in: directory) == expected as NSDictionary)
    }
  }
}
