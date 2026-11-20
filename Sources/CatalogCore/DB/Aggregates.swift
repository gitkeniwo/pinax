import Foundation
import GRDB

public struct TagSummary: Codable, Sendable, Equatable {
  public let name: String
  public let assetCount: Int

  public init(name: String, assetCount: Int) {
    self.name = name
    self.assetCount = assetCount
  }
}

public struct ProjectSummary: Codable, Sendable, Equatable {
  public let slug: String
  public let name: String
  public let assetCount: Int
  public let liveUsageCount: Int
  public let lastScanAt: String?

  public init(
    slug: String, name: String, assetCount: Int, liveUsageCount: Int, lastScanAt: String?
  ) {
    self.slug = slug
    self.name = name
    self.assetCount = assetCount
    self.liveUsageCount = liveUsageCount
    self.lastScanAt = lastScanAt
  }
}

extension CatalogAssets {
  public static func tagSummaries(in database: DatabasePool) throws -> [TagSummary] {
    try database.read { db in
      try fetchTagSummaries(in: db)
    }
  }

  public static func tagSummaries(in database: DatabasePool) async throws -> [TagSummary] {
    try await database.read { db in
      try fetchTagSummaries(in: db)
    }
  }

  static func fetchTagSummaries(in db: GRDB.Database) throws -> [TagSummary] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT t.name AS name, COUNT(at.asset_id) AS asset_count
        FROM tag t
        JOIN asset_tag at ON at.tag_id = t.id
        JOIN asset a ON a.id = at.asset_id AND a.state = 'active'
        GROUP BY t.id
        ORDER BY t.name
        """
    )
    return rows.map { row in
      TagSummary(name: row["name"], assetCount: row["asset_count"])
    }
  }

  /// Distinct `yyyy-MM` values present in `uploaded_at`, newest first, with counts.
  /// Scoped to the given query (minus its cursor) so the toolbar time filter only
  /// offers months that contain assets matching the current sidebar selection.
  public static func availableMonths(
    in database: DatabasePool,
    matching query: AssetQuery = AssetQuery()
  ) throws -> [(month: String, count: Int)] {
    try database.read { db in
      try fetchAvailableMonths(matching: query, in: db)
    }
  }

  public static func availableMonths(
    in database: DatabasePool,
    matching query: AssetQuery = AssetQuery()
  ) async throws -> [(month: String, count: Int)] {
    try await database.read { db in
      try fetchAvailableMonths(matching: query, in: db)
    }
  }

  static func fetchAvailableMonths(
    matching query: AssetQuery, in db: GRDB.Database
  ) throws -> [(month: String, count: Int)] {
    var scoped = query
    scoped.after = nil
    let parts = CatalogAssets.querySQL(scoped, includeCursor: false)
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT substr(a.uploaded_at, 1, 7) AS month, COUNT(DISTINCT a.id) AS count
        FROM asset a\(parts.joins)\(parts.whereClause)
        GROUP BY month
        ORDER BY month DESC
        """,
      arguments: StatementArguments(parts.arguments)
    )
    return rows.map { row in (month: row["month"], count: row["count"]) }
  }
}

extension CatalogAssets {
  /// The next level of the key-prefix tree under `prefix` (nil = the root),
  /// segment names ascending, each with the number of assets in its whole
  /// subtree. `state` scopes the count the way the grid a row opens onto is
  /// scoped — the gallery passes `.active` because archived assets are
  /// hidden from every default view; nil counts every state — so a row's
  /// count is that grid's total. Keys that sit directly under `prefix` with no
  /// further `/` produce no child: they are already inside the parent's own
  /// count, which the level above reported. `hasSubPrefixes` says whether
  /// a child has a level of its own, from the same query, so its row can
  /// show a disclosure triangle only when opening it grows a row, without a
  /// second query per prefix.
  ///
  /// `backendID` keeps the tree to one backend's bucket, so two buckets'
  /// same-named folders stay apart. It is required: no caller merges two
  /// buckets' folders.
  public static func keyPrefixChildren(
    under prefix: String?, state: AssetState? = nil, backendID: Int64, in database: DatabasePool
  ) throws -> [(segment: String, assetCount: Int, hasSubPrefixes: Bool)] {
    try database.read { db in
      try fetchKeyPrefixChildren(under: prefix, state: state, backendID: backendID, in: db)
    }
  }

  public static func keyPrefixChildren(
    under prefix: String?, state: AssetState? = nil, backendID: Int64, in database: DatabasePool
  ) async throws -> [(segment: String, assetCount: Int, hasSubPrefixes: Bool)] {
    try await database.read { db in
      try fetchKeyPrefixChildren(under: prefix, state: state, backendID: backendID, in: db)
    }
  }

