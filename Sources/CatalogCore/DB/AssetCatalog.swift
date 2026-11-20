import Foundation
import GRDB

public enum AssetCatalogError: Error, Equatable, CustomStringConvertible {
  case invalidSHA256Prefix(String)
  case assetNotFound(String)
  case ambiguousIdentifier(String, candidates: [String])
  case invalidTag(String)
  case projectNotFound(String)
  case unlinkBlockedByLiveUsage(project: String, liveCount: Int)

  public var description: String {
    switch self {
    case let .invalidSHA256Prefix(prefix):
      return "SHA-256 prefix '\(prefix)' must contain at least 6 hexadecimal characters."
    case let .assetNotFound(identifier):
      return "No asset matches '\(identifier)'."
    case let .ambiguousIdentifier(identifier, candidates):
      return "Asset identifier '\(identifier)' is ambiguous: \(candidates.joined(separator: ", "))"
    case let .invalidTag(tag):
      return "Tag '\(tag)' must not be empty."
    case let .projectNotFound(slug):
      return "Project '\(slug)' does not exist."
    case let .unlinkBlockedByLiveUsage(project, liveCount):
      return
        "Project '\(project)' still references this asset (\(liveCount) live references). "
        + "Unlinking it requires explicit confirmation."
    }
  }
}

public struct CatalogAssetItem: Codable, Sendable {
  public let asset: Asset
  public let backend: Backend
  public let url: String

  public init(asset: Asset, backend: Backend) {
    self.asset = asset
    self.backend = backend
    self.url = URLResolver.url(for: asset, backend: backend)
  }
}

public struct ProjectUsageCount: Codable, Equatable, Sendable {
  public let slug: String
  public let name: String
  public let liveUsageCount: Int

  public init(slug: String, name: String, liveUsageCount: Int) {
    self.slug = slug
    self.name = name
    self.liveUsageCount = liveUsageCount
  }
}

public struct CatalogAssetDetails: Codable, Sendable {
  public let item: CatalogAssetItem
  public let tags: [String]
  public let projects: [ProjectUsageCount]

  public init(item: CatalogAssetItem, tags: [String], projects: [ProjectUsageCount]) {
    self.item = item
    self.tags = tags
    self.projects = projects
  }
}

