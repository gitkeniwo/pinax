import Foundation
import GRDB

public enum UsageCatalogError: Error, Equatable, CustomStringConvertible {
  case unsupportedSchema(Int)
  case projectMismatch(expected: String, actual: String)
  case projectNotFound(String)
  case projectHasNoBackend(String)
  case emptyScanRejected(previousFoundCount: Int)
  case invalidDocumentField(String)

  public var description: String {
    switch self {
    case let .unsupportedSchema(schema):
      return "Unsupported usage schema \(schema)."
    case let .projectMismatch(expected, actual):
      return "Usage document is for project '\(actual)', not '\(expected)'."
    case let .projectNotFound(slug):
      return "Project '\(slug)' does not exist."
    case let .projectHasNoBackend(slug):
      return "Project '\(slug)' has no backend."
    case let .emptyScanRejected(previousFoundCount):
      return
        "The empty scan was rejected because the previous scan found \(previousFoundCount) refs. Use --allow-empty to accept it."
    case let .invalidDocumentField(field):
      return "Invalid usage document field '\(field)'."
    }
  }
}

public struct UsageReference: Codable, Equatable, Sendable {
  public let rawURL: String
  public let sourceReference: String
  public let kind: String

  public init(rawURL: String, sourceReference: String, kind: String = "markdown") {
    self.rawURL = rawURL
    self.sourceReference = sourceReference
    self.kind = kind
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case rawURL = "raw_url"
    case sourceReference = "source_ref"
  }
}

public struct UsageDocument: Codable, Equatable, Sendable {
  public let schema: Int
  public let project: String
  public let sourceRevision: String?
  public let coverage: [String]
  public let refs: [UsageReference]

  public init(
    schema: Int = 1,
    project: String,
    sourceRevision: String? = nil,
    coverage: [String] = [],
    refs: [UsageReference]
  ) {
    self.schema = schema
    self.project = project
    self.sourceRevision = sourceRevision
    self.coverage = coverage
    self.refs = refs
  }

  enum CodingKeys: String, CodingKey {
    case schema, project, coverage, refs
    case sourceRevision = "source_rev"
  }

  public init(from decoder: Decoder) throws {
    do {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      schema = try container.decode(Int.self, forKey: .schema)
      guard schema == 1 else { throw UsageCatalogError.unsupportedSchema(schema) }
      project = try container.decode(String.self, forKey: .project)
      sourceRevision = try container.decodeIfPresent(String.self, forKey: .sourceRevision)
      coverage = try container.decodeIfPresent([String].self, forKey: .coverage) ?? []
      refs = try container.decodeIfPresent([UsageReference].self, forKey: .refs) ?? []
    } catch let error as UsageCatalogError {
      throw error
    } catch let error as DecodingError {
      throw UsageCatalogError.invalidDocumentField(Self.fieldPath(for: error))
    }
  }

  private static func fieldPath(for error: DecodingError) -> String {
    let path: [CodingKey]
    switch error {
    case let .keyNotFound(key, context):
      path = context.codingPath + [key]
    case let .typeMismatch(_, context), let .valueNotFound(_, context):
      path = context.codingPath
    case let .dataCorrupted(context):
      path = context.codingPath
    @unknown default:
      return "unknown"
    }
    guard !path.isEmpty else { return "document" }
    return path.map { key in
      key.intValue.map { "[\($0)]" } ?? key.stringValue
    }.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
  }
}

public struct UsageSyncResult: Equatable, Sendable {
  public let scanID: Int64
  public let foundCount: Int

  public init(scanID: Int64, foundCount: Int) {
    self.scanID = scanID
    self.foundCount = foundCount
  }
}

public struct UsageReportItem: Codable, Equatable, Sendable {
  public let rawURL: String
  public let sourceReference: String
  public let kind: String
  public let sha256: String?
  public let key: String?
  public let firstSeen: String
  public let lastSeen: String

  public init(
    rawURL: String,
    sourceReference: String,
    kind: String,
    sha256: String?,
    key: String?,
    firstSeen: String,
    lastSeen: String
  ) {
    self.rawURL = rawURL
    self.sourceReference = sourceReference
    self.kind = kind
    self.sha256 = sha256
    self.key = key
    self.firstSeen = firstSeen
    self.lastSeen = lastSeen
  }

