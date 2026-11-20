import Foundation
import GRDB

// MARK: - Result contracts

/// Why an Externals ▸ Your Domains URL was not claimed.
public enum ExternalsClaimSkipReason {
  public static let notFound = PicGoSkipReason.notFound
  public static let forbidden = PicGoSkipReason.forbidden
  public static let fetchFailed = PicGoSkipReason.fetchFailed
  public static let lengthMismatch = PicGoSkipReason.lengthMismatch
  /// The bytes are already in the catalog under another key.
  public static let sameContent = "same_content"
  /// On another backend's domain than the project's.
  public static let otherBackend = "other_backend"
  /// A `cdn-cgi/` transform path, a leading `/`, or empty.
  public static let badKey = "bad_key"
  /// The key is staged for permanent deletion (`pending_deletion`).
  public static let pendingDeletion = "pending_deletion"
  /// A URL named on the command line that is not in Your Domains.
  public static let notInYourDomains = "not_in_your_domains"

  /// The reasons that mean something went wrong rather than "by policy".
  public static let failures: Set<String> = [
    notFound, forbidden, fetchFailed, lengthMismatch, notInYourDomains,
  ]
}

public struct ExternalsClaimSkip: Codable, Equatable, Sendable {
  public let reason: String
  public let url: String
  public let key: String?
  public let detail: String?
  /// The catalog key that already holds these bytes.
  public let existingKey: String?

  public init(
    reason: String, url: String, key: String? = nil, detail: String? = nil,
    existingKey: String? = nil
  ) {
    self.reason = reason
    self.url = url
    self.key = key
    self.detail = detail
    self.existingKey = existingKey
  }

  enum CodingKeys: String, CodingKey {
    case reason, url, key, detail
    case existingKey = "existing_key"
  }
}

public struct ExternalsClaimedItem: Codable, Equatable, Sendable {
  public let key: String
  public let url: String
  public let sha256: String
  public let byteSize: Int64
  public let projects: [String]

  public init(key: String, url: String, sha256: String, byteSize: Int64, projects: [String]) {
    self.key = key
    self.url = url
    self.sha256 = sha256
    self.byteSize = byteSize
    self.projects = projects
  }

  enum CodingKeys: String, CodingKey {
    case key, url, sha256, projects
    case byteSize = "byte_size"
  }
}

/// Whether the public URLs serve the bytes the catalog recorded.
public struct CDNByteCheck: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    /// Every sample that answered matched.
    case matched
    /// No Pinax-uploaded sample, or none answered: nothing was compared.
    case unchecked
    /// At least one sample's public bytes differ — the batch is refused.
    case rewritesBytes = "cdn_rewrites_bytes"
  }

  public let backend: String
  public let status: Status
  public let sampled: Int
  public let matched: Int
  /// Keys whose public bytes hash differently from the catalog's sha256.
  public let mismatched: [String]
  /// Samples whose GET failed; they count neither way.
  public let unreachable: Int

  public init(
    backend: String, status: Status, sampled: Int, matched: Int, mismatched: [String],
    unreachable: Int
  ) {
    self.backend = backend
    self.status = status
    self.sampled = sampled
    self.matched = matched
    self.mismatched = mismatched
    self.unreachable = unreachable
  }
}

public struct ExternalsClaimResult: Codable, Equatable, Sendable {
  /// Shown with every result.
  public static let reindexNotice =
    "Claimed images carry no Pinax metadata on the object, so `pinax reindex` cannot rebuild them; keep backups (`pinax backup`)."

  public let schema: Int
  public let dryRun: Bool
  /// Your Domains references in scope (rows, not distinct URLs).
  public let references: Int
  /// Distinct (backend, key) pairs those references resolve to.
  public let distinctKeys: Int
  /// Keys already in the catalog before this run (no GET was sent).
  public let alreadyInCatalog: Int
  /// Assets claimed (or, on a dry run, that would be).
  public let claimed: [ExternalsClaimedItem]
  public let skipped: [ExternalsClaimSkip]
  public let cdnCheck: [CDNByteCheck]
  /// True when a CDN check found rewritten bytes: nothing was claimed.
  public let refused: Bool
  /// True when the run was cancelled; `remaining` keys were not attempted.
  public let cancelled: Bool
  public let remaining: Int
  /// Usage rows pointed at their asset (on a dry run: that would be).
  public let relinkedUsage: Int
  public let notice: String

