import Foundation
import GRDB

/// A count of objects and their size.
public struct OptimizeTotals: Codable, Equatable, Sendable {
  public var images: Int
  public var bytes: Int64

  public init(images: Int = 0, bytes: Int64 = 0) {
    self.images = images
    self.bytes = bytes
  }

  mutating func add(_ size: Int64) {
    images += 1
    bytes += size
  }
}

/// A backend's active assets under a key prefix and, optionally, with one of a
/// set of file names.
public struct OptimizeSelection: Sendable {
  /// The JPEG rows, in asset-id order.
  public let images: [Asset]
  /// PNG rows that match, which are left alone.
  public let png: OptimizeTotals
  /// Matching rows of every other type, also left alone.
  public let other: OptimizeTotals

  public var totals: OptimizeTotals {
    OptimizeTotals(images: images.count, bytes: images.reduce(0) { $0 + $1.byteSize })
  }

  /// The part of a key after its last `/`.
  public static func name(of key: String) -> String {
    key.lastIndex(of: "/").map { String(key[key.index(after: $0)...]) } ?? key
  }

  /// Keys are compared byte for byte, as the bucket does: case matters, and
  /// so does how a character is composed. An empty `names` keeps every name.
  public static func read(
    backendID: Int64, prefix: String, names: [String], in database: CatalogDatabasePool
  ) throws -> OptimizeSelection {
    let rows = try database.read { db in
      try Asset
        .filter(Column("backend_id") == backendID && Column("state") == AssetState.active.rawValue)
        .order(Column("id"))
        .fetchAll(db)
    }
    let wanted = Set(names.map { Data($0.utf8) })
    var images: [Asset] = []
    var png = OptimizeTotals()
    var other = OptimizeTotals()
    for asset in rows where asset.key.utf8.starts(with: prefix.utf8) {
      if !wanted.isEmpty, !wanted.contains(Data(name(of: asset.key).utf8)) { continue }
      switch asset.mime {
      case "image/jpeg": images.append(asset)
      case "image/png": png.add(asset.byteSize)
      default: other.add(asset.byteSize)
      }
    }
    return OptimizeSelection(images: images, png: png, other: other)
  }

  /// `count` of the images in an order that depends only on `seed` and the
  /// selection; all of them when `count` is nil or too large.
  public func sample(_ count: Int?, seed: UInt64) -> [Asset] {
    var pool = images
    let wanted = max(0, min(count ?? pool.count, pool.count))
    // SplitMix64 and a partial Fisher-Yates shuffle, written out so that a
    // seed keeps naming the same sample across Swift versions.
    var state = seed
    for index in 0..<wanted {
      state &+= 0x9E37_79B9_7F4A_7C15
      var value = state
      value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
      value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
      value ^= value >> 31
      pool.swapAt(index, index + Int(value % UInt64(pool.count - index)))
    }
    return Array(pool.prefix(wanted))
  }
}
