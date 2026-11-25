import ArgumentParser
import CatalogCore
import Foundation

enum AssetListFormat: String, ExpressibleByArgument {
  case table
  case json
  case url
}

/// `--state`; `all` lifts the state condition.
enum AssetStateFilter: String, ExpressibleByArgument, CaseIterable {
  case active
  case archived
  case all

  var queryState: AssetState? {
    switch self {
    case .active: .active
    case .archived: .archived
    case .all: nil
    }
  }
}

enum AssetSortKey: String, ExpressibleByArgument, CaseIterable {
  case uploaded
  case name
  case size
  case kind

  var field: AssetSort.Field {
    switch self {
    case .uploaded: .uploadedAt
    case .name: .name
    case .size: .byteSize
    case .kind: .kind
    }
  }
}

enum AssetSortOrder: String, EnumerableFlag {
  case asc
  case desc

  var direction: AssetSort.Direction {
    switch self {
    case .asc: .ascending
    case .desc: .descending
    }
  }
}

extension SearchField: ExpressibleByArgument {}
extension SearchMatch: ExpressibleByArgument {}
extension AssetLabel: ExpressibleByArgument {}
extension AssetSource: ExpressibleByArgument {}

/// `--after`'s string: the last row's keyset position and the sort that
/// produced it, as base64url. Callers pass it back unchanged.
struct AssetListCursor: Codable {
  let field: String
  let direction: String
  let value: String
  let id: Int64

  static func encode(_ cursor: AssetCursor, sort: AssetSort) throws -> String {
    let token = AssetListCursor(
      field: sort.field.rawValue, direction: sort.direction.rawValue,
      value: cursor.sortValue, id: cursor.id)
    return try JSONEncoder().encode(token).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decode(_ text: String, sort: AssetSort) throws -> AssetCursor {
    var base64 = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
      let token = try? JSONDecoder().decode(AssetListCursor.self, from: data)
    else {
      throw ValidationError("'\(text)' is not a cursor.")
    }
    guard token.field == sort.field.rawValue, token.direction == sort.direction.rawValue else {
      throw ValidationError("The cursor belongs to a different sort order.")
    }
    return AssetCursor(sortValue: token.value, id: token.id)
  }
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

  @Option(name: .long, help: "Which assets to list by state.")
  var state: AssetStateFilter = .active

  @Option(
    name: .long,
    help: "Only include assets uploaded since YYYY-MM, YYYY-MM-DD, or an ISO-8601 timestamp.")
  var since: String?

  @Option(
    name: .long,
    help: "Only include assets uploaded before YYYY-MM, YYYY-MM-DD, or an ISO-8601 timestamp.")
  var until: String?

  @Option(name: .long, help: "Only include assets whose filename, key, or note matches.")
  var search: String?

  @Option(name: .long, help: "What --search looks at.")
  var searchField: SearchField = .any

  @Option(name: .long, help: "How --search compares.")
  var match: SearchMatch = .contains

  @Flag(name: .long, help: "Make --search case-sensitive.")
  var caseSensitive = false

  @Option(name: .long, help: "Only include keys under this path, such as blog/2026.")
  var keyPrefix: String?

  @Option(name: .long, help: "Only include one backend's assets, by slug.")
  var backend: String?

  @Flag(name: .long, help: "Only include favorites.")
  var favorites = false

  @Option(name: .long, help: "Only include assets with this color label.")
  var label: AssetLabel?

  @Option(name: .long, help: "Only include assets from this source; repeat for several.")
  var source: [AssetSource] = []

  @Option(name: .long)
  var sort: AssetSortKey = .uploaded

  @Flag(help: "Sort direction; descending by default.")
  var order: AssetSortOrder = .desc

  @Option(name: .long)
  var limit = 50

  @Option(name: .long, help: "Continue after the `next` cursor of a JSON listing.")
  var after: String?

  @Option(name: .long)
  var format: AssetListFormat = .table

  mutating func run() throws {
    var query = try query()
    let database = try openCatalogDatabase()
    if let backend {
      query.backendID = try CatalogConfiguration.backend(slug: backend, in: database).id
    }
    let page = try CatalogAssets.page(query, in: database)
    switch format {
    case .url:
      for item in page.items {
        print(item.url)
      }
    case .json:
      print(try encodedJSON(AssetListDocument(page, sort: query.sort)))
    case .table:
      print("SHA256\tSTATE\tBYTES\tKEY\tURL")
      for item in page.items {
        print(
          "\(item.asset.sha256.prefix(12))\t\(item.asset.state)\t\(item.asset.byteSize)\t\(item.asset.key)\t\(item.url)"
        )
      }
    }
  }

  /// The query the flags describe, apart from `--backend`, whose id needs
  /// the catalog. A bad argument throws here, before the catalog is opened.
  func query() throws -> AssetQuery {
    guard limit > 0 else {
      throw ValidationError("Limit must be greater than zero.")
    }
    var query = AssetQuery()
    query.sort = AssetSort(field: sort.field, direction: order.direction)
    query.project = project
    query.tag = tag
    query.state = state.queryState
    query.since = try normalizedDate(since, option: "Since")
    query.until = try normalizedDate(until, option: "Until")
    query.search = search
    query.searchField = searchField
    query.searchMatch = match
    query.searchCaseSensitive = caseSensitive
    if let keyPrefix {
      let trimmed = keyPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !trimmed.isEmpty else {
        throw ValidationError("Key prefix must not be empty.")
      }
      query.keyPrefix = trimmed
    }
    query.favoritesOnly = favorites
    query.label = label
    query.sources = Set(source)
    // A page reads one row past its limit.
    query.limit = min(limit, Int.max - 1)
    query.after = try after.map { try AssetListCursor.decode($0, sort: query.sort) }
    return query
  }

  private func normalizedDate(_ value: String?, option: String) throws -> String? {
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
      throw ValidationError("\(option) must be YYYY-MM, YYYY-MM-DD, or an ISO-8601 timestamp.")
    }
    return normalized
  }
}

