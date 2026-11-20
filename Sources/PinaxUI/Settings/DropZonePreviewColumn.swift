import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings
private typealias Geometry = DropZonePreviewGeometry

/// Settings ▸ Drop Zone's right column: the real panel on a mini desktop,
/// following Appearance, Layout, Size, Position and Upload into as they
/// change; its size, the state it shows, and that it is only a preview.
/// It never uploads, copies or touches the app's drop zone.
struct DropZonePreviewColumn: View {
  @ObservedObject var preferences: PreferencesStore
  var projects: [Project]
  @StateObject private var preview = DropZonePreviewController()
  @Environment(\.colorScheme) private var windowScheme

  /// Upload into as the panel would start.
  private var projectSlug: String? {
    DropZonePreviewSamples.projectSlug(
      uploadInto: preferences.dropZoneUploadInto,
      currentProjectSlug: preferences.currentProjectSlug, projects: projects)
  }

  /// What the header can name: the projects' slugs and names.
  private var projectNames: [String] { projects.map { "\($0.slug)/\($0.name)" } }

  /// The panel's Appearance; Auto is the settings window's own.
  private var scheme: ColorScheme {
    switch preferences.dropZoneAppearance {
    case .light: .light
    case .dark: .dark
    case .system: windowScheme
    }
  }

  private var isEnabled: Bool { preferences.isDropZoneEnabled }

  var body: some View {
    VStack(spacing: DesignMetrics.spacing.none) {
      DropZonePreviewDesktop(
        preview: preview, size: preferences.dropZoneSize, corner: preferences.dropZoneCorner,
        resize: { preferences.setDropZoneSize($0) }
      )
      .environment(\.colorScheme, scheme)
      .overlay {
        RoundedRectangle(cornerRadius: Metrics.previewDesktopRadius, style: .continuous)
          .strokeBorder(
            DropZonePreviewPalette.rim(window: windowScheme), lineWidth: Metrics.previewDesktopRimWidth)
      }
      .shadow(
        color: .black.opacity(Metrics.previewDesktopShadowOpacity),
        radius: Metrics.previewDesktopShadowRadius, y: Metrics.previewDesktopShadowOffset)
      Text(Geometry.sizeLabel(for: preferences.dropZoneSize))
        .pinaxSettingsPreviewLabel()
        .padding(.top, Metrics.previewLabelGap)
      Picker("Preview", selection: stageBinding) {
        ForEach(DropZonePreviewStage.allCases, id: \.self) { stage in
          Text(stage.label).tag(stage)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .fixedSize()
      .padding(.top, Metrics.previewSegmentGap)
      Text("Preview only")
        .pinaxSettingsPreviewNote()
        .padding(.top, Metrics.previewNoteGap)
    }
    .frame(width: Metrics.previewColumnWidth)
    // With the drop zone off, the preview greys and fades with the form.
    .saturation(isEnabled ? 1 : 0)
    .opacity(isEnabled ? 1 : Metrics.disabledOpacity)
    .disabled(!isEnabled)
    .onAppear { show(preview.stage) }
    .onChange(of: projectSlug) { _, slug in
      preview.retarget(projects: projects, projectSlug: slug)
    }
    .onChange(of: projectNames) { _, _ in
      preview.retarget(projects: projects, projectSlug: projectSlug)
    }
    .onChange(of: preferences.dropZoneLayout, initial: true) { _, layout in
      preview.state.layout = layout
    }
    .onChange(of: preferences.dropZoneSize, initial: true) { _, size in
      preview.state.panelSize = size
    }
  }

  /// Choosing a state, the current one included, shows it from the start.
  private var stageBinding: Binding<DropZonePreviewStage> {
    Binding(get: { preview.stage }, set: { show($0) })
  }

  private func show(_ stage: DropZonePreviewStage) {
    preview.show(stage, projects: projects, projectSlug: projectSlug)
  }
}

/// The mini desktop: a fixed wallpaper, a thin menu bar, and the real
/// panel at its corner, shrunk evenly when it does not fit, with its
/// resize grip.
struct DropZonePreviewDesktop: View {
  @ObservedObject var preview: DropZonePreviewController
  let size: CGSize
  let corner: DropZoneCorner
  let resize: (CGSize) -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let scale = Geometry.scale(for: size)
    let frame = Geometry.panelFrame(for: size, corner: corner)
    ZStack(alignment: .topLeading) {
      DropZonePreviewWallpaper()
      menuBar
      panel(scale: scale, frame: frame)
        .offset(x: frame.minX, y: frame.minY)
      DropZonePreviewGrip(size: size, scale: scale, resize: resize)
        .offset(
          x: frame.maxX - Metrics.previewGripCornerInset - DesignMetrics.dropZone.gripSize,
          y: frame.maxY - Metrics.previewGripCornerInset - DesignMetrics.dropZone.gripSize)
    }
    .frame(width: Geometry.desktop.width, height: Geometry.desktop.height, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: Metrics.previewDesktopRadius, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Drop zone preview")
  }

  private var menuBar: some View {
    let palette = DropZonePreviewPalette.of(scheme)
    return HStack(spacing: Metrics.previewMenuBarSpacing) {
      Circle()
        .fill(palette.menuBarMark)
        .frame(width: Metrics.previewMenuBarDot, height: Metrics.previewMenuBarDot)
      ForEach(Array(Metrics.previewMenuBarLeadingMarks.enumerated()), id: \.offset) { _, width in
        mark(width, palette)
      }
      Spacer(minLength: 0)
      ForEach(Array(Metrics.previewMenuBarTrailingMarks.enumerated()), id: \.offset) { _, width in
        mark(width, palette)
      }
      Text(verbatim: "Fri 9:41")
        .font(.system(size: Metrics.previewMenuBarClockSize, weight: .semibold))
        .foregroundStyle(palette.menuBarClock)
    }
    .padding(.horizontal, Metrics.previewMenuBarInset)
    .frame(width: Geometry.desktop.width, height: Metrics.previewMenuBarHeight)
    .background(palette.menuBar)
    .accessibilityHidden(true)
  }

  private func mark(_ width: CGFloat, _ palette: DropZonePreviewPalette) -> some View {
    Capsule()
      .fill(palette.menuBarMark)
      .frame(width: width, height: Metrics.previewMenuBarMark)
  }

  /// The real panel at its own size, shrunk from its top-left corner.
  private func panel(scale: CGFloat, frame: CGRect) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: DesignMetrics.dropZone.panelRadius * scale, style: .continuous)
    return DropZoneView(model: preview.model, state: preview.state, isPreview: true)
      .frame(width: size.width, height: size.height)
      .scaleEffect(scale, anchor: .topLeading)
      .frame(width: frame.width, height: frame.height, alignment: .topLeading)
      .background {
        // The app's panel gets its blur from the window behind it; here
        // the blur is the wallpaper under the panel, before macOS 26.
        if GlassSupport.panelUsesBehindWindowMaterial {
          DropZonePreviewWallpaper()
            .blur(radius: Metrics.previewFrostBlur, opaque: true)
            .offset(x: -frame.minX, y: -frame.minY)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipShape(shape)
        }
      }
      .compositingGroup()
      .shadow(
        color: .black.opacity(Metrics.previewPanelShadowOpacity),
        radius: Metrics.previewPanelShadowRadius, y: Metrics.previewPanelShadowOffset)
  }
}