  public init(
    schema: Int = 1, dryRun: Bool, references: Int, distinctKeys: Int, alreadyInCatalog: Int,
    claimed: [ExternalsClaimedItem], skipped: [ExternalsClaimSkip], cdnCheck: [CDNByteCheck],
    refused: Bool, cancelled: Bool, remaining: Int, relinkedUsage: Int,
    notice: String = ExternalsClaimResult.reindexNotice
  ) {
    self.schema = schema
    self.dryRun = dryRun
    self.references = references
    self.distinctKeys = distinctKeys
    self.alreadyInCatalog = alreadyInCatalog
    self.claimed = claimed
    self.skipped = skipped
    self.cdnCheck = cdnCheck
    self.refused = refused
    self.cancelled = cancelled
    self.remaining = remaining
    self.relinkedUsage = relinkedUsage
    self.notice = notice
  }

  /// Skips per reason.
  public var skippedCounts: [String: Int] {
    skipped.reduce(into: [:]) { $0[$1.reason, default: 0] += 1 }
  }

  /// Something failed: a refused batch or a skip that is not policy.
  public var hasFailures: Bool {
    refused || skipped.contains { ExternalsClaimSkipReason.failures.contains($0.reason) }
  }

  enum CodingKeys: String, CodingKey {
    case schema, references, claimed, skipped, refused, cancelled, remaining, notice
    case dryRun = "dry_run"
    case distinctKeys = "distinct_keys"
    case alreadyInCatalog = "already_in_catalog"
    case cdnCheck = "cdn_check"
    case relinkedUsage = "relinked_usage"
    case skippedCounts = "skipped_counts"
    case claimedCount = "claimed_count"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(Int.self, forKey: .schema)
    dryRun = try container.decode(Bool.self, forKey: .dryRun)
    references = try container.decode(Int.self, forKey: .references)
    distinctKeys = try container.decode(Int.self, forKey: .distinctKeys)
    alreadyInCatalog = try container.decode(Int.self, forKey: .alreadyInCatalog)
    claimed = try container.decode([ExternalsClaimedItem].self, forKey: .claimed)
    skipped = try container.decode([ExternalsClaimSkip].self, forKey: .skipped)
    cdnCheck = try container.decode([CDNByteCheck].self, forKey: .cdnCheck)
    refused = try container.decode(Bool.self, forKey: .refused)
    cancelled = try container.decode(Bool.self, forKey: .cancelled)
    remaining = try container.decode(Int.self, forKey: .remaining)
    relinkedUsage = try container.decode(Int.self, forKey: .relinkedUsage)
    notice = try container.decode(String.self, forKey: .notice)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(dryRun, forKey: .dryRun)
    try container.encode(references, forKey: .references)
    try container.encode(distinctKeys, forKey: .distinctKeys)
    try container.encode(alreadyInCatalog, forKey: .alreadyInCatalog)
    try container.encode(claimed.count, forKey: .claimedCount)
    try container.encode(claimed, forKey: .claimed)
    try container.encode(skippedCounts, forKey: .skippedCounts)
    try container.encode(skipped, forKey: .skipped)
    try container.encode(cdnCheck, forKey: .cdnCheck)
    try container.encode(refused, forKey: .refused)
    try container.encode(cancelled, forKey: .cancelled)
    try container.encode(remaining, forKey: .remaining)
    try container.encode(relinkedUsage, forKey: .relinkedUsage)
    try container.encode(notice, forKey: .notice)
  }
}

/// Progress of the claim GETs: one call per finished key.
public struct ExternalsClaimProgress: Equatable, Sendable {
  public let completed: Int
  public let total: Int
  public let bytes: Int64

