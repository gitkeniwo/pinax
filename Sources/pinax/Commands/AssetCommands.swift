import ArgumentParser
import CatalogCore
import Foundation

enum AssetListFormat: String, ExpressibleByArgument {
  case table
  case json
  case url
}

enum AssetState: String, ExpressibleByArgument {
  case active
  case archived
}

struct AssetListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls",
    abstract: "List catalog assets."
  )

  @Option(name: .long)
  var project: String?

  @Option(name: .long)
  var tag: String?

  @Option(name: .long)
  var state: AssetState?

  @Option(
    name: .long,
    help: "Only include assets uploaded since YYYY-MM, YYYY-MM-DD, or an ISO-8601 timestamp.")
  var since: String?

  @Option(name: .long)
  var limit = 50

  @Option(name: .long)
  var format: AssetListFormat = .table

  mutating func run() throws {
    guard limit > 0 else {
      throw ValidationError("Limit must be greater than zero.")
    }
    let database = try openCatalogDatabase()
    let items = try CatalogAssets.list(
      in: database,
      project: project,
      tag: tag,
      state: state?.rawValue,
      since: try normalizedSince(since),
      limit: limit
    )
    switch format {
    case .url:
      for item in items {
        print(item.url)
      }
    case .json:
      print(
        try PublicAssetJSON.encode(items.map { PublicAsset(asset: $0.asset, backend: $0.backend) }))
    case .table:
      print("SHA256\tSTATE\tBYTES\tKEY\tURL")
      for item in items {
        print(
          "\(item.asset.sha256.prefix(12))\t\(item.asset.state)\t\(item.asset.byteSize)\t\(item.asset.key)\t\(item.url)"
        )
      }
    }
  }

  private func normalizedSince(_ value: String?) throws -> String? {
    guard let value else { return nil }
    let normalized: String
    if value.count == 7,
      value[value.index(value.startIndex, offsetBy: 4)] == "-",
      value.replacingOccurrences(of: "-", with: "").allSatisfy(\.isNumber)
    {
      normalized = "\(value)-01T00:00:00Z"
    } else if value.count == 10,
      value[value.index(value.startIndex, offsetBy: 4)] == "-",
      value[value.index(value.startIndex, offsetBy: 7)] == "-",
      value.replacingOccurrences(of: "-", with: "").allSatisfy(\.isNumber)
    {
      normalized = "\(value)T00:00:00Z"
    } else {
      normalized = value
    }
    guard ISO8601DateFormatter().date(from: normalized) != nil else {
      throw ValidationError("Since must be YYYY-MM, YYYY-MM-DD, or an ISO-8601 timestamp.")
    }
    return normalized
  }
}

struct AssetURLCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "url",
    abstract: "Print an asset URL."
  )

  @Argument
  var identifier: String

  mutating func run() throws {
    let item = try CatalogAssets.resolve(identifier, in: openCatalogDatabase())
    print(item.url)
  }
}

struct AssetShowCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Show a full asset record and live usage counts."
  )

  @Argument
  var identifier: String

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    let details = try CatalogAssets.details(identifier, in: openCatalogDatabase())
    if format == .json {
      print(try encodedJSON(AssetDocument(details)))
      return
    }
    let asset = details.item.asset
    print("id: \(asset.id.map(String.init) ?? "")")
    print("sha256: \(asset.sha256)")
    print("backend: \(details.item.backend.slug)")
    print("key: \(asset.key)")
    print("url: \(details.item.url)")
    print("bytes: \(asset.byteSize)")
    print("dimensions: \(dimensions(asset))")
    print("mime: \(asset.mime)")
    print("original-filename: \(asset.originalFilename ?? "")")
    print("state: \(asset.state)")
    print("pinned: \(asset.pinned)")
    print("note: \(asset.note ?? "")")
    print("meta: \(asset.meta)")
    print(
      "source: \(AssetSourceDescription(asset: asset, backend: details.item.backend).text(date: asset.createdAt))"
    )
    print("uploaded-at: \(asset.uploadedAt)")
    print("created-at: \(asset.createdAt)")
    print("updated-at: \(asset.updatedAt)")
    print("tags: \(details.tags.joined(separator: ","))")
    if details.projects.isEmpty {
      print("projects: none")
    } else {
      print("projects:")
      for project in details.projects {
        print("  \(project.slug)\tlive-usage=\(project.liveUsageCount)")
      }
    }
  }

  private func dimensions(_ asset: Asset) -> String {
    guard let width = asset.width, let height = asset.height else { return "" }
    return "\(width)x\(height)"
  }
}

struct NoteCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "note",
    abstract: "Manage an asset note.",
    subcommands: [NoteSetCommand.self, NoteShowCommand.self, NoteClearCommand.self]
  )
}

struct NoteSetCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "set")

  @Argument(help: "An exact asset key or an unambiguous SHA-256 prefix.")
  var identifier: String

  @Argument
  var text: String

  mutating func run() throws {
    try NoteCommandOperations.set(text, for: identifier, in: openCatalogDatabase())
  }
}

struct NoteShowCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "show")

  @Argument(help: "An exact asset key or an unambiguous SHA-256 prefix.")
  var identifier: String

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    let database = try openCatalogDatabase()
    if format == .json {
      let asset = try CatalogAssets.resolve(identifier, in: database).asset
      print(try encodedJSON(NoteDocument(asset)))
      return
    }
    print(try NoteCommandOperations.show(for: identifier, in: database))
  }
}

struct NoteClearCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "clear")

  @Argument(help: "An exact asset key or an unambiguous SHA-256 prefix.")
  var identifier: String

  mutating func run() throws {
    try NoteCommandOperations.clear(for: identifier, in: openCatalogDatabase())
  }
}

/// The exact operations invoked by the three CLI subcommands, separated only
/// so GUI/CLI interoperability can be proved against one in-memory catalog.
/// Writes deliberately route through CatalogAssets.setNote; there is no CLI SQL.
enum NoteCommandOperations {
  static func set(_ note: String, for identifier: String, in database: CatalogDatabasePool)
    throws
  {
    try CatalogAssets.setNote(note, for: identifier, in: database)
  }

  static func show(for identifier: String, in database: CatalogDatabasePool) throws -> String {
    try CatalogAssets.resolve(identifier, in: database).asset.note ?? ""
  }

  static func clear(for identifier: String, in database: CatalogDatabasePool) throws {
    try CatalogAssets.setNote(nil, for: identifier, in: database)
  }
}
