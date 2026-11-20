import AppKit
import ImageIO
import SwiftUI

/// The empty panel: the box illustration and where the images will go. The
/// viewfinder around it is the panel's own layer (`DropZoneViewfinder`), kept
/// under a drag.
struct DropZoneEmptyState: View {
  /// The selected project's name; nil is no project.
  let projectName: String?
  @Environment(\.colorScheme) private var colorScheme

  private var palette: DropZonePalette { .of(colorScheme) }
  private typealias M = DesignMetrics.dropZone

  static let title = "Drop images here"

  var destination: String {
    projectName.map { "They go to \($0)" } ?? "No project"
  }

  var body: some View {
    VStack(spacing: M.illustrationGap) {
      DropBoxIllustration(ink: palette.ink, paper: palette.paper)
      VStack(spacing: M.textSpacing) {
        Text(Self.title)
          .pinaxTitle()
          .foregroundStyle(palette.primary)
        Text(destination)
          .foregroundStyle(palette.secondary)
          .pinaxSecondary()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .dropZoneLayout(.emptyState)
  }
}

/// While a drag hovers the panel, with or without
/// history: the dragged images fanned as a photo stack with their count,
/// and where they will go. The viewfinder stays as it was; what is already
/// there blurs behind the panel's scrim (`DropZoneView`).
struct DropZoneDragOverlay: View {
  /// The drag's files, as `DragMonitor` already read them.
  let fileURLs: [URL]
  let projectName: String?
  @Environment(\.colorScheme) private var colorScheme

  private var palette: DropZonePalette { .of(colorScheme) }
  private typealias M = DesignMetrics.dropZone

  static let title = "Drop to upload"

  /// "3 images into Blog"; no project says so. A drag the monitor did not
  /// see (none read yet) has no count to give.
  var subtitle: String {
    let count = fileURLs.count
    let target = projectName.map { "into \($0)" } ?? "· No project"
    switch count {
    case 0: return projectName.map { "Into \($0)" } ?? "No project"
    case 1: return "1 image \(target)"
    default: return "\(count) images \(target)"
    }
  }

  var body: some View {
    VStack(spacing: M.illustrationGap) {
      DragPhotoStack(fileURLs: fileURLs, accent: palette.accent, placeholder: palette.paper)
      VStack(spacing: M.textSpacing) {
        Text(Self.title)
          .pinaxTitle()
          .fontWeight(.bold)
          .foregroundStyle(palette.primary)
        Text(subtitle)
          .foregroundStyle(palette.secondary)
          .pinaxSecondary()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(Self.title), \(subtitle)")
  }
}

/// The viewfinder: four rounded corner brackets just
/// inside the content area, in the illustration's ink — one layer for the
/// empty state and a drag alike.
struct DropZoneViewfinder: View {
  let ink: Color

  private typealias M = DesignMetrics.dropZone

  var body: some View {
    ViewfinderBrackets(length: M.bracketLength, radius: M.bracketRadius, inset: M.bracketInset)
      .stroke(ink, style: StrokeStyle(lineWidth: M.bracketWidth, lineCap: .round))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// Four rounded corner brackets, `inset` inside the rect.
struct ViewfinderBrackets: Shape {
  let length: CGFloat
  let radius: CGFloat
  let inset: CGFloat

  func path(in rect: CGRect) -> Path {
    let r = rect.insetBy(dx: inset, dy: inset)
    var path = Path()
    // Each corner: from the end of one arm, round the corner, to the other.
    let corners: [(corner: CGPoint, dx: CGFloat, dy: CGFloat)] = [
      (CGPoint(x: r.minX, y: r.minY), 1, 1),
      (CGPoint(x: r.maxX, y: r.minY), -1, 1),
      (CGPoint(x: r.maxX, y: r.maxY), -1, -1),
      (CGPoint(x: r.minX, y: r.maxY), 1, -1),
    ]
    for (corner, dx, dy) in corners {
      path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
      path.addArc(
        tangent1End: corner, tangent2End: CGPoint(x: corner.x + dx * length, y: corner.y),
        radius: radius)
      path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
    }
    return path
  }
}

/// The box drawing: a photo tipping into an open box. Line and paper are
/// the palette's neutral greys — never black in dark. Coordinates are in a
/// 150 × 118 box.
struct DropBoxIllustration: View {
  let ink: Color
  let paper: Color

  private typealias M = DesignMetrics.dropZone
  private static let photoCorner: CGFloat = 5
  private static let boxCorner: CGFloat = 8
  private static let photoTilt: Double = -14
  private static let photoPivot = UnitPoint(x: 75 / 150, y: 40 / 118)

  private static let photo = Path(
    roundedRect: CGRect(x: 50, y: 10, width: 54, height: 42), cornerRadius: photoCorner)

  private static let photoMarks: Path = {
    var path = Path()
    path.addLines([
      CGPoint(x: 56, y: 46), CGPoint(x: 68, y: 33), CGPoint(x: 76, y: 41),
      CGPoint(x: 82, y: 36), CGPoint(x: 97, y: 46),
    ])
    path.addEllipse(in: CGRect(x: 84.5, y: 18.5, width: 7, height: 7))
    return path
  }()

  private static let box: Path = {
    var path = Path()
    path.move(to: CGPoint(x: 22, y: 66))
    path.addLine(to: CGPoint(x: 128, y: 66))
    path.addArc(
      tangent1End: CGPoint(x: 128, y: 106), tangent2End: CGPoint(x: 120, y: 106), radius: boxCorner)
    path.addArc(
      tangent1End: CGPoint(x: 22, y: 106), tangent2End: CGPoint(x: 22, y: 98), radius: boxCorner)
    path.closeSubpath()
    return path
  }()

  /// The open flaps and the box's front lip.
  private static let flaps: Path = {
    var path = Path()
    path.move(to: CGPoint(x: 22, y: 66))
    path.addLine(to: CGPoint(x: 34, y: 50))
    path.move(to: CGPoint(x: 128, y: 66))
    path.addLine(to: CGPoint(x: 116, y: 50))
    path.move(to: CGPoint(x: 52, y: 66))
    path.addCurve(
      to: CGPoint(x: 75, y: 80), control1: CGPoint(x: 52, y: 75), control2: CGPoint(x: 62, y: 80))
    path.addCurve(
      to: CGPoint(x: 98, y: 66), control1: CGPoint(x: 88, y: 80), control2: CGPoint(x: 98, y: 75))
    return path
  }()

  var body: some View {
    let line = StrokeStyle(lineWidth: M.illustrationLine, lineCap: .round, lineJoin: .round)
    ZStack {
      ZStack {
        Self.photo.fill(paper)
        Self.photo.stroke(ink, style: line)
        Self.photoMarks.stroke(ink, style: line)
      }
      .rotationEffect(.degrees(Self.photoTilt), anchor: Self.photoPivot)
      Self.box.fill(paper)
      Self.box.stroke(ink, style: line)
      Self.flaps.stroke(ink, style: line)
    }
    .frame(width: M.illustrationWidth, height: M.illustrationHeight)
    .accessibilityHidden(true)
  }
}

/// Up to three of the drag's images, fanned, the first in front, with the
/// count on an accent badge. Thumbnails are made off the main thread from
/// the first three files only; until (or unless) one is ready its card is
/// a plain placeholder.
struct DragPhotoStack: View {
  let fileURLs: [URL]
  let accent: Color
  let placeholder: Color
  @State private var images: [URL: CGImage] = [:]

  private typealias M = DesignMetrics.dropZone
  /// The canvas's fan, back to front: top-left offsets in the 150 × 130 box
  /// and tilts in degrees.
  private static let fan: [(x: CGFloat, y: CGFloat, tilt: Double)] = [
    (18, 18, -9), (36, 12, 7), (27, 22, 0),
  ]
  nonisolated static let maxShown = 3

  private var shown: [URL] { Array(fileURLs.prefix(Self.maxShown)) }

  var body: some View {
    let shown = self.shown
    // Back to front; with nothing read yet, one blank card in front.
    let count = max(shown.count, 1)
    ZStack(alignment: .topLeading) {
      ForEach(0..<count, id: \.self) { slot in
        let fan = Self.fan[Self.fan.count - count + slot]
        let url = shown.isEmpty ? nil : shown[count - 1 - slot]
        card(url.flatMap { images[$0] })
          .rotationEffect(.degrees(fan.tilt))
          .offset(x: fan.x, y: fan.y)
      }
    }
    .frame(width: M.stackWidth, height: M.stackHeight, alignment: .topLeading)
    .overlay(alignment: .bottomTrailing) {
      if !fileURLs.isEmpty { badge }
    }
    .task(id: shown) { images = await Self.thumbnails(for: shown) }
  }

  private func card(_ image: CGImage?) -> some View {
    let shape = RoundedRectangle(cornerRadius: M.stackCardRadius, style: .continuous)
    return shape.fill(placeholder)
      .overlay {
        if let image {
          Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
        }
      }
      .frame(width: M.stackCardWidth, height: M.stackCardHeight)
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color.white, lineWidth: M.stackCardBorder))
      .shadow(
        color: Color.black.opacity(M.stackShadowOpacity), radius: M.stackShadowRadius,
        y: M.stackShadowOffset)
  }

  private var badge: some View {
    Text("\(fileURLs.count)")
      .pinaxTitle()
      .fontWeight(.heavy)
      .monospacedDigit()
      .foregroundStyle(Color.white)
      .frame(width: M.badgeSize, height: M.badgeSize)
      .background(accent, in: Circle())
      .overlay(Circle().strokeBorder(Color.white, lineWidth: M.badgeBorder))
      .padding(.trailing, M.badgeTrailing)
      .padding(.bottom, M.badgeBottom)
  }

  /// Off the main thread: ImageIO reads only what the downscale needs.
  nonisolated static func thumbnails(for urls: [URL]) async -> [URL: CGImage] {
    await Task.detached(priority: .userInitiated) {
      var images: [URL: CGImage] = [:]
      for url in urls.prefix(maxShown) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: Int(2 * M.stackCardWidth),
          kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        images[url] = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      }
      return images
    }.value
  }
}
