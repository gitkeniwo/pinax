import Foundation
import GRDB

/// Finder's seven colour labels, in Finder's order.
/// The raw value is what `asset_label.label` stores.
public enum AssetLabel: String, CaseIterable, Codable, Hashable, Sendable {
  case red
  case orange
  case yellow
  case green
  case blue
  case purple
  case gray

  public var title: String { rawValue.capitalized }
}

public struct LabelSummary: Sendable, Equatable {
  public let label: AssetLabel
  public let assetCount: Int

  public init(label: AssetLabel, assetCount: Int) {
    self.label = label
    self.assetCount = assetCount
  }
}

/// What the curation writes can change about one asset.
public struct CurationState: Equatable, Sendable {
  public let state: String
  public let favorite: Bool
  /// Finder's order.
  public let labels: [AssetLabel]
  /// The slugs of the projects the asset belongs to, sorted.
  public let projects: [String]
}

/// One asset a curation write resolved, as it was and as the write leaves it.
/// The two are equal when the asset was already there.
public struct CurationChange: Equatable, Sendable {
  public let sha256: String
  public let key: String
  public let before: CurationState
  public let after: CurationState
}

/// Curation writes: archive and put back, favourite, colour labels. Every one
/// of them is a catalog row change and nothing else — no function here takes
/// a backend, and archiving never deletes a remote object. Each takes any
/// number of identifiers and is one transaction: unless every identifier
/// resolves, nothing is written. With `dryRun` the transaction is rolled
/// back, so what is returned is what the write would have done.
extension CatalogAssets {
  /// Archive (`.archived`) or Put Back (`.active`). Stamps `updated_at`, so
  /// `changeStamp` moves and the Catalog tree refetches its counts.
  @discardableResult
  public static func setState(
    _ state: AssetState, for identifiers: [String], in database: DatabasePool,
    dryRun: Bool = false, now: Date = Date()
  ) async throws -> [CurationChange] {
    let date = timestamp(now)
    return try await curate(identifiers, in: database, dryRun: dryRun) { db, assets in
      for asset in assets {
        try db.execute(
          sql: "UPDATE asset SET state = ?, updated_at = ? WHERE id = ?",
          arguments: [state.rawValue, date, asset.id])
      }
    }
  }

  @discardableResult
  public static func setFavorite(
    _ favorite: Bool, for identifiers: [String], in database: DatabasePool, dryRun: Bool = false
  ) async throws -> [CurationChange] {
    try await curate(identifiers, in: database, dryRun: dryRun) { db, assets in
      for asset in assets {
        try db.execute(
          sql: "UPDATE asset SET favorite = ? WHERE id = ?", arguments: [favorite, asset.id])
      }
    }
  }

  @discardableResult
  public static func setLabel(
    _ label: AssetLabel, _ applied: Bool, for identifiers: [String], in database: DatabasePool,
    dryRun: Bool = false
  ) async throws -> [CurationChange] {
    try await curate(identifiers, in: database, dryRun: dryRun) { db, assets in
      for asset in assets {
        if applied {
          try db.execute(
            sql: "INSERT INTO asset_label (asset_id, label) VALUES (?, ?) ON CONFLICT DO NOTHING",
            arguments: [asset.id, label.rawValue])
        } else {
          try db.execute(
            sql: "DELETE FROM asset_label WHERE asset_id = ? AND label = ?",
            arguments: [asset.id, label.rawValue])
        }
      }
    }
  }

