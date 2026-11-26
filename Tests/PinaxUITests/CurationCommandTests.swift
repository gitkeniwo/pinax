import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing
@testable import pinax

/// Every row a curation command could touch.
func curationRows(_ database: DatabasePool) async throws -> [String] {
  try await database.read { db in
    try String.fetchAll(
      db,
      sql: """
        SELECT 'asset ' || id || ' ' || state || ' ' || favorite || ' ' || updated_at FROM asset
        UNION ALL SELECT 'label ' || asset_id || ' ' || label FROM asset_label
        UNION ALL
        SELECT 'member ' || asset_id || ' ' || project_id || ' ' || added_at FROM asset_project
        ORDER BY 1
        """)
  }
}

/// Two assets in `blog`.
private func withTwoAssets(
  _ body: (DatabasePool, URL, [String]) async throws -> Void
) async throws {
  let (database, directory) = try makeUITestDatabase()
  defer { try? FileManager.default.removeItem(at: directory) }
  for index in 0..<2 {
    try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
  }
  try await body(database, directory, ["blog/asset-0.png", "blog/asset-1.png"])
}

/// What the gallery reads back for each key.
private func galleryView(
  _ database: DatabasePool, _ keys: [String]
) async throws -> [(state: String, favorite: Bool, labels: [AssetLabel])] {
  let page = try await ReadOnlyCatalog(database: database).page(AssetQuery())
  return try keys.map { key in
    let item = try #require(page.items.first { $0.asset.key == key })
    let id = try #require(item.asset.id)
    return (item.asset.state, page.favoriteIDs.contains(id), page.labelsByAssetID[id] ?? [])
  }
}

