import Foundation
import GRDB

// MARK: - Result contracts

/// What a signed List of one backend found that the catalog lacks.
/// Finding sends one List and no GET.
public struct UnreferencedObjects: Equatable, Sendable {
  public let backend: String
  /// Every object the List returned; an import re-filters these against
  /// the catalog as it is then, so nothing is listed twice.
  public let objects: [S3ObjectSummary]
  /// The objects to import: not in the catalog, not tombstoned, not a bad
  /// key, and not what any project's pages use.
  public let candidates: [S3ObjectSummary]
  public let alreadyInCatalog: Int
  /// Keys staged for permanent deletion (`pending_deletion`).
  public let pendingDeletion: [String]
  /// Keys never claimed: a `cdn-cgi/` path, a leading `/`, empty, or a
  /// folder marker.
  public let badKeys: [String]
  /// Keys an unmatched usage row resolves to: `pinax externals import`
  /// claims those, attached to the projects that use them.
  public let referenced: [String]
  /// Pinax-uploaded assets the CDN check can sample; 0 means the import
  /// goes ahead unchecked.
  public let cdnSamples: Int

  public init(
    backend: String, objects: [S3ObjectSummary], candidates: [S3ObjectSummary],
    alreadyInCatalog: Int, pendingDeletion: [String], badKeys: [String], referenced: [String],
    cdnSamples: Int
  ) {
    self.backend = backend
    self.objects = objects
    self.candidates = candidates
    self.alreadyInCatalog = alreadyInCatalog
    self.pendingDeletion = pendingDeletion
    self.badKeys = badKeys
    self.referenced = referenced
    self.cdnSamples = cdnSamples
  }
}

public struct BucketClaimResult: Codable, Equatable, Sendable {
  public let schema: Int
  public let dryRun: Bool
  public let backend: String
  /// Objects the List returned.
  public let listed: Int
  public let alreadyInCatalog: Int
  /// Keys some project's pages use; left for `pinax externals import`.
  public let referenced: [String]
  /// Keys that passed every filter and were attempted.
  public let candidates: Int
  public let claimed: [ExternalsClaimedItem]
  /// The Externals import's categories, plus `pending_deletion` and
  /// `bad_key` from the filter.
  public let skipped: [ExternalsClaimSkip]
  public let cdnCheck: [CDNByteCheck]
  public let refused: Bool
  public let cancelled: Bool
  public let remaining: Int
  public let notice: String

  public init(
    schema: Int = 1, dryRun: Bool, backend: String, listed: Int, alreadyInCatalog: Int,
    referenced: [String], candidates: Int, claimed: [ExternalsClaimedItem],
    skipped: [ExternalsClaimSkip], cdnCheck: [CDNByteCheck], refused: Bool, cancelled: Bool,
    remaining: Int, notice: String = ExternalsClaimResult.reindexNotice
  ) {
    self.schema = schema
    self.dryRun = dryRun
    self.backend = backend
    self.listed = listed
    self.alreadyInCatalog = alreadyInCatalog
    self.referenced = referenced
    self.candidates = candidates
    self.claimed = claimed
    self.skipped = skipped
    self.cdnCheck = cdnCheck
    self.refused = refused
    self.cancelled = cancelled
    self.remaining = remaining
    self.notice = notice
  }

  public var skippedCounts: [String: Int] {
    skipped.reduce(into: [:]) { $0[$1.reason, default: 0] += 1 }
  }

  /// The same rule as `ExternalsClaimResult.hasFailures`.
  public var hasFailures: Bool {
    refused || skipped.contains { ExternalsClaimSkipReason.failures.contains($0.reason) }
  }

  enum CodingKeys: String, CodingKey {
    case schema, backend, listed, referenced, candidates, claimed, skipped, refused, cancelled
    case remaining, notice
    case dryRun = "dry_run"
    case alreadyInCatalog = "already_in_catalog"
    case cdnCheck = "cdn_check"
    case skippedCounts = "skipped_counts"
    case claimedCount = "claimed_count"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(Int.self, forKey: .schema)
    dryRun = try container.decode(Bool.self, forKey: .dryRun)
    backend = try container.decode(String.self, forKey: .backend)
    listed = try container.decode(Int.self, forKey: .listed)
    alreadyInCatalog = try container.decode(Int.self, forKey: .alreadyInCatalog)
    referenced = try container.decode([String].self, forKey: .referenced)
    candidates = try container.decode(Int.self, forKey: .candidates)
    claimed = try container.decode([ExternalsClaimedItem].self, forKey: .claimed)
    skipped = try container.decode([ExternalsClaimSkip].self, forKey: .skipped)
    cdnCheck = try container.decode([CDNByteCheck].self, forKey: .cdnCheck)
    refused = try container.decode(Bool.self, forKey: .refused)
    cancelled = try container.decode(Bool.self, forKey: .cancelled)
    remaining = try container.decode(Int.self, forKey: .remaining)
    notice = try container.decode(String.self, forKey: .notice)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(dryRun, forKey: .dryRun)
    try container.encode(backend, forKey: .backend)
    try container.encode(listed, forKey: .listed)
    try container.encode(alreadyInCatalog, forKey: .alreadyInCatalog)
    try container.encode(referenced, forKey: .referenced)
    try container.encode(candidates, forKey: .candidates)
    try container.encode(claimed.count, forKey: .claimedCount)
    try container.encode(claimed, forKey: .claimed)
    try container.encode(skippedCounts, forKey: .skippedCounts)
    try container.encode(skipped, forKey: .skipped)
    try container.encode(cdnCheck, forKey: .cdnCheck)
    try container.encode(refused, forKey: .refused)
    try container.encode(cancelled, forKey: .cancelled)
    try container.encode(remaining, forKey: .remaining)
    try container.encode(notice, forKey: .notice)
  }
}

