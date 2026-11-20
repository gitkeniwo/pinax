import AppKit
import CatalogCore
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PinaxUI

/// A thumbnail that fails, arrives late or is
/// retried must not move any cell. The fake fetcher fails most requests
/// and lets a few through only once the gate opens, with pictures whose
/// shape matches no recorded size (a very wide and a very tall one).
@MainActor
@Suite(.serialized) struct GridThumbnailLoadStabilityTests {
  /// The fake network: every request fails except the allowed ones, which
  /// wait for the gate and then answer with a JPEG.
  private final class FakeNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var attempts: [String: Int] = [:]
    let allowed: (Int) -> Bool

    init(allowed: @escaping (Int) -> Bool) { self.allowed = allowed }

    func openGate() {
      lock.lock()
      open = true
      lock.unlock()
    }

    var isOpen: Bool {
      lock.lock()
      defer { lock.unlock() }
      return open
    }

    func attempts(_ name: String) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return attempts[name, default: 0]
    }

    var totalAttempts: Int {
      lock.lock()
      defer { lock.unlock() }
      return attempts.values.reduce(0, +)
    }

    func fetch(_ url: URL) async throws -> Data {
      let name = url.lastPathComponent
      lock.lock()
      attempts[name, default: 0] += 1
      lock.unlock()
      guard let index = Int(name.replacingOccurrences(of: "asset-", with: "")
        .replacingOccurrences(of: ".png", with: "")), allowed(index)
      else { throw URLError(.cannotConnectToHost) }
      while !isOpen { try await Task.sleep(nanoseconds: 20_000_000) }
      return Self.jpeg(wide: index % 2 == 0)
    }

    static func jpeg(wide: Bool) -> Data {
      let width = wide ? 512 : 150
      let height = wide ? 120 : 512
      let space = CGColorSpaceCreateDeviceRGB()
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let data = NSMutableData()
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, context.makeImage()!, nil)
      CGImageDestinationFinalize(destination)
      return data as Data
    }
  }

  private final class FrameSink {
    var frames: [GalleryModel.Row.ID: CGRect] = [:]
  }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func findScrollView(in root: NSView) -> NSScrollView? {
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
      if let scroll = view as? NSScrollView { return scroll }
      stack.append(contentsOf: view.subviews)
    }
    return nil
  }

  private func frames(of sink: FrameSink, at offset: CGFloat) -> [GalleryModel.Row.ID: CGRect] {
    // Row frames are in the viewport's space: lift them into the document's.
    sink.frames.mapValues { $0.offsetBy(dx: 0, dy: offset) }
  }

  /// The mechanism: a filled picture that is not the cell's shape used to
  /// size its view (853 × 200 in a 200 pt square). Confined, the view is
  /// the size it is offered with or without the picture.
  @Test("A confined thumbnail is the offered size, whatever the picture's shape and whether it has arrived")
  func confinedThumbnailKeepsItsSize() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2025-01-01T12:00:00Z")
    let cache = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbs"),
      fetcher: { _ in throw URLError(.cannotConnectToHost) })
    let model = GalleryModel(catalog: ReadOnlyCatalog(database: database), thumbnails: cache)
    await model.loadInitialData()
    await model.reload()
    let item = try #require(model.rows.first).item
    let offered = CGSize(width: 200, height: 200)
    func size(confined: Bool) -> CGSize {
      NSHostingController(
        rootView: ThumbnailView(item: item, cache: cache, confined: confined)
      ).sizeThatFits(in: offered)
    }
    // Not arrived yet (the placeholder), then a very wide, then a very tall one.
    #expect(size(confined: true) == offered, "placeholder: \(size(confined: true))")
    for wide in [true, false] {
      let request = ThumbnailRequest(
        sha256: item.asset.sha256, sourceURL: URL(string: "https://example.invalid/a.png")!)
      await cache.invalidateMemoryCache()
      _ = await cache.store(data: FakeNetwork.jpeg(wide: wide), for: request)
      #expect(size(confined: true) == offered, "wide \(wide): confined \(size(confined: true))")
      #expect(
        size(confined: false) != offered,
        "wide \(wide): the unconfined view was expected to outgrow the square, as it did")
    }
  }

  @Test(
    "Thumbnails that fail, arrive late or are retried never move a cell",
    arguments: [GridThumbnailSizing.fillGrid, .originalAspect])
  func loadsDoNotMoveCells(sizing: GridThumbnailSizing) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    var index = 0
    for (month, count) in [(1, 30), (2, 30), (3, 30)] {
      for day in 0..<count {
        let wide = index % 3 == 0
        try seedAsset(
          database, index: index,
          uploadedAt: String(format: "2025-%02d-%02dT12:00:00Z", month, day % 28 + 1),
          width: wide ? 2350 : 600, height: wide ? 1000 : 800)
        index += 1
      }
    }
    // One request in six may succeed, and only after the gate opens.
    let network = FakeNetwork(allowed: { $0 % 6 == 0 })
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-d4c-\(UUID().uuidString)"),
        fetcher: { try await network.fetch($0) }))
    await model.loadInitialData()
    model.select(.all, in: .library)
    await model.reload()
    model.gridThumbnailSizing = sizing
    #expect(model.groupsRowsByMonth)
    #expect(model.rows.count == 90)

    let sink = FrameSink()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(
      rootView: AssetGridView(model: model, scrollerStyle: .overlay)
        .onPreferenceChange(RowFramesKey.self) { sink.frames = $0 })
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(1.5)
    let scrollView = try #require(findScrollView(in: host))
    let clip = scrollView.contentView
    let document = try #require(scrollView.documentView)

    func scroll(to y: CGFloat) async {
      clip.scroll(to: NSPoint(x: 0, y: y))
      scrollView.reflectScrolledClipView(clip)
      await spin(0.4)
    }
    /// Cells in the document's space at the current offset, plus the height.
    func snapshot() -> (cells: [GalleryModel.Row.ID: CGRect], height: CGFloat) {
      (frames(of: sink, at: clip.bounds.origin.y), document.frame.height)
    }
    func expectSame(
      _ a: (cells: [GalleryModel.Row.ID: CGRect], height: CGFloat),
      _ b: (cells: [GalleryModel.Row.ID: CGRect], height: CGFloat), _ when: String
    ) {
      #expect(abs(a.height - b.height) <= 0.5, "\(sizing) \(when): document \(a.height) → \(b.height)")
      var compared = 0
      for (id, before) in a.cells {
        guard let after = b.cells[id] else { continue }
        compared += 1
        #expect(
          abs(before.minX - after.minX) <= 0.5 && abs(before.minY - after.minY) <= 0.5
            && abs(before.width - after.width) <= 0.5 && abs(before.height - after.height) <= 0.5,
          "\(sizing) \(when): cell \(id) moved \(before) → \(after)")
      }
      #expect(compared >= 8, "\(sizing) \(when): only \(compared) cells in common")
    }

    // Everything fails at first: the placeholder layout, at three offsets.
    let probes: [CGFloat] = [0, 900, 1800]
    var before: [CGFloat: (cells: [GalleryModel.Row.ID: CGRect], height: CGFloat)] = [:]
    for y in probes {
      await scroll(to: y)
      before[y] = snapshot()
    }
    #expect(network.totalAttempts > 0, "the fake network was never asked")

    // Fast scroll far down and back: many cells appear and vanish, each
    // failing, each retried the next time it appears.
    let bottom = document.frame.height - clip.bounds.height
    for step in stride(from: 0, through: bottom, by: 350) { await scroll(to: step) }
    await scroll(to: bottom)
    for step in stride(from: bottom, through: 0, by: -350) { await scroll(to: step) }

    for y in probes {
      await scroll(to: y)
      expectSame(try #require(before[y]), snapshot(), "after failed retries at \(y)")
    }

    // The few pictures arrive late, with shapes unlike the recorded ones.
    network.openGate()
    await spin(1.0)
    for y in probes {
      await scroll(to: y)
      await spin(0.5)
      expectSame(try #require(before[y]), snapshot(), "after late arrival at \(y)")
    }
    func arrivedPictures() -> [Int] {
      (0..<90).filter { $0 % 6 == 0 }.filter {
        model.thumbnails.peekMemoryImage(for: String(format: "%064x", $0 + 1)) != nil
      }
    }
    let arrivalDeadline = Date().addingTimeInterval(10)
    while arrivedPictures().count < 2, Date() < arrivalDeadline { await spin(0.2) }
    let arrived = arrivedPictures()
    #expect(arrived.count >= 2,"\(sizing): only \(arrived.count) late pictures reached the cache")
    // And once more through the whole document, now with some cached.
    for step in stride(from: 0, through: bottom, by: 350) { await scroll(to: step) }
    for y in probes {
      await scroll(to: y)
      expectSame(try #require(before[y]), snapshot(), "after a second pass at \(y)")
    }
  }
}