  public init(completed: Int, total: Int, bytes: Int64) {
    self.completed = completed
    self.total = total
    self.bytes = bytes
  }
}

/// A cancel switch the caller can flip from anywhere; Task cancellation
/// works too. Keys already committed stay claimed.
public final class ExternalsClaimCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  public init() {}

  public func cancel() {
    lock.lock()
    flag = true
    lock.unlock()
  }

  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flag
  }
}

// MARK: - Claim

/// Claims Externals ▸ Your Domains URLs into the
/// catalog. Each object stays where it is; the catalog gains a row for its
/// key, measured from a public GET. Only GETs are sent — no PUT, no DELETE,
/// no metadata backfill.
public enum ExternalsClaim {
  /// - Parameters:
  ///   - project: one project's Your Domains, or every project's.
  ///   - urls: only these raw URLs; nil claims every Your Domains URL.
  ///   - batchSize: keys per commit (at most 20).
  ///   - sampleSize: CDN check samples per backend (at most 12).
  public static func run(
    project: String? = nil,
    urls: [String]? = nil,
    in database: CatalogDatabasePool,
    fetcher: any PublicObjectFetching,
    now: Date = Date(),
    dryRun: Bool = false,
    maxConcurrentFetches: Int = 8,
    batchSize: Int = 20,
    sampleSize: Int = 12,
    cancellation: ExternalsClaimCancellation? = nil,
    progress: (@Sendable (ExternalsClaimProgress) -> Void)? = nil
  ) async throws -> ExternalsClaimResult {
    let references = try await CatalogUsage.externalReferences(project: project, in: database)
      .references.filter { $0.domain == .yours }
    let plan = try await database.read { db in
      try Plan(references: references, urls: urls, db: db)
    }
    return try await execute(
      plan, references: references.count, in: database, fetcher: fetcher, now: now,
      dryRun: dryRun, maxConcurrentFetches: maxConcurrentFetches, batchSize: batchSize,
      sampleSize: sampleSize, relink: true, cancellation: cancellation, progress: progress)
  }

