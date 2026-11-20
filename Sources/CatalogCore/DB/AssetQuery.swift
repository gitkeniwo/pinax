import Foundation
import GRDB

/// Keyset position after the last row of a page: that row's value for the
/// query's sort field (`AssetSort.sortValue(of:)`) and its id, the tiebreak.
/// Under the default sort `sortValue` is `uploaded_at`. A cursor is only
/// meaningful with the sort that produced it.
public struct AssetCursor: Codable, Sendable, Equatable {
  public let sortValue: String
  public let id: Int64

  public init(sortValue: String, id: Int64) {
    self.sortValue = sortValue
    self.id = id
  }
}

public enum AssetState: String, Codable, Sendable, CaseIterable {
  case active
  case archived
}

/// Which columns `AssetQuery.search` matches. `.any` is the CLI's behaviour
/// (filename OR key OR note); the GUI's search scopes select one column.
public enum SearchField: String, Sendable, Hashable, CaseIterable {
  case any
  case filename
  case key
  case note
}

/// How `AssetQuery.search` compares against the chosen column(s) — the
/// find strip's match-mode control. Every case is a real
/// SQL difference; the case-sensitive paths compare BLOB casts because
/// SQLite's `LIKE` cannot be made case-sensitive per-statement.
public enum SearchMatch: String, Sendable, Hashable, CaseIterable {
  case contains
  case begins
  case ends
  case matches
}

public struct AssetSort: Sendable, Equatable {
  public enum Field: String, Sendable, Hashable, CaseIterable {
    case uploadedAt
    case name
    case byteSize
    case kind
    /// By `AssetSource`, as `AssetSource.of(meta:)` classifies the asset.
    case source
    /// The asset's backend's current host — the
    /// Table's Domain column. Not in the grid's sort menu.
    case domain

    /// The grid's sort menu and the default-sort setting: all but Domain.
    public static let menuCases: [Field] = allCases.filter { $0 != .domain }
  }

  public enum Direction: String, Sendable, Hashable, CaseIterable {
    case ascending
    case descending
  }

  public var field: Field
  public var direction: Direction

  public init(field: Field = .uploadedAt, direction: Direction = .descending) {
    self.field = field
    self.direction = direction
  }

  /// The ORDER BY expression; the keyset predicate compares the same one, so
  /// ordering and paging cannot disagree (name ties are NOCASE ties in both).
  var sqlExpression: String {
    switch field {
    case .uploadedAt: "a.uploaded_at"
    case .name: "COALESCE(a.orig_filename, a.key) COLLATE NOCASE"
    case .byteSize: "a.byte_size"
    case .kind: "a.mime"
    case .source: "pinax_asset_source(a.meta)"
    case .domain: Self.domainExpression
    }
  }

  /// The backend's prefix without its scheme, lowercased: the host first,
  /// so it orders as the column reads.
  static let domainExpression = """
    COALESCE((SELECT lower(substr(b.url_prefix, instr(b.url_prefix, '://') + 3)) \
    FROM backend b WHERE b.id = a.backend_id), '')
    """

  /// The cursor's bound placeholder: sizes compare as integers, the rest as text.
  var cursorPlaceholder: String {
    field == .byteSize ? "CAST(? AS INTEGER)" : "?"
  }

  /// The id is always the second key, in the primary key's direction.
  var orderByClause: String {
    let dir = direction == .ascending ? "ASC" : "DESC"
    return "ORDER BY \(sqlExpression) \(dir), a.id \(dir)"
  }

  func sortValue(of asset: Asset) -> String {
    switch field {
    case .uploadedAt: asset.uploadedAt
    case .name: asset.originalFilename ?? asset.key
    case .byteSize: String(asset.byteSize)
    case .kind: asset.mime
    case .source: AssetSource.of(meta: asset.meta).rawValue
    case .domain: ""
    }
  }

  /// The cursor's value for `asset`; Domain reads its backend's prefix.
  func sortValue(of asset: Asset, in db: GRDB.Database) throws -> String {
    guard field == .domain, let id = asset.id else { return sortValue(of: asset) }
    return try String.fetchOne(
      db, sql: "SELECT \(sqlExpression) FROM asset a WHERE a.id = ?", arguments: [id]) ?? ""
  }
}

