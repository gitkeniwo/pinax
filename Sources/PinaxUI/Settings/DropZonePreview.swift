import AppKit
import CatalogCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private typealias Metrics = DesignMetrics.settings

/// The preview's four states, chosen under it. Lives in the page only.
enum DropZonePreviewStage: CaseIterable, Hashable {
  case empty, dragging, review, results

  var label: String {
    switch self {
    case .empty: "Empty"
    case .dragging: "Dragging"
    case .review: "Review"
    case .results: "Results"
    }
  }
}

/// Every sample the preview shows, in one place: the pictures (drawn in
/// code, no words, no photos), and the cards each state is made of. The
/// cards are built afresh for each showing, never kept, so a state can be
/// shown again from the start.
enum DropZonePreviewSamples {
  /// The pictures: Results' six in card order, then Review's two more.
  enum Picture: String, CaseIterable {
    case forest = "IMG_2817"
    case sunset = "hero-sunset"
    case pier = "pier-dawn"
    case map = "trail-map"
    case cover = "cover-2024"
    case photo = "IMG_2041"
    case banner = "banner-wide"
    case screenshot = "screenshot-0412"

    var pixelSize: (width: Int, height: Int) {
      switch self {
      case .forest: (320, 213)
      case .sunset: (320, 240)
      case .pier: (320, 213)
      case .map: (320, 200)
      case .cover: (320, 168)
      case .photo: (240, 320)
      case .banner: (320, 80)
      case .screenshot: (320, 200)
      }
    }
  }

  /// The pictures as files the drag's photo stack reads, and as images
  /// for the cards' thumbnails.
  struct Pictures {
    let urls: [Picture: URL]
    let images: [Picture: CGImage]
  }

  static let failureMessage = "The network connection was lost."