  /// The claim itself, shared by the Externals import and the bucket import:
  /// the CDN check, then the chunked GET-and-insert, then, with `relink`,
  /// the usage relink.
  static func execute(
    _ plan: Plan,
    references: Int,
    in database: CatalogDatabasePool,
    fetcher: any PublicObjectFetching,
    now: Date,
    dryRun: Bool,
    maxConcurrentFetches: Int,
    batchSize: Int,
    sampleSize: Int,
    relink: Bool,
    cancellation: ExternalsClaimCancellation?,
    progress: (@Sendable (ExternalsClaimProgress) -> Void)?
  ) async throws -> ExternalsClaimResult {
    var skipped = plan.skipped
    let isCancelled: @Sendable () -> Bool = {
      Task.isCancelled || (cancellation?.isCancelled ?? false)
    }

    // Before any claim GET, check each target backend's CDN against
    // bytes the catalog already knows. One mismatch refuses the batch.
    let gate = ImportSlotGate(capacity: maxConcurrentFetches)
    var checks: [CDNByteCheck] = []
    for backend in plan.targetBackends {
      checks.append(
        try await cdnCheck(
          backend: backend, sampleSize: min(max(sampleSize, 0), 12), in: database,
          fetcher: fetcher, gate: gate))
    }
    let refused = checks.contains { $0.status == .rewritesBytes }
    if refused {
      return ExternalsClaimResult(
        dryRun: dryRun, references: references, distinctKeys: plan.distinctKeys,
        alreadyInCatalog: plan.alreadyInCatalog, claimed: [], skipped: skipped,
        cdnCheck: checks, refused: true, cancelled: false, remaining: plan.pending.count,
        relinkedUsage: 0)
    }

    var knownHashes = plan.knownHashes
    var claimed: [ExternalsClaimedItem] = []
    var completed = 0
    var bytes: Int64 = 0
    var cancelled = false
    var remaining = 0
    let stamp = ObjectClaim.iso8601.string(from: now)
    let chunkSize = min(max(batchSize, 1), 20)
    var index = 0
    while index < plan.pending.count {
      if isCancelled() {
        cancelled = true
        remaining = plan.pending.count - index
        break
      }
      let chunk = Array(plan.pending[index..<min(index + chunkSize, plan.pending.count)])
      index += chunk.count
      let hashes = knownHashes
      let guarded = CancelGuardFetcher(base: fetcher, isCancelled: isCancelled)
      let outcomes = try await withThrowingTaskGroup(
        of: (Int, ObjectClaimOutcome?).self
      ) { group in
        for (offset, entry) in chunk.enumerated() {
          group.addTask {
            // A key whose GET has not started when the cancel lands is left
            // for the next run rather than reported as a failure.
            do {
              let outcome = try await ObjectClaim.prepare(
                entry.candidate, backendID: entry.backendID,
                knownHashes: hashes[entry.backendID] ?? [:], now: now,
                uploadedAtFallback: .lastModified, fetcher: guarded, gate: gate)
              return (offset, outcome)
            } catch is CancelGuardFetcher.NotStarted {
              return (offset, nil)
            }
          }
        }
        var collected = [ObjectClaimOutcome?](repeating: nil, count: chunk.count)
        for try await (offset, outcome) in group {
          collected[offset] = outcome
          if outcome != nil {
            completed += 1
            if case let .prepared(asset) = outcome { bytes += asset.byteSize }
            progress?(
              ExternalsClaimProgress(
                completed: completed, total: plan.pending.count, bytes: bytes))
          }
        }
        return collected
      }

      // In order, so a batch-internal duplicate is decided the same way
      // whatever finished first.
      var toInsert: [(asset: Asset, entry: Plan.Entry)] = []
      for (entry, outcome) in zip(chunk, outcomes) {
        switch outcome {
        case nil:
          remaining += 1
          cancelled = true
        case let .prepared(asset):
          if let existing = knownHashes[entry.backendID]?[asset.sha256] {
            skipped.append(sameContent(entry, existingKey: existing))
          } else {
            knownHashes[entry.backendID, default: [:]][asset.sha256] = asset.key
            toInsert.append((asset, entry))
          }
        case let .skipped(skip)
        where skip.reason == ExternalsClaimSkipReason.fetchFailed && isCancelled():
          // A GET torn down by the cancel is not the object's fault.
          remaining += 1
          cancelled = true
        case let .skipped(skip):
          skipped.append(
            ExternalsClaimSkip(
              reason: skip.reason, url: entry.candidate.fetchURL, key: entry.candidate.key,
              detail: skip.detail))
        case let .contentDuplicate(existingKey):
          skipped.append(sameContent(entry, existingKey: existingKey))
        }
      }
      if !dryRun, !toInsert.isEmpty {
        let rows = toInsert
        try await database.write { db in
          for (asset, entry) in rows {
            let row = try asset.insertAndFetch(db)
            for projectID in entry.projectIDs {
              try db.execute(
                sql:
                  "INSERT OR IGNORE INTO asset_project (asset_id, project_id, added_at) VALUES (?, ?, ?)",
                arguments: [row.id, projectID, stamp])
            }
          }
        }
      }
      claimed += toInsert.map { asset, entry in
        ExternalsClaimedItem(
          key: asset.key, url: entry.candidate.fetchURL, sha256: asset.sha256,
          byteSize: asset.byteSize, projects: entry.projectSlugs)
      }
      if cancelled {
        remaining += plan.pending.count - index
        break
      }
    }

    // Point the scope's unmatched rows at what now exists.
    let relinked: Int
    if !relink {
      relinked = 0
    } else if dryRun {
      relinked = plan.relinkable(adding: claimed)
    } else {
      relinked = try await database.write { db in
        try CatalogUsage.relinkUnmatched(projects: plan.projectSlugs, stamp: stamp, db: db)
      }
    }

    return ExternalsClaimResult(
      dryRun: dryRun, references: references, distinctKeys: plan.distinctKeys,
      alreadyInCatalog: plan.alreadyInCatalog, claimed: claimed, skipped: skipped,
      cdnCheck: checks, refused: false, cancelled: cancelled, remaining: remaining,
      relinkedUsage: relinked)
  }

