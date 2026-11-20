import AppKit
import CatalogCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private typealias Metrics = DesignMetrics.settings

/// The preview's three states, chosen under it. Lives in the page only.
enum DropZonePreviewStage: CaseIterable, Hashable {
  case empty, dragging, results

  var label: String {
    switch self {
    case .empty: "Empty"
    case .dragging: "Dragging"
    case .results: "Results"
    }
  }
}

/// Every sample the preview shows, in one place: the pictures (drawn in
/// code, no words, no photos), and the cards each state is made of. The
/// cards are built afresh for each showing, never kept, so a state can be
/// shown again from the start.
enum DropZonePreviewSamples {
  /// The four pictures, in card order.
  enum Picture: String, CaseIterable {
    case sunset = "hero-sunset"
    case map = "trail-map"
    case cover = "cover-2024"
    case photo = "IMG_2041"

    var pixelSize: (width: Int, height: Int) {
      switch self {
      case .sunset: (320, 240)
      case .map: (320, 200)
      case .cover: (320, 168)
      case .photo: (240, 320)
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

  /// Draws the four pictures and writes each as a PNG in `directory`,
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
      landedAt: Date? = nil
    ) -> DropZoneModel.UploadCard {
      DropZoneModel.UploadCard(
        filename: filename,
        fileURL: pictures.urls[picture] ?? URL(fileURLWithPath: filename),
        phase: phase, thumbnail: pictures.images[picture], landedAt: landedAt,
        projectSlug: projectSlug)
    }
    return [
      card("hero-sunset.jpg", .sunset, .uploading),
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

  /// Gradients and simple shapes: sunset orange and pink, a green-blue
  /// map, a purple cover, a grey-brown photo.
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
