import CryptoKit
import Foundation
import GRDB

// MARK: - Bounded concurrency

/// Slot gate with hand-off — the semantics of the thumbnail pipeline's gate:
/// a queued caller receives its slot directly from the
/// releaser rather than re-taking it, so no caller can observe a temporarily
/// low holder count and overshoot the bound.
actor ImportSlotGate {
  private let capacity: Int
  private var holders = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  func withSlot<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async rethrows -> T {
    if holders < capacity {
      holders += 1
    } else {
      await withCheckedContinuation { continuation in
        waiting.append(continuation)
      }
    }
    defer {
      if waiting.isEmpty {
        holders -= 1
      } else {
        waiting.removeFirst().resume()
      }
    }
    return try await operation()
  }
}

// MARK: - Result contracts

public enum PicGoSkipReason {
  public static let prefixMismatch = "prefix_mismatch"
  public static let forbidden = "forbidden"
  public static let notFound = "not_found"
  public static let fetchFailed = "fetch_failed"
  public static let lengthMismatch = "length_mismatch"
}

public struct PicGoImportSkipped: Codable, Equatable, Sendable {
  public let url: String
  public let reason: String
  public let detail: String?

  public init(url: String, reason: String, detail: String? = nil) {
    self.url = url
    self.reason = reason
    self.detail = detail
  }
}

public struct PicGoImportResult: Codable, Equatable, Sendable {
  public let schema: Int
  public let recordsRead: Int
  public let distinctKeys: Int
  public let imported: Int
  public let alreadyPresent: Int
  public let skipped: [PicGoImportSkipped]
  public let duplicateSourceRecords: Int
  public let importedViaRetiredPrefix: Int
  public let dryRun: Bool

  public init(
    schema: Int = 1,
    recordsRead: Int,
    distinctKeys: Int,
    imported: Int,
    alreadyPresent: Int,
    skipped: [PicGoImportSkipped],
    duplicateSourceRecords: Int,
    importedViaRetiredPrefix: Int,
    dryRun: Bool
  ) {
    self.schema = schema
    self.recordsRead = recordsRead
    self.distinctKeys = distinctKeys
    self.imported = imported
    self.alreadyPresent = alreadyPresent
    self.skipped = skipped
    self.duplicateSourceRecords = duplicateSourceRecords
    self.importedViaRetiredPrefix = importedViaRetiredPrefix
    self.dryRun = dryRun
  }

  enum CodingKeys: String, CodingKey {
    case schema
    case recordsRead = "records_read"
    case distinctKeys = "distinct_keys"
    case imported
    case alreadyPresent = "already_present"
    case skipped
    case duplicateSourceRecords = "duplicate_source_records"
    case importedViaRetiredPrefix = "imported_via_retired_prefix"
    case dryRun = "dry_run"
  }
}

public struct PicGoBackfillFailure: Codable, Equatable, Sendable {
  public let key: String
  public let detail: String

  public init(key: String, detail: String) {
    self.key = key
    self.detail = detail
  }
}

public struct PicGoBackfillResult: Codable, Equatable, Sendable {
  public let schema: Int
  public let checked: Int
  public let skippedMatching: Int
  public let backfilled: Int
  public let failed: [PicGoBackfillFailure]
  public let dryRun: Bool

  public init(
    schema: Int = 1,
    checked: Int,
    skippedMatching: Int,
    backfilled: Int,
    failed: [PicGoBackfillFailure],
    dryRun: Bool
  ) {
    self.schema = schema
    self.checked = checked
    self.skippedMatching = skippedMatching
    self.backfilled = backfilled
    self.failed = failed
    self.dryRun = dryRun
  }

  enum CodingKeys: String, CodingKey {
    case schema
    case checked
    case skippedMatching = "skipped_matching"
    case backfilled
    case failed
    case dryRun = "dry_run"
  }
}

// MARK: - Importer

