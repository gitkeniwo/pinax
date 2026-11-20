import CoreGraphics

/// The arithmetic behind a grid cell's `.aspectRatio(contentMode: .fill)`
/// + `.clipped()`: the image is scaled until it covers the frame, centred,
/// and whatever overhangs is cut off.
enum AspectFill {
  /// The part of an image of size `image` that a frame of size `frame`
  /// shows, in the image's own coordinates. An empty size shows the whole
  /// image.
  static func visibleRect(image: CGSize, in frame: CGSize) -> CGRect {
    let whole = CGRect(origin: .zero, size: image)
    guard image.width > 0, image.height > 0, frame.width > 0, frame.height > 0 else {
      return whole
    }
    let scale = max(frame.width / image.width, frame.height / image.height)
    let visible = CGSize(width: frame.width / scale, height: frame.height / scale)
    return CGRect(
      x: (image.width - visible.width) / 2, y: (image.height - visible.height) / 2,
      width: visible.width, height: visible.height)
  }
}