public enum CatalogAssets {
  public static func list(
    in database: DatabasePool,
    project: String? = nil,
    tag: String? = nil,
    state: String? = nil,
    since: String? = nil,
    limit: Int = 50
  ) throws -> [CatalogAssetItem] {
    try database.read { db in
      var joins = ""
      var conditions: [String] = []
      var arguments: [DatabaseValueConvertible?] = []
      if let project {
        joins +=
          " JOIN asset_project ap ON ap.asset_id = a.id JOIN project p ON p.id = ap.project_id"
        conditions.append("p.slug = ?")
        arguments.append(project)
      }
      if let tag {
        joins += " JOIN asset_tag at ON at.asset_id = a.id JOIN tag t ON t.id = at.tag_id"
        conditions.append("t.name = ?")
        arguments.append(tag)
      }
      if let state {
        conditions.append("a.state = ?")
        arguments.append(state)
      }
      if let since {
        conditions.append("a.uploaded_at >= ?")
        arguments.append(since)
      }
      let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
      arguments.append(limit)
      let assets = try Asset.fetchAll(
        db,
        sql: """
          SELECT DISTINCT a.*
          FROM asset a\(joins)\(whereClause)
          ORDER BY a.uploaded_at DESC, a.id DESC
          LIMIT ?
          """,
        arguments: StatementArguments(arguments)
      )
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
  }

  public static func resolve(_ identifier: String, in database: DatabasePool) throws
    -> CatalogAssetItem
  {
    try database.read { db in
      try resolve(identifier, in: db)
    }
  }

  public static func resolve(_ identifier: String, in database: DatabasePool) async throws
    -> CatalogAssetItem
  {
    try await database.read { db in
      try resolve(identifier, in: db)
    }
  }

  static func resolve(_ identifier: String, in db: GRDB.Database) throws -> CatalogAssetItem {
    guard let asset = try resolveInWrite(identifier, db: db),
      let backend = try Backend.fetchOne(db, key: asset.backendID)
    else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    return CatalogAssetItem(asset: asset, backend: backend)
  }

  public static func details(_ identifier: String, in database: DatabasePool) throws
    -> CatalogAssetDetails
  {
    try database.read { db in
      let item = try resolve(identifier, in: db)
      return try assetDetails(item, in: db)
    }
  }

  public static func details(_ identifier: String, in database: DatabasePool) async throws
    -> CatalogAssetDetails
  {
    try await database.read { db in
      let item = try resolve(identifier, in: db)
      return try assetDetails(item, in: db)
    }
  }

  static func assetDetails(_ item: CatalogAssetItem, in db: GRDB.Database) throws
    -> CatalogAssetDetails
  {
    guard let assetID = item.asset.id else {
      throw AssetCatalogError.assetNotFound(item.asset.key)
    }
    let tags = try String.fetchAll(
        db,
        sql: """
          SELECT t.name
          FROM tag t
          JOIN asset_tag at ON at.tag_id = t.id
          WHERE at.asset_id = ?
          ORDER BY t.name
          """,
        arguments: [assetID]
      )
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT DISTINCT p.slug, p.name, COALESCE(l.n, 0) AS live_usage_count
          FROM project p
          LEFT JOIN asset_project ap ON ap.project_id = p.id AND ap.asset_id = ?
          LEFT JOIN asset_live_usage l ON l.project_id = p.id AND l.asset_id = ?
          WHERE ap.asset_id IS NOT NULL OR l.asset_id IS NOT NULL
          ORDER BY p.slug
          """,
        arguments: [assetID, assetID]
      )
      let projects = rows.map { row in
        ProjectUsageCount(
          slug: row["slug"],
          name: row["name"],
          liveUsageCount: row["live_usage_count"]
        )
      }
      return CatalogAssetDetails(item: item, tags: tags, projects: projects)
  }

  public static func addTag(
    _ name: String,
    to identifier: String,
    in database: DatabasePool
  ) throws {
    try database.write { db in
      try addTagInTransaction(name, identifier: identifier, db: db)
    }
  }

  public static func addTag(
    _ name: String,
    to identifier: String,
    in database: DatabasePool
  ) async throws {
    try await database.write { db in
      try addTagInTransaction(name, identifier: identifier, db: db)
    }
  }

  public static func removeTag(
    _ name: String,
    from identifier: String,
    in database: DatabasePool
  ) throws {
    try database.write { db in
      try removeTagInTransaction(name, identifier: identifier, db: db)
    }
  }

  public static func removeTag(
    _ name: String,
    from identifier: String,
    in database: DatabasePool
  ) async throws {
    try await database.write { db in
      try removeTagInTransaction(name, identifier: identifier, db: db)
    }
  }

  /// Sets or clears an asset's note. `nil` clears it. Touches `updated_at`.
  /// Resolution and update happen inside one write transaction so concurrent
  /// writers cannot be reverted by a whole-row rewrite.
  public static func setNote(
    _ note: String?,
    for identifier: String,
    in database: DatabasePool,
    now: Date = Date()
  ) throws {
    try database.write { db in
      try setNoteInTransaction(note, for: identifier, now: now, db: db)
    }
  }

  public static func setNote(
    _ note: String?,
    for identifier: String,
    in database: DatabasePool,
    now: Date = Date()
  ) async throws {
    try await database.write { db in
      // The synchronous body re-resolves inside the writer; reuse it directly.
      try setNoteInTransaction(note, for: identifier, now: now, db: db)
    }
  }

  /// Adds the asset to a project. Re-adding is a no-op.
  public static func addToProject(
    _ slug: String,
    identifier: String,
    in database: DatabasePool,
    now: Date = Date()
  ) throws {
    try membershipChange(slug: slug, identifier: identifier, in: database, now: now) { db, assetID, projectID, date in
      try db.execute(
        sql: "INSERT OR IGNORE INTO asset_project (asset_id, project_id, added_at) VALUES (?, ?, ?)",
        arguments: [assetID, projectID, date]
      )
    }
  }

  public static func addToProject(
    _ slug: String,
    identifier: String,
    in database: DatabasePool,
    now: Date = Date()
  ) async throws {
    let item = try await resolve(identifier, in: database)
    guard let assetID = item.asset.id else { throw AssetCatalogError.assetNotFound(identifier) }
    try await database.write { db in
      guard let project = try Project.filter(Column("slug") == slug).fetchOne(db),
        let projectID = project.id
      else {
        throw AssetCatalogError.projectNotFound(slug)
      }
      try db.execute(
        sql: "INSERT OR IGNORE INTO asset_project (asset_id, project_id, added_at) VALUES (?, ?, ?)",
        arguments: [assetID, projectID, Self.timestamp(now)]
      )
    }
  }

  /// Removes the asset from a project. Removing a non-membership is a no-op.
  /// Removes the asset from a project. Removing a non-membership is a no-op.
  ///
  /// Live usage is a lower bound that never authorizes destructive action, so
  /// an unlink from a project that still references the asset is refused
  /// unless the caller passes `confirmed: true` — the caller's job is to have
  /// asked the user, not to assume. The check runs inside the write
  /// transaction, so it cannot be outrun by a concurrent scan.
  public static func removeFromProject(
    _ slug: String,
    identifier: String,
    in database: DatabasePool,
    confirmed: Bool = false
  ) throws {
    try membershipChange(slug: slug, identifier: identifier, in: database, now: Date()) { db, assetID, projectID, _ in
      if !confirmed {
        try requireNoLiveUsage(assetID: assetID, projectID: projectID, slug: slug, in: db)
      }
      try db.execute(
        sql: "DELETE FROM asset_project WHERE asset_id = ? AND project_id = ?",
        arguments: [assetID, projectID]
      )
    }
  }

  public static func removeFromProject(
    _ slug: String,
    identifier: String,
    in database: DatabasePool,
    confirmed: Bool = false
  ) async throws {
    try await database.write { db in
      let item = try resolve(identifier, in: db)
      guard let assetID = item.asset.id else { throw AssetCatalogError.assetNotFound(identifier) }
      guard let project = try Project.filter(Column("slug") == slug).fetchOne(db),
        let projectID = project.id
      else {
        throw AssetCatalogError.projectNotFound(slug)
      }
      if !confirmed {
        try requireNoLiveUsage(assetID: assetID, projectID: projectID, slug: slug, in: db)
      }
      try db.execute(
        sql: "DELETE FROM asset_project WHERE asset_id = ? AND project_id = ?",
        arguments: [assetID, projectID]
      )
    }
  }

  /// Moves an asset between projects atomically: either both halves land or
  /// neither does. Every decision — asset resolution, both project lookups,
  /// and the live-usage guard on the outgoing side — happens inside the one
  /// transaction, so a bad target slug or a refused unlink leaves the old
  /// membership untouched instead of destroying it.
  public static func moveAsset(
    _ identifier: String,
    fromProject fromSlug: String?,
    toProject toSlug: String?,
    in database: DatabasePool,
    confirmed: Bool = false,
    now: Date = Date()
  ) async throws {
    try await database.write { db in
      guard let assetRow = try resolveInWrite(identifier, db: db),
        let assetID = assetRow.id
      else {
        throw AssetCatalogError.assetNotFound(identifier)
      }
      var fromID: Int64?
      if let fromSlug {
        guard let project = try Project.filter(Column("slug") == fromSlug).fetchOne(db),
          let id = project.id
        else {
          throw AssetCatalogError.projectNotFound(fromSlug)
        }
        fromID = id
      }
      var toID: Int64?
      if let toSlug {
        guard let project = try Project.filter(Column("slug") == toSlug).fetchOne(db),
          let id = project.id
        else {
          throw AssetCatalogError.projectNotFound(toSlug)
        }
        toID = id
      }
      if let fromID {
        if !confirmed {
          try requireNoLiveUsage(assetID: assetID, projectID: fromID, slug: fromSlug!, in: db)
        }
        try db.execute(
          sql: "DELETE FROM asset_project WHERE asset_id = ? AND project_id = ?",
          arguments: [assetID, fromID]
        )
      }
      if let toID {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO asset_project (asset_id, project_id, added_at)
            VALUES (?, ?, ?)
            """,
          arguments: [assetID, toID, timestamp(now)]
        )
      }
    }
  }

  private static func requireNoLiveUsage(
    assetID: Int64, projectID: Int64, slug: String, in db: GRDB.Database
  ) throws {
    let live = try Int.fetchOne(
      db,
      sql: "SELECT n FROM asset_live_usage WHERE asset_id = ? AND project_id = ?",
      arguments: [assetID, projectID]
    ) ?? 0
    if live > 0 {
      throw AssetCatalogError.unlinkBlockedByLiveUsage(project: slug, liveCount: live)
    }
  }

  static func timestamp(_ date: Date) -> String {
    Self.iso8601.string(from: date)
  }

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    return formatter
  }()

  private static func addTagInTransaction(
    _ name: String,
    identifier: String,
    db: GRDB.Database
  ) throws {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw AssetCatalogError.invalidTag(name) }
    guard let asset = try resolveInWrite(identifier, db: db), let assetID = asset.id else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    try db.execute(
      sql: "INSERT INTO tag (name) VALUES (?) ON CONFLICT(name) DO NOTHING",
      arguments: [normalized]
    )
    try db.execute(
      sql: """
        INSERT INTO asset_tag (asset_id, tag_id)
        SELECT ?, id FROM tag WHERE name = ?
        ON CONFLICT(asset_id, tag_id) DO NOTHING
        """,
      arguments: [assetID, normalized]
    )
  }

  private static func removeTagInTransaction(
    _ name: String,
    identifier: String,
    db: GRDB.Database
  ) throws {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw AssetCatalogError.invalidTag(name) }
    guard let asset = try resolveInWrite(identifier, db: db), let assetID = asset.id else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    try db.execute(
      sql: """
        DELETE FROM asset_tag
        WHERE asset_id = ? AND tag_id = (SELECT id FROM tag WHERE name = ?)
        """,
      arguments: [assetID, normalized]
    )
    try db.execute(
      sql:
        "DELETE FROM tag WHERE name = ? AND NOT EXISTS (SELECT 1 FROM asset_tag WHERE tag_id = tag.id)",
      arguments: [normalized]
    )
  }

  private static func membershipChange(
    slug: String,
    identifier: String,
    in database: DatabasePool,
    now: Date,
    _ change: (GRDB.Database, Int64, Int64, String) throws -> Void
  ) throws {
    let date = Self.timestamp(now)
    try database.write { db in
      guard let assetRow = try resolveInWrite(identifier, db: db) else {
        throw AssetCatalogError.assetNotFound(identifier)
      }
      guard let assetID = assetRow.id else { throw AssetCatalogError.assetNotFound(identifier) }
      guard let project = try Project.filter(Column("slug") == slug).fetchOne(db),
        let projectID = project.id
      else {
        throw AssetCatalogError.projectNotFound(slug)
      }
      try change(db, assetID, projectID, date)
    }
  }

  /// An exact key, else an unambiguous sha256 prefix. A key is unique per
  /// backend only: when two backends hold it, the identifier is ambiguous —
  /// never whichever row SQLite returns first.
  static func resolveInWrite(_ identifier: String, db: GRDB.Database) throws -> Asset? {
    let exact = try Asset.filter(Column("key") == identifier).order(Column("id")).fetchAll(db)
    if exact.count > 1 {
      let slugs = try Dictionary(
        uniqueKeysWithValues: Backend.fetchAll(db).map { ($0.id ?? -1, $0.slug) })
      let candidates = exact.map {
        "\($0.sha256.prefix(12)) \($0.key) (\(slugs[$0.backendID] ?? "?"))"
      }
      throw AssetCatalogError.ambiguousIdentifier(identifier, candidates: candidates)
    }
    if let exact = exact.first {
      return exact
    }
    guard identifier.count >= 6,
      identifier.unicodeScalars.allSatisfy({ scalar in
        (48...57).contains(scalar.value) || (65...70).contains(scalar.value)
          || (97...102).contains(scalar.value)
      })
    else {
      throw AssetCatalogError.invalidSHA256Prefix(identifier)
    }
    let matches = try Asset
      .filter(Column("sha256").like("\(identifier.lowercased())%"))
      .order(Column("sha256"), Column("key"))
      .fetchAll(db)
    guard !matches.isEmpty else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    guard matches.count == 1 else {
      let candidates = matches.map { "\($0.sha256.prefix(12)) \($0.key)" }
      throw AssetCatalogError.ambiguousIdentifier(identifier, candidates: candidates)
    }
    return matches[0]
  }

  private static func setNoteInTransaction(
    _ note: String?,
    for identifier: String,
    now: Date,
    db: GRDB.Database
  ) throws {
    let normalized = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleared = (normalized?.isEmpty ?? true) ? nil : normalized
    guard var asset = try resolveInWrite(identifier, db: db) else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    asset.note = cleared
    asset.updatedAt = Self.timestamp(now)
    try asset.update(db)
  }
}
