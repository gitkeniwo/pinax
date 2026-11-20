import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
@preconcurrency import QuickLookUI
import Testing

/// A stand-in for `QLPreviewPanel` that treats keys the way the real one was
/// measured to (three text items, keys posted to the key panel): ← →
/// move its own `currentPreviewItemIndex` (key-value observable, as the real
/// one's is) without asking the delegate, space closes it without asking,
/// and every other key goes to `previewPanel(_:handle:)`. It asks the data
/// source for the shown item on `reloadData` and on an index move only:
/// `refreshCurrentPreviewItem` re-renders the item it already holds
/// (measured: the data source is not asked, the old file stays).
/// Closing is as measured: `close()` asks the delegate for the
/// source frame and the transition image before it returns, still visible;
/// a run-loop turn later it is hidden and the delegate gets
/// `windowWillClose`. Space closes the same way.
@MainActor
final class FakeQuickLookPanel: NSObject, QuickLookPanel {
  @objc dynamic var currentPreviewItemIndex = 0 {
    didSet { fetchShownItem() }
  }
  private(set) var isVisible = false
  private(set) weak var controller: QuickLookController?
  private(set) var currentItem: QLPreviewItem?
  /// What each `close()` got from the delegate to zoom back into.
  private(set) var closingSourceFrames: [NSRect] = []
  private(set) var closingContentRects: [NSRect] = []
  private(set) var closingImages: [NSImage?] = []

  func attach(_ controller: QuickLookController?) { self.controller = controller }
  func reloadData() { fetchShownItem() }
  func refreshCurrentPreviewItem() {}
  func makeKeyAndOrderFront(_ sender: Any?) { isVisible = true }
  func close() {
    closingSourceFrames.append(
      controller?.previewPanel(nil, sourceFrameOnScreenFor: currentItem) ?? .zero)
    var contentRect = NSRect.zero
    closingImages.append(
      controller?.previewPanel(nil, transitionImageFor: currentItem, contentRect: &contentRect)
        as? NSImage)
    closingContentRects.append(contentRect)
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.isVisible = false
        self.controller?.windowWillClose(
          Notification(name: NSWindow.willCloseNotification, object: self))
      }
    }
  }

  var count: Int { controller?.numberOfPreviewItems(in: nil) ?? 0 }

  /// The pixel size of the file the panel was handed for the shown item —
  /// what it sizes itself by.
  var shownPixelSize: CGSize? {
    guard let url = currentItem?.previewItemURL,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return CGSize(width: width, height: height)
  }

  private func fetchShownItem() {
    currentItem = controller?.previewPanel(nil, previewItemAt: currentPreviewItemIndex)
  }

  func press(_ event: NSEvent) {
    switch event.specialKey {
    case .leftArrow? where count > 1:
      currentPreviewItemIndex = (currentPreviewItemIndex + count - 1) % count
    case .rightArrow? where count > 1:
      currentPreviewItemIndex = (currentPreviewItemIndex + 1) % count
    default:
      if event.charactersIgnoringModifiers == " " {
        close()
      } else {
        _ = controller?.previewPanel(nil, handle: event)
      }
    }
  }

  /// ◀ ▶ in the panel's own toolbar: the same index move as ← →.
  func clickNext() { currentPreviewItemIndex = (currentPreviewItemIndex + 1) % count }
  func clickPrevious() {
    currentPreviewItemIndex = (currentPreviewItemIndex + count - 1) % count
  }
}

/// Records which originals were requested and which requests were cancelled;
/// requests hang until cancelled, or fail / succeed at once when `fails` /
/// `succeeds` is set.
final class OriginalFetchProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var startedURLs: [URL] = []
  private var cancelledURLs: [URL] = []
  let fails: Bool
  let succeeds: Bool
  let payload: Data

  init(fails: Bool = false, succeeds: Bool = false, payload: Data = Data([1])) {
    self.fails = fails
    self.succeeds = succeeds
    self.payload = payload
  }

  var started: [URL] { lock.withLock { startedURLs } }
  var cancelled: [URL] { lock.withLock { cancelledURLs } }

  func cache(in directory: URL) -> OriginalImageCache {
    OriginalImageCache(cacheDirectory: directory, fetcher: { [self] url in
      lock.withLock { startedURLs.append(url) }
      if fails { throw URLError(.notConnectedToInternet) }
      if succeeds { return payload }
      return try await withTaskCancellationHandler {
        try await Task.sleep(for: .seconds(60))
        return Data([1])
      } onCancel: {
        self.lock.withLock { self.cancelledURLs.append(url) }
      }
    })
  }
}

/// A PNG of `width × height` pixels.
func pngData(width: Int, height: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  return rep.representation(using: .png, properties: [:])!
}

func quickLookKey(_ characters: String, _ keyCode: UInt16) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
    characters: characters, charactersIgnoringModifiers: characters,
    isARepeat: false, keyCode: keyCode)!
}

