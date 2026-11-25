import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing

@testable import PinaxUI
@testable import pinax

/// Command sources and automatic scanning through the real command parser on
/// a temporary catalog. The one command that runs is a script written here.
@Suite struct CommandSourceCommandTests {
  private func parse<T: ParsableCommand>(_ arguments: [String], as: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }

  private func settings(_ database: DatabasePool) throws -> ProjectSettings {
    try CatalogConfiguration.projectSettings(slug: "blog", in: database)
  }

  @Test("source add --command stores a command source, and ls prints it both ways")
  func addAndList() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let add = try parse(
      ["project", "source", "add", "blog", "--command", "node export.mjs", "--in",
       "~/astro-blog/"],
      as: ProjectSourceAdd.self)
    #expect(try add.output(in: database) == "astro-blog")
    let folder = FileManager.default.homeDirectoryForCurrentUser.path + "/astro-blog"
    #expect(
      try settings(database).sources == [
        ProjectSource(label: "astro-blog", command: "node export.mjs", workingDirectory: folder)
      ])

    let table = try parse(["project", "source", "ls", "blog"], as: ProjectSourceList.self)
    #expect(try table.output(in: database) == "astro-blog\t\(folder)\t-\t-\tcommand\n")
    let json = try parse(
      ["project", "source", "ls", "blog", "--format", "json"], as: ProjectSourceList.self)
    #expect(
      try json.output(in: database) == """
        [
          {
            "command" : "node export.mjs",
            "kind" : "command",
            "label" : "astro-blog",
            "working_directory" : "\(folder)"
          }
        ]

        """)
  }

  @Test(
    "source add takes a folder or a command with its directory",
    arguments: [
      ["blog"], ["blog", "/a", "--command", "x", "--in", "/a"], ["blog", "--command", "x"],
      ["blog", "/a", "--in", "/a"], ["blog", "--command", "x", "--in", "/a", "--include", "*.md"],
    ])
  func addArguments(arguments: [String]) {
    #expect(throws: (any Error).self) {
      try Pinax.parseAsRoot(["project", "source", "add"] + arguments)
    }
  }

  @Test("usage scan runs commands only with --run-commands")
  func usageScan() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(
      """
      echo ran >> marker
      echo '{"schema":1,"refs":[{"raw_url":"https://img.example.com/a.png","source_ref":"p"}]}'

      """.utf8
    ).write(to: directory.appendingPathComponent("export.sh"))
    try CatalogConfiguration.setProjectSources(
      slug: "blog",
      [ProjectSource(label: "cms", command: "/bin/sh ./export.sh", workingDirectory: directory.path)],
      in: database)
    let marker = directory.appendingPathComponent("marker")

    for extra in [[], ["--dry-run"]] {
      let refused = try parse(
        ["usage", "scan", "--project", "blog"] + extra, as: UsageScanCommand.self)
      #expect(throws: RunCommandsRequired(label: "cms")) { try refused.output(in: database) }
    }
    #expect(RunCommandsRequired(label: "cms").description.contains("--run-commands"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    let allowed = try parse(
      ["usage", "scan", "--project", "blog", "--run-commands"], as: UsageScanCommand.self)
    #expect(try allowed.output(in: database).contains(": 1 refs\n0 files, 0 skipped"))
    #expect(try CatalogUsage.report(project: "blog", in: database).items.map(\.sourceReference)
      == ["cms/p"])
  }

  @Test("--run-commands on rewrite only goes with --apply")
  func rewriteFlag() throws {
    #expect(throws: (any Error).self) {
      try Pinax.parseAsRoot(
        ["rewrite", "--project", "blog", "--from-prefix", "https://a.com", "--to-prefix",
         "https://b.com", "--run-commands"])
    }
    let apply = try parse(
      ["rewrite", "--apply", "--from-run", "1", "--run-commands"], as: RewriteCommand.self)
    #expect(apply.runCommands)
  }

  @Test("project set --watch and --schedule change only what they name")
  func projectSet() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    func set(_ arguments: [String]) throws {
      _ = try parse(["project", "set", "--slug", "blog"] + arguments, as: ProjectSet.self)
        .perform(in: database)
    }
    try set(["--watch", "on"])
    #expect(try settings(database).autoScan == ProjectAutoScan(watch: true, schedule: .off))
    try set(["--schedule", "daily"])
    #expect(try settings(database).autoScan == ProjectAutoScan(watch: true, schedule: .daily))
    try set(["--watch", "off", "--schedule", "hourly", "--name", "Renamed"])
    #expect(try settings(database).autoScan == ProjectAutoScan(watch: false, schedule: .hourly))
    #expect(try CatalogConfiguration.projects(in: database).map(\.name).contains("Renamed"))
    #expect(throws: (any Error).self) { try set(["--schedule", "weekly"]) }
  }

  @Test("A command source has no file to open")
  func noFileForCommandSource() {
    let sources = [
      "blog": [ProjectSource(label: "cms", command: "x", workingDirectory: "/tmp")]
    ]
    #expect(
      UsageSourceFile.url(
        project: "blog", path: "cms/posts/hello", sources: sources, fileExists: { _ in true })
        == nil)
  }
}
