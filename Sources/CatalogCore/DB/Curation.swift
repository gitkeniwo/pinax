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

/// Curation writes: archive and put back, favourite, colour labels. Every one
/// of them is a catalog row change and nothing else — no function here takes
/// a backend, and archiving never deletes a remote object.
extension CatalogAssets {
  /// Archive (`.archived`) or Put Back (`.active`). Stamps `updated_at`, so
  /// `changeStamp` moves and the Catalog tree refetches its counts.
  public static func setState(
    _ state: AssetState, for identifiers: [String], in database: DatabasePool, now: Date = Date()
  ) async throws {
    let date = timestamp(now)
    try await database.write { db in
      for id in try assetIDs(identifiers, db: db) {
        try db.execute(
          sql: "UPDATE asset SET state = ?, updated_at = ? WHERE id = ?",
          arguments: [state.rawValue, date, id])
      }
    }
  }

  public static func setFavorite(
    _ favorite: Bool, for identifiers: [String], in database: DatabasePool
  ) async throws {
    try await database.write { db in
      for id in try assetIDs(identifiers, db: db) {
        try db.execute(
          sql: "UPDATE asset SET favorite = ? WHERE id = ?", arguments: [favorite, id])
      }
    }
  }

  public static func setLabel(
    _ label: AssetLabel, _ applied: Bool, for identifiers: [String], in database: DatabasePool
  ) async throws {
    try await database.write { db in
      for id in try assetIDs(identifiers, db: db) {
        if applied {
          try db.execute(
            sql: "INSERT INTO asset_label (asset_id, label) VALUES (?, ?) ON CONFLICT DO NOTHING",
            arguments: [id, label.rawValue])
        } else {
          try db.execute(
            sql: "DELETE FROM asset_label WHERE asset_id = ? AND label = ?",
            arguments: [id, label.rawValue])
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
      let ids = try assetIDs(identifiers, db: db)
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

  private static func assetIDs(_ identifiers: [String], db: GRDB.Database) throws -> [Int64] {
    try identifiers.map { identifier in
      guard let id = try resolveInWrite(identifier, db: db)?.id else {
        throw AssetCatalogError.assetNotFound(identifier)
      }
      return id
    }
  }
}
