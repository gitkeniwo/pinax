import ArgumentParser
import CatalogCore
import Foundation

// `archive`, `unarchive`, `favorite` and `label`: the gallery's curation
// writes. They change catalog rows only; nothing is asked of the object store.

/// What every curation command takes besides its identifiers.
struct CurationOptions: ParsableArguments {
  @Flag(name: .long, help: "Print what would change and write nothing.")
  var dryRun = false

  @Option(name: .long)
  var format: OutputFormat = .table
}

struct CurationIdentifiers: ParsableArguments {
  @Argument(help: "Exact asset keys or unambiguous SHA-256 prefixes.")
  var identifiers: [String]
}

struct ArchiveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "archive",
    abstract: "Archive assets. The remote objects stay."
  )

  @OptionGroup var assets: CurationIdentifiers
  @OptionGroup var options: CurationOptions

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .setState(.archived), assets.identifiers, options: options, in: openCatalogDatabase())
  }
}

struct UnarchiveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unarchive",
    abstract: "Put archived assets back."
  )

  @OptionGroup var assets: CurationIdentifiers
  @OptionGroup var options: CurationOptions

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .setState(.active), assets.identifiers, options: options, in: openCatalogDatabase())
  }
}

struct FavoriteCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "favorite",
    abstract: "Mark assets as favourites.",
    subcommands: [FavoriteAddCommand.self, FavoriteRemoveCommand.self]
  )
}

struct FavoriteAddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add", abstract: "Add assets to the favourites.")

  @OptionGroup var assets: CurationIdentifiers
  @OptionGroup var options: CurationOptions

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .setFavorite(true), assets.identifiers, options: options, in: openCatalogDatabase())
  }
}

struct FavoriteRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm", abstract: "Remove assets from the favourites.")

  @OptionGroup var assets: CurationIdentifiers
  @OptionGroup var options: CurationOptions

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .setFavorite(false), assets.identifiers, options: options, in: openCatalogDatabase())
  }
}

private let labelHelp: ArgumentHelp =
  "One of \(AssetLabel.allCases.map(\.rawValue).joined(separator: ", "))."

struct LabelAddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add", abstract: "Put a color label on assets.")

  @Argument(help: labelHelp)
  var color: AssetLabel

  @OptionGroup var assets: CurationIdentifiers
  @OptionGroup var options: CurationOptions

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .setLabel(color, true), assets.identifiers, options: options, in: openCatalogDatabase())
  }
}

struct LabelRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm", abstract: "Take a color label off assets.")

  @Argument(help: labelHelp)
  var color: AssetLabel

  @OptionGroup var assets: CurationIdentifiers
  @OptionGroup var options: CurationOptions

  mutating func run() async throws {
    try await CurationCommandOperations.run(
      .setLabel(color, false), assets.identifiers, options: options, in: openCatalogDatabase())
  }
}

/// One curation command's write, apart from its identifiers.
enum CurationAction {
  case setState(AssetState)
  case setFavorite(Bool)
  case setLabel(AssetLabel, Bool)
  case link(project: String)
  case unlink(project: String, confirmed: Bool)
  case move(from: String, to: String, confirmed: Bool)

  /// The `action` of the JSON document.
  var name: String {
    switch self {
    case let .setState(state): return state == .archived ? "archive" : "unarchive"
    case let .setFavorite(on): return on ? "favorite.add" : "favorite.rm"
    case let .setLabel(_, on): return on ? "label.add" : "label.rm"
    case .link: return "project.link"
    case .unlink: return "project.unlink"
    case .move: return "project.move"
    }
  }

  /// The part of an asset's state this action changes, as a table cell.
  func column(_ state: CurationState) -> String {
    func list(_ values: [String]) -> String {
      values.isEmpty ? "-" : values.joined(separator: ",")
    }
    switch self {
    case .setState: return state.state
    case .setFavorite: return String(state.favorite)
    case .setLabel: return list(state.labels.map(\.rawValue))
    case .link, .unlink, .move: return list(state.projects)
    }
  }
}

/// The commands' bodies, each a call to the CatalogCore function the gallery
/// uses, or to the batch form that function is built on.
enum CurationCommandOperations {
  static func apply(
    _ action: CurationAction, to identifiers: [String], dryRun: Bool,
    in database: CatalogDatabasePool
  ) async throws -> [CurationChange] {
    switch action {
    case let .setState(state):
      return try await CatalogAssets.setState(
        state, for: identifiers, in: database, dryRun: dryRun)
    case let .setFavorite(favorite):
      return try await CatalogAssets.setFavorite(
        favorite, for: identifiers, in: database, dryRun: dryRun)
    case let .setLabel(label, applied):
      return try await CatalogAssets.setLabel(
        label, applied, for: identifiers, in: database, dryRun: dryRun)
    case let .link(project):
      return try await CatalogAssets.addToProject(
        project, identifiers: identifiers, in: database, dryRun: dryRun)
    case let .unlink(project, confirmed):
      return try await CatalogAssets.removeFromProject(
        project, identifiers: identifiers, in: database, confirmed: confirmed, dryRun: dryRun)
    case let .move(from, to, confirmed):
      return try await CatalogAssets.moveAssets(
        identifiers, fromProject: from, toProject: to, in: database, confirmed: confirmed,
        dryRun: dryRun)
    }
  }

  /// Standard output of the command: the table or the JSON document.
  static func output(
    _ action: CurationAction, _ identifiers: [String], dryRun: Bool = false,
    format: OutputFormat = .table, in database: CatalogDatabasePool
  ) async throws -> String {
    let changes = try await apply(action, to: identifiers, dryRun: dryRun, in: database)
    switch format {
    case .json:
      return try encodedJSON(
        CurationDocument(action: action.name, dryRun: dryRun, changes: changes))
    case .table:
      let rows = changes.map { change in
        let result = change.before == change.after ? "unchanged" : "changed"
        return
          "\(change.sha256.prefix(12))\t\(change.key)\t\(action.column(change.before))\t"
          + "\(action.column(change.after))\t\(result)"
      }
      return (["SHA256\tKEY\tBEFORE\tAFTER\tRESULT"] + rows).joined(separator: "\n")
    }
  }

  static func run(
    _ action: CurationAction, _ identifiers: [String], options: CurationOptions,
    in database: CatalogDatabasePool
  ) async throws {
    let output = try await output(
      action, identifiers, dryRun: options.dryRun, format: options.format, in: database)
    if options.dryRun {
      FileHandle.standardError.write(Data("Dry run: nothing was written.\n".utf8))
    }
    print(output)
  }
}