// MARK: - Find and claim

/// Objects in a backend's bucket that the catalog lacks and no page uses,
/// claimed with the Externals import's core — no project,
/// `{"imported_from":"bucket"}`. Sends one signed List, then public
/// GETs; never a PUT or DELETE.
public enum BucketClaim {
  static let provenanceMeta = "{\"imported_from\":\"bucket\"}"

  /// The signed List and the filter; no GET.
  public static func find(
    backend: Backend, inventory: any ObjectInventory, in database: CatalogDatabasePool
  ) async throws -> UnreferencedObjects {
    let objects = try await inventory.listObjects()
    return try await database.read { db in try filter(objects, backend: backend, db: db) }
  }

  /// Lists, then imports what the List found.
  public static func run(
    backend: Backend, inventory: any ObjectInventory, in database: CatalogDatabasePool,
    fetcher: any PublicObjectFetching, now: Date = Date(), dryRun: Bool = false,
    maxConcurrentFetches: Int = 8, cancellation: ExternalsClaimCancellation? = nil,
    progress: (@Sendable (ExternalsClaimProgress) -> Void)? = nil
  ) async throws -> BucketClaimResult {
    let found = try await find(backend: backend, inventory: inventory, in: database)
    return try await run(
      found, backend: backend, in: database, fetcher: fetcher, now: now, dryRun: dryRun,
      maxConcurrentFetches: maxConcurrentFetches, cancellation: cancellation,
      progress: progress)
  }

  /// Imports what an earlier `find` listed, re-filtered against the catalog
  /// as it is now — so a re-run sends no GET for what is already claimed.
  public static func run(
    _ found: UnreferencedObjects, backend: Backend, in database: CatalogDatabasePool,
    fetcher: any PublicObjectFetching, now: Date = Date(), dryRun: Bool = false,
    maxConcurrentFetches: Int = 8, cancellation: ExternalsClaimCancellation? = nil,
    progress: (@Sendable (ExternalsClaimProgress) -> Void)? = nil
  ) async throws -> BucketClaimResult {
    guard let backendID = backend.id else {
      throw ReindexError.backendNotPersisted(backend.slug)
    }
    let (current, hashes) = try await database.read {
      db -> (UnreferencedObjects, [String: String]) in
      (
        try filter(found.objects, backend: backend, db: db),
        try knownHashes(backendID: backendID, db: db)
      )
    }
    var skipped: [ExternalsClaimSkip] = current.pendingDeletion.map { key in
      ExternalsClaimSkip(
        reason: ExternalsClaimSkipReason.pendingDeletion,
        url: URLResolver.url(forKey: key, backend: backend), key: key,
        detail: "staged for permanent deletion")
    }
    skipped += current.badKeys.map { key in
      ExternalsClaimSkip(
        reason: ExternalsClaimSkipReason.badKey,
        url: URLResolver.url(forKey: key, backend: backend), key: key,
        detail: badKeyDetail(key))
    }
    let pending = current.candidates.map { object in
      let canonical = URLResolver.url(forKey: object.key, backend: backend)
      return ExternalsClaim.Plan.Entry(
        backendID: backendID,
        candidate: ObjectClaimCandidate(
          key: object.key, fetchURL: canonical, reportURL: canonical, width: nil, height: nil,
          originalFilename: object.key.split(separator: "/").last.map(String.init),
          uploadedAt: nil, meta: provenanceMeta),
        // Nothing uses these objects, so no project.
        projectIDs: [], projectSlugs: [])
    }
    let plan = ExternalsClaim.Plan(
      pending: pending, skipped: skipped, distinctKeys: current.objects.count,
      alreadyInCatalog: current.alreadyInCatalog,
      targetBackends: pending.isEmpty ? [] : [backend], knownHashes: [backendID: hashes])
    let result = try await ExternalsClaim.execute(
      plan, references: current.objects.count, in: database, fetcher: fetcher, now: now,
      dryRun: dryRun, maxConcurrentFetches: maxConcurrentFetches, batchSize: 20,
      sampleSize: 12, relink: false, cancellation: cancellation, progress: progress)
    return BucketClaimResult(
      dryRun: dryRun, backend: backend.slug, listed: current.objects.count,
      alreadyInCatalog: current.alreadyInCatalog, referenced: current.referenced,
      candidates: pending.count, claimed: result.claimed, skipped: result.skipped,
      cdnCheck: result.cdnCheck, refused: result.refused, cancelled: result.cancelled,
      remaining: result.remaining)
  }