/// Imports a parsed PicGo gallery into the catalog. Flat on purpose: no
/// derived projects, no derived tags, provenance in `asset.meta`.
/// Idempotent: dedupe on
/// `(backend_id, key)` and `(backend_id, sha256)`, inserts land in one
/// transaction, and no sha256 is ever synthesised.
public enum PicGoGalleryImporter {
  public static func importGallery(
    records: [PicGoGalleryRecord],
    backend: Backend,
    in database: CatalogDatabasePool,
    fetcher: any PublicObjectFetching,
    now: Date = Date(),
    dryRun: Bool = false,
    maxConcurrentFetches: Int = 8
  ) async throws -> PicGoImportResult {
    guard let backendID = backend.id else {
      throw CatalogConfigurationError.backendNotFound(backend.slug)
    }
    let retiredPrefixes = try await database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT url_prefix FROM backend_prefix_history WHERE backend_id = ? ORDER BY id",
        arguments: [backendID]
      )
    }

    // Resolve keys. A URL matching no prefix is skipped, never guessed at;
    // a retired-prefix match is legitimate and reported separately.
    var skipped: [PicGoImportSkipped] = []
    var resolved: [Resolved] = []
    var duplicateSourceRecords = 0
    var seenKeys = Set<String>()
    for record in records {
      guard let (key, viaRetiredPrefix) = resolveKey(
        of: record.url, backend: backend, retiredPrefixes: retiredPrefixes)
      else {
        skipped.append(
          PicGoImportSkipped(
            url: record.url, reason: PicGoSkipReason.prefixMismatch,
            detail: "no current or retired backend prefix matches"))
        continue
      }
      guard seenKeys.insert(key).inserted else {
        duplicateSourceRecords += 1
        continue
      }
      resolved.append(Resolved(record: record, key: key, viaRetiredPrefix: viaRetiredPrefix))
    }

    let (knownKeys, knownHashes) = try await database.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT key, sha256 FROM asset WHERE backend_id = ?", arguments: [backendID])
      let keys = Set(rows.map { $0["key"] as String })
      let hashes = Dictionary(
        rows.map { ($0["sha256"] as String, $0["key"] as String) }, uniquingKeysWith: { a, _ in a })
      return (keys, hashes)
    }

    var alreadyPresent = resolved.filter { knownKeys.contains($0.key) }.count
    let pending = resolved.filter { !knownKeys.contains($0.key) }

    // Fetch and hash off the shared gate; outcomes map onto the original
    // order so the result is deterministic regardless of completion order.
    let gate = ImportSlotGate(capacity: maxConcurrentFetches)
    let outcomes = try await withThrowingTaskGroup(
      of: (String, ObjectClaimOutcome).self
    ) { group in
      for entry in pending {
        group.addTask {
          let outcome = try await ObjectClaim.prepare(
            candidate(for: entry), backendID: backendID, knownHashes: knownHashes, now: now,
            uploadedAtFallback: .now, fetcher: fetcher, gate: gate)
          return (entry.key, outcome)
        }
      }
      var collected: [String: ObjectClaimOutcome] = [:]
      for try await (key, outcome) in group {
        collected[key] = outcome
      }
      return collected
    }

    // Batch-level sha dedup, in the ordered collection loop. `knownHashes` is
    // a pre-import snapshot and knows nothing about this batch: the source's
    // key template (`…-{md5}-{unixtime}`) makes two different keys carrying
    // identical bytes routine, and two such inserts in one transaction hit
    // ux_asset_sha and roll back the entire import. Counting them here (not
    // in ObjectClaim.prepare) keeps the result independent of completion order.
    var prepared: [Asset] = []
    var batchHashes = Set(knownHashes.keys)
    for entry in pending {
      switch outcomes[entry.key] {
      case let .prepared(asset):
        if batchHashes.insert(asset.sha256).inserted {
          prepared.append(asset)
        } else {
          alreadyPresent += 1
        }
      case let .skipped(skip):
        skipped.append(skip)
      case .contentDuplicate:
        alreadyPresent += 1
      case nil:
        // Unreachable: every pending entry produced an outcome.
        skipped.append(
          PicGoImportSkipped(
            url: entry.record.url, reason: PicGoSkipReason.fetchFailed,
            detail: "no outcome recorded"))
      }
    }

    if !dryRun {
      // A let snapshot keeps the write closure's capture immutable.
      let toInsert = prepared
      try await database.write { db in
        for var asset in toInsert {
          try asset.insert(db)
        }
      }
    }

    return PicGoImportResult(
      recordsRead: records.count,
      distinctKeys: resolved.count,
      imported: prepared.count,
      alreadyPresent: alreadyPresent,
      skipped: skipped,
      duplicateSourceRecords: duplicateSourceRecords,
      importedViaRetiredPrefix: resolved.filter(\.viaRetiredPrefix).count,
      dryRun: dryRun
    )
  }

  private static let provenanceMeta = "{\"imported_from\":\"picgo\"}"

  private struct Resolved {
    let record: PicGoGalleryRecord
    let key: String
    let viaRetiredPrefix: Bool
  }

  /// A gallery record as a claim: fetched from the record's own URL, its
  /// recorded dimensions and file name kept, `createdAt` as `uploaded_at`.
  private static func candidate(for entry: Resolved) -> ObjectClaimCandidate {
    ObjectClaimCandidate(
      key: entry.key,
      fetchURL: entry.record.url,
      reportURL: entry.record.url,
      width: entry.record.width,
      height: entry.record.height,
      originalFilename: entry.record.fileName.isEmpty ? nil : entry.record.fileName,
      uploadedAt: entry.record.createdAtMilliseconds > 0
        ? ObjectClaim.iso8601.string(
          from: Date(
            timeIntervalSince1970: TimeInterval(entry.record.createdAtMilliseconds / 1000)))
        : nil,
      meta: provenanceMeta)
  }

  /// The current prefix wins; retired prefixes from `backend_prefix_history`
  /// are legitimate matches for objects uploaded before a prefix change.
  private static func resolveKey(
    of url: String,
    backend: Backend,
    retiredPrefixes: [String]
  ) -> (key: String, viaRetiredPrefix: Bool)? {
    for prefix in [backend.urlPrefix] + retiredPrefixes {
      var candidate = backend
      candidate.urlPrefix = prefix
      if let key = URLResolver.key(from: url, backend: candidate) {
        return (key, prefix != backend.urlPrefix)
      }
    }
    return nil
  }
}

