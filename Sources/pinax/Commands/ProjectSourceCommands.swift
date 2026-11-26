import ArgumentParser
import CatalogCore
import Foundation

/// `pinax project source ls|add|set|rm`. Each command's
/// `output(in:)` is what `run()` prints, so tests drive the parsed command
/// against a temporary catalog.
struct ProjectSourceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "source",
    abstract: "Manage the folders and commands a project's usage scan reads.",
    subcommands: [
      ProjectSourceList.self, ProjectSourceAdd.self, ProjectSourceSet.self,
      ProjectSourceRemove.self,
    ]
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
      return sources.map { sourceRow($0) + "\n" }.joined()
    }
  }
}

/// One source as the `source ls` table prints it.
func sourceRow(_ source: ProjectSource) -> String {
  let isCommand = source.kind == .command
  let include = isCommand ? "-" : source.effectiveInclude.joined(separator: " ")
  let exclude = source.exclude.isEmpty ? "-" : source.exclude.joined(separator: " ")
  return [source.label, source.directory, include, exclude, source.kind.rawValue]
    .joined(separator: "\t")
}

/// A folder argument as stored: ~ expanded, and an absolute path
/// standardized. A relative path is left for the catalog to refuse.
private func normalizedFolder(_ argument: String) -> String {
  let expanded = (argument as NSString).expandingTildeInPath
  return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded).standardizedFileURL.path : expanded
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
    let standardized = normalizedFolder(workingDirectory ?? path ?? "")
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

struct ProjectSourceSet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract: "Change one source in place, keeping its label, its position and every field not given."
  )

  @Argument var slug: String
  @Argument var label: String
  @Option(help: "A folder source's new folder; ~ is expanded.")
  var path: String?
  @Option(help: "Replaces a folder source's include patterns; repeat for more than one.")
  var include: [String] = []
  @Option(help: "Replaces a folder source's exclude patterns; repeat for more than one.")
  var exclude: [String] = []
  @Flag(help: "Go back to the default include patterns.")
  var clearInclude = false
  @Flag(help: "Remove every exclude pattern.")
  var clearExclude = false
  @Option(help: "A command source's new shell command.")
  var command: String?
  @Option(name: .customLong("in"), help: "The folder a command source runs in; ~ is expanded.")
  var workingDirectory: String?

  private var changesFolder: Bool {
    path != nil || !include.isEmpty || !exclude.isEmpty || clearInclude || clearExclude
  }

  private var changesCommand: Bool {
    command != nil || workingDirectory != nil
  }

  func validate() throws {
    guard changesFolder || changesCommand else {
      throw ValidationError("Give something to change.")
    }
    if !include.isEmpty, clearInclude {
      throw ValidationError("Give --include or --clear-include, not both.")
    }
    if !exclude.isEmpty, clearExclude {
      throw ValidationError("Give --exclude or --clear-exclude, not both.")
    }
  }

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()))
  }

  /// Changes the source and returns its label. Which options apply depends
  /// on the source's kind, so a wrong one is refused here.
  func output(in database: CatalogDatabasePool) throws -> String {
    var sources = try CatalogConfiguration.projectSettings(slug: slug, in: database).sources
    guard let index = sources.firstIndex(where: { $0.label == label }) else {
      throw CatalogConfigurationError.sourceNotFound(project: slug, label: label)
    }
    var source = sources[index]
    switch source.kind {
    case .folder:
      if changesCommand {
        throw ValidationError(
          "Source '\(label)' is a folder source; --command and --in apply to a command source.")
      }
      if let path { source.path = normalizedFolder(path) }
      if !include.isEmpty {
        let patterns = trimmedPatterns(include)
        // The default is stored as empty, as the app stores it.
        source.include = patterns == ProjectSource.defaultInclude ? [] : patterns
      }
      if !exclude.isEmpty { source.exclude = trimmedPatterns(exclude) }
      if clearInclude { source.include = [] }
      if clearExclude { source.exclude = [] }
    case .command:
      if changesFolder {
        throw ValidationError(
          "Source '\(label)' is a command source; --path, --include, --exclude, --clear-include "
            + "and --clear-exclude apply to a folder source.")
      }
      if let command { source.command = command }
      if let workingDirectory { source.workingDirectory = normalizedFolder(workingDirectory) }
    }
    sources[index] = source
    try CatalogConfiguration.setProjectSources(slug: slug, sources, in: database)
    return label
  }

  private func trimmedPatterns(_ patterns: [String]) -> [String] {
    patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
