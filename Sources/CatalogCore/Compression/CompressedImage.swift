import Foundation

/// A recompressed copy of an image, ready to upload in place of the source.
public struct CompressedImage: Hashable, Sendable {
  public let data: Data
  public let mime: String
  public let fileExtension: String
  public let width: Int
  public let height: Int
  public let sourceByteSize: Int
  /// The source's size as displayed, after its EXIF orientation.
  public let sourceWidth: Int
  public let sourceHeight: Int
  public let sourceMime: String

  public init(
    data: Data,
    mime: String,
    fileExtension: String,
    width: Int,
    height: Int,
    sourceByteSize: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    sourceMime: String
  ) {
    self.data = data
    self.mime = mime
    self.fileExtension = fileExtension
    self.width = width
    self.height = height
    self.sourceByteSize = sourceByteSize
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    self.sourceMime = sourceMime
  }

  public var byteSize: Int { data.count }
}
