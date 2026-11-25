import Foundation
import GRDB

public enum ReindexError: Error, Equatable, CustomStringConvertible {
  case backendNotPersisted(String)
  case keyConflict(String)

  public var description: String {
    switch self {
    case let .backendNotPersisted(slug):
      return "Backend '\(slug)' is not persisted."
    case let .keyConflict(key):
      return "Object key '\(key)' conflicts with a different catalog asset."
    }
  }
}

public struct ReindexMissingMetadata: Codable, Equatable, Sendable {
  public let key: String
  public let missing: [String]

  public init(key: String, missing: [String]) {
    self.key = key
    self.missing = missing
  }
}

public struct ReindexResult: Codable, Equatable, Sendable {
  public let schema: Int
  public let scanned: Int
  public let reconstructed: Int
  public let existing: Int
  public let missingMetadata: [ReindexMissingMetadata]
  public let dryRun: Bool
  /// Objects whose key has a tombstone: owed a delete, or removed
  /// from the catalog on purpose. Encoded only when there are any, so the
  /// output is unchanged otherwise.
  public let skippedPendingDeletion: Int?

  enum CodingKeys: String, CodingKey {
    case schema, scanned, reconstructed, existing
    case missingMetadata = "missing_metadata"
    case dryRun = "dry_run"
    case skippedPendingDeletion = "skipped_pending_deletion"
  }

  public init(
    schema: Int = 1,
    scanned: Int,
    reconstructed: Int,
    existing: Int,
    missingMetadata: [ReindexMissingMetadata],
    dryRun: Bool,
    skippedPendingDeletion: Int? = nil
  ) {
    self.schema = schema
    self.scanned = scanned
    self.reconstructed = reconstructed
    self.existing = existing
    self.missingMetadata = missingMetadata
    self.dryRun = dryRun
    self.skippedPendingDeletion = skippedPendingDeletion
  }
}