  /// Where the pictures are written; the preview's own caches live under
  /// it too.
  static var defaultDirectory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PinaxDropZonePreview", isDirectory: true)
  }

  /// Draws the pictures and writes each as a PNG in `directory`,
  /// leaving a file that is already there as it is.
  static func pictures(in directory: URL) -> Pictures {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var urls: [Picture: URL] = [:]
    var images: [Picture: CGImage] = [:]
    for picture in Picture.allCases {
      let url = directory.appendingPathComponent(picture.rawValue).appendingPathExtension("png")
      urls[picture] = url
      guard let image = draw(picture) else { continue }
      images[picture] = image
      if !FileManager.default.fileExists(atPath: url.path) { writePNG(image, to: url) }
    }
    return Pictures(urls: urls, images: images)
  }

  /// The cards a state shows, newest first, all into `projectSlug`. A
  /// fresh landing counts from `now`.
  static func cards(
    for stage: DropZonePreviewStage, pictures: Pictures, projectSlug: String?, now: Date
  ) -> [DropZoneModel.UploadCard] {
    guard stage != .empty else { return [] }
    func card(
      _ filename: String, _ picture: Picture, _ phase: DropZoneModel.UploadCard.Phase,
      landedAt: Date? = nil, compression: CardCompression? = nil, prepared: PreparedDrop? = nil
    ) -> DropZoneModel.UploadCard {
      DropZoneModel.UploadCard(
        filename: filename,
        fileURL: pictures.urls[picture] ?? URL(fileURLWithPath: filename),
        phase: phase, thumbnail: pictures.images[picture], landedAt: landedAt,
        projectSlug: projectSlug, compression: compression, prepared: prepared)
    }
    if stage == .review {
      // Held for review: two copies on, one set back to its original, one
      // with no copy worth sending.
      func reviewed(
        _ filename: String, _ picture: Picture, useOriginal: Bool, copy: CardCompression?,
        original: (bytes: Int64, width: Int, height: Int)? = nil
      ) -> DropZoneModel.UploadCard {
        let prepared = PreparedDrop(
          fileURL: pictures.urls[picture] ?? URL(fileURLWithPath: filename),
          projectSlug: projectSlug, compression: copy, sourceByteSize: original?.bytes,
          sourceWidth: original?.width, sourceHeight: original?.height,
          compressesByDefault: true, originalReason: copy == nil ? .notSmaller : nil)
        return card(
          filename, picture, .review(useOriginal: useOriginal), compression: copy,
          prepared: prepared)
      }
      return [
        reviewed(
          "IMG_2817.jpg", .forest, useOriginal: false,
          copy: compression(from: 4_600_000, 6000, 4000, to: 336_000, 2048, 1365)),
        reviewed(
          "IMG_2041.heic", .photo, useOriginal: false,
          copy: compression(
            from: 3_100_000, 4032, 3024, to: 412_000, 2048, 1536, sourceMime: "image/heic")),
        reviewed(
          "banner-wide.jpg", .banner, useOriginal: true,
          copy: compression(from: 640_000, 1920, 480, to: 188_000, 1920, 480)),
        reviewed(
          "screenshot-0412.png", .screenshot, useOriginal: true, copy: nil,
          original: (412_000, 2880, 1800)),
      ]
    }
    return [
      card("IMG_2817.jpg", .forest, .compressing),
      card(
        "hero-sunset.jpg", .sunset, .uploading,
        compression: compression(from: 4_100_000, 4032, 3024, to: 298_000, 2048, 1536)),
      card(
        "pier-dawn.jpg", .pier,
        .done(
          outcome(
            "pier-dawn.jpg", mime: "image/jpeg", bytes: 342_000, width: 2048, height: 1365,
            deduplicated: false, now: now)),
        landedAt: now,
        compression: compression(from: 3_800_000, 6000, 4000, to: 342_000, 2048, 1365)),
      card(
        "trail-map.png", .map,
        .done(
          outcome(
            "trail-map.png", mime: "image/png", bytes: 284_000, width: 1600, height: 1000,
            deduplicated: false, now: now)),
        landedAt: now),
      card(
        "cover-2024.webp", .cover,
        .done(
          outcome(
            "cover-2024.webp", mime: "image/webp", bytes: 96_000, width: 1200, height: 630,
            deduplicated: true, now: now))),
      card("IMG_2041.heic", .photo, .failed(failureMessage)),
    ]
  }

  /// The replay's batch as it arrives: a photo whose copy is smaller, a
  /// PNG sent as it was, and one the library already has.
  static func replayCards(pictures: Pictures, projectSlug: String?) -> [DropZoneModel.UploadCard] {
    [(Picture.forest, "IMG_2817.jpg"), (.map, "trail-map.png"), (.cover, "cover-2024.webp")]
      .map { picture, filename in
        DropZoneModel.UploadCard(
          filename: filename, fileURL: pictures.urls[picture] ?? URL(fileURLWithPath: filename),
          phase: .waiting, thumbnail: pictures.images[picture], projectSlug: projectSlug)
      }
  }

  /// The replay's cards at `step`, the same cards (same identities) with
  /// their phase moved on.
  static func replay(
    _ cards: [DropZoneModel.UploadCard], at step: DropZonePreviewController.ReplayStep, now: Date
  ) -> [DropZoneModel.UploadCard] {
    let copy = compression(from: 4_600_000, 6000, 4000, to: 336_000, 2048, 1365)
    return cards.enumerated().map { index, card in
      var card = card
      switch step {
      case .inserted:
        card.phase = .waiting
      case .compressing:
        card.phase = .compressing
      case .uploading:
        card.phase = .uploading
        card.compression = index == 0 ? copy : nil
      case .done:
        switch index {
        case 0:
          card.phase = .done(
            outcome(
              card.filename, mime: "image/jpeg", bytes: copy.byteSize, width: 2048,
              height: 1365, deduplicated: false, now: now))
          card.landedAt = now
        case 1:
          card.phase = .done(
            outcome(
              card.filename, mime: "image/png", bytes: 284_000, width: 1600, height: 1000,
              deduplicated: false, now: now))
          card.landedAt = now
        default:
          card.phase = .done(
            outcome(
              card.filename, mime: "image/webp", bytes: 96_000, width: 1200, height: 630,
              deduplicated: true, now: now))
        }
      }
      return card
    }
  }

  /// A JPEG (unless `sourceMime` says otherwise) recompressed with the
  /// default options.
  private static func compression(
    from sourceBytes: Int64, _ sourceWidth: Int, _ sourceHeight: Int,
    to bytes: Int64, _ width: Int, _ height: Int, sourceMime: String = "image/jpeg"
  ) -> CardCompression {
    CardCompression(
      sourceByteSize: sourceBytes, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
      sourceMime: sourceMime, byteSize: bytes, width: width, height: height,
      mime: "image/jpeg", options: .default)
  }

  /// Dragging shows three images over the results.
  static func draggedFileURLs(for stage: DropZonePreviewStage, pictures: Pictures) -> [URL] {
    guard stage == .dragging else { return [] }
    return [Picture.sunset, .map, .cover].compactMap { pictures.urls[$0] }
  }

  /// The project the header and the cards name: Upload into as the app
  /// resolves it when the panel shows (Current Project is the app's
  /// current project; a fixed project that is gone is Current Project).
  static func projectSlug(
    uploadInto: DropZoneUploadInto, currentProjectSlug: String?, projects: [Project]
  ) -> String? {
    let slugs = projects.map(\.slug)
    switch uploadInto.resolved(projects: slugs) {
    case .currentProject: return currentProjectSlug.flatMap { slugs.contains($0) ? $0 : nil }
    case .noProject: return nil
    case .project(let slug): return slug
    }
  }

  private static func outcome(
    _ filename: String, mime: String, bytes: Int64, width: Int, height: Int,
    deduplicated: Bool, now: Date
  ) -> UploadOutcome {
    UploadOutcome(
      sha256: String(repeating: "0", count: 64), key: filename,
      url: "https://images.example.com/\(filename)", mime: mime, originalFilename: filename,
      byteSize: bytes, width: width, height: height,
      uploadedAt: ISO8601DateFormatter().string(from: now), deduplicated: deduplicated,
      dryRun: false)
  }

  // MARK: Drawing

  /// Gradients and simple shapes: a wooded hillside, sunset orange and
  /// pink, a pier at dawn, a green-blue map, a purple cover, a grey-brown
  /// photo.
  static func draw(_ picture: Picture) -> CGImage? {
    let (width, height) = picture.pixelSize
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let w = CGFloat(width)
    let h = CGFloat(height)
    func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
      CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    func wash(_ colors: [Int], from start: CGPoint, to end: CGPoint) {
      let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map { rgb($0) } as CFArray,
        locations: nil)!
      context.drawLinearGradient(gradient, start: start, end: end, options: [])
    }
    // CoreGraphics is bottom-up: y = h is the top.
    switch picture {
    case .forest:
      wash([0x9fc3d9, 0xd6e4e8], from: CGPoint(x: 0, y: h), to: CGPoint(x: 0, y: h * 0.5))
      context.setFillColor(rgb(0x6a9457))
      context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.57))
      context.setFillColor(rgb(0x3b6232, 0.85))
      for x in [0.05, 0.28, 0.55, 0.78] {
        context.fillEllipse(in: CGRect(x: w * x, y: -h * 0.1, width: w * 0.22, height: h * 0.62))
      }
    case .pier:
      wash([0x7f9cc4, 0xe8b9a6, 0x5f7894], from: CGPoint(x: 0, y: h), to: .zero)
      context.setFillColor(rgb(0x2f3a4a, 0.85))
      context.fill(CGRect(x: 0, y: h * 0.34, width: w * 0.72, height: h * 0.05))
      for x in [0.1, 0.3, 0.5, 0.68] {
        context.fill(CGRect(x: w * x, y: h * 0.12, width: w * 0.025, height: h * 0.24))
      }
    case .sunset:
      wash([0xff7a59, 0xff9a6b, 0xf2678e, 0x8e4a8c], from: CGPoint(x: 0, y: h), to: .zero)
      context.setFillColor(rgb(0xffe2a8, 0.95))
      context.fillEllipse(in: CGRect(x: w * 0.36, y: h * 0.30, width: w * 0.28, height: w * 0.28))
      context.setFillColor(rgb(0x4a2d5c, 0.85))
      context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.34))
    case .map:
      wash([0x7cc6a4, 0x4fa3b8, 0x3b6fb0], from: CGPoint(x: 0, y: h), to: CGPoint(x: w, y: 0))
      context.setStrokeColor(rgb(0xffffff, 0.7))
      context.setLineWidth(5)
      context.setLineCap(.round)
      context.move(to: CGPoint(x: w * 0.08, y: h * 0.2))
      context.addCurve(
        to: CGPoint(x: w * 0.92, y: h * 0.78), control1: CGPoint(x: w * 0.45, y: h * 0.05),
        control2: CGPoint(x: w * 0.5, y: h * 0.95))
      context.strokePath()
      context.setFillColor(rgb(0xf6f1d8, 0.9))
      context.fillEllipse(in: CGRect(x: w * 0.86, y: h * 0.71, width: 18, height: 18))
    case .cover:
      wash([0x5b3fa8, 0x8a4fd1, 0xc07be8], from: CGPoint(x: 0, y: 0), to: CGPoint(x: w, y: h))
      context.setFillColor(rgb(0xffffff, 0.18))
      context.fillEllipse(in: CGRect(x: w * 0.55, y: h * 0.25, width: h * 0.9, height: h * 0.9))
      context.setFillColor(rgb(0x2a1a5e, 0.35))
      context.fillEllipse(in: CGRect(x: -h * 0.2, y: -h * 0.35, width: h * 0.9, height: h * 0.9))
    case .photo:
      wash([0xb8a48e, 0x8c7660, 0x5e4c3e], from: CGPoint(x: 0, y: h), to: .zero)
      context.setFillColor(rgb(0x3e3128, 0.55))
      context.fill(CGRect(x: w * 0.18, y: 0, width: w * 0.22, height: h * 0.58))
      context.fill(CGRect(x: w * 0.52, y: 0, width: w * 0.34, height: h * 0.42))
    case .banner:
      wash([0x2d4f86, 0x6f9fd6], from: .zero, to: CGPoint(x: w, y: 0))
      context.setFillColor(rgb(0x1f3b6b))
      context.fill(CGRect(x: 0, y: h * 0.3, width: w, height: h * 0.4))
    case .screenshot:
      context.setFillColor(rgb(0xf2f2f5))
      context.fill(CGRect(x: 0, y: 0, width: w, height: h))
      context.setFillColor(rgb(0xdcdce2))
      for row in stride(from: CGFloat(8), to: h * 0.82, by: 14) {
        context.fill(CGRect(x: w * 0.3, y: row, width: w * 0.62, height: 2))
      }
      context.setFillColor(rgb(0x2b2b30))
      context.fill(CGRect(x: 0, y: 0, width: w * 0.26, height: h * 0.82))
      context.setFillColor(rgb(0x3a3a40))
      context.fill(CGRect(x: 0, y: h * 0.82, width: w, height: h * 0.18))
    }
    return context.makeImage()
  }

  private static func writePNG(_ image: CGImage, to url: URL) {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
  }
}