@Suite struct CurationCommandTests {
  @Test("archive and unarchive change the state the gallery reads")
  func archiveRoundTrip() async throws {
    try await withTwoAssets { database, directory, keys in
      let archived = try CLIProcess.run(["archive"] + keys, in: directory)
      #expect(archived.status == 0)
      #expect(
        archived.stdout == """
          SHA256\tKEY\tBEFORE\tAFTER\tRESULT
          000000000000\tblog/asset-0.png\tactive\tarchived\tchanged
          000000000000\tblog/asset-1.png\tactive\tarchived\tchanged

          """)
      #expect(archived.stderr == "")
      #expect(try await galleryView(database, keys).map(\.state) == ["archived", "archived"])

      #expect(try CLIProcess.run(["unarchive", keys[0]], in: directory).status == 0)
      #expect(try await galleryView(database, keys).map(\.state) == ["active", "archived"])

      // The gallery's own write, seen by the CLI as already done.
      try await EditableCatalog(database: database).setState(.active, for: [keys[1]])
      let again = try await CurationCommandOperations.output(
        .setState(.active), keys, in: database)
      #expect(again.components(separatedBy: "\tunchanged").count == 3)
    }
  }

  @Test("favorite add and rm round-trip with the gallery")
  func favorite() async throws {
    try await withTwoAssets { database, directory, keys in
      #expect(try CLIProcess.run(["favorite", "add"] + keys, in: directory).status == 0)
      #expect(try await galleryView(database, keys).map(\.favorite) == [true, true])
      #expect(try CLIProcess.run(["favorite", "rm", keys[0]], in: directory).status == 0)
      #expect(try await galleryView(database, keys).map(\.favorite) == [false, true])

      try await EditableCatalog(database: database).setFavorite(true, for: [keys[0]])
      let again = try await CurationCommandOperations.output(
        .setFavorite(true), keys, in: database)
      #expect(again.contains("blog/asset-0.png\ttrue\ttrue\tunchanged"))
    }
  }

  @Test("label add and rm keep Finder's order and round-trip with the gallery")
  func label() async throws {
    try await withTwoAssets { database, directory, keys in
      #expect(try CLIProcess.run(["label", "add", "blue"] + keys, in: directory).status == 0)
      try await EditableCatalog(database: database).setLabel(.red, true, for: [keys[0]])
      #expect(try await galleryView(database, keys).map(\.labels) == [[.red, .blue], [.blue]])

      let removed = try CLIProcess.run(["label", "rm", "blue", keys[0]], in: directory)
      #expect(removed.stdout.contains("blog/asset-0.png\tred,blue\tred\tchanged"))
      #expect(try await galleryView(database, keys).map(\.labels) == [[.red], [.blue]])

      let unknown = try CLIProcess.run(["label", "add", "pink", keys[0]], in: directory)
      #expect(unknown.status == 64)
    }
  }

  @Test("--format json lists each asset's full state before and after")
  func json() async throws {
    try await withTwoAssets { _, directory, keys in
      let result = try CLIProcess.run(
        ["favorite", "add", keys[0], "--format", "json"], in: directory)
      #expect(result.status == 0)
      let root = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      #expect(root["schema"] as? String == "pinax.curation.v1")
      #expect(root["action"] as? String == "favorite.add")
      #expect(root["dry_run"] as? Bool == false)
      let assets = try #require(root["assets"] as? [[String: Any]])
      #expect(assets.count == 1)
      #expect(assets[0]["sha256"] as? String == String(format: "%064x", 1))
      #expect(assets[0]["key"] as? String == keys[0])
      let before = try #require(assets[0]["before"] as? [String: Any])
      let after = try #require(assets[0]["after"] as? [String: Any])
      #expect(before["favorite"] as? Bool == false)
      #expect(after["favorite"] as? Bool == true)
      #expect(after["state"] as? String == "active")
      #expect(after["labels"] as? [String] == [])
      #expect(after["projects"] as? [String] == ["blog"])
    }
  }

  @Test("--dry-run leaves every row and the change stamp alone")
  func dryRun() async throws {
    try await withTwoAssets { database, directory, keys in
      try await EditableCatalog(database: database).setLabel(.red, true, for: [keys[0]])
      let rows = try await curationRows(database)
      let stamp = try await CatalogAssets.changeStamp(in: database)
      for command in [
        ["archive"], ["unarchive"], ["favorite", "add"], ["favorite", "rm"],
        ["label", "add", "blue"], ["label", "rm", "red"],
      ] {
        let result = try CLIProcess.run(command + keys + ["--dry-run"], in: directory)
        #expect(result.status == 0, "\(command)")
        #expect(result.stderr == "Dry run: nothing was written.\n", "\(command)")
        #expect(result.stdout.hasPrefix("SHA256\tKEY\t"), "\(command)")
      }
      #expect(try await curationRows(database) == rows)
      #expect(try await CatalogAssets.changeStamp(in: database) == stamp)

      let planned = try CLIProcess.run(["archive"] + keys + ["--dry-run"], in: directory)
      #expect(planned.stdout.contains("\tactive\tarchived\tchanged"))
    }
  }

  @Test("Bad identifiers write nothing, exit 66, and are listed one per line")
  func badIdentifiers() async throws {
    try await withTwoAssets { database, directory, keys in
      let rows = try await curationRows(database)
      for command in [["archive"], ["unarchive"], ["favorite", "add"], ["label", "add", "red"]] {
        // `000000` is a prefix of both assets.
        let result = try CLIProcess.run(
          command + [keys[0], "abcdef", "000000"], in: directory)
        #expect(result.status == 66, "\(command)")
        #expect(result.stdout == "", "\(command)")
        let lines = result.stderr.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, "\(command)")
        #expect(lines.first == "Error: No asset matches 'abcdef'.", "\(command)")
        #expect(
          lines.last?.hasPrefix("Asset identifier '000000' is ambiguous:") == true, "\(command)")
      }
      #expect(try await curationRows(database) == rows)
      #expect(try CLIProcess.run(["archive"], in: directory).status == 64)
    }
  }
}
