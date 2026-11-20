import AppKit
import CatalogCore
import SwiftUI

/// The panel's single surface: while no results exist it is the drop hint;
/// once cards exist it is the results list. The project picker ("project" is
/// the user's term — never "album") defaults to the last used project.
public struct DropZoneView: View {
  /// The panel's coordinate space: hover locations, the preview's frame and
  /// the layout report are all in it.
  static let space = "dropZonePanel"

  @ObservedObject var model: DropZoneModel
  @ObservedObject var state: DropZoneViewState
  @Environment(\.colorScheme) private var colorScheme

  public init(model: DropZoneModel) {
    self.init(model: model, state: DropZoneViewState())
  }

  init(model: DropZoneModel, state: DropZoneViewState) {
    self.model = model
    self.state = state
  }

  private var palette: DropZonePalette { .of(colorScheme) }

  /// The panel's layers and their stacking order, back to front: what is
  /// there; under a drag the scrim over the whole
  /// panel; the one viewfinder; the drag's photo stack and words; the
  /// header, never under the scrim.
  enum Layer: Double {
    case content = 0, scrim, viewfinder, dragContent, header
  }

  public var body: some View {
    ZStack(alignment: .top) {
      layer(.content).zIndex(Layer.content.rawValue)
      layer(.scrim).zIndex(Layer.scrim.rawValue)
      layer(.viewfinder).zIndex(Layer.viewfinder.rawValue)
      layer(.dragContent).zIndex(Layer.dragContent.rawValue)
      layer(.header).zIndex(Layer.header.rawValue)
    }
    .foregroundStyle(palette.primary)
    .tint(palette.accent)
    // Settings ▸ Size: the panel sets the size; the root fills it.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .dropZoneLayout(.panel)
    .glassBackground(
      in: RoundedRectangle(cornerRadius: DesignMetrics.dropZone.panelRadius, style: .continuous),
      tint: palette.panelTint, rim: palette.panelRim)
    .overlay(alignment: .topLeading) { preview }
    .coordinateSpace(name: Self.space)
    .onPreferenceChange(DropZoneLayoutKey.self) { [state] frames in
      MainActor.assumeIsolated { state.layoutFrames = frames }
    }
    .onPreferenceChange(DropZoneMotionKey.self) { [state] motions in
      MainActor.assumeIsolated { state.motions = motions }
    }
    .dropDestination(for: URL.self) { urls, _ in
      model.drop(fileURLs: urls)
      return true
    } isTargeted: { targeted in
      state.isDropTargeted = targeted
    }
  }

  @ViewBuilder
  private func layer(_ layer: Layer) -> some View {
    switch layer {
    case .content:
      belowHeader {
        content
          // Whenever a drag hovers the panel,
          // over the empty state and over existing cards alike, what is
          // there blurs and fades under the drag-over state.
          .blur(radius: state.isDropTargeted ? DesignMetrics.dropZone.dragBlur : 0)
          .saturation(state.isDropTargeted ? DesignMetrics.dropZone.dragSaturation : 1)
          .opacity(state.isDropTargeted ? DesignMetrics.dropZone.dragContentOpacity : 1)
      }
    case .scrim:
      if state.isDropTargeted { dragScrim }
    case .viewfinder:
      if model.cards.isEmpty || state.isDropTargeted {
        belowHeader { viewfinder.dropZoneLayout(.viewfinder) }
      }
    case .dragContent:
      if state.isDropTargeted { belowHeader { dragOverlayContent } }
    case .header:
      header
        .frame(height: DesignMetrics.dropZone.headerHeight)
        .padding(DesignMetrics.dropZone.panelInset)
        // Drawn last, read first.
        .accessibilitySortPriority(1)
    }
  }

  /// The content area: the panel inset all round, below the header's slot.
  private func belowHeader(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(spacing: DesignMetrics.spacing.s) {
      Color.clear.frame(height: DesignMetrics.dropZone.headerHeight)
      content()
    }
    .padding(DesignMetrics.dropZone.panelInset)
  }

  @ViewBuilder
  private var content: some View {
    if model.cards.isEmpty {
      emptyStateContent
    } else {
      switch state.layout {
      case .list: cardsList
      case .shelf: shelf
      }
    }
  }

