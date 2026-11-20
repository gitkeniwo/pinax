import Foundation
import GRDB

public enum CatalogDeletionError: Error, Equatable, CustomStringConvertible {
  case tooMany(Int, limit: Int)
  case notArchived([String])
  case unsafeKey(String, reason: String)
  case sharedKey(String, backends: [String])
  /// key → live references. Returned, never decided here: the CLI refuses,
  /// the GUI warns; `includeUsed` is the caller's answer.
  case stillUsed([String: Int])
  case noSuchPendingDeletion(Int64)
  case restoreNeedsRemoteCheck(String)
  case objectGone(String)
  case objectNotOurs(String)
  case restoreConflict(String)

  public var description: String {
    switch self {
    case let .tooMany(count, limit):
      return "\(count) assets requested; at most \(limit) can be deleted per confirmation."
    case let .notArchived(keys):
      return "Archive first; only archived assets can be deleted: \(keys.joined(separator: ", "))"
    case let .unsafeKey(key, reason):
      return "Refusing to delete key '\(key)': \(reason)."
    case let .sharedKey(key, backends):
      return
        "Backends \(backends.joined(separator: ", ")) name the same bucket and key '\(key)'; "
        + "deleting it would break the other."
    case let .stillUsed(counts):
      let list = counts.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }
      return "Still referenced: \(list.joined(separator: ", "))"
    case let .noSuchPendingDeletion(id):
      return "No pending deletion \(id)."
    case let .restoreNeedsRemoteCheck(key):
      return "A delete was already sent for '\(key)'; check the bucket before restoring it."
    case let .objectGone(key):
      return "'\(key)' is no longer in the bucket; it cannot be restored."
    case let .objectNotOurs(key):
      return "The object at '\(key)' is not the one Pinax deleted; it cannot be restored."
    case let .restoreConflict(key):
      return "The catalog already holds '\(key)' or the same image on its backend."
    }
  }
}

public enum DeletionPhase: String, Codable, Sendable {
  /// No delete has been sent; the object is where it was.
  case staged
  /// The HEAD showed bytes Pinax did not write; no delete was sent.
  case refused
  /// A delete was sent at least once; the object may be gone.
  case deleteSent = "delete_sent"
  /// Removed from the catalog only; the object stays (`keep_remote`).
  case kept
}

/// One asset a deletion would take, with what it leaves behind.
public struct DeletionCandidate: Equatable, Sendable {
  public let assetID: Int64
  public let backendSlug: String
  public let bucket: String
  public let key: String
  public let sha256: String
  public let byteSize: Int64
  public let projects: [String]
  /// Live references across every project. A lower bound: Pinax sees only
  /// scanned sources.
  public let liveUsage: Int
}

/// A tombstone: a row removed from the catalog whose object is still owed a
/// delete, or (`keepRemote`) stays in the bucket for good.
public struct PendingDeletion: Equatable, Sendable {
  public let id: Int64
  public let backendID: Int64
  public let backendSlug: String
  public let key: String
  public let sha256: String
  public let byteSize: Int64
  public let keepRemote: Bool
  public let phase: DeletionPhase
  public let attempts: Int
  public let lastError: String?
  public let requestedAt: String
  public let updatedAt: String
}

public enum PurgeOutcome: Equatable, Sendable {
  case deleted(versioned: Bool)
  /// The HEAD found nothing (deleted in the console, or by an earlier run).
  case alreadyGone
  /// A catalog row names this bucket and key again; nothing was sent.
  case superseded
  /// The object's `x-amz-meta-sha256` is not this row's; nothing was sent.
  case refusedMismatch(found: String?)
  case failed(String)
}

public struct PurgeResult: Equatable, Sendable {
  public let id: Int64
  public let backendSlug: String
  public let key: String
  public let outcome: PurgeOutcome
}

public typealias DeletionRemote = @Sendable (Backend) throws -> any ObjectDeleting

/// The one place Pinax deletes: archived, named assets the user confirmed.
/// `stage` removes the rows and leaves a tombstone in one
/// transaction; `purge` then deletes each object after a HEAD proves Pinax
/// wrote it, and drops the tombstone only once a HEAD finds it gone.
public enum CatalogDeletion {
  public static let limit = 100

