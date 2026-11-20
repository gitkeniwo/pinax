import AppKit
import CatalogCore
import Foundation
import ImageIO
@preconcurrency import QuickLookUI
import UniformTypeIdentifiers

@MainActor
public final class QuickLookLoadCoordinator {
  public enum Result {
    case original(URL)
    case failed(Error)
  }

  private let cache: OriginalImageCache
  private var task: Task<Void, Never>?

  public init(cache: OriginalImageCache) {
    self.cache = cache
  }

  public func select(
    _ request: OriginalImageRequest,
    delay: Duration = .zero,
    completion: @escaping @MainActor (Result) -> Void
  ) {
    cancel()
    let cache = self.cache
    task = Task {
      do {
        if delay > .zero { try await Task.sleep(for: delay) }
        let url = try await cache.file(for: request)
        try Task.checkCancellation()
        completion(.original(url))
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        completion(.failed(error))
      }
    }
  }

  public func cancel() {
    task?.cancel()
    task = nil
  }
}

private final class PinaxPreviewItem: NSObject, QLPreviewItem {
  let previewItemURL: URL!
  let previewItemTitle: String!

  init(url: URL?, title: String) {
    self.previewItemURL = url
    self.previewItemTitle = title
  }
}

/// The slice of `QLPreviewPanel` the controller drives, so tests can stand a
/// panel in without the shared window. Its `currentPreviewItemIndex` must be
/// key-value observable: the panel moves it itself on ← → and ◀ ▶.
/// Measured on the real panel: `close()` asks the
/// delegate for the source frame and transition image before it returns,
/// and sends the delegate `windowWillClose` a run-loop turn later.
@MainActor
protocol QuickLookPanel: NSObject {
  var isVisible: Bool { get }
  var currentPreviewItemIndex: Int { get set }
  func attach(_ controller: QuickLookController?)
  func reloadData()
  func refreshCurrentPreviewItem()
  func makeKeyAndOrderFront(_ sender: Any?)
  func close()
}

extension QLPreviewPanel: QuickLookPanel {
  func attach(_ controller: QuickLookController?) {
    dataSource = controller
    delegate = controller
  }
}

/// Where the gallery's rows answer the panel.
@MainActor
protocol QuickLookNavigator: AnyObject {
  /// A key the panel handed over: the grid's own keyboard entry.
  func quickLookMove(_ move: GalleryModel.GridMove)
  /// Space in the panel: the same path as View ▸ Quick Look.
  func quickLookToggle()
  /// The panel moved itself (◀ ▶, ← →) to the entry with this id.
  func quickLookDidMove(to id: Int64)
  /// The shown original failed (a sentence for the status bar), or nil.
  func quickLookError(_ message: String?)
}

