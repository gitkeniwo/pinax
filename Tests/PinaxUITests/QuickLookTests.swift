import Foundation
import PinaxUI
import Testing

@Suite struct OriginalImageCacheTests {
  private func directory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-original-cache-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func request(_ character: Character) -> OriginalImageRequest {
    let sha = String(repeating: String(character), count: 64)
    return OriginalImageRequest(
      sha256: sha,
      sourceURL: URL(string: "https://images.example.com/\(sha).png")!,
      filename: "\(sha).png")
  }

  @Test("Original bytes use a separate sha-keyed disk cache and hits do not fetch")
  func diskHit() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let calls = LockedCounter()
    let cache = OriginalImageCache(cacheDirectory: directory, fetcher: { _ in
      calls.increment()
      return Data(repeating: 7, count: 16)
    })
    let request = request("a")

    let first = try await cache.file(for: request)
    let second = try await cache.file(for: request)

    #expect(first == second)
    #expect(first.path.contains(request.sha256))
    #expect(calls.value == 1)
    #expect((try Data(contentsOf: first)).count == 16)
  }

  @Test("Capacity is enforced by least-recently-used file eviction")
  func lruEviction() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = OriginalImageCache(
      cacheDirectory: directory, capacity: 16,
      fetcher: { url in Data(repeating: UInt8(url.absoluteString.count), count: 8) })
    let firstRequest = request("b")
    let secondRequest = request("c")
    let thirdRequest = request("f")
    let first = try await cache.file(for: firstRequest)
    try await Task.sleep(for: .milliseconds(10))
    let second = try await cache.file(for: secondRequest)
    try await Task.sleep(for: .milliseconds(10))
    _ = await cache.cachedFile(for: firstRequest)
    try await Task.sleep(for: .milliseconds(10))
    let third = try await cache.file(for: thirdRequest)

    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(!FileManager.default.fileExists(atPath: second.path))
    #expect(FileManager.default.fileExists(atPath: third.path))
    #expect(await cache.totalByteCount() <= 16)
  }
}

@MainActor
@Suite struct QuickLookCancellationTests {
  @Test("Moving the selected item cancels its in-flight original request")
  func selectionMoveCancelsRequest() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-quick-look-cancel-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = CancellationProbe()
    let cache = OriginalImageCache(cacheDirectory: directory, fetcher: { _ in
      probe.markStarted()
      return try await withTaskCancellationHandler {
        try await Task.sleep(for: .seconds(60))
        return Data([1])
      } onCancel: {
        probe.markCancelled()
      }
    })
    let loader = QuickLookLoadCoordinator(cache: cache)
    let first = OriginalImageRequest(
      sha256: String(repeating: "d", count: 64),
      sourceURL: URL(string: "https://images.example.com/first.png")!, filename: "first.png")
    let second = OriginalImageRequest(
      sha256: String(repeating: "e", count: 64),
      sourceURL: URL(string: "https://images.example.com/second.png")!, filename: "second.png")

    loader.select(first) { _ in }
    try await waitUntil { probe.started }
    loader.select(second, delay: .seconds(60)) { _ in }
    try await waitUntil { probe.cancelled }

    #expect(probe.cancelled)
    #expect(!FileManager.default.fileExists(atPath: cache.fileURL(for: first).path))
    loader.cancel()
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

private final class CancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var didStart = false
  private var didCancel = false

  func markStarted() { lock.withLock { didStart = true } }
  func markCancelled() { lock.withLock { didCancel = true } }
  var started: Bool { lock.withLock { didStart } }
  var cancelled: Bool { lock.withLock { didCancel } }
}
