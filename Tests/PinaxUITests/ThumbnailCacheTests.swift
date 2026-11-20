import CoreGraphics
import Foundation
import ImageIO
import PinaxUI
import Testing

@Suite struct ThumbnailCacheTests {
  private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-cache-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func request(_ sha: String) -> ThumbnailRequest {
    ThumbnailRequest(
      sha256: sha,
      sourceURL: URL(string: "https://img.example.com/originals/\(sha).png")!
    )
  }

  @Test("A miss downloads, decodes, and writes the cache file at the fixed layout")
  func downloadWritesCacheFile() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let jpeg = makeJPEGData() else {
      Issue.record("could not build fixture JPEG")
      return
    }
    let fetchedURLs = URLCollector()
    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { url in
      fetchedURLs.add(url)
      return jpeg
    })

    let sha = String(repeating: "ab", count: 32)
    let image = try await cache.image(for: request(sha))
    #expect(image != nil)
    #expect(fetchedURLs.count == 1)

    let expectedPath = directory.appendingPathComponent("\(sha.prefix(2))/\(sha).jpg")
    #expect(FileManager.default.fileExists(atPath: expectedPath.path))

    let decoded = await cache.cachedImage(for: request(sha))
    #expect(decoded != nil)
  }

  @Test("A hit — memory or disk — never contacts the fetcher again")
  func hitsDoNotRefetch() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let jpeg = makeJPEGData() else {
      Issue.record("could not build fixture JPEG")
      return
    }
    let counter = CounterBox()
    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in
      counter.increment()
      return jpeg
    })
    let sha = String(repeating: "cd", count: 32)

    _ = try await cache.image(for: request(sha))
    #expect(counter.value == 1)

    await cache.invalidateMemoryCache()
    _ = try await cache.image(for: request(sha))
    #expect(counter.value == 1)

    let secondCache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in
      counter.increment()
      return jpeg
    })
    _ = try await secondCache.image(for: request(sha))
    #expect(counter.value == 1)
  }

  @Test("A failed download is not cached as a failure")
  func failureIsNotCached() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let jpeg = makeJPEGData() else {
      Issue.record("could not build fixture JPEG")
      return
    }
    let flag = FlagBox(true)
    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in
      if flag.value {
        throw URLError(.networkConnectionLost)
      }
      return jpeg
    })
    let sha = String(repeating: "ef", count: 32)

    do {
      _ = try await cache.image(for: request(sha))
      Issue.record("expected a throw")
    } catch {}

    let expectedPath = directory.appendingPathComponent("\(sha.prefix(2))/\(sha).jpg")
    #expect(!FileManager.default.fileExists(atPath: expectedPath.path))

    flag.value = false
    let image = try await cache.image(for: request(sha))
    #expect(image != nil)
    #expect(FileManager.default.fileExists(atPath: expectedPath.path))
  }

  @Test("Non-image bytes produce no image and no cache entry")
  func garbageBytesAreRejected() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in
      Data("this is not an image".utf8)
    })
    let sha = String(repeating: "12", count: 32)
    let image = try await cache.image(for: request(sha))
    #expect(image == nil)
    let expectedPath = directory.appendingPathComponent("\(sha.prefix(2))/\(sha).jpg")
    #expect(!FileManager.default.fileExists(atPath: expectedPath.path))
  }

  @Test("Downloads are bounded at four concurrent requests")
  func concurrencyIsBounded() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let jpeg = makeJPEGData() else {
      Issue.record("could not build fixture JPEG")
      return
    }
    let counter = ConcurrentCounter()
    let cache = ThumbnailCache(
      cacheDirectory: directory,
      fetcher: { _ in
        _ = await counter.enter()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await counter.leave()
        return jpeg
      }
    )

    let shas: [ThumbnailRequest] = (0..<12).map { index in
      request(String(format: "%064x", index + 1))
    }
    await withTaskGroup(of: Void.self) { group in
      for request in shas {
        group.addTask {
          _ = try? await cache.image(for: request)
        }
      }
    }
    let peak = await counter.peak
    #expect(peak <= 4)
    #expect(peak >= 2)
  }

  /// A scrolling gallery is a steady trickle of new requests arriving while
  /// earlier ones finish — the shape that once broke the slot hand-off by
  /// letting a fresh caller slip between a release and its waiter's resumption.
  @Test("Staggered arrivals while earlier downloads finish still respect the bound")
  func staggeredArrivalsRespectBound() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let jpeg = makeJPEGData() else {
      Issue.record("could not build fixture JPEG")
      return
    }
    let counter = ConcurrentCounter()
    let cache = ThumbnailCache(
      cacheDirectory: directory,
      fetcher: { _ in
        _ = await counter.enter()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await counter.leave()
        return jpeg
      }
    )

    let total = 60
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<total {
        if index > 0 {
          try? await Task.sleep(nanoseconds: 3_000_000)
        }
        group.addTask { [cache] in
          _ = try? await cache.image(for: request(String(format: "%064x", index + 1)))
        }
      }
    }

    let peak = await counter.peak
    #expect(peak <= 4)
    let completed = await counter.totalEntered
    #expect(completed == total)
  }

  @Test("Store writes the thumbnail from local bytes without any fetch")
  func storeUsesLocalBytesOnly() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let jpeg = makeJPEGData() else {
      Issue.record("could not build fixture JPEG")
      return
    }
    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in
      Issue.record("store must not fetch — the bytes are in hand")
      throw URLError(.unsupportedURL)
    })

    let sha = String(repeating: "be", count: 32)
    let image = await cache.store(data: jpeg, for: request(sha))
    #expect(image != nil)

    let expectedPath = directory.appendingPathComponent("\(sha.prefix(2))/\(sha).jpg")
    #expect(FileManager.default.fileExists(atPath: expectedPath.path))

    // A gallery cell asking for the same asset hits the cache, not the network.
    let cached = try await cache.image(for: request(sha))
    #expect(cached != nil)
  }

  @Test("Storing non-image bytes writes nothing")
  func storeRejectsGarbage() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in
      Issue.record("store must not fetch")
      throw URLError(.unsupportedURL)
    })

    let sha = String(repeating: "34", count: 32)
    let image = await cache.store(data: Data("not an image".utf8), for: request(sha))
    #expect(image == nil)
    let expectedPath = directory.appendingPathComponent("\(sha.prefix(2))/\(sha).jpg")
    #expect(!FileManager.default.fileExists(atPath: expectedPath.path))
  }

  @Test("Deleting the cache directory mid-session degrades to misses without crashing")
  func deletedCacheIsHarmless() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let jpeg = makeJPEGData() else {
      Issue.record("could not build fixture JPEG")
      return
    }
    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in jpeg })
    let sha = String(repeating: "99", count: 32)
    _ = try await cache.image(for: request(sha))

    try FileManager.default.removeItem(at: directory)
    await cache.invalidateMemoryCache()

    let image = try await cache.image(for: request(sha))
    #expect(image != nil)
  }

  /// The synchronous peek backs a rebuilt cell's first
  /// frame. It sees the in-memory layer only — never disk, never the
  /// fetcher — and goes nil the moment the memory layer is dropped, so a
  /// disk-only state is an honest miss for it.
  @Test("The synchronous peek reads memory only — warmed hit, cold and disk-only misses")
  func peekReadsMemoryLayerOnly() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let jpeg = makeJPEGData() else {
      Issue.record("could not build fixture JPEG")
      return
    }
    let cache = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in jpeg })
    let sha = String(repeating: "77", count: 32)

    #expect(cache.peekMemoryImage(for: sha) == nil)

    _ = try await ThumbnailCache(cacheDirectory: directory, fetcher: { _ in jpeg })
      .image(for: request(sha))
    // The sibling instance wrote the disk file; this instance's memory
    // layer is cold, so the peek must report a miss without touching it.
    #expect(cache.peekMemoryImage(for: sha) == nil)

    _ = try await cache.image(for: request(sha))
    #expect(cache.peekMemoryImage(for: sha) != nil)

    await cache.invalidateMemoryCache()
    #expect(cache.peekMemoryImage(for: sha) == nil)
  }
}

private actor ConcurrentCounter {
  private(set) var active = 0
  private(set) var peak = 0
  private(set) var totalEntered = 0

  func enter() -> Int {
    active += 1
    totalEntered += 1
    peak = max(peak, active)
    return active
  }

  func leave() {
    active -= 1
  }
}


private final class CounterBox: @unchecked Sendable {
  private let lock = NSLock()
  private var backing = 0

  var value: Int {
    lock.withLock { backing }
  }

  func increment() {
    lock.withLock { backing += 1 }
  }
}

private final class FlagBox: @unchecked Sendable {
  private let lock = NSLock()
  private var backing: Bool

  init(_ value: Bool) {
    self.backing = value
  }

  var value: Bool {
    get { lock.withLock { backing } }
    set { lock.withLock { backing = newValue } }
  }
}

private final class URLCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []

  var count: Int {
    lock.withLock { urls.count }
  }

  func add(_ url: URL) {
    lock.withLock { urls.append(url) }
  }
}