  enum CodingKeys: String, CodingKey {
    case kind, sha256, key
    case rawURL = "raw_url"
    case sourceReference = "source_ref"
    case firstSeen = "first_seen"
    case lastSeen = "last_seen"
  }
}

public struct UsageReport: Codable, Equatable, Sendable {
  public let schema: Int
  public let project: String
  public let items: [UsageReportItem]
  public let hasCompletedScan: Bool

  public init(
    schema: Int = 1,
    project: String,
    items: [UsageReportItem],
    hasCompletedScan: Bool = true
  ) {
    self.schema = schema
    self.project = project
    self.items = items
    self.hasCompletedScan = hasCompletedScan
  }

  enum CodingKeys: String, CodingKey {
    case schema, project, items
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(Int.self, forKey: .schema)
    project = try container.decode(String.self, forKey: .project)
    items = try container.decode([UsageReportItem].self, forKey: .items)
    hasCompletedScan = true
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(project, forKey: .project)
    try container.encode(items, forKey: .items)
  }
}

public struct OrphanReport: Sendable {
  public let assets: [CatalogAssetItem]
  /// Under-scanned projects; a not-tracked project is never one.
  public let unscannedProjects: [String]
  /// Every project each candidate — in `assets` or `untracked` — belongs
  /// to, by asset id, slugs sorted. A candidate in no project has no entry.
  public let projectSlugs: [Int64: [String]]
  /// Candidates whose every project is not tracked: used
  /// where Pinax cannot scan, so never orphan candidates. Report order.
  public let untracked: [CatalogAssetItem]
  /// The not-tracked projects in the report's scope, sorted.
  public let notTrackedProjects: [String]
  /// Every not-tracked project, whatever the scope, sorted: a candidate
  /// also in one of these is judged by its tracked projects alone.
  public let notTrackedSlugs: [String]

  public init(
    assets: [CatalogAssetItem],
    unscannedProjects: [String],
    projectSlugs: [Int64: [String]] = [:],
    untracked: [CatalogAssetItem] = [],
    notTrackedProjects: [String] = [],
    notTrackedSlugs: [String] = []
  ) {
    self.assets = assets
    self.unscannedProjects = unscannedProjects
    self.projectSlugs = projectSlugs
    self.untracked = untracked
    self.notTrackedProjects = notTrackedProjects
    self.notTrackedSlugs = notTrackedSlugs
  }

  /// The not-tracked projects the `untracked` assets are in, sorted.
  public var untrackedProjects: [String] {
    Array(Set(untracked.flatMap { $0.asset.id.flatMap { projectSlugs[$0] } ?? [] })).sorted()
  }
}