public struct AssetQuery: Sendable, Equatable {
  public var sort = AssetSort()
  public var project: String?
  public var tag: String?
  public var state: AssetState?
  public var since: String?
  public var until: String?
  public var search: String?
  public var searchField: SearchField = .any
  public var searchMatch: SearchMatch = .contains
  public var searchCaseSensitive = false
  /// A physical key prefix — path segments joined by `/`, no leading or
  /// trailing slash ("blog/202603"). Matches keys strictly under it
  /// (`prefix/…`), never a sibling that merely starts with the same
  /// characters; nil is the whole catalog.
  public var keyPrefix: String?
  /// Only one backend's assets (a Catalog root,
  /// and the key prefixes under it); nil is every backend.
  public var backendID: Int64?
  /// Only favourites; only assets carrying this label.
  public var favoritesOnly = false
  public var label: AssetLabel?
  /// Only assets from these sources, as `AssetSource.of(meta:)`
  /// classifies them; empty is every source.
  public var sources: Set<AssetSource> = []
  public var limit: Int = 100
  public var after: AssetCursor?

  public init() {}
}

public struct AssetPage: Sendable {
  public let items: [CatalogAssetItem]
  public let tagsByAssetID: [Int64: [String]]
  /// Which of `items` are favourites, and their labels.
  public let favoriteIDs: Set<Int64>
  public let labelsByAssetID: [Int64: [AssetLabel]]
  public let next: AssetCursor?

  public init(
    items: [CatalogAssetItem], tagsByAssetID: [Int64: [String]] = [:],
    favoriteIDs: Set<Int64> = [], labelsByAssetID: [Int64: [AssetLabel]] = [:],
    next: AssetCursor?
  ) {
    self.items = items
    self.tagsByAssetID = tagsByAssetID
    self.favoriteIDs = favoriteIDs
    self.labelsByAssetID = labelsByAssetID
    self.next = next
  }
}

extension CatalogAssets {
  public static func page(_ query: AssetQuery, in database: DatabasePool) throws -> AssetPage {
    try database.read { db in
      try fetchPage(query, in: db)
    }
  }

  public static func page(_ query: AssetQuery, in database: DatabasePool) async throws -> AssetPage {
    try await database.read { db in
      try fetchPage(query, in: db)
    }
  }

  /// The number of assets matching `query`, ignoring `limit` and `after`.
  /// Built from the same `querySQL` as the page query: a
  /// second, hand-written WHERE clause would drift from the real query and
  /// lie in a subtler way than having no count at all.
  public static func count(_ query: AssetQuery, in database: DatabasePool) throws -> Int {
    try database.read { db in
      try fetchCount(query, in: db)
    }
  }

  public static func count(_ query: AssetQuery, in database: DatabasePool) async throws -> Int {
    try await database.read { db in
      try fetchCount(query, in: db)
    }
  }

  static func fetchCount(_ query: AssetQuery, in db: GRDB.Database) throws -> Int {
    let parts = querySQL(query, includeCursor: false)
    return try Int.fetchOne(
      db,
      sql: "SELECT COUNT(DISTINCT a.id) FROM asset a\(parts.joins)\(parts.whereClause)",
      arguments: StatementArguments(parts.arguments)
    ) ?? 0
  }

  static func fetchPage(_ query: AssetQuery, in db: GRDB.Database) throws -> AssetPage {
    guard query.limit > 0 else { return AssetPage(items: [], next: nil) }
    let parts = querySQL(query, includeCursor: true)
    var arguments = parts.arguments
    arguments.append(query.limit + 1)
    let assets = try Asset.fetchAll(
      db,
      sql: """
        SELECT DISTINCT a.*
        FROM asset a\(parts.joins)\(parts.whereClause)
        \(query.sort.orderByClause)
        LIMIT ?
        """,
      arguments: StatementArguments(arguments)
    )
    guard assets.count > query.limit else {
      return AssetPage(
        items: try catalogItems(for: assets, in: db),
        tagsByAssetID: try tagsByAssetID(for: assets, in: db),
        favoriteIDs: try favoriteIDs(among: assets, in: db),
        labelsByAssetID: try labelsByAssetID(for: assets, in: db),
        next: nil)
    }
    let kept = Array(assets.prefix(query.limit))
    guard let last = kept.last, let lastID = last.id else {
      return AssetPage(items: [], next: nil)
    }
    return AssetPage(
      items: try catalogItems(for: kept, in: db),
      tagsByAssetID: try tagsByAssetID(for: kept, in: db),
      favoriteIDs: try favoriteIDs(among: kept, in: db),
      labelsByAssetID: try labelsByAssetID(for: kept, in: db),
      next: AssetCursor(sortValue: try query.sort.sortValue(of: last, in: db), id: lastID)
    )
  }

