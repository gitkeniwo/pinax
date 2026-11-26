import ArgumentParser
import CatalogCore
import Foundation

struct ExportCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "export",
    abstract: "Export a project's versioned asset manifest."
  )

  @Option(name: .long)
  var project: String

  @Option(name: [.short, .long], help: "Write the manifest to a file instead of stdout.")
  var output: String?

  mutating func run() throws {
    let manifest = try CatalogManifest.export(
      project: project,
      from: openCatalogDatabase()
    )
    let json = try manifest.json() + "\n"
    if let output {
      try Data(json.utf8).write(to: URL(fileURLWithPath: output), options: .atomic)
    } else {
      print(json, terminator: "")
    }
  }
}

struct TagCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tag",
    abstract: "Manage asset tags.",
    subcommands: [TagAddCommand.self, TagRemoveCommand.self, TagListCommand.self]
  )
}

struct TagAddCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add")

  @Argument(help: "An exact asset key or an unambiguous SHA-256 prefix.")
  var identifier: String

  @Argument
  var tag: String

  mutating func run() throws {
    try CatalogAssets.addTag(tag, to: identifier, in: openCatalogDatabase())
  }
}

struct TagRemoveCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "rm")

  @Argument(help: "An exact asset key or an unambiguous SHA-256 prefix.")
  var identifier: String

  @Argument
  var tag: String

  mutating func run() throws {
    try CatalogAssets.removeTag(tag, from: identifier, in: openCatalogDatabase())
  }
}

struct TagListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls",
    abstract: "List the tags on active assets, with counts."
  )

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    let tags = try CatalogAssets.tagSummaries(in: openCatalogDatabase())
    let counts = tags.map { NameCountJSON(name: $0.name, count: $0.assetCount) }
    if format == .json {
      print(try encodedJSON(TagListDocument(tags: counts)))
      return
    }
    printNameCounts(counts)
  }
}

/// One row of `tag ls` and `label ls`.
struct NameCountJSON: Encodable {
  let name: String
  let count: Int
}

struct TagListDocument: Encodable {
  let schema = "pinax.tags.v1"
  let tags: [NameCountJSON]
}

func printNameCounts(_ rows: [NameCountJSON]) {
  print("NAME\tCOUNT")
  for row in rows {
    print("\(row.name)\t\(row.count)")
  }
}
