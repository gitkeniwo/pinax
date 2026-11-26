import ArgumentParser
import CatalogCore
import Foundation

/// `pinax optimize --dry-run`: measures what recompressing a backend's JPEGs
/// at the same keys would save. It only reads from the bucket. `perform` is
/// what `run()` prints, so tests drive the parsed command with a stub store.
struct OptimizeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "optimize",
    abstract: "Measure what recompressing a backend's JPEGs in place would save."
  )

  @Option(help: "Backend whose images to measure.")
  var backend: String

  @Option(help: "Only keys that start with this.")
  var prefix = ""

  @Option(
    help: "Only keys whose last path component is exactly this, case included. Repeatable.")
  var name: [String] = []

  @Flag(help: "Measure only; nothing in the bucket or on an asset changes. Required.")
  var dryRun = false

  @Option(help: "How many images to read and measure, or all.")
  var sample = SampleSize(count: 50)

  @Option(help: "The longest edge of a copy in pixels, or none to keep the size.")
  var longestEdge = LongestEdge(pixels: CompressionOptions.default.longestEdge)

  @Option(help: "high, medium or small.")
  var quality = CompressionOptions.default.quality

  @Flag(help: "Keep EXIF, location and other metadata in a copy.")
  var keepMetadata = false

  @Option(help: "Draws the same sample again; the run's number by default.")
  var seed: UInt64?

  @Option(help: "table or json.")
  var format: OutputFormat = .table

  func validate() throws {
    guard dryRun else {
      throw ValidationError("Pass --dry-run: optimize can only measure.")
    }
    guard !name.contains(where: { $0.isEmpty || $0.contains("/") }) else {
      throw ValidationError("--name takes a file name, without a slash.")
    }
  }

  var options: CompressionOptions {
    CompressionOptions(
      longestEdge: longestEdge.pixels, quality: quality, removesMetadata: !keepMetadata)
  }

  mutating func run() async throws {
    let database = try openCatalogDatabase()
    try await OptimizeRecovery.resumePending(in: database)
    let selected = try CatalogConfiguration.backend(slug: backend, in: database)
    let reader = S3ObjectInventory(
      backend: selected, credentials: try reindexCredentials(for: selected),
      session: OptimizeDryRun.uncachedSession())
    let output = try await perform(backend: selected, reader: reader, database: database)
    print(output.stdout, terminator: "")
    for warning in output.warnings {
      FileHandle.standardError.write(Data("WARNING: \(warning)\n".utf8))
    }
  }

  func perform(
    backend: Backend, reader: any ObjectReading, database: CatalogDatabasePool
  ) async throws -> (stdout: String, warnings: [String]) {
    let result = try await OptimizeDryRun.run(
      backend: backend, prefix: prefix, names: name, options: options, sample: sample.count,
      seed: seed, reader: reader, database: database)
    let report = result.report
    var warnings: [String] = []
    if report.hasManyHashMismatches {
      warnings.append(
        "\(report.count(.hashMismatch)) of \(report.sampled) sampled objects differ from their "
          + "rows' hashes in the catalog. Don't apply anything yet.")
    }
    let unread = report.count(.notFound) + report.count(.readFailed)
    if unread > 0 {
      warnings.append(
        "\(unread) of \(report.sampled) sampled objects could not be read and are left out of "
          + "the numbers. See: pinax runs show \(result.runID)")
    }
    let stdout =
      format == .json
      ? try encodedJSON(OptimizeDocument(result)) + "\n"
      : OptimizeTable.text(result)
    return (stdout, warnings)
  }
}

/// `--sample`: a count, or nil for `all`.
struct SampleSize: ExpressibleByArgument, Equatable {
  let count: Int?

  init(count: Int?) { self.count = count }

  init?(argument: String) {
    if argument == "all" {
      count = nil
    } else if let value = Int(argument), value > 0 {
      count = value
    } else {
      return nil
    }
  }

  var defaultValueDescription: String { count.map(String.init) ?? "all" }
}

