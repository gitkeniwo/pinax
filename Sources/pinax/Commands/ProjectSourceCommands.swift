import ArgumentParser
import CatalogCore
import Foundation

/// `pinax project source ls|add|rm`. Each command's
/// `output(in:)` is what `run()` prints, so tests drive the parsed command
/// against a temporary catalog.
struct ProjectSourceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "source",
    abstract: "Manage the folders a project's usage scan reads.",
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

  /// Table: one line per source, `label⇥path⇥include⇥exclude`, patterns
  /// separated by spaces (a pattern's own braces hold commas), `-` for none.
  /// An empty include lists the default it stands for.
  func output(in database: CatalogDatabasePool) throws -> String {
    let sources = try CatalogConfiguration.projectSettings(slug: slug, in: database).sources
    switch format {
    case .json:
      return try encodedJSON(sources) + "\n"
    case .table:
      return sources.map { source in
        let exclude = source.exclude.isEmpty ? "-" : source.exclude.joined(separator: " ")
        return [source.label, source.path, source.effectiveInclude.joined(separator: " "), exclude]
          .joined(separator: "\t") + "\n"
      }.joined()
    }
  }
}

struct ProjectSourceAdd: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add")

  @Argument var slug: String
  @Argument(help: "An absolute folder path; ~ is expanded.") var path: String
  @Option var label: String?
  @Option var include: [String] = []
  @Option var exclude: [String] = []

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()))
  }

  /// Appends the source and returns its label.
  func output(in database: CatalogDatabasePool) throws -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let standardized =
      expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded).standardizedFileURL.path : expanded
    var sources = try CatalogConfiguration.projectSettings(slug: slug, in: database).sources
    let label =
      label
      ?? ProjectSource.defaultLabel(forPath: standardized, existing: sources.map(\.label))
    sources.append(
      ProjectSource(label: label, path: standardized, include: include, exclude: exclude))
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
