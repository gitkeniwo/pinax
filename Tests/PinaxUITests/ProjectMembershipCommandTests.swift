import CatalogCore
import Foundation
import GRDB
import PinaxUI
import Testing
@testable import pinax

/// Two assets in `blog`, whose latest scan references the first twice;
/// `notes` is empty.
private func withReferencedAsset(
  _ body: (DatabasePool, URL, [String]) async throws -> Void
) async throws {
  let (database, directory) = try makeUITestDatabase()
  defer { try? FileManager.default.removeItem(at: directory) }
  for index in 0..<2 {
    try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
  }
  try seedLiveUsage(database, projectSlug: "blog", sha256: String(format: "%064x", 1), count: 2)
  try await body(database, directory, ["blog/asset-0.png", "blog/asset-1.png"])
}

/// The projects the gallery's inspector shows each asset as belonging to,
/// leaving out one it lists only for its references.
private func memberships(_ database: DatabasePool, _ keys: [String]) async throws -> [[String]] {
  try await database.read { db in
    try keys.map { key in
      try String.fetchAll(
        db,
        sql: """
          SELECT p.slug FROM asset_project ap
          JOIN project p ON p.id = ap.project_id JOIN asset a ON a.id = ap.asset_id
          WHERE a.key = ? ORDER BY p.slug
          """,
        arguments: [key])
    }
  }
}

@Suite struct ProjectMembershipCommandTests {
  @Test("link adds membership the gallery sees, and re-linking is unchanged")
  func link() async throws {
    try await withReferencedAsset { database, directory, keys in
      let linked = try CLIProcess.run(["project", "link", "notes"] + keys, in: directory)
      #expect(linked.status == 0)
      #expect(linked.stdout.contains("blog/asset-1.png\tblog\tblog,notes\tchanged"))
      #expect(try await memberships(database, keys) == [["blog", "notes"], ["blog", "notes"]])
      let details = try await ReadOnlyCatalog(database: database).details(keys[1])
      #expect(details.projects.map(\.slug) == ["blog", "notes"])

      let again = try CLIProcess.run(["project", "link", "notes", keys[0]], in: directory)
      #expect(again.status == 0)
      #expect(again.stdout.contains("\tblog,notes\tblog,notes\tunchanged"))
    }
  }

  @Test("unlink of a referenced asset is refused whole with 77, until --confirm")
  func unlink() async throws {
    try await withReferencedAsset { database, directory, keys in
      let rows = try await curationRows(database)
      for flags in [[], ["--dry-run"]] {
        let refused = try CLIProcess.run(
          ["project", "unlink", "blog"] + keys + flags, in: directory)
        #expect(refused.status == 77, "\(flags)")
        #expect(refused.stdout == "", "\(flags)")
        #expect(refused.stderr.hasPrefix("Error: Project 'blog' still references"), "\(flags)")
        #expect(
          refused.stderr.contains("  000000000000  blog/asset-0.png  2 live references"),
          "\(flags)")
        #expect(!refused.stderr.contains("asset-1"), "\(flags)")
      }
      #expect(try await curationRows(database) == rows)

      // An unreferenced asset needs no flag.
      #expect(try CLIProcess.run(["project", "unlink", "blog", keys[1]], in: directory).status == 0)
      #expect(try await memberships(database, keys) == [["blog"], []])

      let confirmed = try CLIProcess.run(
        ["project", "unlink", "blog"] + keys + ["--confirm"], in: directory)
      #expect(confirmed.status == 0)
      #expect(confirmed.stdout.contains("blog/asset-0.png\tblog\t-\tchanged"))
      #expect(confirmed.stdout.contains("blog/asset-1.png\t-\t-\tunchanged"))
      #expect(try await memberships(database, keys) == [[], []])
    }
  }

  @Test("move is refused whole for a referenced asset, until --confirm")
  func move() async throws {
    try await withReferencedAsset { database, directory, keys in
      let command = ["project", "move"] + keys + ["--from", "blog", "--to", "notes"]
      let rows = try await curationRows(database)
      let refused = try CLIProcess.run(command, in: directory)
      #expect(refused.status == 77)
      #expect(refused.stderr.contains("blog/asset-0.png  2 live references"))
      #expect(try await curationRows(database) == rows)

      let moved = try CLIProcess.run(command + ["--confirm", "--format", "json"], in: directory)
      #expect(moved.status == 0)
      #expect(moved.stdout.contains("\"action\" : \"project.move\""))
      #expect(try await memberships(database, keys) == [["notes"], ["notes"]])

      // Back again through the gallery's one-asset write.
      try await UploadCatalog(database: database).moveAsset(
        sha256: String(format: "%064x", 2), fromProject: "notes", toProject: "blog")
      #expect(try await memberships(database, keys) == [["notes"], ["blog"]])
    }
  }

  @Test("--dry-run of link, unlink and move writes nothing")
  func dryRun() async throws {
    try await withReferencedAsset { database, directory, keys in
      let rows = try await curationRows(database)
      let stamp = try await CatalogAssets.changeStamp(in: database)
      let cases: [([String], String)] = [
        (["project", "link", "notes"] + keys, "\tblog\tblog,notes\tchanged"),
        (["project", "unlink", "blog", "--confirm"] + keys, "\tblog\t-\tchanged"),
        (
          ["project", "move", "--from", "blog", "--to", "notes", "--confirm"] + keys,
          "\tblog\tnotes\tchanged"
        ),
      ]
      for (command, row) in cases {
        let result = try CLIProcess.run(command + ["--dry-run"], in: directory)
        #expect(result.status == 0, "\(command)")
        #expect(result.stdout.contains(row), "\(command)")
      }
      #expect(try await curationRows(database) == rows)
      #expect(try await CatalogAssets.changeStamp(in: database) == stamp)
    }
  }

  @Test("Bad identifiers and missing projects write nothing and exit 66")
  func notFound() async throws {
    try await withReferencedAsset { database, directory, keys in
      let rows = try await curationRows(database)
      let commands = [
        ["project", "link", "notes", keys[0], "abcdef", "fedcba"],
        ["project", "unlink", "blog", keys[1], "abcdef", "fedcba"],
        ["project", "move", keys[1], "abcdef", "fedcba", "--from", "blog", "--to", "notes"],
      ]
      for command in commands {
        let result = try CLIProcess.run(command, in: directory)
        #expect(result.status == 66, "\(command)")
        #expect(
          result.stderr == "Error: No asset matches 'abcdef'.\nNo asset matches 'fedcba'.\n",
          "\(command)")
      }
      for command in [
        ["project", "link", "ghost", keys[1]],
        ["project", "move", keys[1], "--from", "blog", "--to", "ghost"],
        ["project", "move", keys[1], "--from", "ghost", "--to", "notes"],
      ] {
        let result = try CLIProcess.run(command, in: directory)
        #expect(result.status == 66, "\(command)")
        #expect(result.stderr == "Error: Project 'ghost' does not exist.\n", "\(command)")
      }
      let same = try CLIProcess.run(
        ["project", "move", keys[1], "--from", "blog", "--to", "blog"], in: directory)
      #expect(same.status == 64)
      #expect(try await curationRows(database) == rows)
    }
  }
}
