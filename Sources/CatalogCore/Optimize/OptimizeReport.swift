import Foundation

/// What the sample saves. `bytesBefore` and `bytesAfter` cover the sampled
/// objects that were read; one that would be left as it is counts the same in
/// both, and one that never arrived counts in neither.
public struct OptimizeSavings: Codable, Equatable, Sendable {
  public var measured: Int
  public var bytesBefore: Int64
  public var bytesAfter: Int64

  public init(measured: Int = 0, bytesBefore: Int64 = 0, bytesAfter: Int64 = 0) {
    self.measured = measured
    self.bytesBefore = bytesBefore
    self.bytesAfter = bytesAfter
  }

  /// The fraction saved, from 0 to 1; nil when nothing was measured.
  public var savedRatio: Double? {
    bytesBefore > 0 ? Double(bytesBefore - bytesAfter) / Double(bytesBefore) : nil
  }

  mutating func add(_ event: ObjectMeasuredEvent) {
    guard event.outcome.wasRead else { return }
    measured += 1
    bytesBefore += event.bytesBefore
    bytesAfter += event.outcome == .smaller ? event.bytesAfter ?? event.bytesBefore : event.bytesBefore
  }

  enum CodingKeys: String, CodingKey {
    case measured
    case bytesBefore = "bytes_before"
    case bytesAfter = "bytes_after"
  }
}

/// The selected and sampled images with one file name.
public struct OptimizeNameRow: Codable, Equatable, Sendable {
  public var name: String
  /// On the row that stands for the names past the limit, how many it holds.
  public var mergedNames: Int?
  public var selection: OptimizeTotals
  /// How many were drawn into the sample.
  public var sampled: Int
  public var savings: OptimizeSavings

  /// How many names get a row of their own.
  public static let limit = 20
  /// The merged row's `name`; `mergedNames` tells it from a file so named.
  public static let mergedName = "other"

  enum CodingKeys: String, CodingKey {
    case name, selection, sampled, savings
    case mergedNames = "merged_names"
  }
}

/// A dry run's numbers: what its summary stores and the CLI prints.
public struct OptimizeReport: Codable, Equatable, Sendable {
  public var params: OptimizeRunParams
  /// The seed the sample was drawn with.
  public var seed: UInt64
  public var selection: OptimizeTotals
  /// How many images were drawn.
  public var sampled: Int
  public var savings: OptimizeSavings
  /// How many sampled objects had each outcome.
  public var outcomes: [String: Int]
  public var png: OptimizeTotals
  public var other: OptimizeTotals
  /// Most selected bytes first.
  public var byName: [OptimizeNameRow]

  public func count(_ outcome: OptimizeOutcome) -> Int { outcomes[outcome.rawValue] ?? 0 }

  /// The whole selection's size if it shrinks as the sample did: an estimate.
  public var estimatedBytesAfter: Int64? {
    savings.bytesBefore > 0
      ? Int64(
        (Double(selection.bytes) * Double(savings.bytesAfter) / Double(savings.bytesBefore))
          .rounded())
      : nil
  }

  public var estimatedSavedBytes: Int64? { estimatedBytesAfter.map { selection.bytes - $0 } }

  /// More than a tenth of the sample is not what the catalog says it is.
  public var hasManyHashMismatches: Bool { count(.hashMismatch) * 10 > sampled }

  init(
    params: OptimizeRunParams, seed: UInt64, selection: OptimizeSelection, sample: [Asset],
    results: [ObjectMeasuredEvent]
  ) {
    self.params = params
    self.seed = seed
    self.selection = selection.totals
    sampled = sample.count
    png = selection.png
    other = selection.other
    var savings = OptimizeSavings()
    var outcomes: [String: Int] = [:]
    var rows: [Data: OptimizeNameRow] = [:]
    func change(_ key: String, _ body: (inout OptimizeNameRow) -> Void) {
      let name = OptimizeSelection.name(of: key)
      var row =
        rows[Data(name.utf8)]
        ?? OptimizeNameRow(
          name: name, selection: OptimizeTotals(), sampled: 0, savings: OptimizeSavings())
      body(&row)
      rows[Data(name.utf8)] = row
    }
    for asset in selection.images {
      change(asset.key) { $0.selection.add(asset.byteSize) }
    }
    for asset in sample {
      change(asset.key) { $0.sampled += 1 }
    }
    for event in results {
      savings.add(event)
      outcomes[event.outcome.rawValue, default: 0] += 1
      change(event.key) { $0.savings.add(event) }
    }
    self.savings = savings
    self.outcomes = outcomes
    byName = Self.limited(Array(rows.values))
  }

  private static func limited(_ rows: [OptimizeNameRow]) -> [OptimizeNameRow] {
    let sorted = rows.sorted {
      ($1.selection.bytes, $0.name) < ($0.selection.bytes, $1.name)
    }
    guard sorted.count > OptimizeNameRow.limit else { return sorted }
    let rest = sorted.dropFirst(OptimizeNameRow.limit)
    var merged = OptimizeNameRow(
      name: OptimizeNameRow.mergedName, mergedNames: rest.count, selection: OptimizeTotals(),
      sampled: 0, savings: OptimizeSavings())
    for row in rest {
      merged.selection.images += row.selection.images
      merged.selection.bytes += row.selection.bytes
      merged.sampled += row.sampled
      merged.savings.measured += row.savings.measured
      merged.savings.bytesBefore += row.savings.bytesBefore
      merged.savings.bytesAfter += row.savings.bytesAfter
    }
    return sorted.prefix(OptimizeNameRow.limit) + [merged]
  }

  enum CodingKeys: String, CodingKey {
    case params, seed, selection, sampled, savings, outcomes, png, other
    case byName = "by_name"
  }
}