/// The mini desktop's arithmetic: how much the panel shrinks to fit, where
/// it sits, what the size label says, and what a drag of the grip asks for.
enum DropZonePreviewGeometry {
  static let desktop = CGSize(
    width: Metrics.previewDesktopWidth, height: Metrics.previewDesktopHeight)

  /// The room the panel has: the desktop less the margin all round and the
  /// menu bar.
  static var available: CGSize {
    CGSize(
      width: desktop.width - 2 * Metrics.previewPanelMargin,
      height: desktop.height - Metrics.previewMenuBarHeight - 2 * Metrics.previewPanelMargin)
  }

  /// 1 when the panel fits; otherwise the even shrink that makes it fit.
  static func scale(for panel: CGSize) -> CGFloat {
    guard panel.width > 0, panel.height > 0 else { return 1 }
    return min(1, available.width / panel.width, available.height / panel.height)
  }

  /// "340 × 420 pt", with " · 62%" when shrunk.
  static func sizeLabel(for panel: CGSize) -> String {
    let base = "\(Int(panel.width.rounded())) × \(Int(panel.height.rounded())) pt"
    let scale = scale(for: panel)
    guard scale < 1 else { return base }
    return base + " · \(Int((scale * 100).rounded()))%"
  }

  /// The panel as drawn on the desktop, at its corner.
  static func panelFrame(for panel: CGSize, corner: DropZoneCorner) -> CGRect {
    let scale = scale(for: panel)
    let size = CGSize(width: panel.width * scale, height: panel.height * scale)
    let margin = Metrics.previewPanelMargin
    let left = margin
    let right = desktop.width - margin - size.width
    let top = Metrics.previewMenuBarHeight + margin
    let bottom = desktop.height - margin - size.height
    let origin: CGPoint
    switch corner {
    case .topLeft: origin = CGPoint(x: left, y: top)
    case .topRight: origin = CGPoint(x: right, y: top)
    case .bottomLeft: origin = CGPoint(x: left, y: bottom)
    case .bottomRight: origin = CGPoint(x: right, y: bottom)
    }
    return CGRect(origin: origin, size: size)
  }