  /// Every backend, by id, with the number of its assets in `state` (nil:
  /// every state) — the count on the backend's root row. A backend with
  /// none is listed with 0.
  public static func backendAssetTotals(
    state: AssetState? = nil, in database: DatabasePool
  ) async throws -> [(backendID: Int64, slug: String, assetCount: Int)] {
    try await database.read { db in try fetchBackendAssetTotals(state: state, in: db) }
  }

  public static func backendAssetTotals(
    state: AssetState? = nil, in database: DatabasePool
  ) throws -> [(backendID: Int64, slug: String, assetCount: Int)] {
    try database.read { db in try fetchBackendAssetTotals(state: state, in: db) }
  }

  static func fetchBackendAssetTotals(
    state: AssetState?, in db: GRDB.Database
  ) throws -> [(backendID: Int64, slug: String, assetCount: Int)] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT b.id, b.slug, COUNT(a.id) AS asset_count
        FROM backend b LEFT JOIN asset a ON a.backend_id = b.id\(state == nil ? "" : " AND a.state = ?")
        GROUP BY b.id ORDER BY b.id
        """,
      arguments: StatementArguments(state.map { [$0.rawValue] } ?? []))
    return rows.map { (backendID: $0["id"], slug: $0["slug"], assetCount: $0["asset_count"]) }
  }

  static func fetchKeyPrefixChildren(
    under prefix: String?, state: AssetState? = nil, backendID: Int64, in db: GRDB.Database
  ) throws -> [(segment: String, assetCount: Int, hasSubPrefixes: Bool)] {
    let range = prefix.map(keyPrefixRange)
    var conditions: [String] = []
    var arguments: [DatabaseValueConvertible?] = [prefix.map { $0 + "/" } ?? ""]
    if let range {
      conditions.append(range.sql)
      arguments.append(contentsOf: range.arguments)
    }
    conditions.append("a.backend_id = ?")
    arguments.append(backendID)
    if let state {
      conditions.append("a.state = ?")
      arguments.append(state.rawValue)
    }
    let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT CASE WHEN instr(rest, '/') > 0 THEN substr(rest, 1, instr(rest, '/') - 1) END AS segment,
               COUNT(*) AS asset_count,
               MAX(instr(substr(rest, instr(rest, '/') + 1), '/') > 0) AS has_sub_prefixes
        FROM (SELECT substr(a.key, length(?) + 1) AS rest
              FROM asset a\(whereClause))
        GROUP BY segment ORDER BY segment
        """,
      arguments: StatementArguments(arguments)
    )
    return rows.compactMap { row in
      guard let segment: String = row["segment"] else { return nil }
      return (
        segment: segment, assetCount: row["asset_count"],
        hasSubPrefixes: row["has_sub_prefixes"])
    }
  }

  /// A cheap fingerprint of the asset table, for caches of aggregates over
  /// it (the key-prefix tree): it moves on an insert
  /// (row count, newest id), a delete (row count), a state change (active
  /// count) and any edit that stamps `updated_at`. Equal stamps mean the
  /// cached levels are still the data's; the reader, not a write hook,
  /// notices, so a change made by the CLI in another process counts too.
  public static func changeStamp(in database: DatabasePool) async throws -> String {
    try await database.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) || ':' || IFNULL(MAX(id), '') || ':'
                 || IFNULL(SUM(state = 'active'), '') || ':' || IFNULL(MAX(updated_at), '')
          FROM asset
          """) ?? ""
    }
  }
}

extension CatalogConfiguration {
  public static func projectSummaries(in database: DatabasePool) throws -> [ProjectSummary] {
    try database.read { db in
      try fetchProjectSummaries(in: db)
    }
  }

  public static func projectSummaries(in database: DatabasePool) async throws -> [ProjectSummary] {
    try await database.read { db in
      try fetchProjectSummaries(in: db)
    }
  }

  static func fetchProjectSummaries(in db: GRDB.Database) throws -> [ProjectSummary] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT p.slug AS slug,
               p.name AS name,
               (SELECT COUNT(*) FROM asset_project ap JOIN asset a ON a.id = ap.asset_id
                WHERE ap.project_id = p.id AND a.state = 'active') AS asset_count,
               (SELECT COUNT(*) FROM usage u
                WHERE u.project_id = p.id
                  AND u.last_scan_id IS NOT NULL
                  AND u.last_scan_id = p.last_scan_id) AS live_usage_count,
               s.started_at AS last_scan_at
        FROM project p
        LEFT JOIN scan s ON s.id = p.last_scan_id
        ORDER BY p.slug
        """
    )
    return rows.map { row in
      ProjectSummary(
        slug: row["slug"],
        name: row["name"],
        assetCount: row["asset_count"],
        liveUsageCount: row["live_usage_count"],
        lastScanAt: row["last_scan_at"]
      )
    }
  }
}
