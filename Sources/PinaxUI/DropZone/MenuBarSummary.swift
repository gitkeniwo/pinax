import AppKit
import CatalogCore
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

// What the menu bar panel's home page shows, as values. The view reads
// `MenuBarSummary` and nothing else, so the tests read the same thing without
// opening a panel.

/// The image on the clipboard, as the panel's card words it.
struct ClipboardImageInfo: Equatable {
  /// "PNG", "TIFF", "JPEG"…
  let kind: String
  let width: Int?
  let height: Int?
  let byteSize: Int64

  /// "PNG · 1280 × 720 · 482 KB".
  var detailLine: String {
    [kind, PinaxFormat.dimensions(width: width, height: height), PinaxFormat.fileSize(byteSize)]
      .compactMap { $0 }
      .joined(separator: " · ")
  }
}

/// The probe's result: the info plus a small thumbnail for the card.
struct ClipboardImage {
  let info: ClipboardImageInfo
  let thumbnail: CGImage?
}

enum ClipboardImageProbe {
  static let thumbnailPixels = 96

  /// The image "Upload from Clipboard" would upload, read without decoding
  /// it: an image file URL first, otherwise PNG then TIFF data (the same
  /// order as `PasteboardUploads.collectImageFiles`). nil = no card.
  /// Pasteboard reads round-trip to the pasteboard server — call off main.
  static func probe(_ pasteboard: NSPasteboard) -> ClipboardImage? {
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    {
      for url in urls {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
          let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { continue }
        return image(from: data, kind: (type.preferredFilenameExtension ?? url.pathExtension))
      }
    }
    for (type, kind) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
      if let data = pasteboard.data(forType: type), let found = image(from: data, kind: kind) {
        return found
      }
    }
    return nil
  }

  private static func image(from data: Data, kind: String) -> ClipboardImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let properties =
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let thumbnail = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels * 2,
      ] as CFDictionary)
    return ClipboardImage(
      info: ClipboardImageInfo(
        kind: kind.uppercased(),
        width: properties[kCGImagePropertyPixelWidth] as? Int,
        height: properties[kCGImagePropertyPixelHeight] as? Int,
        byteSize: Int64(data.count)),
      thumbnail: thumbnail)
  }
}

/// The home page's content.
struct MenuBarSummary: Equatable {
  enum Footer: Equatable {
    case dropZoneWhileDragging, showDropZone, divider, quit
  }

  /// Nothing to upload to yet: "No backend", the dashed box, only Quit.
  let isFirstRun: Bool
  let clipboard: ClipboardImageInfo?
  let recent: [RecentUpload]
  /// "Uploading 2 of 5 · Show Drop Zone ›", only while the drop zone's
  /// panel is not already showing the uploads.
  let uploadingLine: String?

  init(
    hasBackend: Bool, clipboard: ClipboardImageInfo?, recent: [RecentUpload],
    uploadCounts: UploadCounts?, dropZonePanelVisible: Bool
  ) {
    isFirstRun = !hasBackend
    self.recent = hasBackend ? recent : []
    self.clipboard = hasBackend ? clipboard : nil
    if hasBackend, let counts = uploadCounts, !dropZonePanelVisible {
      uploadingLine = "Uploading \(min(counts.completed + 1, counts.total)) of \(counts.total)"
    } else {
      uploadingLine = nil
    }
  }

  /// What the app installs: the panel reads the app model through this.
  /// A backends list that has not loaded yet counts as configured, so the
  /// first-run state never flashes.
  @MainActor
  init(app: PinaxAppModel, clipboard: ClipboardImageInfo?) {
    let zone = app.dropZone?.model
    self.init(
      hasBackend: app.backends?.rows.map { !$0.isEmpty } ?? true,
      clipboard: clipboard,
      recent: app.recentUploads,
      uploadCounts: zone?.uploadCounts,
      dropZonePanelVisible: zone?.isWindowVisible ?? false)
  }

  var footer: [Footer] {
    isFirstRun
      ? [.quit] : [.dropZoneWhileDragging, .showDropZone, .divider, .quit]
  }
}

/// The panel's own state: the clipboard probe and the copy feedback.
@MainActor
final class MenuBarPanelModel: ObservableObject {
  struct Copied: Equatable {
    let uploadID: Int64
    let filename: String
    let message: String
  }