/// The fixed wallpaper: a 165° wash with a glow top right and one bottom
/// left, in the preview's appearance.
struct DropZonePreviewWallpaper: View {
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let palette = DropZonePreviewPalette.of(scheme)
    let size = Geometry.desktop
    ZStack(alignment: .topLeading) {
      LinearGradient(
        colors: palette.wash, startPoint: UnitPoint(x: 0.37, y: 0),
        endPoint: UnitPoint(x: 0.63, y: 1))
      glow(palette.topGlow, center: CGPoint(x: 0.88, y: 0.06), radii: CGSize(width: 1.1, height: 0.7), reach: 0.62)
      glow(palette.bottomGlow, center: CGPoint(x: 0.08, y: 0.98), radii: CGSize(width: 0.95, height: 0.7), reach: 0.66)
    }
    .frame(width: size.width, height: size.height)
    .clipped()
  }

  /// An elliptical glow: `radii` as shares of the desktop, fading out by
  /// `reach` of them.
  private func glow(_ color: Color, center: CGPoint, radii: CGSize, reach: CGFloat) -> some View {
    let size = Geometry.desktop
    return EllipticalGradient(
      colors: [color, color.opacity(0)], center: .center, startRadiusFraction: 0,
      endRadiusFraction: reach
    )
    .frame(width: 2 * radii.width * size.width, height: 2 * radii.height * size.height)
    .position(x: center.x * size.width, y: center.y * size.height)
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .allowsHitTesting(false)
  }
}

/// The panel's resize grip, drawn like the app's: three short diagonals.
/// It stays 16 pt when the panel is shrunk; dragging it changes Size by
/// what moved on screen over the shrink.
struct DropZonePreviewGrip: View {
  let size: CGSize
  let scale: CGFloat
  let resize: (CGSize) -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var hovered = false
  @State private var dragStart: (size: CGSize, scale: CGFloat)?

  var body: some View {
    let palette = DropZonePalette.of(scheme)
    let side = DesignMetrics.dropZone.gripSize
    GripLines()
      .stroke(
        hovered ? palette.primary : Color(nsColor: .tertiaryLabelColor),
        style: StrokeStyle(lineWidth: DesignMetrics.dropZone.gripLine, lineCap: .round))
      .frame(width: side, height: side)
      .background {
        if hovered {
          RoundedRectangle(cornerRadius: Metrics.previewGripHoverRadius, style: .continuous)
            .fill(palette.buttonHover)
        }
      }
      .contentShape(Rectangle())
      .onHover { inside in
        guard inside != hovered else { return }
        hovered = inside
        if inside { Self.cursor.push() } else { NSCursor.pop() }
      }
      .onDisappear {
        if hovered { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
          .onChanged { drag in
            let start = dragStart ?? (size, scale)
            dragStart = start
            resize(
              Geometry.resized(from: start.size, by: drag.translation, scale: start.scale))
          }
          .onEnded { _ in dragStart = nil })
      .accessibilityLabel("Resize")
  }

  private static var cursor: NSCursor {
    if #available(macOS 15.0, *) {
      return .frameResize(position: .bottomRight, directions: .all)
    }
    return .crosshair
  }

  private struct GripLines: Shape {
    func path(in rect: CGRect) -> Path {
      let inset = DesignMetrics.dropZone.gripInset
      let reach = rect.width - 2 * inset
      var path = Path()
      for step in 1...3 {
        let length = reach * CGFloat(step) / 3
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset - length))
        path.addLine(to: CGPoint(x: rect.maxX - inset - length, y: rect.maxY - inset))
      }
      return path
    }
  }
}
