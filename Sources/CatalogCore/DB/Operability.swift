import Foundation
import GRDB

public enum DatabaseLocationWarning: Equatable, Sendable {
  case unsafeExistingDatabase(problem: String)
}

public enum DatabasePathSafety {
  public static func problem(
    at databaseURL: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> String? {
    let resolved = databaseURL.standardizedFileURL.resolvingSymlinksInPath()
    let path = resolved.path
    let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    let syncedRoots = [
      "\(home)/Library/CloudStorage",
      "\(home)/Library/Mobile Documents",
      "\(home)/Dropbox",
    ]
    if syncedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
      return "The database path is inside a synced storage directory: \(path)"
    }

    var volumeProbe = resolved.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: volumeProbe.path),
      volumeProbe.path != "/"
    {
      volumeProbe.deleteLastPathComponent()
    }
    if let values = try? volumeProbe.resourceValues(forKeys: [.volumeIsLocalKey]),
      values.volumeIsLocal == false
    {
      return "The database path is on a network filesystem: \(path)"
    }
    return nil
  }

  static func refuseNewDatabase(
    at databaseURL: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) throws {
    guard !fileManager.fileExists(atPath: databaseURL.path),
      let problem = problem(at: databaseURL, homeDirectory: homeDirectory)
    else {
      return
    }
    throw DatabaseLocationError.unsafePath(problem)
  }

  static func prepareToOpen(
    at databaseURL: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) throws -> DatabaseLocationWarning? {
    guard let problem = problem(at: databaseURL, homeDirectory: homeDirectory) else {
      return nil
    }
    guard fileManager.fileExists(atPath: databaseURL.path) else {
      throw DatabaseLocationError.unsafePath(problem)
    }
    return .unsafeExistingDatabase(problem: problem)
  }
}

public enum DoctorStatus: String, Codable, Equatable, Sendable {
  case pass
  /// A legitimate state worth stating, not a fault — e.g. a backend
  /// registered without credentials for read-only use.
  case info
  case warning
  case failure
}

public struct DoctorCheck: Codable, Equatable, Sendable {
  public let name: String
  public let status: DoctorStatus
  public let detail: String

  public init(name: String, status: DoctorStatus, detail: String) {
    self.name = name
    self.status = status
    self.detail = detail
  }
}

public struct DoctorReport: Codable, Equatable, Sendable {
  public let schema: Int
  public let checks: [DoctorCheck]

  public init(schema: Int = 1, checks: [DoctorCheck]) {
    self.schema = schema
    self.checks = checks
  }

  public var hasFailures: Bool {
    checks.contains { $0.status == .failure }
  }
}