  /// A grip drag: what moved on screen, in the panel's own points, added
  /// to the size the drag began at. The store clamps it.
  static func resized(from start: CGSize, by translation: CGSize, scale: CGFloat) -> CGSize {
    let scale = scale > 0 ? scale : 1
    return CGSize(
      width: (start.width + translation.width / scale).rounded(),
      height: (start.height + translation.height / scale).rounded())
  }
}

/// The preview's model and surface state, owned by the page: made when the
/// page appears, gone when it goes. Never the app's drop zone.
@MainActor
final class DropZonePreviewController: ObservableObject {
  let model: DropZoneModel
  let state = DropZoneViewState()
  @Published private(set) var stage: DropZonePreviewStage = .results
  let directory: URL
  private(set) var pictures: DropZonePreviewSamples.Pictures?

  init(
    directory: URL = DropZonePreviewSamples.defaultDirectory,
    service: (any DropZoneService)? = nil,
    urlCopier: ((String) -> Void)? = nil
  ) {
    self.directory = directory
    self.model = DropZoneModel.preview(
      directory: directory, service: service, urlCopier: urlCopier)
  }

  /// Shows `stage` from the start, choosing it again included: the cards
  /// are made anew and a fresh landing counts from `now`. The pictures are
  /// written the first time.
  func show(
    _ stage: DropZonePreviewStage, projects: [Project], projectSlug: String?, now: Date = Date()
  ) {
    stopReplay()
    self.stage = stage
    let pictures = self.pictures ?? DropZonePreviewSamples.pictures(in: directory)
    self.pictures = pictures
    model.seedPreview(
      cards: DropZonePreviewSamples.cards(
        for: stage, pictures: pictures, projectSlug: projectSlug, now: now),
      draggedFileURLs: DropZonePreviewSamples.draggedFileURLs(for: stage, pictures: pictures),
      projects: projects, selectedProjectSlug: projectSlug)
    state.isDropTargeted = stage == .dragging
  }