  /// Checks for a cancel inside the fetch slot, so a GET queued behind the
  /// concurrency bound is never sent once the run is cancelled.
  private struct CancelGuardFetcher: PublicObjectFetching {
    struct NotStarted: Error {}

    let base: any PublicObjectFetching
    let isCancelled: @Sendable () -> Bool

    func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
      let object = try await fetchObject(url)
      return (object.data, object.mime, object.contentLength)
    }

    func fetchObject(_ url: URL) async throws -> PublicObject {
      if isCancelled() { throw NotStarted() }
      return try await base.fetchObject(url)
    }
  }

  private static func sameContent(_ entry: Plan.Entry, existingKey: String)
    -> ExternalsClaimSkip
  {
    ExternalsClaimSkip(
      reason: ExternalsClaimSkipReason.sameContent, url: entry.candidate.fetchURL,
      key: entry.candidate.key, detail: "same image as \(existingKey)", existingKey: existingKey)
  }

  /// GET up to `sampleSize` assets Pinax uploaded itself (no
  /// `imported_from` in `meta`) from the current prefix and compare sha256.
  static func cdnCheck(
    backend: Backend, sampleSize: Int, in database: CatalogDatabasePool,
    fetcher: any PublicObjectFetching, gate: ImportSlotGate
  ) async throws -> CDNByteCheck {
    let samples = try await database.read { db in
      try Asset.fetchAll(
        db,
        sql: """
          SELECT * FROM asset
          WHERE backend_id = ? AND meta NOT LIKE '%imported_from%'
          ORDER BY id DESC LIMIT ?
          """,
        arguments: [backend.id, sampleSize])
    }
    let results = try await withThrowingTaskGroup(of: (String, Bool?).self) { group in
      for asset in samples {
        group.addTask {
          guard let url = URL(string: URLResolver.url(for: asset, backend: backend)) else {
            return (asset.key, nil)
          }
          do {
            let object = try await gate.withSlot { try await fetcher.fetchObject(url) }
            return (asset.key, Hashing.sha256(of: object.data) == asset.sha256)
          } catch is PublicObjectFetchError {
            return (asset.key, nil)
          }
        }
      }
      var collected: [(String, Bool?)] = []
      for try await result in group { collected.append(result) }
      return collected
    }
    let mismatched = results.filter { $0.1 == false }.map(\.0).sorted()
    let matched = results.filter { $0.1 == true }.count
    let status: CDNByteCheck.Status =
      !mismatched.isEmpty ? .rewritesBytes : matched > 0 ? .matched : .unchecked
    return CDNByteCheck(
      backend: backend.slug, status: status, sampled: samples.count, matched: matched,
      mismatched: mismatched, unreachable: results.count - matched - mismatched.count)
  }

  // MARK: - Planning

  /// What a run will do before any GET: the Your Domains references
  /// resolved, filtered and grouped by (backend, key).
  struct Plan {
    struct Entry: Sendable {
      let backendID: Int64
      let candidate: ObjectClaimCandidate
      let projectIDs: [Int64]
      let projectSlugs: [String]
    }

    var skipped: [ExternalsClaimSkip] = []
    var pending: [Entry] = []
    var distinctKeys = 0
    var alreadyInCatalog = 0
    var targetBackends: [Backend] = []
    var projectSlugs: [String] = []
    /// sha256 → key, per backend, for the same-content skip.
    var knownHashes: [Int64: [String: String]] = [:]
    /// Unmatched latest-scan rows by the (backend, key) they resolve to,
    /// for a dry run's relink count.
    private var unmatchedKeys: [Int64: [String: Int]] = [:]
    private var linkableNow = 0

    /// A plan whose entries are already resolved (the bucket import).
    init(
      pending: [Entry], skipped: [ExternalsClaimSkip], distinctKeys: Int, alreadyInCatalog: Int,
      targetBackends: [Backend], knownHashes: [Int64: [String: String]]
    ) {
      self.pending = pending
      self.skipped = skipped
      self.distinctKeys = distinctKeys
      self.alreadyInCatalog = alreadyInCatalog
      self.targetBackends = targetBackends
      self.knownHashes = knownHashes
    }

    init(references: [ExternalReference], urls: [String]?, db: GRDB.Database) throws {
      var selected = references
      if let urls {
        let wanted = Set(urls)
        selected = references.filter { wanted.contains($0.rawURL) }
        let present = Set(references.map(\.rawURL))
        for url in urls where !present.contains(url) {
          skipped.append(
            ExternalsClaimSkip(
              reason: ExternalsClaimSkipReason.notInYourDomains, url: url,
              detail: "not an unmatched Your Domains URL in the latest scan"))
        }
      }
      let projects = try Project.fetchAll(db)
      let projectsBySlug = Dictionary(uniqueKeysWithValues: projects.map { ($0.slug, $0) })
      let backends = Dictionary(
        uniqueKeysWithValues: try Backend.fetchAll(db).compactMap { b in b.id.map { ($0, b) } })
      var retired: [Int64: [String]] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT backend_id, url_prefix FROM backend_prefix_history ORDER BY id")
      {
        retired[row["backend_id"], default: []].append(row["url_prefix"])
      }

      struct Group {
        var backendID: Int64
        var key: String
        var firstURL: String
        /// Every reference to the key, query and fragment cut, in scan order.
        var recordedURLs: [String]
        var projectIDs: [Int64]
        var projectSlugs: [String]
      }
      var groups: [Group] = []
      var groupIndex: [String: Int] = [:]
      var reported = Set<String>()
      for reference in selected {
        guard let project = projectsBySlug[reference.projectSlug], let projectID = project.id,
          let backendID = project.backendID, let backend = backends[backendID]
        else { continue }
        // Only what the project's own scan would resolve.
        guard reference.match?.backendSlug == backend.slug,
          let key = URLResolver.key(
            from: reference.rawURL, backend: backend, retiredPrefixes: retired[backendID] ?? [])
        else {
          if reported.insert("o\u{0}\(reference.rawURL)").inserted {
            skipped.append(
              ExternalsClaimSkip(
                reason: ExternalsClaimSkipReason.otherBackend, url: reference.rawURL,
                detail:
                  "on \(reference.match?.backendSlug ?? "another backend")'s domain; project '\(project.slug)' uses \(backend.slug)"
              ))
          }
          continue
        }
        // Never claim a transform path or a key no upload would make.
        if key.isEmpty || key.hasPrefix("/") || key.hasPrefix("cdn-cgi/") {
          if reported.insert("b\u{0}\(reference.rawURL)").inserted {
            skipped.append(
              ExternalsClaimSkip(
                reason: ExternalsClaimSkipReason.badKey, url: reference.rawURL, key: key,
                detail: key.hasPrefix("cdn-cgi/")
                  ? "a Cloudflare transform path, not an object key"
                  : "a key starting with '/' or empty"))
          }
          continue
        }
        let id = "\(backendID)\u{0}\(key)"
        if let at = groupIndex[id] {
          groups[at].recordedURLs.append(AssetProvenance.recordedURL(reference.rawURL))
          if !groups[at].projectIDs.contains(projectID) {
            groups[at].projectIDs.append(projectID)
            groups[at].projectSlugs.append(project.slug)
          }
        } else {
          groupIndex[id] = groups.count
          groups.append(
            Group(
              backendID: backendID, key: key, firstURL: reference.rawURL,
              recordedURLs: [AssetProvenance.recordedURL(reference.rawURL)],
              projectIDs: [projectID], projectSlugs: [project.slug]))
        }
      }
      distinctKeys = groups.count

      var knownKeys: [Int64: Set<String>] = [:]
      var pendingDeletion: [Int64: Set<String>] = [:]
      for backendID in Set(groups.map(\.backendID)) {
        let rows = try Row.fetchAll(
          db, sql: "SELECT key, sha256 FROM asset WHERE backend_id = ? ORDER BY id",
          arguments: [backendID])
        knownKeys[backendID] = Set(rows.map { $0["key"] as String })
        knownHashes[backendID] = Dictionary(
          rows.map { ($0["sha256"] as String, $0["key"] as String) },
          uniquingKeysWith: { first, _ in first })
        pendingDeletion[backendID] = Set(
          try String.fetchAll(
            db, sql: "SELECT key FROM pending_deletion WHERE backend_id = ?",
            arguments: [backendID]))
      }

      var targets = Set<Int64>()
      for group in groups {
        guard let backend = backends[group.backendID] else { continue }
        let canonical = URLResolver.url(forKey: group.key, backend: backend)
        // A re-run filters what is already claimed before any GET.
        if knownKeys[group.backendID]?.contains(group.key) == true {
          alreadyInCatalog += 1
          continue
        }
        if pendingDeletion[group.backendID]?.contains(group.key) == true {
          skipped.append(
            ExternalsClaimSkip(
              reason: ExternalsClaimSkipReason.pendingDeletion, url: canonical, key: group.key,
              detail: "staged for permanent deletion"))
          continue
        }
        targets.insert(group.backendID)
        pending.append(
          Entry(
            backendID: group.backendID,
            // Always the current prefix — never a `?w=` variant or a
            // retired domain that may no longer answer.
            candidate: ObjectClaimCandidate(
              key: group.key, fetchURL: canonical, reportURL: canonical, width: nil,
              height: nil,
              // The key's last segment.
              originalFilename: group.key.split(separator: "/").last.map(String.init),
              uploadedAt: nil,
              // The reference that is the canonical URL, else the
              // first one; always next to `imported_from`.
              meta: AssetProvenance.meta(
                importedFrom: "externals",
                sourceURL: group.recordedURLs.first { $0 == canonical } ?? group.recordedURLs.first)),
            projectIDs: group.projectIDs, projectSlugs: group.projectSlugs))
      }
      targetBackends = targets.sorted().compactMap { backends[$0] }

      // The relink scope, and what a dry run would relink.
      let scopeSlugs = Set(references.map(\.projectSlug))
      projectSlugs = scopeSlugs.sorted()
      for slug in projectSlugs {
        guard let project = projectsBySlug[slug], let projectID = project.id,
          let scanID = project.lastScanID, let backendID = project.backendID,
          let backend = backends[backendID]
        else { continue }
        for rawURL in try String.fetchAll(
          db,
          sql:
            "SELECT raw_url FROM usage WHERE project_id = ? AND last_scan_id = ? AND asset_id IS NULL",
          arguments: [projectID, scanID])
        {
          if try CatalogUsage.usageAssetID(
            for: rawURL, backend: backend, retiredPrefixes: retired[backendID] ?? [], db: db)
            != nil
          {
            linkableNow += 1
          } else if let key = URLResolver.key(
            from: rawURL, backend: backend, retiredPrefixes: retired[backendID] ?? [])
          {
            unmatchedKeys[backendID, default: [:]][key, default: 0] += 1
          }
        }
      }
    }

    /// A dry run's relink count: rows that resolve today, plus rows whose
    /// key the run would have claimed.
    func relinkable(adding claimed: [ExternalsClaimedItem]) -> Int {
      let claimedKeys = Set(
        pending.filter { entry in claimed.contains { $0.key == entry.candidate.key } }
          .map { "\($0.backendID)\u{0}\($0.candidate.key)" })
      var count = linkableNow
      for (backendID, keys) in unmatchedKeys {
        for (key, rows) in keys where claimedKeys.contains("\(backendID)\u{0}\(key)") {
          count += rows
        }
      }
      return count
    }
  }
}