/// No status file; a failed original keeps
/// the thumbnail entry, says so in its title, and puts the sentence in the
/// status bar's error slot.
@MainActor
@Suite struct QuickLookPanelTests {
  @Test("A failed original is titled unavailable and its sentence reaches the status bar")
  func failedOriginal() async throws {
    // `toggleQuickLookFromCommand` reads `NSApp.currentEvent`; the hosted
    // suites create the application, this one may run first.
    _ = NSApplication.shared
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<3 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
    }
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let probe = OriginalFetchProbe(fails: true)
    let panel = FakeQuickLookPanel()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database), thumbnails: thumbnails,
      quickLook: QuickLookController(
        thumbnails: thumbnails,
        originals: probe.cache(in: directory.appendingPathComponent("originals")),
        panel: { panel }))
    await model.loadInitialData()
    model.select(model.rows[1])

    model.toggleQuickLookFromCommand()
    #expect(panel.isVisible)
    #expect(panel.count == 3, "the panel pages through the loaded rows")
    #expect(panel.currentPreviewItemIndex == 1)
    for _ in 0..<100 where model.quickLookErrorMessage == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.quickLookErrorMessage?.hasPrefix("Could not load the original image") == true)
    #expect(panel.currentItem?.previewItemTitle?.hasSuffix("— original unavailable") == true)
    #expect(probe.started.count == 1, "only the current entry is fetched")

    // The sentence is also in the panel's title, so it goes when the panel
    // does; Download Original's sentence has no other place to be read and
    // stays.
    let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    model.downloader = OriginalDownloader(fetcher: DownloadOriginalTests.FakeFetcher(objects: [:]))
    model.downloadFolder = downloads
    await model.downloadSelection()
    let downloadError = try #require(model.downloadError)
    model.toggleQuickLookFromCommand()
    for _ in 0..<100 where panel.isVisible { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!panel.isVisible)
    #expect(model.quickLookErrorMessage == nil, "closing the panel clears its sentence")
    #expect(model.downloadError == downloadError, "the download sentence stays")
    #expect(GalleryStatusBar(model: model).activityText == downloadError)
  }

  @Test("An original that lands while the panel is open replaces the shown thumbnail entry")
  func landedOriginalIsShown() async throws {
    _ = NSApplication.shared
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<3 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
    }
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let originals = OriginalFetchProbe(succeeds: true).cache(
      in: directory.appendingPathComponent("originals"))
    let panel = FakeQuickLookPanel()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database), thumbnails: thumbnails,
      quickLook: QuickLookController(
        thumbnails: thumbnails, originals: originals, panel: { panel }))
    await model.loadInitialData()
    model.select(model.rows[0])
    model.toggleQuickLookFromCommand()

    // Arrive on the next row the way the user does with the panel open.
    panel.press(quickLookKey(String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), 124))
    #expect(model.selectedIDs == [model.rows[1].id])
    let row = model.rows[1].item
    let expected = originals.fileURL(
      for: OriginalImageRequest(
        sha256: row.asset.sha256, sourceURL: URL(string: row.url)!,
        filename: row.asset.originalFilename ?? (row.asset.key as NSString).lastPathComponent))
    for _ in 0..<100 where panel.currentItem?.previewItemURL != expected {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(panel.currentItem?.previewItemURL == expected, "the panel shows the landed original")
    #expect(panel.currentItem?.previewItemTitle?.contains("loading") == false)
  }

  // MARK: - Opening, paging and closing

  private struct Fixture {
    let model: GalleryModel
    let panel: FakeQuickLookPanel
    let originals: OriginalImageCache
    let directory: URL
    let placeholders: URL
  }

  /// Three rows at the library's `library` size (800 × 600 by default),
  /// each with an 800 × 600 thumbnail file on disk.
  private func makeFixture(
    _ probe: OriginalFetchProbe, library: CGSize = CGSize(width: 800, height: 600)
  ) async throws -> Fixture {
    _ = NSApplication.shared
    let (database, directory) = try makeUITestDatabase()
    for index in 0..<3 {
      try seedAsset(
        database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z",
        width: Int(library.width), height: Int(library.height))
    }
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let originals = probe.cache(in: directory.appendingPathComponent("originals"))
    let placeholders = directory.appendingPathComponent("placeholders", isDirectory: true)
    let panel = FakeQuickLookPanel()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database), thumbnails: thumbnails,
      quickLook: QuickLookController(
        thumbnails: thumbnails, originals: originals, placeholderDirectory: placeholders,
        panel: { panel }))
    await model.loadInitialData()
    for row in model.rows {
      _ = await thumbnails.store(
        data: pngData(width: 800, height: 600),
        for: ThumbnailRequest(sha256: row.item.asset.sha256, sourceURL: URL(string: row.item.url)!))
    }
    return Fixture(
      model: model, panel: panel, originals: originals, directory: directory,
      placeholders: placeholders)
  }

  private func originalURL(_ fixture: Fixture, _ row: Int) -> URL {
    let item = fixture.model.rows[row].item
    return fixture.originals.fileURL(
      for: OriginalImageRequest(
        sha256: item.asset.sha256, sourceURL: URL(string: item.url)!,
        filename: item.asset.originalFilename ?? (item.asset.key as NSString).lastPathComponent))
  }

  @Test("An original already in the disk cache is the first item the panel gets")
  func cachedOriginalOpensFirst() async throws {
    let fixture = try await makeFixture(OriginalFetchProbe())
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    for row in [1, 2] {
      let cached = originalURL(fixture, row)
      try FileManager.default.createDirectory(
        at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
      try pngData(width: 800, height: 600).write(to: cached)
    }

    fixture.model.select(fixture.model.rows[1])
    fixture.model.toggleQuickLookFromCommand()
    #expect(fixture.panel.currentItem?.previewItemURL == originalURL(fixture, 1))
    #expect(fixture.panel.currentItem?.previewItemTitle == "asset-1.png")

    // Paging onto another cached row: the panel asks before the selection
    // follows, and gets the original then too.
    fixture.panel.press(
      quickLookKey(String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), 124))
    #expect(fixture.panel.currentItem?.previewItemURL == originalURL(fixture, 2))
  }

  /// Cold open and paging onto a row whose
  /// original has not landed both hand the panel a file the library's size;
  /// the original that lands keeps it; the placeholders go on close.
  @Test("Rows without their original show a placeholder the library's size, gone on close")
  func placeholderHasLibrarySize() async throws {
    let fixture = try await makeFixture(
      OriginalFetchProbe(succeeds: true, payload: pngData(width: 800, height: 600)))
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let (model, panel) = (fixture.model, fixture.panel)
    let library = CGSize(width: 800, height: 600)

    model.select(model.rows[0])
    model.toggleQuickLookFromCommand()
    let cold = try #require(panel.currentItem?.previewItemURL)
    #expect(panel.shownPixelSize == library, "cold open: the thumbnail is 512 × 384")
    #expect(cold.deletingLastPathComponent() == fixture.placeholders)
    #expect(panel.currentItem?.previewItemTitle?.hasSuffix("— loading original…") == true)

    // The panel's own →, onto a row whose original has not landed.
    panel.press(quickLookKey(String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), 124))
    #expect(model.selectedIDs == [model.rows[1].id])
    #expect(panel.currentItem?.previewItemURL != originalURL(fixture, 1))
    #expect(panel.shownPixelSize == library, "paging: a placeholder, not the thumbnail")

    for _ in 0..<100 where panel.currentItem?.previewItemURL != originalURL(fixture, 1) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(panel.currentItem?.previewItemURL == originalURL(fixture, 1))
    #expect(panel.shownPixelSize == library, "the landed original keeps the size")
    let written = try FileManager.default.contentsOfDirectory(atPath: fixture.placeholders.path)
    #expect(!written.isEmpty)

    model.toggleQuickLookFromCommand()
    for _ in 0..<100 where panel.isVisible { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!panel.isVisible)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.placeholders.path) == [])
  }

  /// The zoom ceiling: a library size far past any screen gets a
  /// placeholder the largest screen's longer side, aspect kept.
  @Test("A placeholder for an original larger than the screen is capped to the screen")
  func placeholderIsCappedToTheScreen() async throws {
    let fixture = try await makeFixture(
      OriginalFetchProbe(), library: CGSize(width: 12000, height: 9000))
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let limit = NSScreen.screens.map { max($0.frame.width, $0.frame.height) }.max() ?? 2560

    fixture.model.select(fixture.model.rows[0])
    fixture.model.toggleQuickLookFromCommand()
    let size = try #require(fixture.panel.shownPixelSize)
    #expect(fixture.panel.currentItem?.previewItemURL?.deletingLastPathComponent() == fixture.placeholders)
    #expect(size.width == limit.rounded(), "capped: \(size) on a \(limit) pt screen")
    #expect(abs(size.width * 3 - size.height * 4) <= 4, "aspect kept: \(size)")
  }

  @Test("AspectFill shows the centred square of a 4:3 image in a 1:1 cell")
  func aspectFillVisibleRect() {
    #expect(
      AspectFill.visibleRect(image: CGSize(width: 400, height: 300), in: CGSize(width: 150, height: 150))
        == CGRect(x: 50, y: 0, width: 300, height: 300))
    #expect(
      AspectFill.visibleRect(image: CGSize(width: 256, height: 512), in: CGSize(width: 64, height: 32))
        == CGRect(x: 0, y: 192, width: 256, height: 128))
    #expect(
      AspectFill.visibleRect(image: CGSize(width: 400, height: 300), in: CGSize(width: 200, height: 150))
        == CGRect(x: 0, y: 0, width: 400, height: 300))
  }
}
