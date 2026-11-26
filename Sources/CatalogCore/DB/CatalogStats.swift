import Foundation
import GRDB

/// Everything the Overview page draws, read in one call.
/// Read-only: aggregates over the catalog and the reports' own reads, so
/// each number is the one its page shows when clicked.
public struct CatalogStats: Equatable, Sendable {
  /// A count and its bytes.
  public struct Total: Equatable, Sendable {
    public var count: Int
    public var bytes: Int64

    public init(count: Int = 0, bytes: Int64 = 0) {
      self.count = count
      self.bytes = bytes
    }
  }

  /// One bar of a breakdown: a tag, a kind (MIME type) or a backend.
  public struct Share: Equatable, Sendable {
    public let name: String
    public let total: Total

    public init(name: String, total: Total) {
      self.name = name
      self.total = total
    }
  }

  /// One row of Usage by Project. Each number is what the matching report
  /// shows with the project current.
  public struct ProjectUsage: Equatable, Sendable {
    public let slug: String
    public let name: String
    /// Distinct images the latest completed scan references (Usage).
    public let used: Int
    /// Orphans with the project current.
    public let orphanCandidates: Int
    /// Externals with the project current, each half.
    public let yourDomains: Int
    public let otherDomains: Int
    public let lastScanAt: String?
    public let usageTracking: UsageTracking

    public init(
      slug: String, name: String, used: Int, orphanCandidates: Int, yourDomains: Int,
      otherDomains: Int, lastScanAt: String?, usageTracking: UsageTracking
    ) {
      self.slug = slug
      self.name = name
      self.used = used
      self.orphanCandidates = orphanCandidates
      self.yourDomains = yourDomains
      self.otherDomains = otherDomains
      self.lastScanAt = lastScanAt
      self.usageTracking = usageTracking
    }
  }

  /// nil = All Projects.
  public let project: String?
  /// Active assets in scope.
  public let assets: Total
  public let favorites: Int
  public let archived: Int
  /// Active assets in scope by the day they were uploaded, keyed by the
  /// start of that day in the calendar asked for. Days with none are absent.
  public let uploadsByDay: [Date: Total]
  /// Every tag on an active asset in scope, most used first, then by name.
  public let tags: [Share]
  public let tagged: Int
  public let untagged: Int
  /// By MIME type and by backend slug, most assets first, then by name.
  public let kinds: [Share]
  public let backends: [Share]
  public let usedImages: Int
  public let orphanCandidates: Total
  /// Unmatched references on your domains (Externals ▸ Your Domains).
  public let yourDomains: Int
  /// Matched references still on a retired prefix (Usage ▸ Old Domains).
  public let oldDomains: Int
  /// The projects in scope, by slug.
  public let projects: [ProjectUsage]
  /// Active assets in scope by project name, most bytes first, then by
  /// name; an asset in two projects counts in both, one in none under ""
  /// (All Projects only). With a project current, that project alone.
  public let projectShares: [Share]

  public init(
    project: String?, assets: Total, favorites: Int, archived: Int,
    uploadsByDay: [Date: Total], tags: [Share], tagged: Int, untagged: Int,
    kinds: [Share], backends: [Share], usedImages: Int, orphanCandidates: Total,
    yourDomains: Int, oldDomains: Int, projects: [ProjectUsage], projectShares: [Share] = []
  ) {
    self.project = project
    self.assets = assets
    self.favorites = favorites
    self.archived = archived
    self.uploadsByDay = uploadsByDay
    self.tags = tags
    self.tagged = tagged
    self.untagged = untagged
    self.kinds = kinds
    self.backends = backends
    self.usedImages = usedImages
    self.orphanCandidates = orphanCandidates
    self.yourDomains = yourDomains
    self.oldDomains = oldDomains
    self.projects = projects
    self.projectShares = projectShares
  }

  /// One project's assets (`project`), or every asset (nil). Upload days
  /// are bucketed in `calendar` — its time zone decides where a day ends.
  ///
  /// The report numbers are counted here rather than by building each
  /// report (`orphans`, `liveUsage`, `externalReferences` decode every
  /// asset they list): the same rules, one read. `OverviewStatsTests` holds
  /// them equal to those reports.
  public static func load(
    project slug: String? = nil,
    calendar: Calendar,
    in database: CatalogDatabasePool
  ) async throws -> CatalogStats {
    try await database.read { db in
      let totals = try fetchCatalogTotals(project: slug, calendar: calendar, in: db)
      let reports = try fetchReportCounts(project: slug, in: db)
      let projects = totals.projects.map { project in
        ProjectUsage(
          slug: project.slug, name: project.name, used: reports.used[project.id] ?? 0,
          orphanCandidates: reports.orphans[project.id]?.count ?? 0,
          yourDomains: reports.yours[project.id] ?? 0, otherDomains: reports.other[project.id] ?? 0,
          lastScanAt: project.lastScanAt, usageTracking: project.usageTracking)
      }
      return CatalogStats(
        project: slug, assets: totals.assets, favorites: totals.favorites,
        archived: totals.archived, uploadsByDay: totals.uploadsByDay, tags: totals.tags,
        tagged: totals.tagged, untagged: totals.assets.count - totals.tagged,
        kinds: totals.kinds, backends: totals.backends,
        usedImages: reports.usedInScope, orphanCandidates: reports.orphansInScope,
        yourDomains: reports.yours.values.reduce(0, +), oldDomains: reports.oldDomains,
        projects: projects, projectShares: totals.projectShares)
    }
  }

