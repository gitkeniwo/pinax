import CatalogCore
import CoreGraphics
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// The property: *a `ThumbnailView` rebuilt for a sha already
/// in the cache never renders the placeholder state* — its first committed
/// frame carries the image.
///
/// `ImageRenderer` commits the view's init-time state synchronously: the
/// render never runs a runloop turn, so `.task` has not fired, and the
/// bitmap is exactly the frame a rebuilt cell shows before any async work
/// can land. The assertion is on the bitmap itself — the fixture thumbnail
/// is a solid colour, so "the image is present" is a colour measurement,
/// not an outcome report. The cold twin in the same test is the falsifier:
/// it proves the instrument renders the placeholder when no seed exists,
/// so a regression that empties the seed turns the property expectation
/// red rather than passing vacuously.
@MainActor
@Suite struct ThumbnailFirstFrameTests {

  @Test("A rebuilt cell's first committed frame draws the cached image")
  func firstFrameDrawsTheCachedImage() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T13:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-20T13:00:01Z")

    let page = try await ReadOnlyCatalog(database: database).page(AssetQuery())
    #expect(page.items.count == 2)

    let cache = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbs"),
      fetcher: { _ in throw URLError(.unsupportedURL) }
    )
    guard let jpeg = makeJPEGData() else {
      Issue.record("fixture JPEG could not be generated")
      return
    }
    // Warm the first asset only; the second stays cold as the twin.
    let warmed = await cache.store(
      data: jpeg,
      for: ThumbnailRequest(
        sha256: page.items[0].asset.sha256,
        sourceURL: URL(string: page.items[0].url) ?? URL(fileURLWithPath: "/dev/null")
      ))

    let seeded = blueRatio(of: renderFirstFrame(page.items[0], cache: cache))
    let cold = blueRatio(of: renderFirstFrame(page.items[1], cache: cache))

    #expect(warmed != nil)
    #expect(seeded > 0.8, "a warmed cell's first frame is the image, not the placeholder")
    #expect(cold < 0.2, "a cold cell renders the placeholder — the instrument can go red")
  }

  private func renderFirstFrame(
    _ item: CatalogAssetItem, cache: ThumbnailCache
  ) -> CGImage? {
    let renderer = ImageRenderer(
      content: ThumbnailView(item: item, cache: cache).frame(width: 64, height: 48))
    return renderer.cgImage
  }

  /// Fraction of pixels matching the fixture's solid blue (0.2, 0.5, 0.8),
  /// resampled through an 8-bit RGBA context to a fixed small size.
  private func blueRatio(of image: CGImage?) -> Double {
    guard let image else { return -1 }
    let width = 32
    let height = 24
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &pixels, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return -1 }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var blue = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let r = Int(pixels[offset]), g = Int(pixels[offset + 1]),
        b = Int(pixels[offset + 2]), a = Int(pixels[offset + 3])
      if a > 200, abs(r - 51) < 24, abs(g - 128) < 24, abs(b - 204) < 24 {
        blue += 1
      }
    }
    return Double(blue) / Double(width * height)
  }
}