// MARK: - Object metadata backfill

/// What a HEAD pass decided about one backend's objects. `plan` is cheap and
/// side-effect free; the CLI prints it and asks for confirmation before
/// `apply` writes anything. Candidates carry their HEAD result so
/// `apply` writes back the exact Content-Type (and Cache-Control, when HEAD
/// reported one). No ACL travels this path: HEAD responses never carry one,
/// so there is nothing truthful to write back — see
/// `requiresACLResetAcknowledgement`.
public struct PicGoBackfillCandidate: Sendable {
  public let asset: Asset
  public let head: S3ObjectHead

  public init(asset: Asset, head: S3ObjectHead) {
    self.asset = asset
    self.head = head
  }
}

public struct PicGoBackfillPlan: Sendable {
  public let matchingKeys: [String]
  public let candidates: [PicGoBackfillCandidate]
  public let headFailures: [PicGoBackfillFailure]

  public init(
    matchingKeys: [String],
    candidates: [PicGoBackfillCandidate],
    headFailures: [PicGoBackfillFailure]
  ) {
    self.matchingKeys = matchingKeys
    self.candidates = candidates
    self.headFailures = headFailures
  }
}

/// Opt-in, off by default. Re-`PutObject`s each object onto itself with
/// the metadata `pinax db reindex` reads, so a read-only import does not leave
/// assets that can only be recovered from a catalog backup. Content-Type and
/// ACL are preserved by writing back exactly what HEAD returned; an object
/// already carrying a matching sha256 is a `matchingKey`, so a half-finished
/// run can simply be re-run.
public enum PicGoBackfill {
  public static func assets(
    for backend: Backend,
    in database: CatalogDatabasePool
  ) throws -> [Asset] {
    guard let backendID = backend.id else {
      throw CatalogConfigurationError.backendNotFound(backend.slug)
    }
    return try database.read { db in
      try Asset.order(Column("key")).filter(Column("backend_id") == backendID).fetchAll(db)
    }
  }

  private enum PlanOutcome: Sendable {
    case matching
    case needsWrite(S3ObjectHead)
    case headFailure(String)
  }

  public static func plan(
    assets: [Asset],
    inventory: any ObjectInventory,
    maxConcurrent: Int = 8
  ) async throws -> PicGoBackfillPlan {
    let gate = ImportSlotGate(capacity: maxConcurrent)
    let outcomes = try await withThrowingTaskGroup(
      of: (String, PlanOutcome).self
    ) { group in
      for asset in assets {
        group.addTask {
          do {
            let head = try await gate.withSlot { try await inventory.headObject(key: asset.key) }
            return (
              asset.key,
              head.metadata["sha256"] == asset.sha256 ? .matching : .needsWrite(head)
            )
          } catch {
            return (asset.key, .headFailure(String(describing: error)))
          }
        }
      }
      var collected: [String: PlanOutcome] = [:]
      for try await (key, outcome) in group {
        collected[key] = outcome
      }
      return collected
    }
    var matching: [String] = []
    var candidates: [PicGoBackfillCandidate] = []
    var failures: [PicGoBackfillFailure] = []
    for asset in assets {
      switch outcomes[asset.key] {
      case .matching:
        matching.append(asset.key)
      case let .needsWrite(head):
        candidates.append(PicGoBackfillCandidate(asset: asset, head: head))
      case let .headFailure(detail):
        failures.append(PicGoBackfillFailure(key: asset.key, detail: "HEAD failed: \(detail)"))
      case nil:
        failures.append(PicGoBackfillFailure(key: asset.key, detail: "no outcome recorded"))
      }
    }
    return PicGoBackfillPlan(
      matchingKeys: matching, candidates: candidates, headFailures: failures)
  }