  private var header: some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      projectPicker
      // Pinned, the panel never hides on its own (this run only).
      Button {
        model.togglePin()
      } label: {
        Image(systemName: model.isPinned ? "pin.fill" : "pin")
      }
      .buttonStyle(DropZoneIconButtonStyle())
      .help(model.isPinned ? "Unpin" : "Pin")
      .accessibilityLabel(model.isPinned ? "Unpin" : "Pin")
      .dropZoneLayout(.action("Pin"))
      Button {
        model.dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(DropZoneIconButtonStyle())
      .help("Close")
      .accessibilityLabel("Close")
      .dropZoneLayout(.action("Close"))
    }
  }

  /// The app's current project as a framed pill: All Projects uploads into no
  /// project.
  private var projectPicker: some View {
    Menu {
      Picker("Project", selection: $model.selectedProjectSlug) {
        Text("All Projects").tag(String?.none)
        ForEach(model.projects, id: \.slug) { project in
          Text(project.name).tag(String?.some(project.slug))
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      HStack(spacing: DesignMetrics.spacing.s) {
        Image(systemName: "folder")
          .foregroundStyle(palette.secondary)
        Text(selectedProjectTitle)
          .fontWeight(.semibold)
          .pinaxBody()
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .foregroundStyle(palette.secondary)
      }
      .fontWeight(.medium)
      .dropZoneLayout(.projectPicker)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(DropZonePillButtonStyle())
    .help("Upload into")
    .accessibilityLabel("Project: \(selectedProjectTitle)")
  }

  private var selectedProjectTitle: String {
    guard let slug = model.selectedProjectSlug else { return "All Projects" }
    return model.projects.first { $0.slug == slug }?.name ?? "All Projects"
  }

  /// The selected project's name for the empty and drag-over words; nil
  /// (or a project that is gone) is no project.
  private var selectedProjectName: String? {
    guard let slug = model.selectedProjectSlug else { return nil }
    return model.projects.first { $0.slug == slug }?.name
  }

  /// What the empty and drag-over states say, from the model.
  var emptyStateContent: DropZoneEmptyState {
    DropZoneEmptyState(projectName: selectedProjectName)
  }

  var dragOverlayContent: DropZoneDragOverlay {
    DropZoneDragOverlay(fileURLs: model.draggedFileURLs, projectName: selectedProjectName)
  }

  /// The empty state's viewfinder, which a drag keeps as it is — same
  /// place, same ink.
  var viewfinder: DropZoneViewfinder {
    DropZoneViewfinder(ink: palette.ink)
  }

  /// Under a drag, a thin wash over the whole panel, edge to edge and top to
  /// bottom; the header floats above it.
  private var dragScrim: some View {
    palette.dropWash
      .clipShape(
        RoundedRectangle(cornerRadius: DesignMetrics.dropZone.panelRadius, style: .continuous))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .dropZoneLayout(.dropOverlay)
      .allowsHitTesting(false)
  }

  private var cardsList: some View {
    ScrollView {
      LazyVStack(spacing: DesignMetrics.spacing.s) {
        ForEach(model.cards) { card in
          ResultCardView(card: card, model: model, state: state)
        }
      }
    }
    .scrollIndicators(.hidden)
    .frame(maxHeight: .infinity)
  }

  /// Shelf: two columns of large thumbnails, newest first, read
  /// left to right.
  private var shelf: some View {
    ScrollView {
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: DesignMetrics.dropZone.shelfColumnGap),
          count: 2),
        spacing: DesignMetrics.dropZone.shelfRowGap
      ) {
        ForEach(model.cards) { card in
          ShelfCellView(card: card, model: model, state: state)
        }
      }
      // Room inside the scroll clip for the status drawn outside each
      // image (the ring, the in-library copy); the scroll area grows by
      // the same so the cells stay where they were.
      .padding(DesignMetrics.dropZone.statusOutset)
    }
    .scrollIndicators(.hidden)
    .dropZoneLayout(.scroll)
    .padding(-DesignMetrics.dropZone.statusOutset)
    .frame(maxHeight: .infinity)
  }

  /// The hovered thumbnail, enlarged, over the panel. It lives here
  /// rather than in the card so the list's scroll clip cannot cut it.
  @ViewBuilder
  private var preview: some View {
    if let preview = state.preview,
      let image = model.cards.first(where: { $0.id == preview.cardID })?.thumbnail
    {
      Image(decorative: image, scale: 1)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: preview.frame.width, height: preview.frame.height)
        .clipShape(
          RoundedRectangle(cornerRadius: DesignMetrics.dropZone.previewRadius, style: .continuous))
        .opacity(DesignMetrics.dropZone.previewOpacity)
        .shadow(
          color: Color(nsColor: .shadowColor).opacity(DesignMetrics.dropZone.previewShadowOpacity),
          radius: DesignMetrics.dropZone.previewShadowRadius,
          y: DesignMetrics.dropZone.previewShadowOffset)
        .dropZoneLayout(.preview)
        .padding(.leading, preview.frame.minX)
        .padding(.top, preview.frame.minY)
        .allowsHitTesting(false)
    }
  }
}

