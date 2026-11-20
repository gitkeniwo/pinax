import CatalogCore
import GRDB
import Foundation

/// The only object PinaxUI views may talk to. It holds the database privately and
/// exposes read paths exclusively; there is no write API anywhere on this type.
public struct ReadOnlyCatalog: Sendable, ExternalUsageReading {
  private let database: DatabasePool

  public init(database: DatabasePool) {
    self.database = database
  }

  public func page(_ query: AssetQuery) async throws -> AssetPage {
    try await CatalogAssets.page(query, in: database)
  }

  /// The status bar's count: the same query's predicates
  /// with no LIMIT — an honest total, not the page length.
  public func count(_ query: AssetQuery) async throws -> Int {
    try await CatalogAssets.count(query, in: database)
  }

  public func details(_ identifier: String) async throws -> CatalogAssetDetails {
    try await CatalogAssets.details(identifier, in: database)
  }

  /// One read for the grid page's project membership. Context-menu state must
  /// be ready before rows are published, but fetching full details once per
  /// cell would turn a 120-row page into 120 database round trips.
  public func projectMemberships(assetIDs: [Int64]) async throws -> [Int64: Set<String>] {
    guard !assetIDs.isEmpty else { return [:] }
    return try await database.read { db in
      let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ap.asset_id, p.slug
          FROM asset_project ap
          JOIN project p ON p.id = ap.project_id
          WHERE ap.asset_id IN (\(placeholders))
          """,
        arguments: StatementArguments(assetIDs)
      )
      var result: [Int64: Set<String>] = [:]
      for row in rows {
        let assetID: Int64 = row["asset_id"]
        let slug: String = row["slug"]
        result[assetID, default: []].insert(slug)
      }
      return result
    }
  }

  public func tagSummaries() async throws -> [TagSummary] {
    try await CatalogAssets.tagSummaries(in: database)
  }

  public func projectSummaries() async throws -> [ProjectSummary] {
    try await CatalogConfiguration.projectSummaries(in: database)
  }

  public func availableMonths(matching query: AssetQuery) async throws -> [(month: String, count: Int)] {
    try await CatalogAssets.availableMonths(in: database, matching: query)
  }

  /// One backend's level under `prefix` (each backend has its own
  /// root, so two buckets' folders never merge).
  public func keyPrefixChildren(
    under prefix: String?, backendID: Int64
  ) async throws -> [(segment: String, assetCount: Int, hasSubPrefixes: Bool)] {
    // Active only: every grid a Catalog row opens onto hides archived
    // assets, and the row's count is that grid's total.
    try await CatalogAssets.keyPrefixChildren(
      under: prefix, state: .active, backendID: backendID, in: database)
  }

  /// Every backend with its Current and Old domains and its active assets:
  /// the Catalog roots and the Usage domain menu.
  public func domainBackends() async throws -> [DomainBackend] {
    let totals = try await CatalogAssets.backendAssetTotals(state: .active, in: database)
    let database = database
    return try await Task.detached {
      try CatalogConfiguration.backends(in: database).compactMap { backend -> DomainBackend? in
        guard let id = backend.id else { return nil }
        return DomainBackend(
          id: id, slug: backend.slug, current: backend.urlPrefix,
          oldDomains: try CatalogConfiguration.oldDomains(backendSlug: backend.slug, in: database),
          assetCount: totals.first { $0.backendID == id }?.assetCount ?? 0,
          bucket: backend.bucket)
      }
    }.value
  }

  /// The colour labels in use, for the Collections navigator.
  public func labelSummaries() async throws -> [LabelSummary] {
    try await CatalogAssets.labelSummaries(in: database)
  }

  /// How many of `identifiers` a completed scan still sees referenced.
  public func liveUsageAssetCount(identifiers: [String]) async throws -> Int {
    try await CatalogAssets.liveUsageAssetCount(identifiers: identifiers, in: database)
  }

  /// The slugs of the projects whose `meta` names at least one source.
  public func sourcedProjects() async throws -> Set<String> {
    try await database.read { db in
      Set(
        try Project.fetchAll(db)
          .filter { !ProjectSettings(meta: $0.meta).sources.isEmpty }
          .map(\.slug))
    }
  }

  public func changeStamp() async throws -> String {
    try await CatalogAssets.changeStamp(in: database)
  }

  /// The Overview's numbers, one read.
  public func overviewStats(project: String?, calendar: Calendar) async throws -> CatalogStats {
    try await CatalogStats.load(project: project, calendar: calendar, in: database)
  }

  public func orphans(project: String?) async throws -> OrphanReport {
    try await CatalogUsage.orphans(project: project, in: database)
  }

  public func usageReport(project slug: String) async throws -> UsageReport {
    try await CatalogUsage.report(project: slug, in: database)
  }

  public func liveUsage(project slug: String? = nil, assetID: Int64? = nil) async throws
    -> LiveUsageSet
  {
    try await CatalogUsage.liveUsage(project: slug, assetID: assetID, in: database)
  }

  /// The links under each prefix in the latest
  /// scans, in the catalog or not (`domainLinkCounts`' count).
  public func domainLinks(prefixes: [String], project slug: String?) async throws -> [String: Int] {
    let database = database
    return try await Task.detached {
      try DomainLinks.counts(prefixes: prefixes, project: slug, in: database)
    }.value
  }

  public func externalReferences(project slug: String?) async throws -> ExternalReferenceSet {
    try await CatalogUsage.externalReferences(project: slug, in: database)
  }

  /// The activity panel's runs, newest first; a
  /// dead `running` run reads as interrupted, nothing is written.
  public func runs(limit: Int) async throws -> [RunRecord] {
    try RunLog.listedRuns(limit: limit, in: database)
  }

  /// A run's events after `seq` (0: all of them).
  public func runEvents(of runID: Int64, after seq: Int) async throws -> [RunEventRecord] {
    try RunLog.events(of: runID, after: seq, in: database)
  }
}