  /// The checks of `stage`, without writing.
  public static func plan(
    _ identifiers: [String], in database: DatabasePool, includeUsed: Bool = false,
    keepRemote: Bool = false
  ) throws -> [DeletionCandidate] {
    try database.read { db in
      try check(identifiers, db: db, includeUsed: includeUsed, keepRemote: keepRemote).map(\.1)
    }
  }

  /// One write transaction: every guard, then a tombstone per asset and the
  /// row deleted (memberships, tags and labels cascade; usage keeps its rows
  /// with `asset_id` NULL). Any failed guard writes nothing.
  @discardableResult
  public static func stage(
    _ identifiers: [String], in database: DatabasePool, includeUsed: Bool = false,
    now: Date = Date()
  ) throws -> [DeletionCandidate] {
    try write(identifiers, in: database, includeUsed: includeUsed, keepRemote: false, now: now)
  }

  /// Like `stage`, but the objects stay in the bucket: the tombstone is
  /// kept for good so `reindex` does not bring the rows back. No request.
  @discardableResult
  public static func removeFromCatalogOnly(
    _ identifiers: [String], in database: DatabasePool, includeUsed: Bool = false,
    now: Date = Date()
  ) throws -> [DeletionCandidate] {
    try write(identifiers, in: database, includeUsed: includeUsed, keepRemote: true, now: now)
  }

  public static func pending(in database: DatabasePool) throws -> [PendingDeletion] {
    try database.read { try pending($0) }
  }

  /// Per tombstone (all owed deletes when `ids` is nil): HEAD must show this
  /// row's sha256 → one DELETE → HEAD must find nothing. Each key stands
  /// alone; a failure keeps its tombstone with the error for the next run.
  public static func purge(
    _ ids: [Int64]? = nil, in database: DatabasePool, remote: DeletionRemote,
    now: Date = Date()
  ) async throws -> [PurgeResult] {
    let wanted = ids.map(Set.init)
    let rows = try await database.read { db in
      try pending(db).filter { !$0.keepRemote && (wanted?.contains($0.id) ?? true) }
    }
    let backends = try await database.read { db in
      try Dictionary(uniqueKeysWithValues: Backend.fetchAll(db).map { ($0.id ?? -1, $0) })
    }
    var deleters: [Int64: Result<any ObjectDeleting, Error>] = [:]
    var results: [PurgeResult] = []
    for row in rows {
      let outcome: PurgeOutcome
      if try await database.read({ try isNamedByRow(row, db: $0) }) {
        outcome = .superseded
      } else {
        do {
          if deleters[row.backendID] == nil {
            guard let backend = backends[row.backendID] else {
              throw CatalogDeletionError.noSuchPendingDeletion(row.id)
            }
            deleters[row.backendID] = Result { try remote(backend) }
          }
          let deleter = try deleters[row.backendID]!.get()
          outcome = try await purgeOne(row, deleter: deleter, database: database, now: now)
        } catch {
          outcome = .failed(String(describing: error))
        }
      }
      try await record(outcome, for: row, in: database, now: now)
      results.append(PurgeResult(id: row.id, backendSlug: row.backendSlug, key: row.key, outcome: outcome))
    }
    return results
  }

  /// Carries on every owed delete (after a failure, a quit or no network).
  public static func resume(
    in database: DatabasePool, remote: DeletionRemote, now: Date = Date()
  ) async throws -> [PurgeResult] {
    try await purge(nil, in: database, remote: remote, now: now)
  }

  /// Puts a tombstone's row back (with its projects, tags, labels and
  /// usage links) — only while its object is certainly still there: no
  /// delete was ever sent, or a HEAD through `remote` finds Pinax's bytes.
  @discardableResult
  public static func restore(
    _ id: Int64, in database: DatabasePool, remote: DeletionRemote? = nil, now: Date = Date()
  ) async throws -> Asset {
    let row = try await database.read { db in
      try pending(db).first { $0.id == id }
    }
    guard let row else { throw CatalogDeletionError.noSuchPendingDeletion(id) }
    if row.phase == .deleteSent {
      guard let remote else { throw CatalogDeletionError.restoreNeedsRemoteCheck(row.key) }
      let backend = try await database.read { try Backend.fetchOne($0, key: row.backendID) }
      guard let backend else { throw CatalogDeletionError.noSuchPendingDeletion(id) }
      switch try await remote(backend).head(key: row.key) {
      case .absent:
        throw CatalogDeletionError.objectGone(row.key)
      case let .present(sha) where sha?.lowercased() != row.sha256.lowercased():
        throw CatalogDeletionError.objectNotOurs(row.key)
      case .present:
        break
      }
    }
    return try await database.write { db in
      guard
        let snapshot = try String.fetchOne(
          db, sql: "SELECT snapshot FROM pending_deletion WHERE id = ? AND phase = ?",
          arguments: [id, row.phase.rawValue])
      else { throw CatalogDeletionError.noSuchPendingDeletion(id) }
      let asset = try putBack(snapshot, key: row.key, db: db)
      try db.execute(sql: "DELETE FROM pending_deletion WHERE id = ?", arguments: [id])
      return asset
    }
  }

