import CoreGraphics
import Foundation
import ImageIO

/// Images drawn in code for the compressor tests, so no image files live in
/// the repository. Everything here is deterministic.
enum CompressionFixtures {
  struct FixtureError: Error, CustomStringConvertible {
    let description: String
  }

  static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

  /// A small, fast random source so the noise is the same on every run.
  struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  // MARK: - Drawing

  /// Fills an 8-bit RGBA buffer pixel by pixel and returns the image.
  static func image(
    width: Int,
    height: Int,
    space: CGColorSpace = sRGB,
    alphaInfo: CGImageAlphaInfo = .noneSkipLast,
    pixel: (_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int)
  ) throws -> CGImage {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space, bitmapInfo: alphaInfo.rawValue),
      let data = context.data
    else {
      throw FixtureError(description: "could not create a drawing context")
    }
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let value = pixel(x, y)
        let offset = (y * width + x) * 4
        // Premultiplied alpha: color channels never exceed alpha.
        let a: UInt8 = clamp(value.a)
        bytes[offset] = min(clamp(value.r), a)
        bytes[offset + 1] = min(clamp(value.g), a)
        bytes[offset + 2] = min(clamp(value.b), a)
        bytes[offset + 3] = a
      }
    }
    guard let image = context.makeImage() else {
      throw FixtureError(description: "could not make an image")
    }
    return image
  }

  private static func clamp(_ value: Int) -> UInt8 {
    UInt8(max(0, min(255, value)))
  }

  /// Something like a landscape photo: smooth gradients and soft shapes
  /// with a little sensor noise, which is what JPEG is good at.
  static func photo(
    width: Int,
    height: Int,
    seed: UInt64 = 1,
    noise: Int = 6,
    space: CGColorSpace = sRGB,
    alphaInfo: CGImageAlphaInfo = .noneSkipLast,
    alpha: (_ x: Int, _ y: Int) -> Int = { _, _ in 255 }
  ) throws -> CGImage {
    var random = SplitMix64(seed: seed)
    let span = UInt64(noise * 2 + 1)
    return try image(width: width, height: height, space: space, alphaInfo: alphaInfo) { x, y in
      let fx = Double(x) / Double(width)
      let fy = Double(y) / Double(height)
      let hill = 0.55 + 0.12 * sin(fx * 7.0) + 0.05 * sin(fx * 23.0)
      let ground = fy > hill
      var r: Double
      var g: Double
      var b: Double
      if ground {
        r = 70 + 60 * fy + 20 * sin(fx * 31 + fy * 17)
        g = 90 + 50 * fy + 25 * sin(fx * 13 - fy * 29)
        b = 40 + 20 * fy
      } else {
        r = 120 + 110 * fy
        g = 160 + 70 * fy
        b = 235 - 30 * fy
        let dx = fx - 0.72
        let dy = fy - 0.22
        let sun = max(0, 1 - (dx * dx + dy * dy) * 40)
        r += 90 * sun
        g += 70 * sun
        b += 20 * sun
      }
      func jitter() -> Int { noise == 0 ? 0 : Int(random.next() % span) - noise }
      return (Int(r) + jitter(), Int(g) + jitter(), Int(b) + jitter(), alpha(x, y))
    }
  }

  /// Something like a screenshot: flat panels, a title bar and rows of
  /// dark bars standing in for text. PNG stores this far better than JPEG.
  static func screenshot(width: Int, height: Int) throws -> CGImage {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else {
      throw FixtureError(description: "could not create a drawing context")
    }
    func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
      context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
      context.fill(rect)
    }
    let w = CGFloat(width)
    let h = CGFloat(height)
    fill(0.93, 0.94, 0.95, CGRect(x: 0, y: 0, width: w, height: h))
    fill(0.20, 0.22, 0.25, CGRect(x: 0, y: h - 28, width: w, height: 28))
    fill(0.85, 0.87, 0.90, CGRect(x: 0, y: 0, width: w * 0.22, height: h - 28))
    fill(0.18, 0.55, 0.35, CGRect(x: w * 0.26, y: h - 90, width: 120, height: 32))
    var y = h - 140
    var line = 0
    while y > 40 {
      let length = w * (0.35 + 0.3 * CGFloat((line * 37) % 10) / 10)
      fill(0.25, 0.25, 0.28, CGRect(x: w * 0.26, y: y, width: length, height: 9))
      y -= 22
      line += 1
    }
    guard let image = context.makeImage() else {
      throw FixtureError(description: "could not make an image")
    }
    return image
  }

  /// Redraws `image` into a 16-bit RGB or 8-bit CMYK context.
  static func redrawn(_ image: CGImage, bitsPerComponent: Int, space: CGColorSpace) throws
    -> CGImage
  {
    let alphaInfo: CGImageAlphaInfo = space.model == .cmyk ? .none : .noneSkipLast
    var info = alphaInfo.rawValue
    if bitsPerComponent == 16 {
      info |= CGBitmapInfo.byteOrder16Little.rawValue
    }
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: space, bitmapInfo: info)
    else {
      throw FixtureError(description: "could not create a \(bitsPerComponent)-bit context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = context.makeImage() else {
      throw FixtureError(description: "could not make an image")
    }
    return result
  }

  // MARK: - Encoding

  static func encode(
    _ images: [CGImage],
    type: String,
    properties: [CFString: Any] = [:],
    containerProperties: [CFString: Any]? = nil
  ) throws -> Data {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, type as CFString, images.count, nil)
    else {
      throw FixtureError(description: "ImageIO cannot write \(type)")
    }
    if let containerProperties {
      CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)
    }
    for image in images {
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else {
      throw FixtureError(description: "could not finish writing \(type)")
    }
    return output as Data
  }

  static func jpeg(
    _ image: CGImage, quality: Double = 1.0, properties: [CFString: Any] = [:]
  ) throws -> Data {
    var all = properties
    all[kCGImageDestinationLossyCompressionQuality] = quality
    return try encode([image], type: "public.jpeg", properties: all)
  }

  static func png(_ image: CGImage) throws -> Data {
    try encode([image], type: "public.png")
  }

  static func heic(_ image: CGImage, quality: Double = 0.9) throws -> Data {
    try encode(
      [image], type: "public.heic",
      properties: [kCGImageDestinationLossyCompressionQuality: quality])
  }

  static func gif(_ frames: [CGImage]) throws -> Data {
    try encode(
      frames, type: "com.compuserve.gif",
      properties: [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
      ],
      containerProperties: [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
      ])
  }

  /// Whether this machine's ImageIO can write HEIC at all.
  static var canEncodeHEIC: Bool {
    guard let image = try? photo(width: 64, height: 64, noise: 0) else { return false }
    return (try? heic(image)) != nil
  }

  // MARK: - Reading back

  static func properties(of data: Data) -> [CFString: Any] {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return [:]
    }
    return properties
  }

  static func decoded(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// The sRGB color of one pixel, with (0, 0) at the top left.
  static func pixel(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let data = context.data
    else {
      return nil
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    let offset = (y * image.width + x) * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
  }
}