public enum CatalogDoctor {
  public static func run(
    database: CatalogDatabasePool,
    databaseURL: URL,
    credentialExists: (String) throws -> Bool
  ) throws -> DoctorReport {
    var checks: [DoctorCheck] = []
    if let problem = DatabasePathSafety.problem(at: databaseURL) {
      checks.append(DoctorCheck(name: "database-location", status: .failure, detail: problem))
    } else {
      checks.append(
        DoctorCheck(
          name: "database-location",
          status: .pass,
          detail: databaseURL.standardizedFileURL.path
        ))
    }

    try database.read { db in
      let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check").joined(separator: "; ")
      checks.append(
        DoctorCheck(
          name: "integrity-check",
          status: integrity == "ok" ? .pass : .failure,
          detail: integrity
        ))
      let journalMode = (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown")
        .lowercased()
      checks.append(
        DoctorCheck(
          name: "journal-mode",
          status: journalMode == "wal" ? .pass : .failure,
          detail: journalMode
        ))

      let projectCount = try Project.fetchCount(db)
      let assetCount = projectCount == 0 ? try Asset.fetchCount(db) : 0
      let unscanned = try String.fetchAll(
        db,
        sql: "SELECT slug FROM project WHERE last_scan_id IS NULL ORDER BY slug"
      )
      let usageScanStatus: DoctorStatus
      let usageScanDetail: String
      if projectCount == 0, assetCount > 0 {
        let assetLabel = assetCount == 1 ? "1 asset" : "\(assetCount) assets"
        usageScanStatus = .warning
        usageScanDetail =
          "\(assetLabel), 0 projects. Reindex does not restore projects, tags, or usage history."
      } else if projectCount == 0 {
        usageScanStatus = .pass
        usageScanDetail = "No projects exist."
      } else if unscanned.isEmpty {
        usageScanStatus = .pass
        usageScanDetail = "All projects have completed scans."
      } else {
        usageScanStatus = .warning
        usageScanDetail = unscanned.joined(separator: ", ")
      }
      checks.append(
        DoctorCheck(
          name: "usage-scans",
          status: usageScanStatus,
          detail: usageScanDetail
        ))

      let orphansByProject = try Row.fetchAll(
        db,
        sql: """
          SELECT p.slug AS slug, COUNT(*) AS n
          FROM usage u
          JOIN project p ON p.id = u.project_id
          WHERE u.asset_id IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM asset_project ap
              WHERE ap.asset_id = u.asset_id AND ap.project_id = u.project_id
            )
          GROUP BY p.slug
          ORDER BY p.slug
          """
      )
      if orphansByProject.isEmpty {
        checks.append(
          DoctorCheck(
            name: "usage-membership",
            status: .pass,
            detail: "Every referenced asset is a member of its referencing project."
          ))
      } else {
        let detail = orphansByProject.map { row in
          "\(row["slug"] as String): \(row["n"] as Int)"
        }.joined(separator: ", ")
        checks.append(
          DoctorCheck(
            name: "usage-membership",
            status: .warning,
            detail:
              "Projects reference assets that are not members of the project; their manifests "
                + "omit these images while the site still uses them: \(detail). "
                + "Re-add membership to repair."
          ))
      }

      let backends = try Backend.order(Column("slug")).fetchAll(db)
      var missingCredentials: [String] = []
      var credentialLess: [String] = []
      for backend in backends {
        if backend.keychainRef.isEmpty {
          // Registered with --no-credentials: read-only is a legitimate
          // state, not a fault.
          credentialLess.append(backend.slug)
        } else if try !credentialExists(backend.keychainRef) {
          missingCredentials.append(backend.slug)
        }
      }
      var detail = ""
      var status = DoctorStatus.pass
      if missingCredentials.isEmpty && credentialLess.isEmpty {
        detail = "All backend credentials are available."
      } else {
        var parts: [String] = []
        if !missingCredentials.isEmpty {
          status = .warning
          parts.append("missing credentials: " + missingCredentials.joined(separator: ", "))
        } else {
          status = .info
        }
        if !credentialLess.isEmpty {
          parts.append(
            "registered without credentials (read-only): "
              + credentialLess.joined(separator: ", "))
        }
        detail = parts.joined(separator: "; ")
      }
      checks.append(
        DoctorCheck(
          name: "backend-credentials",
          status: status,
          detail: detail
        ))

      // Deletes still owed to the bucket. Absent when there are none,
      // so the report is unchanged; rows removed with keep_remote are not
      // owed anything.
      let owed = try CatalogDeletion.pending(db).filter { !$0.keepRemote }
      if let oldest = owed.map(\.requestedAt).min() {
        let items = owed.map { item in
          "\(item.backendSlug):\(item.key) (\(item.lastError ?? "not tried yet"))"
        }
        checks.append(
          DoctorCheck(
            name: "pending-deletions",
            status: .warning,
            detail:
              "\(owed.count) removed from the catalog, not yet deleted from the bucket "
              + "(oldest \(oldest)): \(items.joined(separator: "; "))"
          ))
      }
    }
    return DoctorReport(checks: checks)
  }
}

public struct CatalogBackupTables: Codable, Sendable {
  public let backends: [Backend]
  public let backendPrefixHistory: [BackendPrefixHistory]
  public let assets: [Asset]
  public let projects: [Project]
  public let assetProjects: [AssetProject]
  public let tags: [Tag]
  public let assetTags: [AssetTag]
  public let scans: [Scan]
  public let usages: [Usage]
  /// `v2_favorite_label`: the favourite asset ids and the label rows —
  /// `Asset` does not carry the `favorite` column, so it is exported here.
  public let assetFavorites: [Int64]
  public let assetLabels: [AssetLabelRow]
  /// Whether the decoded document carried the two `v2_favorite_label` keys.
  /// Not encoded: `create` always writes both.
  var hasFavoriteLabelKeys = true

