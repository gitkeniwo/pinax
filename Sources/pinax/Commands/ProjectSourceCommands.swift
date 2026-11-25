import ArgumentParser
import CatalogCore
import Foundation

/// `pinax project source ls|add|rm`. Each command's
/// `output(in:)` is what `run()` prints, so tests drive the parsed command
/// against a temporary catalog.
struct ProjectSourceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "source",
    abstract: "Manage the folders and commands a project's usage scan reads.",
    subcommands: [ProjectSourceList.self, ProjectSourceAdd.self, ProjectSourceRemove.self]
  )
}

struct ProjectSourceList: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ls")

  @Argument var slug: String
  @Option var format: UsageOutputFormat = .table

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()), terminator: "")
  }

  /// Table: one line per source, `label⇥path⇥include⇥exclude⇥kind`, patterns
  /// separated by spaces (a pattern's own braces hold commas), `-` for none.
  /// An empty include lists the default it stands for. A command source's
  /// path is the folder its command runs in and it has no patterns; the
  /// command itself is in the JSON.
  func output(in database: CatalogDatabasePool) throws -> String {
    let sources = try CatalogConfiguration.projectSettings(slug: slug, in: database).sources
    switch format {
    case .json:
      return try encodedJSON(sources) + "\n"
    case .table:
      return sources.map { source in
        let isCommand = source.kind == .command
        let include = isCommand ? "-" : source.effectiveInclude.joined(separator: " ")
        let exclude = source.exclude.isEmpty ? "-" : source.exclude.joined(separator: " ")
        return [source.label, source.directory, include, exclude, source.kind.rawValue]
          .joined(separator: "\t") + "\n"
      }.joined()
    }
  }
}

struct ProjectSourceAdd: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add")

  @Argument var slug: String
  @Argument(help: "An absolute folder path; ~ is expanded. Leave out with --command.")
  var path: String?
  @Option(help: "A shell command whose output lists references, instead of a folder.")
  var command: String?
  @Option(name: .customLong("in"), help: "The folder --command runs in; ~ is expanded.")
  var workingDirectory: String?
  @Option var label: String?
  @Option var include: [String] = []
  @Option var exclude: [String] = []

  func validate() throws {
    guard (path == nil) != (command == nil) else {
      throw ValidationError("Give a folder path or --command, not both.")
    }
    guard (command == nil) == (workingDirectory == nil) else {
      throw ValidationError("Give --command and --in together.")
    }
    if command != nil, !include.isEmpty || !exclude.isEmpty {
      throw ValidationError("--include and --exclude only apply to a folder.")
    }
  }

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()))
  }

  /// Appends the source and returns its label.
  func output(in database: CatalogDatabasePool) throws -> String {
    let expanded = ((workingDirectory ?? path ?? "") as NSString).expandingTildeInPath
    let standardized =
      expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded).standardizedFileURL.path : expanded
    var sources = try CatalogConfiguration.projectSettings(slug: slug, in: database).sources
    let label =
      label
      ?? ProjectSource.defaultLabel(forPath: standardized, existing: sources.map(\.label))
    sources.append(
      command.map {
        ProjectSource(label: label, command: $0, workingDirectory: standardized)
      } ?? ProjectSource(label: label, path: standardized, include: include, exclude: exclude))
    try CatalogConfiguration.setProjectSources(slug: slug, sources, in: database)
    return label
  }
}

struct ProjectSourceRemove: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "rm")

  @Argument var slug: String
  @Argument var label: String

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()))
  }

  /// Removes the source and returns its label.
  func output(in database: CatalogDatabasePool) throws -> String {
    var sources = try CatalogConfiguration.projectSettings(slug: slug, in: database).sources
    guard let index = sources.firstIndex(where: { $0.label == label }) else {
      throw CatalogConfigurationError.sourceNotFound(project: slug, label: label)
    }
    sources.remove(at: index)
    try CatalogConfiguration.setProjectSources(slug: slug, sources, in: database)
    return label
  }
}