  public static func apply(
    plan: PicGoBackfillPlan,
    backend: Backend,
    uploader: any Uploader,
    fetcher: any PublicObjectFetching,
    dryRun: Bool = false,
    maxConcurrent: Int = 8
  ) async throws -> PicGoBackfillResult {
    let gate = ImportSlotGate(capacity: maxConcurrent)
    let outcomes = try await withThrowingTaskGroup(
      of: (String, ApplyOutcome).self
    ) { group in
      for candidate in plan.candidates {
        group.addTask {
          (
            candidate.asset.key,
            await applyOne(candidate, backend: backend, uploader: uploader, fetcher: fetcher, gate: gate, dryRun: dryRun)
          )
        }
      }
      var collected: [String: ApplyOutcome] = [:]
      for try await (key, outcome) in group {
        collected[key] = outcome
      }
      return collected
    }
    var backfilled = 0
    var failed = plan.headFailures
    for candidate in plan.candidates {
      switch outcomes[candidate.asset.key] {
      case .written:
        backfilled += 1
      case let .failure(detail):
        failed.append(PicGoBackfillFailure(key: candidate.asset.key, detail: detail))
      case nil:
        failed.append(PicGoBackfillFailure(key: candidate.asset.key, detail: "no outcome recorded"))
      }
    }
    return PicGoBackfillResult(
      checked: plan.matchingKeys.count + plan.candidates.count + plan.headFailures.count,
      skippedMatching: plan.matchingKeys.count,
      backfilled: backfilled,
      failed: failed,
      dryRun: dryRun
    )
  }

  private enum ApplyOutcome: Sendable {
    case written
    case failure(String)
  }

  private static func applyOne(
    _ candidate: PicGoBackfillCandidate,
    backend: Backend,
    uploader: any Uploader,
    fetcher: any PublicObjectFetching,
    gate: ImportSlotGate,
    dryRun: Bool
  ) async -> ApplyOutcome {
    let asset = candidate.asset
    guard let url = URL(string: URLResolver.url(for: asset, backend: backend)) else {
      return .failure("malformed object URL")
    }
    let bytes: (data: Data, mime: String?, contentLength: Int64?)
    do {
      bytes = try await gate.withSlot { try await fetcher.fetch(url) }
    } catch {
      return .failure("fetch failed: \(String(describing: error))")
    }
    let digest = SHA256.hash(data: bytes.data).map { String(format: "%02x", $0) }.joined()
    guard digest == asset.sha256 else {
      // Never write metadata onto bytes that are not the cataloged asset.
      return .failure("object content does not match the catalog row")
    }
    guard !dryRun else {
      return .written
    }
    // Content-Type is written back exactly as HEAD reported it. Cache-Control
    // is written back when HEAD reported one, and set to the immutable policy
    // otherwise. No ACL is sent at all: HEAD responses never carry x-amz-acl
    // (it is a PUT request header), so "preserving" it was never possible —
    // R2 has no per-object ACL and is unaffected; on other S3 providers the
    // rewrite lands on the bucket default, which `requiresACLResetAcknowledgement`
    // makes the caller acknowledge up front.
    let head = candidate.head
    var metadata = ["sha256": asset.sha256]
    if let filename = asset.originalFilename {
      metadata["orig-filename"] = MetadataValueCodec.encode(filename)
    }
    if let width = asset.width {
      metadata["width"] = String(width)
    }
    if let height = asset.height {
      metadata["height"] = String(height)
    }
    let request = UploadRequest(
      data: bytes.data,
      sha256: digest,
      key: asset.key,
      mime: head.mime ?? bytes.mime ?? asset.mime,
      metadata: metadata,
      cacheControl: head.cacheControl ?? S3Uploader.immutableCacheControl
    )
    do {
      _ = try await gate.withSlot { try await uploader.upload(request) }
    } catch {
      return .failure("upload failed: \(String(describing: error))")
    }
    return .written
  }

  /// Heuristic endpoint check: R2 hostnames end in `r2.cloudflarestorage.com`
  /// and R2 has no per-object ACL, so a metadata rewrite cannot change
  /// visibility there. Any other endpoint gets the benefit of the doubt and
  /// requires an explicit acknowledgement before backfill.
  public static func requiresACLResetAcknowledgement(_ backend: Backend) -> Bool {
    !backend.endpoint.contains(".r2.cloudflarestorage.com")
  }
}
