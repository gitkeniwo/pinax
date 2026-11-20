import CatalogCore
import CoreGraphics
import Foundation
import SwiftUI

public struct GridOverlayOptions: Equatable, Sendable {
  public enum CornerField: String, CaseIterable, Identifiable, Sendable {
    case none
    case tags
    case noteIndicator
    case fileSize
    case dimensions
    case format
    case uploadDate

    public var id: String { rawValue }

    public var label: String {
      switch self {
      case .none: return "None"
      case .tags: return "Tags"
      case .noteIndicator: return "Note indicator"
      case .fileSize: return "File size"
      case .dimensions: return "Dimensions"
      case .format: return "Format"
      case .uploadDate: return "Upload date"
      }
    }
  }

  /// When the metadata scrim shows. `PreferencesStore` migrates the older
  /// on/off key.
  public enum MetadataVisibility: String, CaseIterable, Identifiable, Sendable {
    case always
    case hoverOrSelected
    case off

    public static let `default`: MetadataVisibility = .hoverOrSelected

    public var id: String { rawValue }

    public var label: String {
      switch self {
      case .always: return "Always"
      case .hoverOrSelected: return "On Hover or Selection"
      case .off: return "Never"
      }
    }

    /// Whether a cell in this state draws the scrim (selected and hovered
    /// show it, at rest nothing).
    public func showsScrim(hovered: Bool, selected: Bool) -> Bool {
      switch self {
      case .always: return true
      case .hoverOrSelected: return hovered || selected
      case .off: return false
      }
    }
  }

  public var metadataVisibility: MetadataVisibility
  /// The filename line under the thumbnail. Unlike the
  /// metadata below, it is laid out, not faded: turning it off gives the
  /// cell back one caption line.
  public var showsFilename: Bool
  public var showsUploadDateBelowImage: Bool
  public var leadingCorner: CornerField
  public var trailingCorner: CornerField
  /// How the cell marks PicGo and bucket imports.
  public var sourceTagStyle: SourceTagStyle

  /// The scrim's two fields by default, as in "553 kB · JPEG".
  public static let defaultLeadingCorner: CornerField = .fileSize
  public static let defaultTrailingCorner: CornerField = .format

  public init(
    metadataVisibility: MetadataVisibility = .default,
    showsFilename: Bool = true,
    showsUploadDateBelowImage: Bool = true,
    leadingCorner: CornerField = GridOverlayOptions.defaultLeadingCorner,
    trailingCorner: CornerField = GridOverlayOptions.defaultTrailingCorner,
    sourceTagStyle: SourceTagStyle = .dateLine
  ) {
    self.metadataVisibility = metadataVisibility
    self.showsFilename = showsFilename
    self.showsUploadDateBelowImage = showsUploadDateBelowImage
    self.leadingCorner = leadingCorner
    self.trailingCorner = trailingCorner
    self.sourceTagStyle = sourceTagStyle
  }
}

public enum GridThumbnailSizing: String, CaseIterable, Sendable {
  case originalAspect
  case fillGrid
}

/// Renders a thumbnail, driving the shared cache with structured cancellation:
/// when the cell leaves the hierarchy the in-flight load is cancelled.
/// `contentMode` defaults to `.fill` (grid cells crop to their footprint);
/// the inspector passes `.fit` so the preview shows the whole image.
struct ThumbnailView: View {
  let item: CatalogAssetItem
  let cache: ThumbnailCache
  var contentMode: ContentMode = .fill
  /// The view is exactly the size it is offered,
  /// whatever picture it holds or whether it holds one yet. Unconfined, a
  /// filled picture sizes the view (a 512×120 thumbnail in a 200 pt square
  /// makes it 853 × 200), so a late arrival changed the view's layout size
  /// and what the cell's clip and hit area were computed from. The grid's
  /// cells confine; the inspector does not (it wants the fitted picture's
  /// own size).
  var confined = false

  @State private var image: CGImage?