public enum CatalogReindex {
  public static func run(
    backend: Backend,
    inventory: any ObjectInventory,
    database: CatalogDatabasePool,
    dryRun: Bool = false,
    now: Date = Date()
  ) async throws -> ReindexResult {
    guard dryRun || backend.id != nil else {
      throw ReindexError.backendNotPersisted(backend.slug)
    }
    let backendID = backend.id ?? -1
    let summaries = try await inventory.listObjects()
    var candidates: [ReindexCandidate] = []
    candidates.reserveCapacity(summaries.count)
    var missingMetadata: [ReindexMissingMetadata] = []
    // A tombstoned key was deleted from the catalog on purpose:
    // bringing it back would undo the deletion.
    let tombstoned = try await database.read { db in
      try Set(
        String.fetchAll(
          db,
          sql: """
            SELECT d.key FROM pending_deletion d JOIN backend b ON b.id = d.backend_id
            WHERE rtrim(lower(b.endpoint), '/') = rtrim(lower(?), '/') AND b.bucket = ?
            """, arguments: [backend.endpoint, backend.bucket]))
    }
    var skipped = 0

    for summary in summaries {
      if tombstoned.contains(summary.key) {
        skipped += 1
        continue
      }
      let head = try await inventory.headObject(key: summary.key)
      switch try candidate(from: head, summary: summary) {
      case let .valid(candidate):
        candidates.append(candidate)
      case let .missing(fields):
        missingMetadata.append(ReindexMissingMetadata(key: summary.key, missing: fields))
      }
    }

    let timestamp = ISO8601DateFormatter().string(from: now)
    let validCandidates = candidates
    let counts = try await database.write { db -> (reconstructed: Int, existing: Int) in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT sha256, key FROM asset WHERE backend_id = ?",
        arguments: [backendID]
      )
      var knownHashes = Set(rows.map { (row: Row) -> String in row["sha256"] })
      var knownKeys = Dictionary(
        uniqueKeysWithValues: rows.map { (row: Row) -> (String, String) in
          (row["key"], row["sha256"])
        }
      )
      var reconstructed = 0
      var existing = 0
      for candidate in validCandidates {
        if knownHashes.contains(candidate.sha256) {
          existing += 1
          // A compressed copy's original hash fills a row that lacks it.
          if !dryRun, let sourceSHA256 = candidate.sourceSHA256 {
            try db.execute(
              sql: """
                UPDATE asset SET source_sha256 = ?
                WHERE backend_id = ? AND sha256 = ? AND source_sha256 IS NULL
                """, arguments: [sourceSHA256, backendID, candidate.sha256])
          }
          continue
        }
        if knownKeys[candidate.key] != nil {
          throw ReindexError.keyConflict(candidate.key)
        }
        reconstructed += 1
        knownHashes.insert(candidate.sha256)
        knownKeys[candidate.key] = candidate.sha256
        guard !dryRun else { continue }
        var asset = Asset(
          sha256: candidate.sha256,
          backendID: backendID,
          key: candidate.key,
          byteSize: candidate.byteSize,
          width: candidate.width,
          height: candidate.height,
          mime: candidate.mime,
          originalFilename: candidate.originalFilename,
          uploadedAt: candidate.uploadedAt ?? timestamp,
          createdAt: timestamp,
          updatedAt: timestamp,
          sourceSHA256: candidate.sourceSHA256
        )
        try asset.insert(db)
      }
      return (reconstructed, existing)
    }
    return ReindexResult(
      scanned: summaries.count,
      reconstructed: counts.reconstructed,
      existing: counts.existing,
      missingMetadata: missingMetadata,
      dryRun: dryRun,
      skippedPendingDeletion: skipped > 0 ? skipped : nil
    )
  }

  private static func candidate(
    from head: S3ObjectHead,
    summary: S3ObjectSummary
  ) throws -> CandidateResult {
    var missing: [String] = []
    let sha256 = head.metadata["sha256"]
    if !isHexDigest(sha256) {
      missing.append("sha256")
    }
    // Optional: only compressed copies carry it, and a bad value is ignored.
    let sourceSHA256 = head.metadata["source-sha256"].flatMap { isHexDigest($0) ? $0 : nil }
    let originalFilename: String?
    if let encodedFilename = head.metadata["orig-filename"], !encodedFilename.isEmpty {
      originalFilename = try? MetadataValueCodec.decode(encodedFilename)
      if originalFilename == nil {
        missing.append("orig-filename")
      }
    } else {
      originalFilename = nil
      missing.append("orig-filename")
    }
    let width = head.metadata["width"].flatMap(Int.init)
    if width.map({ $0 > 0 }) != true {
      missing.append("width")
    }
    let height = head.metadata["height"].flatMap(Int.init)
    if height.map({ $0 > 0 }) != true {
      missing.append("height")
    }
    guard let mime = head.mime, !mime.isEmpty else {
      missing.append("content-type")
      return .missing(missing)
    }
    guard missing.isEmpty,
      let sha256,
      let originalFilename,
      let width,
      let height
    else {
      return .missing(missing)
    }
    return .valid(
      ReindexCandidate(
        key: head.key,
        sha256: sha256,
        byteSize: head.byteSize > 0 ? head.byteSize : summary.byteSize,
        width: width,
        height: height,
        mime: mime,
        originalFilename: originalFilename,
        uploadedAt: normalizedTimestamp(summary.lastModified)
          ?? normalizedTimestamp(head.lastModified),
        sourceSHA256: sourceSHA256
      ))
  }

  /// 64 lowercase hex digits.
  private static func isHexDigest(_ value: String?) -> Bool {
    value?.count == 64
      && value?.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }) == true
  }

  private static func normalizedTimestamp(_ value: String?) -> String? {
    guard let value else { return nil }
    let date =
      fractionalISO8601.date(from: value)
      ?? internetISO8601.date(from: value)
      ?? rfc1123.date(from: value)
    return date.map(internetISO8601.string(from:))
  }

  private static let fractionalISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let internetISO8601 = ISO8601DateFormatter()

  private static let rfc1123: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    formatter.isLenient = false
    return formatter
  }()
}

private enum CandidateResult {
  case valid(ReindexCandidate)
  case missing([String])
}

private struct ReindexCandidate {
  let key: String
  let sha256: String
  let byteSize: Int64
  let width: Int
  let height: Int
  let mime: String
  let originalFilename: String
  let uploadedAt: String?
  let sourceSHA256: String?
}
