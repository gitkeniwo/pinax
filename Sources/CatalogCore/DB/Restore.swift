import Foundation
import GRDB

/// Rows per table: a backup's, or a catalog's. The same ten tables
/// `CatalogBackups.create` exports, plus the favourite flag it carries
/// beside them.
public struct CatalogTableCounts: Equatable, Sendable {
  public var backends = 0
  public var backendPrefixHistory = 0
  public var assets = 0
  public var projects = 0
  public var assetProjects = 0
  public var tags = 0
  public var assetTags = 0
  public var scans = 0
  public var usages = 0
  public var assetLabels = 0
  public var favorites = 0

  public init() {}

  public init(_ tables: CatalogBackupTables) {
    backends = tables.backends.count
    backendPrefixHistory = tables.backendPrefixHistory.count
    assets = tables.assets.count
    projects = tables.projects.count
    assetProjects = tables.assetProjects.count
    tags = tables.tags.count
    assetTags = tables.assetTags.count
    scans = tables.scans.count
    usages = tables.usages.count
    assetLabels = tables.assetLabels.count
    favorites = tables.assetFavorites.count
  }

  /// The ten tables, by their SQLite names, in restore order.
  public var tables: [(name: String, count: Int)] {
    [
      ("backend", backends), ("backend_prefix_history", backendPrefixHistory),
      ("asset", assets), ("project", projects), ("asset_project", assetProjects),
      ("tag", tags), ("asset_tag", assetTags), ("scan", scans), ("usage", usages),
      ("asset_label", assetLabels),
    ]
  }

  /// No row in any of the ten tables: the only catalog a restore writes to.
  public var isEmpty: Bool { tables.allSatisfy { $0.count == 0 } }

  /// "tag 1, asset 3" — the non-empty tables, for messages.
  public var nonEmptyDescription: String {
    tables.filter { $0.count > 0 }.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
  }
}

public enum CatalogRestoreError: Error, Equatable, LocalizedError, CustomStringConvertible {
  case unsupportedSchema(Int)
  /// The backup lists migrations this app does not have.
  case newerVersion(unknownMigrations: [String])
  /// Every migration is known, but not as a prefix of this catalog's.
  case incompatibleMigrations([String])
  case catalogNotEmpty(CatalogTableCounts)
  /// The catalog to replace no longer holds what the user confirmed.
  case catalogChanged(CatalogTableCounts)
  case integrity(String)

  public var description: String {
    switch self {
    case .unsupportedSchema(let schema):
      return "This backup uses format \(schema); this version of Pinax reads format 1."
    case .newerVersion(let names):
      return "This backup comes from a newer version of Pinax (\(names.joined(separator: ", "))). "
        + "Update Pinax, then restore."
    case .incompatibleMigrations(let names):
      return "This backup's schema history (\(names.joined(separator: ", "))) "
        + "does not match this catalog's."
    case .catalogNotEmpty(let counts):
      return "Pinax restores only into an empty catalog; this one has "
        + "\(counts.nonEmptyDescription). To replace it, quit Pinax, move catalog.sqlite "
        + "out of its folder, open Pinax again, and restore."
    case .catalogChanged(let counts):
      return "The catalog changed after you confirmed (it now has \(counts.nonEmptyDescription)). "
        + "Nothing was replaced; start the restore again."
    case .integrity(let detail):
      return "The backup could not be restored: \(detail). The catalog was left as it was."
    }
  }

  public var errorDescription: String? { description }
}

/// What a restored catalog still needs on this Mac: credentials live
/// in the Keychain and source folders are absolute paths, so neither moves
/// with the backup.
public struct CatalogRestoreFollowUps: Equatable, Sendable {
  public struct MissingSources: Equatable, Sendable {
    public let projectSlug: String
    public let projectName: String
    public let paths: [String]
  }

  /// Slugs of the backends with no credentials on this Mac.
  public let backendsWithoutCredentials: [String]
  public let projectsWithMissingSources: [MissingSources]

  public var isEmpty: Bool {
    backendsWithoutCredentials.isEmpty && projectsWithMissingSources.isEmpty
  }
}

extension CatalogBackups {
  static let favoriteLabelMigration = "v2_favorite_label"

  /// Decodes a backup file, accepting the pre-`v2_favorite_label` shape.
  public static func decode(_ data: Data) throws -> CatalogBackup {
    try JSONDecoder().decode(CatalogBackup.self, from: data)
  }

  /// The version check, without writing: run before asking
  /// the user to confirm.
  public static func validate(_ backup: CatalogBackup, for database: CatalogDatabasePool) throws {
    let applied = try database.read { try appliedMigrations($0) }
    try validate(backup, applied: applied)
  }

  /// Rows per table in a catalog.
  public static func counts(in database: CatalogDatabasePool) throws -> CatalogTableCounts {
    try database.read { try counts($0) }
  }

  /// Restores a whole catalog into an empty one, keeping every id. One write
  /// transaction: on any failure nothing is written. Never touches the
  /// network, the object store, the Keychain, or preferences.
  @discardableResult
  public static func restore(
    _ backup: CatalogBackup, into database: CatalogDatabasePool
  ) throws -> CatalogTableCounts {
    try database.write { db in
      try validate(backup, applied: try appliedMigrations(db))
      let existing = try counts(db)
      guard existing.isEmpty else {
        throw CatalogRestoreError.catalogNotEmpty(existing)
      }
      return try insert(backup, db)
    }
  }