  init(
    item: CatalogAssetItem, cache: ThumbnailCache, contentMode: ContentMode = .fill,
    confined: Bool = false
  ) {
    self.item = item
    self.cache = cache
    self.contentMode = contentMode
    self.confined = confined
    // Seed from the in-memory cache so a rebuilt cell's first committed
    // frame already draws the image. Without the seed, measured:
    // 4 rebuilt cells flashed the placeholder across one 2↔3 column
    // reflow with every image already cached. The State initializer only
    // takes effect for a new identity, so this cannot fight the task's
    // loads for an existing one; a miss is a miss and `.task` loads it.
    _image = State(initialValue: cache.peekMemoryImage(for: item.asset.sha256))
  }

  @ViewBuilder
  private var picture: some View {
    if let image {
      Image(decorative: image, scale: 1)
        .resizable()
        .aspectRatio(contentMode: contentMode)
    } else {
      Image(systemName: "photo")
        .font(.title2)
        .foregroundStyle(.tertiary)
    }
  }

  var body: some View {
    Group {
      if confined {
        // `Color.clear` takes the offered size and an overlay never changes
        // its host's size, so the picture can only be cropped, not grow it.
        Color.clear.overlay { picture }
      } else {
        ZStack { picture }
      }
    }
    .clipped()
    .task(id: item.asset.sha256) {
      // The view can outlive its item (same row identity, new asset): never
      // keep the previous asset's picture while the new one loads.
      image = cache.peekMemoryImage(for: item.asset.sha256)
      let timing = SwitchTiming.thumbnailStarted()
      defer { SwitchTiming.thumbnailFinished(timing) }
      let request = ThumbnailRequest(
        sha256: item.asset.sha256,
        sourceURL: URL(string: item.url) ?? URL(fileURLWithPath: "/dev/null")
      )
      if let cached = await cache.cachedImage(for: request) {
        image = cached
        return
      }
      do {
        if let loaded = try await cache.image(for: request) {
          image = loaded
        }
      } catch is CancellationError {
      } catch {}
    }
  }
}

struct AssetGridCell: View {
  let row: GalleryModel.Row
  let cache: ThumbnailCache
  var overlays = GridOverlayOptions()
  var thumbnailSizing: GridThumbnailSizing = .fillGrid
  var isSelected = false
  var quickLook: QuickLookController?
  var tier: SourceTier = .medium
  /// The grid's one hovered cell, which the grid around the
  /// cell keeps; the cell only reads it. `nil` where nothing tracks the
  /// pointer.
  var hover: GridHoverState?
  /// Usage's captions. `.images` drops the filename line and
  /// keeps the date; `.files` writes "Line N" and marks an image the file
  /// already used with "same as above".
  var usageCaption: UsageGridCaption = .none

  private var sourceCaption: SourceCaption? {
    SourceCaption.make(
      style: overlays.sourceTagStyle,
      source: AssetSource.of(meta: row.item.asset.meta),
      tier: tier, showsFilename: overlays.showsFilename)
  }

