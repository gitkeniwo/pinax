import Foundation
import ImageIO

public struct ImageDimensions: Equatable, Sendable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

public enum ImageProbe {
  public static func dimensions(ofFileAt fileURL: URL) -> ImageDimensions? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else {
      return nil
    }
    return dimensions(from: source, options: options)
  }

  public static func dimensions(of data: Data) -> ImageDimensions? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
      return nil
    }
    return dimensions(from: source, options: options)
  }

  private static func dimensions(
    from source: CGImageSource,
    options: CFDictionary
  ) -> ImageDimensions? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
        as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      return nil
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let storedWidth = width.intValue
    let storedHeight = height.intValue
    if (5...8).contains(orientation) {
      return ImageDimensions(width: storedHeight, height: storedWidth)
    }
    return ImageDimensions(width: storedWidth, height: storedHeight)
  }
}