// MARK: - pinax ls --format json

/// One page of `ls`, in the table's order. `next` is null on the last page.
struct AssetListDocument: Encodable {
  let schema = "pinax.list.v1"
  let assets: [ListedAssetJSON]
  @ExplicitNull var next: String?

  init(_ page: AssetPage, sort: AssetSort) throws {
    assets = page.items.map { item in
      let id = item.asset.id
      return ListedAssetJSON(
        item,
        favorite: id.map(page.favoriteIDs.contains) ?? false,
        labels: id.flatMap { page.labelsByAssetID[$0] } ?? [],
        tags: id.flatMap { page.tagsByAssetID[$0] } ?? [])
    }
    next = try page.next.map { try AssetListCursor.encode($0, sort: sort) }
  }
}

/// The keys of an asset in `upload` JSON, and what the catalog knows
/// besides.
struct ListedAssetJSON: Encodable {
  @ExplicitNull var id: Int64?
  let sha256: String
  let backend: String
  let key: String
  let url: String
  @ExplicitNull var width: Int?
  @ExplicitNull var height: Int?
  let bytes: Int64
  let mime: String
  let filename: String
  let uploadedAt: String
  let state: String
  let favorite: Bool
  let labels: [String]
  let tags: [String]
  let source: String
  @ExplicitNull var note: String?

  init(_ item: CatalogAssetItem, favorite: Bool, labels: [AssetLabel], tags: [String]) {
    let asset = PublicAsset(asset: item.asset, backend: item.backend)
    id = item.asset.id
    sha256 = asset.sha256
    backend = item.backend.slug
    key = asset.key
    url = asset.url
    width = asset.width
    height = asset.height
    bytes = asset.bytes
    mime = asset.mime
    filename = asset.filename
    uploadedAt = asset.uploadedAt
    state = item.asset.state
    self.favorite = favorite
    self.labels = labels.map(\.rawValue)
    self.tags = tags
    source = AssetSource.of(meta: item.asset.meta).rawValue
    note = item.asset.note
  }

  enum CodingKeys: String, CodingKey {
    case id, sha256, backend, key, url, width, height, bytes, mime, filename, state, favorite
    case labels, tags, source, note
    case uploadedAt = "uploaded_at"
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
    print("favorite: \(details.favorite)")
    print("labels: \(details.labels.map(\.rawValue).joined(separator: ","))")
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