  private var aspectRatio: CGFloat? {
    guard let width = row.item.asset.width, let height = row.item.asset.height,
      width > 0, height > 0
    else { return nil }
    return CGFloat(width) / CGFloat(height)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.grid.captionSpacing) {
      // Every cell is the same square, whatever the
      // image's shape, so every row is the same height. A row as tall as
      // its tallest image left the lazy grid estimating unbuilt rows from
      // built ones, and the scroller grew and shrank mid-scroll.
      Color.clear
        .aspectRatio(1, contentMode: .fit)
        .overlay {
          switch thumbnailSizing {
          case .originalAspect:
            // Photos-style: the image fits the square, centred both ways,
            // on no tile; everything drawn on it follows its own bounds.
            decorated(Color.clear.aspectRatio(aspectRatio ?? 1, contentMode: .fit))
          case .fillGrid:
            decorated(Color.clear)
          }
        }

      if overlays.showsFilename, usageCaption == .none {
        // The primary style sits on the Text itself, inside the caption
        // role's secondary, so it is the one that wins.
        HStack(spacing: DesignMetrics.spacing.xs) {
          if sourceCaption?.placement == .beforeFilename { markerIcon }
          Text(filename)
            .foregroundStyle(.primary)
            .pinaxCaption()
            .lineLimit(1)
            .truncationMode(.middle)
            .help(row.item.asset.key)
        }
      }
      if usageCaption == .files {
        filesCaption
      } else {
        HStack(spacing: DesignMetrics.spacing.xs) {
          if sourceCaption?.placement == .beforeDate { markerIcon }
          dateText
          Spacer(minLength: 0)
          // The Date line style's mark is a
          // 13 x 13 square at the line's trailing end.
          if sourceCaption?.placement == .dateLine { sourceSquare }
        }
        .help(sourceCaption?.help ?? "")
        .opacity(showsDateLine ? 1 : 0)
        .accessibilityHidden(!showsDateLine)
      }
      if SourceCaption.reservesExtraRow(overlays.sourceTagStyle) {
        extraRow
      }
    }
  }

  private var showsDateLine: Bool {
    sectionLine != nil
      || (overlays.metadataVisibility != .off && overlays.showsUploadDateBelowImage)
  }

  /// Under its file's section, a Usage ▸ Images
  /// cell writes the image's line there in the date's place, whatever the
  /// metadata setting (it carries the line, as Files' does).
  private var sectionLine: String? {
    guard usageCaption == .images, let section = row.usageSection else { return nil }
    return section.line.map { "Line \($0)" } ?? ""
  }

  /// The date; on a selected cell, white on accentFill (5 pt padding each
  /// side, pulled 5 pt left, corner 4). The plate's
  /// padding is there in both states, so selecting never moves the text.
  private var dateText: some View {
    Text(sectionLine ?? uploadDate)
      .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .pinaxCaption()
      .monospacedDigit()
      .lineLimit(1)
      .pinaxSelectedDatePlate(isSelected)
  }

  /// Usage ▸ Files' caption: "Line N" — on the selected
  /// cell's accentFill plate — and "same as above" for an image the file
  /// already used higher up. The filename row is gone there too.
  private var filesCaption: some View {
    HStack(spacing: DesignMetrics.usageCaption.sameAsAboveSpacing) {
      Text(lineText)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .pinaxCaption()
        .monospacedDigit()
        .lineLimit(1)
        .pinaxSelectedDatePlate(isSelected)
        .layoutPriority(1)
      Spacer(minLength: 0)
      if row.repeatsPreviousImage {
        Text("same as above")
          .pinaxSameAsAbove()
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
    }
    .help(lineText.isEmpty ? row.item.asset.key : lineText)
  }

  private var lineText: String {
    Self.lineCaption(row.usage) ?? ""
  }

  /// A Files cell's caption — "Line N", nothing for a
  /// reference without a line.
  static func lineCaption(_ usage: UsageRowInfo?) -> String? {
    guard case let .line(line?) = usage else { return nil }
    return "Line \(line)"
  }

  @ViewBuilder
  private var sourceSquare: some View {
    if let caption = sourceCaption, let icon = caption.icon {
      ColorSquare(size: .caption, color: caption.tint.color, content: .symbol(icon))
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var markerIcon: some View {
    if let caption = sourceCaption, let icon = caption.icon {
      Image(systemName: icon)
        .pinaxCaption()
        .foregroundStyle(caption.tint.color)
        .accessibilityHidden(true)
    }
  }

  /// Pill and Dot: a row under the date that every cell has, marked or
  /// not, so a row is as tall as any other.
  private var extraRow: some View {
    let caption = sourceCaption
    let style = overlays.sourceTagStyle
    return Group {
      if style == .pill {
        HStack(spacing: DesignMetrics.spacing.xs) {
          Image(systemName: caption?.icon ?? "photo.on.rectangle")
            .foregroundStyle(caption?.tint.color ?? .secondary)
          Text(caption?.text ?? "PicGo")
        }
        .pinaxCaption()
        .lineLimit(1)
        .padding(.horizontal, DesignMetrics.spacing.xs)
        .background(.quaternary, in: Capsule())
      } else {
        HStack(spacing: DesignMetrics.spacing.xs) {
          Circle()
            .fill(caption?.tint.color ?? .secondary)
            .frame(width: DesignMetrics.spacing.xs * 2, height: DesignMetrics.spacing.xs * 2)
          Text(caption?.text ?? "PicGo")
        }
        .pinaxCaption()
        .lineLimit(1)
      }
    }
    .opacity(caption == nil ? 0 : 1)
    .accessibilityHidden(caption == nil)
  }

  /// The thumbnail's footprint — the image's own bounds in Original aspect,
  /// the whole square in Fill — with everything drawn on it: the thumbnail,
  /// the chips, Quick Look's anchor, the rounded clip and the ring.
  private func decorated(_ footprint: some View) -> some View {
    footprint
      .background {
        // Fill keeps the tile as the loading placeholder; Original aspect
        // draws on nothing, as Photos does — a tile there is a grey frame
        // around every image that does not fill the square.
        if thumbnailSizing == .fillGrid {
          RoundedRectangle(cornerRadius: DesignMetrics.radius.thumbnail)
            .fill(.quaternary)
        }
      }
      .overlay {
        ThumbnailView(item: row.item, cache: cache, confined: true)
      }
      .overlay { metadataScrim }
      .overlay(alignment: .topTrailing) {
        HStack(spacing: DesignMetrics.spacing.none) {
          usesChip
          favoriteChip
        }
      }
      .overlay(alignment: .topLeading) { usageMarkChip }
      .background {
        QuickLookAnchorRegion(
          sha256: row.item.asset.sha256,
          sizing: thumbnailSizing,
          quickLook: quickLook)
      }
      .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radius.thumbnail))
      // Clipping crops the drawing, not the hit area. A filled wide image
      // overflows its footprint (the `maxWidth: .infinity` frame grows to
      // the image), so without this the next cell, drawn on top, took
      // clicks on this one's right part. The footprint is the hit area.
      .contentShape(Rectangle())
      .overlay { selectionRing }
  }

  /// The Photos-style ring: outside the thumbnail with a gap
  /// of background between, around the image only, never the caption. An
  /// overlay, so selecting never moves a cell.
  @ViewBuilder
  private var selectionRing: some View {
    if isSelected {
      RoundedRectangle(cornerRadius: DesignMetrics.selection.ringRadius)
        .strokeBorder(PinaxPalette.accent, lineWidth: DesignMetrics.selection.ringWidth)
        .padding(-(DesignMetrics.selection.ringGap + DesignMetrics.selection.ringWidth))
        .allowsHitTesting(false)
    }
  }

  /// The favourite mark, in the corner chips' material. Shown
  /// whatever the display options say — it is the item's state, not an
  /// optional metadata field.
  @ViewBuilder
  private var favoriteChip: some View {
    if row.isFavorite {
      Image(systemName: "heart.fill")
        .symbolRenderingMode(.monochrome)
        .pinaxCaption()
        .padding(DesignMetrics.spacing.xs)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignMetrics.radius.chip))
        .padding(DesignMetrics.spacing.xs)
        .allowsHitTesting(false)
        .accessibilityLabel("Favorite")
    }
  }

  /// The reference count, on its yellow badge, only when
  /// the image is used more than once.
  @ViewBuilder
  private var usesChip: some View {
    if case let .image(uses, _, _) = row.usage, Self.showsReferenceBadge(row.usage) {
      UsageRefsBadge(count: uses)
        .padding(DesignMetrics.usageRefsBadge.inset)
        .allowsHitTesting(false)
        .accessibilityLabel(PinaxFormat.count(uses, singular: "reference"))
        .help(PinaxFormat.count(uses, singular: "reference"))
    }
  }

  /// The reference badge is for more than one reference;
  /// an image used once carries none.
  static func showsReferenceBadge(_ usage: UsageRowInfo?) -> Bool {
    guard case let .image(uses, _, _) = usage else { return false }
    return uses > 1
  }

  /// OLD when a reference is on an old domain (Images). Files
  /// writes its line in the caption instead.
  @ViewBuilder
  private var usageMarkChip: some View {
    if let mark = Self.usageMark(row.usage) {
      Text(mark)
        .monospacedDigit()
        .pinaxCaption()
        .padding(DesignMetrics.spacing.xs)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignMetrics.radius.chip))
        .padding(DesignMetrics.spacing.xs)
        .allowsHitTesting(false)
    }
  }

  enum Corner { case leading, trailing }

  /// The one corner chip a footprint too narrow for both keeps: the size
  /// (file size, then dimensions), else the leading one.
  static func narrowCorner(
    leading: GridOverlayOptions.CornerField, trailing: GridOverlayOptions.CornerField
  ) -> Corner {
    for size in [GridOverlayOptions.CornerField.fileSize, .dimensions] {
      if leading == size { return .leading }
      if trailing == size { return .trailing }
    }
    return .leading
  }

  static func usageMark(_ usage: UsageRowInfo?) -> String? {
    switch usage {
    case .image(_, true, _): return "OLD"
    default: return nil
    }
  }

  /// The two fields in one dark scrim at the bottom
  /// left ("553 kB · JPEG" by default), shown by `metadataVisibility`.
  private var metadataScrim: some View {
    let fields = [overlays.leadingCorner, overlays.trailingCorner]
    let kept =
      Self.narrowCorner(leading: overlays.leadingCorner, trailing: overlays.trailingCorner)
      == .leading ? overlays.leadingCorner : overlays.trailingCorner
    return MetadataScrim(
      id: row.id,
      visibility: overlays.metadataVisibility,
      isSelected: isSelected,
      hover: hover,
      full: scrimText(fields),
      narrow: scrimText([kept]))
  }

  /// The fields' values joined by " · "; `nil` when none has a value.
  private func scrimText(_ fields: [GridOverlayOptions.CornerField]) -> Text? {
    let pieces = fields.compactMap(fieldText)
    guard let first = pieces.first else { return nil }
    return pieces.dropFirst().reduce(first) { $0 + Text(" · ") + $1 }
  }

  private func fieldText(_ field: GridOverlayOptions.CornerField) -> Text? {
    switch field {
    case .none:
      return nil
    case .tags:
      guard let tag = row.tags.first else { return nil }
      return Text(row.tags.count > 1 ? "\(tag) +\(row.tags.count - 1)" : tag)
    case .noteIndicator:
      return hasNote ? Text(Image(systemName: "note.text")) : nil
    case .fileSize:
      return Text(fileSize)
    case .dimensions:
      return dimensions.map { Text($0) }
    case .format:
      return Text(format)
    case .uploadDate:
      return Text(uploadDate)
    }
  }

  private var filename: String {
    row.item.asset.originalFilename ?? row.item.asset.key
  }

  private var uploadDate: String {
    PinaxFormat.date(row.item.asset.uploadedAt, style: .day)
  }

  private var hasNote: Bool {
    !(row.item.asset.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  private var dimensions: String? {
    guard let width = row.item.asset.width, let height = row.item.asset.height else { return nil }
    return "\(width) × \(height)"
  }

  private var format: String {
    PinaxFormat.shortKind(mime: row.item.asset.mime)
  }

  private var fileSize: String {
    row.item.asset.byteSize.formatted(.byteCount(style: .file))
  }
}

/// The Quick Look transition anchor: a concrete AppKit view the panel can
/// zoom from and back into. It has no tracking area and no hover state
/// — a tracking area moved by a zoom-step relayout never saw
/// its exit, which left cells stuck in a hover overlay.
private struct QuickLookAnchorRegion: NSViewRepresentable {
  let sha256: String
  let sizing: GridThumbnailSizing
  weak var quickLook: QuickLookController?

  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView()
    view.identifier = Self.identifier(for: sha256)
    quickLook?.registerTransitionAnchor(view, for: sha256, sizing: sizing)
    return view
  }

  func updateNSView(_ view: AnchorView, context: Context) {
    view.identifier = Self.identifier(for: sha256)
    quickLook?.registerTransitionAnchor(view, for: sha256, sizing: sizing)
  }

  static func identifier(for sha256: String) -> NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier("PinaxAssetGridCellThumbnail-\(sha256)")
  }

  final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }
  }
}