  enum CodingKeys: String, CodingKey {
    case backends, assets, projects, tags, scans, usages
    case backendPrefixHistory = "backend_prefix_history"
    case assetProjects = "asset_projects"
    case assetTags = "asset_tags"
    case assetFavorites = "asset_favorites"
    case assetLabels = "asset_labels"
  }
}

extension CatalogBackupTables {
  /// Backups written before `v2_favorite_label` (2026-09-24) lack
  /// `asset_favorites` and `asset_labels`; they decode as empty here and
  /// `CatalogBackup` rejects the omission when its migrations include v2.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    backends = try container.decode([Backend].self, forKey: .backends)
    backendPrefixHistory = try container.decode(
      [BackendPrefixHistory].self, forKey: .backendPrefixHistory)
    assets = try container.decode([Asset].self, forKey: .assets)
    projects = try container.decode([Project].self, forKey: .projects)
    assetProjects = try container.decode([AssetProject].self, forKey: .assetProjects)
    tags = try container.decode([Tag].self, forKey: .tags)
    assetTags = try container.decode([AssetTag].self, forKey: .assetTags)
    scans = try container.decode([Scan].self, forKey: .scans)
    usages = try container.decode([Usage].self, forKey: .usages)
    let favorites = try container.decodeIfPresent([Int64].self, forKey: .assetFavorites)
    let labels = try container.decodeIfPresent([AssetLabelRow].self, forKey: .assetLabels)
    assetFavorites = favorites ?? []
    assetLabels = labels ?? []
    hasFavoriteLabelKeys = favorites != nil && labels != nil
  }
}

public struct AssetLabelRow: Codable, Equatable, Sendable {
  public let assetID: Int64
  public let label: String

  enum CodingKeys: String, CodingKey {
    case label
    case assetID = "asset_id"
  }
}

public struct CatalogBackup: Codable, Sendable {
  public let schema: Int
  public let generatedAt: String
  public let migrations: [String]
  public let tables: CatalogBackupTables

  enum CodingKeys: String, CodingKey {
    case schema, migrations, tables
    case generatedAt = "generated_at"
  }

  public init(
    schema: Int = 1,
    generatedAt: String,
    migrations: [String],
    tables: CatalogBackupTables
  ) {
    self.schema = schema
    self.generatedAt = generatedAt
    self.migrations = migrations
    self.tables = tables
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(Int.self, forKey: .schema)
    generatedAt = try container.decode(String.self, forKey: .generatedAt)
    migrations = try container.decode([String].self, forKey: .migrations)
    tables = try container.decode(CatalogBackupTables.self, forKey: .tables)
    if migrations.contains(CatalogBackups.favoriteLabelMigration), !tables.hasFavoriteLabelKeys {
      throw DecodingError.keyNotFound(
        CatalogBackupTables.CodingKeys.assetFavorites,
        DecodingError.Context(
          codingPath: [CodingKeys.tables],
          debugDescription:
            "A backup made after \(CatalogBackups.favoriteLabelMigration) must carry "
            + "asset_favorites and asset_labels."))
    }
  }
}

public enum CatalogBackups {
  public static func create(
    from database: CatalogDatabasePool,
    now: Date = Date()
  ) throws -> CatalogBackup {
    try database.read { db in
      let migrations = try String.fetchAll(
        db,
        sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
      )
      return CatalogBackup(
        generatedAt: ISO8601DateFormatter().string(from: now),
        migrations: migrations,
        tables: CatalogBackupTables(
          backends: try Backend.order(Column("id")).fetchAll(db),
          backendPrefixHistory: try BackendPrefixHistory.order(Column("id")).fetchAll(db),
          assets: try Asset.order(Column("id")).fetchAll(db),
          projects: try Project.order(Column("id")).fetchAll(db),
          assetProjects: try AssetProject.order(Column("asset_id"), Column("project_id")).fetchAll(
            db),
          tags: try Tag.order(Column("id")).fetchAll(db),
          assetTags: try AssetTag.order(Column("asset_id"), Column("tag_id")).fetchAll(db),
          scans: try Scan.order(Column("id")).fetchAll(db),
          usages: try Usage.order(Column("id")).fetchAll(db),
          assetFavorites: try Int64.fetchAll(
            db, sql: "SELECT id FROM asset WHERE favorite = 1 ORDER BY id"),
          assetLabels: try Row.fetchAll(
            db, sql: "SELECT asset_id, label FROM asset_label ORDER BY asset_id, label"
          ).map { AssetLabelRow(assetID: $0["asset_id"], label: $0["label"]) }
        )
      )
    }
  }
}
