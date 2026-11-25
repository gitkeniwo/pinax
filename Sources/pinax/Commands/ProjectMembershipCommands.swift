import ArgumentParser
import CatalogCore

// `project link`, `unlink` and `move`: which projects assets belong to.

struct ProjectLinkCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "link",
    abstract: "Add assets to a project."
  )

  @Argument(help: "The project's slug.")
  var project: String

  @OptionGroup var assets: CurationIdentifiers
  @OptionGroup var options: CurationOptions

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .link(project: project), assets.identifiers, options: options, in: openCatalogDatabase())
  }
}

struct ProjectUnlinkCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unlink",
    abstract: "Remove assets from a project."
  )

  @Argument(help: "The project's slug.")
  var project: String

  @OptionGroup var assets: CurationIdentifiers

  @Flag(name: .long, help: "Unlink even assets the project's latest scan still references.")
  var confirm = false

  @OptionGroup var options: CurationOptions

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .unlink(project: project, confirmed: confirm), assets.identifiers, options: options,
      in: openCatalogDatabase())
  }
}

struct ProjectMoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "move",
    abstract: "Move assets from one project to another."
  )

  @OptionGroup var assets: CurationIdentifiers

  @Option(name: .long, help: "The slug of the project to leave.")
  var from: String

  @Option(name: .long, help: "The slug of the project to join.")
  var to: String

  @Flag(name: .long, help: "Move even assets the old project's latest scan still references.")
  var confirm = false

  @OptionGroup var options: CurationOptions

  func validate() throws {
    guard from != to else { throw ValidationError("--from and --to name the same project.") }
  }

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .move(from: from, to: to, confirmed: confirm), assets.identifiers, options: options,
      in: openCatalogDatabase())
  }
}
