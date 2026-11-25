import Foundation

/// The three JPEG quality steps a project can pick. The values are ImageIO's
/// `kCGImageDestinationLossyCompressionQuality`, whose scale is not libjpeg's
/// (0.85 here is not the same as `-quality 85` elsewhere).
public enum CompressionQuality: String, CaseIterable, Codable, Hashable, Sendable {
  case high
  case medium
  case small

  public var jpegQuality: Double {
    switch self {
    case .high: return 0.85
    case .medium: return 0.75
    case .small: return 0.6
    }
  }
}