  /// The labels in use on active assets, Finder's order, with counts — the
  /// Collections navigator lists only these.
  public static func labelSummaries(in database: DatabasePool) async throws -> [LabelSummary] {
    try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT al.label AS label, COUNT(*) AS asset_count
          FROM asset_label al JOIN asset a ON a.id = al.asset_id
          WHERE a.state = 'active'
          GROUP BY al.label
          """)
      let counts = Dictionary(
        uniqueKeysWithValues: rows.compactMap { row -> (AssetLabel, Int)? in
          AssetLabel(rawValue: row["label"]).map { ($0, row["asset_count"]) }
        })
      return AssetLabel.allCases.compactMap { label in
        counts[label].map { LabelSummary(label: label, assetCount: $0) }
      }
    }
  }

  /// How many of `identifiers` have live usage — the archive confirmation's
  /// "N still referenced".
  public static func liveUsageAssetCount(
    identifiers: [String], in database: DatabasePool
  ) async throws -> Int {
    try await database.read { db in
      let ids = try resolveAll(identifiers, db: db).compactMap(\.id)
      guard !ids.isEmpty else { return 0 }
      return try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(DISTINCT asset_id) FROM asset_live_usage
          WHERE asset_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
          """,
        arguments: StatementArguments(ids)) ?? 0
    }
  }

  static func favoriteIDs(among assets: [Asset], in db: GRDB.Database) throws -> Set<Int64> {
    let ids = assets.compactMap(\.id)
    guard !ids.isEmpty else { return [] }
    return Set(
      try Int64.fetchAll(
        db,
        sql: """
          SELECT id FROM asset
          WHERE favorite = 1 AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
          """,
        arguments: StatementArguments(ids)))
  }

  static func labelsByAssetID(
    for assets: [Asset], in db: GRDB.Database
  ) throws -> [Int64: [AssetLabel]] {
    let ids = assets.compactMap(\.id)
    guard !ids.isEmpty else { return [:] }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT asset_id, label FROM asset_label
        WHERE asset_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
        """,
      arguments: StatementArguments(ids))
    return Dictionary(grouping: rows, by: { $0["asset_id"] as Int64 }).mapValues { rows in
      let labels = Set(rows.compactMap { AssetLabel(rawValue: $0["label"]) })
      return AssetLabel.allCases.filter(labels.contains)
    }
  }

  /// The assets the identifiers name, in order, each once. Every identifier
  /// is tried, so the error lists all that did not resolve.
  static func resolveAll(_ identifiers: [String], db: GRDB.Database) throws -> [Asset] {
    try resolveNamed(identifiers, db: db).map(\.asset)
  }

  /// `resolveAll`, keeping with each asset the first identifier that named
  /// it: a key or prefix that still names that one asset alone.
  public static func resolveNamed(_ identifiers: [String], in database: DatabasePool) throws
    -> [(identifier: String, asset: Asset)]
  {
    try database.read { try resolveNamed(identifiers, db: $0) }
  }

  private static func resolveNamed(_ identifiers: [String], db: GRDB.Database) throws
    -> [(identifier: String, asset: Asset)]
  {
    var named: [(identifier: String, asset: Asset)] = []
    var seenIDs = Set<Int64>()
    var tried = Set<String>()
    var unresolved: [AssetCatalogError] = []
    for identifier in identifiers where tried.insert(identifier).inserted {
      do {
        guard let asset = try resolveInWrite(identifier, db: db), let id = asset.id else {
          throw AssetCatalogError.assetNotFound(identifier)
        }
        if seenIDs.insert(id).inserted { named.append((identifier, asset)) }
      } catch let error as AssetCatalogError {
        unresolved.append(error)
      }
    }
    guard unresolved.isEmpty else {
      throw AssetCatalogError.unresolvedIdentifiers(unresolved)
    }
    return named
  }

  static func curate(
    _ identifiers: [String], in database: DatabasePool, dryRun: Bool,
    _ apply: @escaping @Sendable (GRDB.Database, [Asset]) throws -> Void
  ) async throws -> [CurationChange] {
    try await database.writeWithoutTransaction { db in
      try curate(identifiers, db: db, dryRun: dryRun, apply)
    }
  }

  static func curate(
    _ identifiers: [String], in database: DatabasePool, dryRun: Bool,
    _ apply: (GRDB.Database, [Asset]) throws -> Void
  ) throws -> [CurationChange] {
    try database.writeWithoutTransaction { db in
      try curate(identifiers, db: db, dryRun: dryRun, apply)
    }
  }

  private static func curate(
    _ identifiers: [String], db: GRDB.Database, dryRun: Bool,
    _ apply: (GRDB.Database, [Asset]) throws -> Void
  ) throws -> [CurationChange] {
    var changes: [CurationChange] = []
    try db.inTransaction {
      let assets = try resolveAll(identifiers, db: db)
      let before = try curationStates(of: assets, db: db)
      try apply(db, assets)
      let after = try curationStates(of: assets, db: db)
      changes = zip(assets, zip(before, after)).map { asset, states in
        CurationChange(
          sha256: asset.sha256, key: asset.key, before: states.0, after: states.1)
      }
      return dryRun ? .rollback : .commit
    }
    return changes
  }

  /// In the order of `assets`, whose rows are read again.
  private static func curationStates(
    of assets: [Asset], db: GRDB.Database
  ) throws -> [CurationState] {
    let ids = assets.compactMap(\.id)
    guard !ids.isEmpty else { return [] }
    let current = try Asset.fetchAll(db, keys: ids)
    let states = Dictionary(uniqueKeysWithValues: current.map { ($0.id ?? -1, $0.state) })
    let favorites = try favoriteIDs(among: assets, in: db)
    let labels = try labelsByAssetID(for: assets, in: db)
    let memberships = try Row.fetchAll(
      db,
      sql: """
        SELECT ap.asset_id AS asset_id, p.slug AS slug
        FROM asset_project ap JOIN project p ON p.id = ap.project_id
        WHERE ap.asset_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
        ORDER BY p.slug
        """,
      arguments: StatementArguments(ids))
    let projects = Dictionary(grouping: memberships, by: { $0["asset_id"] as Int64 })
      .mapValues { rows in rows.map { $0["slug"] as String } }
    return ids.map { id in
      CurationState(
        state: states[id] ?? "", favorite: favorites.contains(id), labels: labels[id] ?? [],
        projects: projects[id] ?? [])
    }
  }
}
