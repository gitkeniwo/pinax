import CatalogCore
import Foundation
import GRDB

/// What the Delete Permanently… sheet needs to know about one selected
/// asset. Catalog data only: nothing here comes from
/// the bucket.
public struct DeletionFacts: Equatable, Sendable {
  public let sha256: String
  public let key: String
  public let byteSize: Int64
  public let isArchived: Bool
  public let backendSlug: String
  public let bucket: String
  /// The projects it belongs to, by slug.
  public let projects: [String]
  /// `meta.imported_from` (PicGo, a claimed external): Pinax cannot prove
  /// it wrote these bytes, so the object stays and only the row goes.
  public let importedFrom: String?
  /// The scanned files that still reference it, across every project
  /// (a lower bound: Pinax sees only scanned sources).
  public let usedInFiles: [String]
  /// Live references inside each project, by slug.
  public let liveUsageByProject: [String: Int]

  public init(
    sha256: String, key: String, byteSize: Int64, isArchived: Bool, backendSlug: String,
    bucket: String, projects: [String], importedFrom: String? = nil, usedInFiles: [String] = [],
    liveUsageByProject: [String: Int] = [:]
  ) {
    self.sha256 = sha256
    self.key = key
    self.byteSize = byteSize
    self.isArchived = isArchived
    self.backendSlug = backendSlug
    self.bucket = bucket
    self.projects = projects
    self.importedFrom = importedFrom
    self.usedInFiles = usedInFiles
    self.liveUsageByProject = liveUsageByProject
  }

  public var deletesRemote: Bool { importedFrom == nil }
}

/// A tombstone still owed a delete, as the Archived banner shows it.
public struct UnfinishedDeletion: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let key: String
  public let sha256: String
  public let bucket: String
  public let phase: DeletionPhase
  public let lastError: String?
}

/// The one GUI path to `CatalogDeletion` (README rule 1). It holds the
/// database and the remote factory; the gallery calls `stage`, `purge`,
/// `resume` and `restore` only after the user confirmed in the sheet or
/// pressed Retry / Restore to Library on the banner — never on launch.
public struct DeletingCatalog: Sendable {
  private let database: DatabasePool
  private let remote: DeletionRemote

  public init(database: DatabasePool, remote: @escaping DeletionRemote) {
    self.database = database
    self.remote = remote
  }

  /// The app's remote: the backend's Keychain credentials, one
  /// `S3ObjectDeleter` per backend.
  public static func keychainRemote(_ backend: Backend) throws -> any ObjectDeleting {
    guard let credentials = try Keychain().load(for: backend.keychainRef) else {
      throw DeletingCatalogError.missingCredentials(backend.slug)
    }
    return S3ObjectDeleter(backend: backend, credentials: credentials)
  }

  public func facts(for identifiers: [String]) async throws -> [DeletionFacts] {
    try await database.read { db in
      try identifiers.compactMap { identifier -> DeletionFacts? in
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT a.id, a.sha256, a.key, a.byte_size, a.state, a.meta, b.slug, b.bucket
              FROM asset a JOIN backend b ON b.id = a.backend_id
              WHERE a.sha256 = ? ORDER BY a.id LIMIT 1
              """, arguments: [identifier])
        else { return nil }
        let assetID: Int64 = row["id"]
        let projects = try String.fetchAll(
          db,
          sql: """
            SELECT p.slug FROM asset_project ap JOIN project p ON p.id = ap.project_id
            WHERE ap.asset_id = ? ORDER BY p.slug
            """, arguments: [assetID])
        let live = try Row.fetchAll(
          db,
          sql: """
            SELECT p.slug, l.n FROM asset_live_usage l JOIN project p ON p.id = l.project_id
            WHERE l.asset_id = ?
            """, arguments: [assetID])
        let references = try String.fetchAll(
          db,
          sql: """
            SELECT DISTINCT u.source_ref FROM usage u JOIN project p ON p.id = u.project_id
            WHERE u.asset_id = ? AND u.last_scan_id IS NOT NULL AND u.last_scan_id = p.last_scan_id
            """, arguments: [assetID])
        let meta = (row["meta"] as String?).flatMap {
          try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        return DeletionFacts(
          sha256: row["sha256"], key: row["key"], byteSize: row["byte_size"],
          isArchived: (row["state"] as String) == AssetState.archived.rawValue,
          backendSlug: row["slug"], bucket: row["bucket"], projects: projects,
          importedFrom: meta?["imported_from"] as? String,
          usedInFiles: Array(Set(references.map(Self.file(of:)))).sorted(),
          liveUsageByProject: Dictionary(
            uniqueKeysWithValues: live.map { ($0["slug"] as String, $0["n"] as Int) }))
      }
    }
  }

  /// "blog/posts/a.md#L12" → "blog/posts/a.md": a reference names a line;
  /// the sheet counts files.
  static func file(of sourceReference: String) -> String {
    guard let hash = sourceReference.lastIndex(of: "#") else { return sourceReference }
    return String(sourceReference[..<hash])
  }

  /// Stages the deletable ones and removes the rest from the catalog only,
  /// in that order; returns the tombstones owed a delete. The sheet already
  /// warned about live usage, so both pass `includeUsed`.
  public func stage(deleting: [String], keeping: [String]) throws -> [Int64] {
    var staged: [DeletionCandidate] = []
    if !deleting.isEmpty {
      staged = try CatalogDeletion.stage(deleting, in: database, includeUsed: true)
    }
    if !keeping.isEmpty {
      try CatalogDeletion.removeFromCatalogOnly(keeping, in: database, includeUsed: true)
    }
    let wanted = Set(staged.map { "\($0.backendSlug)\u{0}\($0.key)" })
    return try CatalogDeletion.pending(in: database)
      .filter { !$0.keepRemote && wanted.contains("\($0.backendSlug)\u{0}\($0.key)") }
      .map(\.id)
  }

  public func purge(_ id: Int64) async throws -> PurgeResult? {
    try await CatalogDeletion.purge([id], in: database, remote: remote).first
  }

  public func resume() async throws -> [PurgeResult] {
    try await CatalogDeletion.resume(in: database, remote: remote)
  }

  public func restore(_ id: Int64) async throws {
    try await CatalogDeletion.restore(id, in: database, remote: remote)
  }

  /// Every tombstone still owed a delete; `keep_remote` ones are finished.
  public func unfinished() async throws -> [UnfinishedDeletion] {
    let rows = try CatalogDeletion.pending(in: database).filter { !$0.keepRemote }
    let buckets = try await database.read { db in
      try Dictionary(
        uniqueKeysWithValues: Backend.fetchAll(db).map { ($0.id ?? -1, $0.bucket) })
    }
    return rows.map {
      UnfinishedDeletion(
        id: $0.id, key: $0.key, sha256: $0.sha256, bucket: buckets[$0.backendID] ?? $0.backendSlug,
        phase: $0.phase, lastError: $0.lastError)
    }
  }
}

public enum DeletingCatalogError: Error, Equatable, CustomStringConvertible {
  case missingCredentials(String)

  public var description: String {
    switch self {
    case let .missingCredentials(slug):
      return "No credentials for backend '\(slug)' in Keychain."
    }
  }
}
