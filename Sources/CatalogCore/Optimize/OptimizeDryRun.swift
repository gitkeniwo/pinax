import Foundation
import GRDB

public enum OptimizeError: Error, Equatable, CustomStringConvertible {
  /// No active JPEG on the backend matches.
  case noImages(backend: String, prefix: String, names: [String])
  /// Not one sampled object could be read. The run is recorded as failed.
  case nothingRead(runID: Int64, sampled: Int, firstFailure: String)

  public var description: String {
    switch self {
    case let .noImages(backend, prefix, names):
      var what = "No active JPEG assets on backend \(backend)"
      if !prefix.isEmpty { what += " under \"\(prefix)\"" }
      if !names.isEmpty {
        what += " named " + names.map { "\"\($0)\"" }.joined(separator: " or ")
      }
      return what + "."
    case let .nothingRead(runID, sampled, firstFailure):
      return "None of the \(sampled) sampled objects could be read (run \(runID)): \(firstFailure)"
    }
  }
}

public struct OptimizeDryRunResult: Sendable {
  public let runID: Int64
  public let report: OptimizeReport
}

/// Measures what recompressing a backend's JPEGs in place would save. It reads
/// a sample from the bucket, compresses each copy in memory, and records a
/// dry-run `optimize` run. It can only read: no object and no asset row
/// changes, and no image bytes are written to disk.
public enum OptimizeDryRun {
  /// How many objects are read and compressed at a time.
  static let concurrency = 4

