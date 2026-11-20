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
    subcommands: [TagAddCommand.self, TagRemoveCommand.self]
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
