import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PinaxUI

@Suite struct ThumbnailDecodePoolTests {
  private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-decode-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func request(_ index: Int) -> ThumbnailRequest {
    let sha = String(format: "%064x", index)
    return ThumbnailRequest(
      sha256: sha, sourceURL: URL(string: "https://img.example.com/originals/\(sha).jpg")!)
  }

  /// Waits for a state the code under test reaches on its own; the deadline
  /// only turns a broken implementation into a failure instead of a hang.
  private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if await condition() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
  }

  @Test("A memory hit returns while another thumbnail is stuck mid-decode")
  func memoryHitDoesNotWaitForDecode() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let jpeg = try #require(makeJPEGData())
    let gate = DecodeGate()
    let cache = ThumbnailCache(
      cacheDirectory: directory, fetcher: { _ in jpeg }, maxConcurrentDownloads: 4,
      decodeConcurrency: 3, beforeDecode: gate.pass)

    let warm = request(1)
    let warmed = try #require(await cache.store(data: jpeg, for: warm))

    gate.close()
    let slow = Task { try await cache.image(for: request(2)) }
    #expect(await waitUntil { gate.entered == 1 })

    // Should the decode ever block the actor, this valve frees it so the
    // test fails on the order below instead of hanging.
    let valve = Task.detached {
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      gate.open()
    }
    let hit = await cache.cachedImage(for: warm)
    let openedBeforeHit = gate.isOpen
    gate.open()
    valve.cancel()

    #expect(hit === warmed)
    #expect(!openedBeforeHit)
    #expect(try await slow.value != nil)
  }

  @Test("Decodes run at most three at once; downloads finish meanwhile and keep their own bound")
  func decodePoolIsBoundedAndSeparateFromDownloads() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let jpeg = try #require(makeJPEGData())
    let gate = DecodeGate()
    let downloads = ActiveCounter()
    let cache = ThumbnailCache(
      cacheDirectory: directory,
      fetcher: { _ in
        downloads.enter()
        try? await Task.sleep(nanoseconds: 5_000_000)
        downloads.leave()
        return jpeg
      },
      maxConcurrentDownloads: 4, decodeConcurrency: 3, beforeDecode: gate.pass)
    #expect(cache.decodePool.limit == ThumbnailCache.defaultDecodeConcurrency)
    #expect(ThumbnailCache.defaultDecodeConcurrency == 3)

    gate.close()
    let total = 8
    let loads = Task {
      await withTaskGroup(of: CGImage?.self, returning: Int.self) { group in
        for index in 1...total {
          group.addTask { try? await cache.image(for: request(index)) }
        }
        var made = 0
        for await image in group where image != nil { made += 1 }
        return made
      }
    }

    // Every request has its bytes and stands at the pool: three inside,
    // the rest queued — no download slot is held by a waiting decode.
    let settled = await waitUntil {
      let pool = cache.decodePool
      let running = await pool.running
      let queued = await pool.queued
      return running == 3 && queued == total - 3
    }
    #expect(settled)
    #expect(downloads.total == total)
    #expect(downloads.peak <= 4)
    #expect(gate.entered == 3)

    gate.open()
    #expect(await loads.value == total)
    #expect(gate.peak == 3)
    #expect(gate.entered == total)
  }

  @Test("Memory entries carry their pixel cost under a 256 MB ceiling")
  func memoryCostIsCharged() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailCache(cacheDirectory: directory)
    #expect(cache.memoryTotalCostLimit == 256 * 1024 * 1024)
    #expect(ThumbnailCache.memoryCountLimit == 512)

    let jpeg = try #require(makeJPEGData(width: 512, height: 512))
    let image = try #require(ThumbnailCache.thumbnail(from: jpeg))
    #expect(ThumbnailCache.memoryCost(of: image) == image.bytesPerRow * image.height)
    #expect(ThumbnailCache.memoryCost(of: image) >= 1024 * 1024)

    // 300 entries of at least 1 MB each: under the count limit, over the cost
    // ceiling, so only a charged cost can evict any of them.
    let stored = 300
    for index in 1...stored {
      _ = await cache.store(data: jpeg, for: request(index))
    }
    let resident = (1...stored).filter { cache.peekMemoryImage(for: request($0).sha256) != nil }
    #expect(resident.count < stored)
    #expect(resident.count <= 256)
  }

  @Test("Immediate decoding leaves the pixels exactly as the lazy decode made them")
  func immediateDecodeIsPixelIdentical() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let jpeg = try #require(makeJPEGData(width: 900, height: 600))
    let file = directory.appendingPathComponent("fixture.jpg")
    try jpeg.write(to: file)

    let lazySource = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
    let lazyFull = try #require(CGImageSourceCreateImageAtIndex(lazySource, 0, nil))
    let full = try #require(ThumbnailCache.decode(file))
    #expect(Pixels(full) == Pixels(lazyFull))

    let dataSource = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let lazyOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: ThumbnailCache.maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    let lazyThumb = try #require(
      CGImageSourceCreateThumbnailAtIndex(dataSource, 0, lazyOptions as CFDictionary))
    let thumb = try #require(ThumbnailCache.thumbnail(from: jpeg))
    #expect(Pixels(thumb) == Pixels(lazyThumb))
    #expect(max(thumb.width, thumb.height) == ThumbnailCache.maxPixelSize)

    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in jpeg })
    let loaded = try #require(try await cache.image(for: request(7)))
    #expect(Pixels(loaded) == Pixels(lazyThumb))
  }
}

private struct Pixels: Equatable {
  let width: Int
  let height: Int
  let bytesPerRow: Int
  let bitmapInfo: UInt32
  let bytes: Data?

  init(_ image: CGImage) {
    width = image.width
    height = image.height
    bytesPerRow = image.bytesPerRow
    bitmapInfo = image.bitmapInfo.rawValue
    bytes = image.dataProvider?.data as Data?
  }
}

/// Holds each decode job on its thread while closed; counts who got in.
private final class DecodeGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var closed = false
  private var active = 0
  private var enteredCount = 0
  private var peakCount = 0

  var entered: Int { condition.withLock { enteredCount } }
  var peak: Int { condition.withLock { peakCount } }
  var isOpen: Bool { condition.withLock { !closed } }

  func close() { condition.withLock { closed = true } }

  func open() {
    condition.withLock {
      closed = false
      condition.broadcast()
    }
  }

  var pass: @Sendable () -> Void {
    { [self] in
      condition.withLock {
        enteredCount += 1
        active += 1
        peakCount = max(peakCount, active)
        while closed { condition.wait() }
        active -= 1
      }
    }
  }
}

private final class ActiveCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var peakCount = 0
  private var totalCount = 0

  var peak: Int { lock.withLock { peakCount } }
  var total: Int { lock.withLock { totalCount } }

  func enter() {
    lock.withLock {
      active += 1
      peakCount = max(peakCount, active)
    }
  }

  func leave() {
    lock.withLock {
      active -= 1
      totalCount += 1
    }
  }
}