  /// A session for the reader. `URLSession.shared` would keep a copy of each
  /// cacheable object in the on-disk URL cache.
  public static func uncachedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }

  /// - Parameters:
  ///   - prefix: the start of the keys to select; empty selects every key.
  ///   - names: file names to keep, any of them; empty keeps all.
  ///   - sample: how many to measure; nil measures every selected image.
  ///   - seed: which sample to draw; nil takes the run's number.
  public static func run(
    backend: Backend,
    prefix: String = "",
    names: [String] = [],
    options: CompressionOptions = .default,
    sample sampleCount: Int?,
    seed requestedSeed: UInt64? = nil,
    reader: any ObjectReading,
    database: CatalogDatabasePool,
    now: Date = Date()
  ) async throws -> OptimizeDryRunResult {
    guard let backendID = backend.id else {
      throw CatalogConfigurationError.backendNotFound(backend.slug)
    }
    let selection = try OptimizeSelection.read(
      backendID: backendID, prefix: prefix, names: names, in: database)
    guard !selection.images.isEmpty else {
      throw OptimizeError.noImages(backend: backend.slug, prefix: prefix, names: names)
    }

    let params = OptimizeRunParams(
      backend: backend.slug, prefix: prefix, names: names, options: options, sample: sampleCount,
      seed: requestedSeed)
    let runID = try RunLog.start(
      kind: .optimize, backendID: backendID, dryRun: true, params: params, in: database, now: now)
    do {
      let seed = requestedSeed ?? UInt64(runID)
      let sample = selection.sample(sampleCount, seed: seed)
      try RunLog.append(
        .optimizeSelected(
          OptimizeSelectedEvent(
            seed: seed, sample: sample.count,
            images: selection.images.compactMap { asset in
              asset.id.map {
                OptimizeSelectedImage(
                  assetID: $0, key: asset.key, sha256: asset.sha256, bytes: asset.byteSize)
              }
            })),
        to: runID, in: database)

      var results: [ObjectMeasuredEvent] = []
      var errors = 0
      try await withThrowingTaskGroup(of: ObjectMeasuredEvent.self) { group in
        var pending = sample.makeIterator()
        func startNext() {
          guard let asset = pending.next() else { return }
          group.addTask {
            try await measure(asset, options: options, reader: reader, database: database)
          }
        }
        for _ in 0..<concurrency { startNext() }
        while let result = try await group.next() {
          let record = try RunLog.append(.objectMeasured(result), to: runID, in: database)
          if record.level == .error { errors += 1 }
          results.append(result)
          startNext()
        }
      }

      let report = OptimizeReport(
        params: params, seed: seed, selection: selection, sample: sample, results: results)
      let nothingRead = !results.contains { $0.outcome.wasRead }
      var summary = RewriteRunSummary(errors: errors)
      summary.optimize = report
      try RunLog.append(.runFinished(summary), to: runID, in: database)
      try RunLog.finish(
        runID, state: nothingRead ? .failed : .finished, summary: summary, in: database)
      if nothingRead {
        throw OptimizeError.nothingRead(
          runID: runID, sampled: sample.count, firstFailure: results.first?.detail ?? "not found")
      }
      return OptimizeDryRunResult(runID: runID, report: report)
    } catch {
      RunLog.fail(runID, in: database)
      throw error
    }
  }

  /// Reads one object and says what replacing it would do. The bytes stay in
  /// memory. Throws only for a catalog error or a cancelled task; a failed
  /// read is an outcome.
  private static func measure(
    _ asset: Asset, options: CompressionOptions, reader: any ObjectReading,
    database: CatalogDatabasePool
  ) async throws -> ObjectMeasuredEvent {
    var event = ObjectMeasuredEvent(
      assetID: asset.id ?? 0, key: asset.key, outcome: .readFailed, bytesBefore: asset.byteSize,
      widthBefore: asset.width, heightBefore: asset.height)
    func ending(_ outcome: OptimizeOutcome, detail: String? = nil) -> ObjectMeasuredEvent {
      var ended = event
      ended.outcome = outcome
      ended.detail = detail
      return ended
    }

    let object: S3StoredObject
    do {
      object = try await reader.getObject(key: asset.key)
    } catch let ObjectReadError.lengthMismatch(_, _, _, encoding?)
      where encoding.lowercased() != "identity"
    {
      // `URLSession` decoded the body, so the stored bytes never arrive.
      return ending(.unsupportedHeaders, detail: "Content-Encoding: \(encoding)")
    } catch ObjectReadError.notFound {
      return ending(.notFound)
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      return ending(.readFailed, detail: failureText(error))
    }
    guard Hashing.sha256(of: object.data) == asset.sha256 else {
      return ending(.hashMismatch)
    }

    let result = autoreleasepool { ImageCompressor.compress(object.data, options: options) }
    let copy: CompressedImage
    switch result {
    case let .skipped(reason):
      return ending(OptimizeOutcome(reason))
    case let .compressed(image):
      copy = image
    }
    let hash = Hashing.sha256(of: copy.data)
    event.bytesAfter = Int64(copy.byteSize)
    event.widthBefore = copy.sourceWidth
    event.heightBefore = copy.sourceHeight
    event.widthAfter = copy.width
    event.heightAfter = copy.height
    event.sha256After = hash

    let mediaType = object.contentType?
      .split(separator: ";").first?
      .trimmingCharacters(in: .whitespaces).lowercased()
    guard mediaType == copy.mime, copy.sourceMime == copy.mime else {
      return ending(
        .formatWouldChange,
        detail: "served as \(object.contentType ?? "no Content-Type"), holds \(copy.sourceMime)")
    }
    let taken = try await database.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (SELECT 1 FROM asset
            WHERE backend_id = ? AND id != ? AND (sha256 = ? OR source_sha256 = ?))
          """,
        arguments: [asset.backendID, asset.id, hash, hash]) ?? false
    }
    if taken { return ending(.duplicateHash) }
    let lost = headersLost(by: object)
    if !lost.isEmpty {
      return ending(.unsupportedHeaders, detail: lost.joined(separator: ", "))
    }
    return ending(.smaller)
  }

  /// The names of what a replacement upload would drop.
  static func headersLost(by object: S3StoredObject) -> [String] {
    let foreign = object.metadata.keys
      .map { "x-amz-meta-\($0)" }
      .filter { !S3Uploader.allowedMetadata.contains($0) }
    return object.otherHeaders.keys.sorted() + foreign.sorted()
  }

  private static func failureText(_ error: Error) -> String {
    let text: String
    switch error {
    case let S3UploaderError.http(statusCode, _): text = "HTTP \(statusCode)"
    case let error as URLError: text = error.localizedDescription
    default: text = String(describing: error)
    }
    return String(text.prefix(300))
  }
}

extension OptimizeOutcome {
  init(_ reason: SkipReason) {
    switch reason {
    case .notSmaller: self = .notSmaller
    case .transparent: self = .transparent
    case .animated: self = .animated
    case .unsupportedFormat: self = .unsupportedFormat
    case .unreadable: self = .unreadable
    }
  }
}