  /// How long "✓ Link copied" stays on the cell.
  static let feedbackSeconds: TimeInterval = 1.5

  @Published private(set) var clipboard: ClipboardImage?
  @Published private(set) var copied: Copied?
  /// The Library page's own Day / Week / Month: set from the card's
  /// setting each time the page opens, never written back.
  @Published var libraryUnit = MenuBarChartUnit.default.libraryUnit

  private let pasteboard: NSPasteboard
  private let notificationCenter: NotificationCenter
  /// The window the panel is drawn in, once the view is in one.
  private weak var window: AnyObject?
  private var keyObserver: AnyCancellable?
  private let copier: ((String) -> Void)?
  /// Runs `action` after the delay; production sleeps, tests hold it.
  private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
  private var feedbackGeneration = 0

  init(
    pasteboard: NSPasteboard = .general,
    notificationCenter: NotificationCenter = .default,
    copier: ((String) -> Void)? = nil,
    schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(delay))
        action()
      }
    }
  ) {
    self.pasteboard = pasteboard
    self.notificationCenter = notificationCenter
    self.copier = copier
    self.schedule = schedule
  }

  /// The panel's refresh point: each time the panel's own
  /// window becomes key — the panel opened — and no other window's. The
  /// view hands its window over once it is in one.
  /// Closes the panel and clears the status item's pressed look, before a
  /// ⌘D / ⌘, jump to another window.
  func dismiss() {
    // Closing the window alone leaves the status item pressed; clicking the
    // status button toggles the MenuBarExtra shut the way the user would.
    let button = NSApp.windows
      .filter { $0.className.contains("NSStatusBarWindow") }
      .compactMap { $0.contentView.flatMap(Self.statusButton(in:)) }
      .first
    if let button, (window as? NSWindow)?.isVisible == true {
      button.performClick(nil)
    } else {
      (window as? NSWindow)?.close()
    }
  }

  private static func statusButton(in view: NSView) -> NSStatusBarButton? {
    if let button = view as? NSStatusBarButton { return button }
    for sub in view.subviews { if let b = statusButton(in: sub) { return b } }
    return nil
  }

  func attach(window: AnyObject, app: PinaxAppModel) {
    guard window !== self.window else { return }
    self.window = window
    keyObserver = notificationCenter
      .publisher(for: NSWindow.didBecomeKeyNotification, object: window)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak app] _ in
        guard let self, let app else { return }
        Task { await self.panelOpened(app: app) }
      }
    if (window as? NSWindow)?.isKeyWindow == true {
      Task { await panelOpened(app: app) }
    }
  }

  /// The panel opened: opening it is looking at the failures, and
  /// the clipboard, RECENT and the Library numbers are read again.
  func panelOpened(app: PinaxAppModel) async {
    app.menuBarActivity.markFailuresSeen()
    await refreshClipboard()
    await app.refreshRecentUploads()
    await app.backends?.load()
  }

  /// The card opened the Library page: it starts on the card's unit, Year
  /// as Month.
  func openLibrary(preferences: PreferencesStore) {
    libraryUnit = preferences.menuBarChartUnit.libraryUnit
  }

  /// Probes the pasteboard once, off the main thread (the panel just opened).
  func refreshClipboard() async {
    let pasteboard = pasteboard
    clipboard = await Task.detached(priority: .userInitiated) {
      ClipboardImageProbe.probe(pasteboard)
    }.value
  }

  func copyLink(_ upload: RecentUpload) {
    copy(upload.url, of: upload, message: "✓ Link copied")
  }

  func copyMarkdown(_ upload: RecentUpload) {
    let fields = CopyFields(
      url: upload.url, filename: upload.filename, width: nil, height: nil, key: "", projects: [])
    copy(
      CopyTemplate.render(CopyFormat.markdown.template, fields: fields), of: upload,
      message: "✓ Markdown copied")
  }

  private func copy(_ string: String, of upload: RecentUpload, message: String) {
    if let copier { copier(string) } else { Clipboard.copy(string) }
    feedbackGeneration += 1
    let generation = feedbackGeneration
    copied = Copied(uploadID: upload.id, filename: upload.filename, message: message)
    schedule(Self.feedbackSeconds) { [weak self] in
      guard let self, self.feedbackGeneration == generation else { return }
      self.copied = nil
    }
  }
}
