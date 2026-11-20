import Foundation

public typealias OriginalImageFetcher = @Sendable (URL) async throws -> Data

public struct OriginalImageRequest: Sendable, Hashable {
  public let sha256: String
  public let sourceURL: URL
  public let filename: String

  public init(sha256: String, sourceURL: URL, filename: String) {
    self.sha256 = sha256
    self.sourceURL = sourceURL
    self.filename = filename
  }

  var fileExtension: String {
    let filenameExtension = (filename as NSString).pathExtension
    let candidate = filenameExtension.isEmpty ? sourceURL.pathExtension : filenameExtension
    let safe = candidate.lowercased().filter { $0.isLetter || $0.isNumber }
    return safe.isEmpty ? "image" : safe
  }

  var cachePathComponent: String {
    "\(sha256.prefix(2))/\(sha256)/original.\(fileExtension)"
  }
}

/// A bounded, disposable cache for original image bytes used only by Quick Look.
/// Its LRU timestamp lives on the cache files themselves; no cache bytes or
/// bookkeeping ever enter the catalog.
public actor OriginalImageCache {
  public static let defaultCapacity: Int64 = 1_073_741_824

  private let directory: URL
  private let fetcher: OriginalImageFetcher
  private let capacity: Int64

  public init(
    cacheDirectory: URL? = nil,
    capacity: Int64 = OriginalImageCache.defaultCapacity,
    fetcher: OriginalImageFetcher? = nil
  ) {
    let base =
      cacheDirectory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("tech.gitkeniwo.pinax/originals", isDirectory: true)
    self.directory =
      base ?? FileManager.default.temporaryDirectory.appendingPathComponent("pinax-originals")
    self.capacity = max(0, capacity)
    self.fetcher = fetcher ?? Self.defaultFetcher
  }

  public static let defaultFetcher: OriginalImageFetcher = { url in
    let (data, response) = try await URLSession.shared.data(from: url)
    return try RemoteImageStatusError.check(data, response)
  }

  public nonisolated func fileURL(for request: OriginalImageRequest) -> URL {
    directory.appendingPathComponent(request.cachePathComponent)
  }

  public func cachedFile(for request: OriginalImageRequest) -> URL? {
    let url = fileURL(for: request)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    touch(url)
    return url
  }

  public func file(for request: OriginalImageRequest) async throws -> URL {
    if let hit = cachedFile(for: request) { return hit }
    try Task.checkCancellation()
    let data = try await fetcher(request.sourceURL)
    try Task.checkCancellation()

    let destination = fileURL(for: request)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination, options: .atomic)
    do {
      try Task.checkCancellation()
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    touch(destination)
    evictIfNeeded(protecting: destination)
    return destination
  }

  /// A permanently deleted image: its folder goes.
  public func forget(sha256: String) {
    try? FileManager.default.removeItem(
      at: directory.appendingPathComponent("\(sha256.prefix(2))/\(sha256)", isDirectory: true))
  }

  public func totalByteCount() -> Int64 {
    cacheEntries().reduce(0) { $0 + $1.size }
  }

  private func touch(_ url: URL) {
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
  }

  private func evictIfNeeded(protecting protectedURL: URL) {
    var entries = cacheEntries()
    var total = entries.reduce(0) { $0 + $1.size }
    guard total > capacity else { return }
    entries.sort { $0.date < $1.date }
    for entry in entries where entry.url != protectedURL && total > capacity {
      do {
        try FileManager.default.removeItem(at: entry.url)
        total -= entry.size
      } catch {}
    }
  }

  private func cacheEntries() -> [(url: URL, size: Int64, date: Date)] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles])
    else { return [] }

    return enumerator.compactMap { value in
      guard let url = value as? URL,
        let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else { return nil }
      return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
    }
  }
}