/// `--longest-edge`: pixels, or nil for `none`.
struct LongestEdge: ExpressibleByArgument, Equatable {
  let pixels: Int?

  init(pixels: Int?) { self.pixels = pixels }

  init?(argument: String) {
    if argument == "none" {
      pixels = nil
    } else if let value = Int(argument), value > 0 {
      pixels = value
    } else {
      return nil
    }
  }

  var defaultValueDescription: String { pixels.map(String.init) ?? "none" }
}

extension CompressionQuality: ExpressibleByArgument {}

// MARK: - Table

enum OptimizeTable {
  static func text(_ result: OptimizeDryRunResult) -> String {
    let report = result.report
    let params = report.params
    var lines = [
      "Run \(result.runID) · dry run · nothing was changed",
      "backend: \(params.backend)",
      "prefix: \(params.prefix.isEmpty ? "(every key)" : params.prefix)",
    ]
    if !params.names.isEmpty { lines.append("names: \(params.names.joined(separator: ", "))") }
    lines += [
      "options: \(params.fingerprint)",
      "selected: \(images(report.selection.images, "JPEG")), \(size(report.selection.bytes))",
      "sample: \(report.sampled) (seed \(report.seed)), \(report.savings.measured) read",
      "measured: \(change(report.savings))",
    ]
    if let after = report.estimatedBytesAfter, let saved = report.estimatedSavedBytes {
      lines.append(
        "estimate for all: \(size(report.selection.bytes)) → about \(size(after)), "
          + "saving about \(size(saved))")
    }
    let skipped = OptimizeOutcome.skipReasons.filter { report.count($0) > 0 }
      .map { "\(report.count($0)) \($0.label)" }
    lines.append("would leave: \(skipped.isEmpty ? "none" : skipped.joined(separator: ", "))")
    lines.append("hash mismatches: \(report.count(.hashMismatch))")
    lines.append(
      "not read: \(report.count(.notFound)) not in the bucket, "
        + "\(report.count(.readFailed)) failed")
    lines.append(
      "not touched: PNG \(report.png.images), \(size(report.png.bytes)); "
        + "other types \(report.other.images), \(size(report.other.bytes))")
    lines.append("")
    lines.append("NAME\tSELECTED\tSIZE\tSAMPLE\tBEFORE\tAFTER\tSAVED")
    for row in report.byName {
      let label = row.mergedNames.map { "\(row.name) (\($0) names)" } ?? row.name
      let measured = row.savings.measured > 0
      lines.append(
        [
          label, String(row.selection.images), size(row.selection.bytes), String(row.sampled),
          measured ? size(row.savings.bytesBefore) : "-",
          measured ? size(row.savings.bytesAfter) : "-",
          row.savings.savedRatio.map(percent) ?? "-",
        ].joined(separator: "\t"))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func change(_ savings: OptimizeSavings) -> String {
    guard let ratio = savings.savedRatio else { return "nothing" }
    return "\(size(savings.bytesBefore)) → \(size(savings.bytesAfter)) (\(percent(ratio)) saved)"
  }

  private static func images(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }

  private static func percent(_ ratio: Double) -> String {
    "\(Int((ratio * 100).rounded()))%"
  }

  /// Decimal units, one decimal place, the same in every locale.
  static func size(_ bytes: Int64) -> String {
    if bytes < 1000 { return "\(bytes) B" }
    var value = Double(bytes) / 1000
    for unit in ["kB", "MB", "GB"] {
      if value < 999.95 { return String(format: "%.1f %@", value, unit) }
      value /= 1000
    }
    return String(format: "%.1f TB", value)
  }
}

// MARK: - pinax optimize --format json

struct OptimizeDocument: Encodable {
  let schema = "pinax.optimize.v1"
  let mode = "dry_run"
  let runID: Int64
  let backend: String
  let prefix: String
  let names: [String]
  let options: Options
  let seed: UInt64
  let selection: OptimizeTotals
  let sample: Sample
  /// Every reason, zeros included.
  let skipped: [String: Int]
  let hashMismatch: Int
  let readFailures: [String: Int]
  let estimate: Estimate
  let untouched: Untouched
  let byName: [Name]

  struct Options: Encodable {
    let fingerprint: String
    /// Null keeps the size.
    @ExplicitNull var longestEdge: Int?
    let quality: String
    let keepMetadata: Bool

    enum CodingKeys: String, CodingKey {
      case fingerprint, quality
      case longestEdge = "longest_edge"
      case keepMetadata = "keep_metadata"
    }
  }

  struct Sample: Encodable {
    /// Null for `all`.
    @ExplicitNull var requested: Int?
    let images: Int
    let measured: Int
    let bytesBefore: Int64
    let bytesAfter: Int64
    @ExplicitNull var savedRatio: Double?

    enum CodingKeys: String, CodingKey {
      case requested, images, measured
      case bytesBefore = "bytes_before"
      case bytesAfter = "bytes_after"
      case savedRatio = "saved_ratio"
    }
  }

  struct Estimate: Encodable {
    let estimate = true
    @ExplicitNull var bytesAfter: Int64?
    @ExplicitNull var savedBytes: Int64?

    enum CodingKeys: String, CodingKey {
      case estimate
      case bytesAfter = "bytes_after"
      case savedBytes = "saved_bytes"
    }
  }

  struct Untouched: Encodable {
    let png: OptimizeTotals
    let other: OptimizeTotals
  }

  struct Name: Encodable {
    let name: String
    /// Set only on the row that stands for the names past the limit.
    @ExplicitNull var mergedNames: Int?
    let images: Int
    let bytes: Int64
    let sampled: Int
    let measured: Int
    let sampleBytesBefore: Int64
    let sampleBytesAfter: Int64
    @ExplicitNull var savedRatio: Double?

    enum CodingKeys: String, CodingKey {
      case name, images, bytes, sampled, measured
      case mergedNames = "merged_names"
      case sampleBytesBefore = "sample_bytes_before"
      case sampleBytesAfter = "sample_bytes_after"
      case savedRatio = "saved_ratio"
    }
  }

  init(_ result: OptimizeDryRunResult) {
    let report = result.report
    let params = report.params
    runID = result.runID
    backend = params.backend
    prefix = params.prefix
    names = params.names
    options = Options(
      fingerprint: params.fingerprint, longestEdge: params.longestEdge,
      quality: params.quality.rawValue, keepMetadata: params.keepMetadata)
    seed = report.seed
    selection = report.selection
    sample = Sample(
      requested: params.sample, images: report.sampled, measured: report.savings.measured,
      bytesBefore: report.savings.bytesBefore, bytesAfter: report.savings.bytesAfter,
      savedRatio: report.savings.savedRatio)
    skipped = Dictionary(
      uniqueKeysWithValues: OptimizeOutcome.skipReasons.map { ($0.rawValue, report.count($0)) })
    hashMismatch = report.count(.hashMismatch)
    readFailures = Dictionary(
      uniqueKeysWithValues: [OptimizeOutcome.notFound, .readFailed].map {
        ($0.rawValue, report.count($0))
      })
    estimate = Estimate(
      bytesAfter: report.estimatedBytesAfter, savedBytes: report.estimatedSavedBytes)
    untouched = Untouched(png: report.png, other: report.other)
    byName = report.byName.map { row in
      Name(
        name: row.name, mergedNames: row.mergedNames, images: row.selection.images,
        bytes: row.selection.bytes, sampled: row.sampled, measured: row.savings.measured,
        sampleBytesBefore: row.savings.bytesBefore, sampleBytesAfter: row.savings.bytesAfter,
        savedRatio: row.savings.savedRatio)
    }
  }

  enum CodingKeys: String, CodingKey {
    case schema, mode, backend, prefix, names, options, seed, selection, sample, skipped, estimate
    case untouched
    case runID = "run_id"
    case hashMismatch = "hash_mismatch"
    case readFailures = "read_failures"
    case byName = "by_name"
  }
}
