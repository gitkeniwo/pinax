import Foundation

public enum CompressionResult: Hashable, Sendable {
  case compressed(CompressedImage)
  case skipped(SkipReason)

  public var compressedImage: CompressedImage? {
    if case .compressed(let image) = self { return image }
    return nil
  }

  public var skipReason: SkipReason? {
    if case .skipped(let reason) = self { return reason }
    return nil
  }
}