  /// The tables a restore writes, children first.
  static let replacedTables = [
    "asset_label", "asset_tag", "asset_project", "usage", "scan", "tag", "project",
    "asset", "backend_prefix_history", "backend",
  ]

  /// Replaces the whole catalog with the backup, keeping every id: the rows
  /// are cleared and the backup written in one write transaction, so on any
  /// failure the catalog is left exactly as it was. `confirmed` is what the
  /// user agreed to replace; a catalog that holds anything else is refused.
  /// Never touches the network, the object store, the Keychain, or
  /// preferences.
  @discardableResult
  public static func replace(
    _ backup: CatalogBackup, into database: CatalogDatabasePool,
    confirmed: CatalogTableCounts
  ) throws -> CatalogTableCounts {
    try database.write { db in
      try validate(backup, applied: try appliedMigrations(db))
      let existing = try counts(db)
      guard existing == confirmed else {
        throw CatalogRestoreError.catalogChanged(existing)
      }
      try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
      for table in replacedTables {
        try db.execute(sql: "DELETE FROM \(table)")
      }
      return try insert(backup, db)
    }
  }

  /// Writes every row of the backup into a catalog with no rows, then checks
  /// references and counts; throws (rolling the transaction back) on any gap.
  private static func insert(
    _ backup: CatalogBackup, _ db: GRDB.Database
  ) throws -> CatalogTableCounts {
    // project.last_scan_id → scan and scan.project_id → project form a
    // cycle; checked at commit instead of per row.
    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
    let tables = backup.tables
    for var row in tables.backends { try row.insert(db) }
    for var row in tables.backendPrefixHistory { try row.insert(db) }
    for var row in tables.assets { try row.insert(db) }
    for var row in tables.projects { try row.insert(db) }
    for var row in tables.assetProjects { try row.insert(db) }
    for var row in tables.tags { try row.insert(db) }
    for var row in tables.assetTags { try row.insert(db) }
    for var row in tables.scans { try row.insert(db) }
    for var row in tables.usages { try row.insert(db) }
    for id in tables.assetFavorites {
      try db.execute(sql: "UPDATE asset SET favorite = 1 WHERE id = ?", arguments: [id])
    }
    for label in tables.assetLabels {
      try db.execute(
        sql: "INSERT INTO asset_label (asset_id, label) VALUES (?, ?)",
        arguments: [label.assetID, label.label])
    }

    let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
    if let first = violations.first {
      let table: String = first["table"] ?? "?"
      let parent: String = first["parent"] ?? "?"
      let rowID: Int64? = first["rowid"]
      throw CatalogRestoreError.integrity(
        "\(violations.count) broken reference(s), first in \(table) row \(rowID.map(String.init) ?? "?") → \(parent)"
      )
    }
    let restored = try counts(db)
    let expected = CatalogTableCounts(tables)
    guard restored == expected else {
      throw CatalogRestoreError.integrity(
        "restored \(restored.nonEmptyDescription), favorite \(restored.favorites); "
          + "backup has \(expected.nonEmptyDescription), favorite \(expected.favorites)")
    }
    return restored
  }

  /// The backends without credentials and the projects whose source folders
  /// are not on this Mac. `credentialExists` takes a keychain reference.
  public static func followUps(
    in database: CatalogDatabasePool,
    credentialExists: (String) throws -> Bool,
    folderExists: (String) -> Bool = CatalogBackups.directoryExists
  ) throws -> CatalogRestoreFollowUps {
    let (backends, projects) = try database.read { db in
      (
        try Backend.order(Column("id")).fetchAll(db),
        try Project.order(Column("id")).fetchAll(db)
      )
    }
    return CatalogRestoreFollowUps(
      backendsWithoutCredentials: try backends.filter { backend in
        if backend.keychainRef.isEmpty { return true }
        return !(try credentialExists(backend.keychainRef))
      }.map(\.slug),
      projectsWithMissingSources: projects.compactMap { project in
        let missing = ProjectSettings(meta: project.meta).sources.map(\.path)
          .filter { !folderExists($0) }
        return missing.isEmpty
          ? nil
          : .init(projectSlug: project.slug, projectName: project.name, paths: missing)
      })
  }

  public static func directoryExists(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func appliedMigrations(_ db: GRDB.Database) throws -> [String] {
    try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
  }

  private static func validate(_ backup: CatalogBackup, applied: [String]) throws {
    guard backup.schema == 1 else { throw CatalogRestoreError.unsupportedSchema(backup.schema) }
    let unknown = backup.migrations.filter { !applied.contains($0) }
    guard unknown.isEmpty else {
      throw CatalogRestoreError.newerVersion(unknownMigrations: unknown)
    }
    guard backup.migrations.count <= applied.count,
      Array(applied.prefix(backup.migrations.count)) == backup.migrations
    else { throw CatalogRestoreError.incompatibleMigrations(backup.migrations) }
  }

  private static func counts(_ db: GRDB.Database) throws -> CatalogTableCounts {
    func count(_ table: String, _ condition: String = "") throws -> Int {
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) \(condition)") ?? 0
    }
    var counts = CatalogTableCounts()
    counts.backends = try count("backend")
    counts.backendPrefixHistory = try count("backend_prefix_history")
    counts.assets = try count("asset")
    counts.projects = try count("project")
    counts.assetProjects = try count("asset_project")
    counts.tags = try count("tag")
    counts.assetTags = try count("asset_tag")
    counts.scans = try count("scan")
    counts.usages = try count("usage")
    counts.assetLabels = try count("asset_label")
    counts.favorites = try count("asset", "WHERE favorite = 1")
    return counts
  }
}