public enum CatalogUsage {
  public static func sync(
    _ document: UsageDocument,
    project expectedProject: String,
    in database: CatalogDatabasePool,
    now: Date = Date(),
    allowEmpty: Bool = false
  ) throws -> UsageSyncResult {
    guard document.schema == 1 else {
      throw UsageCatalogError.unsupportedSchema(document.schema)
    }
    guard document.project == expectedProject else {
      throw UsageCatalogError.projectMismatch(expected: expectedProject, actual: document.project)
    }
    let timestamp = timestamp(now)
    return try database.write { db in
      guard var project = try Project.filter(Column("slug") == expectedProject).fetchOne(db) else {
        throw UsageCatalogError.projectNotFound(expectedProject)
      }
      guard let projectID = project.id, let backendID = project.backendID,
        let backend = try Backend.fetchOne(db, key: backendID)
      else {
        throw UsageCatalogError.projectHasNoBackend(expectedProject)
      }
      if !allowEmpty, document.refs.isEmpty, let previousScanID = project.lastScanID {
        let previousFoundCount =
          try Int.fetchOne(
            db,
            sql: "SELECT found_count FROM scan WHERE id = ?",
            arguments: [previousScanID]
          ) ?? 0
        if previousFoundCount > 0 {
          throw UsageCatalogError.emptyScanRejected(previousFoundCount: previousFoundCount)
        }
      }
      let retiredPrefixes = try String.fetchAll(
        db,
        sql: "SELECT url_prefix FROM backend_prefix_history WHERE backend_id = ? ORDER BY id",
        arguments: [backendID]
      )
      let coverageData = try JSONEncoder().encode(document.coverage)
      var scan = Scan(
        projectID: projectID,
        startedAt: timestamp,
        sourceRevision: document.sourceRevision,
        coverage: String(decoding: coverageData, as: UTF8.self)
      )
      scan = try scan.insertAndFetch(db)
      guard let scanID = scan.id else { throw UsageCatalogError.projectNotFound(expectedProject) }

      for reference in document.refs {
        let assetID = try usageAssetID(
          for: reference.rawURL, backend: backend, retiredPrefixes: retiredPrefixes, db: db)
        if let assetID,
          try Usage
            .filter(Column("project_id") == projectID)
            .filter(Column("source_ref") == reference.sourceReference)
            .filter(Column("raw_url") == reference.rawURL)
            .filter(Column("kind") == reference.kind)
            .fetchCount(db) == 0,
          var existing =
            try Usage
            .filter(Column("project_id") == projectID)
            .filter(Column("source_ref") == reference.sourceReference)
            .filter(Column("kind") == reference.kind)
            .filter(Column("asset_id") == assetID)
            .filter(Column("last_scan_id") != scanID)
            .order(Column("first_seen"))
            .fetchOne(db),
          existing.rawURL != reference.rawURL
        {
          existing.rawURL = reference.rawURL
          existing.lastSeen = timestamp
          existing.lastScanID = scanID
          try existing.update(db)
          continue
        }
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id, source_ref, raw_url, kind) DO UPDATE SET
              asset_id = excluded.asset_id,
              last_seen = excluded.last_seen,
              last_scan_id = excluded.last_scan_id
            """,
          arguments: [
            projectID, assetID, reference.rawURL, reference.sourceReference, reference.kind,
            timestamp, timestamp, scanID,
          ]
        )
      }

      scan.finishedAt = timestamp
      scan.foundCount = document.refs.count
      try scan.update(db)
      project.lastScanID = scanID
      project.updatedAt = timestamp
      try project.update(db)
      return UsageSyncResult(scanID: scanID, foundCount: document.refs.count)
    }
  }

  /// The one rule that ties a usage URL to an asset:
  /// the key under the project's backend — its current prefix or a retired
  /// one — looked up by `(backend, key)`. `sync` and `relinkUnmatched` both
  /// go through here, so a relink can never disagree with a rescan.
  static func usageAssetID(
    for rawURL: String, backend: Backend, retiredPrefixes: [String], db: GRDB.Database
  ) throws -> Int64? {
    guard let backendID = backend.id,
      let key = URLResolver.key(from: rawURL, backend: backend, retiredPrefixes: retiredPrefixes)
    else {
      return nil
    }
    return try Int64.fetchOne(
      db,
      sql: "SELECT id FROM asset WHERE backend_id = ? AND key = ?",
      arguments: [backendID, key]
    )
  }

  /// After a claim, point the unmatched rows of each project's
  /// latest scan at the assets that now exist — by `usageAssetID`, the
  /// rule `sync` uses — without reading any file or starting a scan. Every
  /// newly linked asset's `updated_at` is stamped so `changeStamp` moves and
  /// the app refetches. Returns how many usage rows were linked.
  @discardableResult
  public static func relinkUnmatched(
    projects slugs: [String]? = nil,
    in database: CatalogDatabasePool,
    now: Date = Date()
  ) async throws -> Int {
    let stamp = timestamp(now)
    return try await database.write { db in
      try relinkUnmatched(projects: slugs, stamp: stamp, db: db)
    }
  }

  static func relinkUnmatched(
    projects slugs: [String]?, stamp: String, db: GRDB.Database
  ) throws -> Int {
    var request = Project.order(Column("slug"))
    if let slugs {
      request = request.filter(slugs.contains(Column("slug")))
    }
    var linked = 0
    var linkedAssets = Set<Int64>()
    for project in try request.fetchAll(db) {
      guard let projectID = project.id, let scanID = project.lastScanID,
        let backendID = project.backendID, let backend = try Backend.fetchOne(db, key: backendID)
      else { continue }
      let retiredPrefixes = try String.fetchAll(
        db,
        sql: "SELECT url_prefix FROM backend_prefix_history WHERE backend_id = ? ORDER BY id",
        arguments: [backendID])
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, raw_url FROM usage
          WHERE project_id = ? AND last_scan_id = ? AND asset_id IS NULL
          ORDER BY id
          """,
        arguments: [projectID, scanID])
      for row in rows {
        guard
          let assetID = try usageAssetID(
            for: row["raw_url"], backend: backend, retiredPrefixes: retiredPrefixes, db: db)
        else { continue }
        try db.execute(
          sql: "UPDATE usage SET asset_id = ? WHERE id = ?",
          arguments: [assetID, row["id"] as Int64])
        linked += 1
        linkedAssets.insert(assetID)
      }
    }
    for assetID in linkedAssets.sorted() {
      try db.execute(
        sql: "UPDATE asset SET updated_at = ? WHERE id = ? AND updated_at < ?",
        arguments: [stamp, assetID, stamp])
    }
    return linked
  }

  public static func report(
    project slug: String,
    in database: CatalogDatabasePool
  ) throws -> UsageReport {
    try database.read { db in
      try fetchReport(project: slug, in: db)
    }
  }

  public static func report(
    project slug: String,
    in database: CatalogDatabasePool
  ) async throws -> UsageReport {
    try await database.read { db in
      try fetchReport(project: slug, in: db)
    }
  }

  private static func fetchReport(
    project slug: String,
    in db: GRDB.Database
  ) throws -> UsageReport {
    guard let project = try Project.filter(Column("slug") == slug).fetchOne(db),
      let projectID = project.id
    else {
      throw UsageCatalogError.projectNotFound(slug)
    }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT u.raw_url, u.source_ref, u.kind, a.sha256, a.key, u.first_seen, u.last_seen
        FROM usage u
        LEFT JOIN asset a ON a.id = u.asset_id
        WHERE u.project_id = ? AND u.last_scan_id = ?
        ORDER BY u.source_ref, u.raw_url, u.kind
        """,
      arguments: [projectID, project.lastScanID]
    )
    return UsageReport(
      project: slug,
      items: rows.map { row in
        UsageReportItem(
          rawURL: row["raw_url"],
          sourceReference: row["source_ref"],
          kind: row["kind"],
          sha256: row["sha256"],
          key: row["key"],
          firstSeen: row["first_seen"],
          lastSeen: row["last_seen"]
        )
      },
      hasCompletedScan: project.lastScanID != nil
    )
  }

  public static func orphans(
    project slug: String? = nil,
    minimumScans: Int = 2,
    in database: CatalogDatabasePool
  ) throws -> OrphanReport {
    try database.read { db in
      try fetchOrphans(project: slug, minimumScans: minimumScans, in: db)
    }
  }

  public static func orphans(
    project slug: String? = nil,
    minimumScans: Int = 2,
    in database: CatalogDatabasePool
  ) async throws -> OrphanReport {
    try await database.read { db in
      try fetchOrphans(project: slug, minimumScans: minimumScans, in: db)
    }
  }

  private static func fetchOrphans(
    project slug: String?,
    minimumScans: Int,
    in db: GRDB.Database
  ) throws -> OrphanReport {
    let project: Project?
    if let slug {
      guard let found = try Project.filter(Column("slug") == slug).fetchOne(db) else {
        throw UsageCatalogError.projectNotFound(slug)
      }
      project = found
    } else {
      project = nil
    }
    let assets: [Asset]
    if let projectID = project?.id {
      assets = try Asset.fetchAll(
        db,
        sql: """
          SELECT DISTINCT a.*
          FROM asset a
          JOIN asset_project ap ON ap.asset_id = a.id
          WHERE a.state = 'active' AND a.pinned = 0 AND a.favorite = 0 AND ap.project_id = ?
            AND NOT EXISTS (
              SELECT 1 FROM asset_live_usage l
              WHERE l.asset_id = a.id AND l.project_id = ?
            )
          ORDER BY a.uploaded_at, a.id
          """,
        arguments: [projectID, projectID]
      )
    } else {
      assets = try Asset.fetchAll(
        db,
        sql: """
          SELECT a.*
          FROM asset a
          WHERE a.state = 'active' AND a.pinned = 0 AND a.favorite = 0
            AND NOT EXISTS (
              SELECT 1 FROM asset_live_usage l
              WHERE l.asset_id = a.id
            )
          ORDER BY a.uploaded_at, a.id
          """
      )
    }
    let backendIDs = Set(assets.map(\.backendID))
    let backends = try Backend.filter(backendIDs.contains(Column("id"))).fetchAll(db)
    let backendByID = Dictionary(
      uniqueKeysWithValues: backends.compactMap { backend in backend.id.map { ($0, backend) } }
    )
    let notTracked = Set(
      try Project.fetchAll(db)
        .filter { ProjectSettings(meta: $0.meta).usageTracking == .notTracked }
        .map(\.slug))
    var unscanned: [String]
    if let project {
      let scanCount =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM scan WHERE project_id = ? AND finished_at IS NOT NULL",
          arguments: [project.id]
        ) ?? 0
      unscanned = scanCount < minimumScans ? [project.slug] : []
    } else {
      unscanned = try String.fetchAll(
        db,
        sql: """
          SELECT p.slug
          FROM project p
          LEFT JOIN scan s ON s.project_id = p.id AND s.finished_at IS NOT NULL
          GROUP BY p.id
          HAVING COUNT(s.id) < ?
          ORDER BY p.slug
          """,
        arguments: [minimumScans]
      )
    }
    let candidateIDs = Set(assets.compactMap(\.id))
    var projectSlugs: [Int64: [String]] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT ap.asset_id, p.slug
        FROM asset_project ap
        JOIN project p ON p.id = ap.project_id
        ORDER BY p.slug
        """
    ) {
      let assetID: Int64 = row["asset_id"]
      if candidateIDs.contains(assetID) {
        projectSlugs[assetID, default: []].append(row["slug"])
      }
    }
    unscanned.removeAll(where: notTracked.contains)
    // A candidate in no project, or in any tracked one, stays a candidate:
    // the tracked projects' scans decide it.
    var candidates: [CatalogAssetItem] = []
    var untracked: [CatalogAssetItem] = []
    for asset in assets {
      guard let backend = backendByID[asset.backendID] else { continue }
      let item = CatalogAssetItem(asset: asset, backend: backend)
      let slugs = asset.id.flatMap { projectSlugs[$0] } ?? []
      if !slugs.isEmpty && slugs.allSatisfy(notTracked.contains) {
        untracked.append(item)
      } else {
        candidates.append(item)
      }
    }
    return OrphanReport(
      assets: candidates,
      unscannedProjects: unscanned,
      projectSlugs: projectSlugs,
      untracked: untracked,
      notTrackedProjects: notTracked.filter { project == nil || $0 == project?.slug }.sorted(),
      notTrackedSlugs: notTracked.sorted()
    )
  }

  public static func externals(
    project slug: String? = nil,
    in database: CatalogDatabasePool
  ) throws -> [UsageReportItem] {
    try database.read { db in
      var conditions = ["u.asset_id IS NULL", "u.last_scan_id = p.last_scan_id"]
      var arguments: [DatabaseValueConvertible?] = []
      if let slug {
        guard try Project.filter(Column("slug") == slug).fetchCount(db) == 1 else {
          throw UsageCatalogError.projectNotFound(slug)
        }
        conditions.append("p.slug = ?")
        arguments.append(slug)
      }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT u.raw_url, u.source_ref, u.kind, u.first_seen, u.last_seen
          FROM usage u
          JOIN project p ON p.id = u.project_id
          WHERE \(conditions.joined(separator: " AND "))
          ORDER BY p.slug, u.source_ref, u.raw_url, u.kind
          """,
        arguments: StatementArguments(arguments)
      )
      return rows.map { row in
        UsageReportItem(
          rawURL: row["raw_url"],
          sourceReference: row["source_ref"],
          kind: row["kind"],
          sha256: nil,
          key: nil,
          firstSeen: row["first_seen"],
          lastSeen: row["last_seen"]
        )
      }
    }
  }

  private static func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
