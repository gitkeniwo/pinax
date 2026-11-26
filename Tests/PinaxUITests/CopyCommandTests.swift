import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `url`, and `--template` on `url`, `ls` and `upload`, run as the built
/// binary. asset-0 and asset-1 are members of `blog`, asset-0 of `notes` too.
@Suite struct CopyCommandTests {
  private let first = "blog/asset-0.png"
  private let second = "blog/asset-1.png"
  private let firstURL = "https://img.example.com/blog/asset-0.png"
  private let secondURL = "https://img.example.com/blog/asset-1.png"

  private func withFixture(_ body: (DatabasePool, URL) throws -> Void) throws {
    let (database, directory) = try makeCLITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CatalogAssets.addToProject("notes", identifier: first, in: database)
    try body(database, directory)
  }

  private func expectOutput(
    _ arguments: [String], _ lines: [String], in directory: URL,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let result = try CLIProcess.run(arguments, in: directory)
    #expect(result.status == 0, "\(result.stderr)", sourceLocation: sourceLocation)
    #expect(
      result.stdout == lines.map { $0 + "\n" }.joined(), "\(arguments)",
      sourceLocation: sourceLocation)
  }

  private func expectFailure(
    _ arguments: [String], status: Int32, _ messages: [String], in directory: URL,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let result = try CLIProcess.run(arguments, in: directory)
    #expect(result.status == status, "\(result.stderr)", sourceLocation: sourceLocation)
    #expect(result.stdout.isEmpty, "\(arguments)", sourceLocation: sourceLocation)
    for message in messages {
      #expect(
        result.stderr.contains(message), "\(result.stderr)", sourceLocation: sourceLocation)
    }
  }

  @Test("url prints one line per asset, in the order named, each asset once")
  func severalIdentifiers() throws {
    try withFixture { _, directory in
      try expectOutput(["url", first], [firstURL], in: directory)
      try expectOutput(["url", second, first, second], [secondURL, firstURL], in: directory)
    }
  }

  @Test("url prints nothing when any identifier is bad, and names every bad one")
  func badIdentifiers() throws {
    try withFixture { _, directory in
      try expectFailure(
        ["url", first, "blog/none.png", "abc", second], status: 66,
        ["blog/none.png", "'abc'"], in: directory)
      // One identifier alone fails as it always has.
      try expectFailure(["url", "deadbeef"], status: 66, ["deadbeef"], in: directory)
      try expectFailure(["url", "abc"], status: 1, ["'abc'"], in: directory)
      try expectFailure(["url"], status: 64, ["Usage"], in: directory)
    }
  }

  @Test("url --format prints the upload link forms")
  func formats() throws {
    try withFixture { database, directory in
      try database.write { db in
        try db.execute(
          sql: "UPDATE asset SET orig_filename = 'a ]\"b.png', width = 8, height = 6 WHERE id = 1")
      }
      try expectOutput(["url", first, "--format", "url"], [firstURL], in: directory)
      try expectOutput(
        ["url", first, second, "--format", "markdown"],
        ["![a \\]\"b](\(firstURL))", "![asset-1](\(secondURL))"], in: directory)
      try expectOutput(
        ["url", first, "--format", "html"],
        [#"<img src="\#(firstURL)" alt="a ]&quot;b" width="8" height="6">"#], in: directory)
      try expectFailure(["url", first, "--format", "json"], status: 64, [], in: directory)
    }
  }

  @Test("url --template fills in the asset's fields and its member projects")
  func urlTemplate() throws {
    try withFixture { database, directory in
      try database.write { db in
        try db.execute(
          sql: "UPDATE asset SET orig_filename = NULL, width = NULL, height = NULL WHERE id = 2")
      }
      try expectOutput(
        ["url", first, second, "--template", "{name}|{filename}|{width}x{height}|{key}|{project}"],
        [
          "asset-0|asset-0.png|800x600|\(first)|blog, notes",
          "asset-1|asset-1.png|x|\(second)|blog",
        ], in: directory)
    }
  }

  @Test("ls --template prints the listed assets in the listing's order, with no header")
  func listTemplate() throws {
    try withFixture { _, directory in
      try expectOutput(
        ["ls", "--sort", "uploaded", "--asc", "--limit", "2", "--template", "{key} {project}"],
        ["\(first) blog, notes", "\(second) blog"], in: directory)
      try expectOutput(["ls", "--tag", "nothing", "--template", "{url}"], [], in: directory)
    }
  }

  @Test("upload --template renders each upload; a dry run counts the project it would add")
  func uploadTemplate() throws {
    try withFixture { database, directory in
      let known = directory.appendingPathComponent("known.png")
      try Data("known bytes".utf8).write(to: known)
      let sha = try Hashing.sha256(ofFileAt: known)
      try database.write { db in
        try db.execute(sql: "UPDATE asset SET sha256 = ? WHERE id = 2", arguments: [sha])
      }
      let fresh = directory.appendingPathComponent("Fresh Shot.png")
      try Data(base64Encoded: [
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9",
        "awAAAABJRU5ErkJggg==",
      ].joined())!.write(to: fresh)

      try expectOutput(
        [
          "upload", known.path, fresh.path, "--project", "notes", "--dry-run",
          "--template", "{filename}|{width}x{height}|{project}",
        ],
        ["asset-1.png|x|blog, notes", "Fresh Shot.png|1x1|notes"], in: directory)
      try expectOutput(
        ["upload", known.path, "--dry-run", "--template", "{project}"], ["blog"], in: directory)
    }
  }

  @Test(
    "--template refuses --format and unknown placeholders",
    arguments: [["url", "blog/asset-0.png"], ["ls"], ["upload", "x.png", "--dry-run"]])
  func refusals(command: [String]) throws {
    try withFixture { _, directory in
      try expectFailure(
        command + ["--template", "{url}", "--format", "url"], status: 64,
        ["--template and --format cannot be used together."], in: directory)
      try expectFailure(
        command + ["--template", "{url} {nmae} {Key}"], status: 64,
        ["Unknown placeholders: {nmae}, {Key}"], in: directory)
    }
  }
}