  // MARK: Replay

  /// The steps a replay walks through, in order.
  enum ReplayStep: Equatable {
    case inserted, compressing, uploading, done
  }

  /// A replay is running: the Replay button waits for it.
  @Published private(set) var isReplaying = false
  var canReplay: Bool { !isReplaying }
  /// Each step as the replay reached it; for a test.
  private(set) var replaySteps: [ReplayStep] = []
  private var replayTask: Task<Void, Never>?
  private var replayRun: UUID?
  /// How a replay waits between steps; a test makes it immediate.
  var replayPause: @MainActor (TimeInterval) async -> Void = { seconds in
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  /// Plays a batch on the Results state: three cards drop in, compress,
  /// upload and finish — one copy smaller, one sent as it was, one already
  /// in the library. Only the preview's cards change: nothing uploads or
  /// copies. A replay already running is left to finish.
  func replay(projects: [Project], projectSlug: String?) {
    guard canReplay else { return }
    replayTask = Task { [weak self] in
      await self?.runReplay(projects: projects, projectSlug: projectSlug)
    }
  }

  /// `replay`, awaited.
  func runReplay(projects: [Project], projectSlug: String?) async {
    guard canReplay else { return }
    let run = UUID()
    replayRun = run
    isReplaying = true
    replaySteps = []
    stage = .results
    state.isDropTargeted = false
    let pictures = self.pictures ?? DropZonePreviewSamples.pictures(in: directory)
    self.pictures = pictures
    model.seedPreview(
      cards: [], draggedFileURLs: [], projects: projects, selectedProjectSlug: projectSlug)
    await replayPause(DropZonePanelMotion.replayLead)
    var cards = DropZonePreviewSamples.replayCards(pictures: pictures, projectSlug: projectSlug)
    for step in [ReplayStep.inserted, .compressing, .uploading, .done] {
      guard replayRun == run, !Task.isCancelled else { return }
      cards = DropZonePreviewSamples.replay(cards, at: step, now: Date())
      seedReplay(cards)
      replaySteps.append(step)
      switch step {
      case .inserted: await replayPause(DropZonePanelMotion.replayWaiting)
      case .compressing: await replayPause(DropZonePanelMotion.replayCompressing)
      case .uploading: await replayPause(DropZonePanelMotion.replayUploading)
      case .done: break
      }
    }
    guard replayRun == run else { return }
    isReplaying = false
    replayRun = nil
    replayTask = nil
  }

  /// Choosing a state ends a replay where it is.
  private func stopReplay() {
    replayTask?.cancel()
    replayTask = nil
    replayRun = nil
    isReplaying = false
  }

  /// The replay's cards into whatever project the preview names now
  /// (Upload into may change while it plays).
  private func seedReplay(_ cards: [DropZoneModel.UploadCard]) {
    let slug = model.selectedProjectSlug
    model.seedPreview(
      cards: cards.map { card in
        var card = card
        card.projectSlug = slug
        return card
      },
      draggedFileURLs: [], projects: model.projects, selectedProjectSlug: slug)
  }

  /// Upload into (or the projects) changed: the header and every card's
  /// project follow, and nothing starts over.
  func retarget(projects: [Project], projectSlug: String?) {
    guard pictures != nil else { return }
    let cards = model.cards.map { card -> DropZoneModel.UploadCard in
      var card = card
      card.projectSlug = projectSlug
      return card
    }
    model.seedPreview(
      cards: cards, draggedFileURLs: model.draggedFileURLs, projects: projects,
      selectedProjectSlug: projectSlug)
  }
}