  /// "Strictly under `prefix`" as a byte range on `a.key`: `prefix/` up to,
  /// not including, `prefix0` (`0` is the byte after `/`). `key` has the
  /// default BINARY collation, so the comparison is `memcmp` — case-exact
  /// like an S3 key, where a `LIKE` would fold ASCII case, and with no
  /// wildcard characters to escape. Shared by
  /// the predicate and the children aggregate so the tree's counts and the
  /// grid's rows are cut by the same range. nil (the root) has no range.
  static func keyPrefixRange(_ prefix: String) -> (sql: String, arguments: [String]) {
    ("a.key >= ? AND a.key < ?", [prefix + "/", prefix + "0"])
  }

  private static func likeEscaped(_ input: String) -> String {
    input.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  /// One column's search predicate for the current match mode. The
  /// case-insensitive path is the long-standing `LIKE … ESCAPE '\'` with a
  /// mode-shaped pattern; the case-sensitive path compares BLOB casts
  /// (`instr` positions), byte-exact by construction.
  private static func searchPredicate(
    column: String, search: String, match: SearchMatch, caseSensitive: Bool
  ) -> (sql: String, arguments: [DatabaseValueConvertible?]) {
    if caseSensitive {
      let blob = "CAST(\(column) AS BLOB)"
      switch match {
      case .contains:
        return ("instr(\(blob), CAST(? AS BLOB)) > 0", [search])
      case .begins:
        return ("instr(\(blob), CAST(? AS BLOB)) = 1", [search])
      case .ends:
        // A hit at the tail: not-found returns 0 and can never equal
        // length − termLength + 1 for a non-empty term.
        return (
          "instr(\(blob), CAST(? AS BLOB)) = length(\(blob)) - length(CAST(? AS BLOB)) + 1",
          [search, search]
        )
      case .matches:
        return ("\(blob) = CAST(? AS BLOB)", [search])
      }
    }
    let term = likeEscaped(search)
    let pattern: String
    switch match {
    case .contains: pattern = "%\(term)%"
    case .begins: pattern = "\(term)%"
    case .ends: pattern = "%\(term)"
    case .matches: pattern = term
    }
    return ("\(column) LIKE ? ESCAPE '\\'", [pattern])
  }

  /// The single place that turns an `AssetQuery` into SQL joins, a WHERE clause,
  /// and bound arguments. Every read that filters assets must go through here so
  /// the gallery's grid, counts, and month filter can never disagree.
  static func querySQL(_ query: AssetQuery, includeCursor: Bool) -> (
    joins: String, whereClause: String, arguments: [DatabaseValueConvertible?]
  ) {
    var joins = ""
    var conditions: [String] = []
    var arguments: [DatabaseValueConvertible?] = []
    if let project = query.project {
      joins += " JOIN asset_project ap ON ap.asset_id = a.id JOIN project p ON p.id = ap.project_id"
      conditions.append("p.slug = ?")
      arguments.append(project)
    }
    if let tag = query.tag {
      joins += " JOIN asset_tag at2 ON at2.asset_id = a.id JOIN tag t ON t.id = at2.tag_id"
      conditions.append("t.name = ?")
      arguments.append(tag)
    }
    if let state = query.state {
      conditions.append("a.state = ?")
      arguments.append(state.rawValue)
    }
    if query.favoritesOnly {
      conditions.append("a.favorite = 1")
    }
    if let label = query.label {
      conditions.append("EXISTS (SELECT 1 FROM asset_label al WHERE al.asset_id = a.id AND al.label = ?)")
      arguments.append(label.rawValue)
    }
    if !query.sources.isEmpty {
      let sources = AssetSource.allCases.filter(query.sources.contains)
      conditions.append(
        "\(AssetSource.sqlFunction.name)(a.meta) IN (\(sources.map { _ in "?" }.joined(separator: ",")))")
      arguments.append(contentsOf: sources.map(\.rawValue))
    }
    if let since = query.since {
      conditions.append("a.uploaded_at >= ?")
      arguments.append(since)
    }
    if let until = query.until {
      conditions.append("a.uploaded_at < ?")
      arguments.append(until)
    }
    if let backendID = query.backendID {
      conditions.append("a.backend_id = ?")
      arguments.append(backendID)
    }
    if let keyPrefix = query.keyPrefix {
      let range = keyPrefixRange(keyPrefix)
      conditions.append(range.sql)
      arguments.append(contentsOf: range.arguments)
    }
    if let search = query.search, !search.isEmpty {
      func predicate(_ column: String) -> (sql: String, arguments: [DatabaseValueConvertible?]) {
        searchPredicate(
          column: column, search: search, match: query.searchMatch,
          caseSensitive: query.searchCaseSensitive)
      }
      switch query.searchField {
      case .any:
        let filename = predicate("a.orig_filename")
        let key = predicate("a.key")
        let note = predicate("a.note")
        conditions.append("(\(filename.sql) OR \(key.sql) OR \(note.sql))")
        arguments.append(contentsOf: filename.arguments)
        arguments.append(contentsOf: key.arguments)
        arguments.append(contentsOf: note.arguments)
      case .filename:
        let p = predicate("a.orig_filename")
        conditions.append(p.sql)
        arguments.append(contentsOf: p.arguments)
      case .key:
        let p = predicate("a.key")
        conditions.append(p.sql)
        arguments.append(contentsOf: p.arguments)
      case .note:
        let p = predicate("a.note")
        conditions.append(p.sql)
        arguments.append(contentsOf: p.arguments)
      }
    }
    if includeCursor, let after = query.after {
      let sort = query.sort
      let op = sort.direction == .ascending ? ">" : "<"
      let (expr, value) = (sort.sqlExpression, sort.cursorPlaceholder)
      conditions.append("(\(expr) \(op) \(value) OR (\(expr) = \(value) AND a.id \(op) ?))")
      arguments.append(after.sortValue)
      arguments.append(after.sortValue)
      arguments.append(after.id)
    }
    let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    return (joins, whereClause, arguments)
  }

  static func catalogItems(for assets: [Asset], in db: GRDB.Database) throws -> [CatalogAssetItem] {
    let backendIDs = Set(assets.map(\.backendID))
    let backends = try Backend.filter(backendIDs.contains(Column("id"))).fetchAll(db)
    let backendByID = Dictionary(
      uniqueKeysWithValues: backends.compactMap { backend in
        backend.id.map { ($0, backend) }
      })
    return assets.compactMap { asset in
      backendByID[asset.backendID].map { CatalogAssetItem(asset: asset, backend: $0) }
    }
  }

  private static func tagsByAssetID(
    for assets: [Asset], in db: GRDB.Database
  ) throws -> [Int64: [String]] {
    let assetIDs = assets.compactMap(\.id)
    guard !assetIDs.isEmpty else { return [:] }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT at.asset_id, t.name
        FROM asset_tag at
        JOIN tag t ON t.id = at.tag_id
        WHERE at.asset_id IN (\(assetIDs.map { _ in "?" }.joined(separator: ",")))
        ORDER BY at.asset_id, t.name
        """,
      arguments: StatementArguments(assetIDs)
    )
    return Dictionary(grouping: rows, by: { $0["asset_id"] as Int64 })
      .mapValues { $0.map { $0["name"] as String } }
  }
}

extension AssetSource {
  /// `pinax_asset_source(meta)`: `AssetSource.of(meta:)` inside SQLite, so
  /// the filter can never disagree with the classifier. Every connection
  /// `Database.open` makes has it.
  static let sqlFunction = DatabaseFunction("pinax_asset_source", argumentCount: 1, pure: true) {
    values in
    AssetSource.of(meta: String.fromDatabaseValue(values[0])).rawValue
  }
}
