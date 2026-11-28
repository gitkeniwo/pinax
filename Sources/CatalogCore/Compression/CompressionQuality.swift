import Foundation

/// The JPEG quality of a compressed copy, as a whole percentage from 40 to
/// 100: higher is sharper and larger. ImageIO receives the percentage over
/// 100 as `kCGImageDestinationLossyCompressionQuality`, whose scale is not
/// libjpeg's (85 here is not the same as `-quality 85` elsewhere).
///
/// Earlier versions stored one of three names; `high`, `medium` and `small`
/// still read as 85, 75 and 60 wherever a quality is read.
public struct CompressionQuality: Hashable, Comparable, Sendable, Codable,
  ExpressibleByIntegerLiteral, CustomStringConvertible
{
  public static let range = 40...100
  /// Where the three named steps of earlier versions sit.
  public static let ticks = [60, 75, 85]
  public static let `default` = CompressionQuality(85)

  /// The names earlier versions stored, with the percentage each reads as.
  static let legacyNames: [String: Int] = ["high": 85, "medium": 75, "small": 60]

  public let percent: Int

  /// `percent` pulled into `range`.
  public init(_ percent: Int) {
    self.percent = min(max(percent, Self.range.lowerBound), Self.range.upperBound)
  }

  public init(integerLiteral value: Int) {
    self.init(value)
  }

  /// A whole percentage inside `range`, or nil.
  public init?(exactly percent: Int) {
    guard Self.range.contains(percent) else { return nil }
    self.percent = percent
  }

  /// `85`, or one of the old names `high`, `medium`, `small` (any case).
  public init?(parsing text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    if let legacy = Self.legacyNames[trimmed] {
      self.init(legacy)
    } else if let number = Int(trimmed) {
      self.init(exactly: number)
    } else {
      return nil
    }
  }

  /// A stored value: a whole number inside `range`, or an old name.
  init?(json value: Any?) {
    switch value {
    case let number as NSNumber where !CFNumberIsFloatType(number):
      self.init(exactly: number.intValue)
    case let text as String:
      self.init(parsing: text)
    default:
      return nil
    }
  }

  public var jpegQuality: Double { Double(percent) / 100 }

  /// `85%`.
  public var description: String { "\(percent)%" }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.percent < rhs.percent }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let number = try? container.decode(Int.self) {
      guard let value = Self(exactly: number) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Quality \(number) is outside 40–100.")
      }
      self = value
    } else {
      let text = try container.decode(String.self)
      guard let value = Self(parsing: text) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Unknown quality \(text).")
      }
      self = value
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(percent)
  }
}