  /// A refused List (401/403) in words a person can act on; nil for any
  /// other error.
  public static func listRefusalMessage(for error: Error, backend: Backend) -> String? {
    guard case let .http(status, _) = error as? S3UploaderError, status == 401 || status == 403
    else { return nil }
    return
      "\(backend.bucket) refused to list its objects (HTTP \(status)). The credentials for \(backend.slug) need permission to list the bucket."
  }

  // MARK: - Filter

  static func filter(_ objects: [S3ObjectSummary], backend: Backend, db: GRDB.Database) throws
    -> UnreferencedObjects
  {
    let backendID = backend.id ?? -1
    let inCatalog = Set(
      try String.fetchAll(
        db, sql: "SELECT key FROM asset WHERE backend_id = ?", arguments: [backendID]))
    // The same bucket under any backend row, as reindex reads it.
    let tombstoned = Set(
      try String.fetchAll(
        db,
        sql: """
          SELECT d.key FROM pending_deletion d JOIN backend b ON b.id = d.backend_id
          WHERE rtrim(lower(b.endpoint), '/') = rtrim(lower(?), '/') AND b.bucket = ?
          """, arguments: [backend.endpoint, backend.bucket]))
    let referenced = try referencedKeys(backend: backend, db: db)
    let cdnSamples =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM (SELECT 1 FROM asset
          WHERE backend_id = ? AND meta NOT LIKE '%imported_from%' LIMIT 12)
          """, arguments: [backendID]) ?? 0

    var candidates: [S3ObjectSummary] = []
    var alreadyInCatalog = 0
    var pendingDeletion: [String] = []
    var badKeys: [String] = []
    var referencedHere: [String] = []
    for object in objects {
      if inCatalog.contains(object.key) {
        alreadyInCatalog += 1
      } else if tombstoned.contains(object.key) {
        pendingDeletion.append(object.key)
      } else if isBadKey(object.key) {
        badKeys.append(object.key)
      } else if referenced.contains(object.key) {
        referencedHere.append(object.key)
      } else {
        candidates.append(object)
      }
    }
    return UnreferencedObjects(
      backend: backend.slug, objects: objects, candidates: candidates,
      alreadyInCatalog: alreadyInCatalog, pendingDeletion: pendingDeletion, badKeys: badKeys,
      referenced: referencedHere, cdnSamples: cdnSamples)
  }

  /// A key no upload would make, or a folder marker (a key ending in `/`),
  /// which is not an image.
  static func isBadKey(_ key: String) -> Bool {
    key.isEmpty || key.hasPrefix("/") || key.hasPrefix("cdn-cgi/") || key.hasSuffix("/")
  }

  private static func badKeyDetail(_ key: String) -> String {
    if key.hasPrefix("cdn-cgi/") { return "a Cloudflare transform path, not an object key" }
    if key.hasSuffix("/") && !key.isEmpty { return "a folder marker, not an image" }
    return "a key starting with '/' or empty"
  }

  /// Keys on this backend that an unmatched row of any project's latest
  /// scan resolves to, by the scan's own rule (prefix + retired prefixes).
  private static func referencedKeys(backend: Backend, db: GRDB.Database) throws -> Set<String> {
    let retired = try String.fetchAll(
      db, sql: "SELECT url_prefix FROM backend_prefix_history WHERE backend_id = ? ORDER BY id",
      arguments: [backend.id ?? -1])
    let rawURLs = try String.fetchAll(
      db,
      sql: """
        SELECT u.raw_url FROM usage u JOIN project p ON p.id = u.project_id
        WHERE u.last_scan_id = p.last_scan_id AND u.asset_id IS NULL
        """)
    return Set(
      rawURLs.compactMap { URLResolver.key(from: $0, backend: backend, retiredPrefixes: retired) })
  }

  private static func knownHashes(backendID: Int64, db: GRDB.Database) throws -> [String: String]
  {
    let rows = try Row.fetchAll(
      db, sql: "SELECT key, sha256 FROM asset WHERE backend_id = ? ORDER BY id",
      arguments: [backendID])
    return Dictionary(
      rows.map { ($0["sha256"] as String, $0["key"] as String) },
      uniquingKeysWith: { first, _ in first })
  }
}