  private struct ReportCounts {
    /// By project id: what Usage, Orphans and Externals show with that
    /// project current.
    var used: [Int64: Int] = [:]
    var orphans: [Int64: Total] = [:]
    var yours: [Int64: Int] = [:]
    var other: [Int64: Int] = [:]
    /// The scope's own: All Projects is not the sum of its projects.
    var usedInScope = 0
    var orphansInScope = Total()
    var oldDomains = 0
  }

  /// `liveUsage`, `orphans` and `externalReferences`, counted. A reference
  /// is live when it belongs to its project's latest completed scan.
  private static func fetchReportCounts(
    project slug: String?, in db: GRDB.Database
  ) throws -> ReportCounts {
    let projects = try Project.fetchAll(db)
    let scoped = Set(projects.filter { slug == nil || $0.slug == slug }.compactMap(\.id))
    let notTracked = Set(
      projects.filter { ProjectSettings(meta: $0.meta).usageTracking == .notTracked }
        .compactMap(\.id))
    let backends = try Backend.order(Column("id")).fetchAll(db)
    let backendByID = Dictionary(
      uniqueKeysWithValues: backends.compactMap { backend in backend.id.map { ($0, backend) } })
    var retired: [Int64: [String]] = [:]
    for row in try Row.fetchAll(
      db, sql: "SELECT backend_id, url_prefix FROM backend_prefix_history ORDER BY id")
    {
      retired[row["backend_id"], default: []].append(row["url_prefix"])
    }
    var counts = ReportCounts()

    // Live references: matched (Usage) and unmatched (Externals).
    var usedBy: [Int64: Set<Int64>] = [:]
    var usedInScope = Set<Int64>()
    var usedAnywhere = Set<Int64>()
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT u.project_id, u.asset_id, u.raw_url, a.backend_id
        FROM usage u
        JOIN project p ON p.id = u.project_id
        LEFT JOIN asset a ON a.id = u.asset_id
        WHERE u.last_scan_id = p.last_scan_id
        """)
    {
      let projectID: Int64 = row["project_id"]
      let rawURL: String = row["raw_url"]
      let inScope = scoped.contains(projectID)
      if let assetID: Int64 = row["asset_id"] {
        usedAnywhere.insert(assetID)
        usedBy[projectID, default: []].insert(assetID)
        guard inScope else { continue }
        usedInScope.insert(assetID)
        if let backendID: Int64 = row["backend_id"], let backend = backendByID[backendID],
          CatalogUsage.isOldDomain(rawURL, backend: backend, retiredPrefixes: retired[backendID] ?? [])
        {
          counts.oldDomains += 1
        }
      } else if inScope {
        switch CatalogUsage.externalDomain(rawURL, backends: backends, retiredPrefixes: retired) {
        case .yours: counts.yours[projectID, default: 0] += 1
        case .other: counts.other[projectID, default: 0] += 1
        }
      }
    }
    counts.usedInScope = usedInScope.count
    counts.used = usedBy.filter { scoped.contains($0.key) }.mapValues(\.count)

    // Orphans: active, unpinned, not a favorite, unused — by any project for All, by the
    // project itself when one is current — less the assets whose every
    // project is not tracked.
    var memberships: [Int64: [Int64]] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT asset_id, project_id FROM asset_project") {
      memberships[row["asset_id"], default: []].append(row["project_id"])
    }
    for row in try Row.fetchAll(
      db,
      sql: "SELECT id, byte_size FROM asset WHERE state = 'active' AND pinned = 0 AND favorite = 0")
    {
      let assetID: Int64 = row["id"]
      let bytes: Int64 = row["byte_size"]
      let homes = memberships[assetID] ?? []
      guard homes.isEmpty || !homes.allSatisfy(notTracked.contains) else { continue }
      if slug == nil, !usedAnywhere.contains(assetID) {
        counts.orphansInScope.count += 1
        counts.orphansInScope.bytes += bytes
      }
      for projectID in homes where scoped.contains(projectID) {
        guard usedBy[projectID]?.contains(assetID) != true else { continue }
        counts.orphans[projectID, default: Total()].count += 1
        counts.orphans[projectID, default: Total()].bytes += bytes
      }
    }
    if slug != nil, let projectID = scoped.first {
      counts.orphansInScope = counts.orphans[projectID] ?? Total()
    }
    return counts
  }

  private struct CatalogTotals {
    var assets = Total()
    var favorites = 0
    var archived = 0
    var uploadsByDay: [Date: Total] = [:]
    var tags: [Share] = []
    var tagged = 0
    var kinds: [Share] = []
    var backends: [Share] = []
    var projectShares: [Share] = []
    var projects:
      [(id: Int64, slug: String, name: String, lastScanAt: String?, usageTracking: UsageTracking)] =
        []
  }

  private static func fetchCatalogTotals(
    project slug: String?, calendar: Calendar, in db: GRDB.Database
  ) throws -> CatalogTotals {
    var scope = ""
    var arguments: StatementArguments = []
    if let slug {
      guard try Project.filter(Column("slug") == slug).fetchCount(db) == 1 else {
        throw UsageCatalogError.projectNotFound(slug)
      }
      scope = """
         AND EXISTS (SELECT 1 FROM asset_project ap JOIN project p ON p.id = ap.project_id
                     WHERE ap.asset_id = a.id AND p.slug = ?)
        """
      arguments = [slug]
    }
    let active = "a.state = 'active'" + scope
    var totals = CatalogTotals()

    if let row = try Row.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) AS n, IFNULL(SUM(byte_size), 0) AS bytes,
               IFNULL(SUM(favorite = 1), 0) AS favorites
        FROM asset a WHERE \(active)
        """, arguments: arguments)
    {
      totals.assets = Total(count: row["n"], bytes: row["bytes"])
      totals.favorites = row["favorites"]
    }
    totals.archived =
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM asset a WHERE a.state = 'archived'" + scope,
        arguments: arguments) ?? 0

    // Quarter hours, not days, so any time zone's day boundary falls on a
    // bucket edge; the calendar puts each quarter in its day. In order, so
    // the calendar is asked once per day rather than once per quarter.
    var day: DateInterval?
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT CAST(strftime('%s', a.uploaded_at) AS INTEGER) / 900 AS quarter,
               COUNT(*) AS n, SUM(a.byte_size) AS bytes
        FROM asset a WHERE \(active) AND quarter IS NOT NULL
        GROUP BY quarter
        ORDER BY quarter
        """, arguments: arguments)
    {
      let quarter: Int64 = row["quarter"]
      let moment = Date(timeIntervalSince1970: TimeInterval(quarter * 900))
      if day.map({ moment < $0.start || moment >= $0.end }) ?? true {
        day = calendar.dateInterval(of: .day, for: moment)
      }
      guard let start = day?.start else { continue }
      totals.uploadsByDay[start, default: Total()].count += row["n"]
      totals.uploadsByDay[start, default: Total()].bytes += row["bytes"]
    }

    totals.tags = try Row.fetchAll(
      db,
      sql: """
        SELECT t.name AS name, COUNT(*) AS n
        FROM asset_tag at
        JOIN tag t ON t.id = at.tag_id
        JOIN asset a ON a.id = at.asset_id
        WHERE \(active)
        GROUP BY t.id
        ORDER BY n DESC, t.name
        """, arguments: arguments
    ).map { Share(name: $0["name"], total: Total(count: $0["n"])) }
    totals.tagged =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM asset a
          WHERE \(active) AND EXISTS (SELECT 1 FROM asset_tag at WHERE at.asset_id = a.id)
          """, arguments: arguments) ?? 0

    func shares(_ column: String, join: String = "") throws -> [Share] {
      try Row.fetchAll(
        db,
        sql: """
          SELECT \(column) AS name, COUNT(*) AS n, SUM(a.byte_size) AS bytes
          FROM asset a \(join)
          WHERE \(active)
          GROUP BY name
          ORDER BY n DESC, name
          """, arguments: arguments
      ).map { Share(name: $0["name"], total: Total(count: $0["n"], bytes: $0["bytes"])) }
    }
    totals.kinds = try shares("a.mime")
    totals.backends = try shares("b.slug", join: "JOIN backend b ON b.id = a.backend_id")
    totals.projectShares = try Row.fetchAll(
      db,
      sql: """
        SELECT IFNULL(p.name, '') AS name, COUNT(*) AS n, IFNULL(SUM(a.byte_size), 0) AS bytes
        FROM asset a
        LEFT JOIN asset_project ap ON ap.asset_id = a.id
        LEFT JOIN project p ON p.id = ap.project_id
        WHERE \(active)\(slug == nil ? "" : " AND p.slug = ?")
        GROUP BY p.id
        ORDER BY bytes DESC, name
        """, arguments: slug.map { [$0, $0] } ?? []
    ).map { Share(name: $0["name"], total: Total(count: $0["n"], bytes: $0["bytes"])) }

    var projects = Project.order(Column("slug"))
    if let slug { projects = projects.filter(Column("slug") == slug) }
    let summaries = Dictionary(
      try CatalogConfiguration.fetchProjectSummaries(in: db).map { ($0.slug, $0) },
      uniquingKeysWith: { first, _ in first })
    totals.projects = try projects.fetchAll(db).map { project in
      (
        project.id ?? 0, project.slug, project.name, summaries[project.slug]?.lastScanAt,
        ProjectSettings(meta: project.meta).usageTracking
      )
    }
    return totals
  }
}