/// What the panel's surface holds that is the view's, not the model's: the
/// drop-target flag and the hover preview. Its own object (the controller
/// makes one per panel) so a hosted test can set it — neither a system drag
/// nor a real pointer can be driven under test.
@MainActor
final class DropZoneViewState: ObservableObject {
  struct Preview: Equatable {
    let cardID: UUID
    let frame: CGRect
  }

  @Published var isDropTargeted = false
  /// Settings ▸ Size, pushed by the controller: the hover preview's bounds.
  @Published var panelSize = DropZonePanel.defaultSize
  @Published private(set) var preview: Preview?
  /// Settings ▸ Drop Zone ▸ Layout, pushed by the controller.
  @Published var layout: DropZoneLayout = .list
  /// System Settings ▸ Accessibility ▸ Reduce motion, pushed by the
  /// controller: the upload arc stands still and the fresh-upload glow
  /// goes without fading.
  @Published var reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  /// Each card's status motion as drawn (`DropZoneMotionKey`); like
  /// `layoutFrames`, for a test only.
  var motions: [UUID: DropZoneMotion] = [:]
  /// Where each part of the panel last landed (`DropZoneLayoutKey`). Not
  /// published — nothing redraws from it; a test reads it from the panel
  /// the app itself hosts.
  var layoutFrames: [DropZoneLayoutKey.Part: CGRect] = [:]

  /// A thumbnail's hover: shown at once on entry, following the
  /// pointer at a fixed size, gone at once on exit. `location` is in the
  /// panel's space. A card without a cached thumbnail shows nothing — the
  /// preview never fetches.
  func thumbnailHover(
    _ phase: HoverPhase, cardID: UUID, imageSize: CGSize?,
    panelSize: CGSize? = nil
  ) {
    let panelSize = panelSize ?? self.panelSize
    switch phase {
    case .active(let location):
      guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
        preview = nil
        return
      }
      let size = Self.previewSize(image: imageSize, panel: panelSize)
      preview = Preview(
        cardID: cardID, frame: Self.previewFrame(pointer: location, size: size, panel: panelSize))
    case .ended:
      if preview?.cardID == cardID { preview = nil }
    }
  }

  /// Fixed width (a share of the panel's), the image's aspect, never taller
  /// than the panel allows.
  static func previewSize(image: CGSize, panel: CGSize) -> CGSize {
    let inset = DesignMetrics.dropZone.previewEdgeInset
    let width = panel.width * DesignMetrics.dropZone.previewWidthFraction
    let height = min(width * image.height / image.width, panel.height - 2 * inset)
    return CGSize(width: width, height: height)
  }

  /// Below-right of the pointer; flipped to the other side where it would
  /// leave the panel; then clamped so it stays wholly inside, the inset
  /// leaving room for the shadow.
  static func previewFrame(pointer: CGPoint, size: CGSize, panel: CGSize) -> CGRect {
    let gap = DesignMetrics.dropZone.previewPointerGap
    let inset = DesignMetrics.dropZone.previewEdgeInset
    func place(_ pointer: CGFloat, _ length: CGFloat, _ panel: CGFloat) -> CGFloat {
      var origin = pointer + gap
      if origin + length > panel - inset { origin = pointer - gap - length }
      return min(max(origin, inset), panel - inset - length)
    }
    return CGRect(
      x: place(pointer.x, size.width, panel.width),
      y: place(pointer.y, size.height, panel.height),
      width: size.width, height: size.height)
  }
}

/// Where each part of the panel landed, in the panel's space. The panel
/// itself never reads it; a hosted test does, to measure alignment, equal
/// heights and the preview without a screenshot.
struct DropZoneLayoutKey: PreferenceKey {
  enum Role: Hashable {
    case card, thumbnail, text, buttons, filename, statusLayer, statusText, meta, error, retry
    case moveError, emptyState, dropOverlay, panel, preview, projectPicker, projectToken, shelfBar
    case viewfinder, scroll
    case action(String)
  }

  struct Part: Hashable {
    let card: UUID?
    let role: Role
  }

  static var defaultValue: [Part: CGRect] = [:]
  static func reduce(value: inout [Part: CGRect], nextValue: () -> [Part: CGRect]) {
    value.merge(nextValue()) { _, new in new }
  }
}

extension View {
  func dropZoneLayout(_ role: DropZoneLayoutKey.Role, card: UUID? = nil) -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: DropZoneLayoutKey.self,
          value: [
            DropZoneLayoutKey.Part(card: card, role: role):
              proxy.frame(in: .named(DropZoneView.space))
          ])
      })
  }
}

enum PasteboardWriter {
  static func copy(_ string: String, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }
}
