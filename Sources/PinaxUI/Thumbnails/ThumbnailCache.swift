import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public typealias ThumbnailFetcher = @Sendable (URL) async throws -> Data

/// A remote image answered with a non-2xx status; the sentence is the
/// status and its standard phrase, "404 · not found".
public struct RemoteImageStatusError: LocalizedError, Equatable, Sendable {
  public let statusCode: Int

  public init(statusCode: Int) {
    self.statusCode = statusCode
  }

  public var errorDescription: String? {
    "\(statusCode) · \(HTTPURLResponse.localizedString(forStatusCode: statusCode))"
  }

  /// The response's body, or this error for a status outside 2xx.
  static func check(_ data: Data, _ response: URLResponse) throws -> Data {
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard (200..<300).contains(http.statusCode) else {
      throw RemoteImageStatusError(statusCode: http.statusCode)
    }
    return data
  }
}

/// What a Load read off the original it fetched —
/// its size in bytes, its pixels and its type. Never asked for on its own:
/// it rides along with the thumbnail's one download.
public struct RemoteImageInfo: Codable, Equatable, Sendable {
  public let bytes: Int64
  public let pixelWidth: Int
  public let pixelHeight: Int
  /// The type ImageIO read from the bytes, as a UTI.
  public let typeIdentifier: String

  public init(bytes: Int64, pixelWidth: Int, pixelHeight: Int, typeIdentifier: String) {
    self.bytes = bytes
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.typeIdentifier = typeIdentifier
  }

  public var type: UTType? { UTType(typeIdentifier) }

  /// "JPEG", "PNG", "WEBP": the type's own extension, upper case.
  public var typeName: String {
    type?.preferredFilenameExtension?.uppercased() ?? "Image"
  }

  /// At or over `PinaxFormat.largeImageBytes`.
  public var isLarge: Bool { PinaxFormat.isLarge(bytes) }

  /// The facts of `data`, or nil when ImageIO can't read it as an image.
  public static func read(_ data: Data) -> RemoteImageInfo? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source) as String?,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return RemoteImageInfo(
      bytes: Int64(data.count), pixelWidth: width, pixelHeight: height, typeIdentifier: type)
  }
}

/// A thumbnail and, when its original came through a Load, the original's
/// facts; nil for an entry cached before them.
public struct ThumbnailLoad: Sendable {
  public let image: CGImage
  public let info: RemoteImageInfo?
}

public struct ThumbnailRequest: Sendable, Hashable {
  public let sha256: String
  public let sourceURL: URL

  public init(sha256: String, sourceURL: URL) {
    self.sha256 = sha256
    self.sourceURL = sourceURL
  }

  public var cachePathComponent: String {
    "\(sha256.prefix(2))/\(sha256).jpg"
  }
}

