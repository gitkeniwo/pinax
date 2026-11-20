import Foundation
import GRDB

/// One reference a project's latest completed scan matched to an asset.
/// `isOldDomain`: the URL misses the asset's backend's current prefix and
/// hits one of its retired ones.
public struct LiveUsageReference: Equatable, Sendable {
  public let assetID: Int64
  public let projectSlug: String
  public let sourceReference: String
  public let rawURL: String
  public let kind: String
  public let isOldDomain: Bool

  public init(
    assetID: Int64, projectSlug: String, sourceReference: String, rawURL: String,
    kind: String, isOldDomain: Bool
  ) {
    self.assetID = assetID
    self.projectSlug = projectSlug
    self.sourceReference = sourceReference
    self.rawURL = rawURL
    self.kind = kind
    self.isOldDomain = isOldDomain
  }
}

/// The live references in a scope, the assets they point at, and enough of
/// each project to read them: which projects completed a scan, and each
/// project's configured sources (for the Open File rule).
public struct LiveUsageSet: Sendable {
  /// Ordered by project slug, source reference, URL, kind.
  public let references: [LiveUsageReference]
  public let assets: [Int64: CatalogAssetItem]
  /// The scope's projects with a completed scan, by slug.
  public let scannedProjects: Set<String>
  /// The scope's projects, by slug.
  public let projectSources: [String: [ProjectSource]]

  public init(
    references: [LiveUsageReference], assets: [Int64: CatalogAssetItem],
    scannedProjects: Set<String>, projectSources: [String: [ProjectSource]]
  ) {
    self.references = references
    self.assets = assets
    self.scannedProjects = scannedProjects
    self.projectSources = projectSources
  }
}

extension CatalogUsage {
  /// Read-only: the matched references of each project's latest
  /// completed scan — every project, or the one named — optionally of one
  /// asset only (the inspector's Used In).
  public static func liveUsage(
    project slug: String? = nil,
    assetID: Int64? = nil,
    in database: CatalogDatabasePool
  ) async throws -> LiveUsageSet {
    try await database.read { db in
      try fetchLiveUsage(project: slug, assetID: assetID, in: db)
    }
  }

  static func fetchLiveUsage(
    project slug: String?, assetID: Int64?, in db: GRDB.Database
  ) throws -> LiveUsageSet {
    var projectsRequest = Project.order(Column("slug"))
    if let slug {
      projectsRequest = projectsRequest.filter(Column("slug") == slug)
      guard try projectsRequest.fetchCount(db) == 1 else {
        throw UsageCatalogError.projectNotFound(slug)
      }
    }
    let projects = try projectsRequest.fetchAll(db)
    var conditions = ["u.asset_id IS NOT NULL", "u.last_scan_id = p.last_scan_id"]
    var arguments: [DatabaseValueConvertible?] = []
    if let slug {
      conditions.append("p.slug = ?")
      arguments.append(slug)
    }
    if let assetID {
      conditions.append("u.asset_id = ?")
      arguments.append(assetID)
    }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT u.asset_id, p.slug, u.source_ref, u.raw_url, u.kind
        FROM usage u
        JOIN project p ON p.id = u.project_id
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY p.slug, u.source_ref, u.raw_url, u.kind
        """,
      arguments: StatementArguments(arguments))
    let assetIDs = Set(rows.map { $0["asset_id"] as Int64 })
    let assets = try Asset.filter(assetIDs.contains(Column("id"))).fetchAll(db)
    let backendIDs = Set(assets.map(\.backendID))
    let backends = try Backend.filter(backendIDs.contains(Column("id"))).fetchAll(db)
    let backendByID = Dictionary(
      uniqueKeysWithValues: backends.compactMap { backend in backend.id.map { ($0, backend) } })
    var retired: [Int64: [String]] = [:]
    for row in try Row.fetchAll(
      db, sql: "SELECT backend_id, url_prefix FROM backend_prefix_history ORDER BY id")
    {
      retired[row["backend_id"], default: []].append(row["url_prefix"])
    }
    var items: [Int64: CatalogAssetItem] = [:]
    for asset in assets {
      guard let id = asset.id, let backend = backendByID[asset.backendID] else { continue }
      items[id] = CatalogAssetItem(asset: asset, backend: backend)
    }
    let references = rows.compactMap { row -> LiveUsageReference? in
      let id: Int64 = row["asset_id"]
      guard let item = items[id] else { return nil }
      let rawURL: String = row["raw_url"]
      return LiveUsageReference(
        assetID: id, projectSlug: row["slug"], sourceReference: row["source_ref"],
        rawURL: rawURL, kind: row["kind"],
        isOldDomain: isOldDomain(
          rawURL, backend: item.backend, retiredPrefixes: retired[item.asset.backendID] ?? []))
    }
    return LiveUsageSet(
      references: references, assets: items,
      scannedProjects: Set(projects.filter { $0.lastScanID != nil }.map(\.slug)),
      projectSources: Dictionary(
        uniqueKeysWithValues: projects.map { ($0.slug, ProjectSettings(meta: $0.meta).sources) }))
  }

  /// A URL is on an old domain when the backend's current prefix
  /// does not resolve it and one of its retired prefixes does.
  public static func isOldDomain(
    _ rawURL: String, backend: Backend, retiredPrefixes: [String]
  ) -> Bool {
    guard URLResolver.key(from: rawURL, backend: backend) == nil else { return false }
    return URLResolver.key(from: rawURL, backend: backend, retiredPrefixes: retiredPrefixes) != nil
  }
}