  // MARK: - Staging

  private static func write(
    _ identifiers: [String], in database: DatabasePool, includeUsed: Bool, keepRemote: Bool,
    now: Date
  ) throws -> [DeletionCandidate] {
    let stamp = CatalogAssets.timestamp(now)
    return try database.write { db in
      let checked = try check(identifiers, db: db, includeUsed: includeUsed, keepRemote: keepRemote)
      for (asset, _) in checked {
        guard let assetID = asset.id else { continue }
        let snapshot = try snapshot(of: assetID, db: db)
        // An older tombstone for this key (kept, or superseded by this row's
        // re-upload) is replaced: this row is what names the key now.
        try db.execute(
          sql: "DELETE FROM pending_deletion WHERE backend_id = ? AND key = ?",
          arguments: [asset.backendID, asset.key])
        try db.execute(
          sql: """
            INSERT INTO pending_deletion
              (backend_id, key, sha256, byte_size, keep_remote, phase, snapshot,
               requested_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            asset.backendID, asset.key, asset.sha256, asset.byteSize, keepRemote,
            (keepRemote ? DeletionPhase.kept : .staged).rawValue, snapshot, stamp, stamp,
          ])
        let tagIDs = try Int64.fetchAll(
          db, sql: "SELECT tag_id FROM asset_tag WHERE asset_id = ?", arguments: [assetID])
        try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [assetID])
        // As `tag rm`: a tag no asset carries any more goes too.
        for tagID in tagIDs {
          try db.execute(
            sql: """
              DELETE FROM tag WHERE id = ?
                AND NOT EXISTS (SELECT 1 FROM asset_tag WHERE tag_id = tag.id)
              """, arguments: [tagID])
        }
      }
      return checked.map(\.1)
    }
  }

  private static func check(
    _ identifiers: [String], db: GRDB.Database, includeUsed: Bool, keepRemote: Bool
  ) throws -> [(Asset, DeletionCandidate)] {
    var seen = Set<String>()
    let unique = identifiers.filter { seen.insert($0).inserted }
    guard unique.count <= limit else {
      throw CatalogDeletionError.tooMany(unique.count, limit: limit)
    }
    // Every identifier resolves, or nothing is written.
    var assets: [Asset] = []
    for identifier in unique {
      guard let asset = try CatalogAssets.resolveInWrite(identifier, db: db) else {
        throw AssetCatalogError.assetNotFound(identifier)
      }
      if !assets.contains(where: { $0.id == asset.id }) { assets.append(asset) }
    }
    let active = assets.filter { $0.state != AssetState.archived.rawValue }
    guard active.isEmpty else { throw CatalogDeletionError.notArchived(active.map(\.key)) }

    var checked: [(Asset, DeletionCandidate)] = []
    var used: [String: Int] = [:]
    for asset in assets {
      guard let assetID = asset.id, let backend = try Backend.fetchOne(db, key: asset.backendID)
      else { throw AssetCatalogError.assetNotFound(asset.key) }
      if !keepRemote {
        if let reason = DeletionKeyGuard.problem(asset.key) {
          throw CatalogDeletionError.unsafeKey(asset.key, reason: reason)
        }
        let twins = try String.fetchAll(
          db,
          sql: """
            SELECT b.slug FROM asset a JOIN backend b ON b.id = a.backend_id
            WHERE a.id != ? AND a.key = ? AND \(sameBucket("b", backendID: "?"))
            ORDER BY b.slug
            """, arguments: [assetID, asset.key, asset.backendID])
        if !twins.isEmpty {
          throw CatalogDeletionError.sharedKey(asset.key, backends: [backend.slug] + twins)
        }
      }
      let live =
        try Int.fetchOne(
          db, sql: "SELECT IFNULL(SUM(n), 0) FROM asset_live_usage WHERE asset_id = ?",
          arguments: [assetID]) ?? 0
      if live > 0 { used[asset.key] = live }
      let projects = try String.fetchAll(
        db,
        sql: """
          SELECT p.slug FROM asset_project ap JOIN project p ON p.id = ap.project_id
          WHERE ap.asset_id = ? ORDER BY p.slug
          """, arguments: [assetID])
      checked.append(
        (
          asset,
          DeletionCandidate(
            assetID: assetID, backendSlug: backend.slug, bucket: backend.bucket, key: asset.key,
            sha256: asset.sha256, byteSize: asset.byteSize, projects: projects, liveUsage: live)
        ))
    }
    if !used.isEmpty, !includeUsed { throw CatalogDeletionError.stillUsed(used) }
    return checked
  }

  /// SQL: backend `alias` points at the same endpoint and bucket as the
  /// backend whose id is bound at `backendID`.
  private static func sameBucket(_ alias: String, backendID: String) -> String {
    """
    EXISTS (SELECT 1 FROM backend mine WHERE mine.id = \(backendID)
      AND rtrim(lower(\(alias).endpoint), '/') = rtrim(lower(mine.endpoint), '/')
      AND \(alias).bucket = mine.bucket)
    """
  }

  /// A row (re-uploaded, restored from a backup, reindexed) names this
  /// bucket and key again: the object is that row's now.
  private static func isNamedByRow(_ row: PendingDeletion, db: GRDB.Database) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS (SELECT 1 FROM asset a JOIN backend b ON b.id = a.backend_id
          WHERE a.key = ? AND \(sameBucket("b", backendID: "?")))
        """, arguments: [row.key, row.backendID]) ?? true
  }

  // MARK: - Purging

  private static func purgeOne(
    _ row: PendingDeletion, deleter: any ObjectDeleting, database: DatabasePool, now: Date
  ) async throws -> PurgeOutcome {
    switch try await deleter.head(key: row.key) {
    case .absent:
      return .alreadyGone
    case let .present(sha) where sha?.lowercased() != row.sha256.lowercased():
      return .refusedMismatch(found: sha)
    case .present:
      break
    }
    // Written before the request: from here on the object may be gone.
    try await database.write { db in
      try db.execute(
        sql: "UPDATE pending_deletion SET phase = ?, updated_at = ? WHERE id = ?",
        arguments: [DeletionPhase.deleteSent.rawValue, CatalogAssets.timestamp(now), row.id])
    }
    let receipt = try await deleter.delete(key: row.key)
    switch try await deleter.head(key: row.key) {
    case .absent:
      return .deleted(versioned: receipt.versioned)
    case .present:
      return .failed("The object is still there after the delete.")
    }
  }

  private static func record(
    _ outcome: PurgeOutcome, for row: PendingDeletion, in database: DatabasePool, now: Date
  ) async throws {
    let stamp = CatalogAssets.timestamp(now)
    try await database.write { db in
      switch outcome {
      case .deleted, .alreadyGone, .superseded:
        try db.execute(sql: "DELETE FROM pending_deletion WHERE id = ?", arguments: [row.id])
      case let .refusedMismatch(found):
        let message =
          "Not deleted: the object's x-amz-meta-sha256 is \(found.map { "'\($0)'" } ?? "missing"), "
          + "so Pinax did not write it. Restore it to the library, or delete it in the console."
        try db.execute(
          sql: """
            UPDATE pending_deletion
            SET phase = CASE phase WHEN 'staged' THEN 'refused' ELSE phase END,
                attempts = attempts + 1, last_error = ?, updated_at = ?
            WHERE id = ?
            """, arguments: [message, stamp, row.id])
      case let .failed(message):
        try db.execute(
          sql: """
            UPDATE pending_deletion SET attempts = attempts + 1, last_error = ?, updated_at = ?
            WHERE id = ?
            """, arguments: [message, stamp, row.id])
      }
    }
  }

  static func pending(_ db: GRDB.Database) throws -> [PendingDeletion] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT d.*, b.slug AS backend_slug FROM pending_deletion d
        JOIN backend b ON b.id = d.backend_id ORDER BY d.id
        """
    ).map { row in
      PendingDeletion(
        id: row["id"], backendID: row["backend_id"], backendSlug: row["backend_slug"],
        key: row["key"], sha256: row["sha256"], byteSize: row["byte_size"],
        keepRemote: row["keep_remote"],
        phase: DeletionPhase(rawValue: row["phase"]) ?? .staged, attempts: row["attempts"],
        lastError: row["last_error"], requestedAt: row["requested_at"],
        updatedAt: row["updated_at"])
    }
  }

  // MARK: - Snapshot

  /// The whole asset row, plus what cascades away with it, as JSON.
  private static func snapshot(of assetID: Int64, db: GRDB.Database) throws -> String {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE id = ?", arguments: [assetID])
    else { throw AssetCatalogError.assetNotFound(String(assetID)) }
    var asset: [String: Any] = [:]
    for (column, value) in row {
      switch value.storage {
      case .null: asset[column] = NSNull()
      case let .int64(number): asset[column] = number
      case let .double(number): asset[column] = number
      case let .string(text): asset[column] = text
      case let .blob(data): asset[column] = data.base64EncodedString()
      }
    }
    let projects = try Row.fetchAll(
      db, sql: "SELECT project_id, added_at FROM asset_project WHERE asset_id = ? ORDER BY project_id",
      arguments: [assetID]
    ).map { ["project_id": $0["project_id"] as Int64, "added_at": $0["added_at"] as String] as [String: Any] }
    let tags = try String.fetchAll(
      db,
      sql: "SELECT t.name FROM asset_tag at JOIN tag t ON t.id = at.tag_id WHERE at.asset_id = ? ORDER BY t.name",
      arguments: [assetID])
    let labels = try String.fetchAll(
      db, sql: "SELECT label FROM asset_label WHERE asset_id = ? ORDER BY label", arguments: [assetID])
    let usage = try Int64.fetchAll(
      db, sql: "SELECT id FROM usage WHERE asset_id = ? ORDER BY id", arguments: [assetID])
    let document: [String: Any] = [
      "asset": asset, "projects": projects, "tags": tags, "labels": labels, "usage_ids": usage,
    ]
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  private static func putBack(_ snapshot: String, key: String, db: GRDB.Database) throws -> Asset {
    guard
      let document = try JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any],
      var asset = document["asset"] as? [String: Any]
    else { throw CatalogDeletionError.restoreConflict(key) }
    let columns = Set(try db.columns(in: "asset").map(\.name))
    if let id = asset["id"] as? NSNumber,
      try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM asset WHERE id = ?)", arguments: [id.int64Value])
        == true
    {
      asset["id"] = nil
    }
    let names = asset.keys.filter(columns.contains).sorted()
    let values: [DatabaseValue] = names.map { name in
      switch asset[name] {
      case let number as NSNumber:
        return CFNumberIsFloatType(number) ? number.doubleValue.databaseValue : number.int64Value.databaseValue
      case let text as String: return text.databaseValue
      default: return .null
      }
    }
    do {
      try db.execute(
        sql: "INSERT INTO asset (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
        arguments: StatementArguments(values))
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw CatalogDeletionError.restoreConflict(key)
    }
    let assetID = db.lastInsertedRowID
    for project in document["projects"] as? [[String: Any]] ?? [] {
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO asset_project (asset_id, project_id, added_at)
          SELECT ?, id, ? FROM project WHERE id = ?
          """,
        arguments: [assetID, project["added_at"] as? String, (project["project_id"] as? NSNumber)?.int64Value])
    }
    for tag in document["tags"] as? [String] ?? [] {
      try db.execute(sql: "INSERT OR IGNORE INTO tag (name) VALUES (?)", arguments: [tag])
      try db.execute(
        sql: "INSERT OR IGNORE INTO asset_tag (asset_id, tag_id) SELECT ?, id FROM tag WHERE name = ?",
        arguments: [assetID, tag])
    }
    for label in document["labels"] as? [String] ?? [] {
      try db.execute(
        sql: "INSERT OR IGNORE INTO asset_label (asset_id, label) VALUES (?, ?)",
        arguments: [assetID, label])
    }
    for usageID in (document["usage_ids"] as? [NSNumber] ?? []).map(\.int64Value) {
      try db.execute(
        sql: "UPDATE usage SET asset_id = ? WHERE id = ? AND asset_id IS NULL",
        arguments: [assetID, usageID])
    }
    guard let restored = try Asset.fetchOne(db, key: assetID) else {
      throw CatalogDeletionError.restoreConflict(key)
    }
    return restored
  }
}