/// Owns the on-disk thumbnail cache and the bounded download pipeline.
///
/// Two bounds, each guarding its own resource: a download slot covers only
/// fetching an original's bytes, and the decode pool covers every ImageIO
/// step — reading a cached file, downscaling, writing the JPEG. The actor
/// itself does bookkeeping only, so a memory hit never waits behind pixels.
///
/// The cache directory is pure derived data: deleting it at any moment is harmless,
/// it is never referenced from SQLite, and every entry is rebuildable from the
/// original object. A failed download is never recorded — the next appearance of a
/// cell retries, and because loads are driven by cell appearance they cannot loop
/// tightly.
public actor ThumbnailCache {
  public static let maxPixelSize: Int = 512
  /// Upper bound on the decoded pixels held in memory; each entry costs
  /// `bytesPerRow × height`. The entry count limit stays as well — whichever
  /// is reached first evicts.
  static let memoryCostLimit = 256 * 1024 * 1024
  static let memoryCountLimit = 512
  static let defaultDecodeConcurrency = 3

  private let directory: URL
  private let fetcher: ThumbnailFetcher
  private let maxConcurrentDownloads: Int
  nonisolated let decodePool: ThumbnailDecodePool
  /// `NSCache` is documented thread-safe, and isolating it would force the
  /// reflow peek (below) through an actor hop it cannot afford; the unsafe
  /// opt-out is exactly this one constant, whose every use is a cache call.
  private nonisolated(unsafe) let memory = NSCache<NSString, CGImage>()
  /// The originals' facts by request key; on disk beside each
  /// thumbnail as `<sha>.json`, so a cache hit has them without a request.
  private var infos: [String: RemoteImageInfo] = [:]
  private var inFlightCount = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  public init(
    cacheDirectory: URL? = nil,
    fetcher: ThumbnailFetcher? = nil,
    maxConcurrentDownloads: Int = 4
  ) {
    self.init(
      cacheDirectory: cacheDirectory,
      fetcher: fetcher,
      maxConcurrentDownloads: maxConcurrentDownloads,
      decodeConcurrency: Self.defaultDecodeConcurrency,
      beforeDecode: nil
    )
  }

  /// `beforeDecode` runs on the decode thread ahead of each pooled job.
  init(
    cacheDirectory: URL?,
    fetcher: ThumbnailFetcher?,
    maxConcurrentDownloads: Int,
    decodeConcurrency: Int,
    beforeDecode: (@Sendable () -> Void)?
  ) {
    let base =
      cacheDirectory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("tech.gitkeniwo.pinax/thumbs", isDirectory: true)
    self.directory = base ?? FileManager.default.temporaryDirectory.appendingPathComponent("thumbs")
    self.fetcher = fetcher ?? ThumbnailCache.defaultFetcher
    self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
    self.decodePool = ThumbnailDecodePool(limit: decodeConcurrency, beforeWork: beforeDecode)
    memory.countLimit = Self.memoryCountLimit
    memory.totalCostLimit = Self.memoryCostLimit
  }

  /// What an image costs against `memoryCostLimit`.
  static func memoryCost(of image: CGImage) -> Int {
    image.bytesPerRow * image.height
  }

  nonisolated var memoryTotalCostLimit: Int { memory.totalCostLimit }

  private func remember(_ image: CGImage, for sha256: String) {
    memory.setObject(image, forKey: sha256 as NSString, cost: Self.memoryCost(of: image))
  }

  public static let defaultFetcher: ThumbnailFetcher = { url in
    let (data, response) = try await URLSession.shared.data(from: url)
    return try RemoteImageStatusError.check(data, response)
  }

  /// Cached file URL for a request, whether or not it exists yet.
  public nonisolated func fileURL(for request: ThumbnailRequest) -> URL {
    directory.appendingPathComponent(request.cachePathComponent)
  }

  public func cachedImage(for request: ThumbnailRequest) async -> CGImage? {
    if let hit = memory.object(forKey: request.sha256 as NSString) {
      return hit
    }
    let url = fileURL(for: request)
    guard FileManager.default.fileExists(atPath: url.path),
      let image = await decodePool.run({ Self.decode(url) })
    else { return nil }
    remember(image, for: request.sha256)
    return image
  }

  /// A synchronous peek at the in-memory layer only. A cell
  /// `LazyVGrid` discards during a reflow comes back as a brand-new identity
  /// whose first frame used to be the placeholder — even with the image
  /// sitting in this cache — because loading was only reachable through an
  /// `await`. `NSCache` is documented thread-safe, so this reads it without
  /// hopping the actor; it must not block, touch disk, or download — a miss
  /// is a miss and the async path stays the only loader.
  public nonisolated func peekMemoryImage(for sha256: String) -> CGImage? {
    memory.object(forKey: sha256 as NSString)
  }

  /// Quick Look needs a file URL synchronously for its first frame. Normal
  /// thumbnail loads already write this file; if only the memory seed
  /// survived a grid reflow, materialize those same 512px pixels without a
  /// network request so the preview panel still never opens empty.
  public nonisolated func previewFileURL(for request: ThumbnailRequest) -> URL? {
    let destination = fileURL(for: request)
    if FileManager.default.fileExists(atPath: destination.path) { return destination }
    guard let image = memory.object(forKey: request.sha256 as NSString) else { return nil }
    Self.writeAtomically(image, to: destination)
    return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
  }

  /// The `.json` beside a thumbnail that holds its original's facts.
  nonisolated func infoURL(for request: ThumbnailRequest) -> URL {
    fileURL(for: request).deletingPathExtension().appendingPathExtension("json")
  }

  /// The original's facts for a cached thumbnail; nil when they were never
  /// recorded. Reads memory, then disk — never the network.
  public func cachedInfo(for request: ThumbnailRequest) -> RemoteImageInfo? {
    if let hit = infos[request.sha256] { return hit }
    guard let data = try? Data(contentsOf: infoURL(for: request)),
      let info = try? JSONDecoder().decode(RemoteImageInfo.self, from: data)
    else { return nil }
    infos[request.sha256] = info
    return info
  }

  public func invalidateMemoryCache() {
    memory.removeAllObjects()
  }

  /// A permanently deleted image: its thumbnail leaves
  /// memory and disk.
  public func forget(sha256: String) {
    memory.removeObject(forKey: sha256 as NSString)
    infos[sha256] = nil
    let request = ThumbnailRequest(sha256: sha256, sourceURL: directory)
    try? FileManager.default.removeItem(at: fileURL(for: request))
    try? FileManager.default.removeItem(at: infoURL(for: request))
  }

  /// Stores a thumbnail generated from bytes already in hand — the upload
  /// path, where the original is local and must never cost a download. This
  /// is the one place upload and cache legitimately touch.
  public func store(data: Data, for request: ThumbnailRequest) -> CGImage? {
    guard let image = Self.thumbnail(from: data) else { return nil }
    writeAtomically(image, for: request)
    remember(image, for: request.sha256)
    return image
  }

  /// Returns the thumbnail for `request`, downloading and caching it on miss.
  /// Cancellation propagates into the download; a cancelled call leaves no state.
  public func image(for request: ThumbnailRequest) async throws -> CGImage? {
    try await fetch(request, keepingInfo: false)?.image
  }

  /// As `image(for:)`, with the original's bytes,
  /// pixels and type read from the same download — and, on a cache hit,
  /// from the record that download left. A thumbnail cached before those
  /// records existed has none: its original is asked for once more, the
  /// record written, and the cached image kept; a failed ask leaves the
  /// image without facts.
  public func load(for request: ThumbnailRequest) async throws -> ThumbnailLoad? {
    let wasCached = await cachedImage(for: request) != nil
    guard let load = try await fetch(request, keepingInfo: true) else { return nil }
    guard load.info == nil, wasCached else { return load }
    await acquireSlot()
    defer { releaseSlot() }
    if let info = cachedInfo(for: request) { return ThumbnailLoad(image: load.image, info: info) }
    guard let data = try? await fetcher(request.sourceURL), let info = RemoteImageInfo.read(data)
    else { return load }
    keep(info, for: request)
    return ThumbnailLoad(image: load.image, info: info)
  }

  private func keep(_ info: RemoteImageInfo, for request: ThumbnailRequest) {
    infos[request.sha256] = info
    Self.writeInfo(info, to: infoURL(for: request))
  }

  private nonisolated static func writeInfo(_ info: RemoteImageInfo, to url: URL) {
    if let json = try? JSONEncoder().encode(info) {
      try? json.write(to: url, options: .atomic)
    }
  }

  private func fetch(_ request: ThumbnailRequest, keepingInfo: Bool) async throws -> ThumbnailLoad? {
    if let cached = await cachedImage(for: request) {
      return ThumbnailLoad(image: cached, info: keepingInfo ? cachedInfo(for: request) : nil)
    }
    let data: Data
    do {
      await acquireSlot()
      defer { releaseSlot() }
      if let raced = await cachedImage(for: request) {
        return ThumbnailLoad(image: raced, info: keepingInfo ? cachedInfo(for: request) : nil)
      }
      data = try await fetcher(request.sourceURL)
    }
    // The slot is back in the pool; everything below is ImageIO and disk.
    let destination = fileURL(for: request)
    let infoDestination = infoURL(for: request)
    let made: (image: CGImage, info: RemoteImageInfo?)? = await decodePool.run {
      guard let image = Self.thumbnail(from: data) else { return nil }
      Self.writeAtomically(image, to: destination)
      guard keepingInfo, let info = RemoteImageInfo.read(data) else { return (image, nil) }
      Self.writeInfo(info, to: infoDestination)
      return (image, info)
    }
    guard let made else { return nil }
    remember(made.image, for: request.sha256)
    if let info = made.info { infos[request.sha256] = info }
    return ThumbnailLoad(image: made.image, info: made.info)
  }

  /// The slot count is the number of holders; a queued caller receives its slot
  /// by hand-off on resume rather than re-taking it. Releasing and re-acquiring
  /// separately would open a window where a fresh caller sees a temporarily low
  /// count and overshoots the bound.
  private func acquireSlot() async {
    if inFlightCount < maxConcurrentDownloads {
      inFlightCount += 1
      return
    }
    await withCheckedContinuation { continuation in
      waiting.append(continuation)
    }
  }

  private func releaseSlot() {
    if waiting.isEmpty {
      inFlightCount -= 1
    } else {
      waiting.removeFirst().resume()
    }
  }

  private func writeAtomically(_ image: CGImage, for request: ThumbnailRequest) {
    let destinationPath = fileURL(for: request)
    Self.writeAtomically(image, to: destinationPath)
  }

  private nonisolated static func writeAtomically(_ image: CGImage, to destinationPath: URL) {
    let temporaryPath = destinationPath.deletingLastPathComponent()
      .appendingPathComponent(UUID().uuidString + ".tmp")
    do {
      try FileManager.default.createDirectory(
        at: destinationPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard let destination = CGImageDestinationCreateWithURL(
        temporaryPath as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      ) else {
        return
      }
      let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
      CGImageDestinationAddImage(destination, image, options as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        try? FileManager.default.removeItem(at: temporaryPath)
        return
      }
      try FileManager.default.moveItem(at: temporaryPath, to: destinationPath)
    } catch {
      try? FileManager.default.removeItem(at: temporaryPath)
    }
  }

  public static func decode(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }
    let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
    return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
  }

  /// Decodes a downscaled thumbnail from arbitrary image bytes. Both transform
  /// flags are load-bearing: without `…FromImageAlways` ImageIO prefers the
  /// often-stale EXIF thumbnail, and without `…WithTransform` portrait photos
  /// render sideways. `…CacheImmediately` decodes the pixels here, off the
  /// main thread, instead of at the first draw.
  public static func thumbnail(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

/// Runs ImageIO jobs on a private dispatch queue, at most `limit` at a time.
/// Decoding blocks a thread for its whole run, so it stays off both the
/// cache's actor and Swift's cooperative pool; a queued job receives its
/// place by hand-off, as the download slots do.
actor ThumbnailDecodePool {
  nonisolated let limit: Int
  private nonisolated let queue = DispatchQueue(
    label: "PinaxUI.ThumbnailDecodePool", qos: .userInitiated, attributes: .concurrent)
  private nonisolated let beforeWork: (@Sendable () -> Void)?
  private(set) var running = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(limit: Int, beforeWork: (@Sendable () -> Void)? = nil) {
    self.limit = max(1, limit)
    self.beforeWork = beforeWork
  }

  /// Jobs waiting for a place.
  var queued: Int { waiting.count }

  nonisolated func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await acquire()
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
      queue.async { [beforeWork] in
        beforeWork?()
        continuation.resume(returning: work())
      }
    }
    await release()
    return result
  }

  private func acquire() async {
    if running < limit {
      running += 1
      return
    }
    await withCheckedContinuation { continuation in
      waiting.append(continuation)
    }
  }

  private func release() {
    if waiting.isEmpty {
      running -= 1
    } else {
      waiting.removeFirst().resume()
    }
  }
}