/// Owns the app's one Quick Look panel. Gallery originals use the remote
/// pipeline; drop-zone cards call `toggleLocal` and never enter that pipeline.
///
/// Remote mode shows the gallery's loaded rows: the panel gets
/// its own ◀ ▶ and counter, and `currentPreviewItemIndex` is the selected
/// row. An entry is its original once that has landed, otherwise its
/// thumbnail file, titled so it never passes for the original.
/// Only the current entry is ever downloaded. An entry whose original has
/// not landed is shown as a placeholder the original's size, so
/// the panel keeps its size when the original arrives.
@MainActor
public final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
  @preconcurrency QLPreviewPanelDelegate
{
  private let thumbnails: ThumbnailCache
  private let loader: QuickLookLoadCoordinator
  private let originalsCache: OriginalImageCache
  private let placeholderDirectory: URL
  private let makePanel: () -> QuickLookPanel?
  private var panel: QuickLookPanel?
  private var localItem: PinaxPreviewItem?
  private var entries: [CatalogAssetItem] = []
  private var currentIndex = 0
  /// Originals that landed while the panel was open, by sha256.
  private var originals: [String: URL] = [:]
  private var failures: Set<String> = []
  /// Placeholders written while the panel was open, by sha256.
  private var placeholders: [String: URL] = [:]
  private var remoteRequest: OriginalImageRequest?
  /// Our own writes to the panel; the index notifications they cause are
  /// not the user's.
  private var updatingPanel = false
  private var transitionSHA256: String?
  private var transitionImage: NSImage?
  private var transitionAnchors: [String: Anchor] = [:]
  weak var navigator: QuickLookNavigator?

  public convenience init(
    thumbnails: ThumbnailCache, originals: OriginalImageCache = OriginalImageCache()
  ) {
    self.init(thumbnails: thumbnails, originals: originals, panel: { QLPreviewPanel.shared() })
  }

  init(
    thumbnails: ThumbnailCache, originals: OriginalImageCache,
    placeholderDirectory: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-quick-look-placeholders", isDirectory: true),
    panel: @escaping () -> QuickLookPanel?
  ) {
    self.thumbnails = thumbnails
    self.loader = QuickLookLoadCoordinator(cache: originals)
    self.originalsCache = originals
    self.placeholderDirectory = placeholderDirectory
    self.makePanel = panel
    super.init()
  }

  public var isVisible: Bool { panel?.isVisible == true }

  /// A permanently deleted image: the original this
  /// panel fetched leaves the cache.
  public func forgetOriginal(sha256: String) async {
    originals[sha256] = nil
    await originalsCache.forget(sha256: sha256)
  }

  /// The view the panel zooms from and back into for `sha256`, and how the
  /// cell draws the thumbnail inside it.
  public func registerTransitionAnchor(
    _ view: NSView, for sha256: String, sizing: GridThumbnailSizing
  ) {
    transitionAnchors = transitionAnchors.filter { $0.value.view != nil }
    transitionAnchors[sha256] = Anchor(view, sizing: sizing)
  }

  /// Opens the panel on `entries[index]`, or closes it when it is open.
  /// Closing keeps the delegate until `windowWillClose`, so the panel can
  /// zoom back into the cell.
  public func toggleRemote(_ entries: [CatalogAssetItem], at index: Int) {
    if isVisible {
      panel?.close()
    } else {
      showRemote(entries, at: index, delay: .zero)
    }
  }

  /// Opens the panel on `entries[index]`, or moves it there when it is
  /// already open — a cell's double-click opens, it never closes.
  public func openRemote(_ entries: [CatalogAssetItem], at index: Int) {
    showRemote(entries, at: index, delay: .zero)
  }

  /// The gallery's selection moved: follow it, or close on no single row.
  public func selectionDidChange(to entries: [CatalogAssetItem], at index: Int?) {
    guard isVisible, isRemote else { return }
    guard let index else {
      panel?.close()
      return
    }
    showRemote(entries, at: index, delay: .milliseconds(180))
  }

  /// An Externals reference — no catalog row, no thumbnail —
  /// shown as its original, fetched only now, through the originals cache;
  /// closes the panel when it is open.
  public func toggleExternal(_ request: OriginalImageRequest) {
    if isVisible {
      panel?.close()
      return
    }
    navigator?.quickLookError(nil)
    loader.select(request) { [weak self] result in
      switch result {
      case .original(let url):
        self?.toggleLocal(url)
      case .failed(let error):
        self?.navigator?.quickLookError(
          "Could not load the image: \(UserFacingErrorMessage.resolve(error))")
      }
    }
  }

  public func toggleLocal(_ url: URL) {
    loader.cancel()
    remoteRequest = nil
    entries = []
    transitionSHA256 = nil
    transitionImage = nil
    if isVisible, localItem?.previewItemURL == url {
      panel?.close()
      return
    }
    localItem = PinaxPreviewItem(url: url, title: url.lastPathComponent)
    currentIndex = 0
    present()
  }

  public static func textInputHasFocus(in window: NSWindow?) -> Bool {
    guard let responder = window?.firstResponder else { return false }
    return responder is NSTextView || responder is NSTextField
  }

  public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    if localItem != nil { return 1 }
    return entries.count
  }

  public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    if let localItem { return localItem }
    guard entries.indices.contains(index) else { return nil }
    return previewItem(for: entries[index], isCurrent: index == currentIndex)
  }

  /// Arrow keys go to the grid's keyboard navigation and space to View ▸
  /// Quick Look. Measured on the real panel with several items:
  /// it takes ← → (moving its own index, see `observeValue`) and space
  /// (closing) without asking; ↑ ↓ and the rest arrive here.
  public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    guard isRemote, let navigator, let event, event.type == .keyDown else {
      return false
    }
    let move: GalleryModel.GridMove
    switch event.specialKey {
    case .leftArrow?: move = .left
    case .rightArrow?: move = .right
    case .upArrow?: move = .up
    case .downArrow?: move = .down
    case .home?: move = .home
    case .end?: move = .end
    default:
      guard event.charactersIgnoringModifiers == " " else { return false }
      navigator.quickLookToggle()
      return true
    }
    navigator.quickLookMove(move)
    return true
  }

  /// The panel's own close (`close()`, space, its close button): the
  /// delegate is let go only here, after the panel asked for the frame to
  /// zoom back into. `QLPreviewPanelDelegate` has no will-close of its own;
  /// the real panel sends its delegate this `NSWindowDelegate` call
  /// (measured).
  public func windowWillClose(_ notification: Notification) {
    close()
  }

  public func previewPanel(
    _ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!
  ) -> NSRect {
    guard let view = transitionAnchor?.view, let window = view.window else { return .zero }
    return window.convertToScreen(view.convert(view.bounds, to: nil))
  }

  public func previewPanel(
    _ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
    contentRect: UnsafeMutablePointer<NSRect>!
  ) -> Any! {
    guard let transitionImage else { return nil }
    // A filled cell shows only the middle of the thumbnail.
    let whole = NSRect(origin: .zero, size: transitionImage.size)
    if let anchor = transitionAnchor, anchor.sizing == .fillGrid, let view = anchor.view {
      contentRect?.pointee = AspectFill.visibleRect(
        image: transitionImage.size, in: view.bounds.size)
    } else {
      contentRect?.pointee = whole
    }
    return transitionImage
  }

  private var transitionAnchor: Anchor? {
    transitionSHA256.flatMap { transitionAnchors[$0] }
  }

  /// The panel moved itself (◀ ▶, ← →): hand the new entry to the gallery,
  /// whose selection change comes back through `selectionDidChange`.
  nonisolated override public func observeValue(
    forKeyPath keyPath: String?, of object: Any?,
    change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
  ) {
    guard context == &Self.indexContext else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }
    MainActor.assumeIsolated {
      guard !updatingPanel, isRemote, let panel,
        entries.indices.contains(panel.currentPreviewItemIndex),
        panel.currentPreviewItemIndex != currentIndex,
        let id = entries[panel.currentPreviewItemIndex].asset.id
      else { return }
      navigator?.quickLookDidMove(to: id)
    }
  }

  nonisolated(unsafe) private static var indexContext = 0

  private var isRemote: Bool { localItem == nil && !entries.isEmpty }

  private static func filename(_ item: CatalogAssetItem) -> String {
    item.asset.originalFilename ?? (item.asset.key as NSString).lastPathComponent
  }

  private func thumbnailURL(_ item: CatalogAssetItem) -> URL? {
    guard let sourceURL = URL(string: item.url) else { return nil }
    return thumbnails.previewFileURL(
      for: ThumbnailRequest(sha256: item.asset.sha256, sourceURL: sourceURL))
  }

  private static func originalRequest(_ item: CatalogAssetItem) -> OriginalImageRequest? {
    URL(string: item.url).map {
      OriginalImageRequest(sha256: item.asset.sha256, sourceURL: $0, filename: filename(item))
    }
  }

  /// The original when it is already in the disk cache (open
  /// straight on it). Only looks; `QuickLookLoadCoordinator` still reads it
  /// through the cache, which keeps its LRU order.
  private func cachedOriginal(_ item: CatalogAssetItem) -> URL? {
    guard let request = Self.originalRequest(item) else { return nil }
    let url = originalsCache.fileURL(for: request)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  private func previewItem(for item: CatalogAssetItem, isCurrent: Bool) -> PinaxPreviewItem {
    let filename = Self.filename(item)
    if let original = originals[item.asset.sha256] ?? cachedOriginal(item) {
      return PinaxPreviewItem(url: original, title: filename)
    }
    let state =
      failures.contains(item.asset.sha256)
      ? "original unavailable"
      : isCurrent ? "loading original…" : "thumbnail"
    return PinaxPreviewItem(
      url: placeholderURL(item) ?? thumbnailURL(item), title: "\(filename) — \(state)")
  }

  /// The thumbnail drawn up to the library's `width × height` (capped to the
  /// largest screen, aspect kept) and visibly soft, so the
  /// panel opens — and pages — at the original's size and the original
  /// only sharpens it. Not an `OriginalImageCache` entry; deleted on close.
  /// Nil without a library size or a thumbnail file: the thumbnail is shown.
  private func placeholderURL(_ item: CatalogAssetItem) -> URL? {
    let sha256 = item.asset.sha256
    if let url = placeholders[sha256] { return url }
    guard let width = item.asset.width, let height = item.asset.height, width > 0, height > 0,
      let thumbnailURL = thumbnailURL(item),
      let thumbnail = ThumbnailCache.decode(thumbnailURL)
    else { return nil }
    let limit = NSScreen.screens.map { max($0.frame.width, $0.frame.height) }.max() ?? 2560
    let scale = min(1, limit / CGFloat(max(width, height)))
    let size = CGSize(
      width: max(1, (CGFloat(width) * scale).rounded()),
      height: max(1, (CGFloat(height) * scale).rounded()))
    // Through a tiny copy first: an upscaled 512 px thumbnail can pass for
    // the original, a 64 px one cannot.
    let tinyScale = min(1, 64 / max(size.width, size.height))
    guard
      let tiny = Self.draw(
        thumbnail,
        size: CGSize(
          width: max(1, (size.width * tinyScale).rounded()),
          height: max(1, (size.height * tinyScale).rounded()))),
      let image = Self.draw(tiny, size: size)
    else { return nil }
    let url = placeholderDirectory.appendingPathComponent("\(sha256).png")
    try? FileManager.default.createDirectory(
      at: placeholderDirectory, withIntermediateDirectories: true)
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    placeholders[sha256] = url
    return url
  }

  private static func draw(_ image: CGImage, size: CGSize) -> CGImage? {
    guard
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: size))
    return context.makeImage()
  }

  private func showRemote(_ newEntries: [CatalogAssetItem], at index: Int, delay: Duration) {
    guard newEntries.indices.contains(index) else { return }
    let catalogItem = newEntries[index]
    let entriesChanged =
      newEntries.map(\.asset.sha256) != entries.map(\.asset.sha256) || localItem != nil
    localItem = nil
    entries = newEntries
    currentIndex = index
    transitionSHA256 = catalogItem.asset.sha256
    transitionImage = thumbnailURL(catalogItem).flatMap(NSImage.init(contentsOf:))

    let sha256 = catalogItem.asset.sha256
    guard let request = Self.originalRequest(catalogItem) else {
      remoteRequest = nil
      fail(sha256, "The original image URL is invalid.")
      return
    }
    remoteRequest = request
    navigator?.quickLookError(nil)
    present(reload: entriesChanged)

    guard originals[sha256] == nil else {
      loader.cancel()
      return
    }
    failures.remove(sha256)
    loader.select(request, delay: delay) { [weak self] result in
      guard let self, self.remoteRequest == request else { return }
      switch result {
      case .original(let url):
        self.originals[sha256] = url
        self.present()
      case .failed(let error):
        self.fail(sha256, "Could not load the original image: \(error.localizedDescription)")
      }
    }
  }

  /// The thumbnail stays; the title says the original is unavailable and the
  /// sentence goes to the status bar until the panel closes.
  private func fail(_ sha256: String, _ message: String) {
    loader.cancel()
    failures.insert(sha256)
    navigator?.quickLookError(message)
    present()
  }

  /// An entry whose file or title changed needs `reload`: the panel asks
  /// the data source again only on `reloadData` (keeping its index) and on
  /// an index move — `refreshCurrentPreviewItem` re-renders the item it
  /// already holds (measured on the real panel).
  private func present(reload: Bool = true) {
    let opening = panel == nil
    guard let previewPanel = panel ?? makePanel() else { return }
    updatingPanel = true
    defer { updatingPanel = false }
    if opening {
      panel = previewPanel
      previewPanel.attach(self)
      previewPanel.addObserver(
        self, forKeyPath: "currentPreviewItemIndex", options: [], context: &Self.indexContext)
    }
    if opening || reload { previewPanel.reloadData() }
    if previewPanel.currentPreviewItemIndex != currentIndex {
      previewPanel.currentPreviewItemIndex = currentIndex
    }
    previewPanel.refreshCurrentPreviewItem()
    if !previewPanel.isVisible { previewPanel.makeKeyAndOrderFront(nil) }
  }

  private func close() {
    loader.cancel()
    remoteRequest = nil
    transitionSHA256 = nil
    transitionImage = nil
    localItem = nil
    entries = []
    originals = [:]
    failures = []
    for url in placeholders.values { try? FileManager.default.removeItem(at: url) }
    placeholders = [:]
    // The sentence is in the panel's title too; it goes with the panel.
    navigator?.quickLookError(nil)
    guard let panel else { return }
    panel.removeObserver(self, forKeyPath: "currentPreviewItemIndex", context: &Self.indexContext)
    panel.attach(nil)
    self.panel = nil
  }
}

private final class Anchor {
  weak var view: NSView?
  let sizing: GridThumbnailSizing

  init(_ view: NSView, sizing: GridThumbnailSizing) {
    self.view = view
    self.sizing = sizing
  }
}
