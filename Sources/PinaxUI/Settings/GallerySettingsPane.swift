import AppKit
import CatalogCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private typealias Metrics = DesignMetrics.settings

/// Machine-local gallery display choices: a preview drawn by the grid's own
/// cell over the thumbnail switches, the source tag styles as five cards, and
/// the order in one row. The metadata switches stay mounted while details are
/// off, dimmed. Copy formats and Downloads live on General.
struct GallerySettingsPane: View {
  @ObservedObject var preferences: PreferencesStore

  var body: some View {
    SettingsPage {
      SettingsSection("Thumbnails") {
        SettingsGroup {
          GalleryPreview(
            overlays: preferences.gridOverlays, sizing: preferences.gridThumbnailSizing)
          SettingsRowDivider()
          SettingsRow("Show details") {
            SettingsMenuPicker("Show details", selection: overlayBinding(\.metadataVisibility)) {
              ForEach(GridOverlayOptions.MetadataVisibility.allCases) { visibility in
                Text(visibility.label).tag(visibility)
              }
            } label: {
              Text(preferences.gridOverlays.metadataVisibility.label)
            }
          }
          SettingsRowDivider()
          SettingsRow("Filename below thumbnail") {
            Toggle("Filename below thumbnail", isOn: overlayBinding(\.showsFilename))
              .settingsSwitch()
          }
          Group {
            SettingsRowDivider()
            SettingsRow("Upload date below filename") {
              Toggle("Upload date below filename", isOn: overlayBinding(\.showsUploadDateBelowImage))
                .settingsSwitch()
            }
            SettingsRowDivider()
            SettingsRow("Details show") {
              HStack(spacing: Metrics.detailsShowSpacing) {
                cornerPicker("First field", keyPath: \.leadingCorner)
                Text("and").pinaxSettingsRowSubtitle()
                cornerPicker("Second field", keyPath: \.trailingCorner)
              }
              .fixedSize()
            }
          }
          .disabled(preferences.gridOverlays.metadataVisibility == .off)
          SettingsRowDivider()
          SettingsRow("Fill grid footprints", subtitle: "Turn off to keep each image's aspect ratio.") {
            Toggle("Fill grid footprints", isOn: fillGridBinding)
              .settingsSwitch()
          }
        }
      }

      SettingsSection(
        "Source tags",
        note: "Marks images imported from PicGo or found in your bucket. Pinax's own uploads are never marked."
      ) {
        SettingsGroup {
          SourceTagCards(selection: overlayBinding(\.sourceTagStyle))
        }
      }

      // The one order View ▸ Sort By, the jump bar and the
      // table headers write, through the same store.
      SettingsSection("Sort") {
        SettingsGroup {
          SettingsRow("Sort by") {
            SettingsMenuPicker("Sort by", selection: $preferences.gallerySort.field) {
              ForEach(AssetSort.Field.menuCases, id: \.self) { field in
                Text(SortMenuItems.title(field)).tag(field)
              }
            } label: {
              Text(SortMenuItems.title(preferences.gallerySort.field))
            }
            SettingsMenuPicker("Order", selection: $preferences.gallerySort.direction) {
              Text("Ascending").tag(AssetSort.Direction.ascending)
              Text("Descending").tag(AssetSort.Direction.descending)
            } label: {
              Text(preferences.gallerySort.direction == .ascending ? "Ascending" : "Descending")
            }
          }
        }
      }
    }
  }

  private func overlayBinding<Value>(
    _ keyPath: WritableKeyPath<GridOverlayOptions, Value>
  ) -> Binding<Value> {
    Binding(
      get: { preferences.gridOverlays[keyPath: keyPath] },
      set: { preferences.gridOverlays[keyPath: keyPath] = $0 })
  }

  private var fillGridBinding: Binding<Bool> {
    Binding(
      get: { preferences.gridThumbnailSizing == .fillGrid },
      set: { preferences.gridThumbnailSizing = $0 ? .fillGrid : .originalAspect })
  }

  private func cornerPicker(
    _ title: String,
    keyPath: WritableKeyPath<GridOverlayOptions, GridOverlayOptions.CornerField>
  ) -> some View {
    SettingsMenuPicker(title, selection: overlayBinding(keyPath)) {
      ForEach(GridOverlayOptions.CornerField.allCases) { field in
        Text(field.label).tag(field)
      }
    } label: {
      Text(preferences.gridOverlays[keyPath: keyPath].label)
    }
  }
}

/// The grid's own cell, selected, for one fixed PicGo image —
/// so the scrim, the caption lines and the source tag are what the
/// gallery draws with the same options.
struct GalleryPreview: View {
  let overlays: GridOverlayOptions
  let sizing: GridThumbnailSizing

  var body: some View {
    AssetGridCell(
      row: Self.row, cache: Self.cache, overlays: overlays, thumbnailSizing: sizing,
      isSelected: true, tier: .medium)
      .frame(width: Metrics.previewCellWidth)
      .allowsHitTesting(false)
      .padding(Metrics.previewPadding)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .bottomTrailing) {
        Text("Preview")
          .pinaxSettingsRowSubtitle()
          .padding(.trailing, Metrics.previewLabelTrailing)
          .padding(.bottom, Metrics.previewLabelBottom)
      }
      .background(
        PinaxPalette.Settings.previewGround,
        in: UnevenRoundedRectangle(
          topLeadingRadius: Metrics.groupRadius, topTrailingRadius: Metrics.groupRadius,
          style: .continuous))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Thumbnail preview")
  }

  /// A 1.2 MB PNG from PicGo, uploaded Jun 3.
  static let row = GalleryModel.Row(
    CatalogAssetItem(
      asset: Asset(
        id: -1, sha256: "pinax-settings-preview", backendID: 0, key: "photo.png",
        byteSize: 1_200_000, width: 1200, height: 1200, mime: "image/png",
        originalFilename: "photo.png", meta: #"{"imported_from":"picgo"}"#,
        uploadedAt: "2026-06-03T10:00:00Z", createdAt: "2026-06-03T10:00:00Z",
        updatedAt: "2026-06-03T10:00:00Z"),
      backend: Backend(
        id: 0, slug: "preview", kind: "s3", endpoint: "", bucket: "",
        urlPrefix: "https://preview.invalid", keychainRef: "",
        createdAt: "2026-06-03T10:00:00Z", updatedAt: "2026-06-03T10:00:00Z")))

  /// A cache of its own in the temporary folder, holding only the sample
  /// image, which never downloads.
  static let cache: ThumbnailCache = {
    let cache = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinax-settings-preview", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let request = ThumbnailRequest(
      sha256: row.item.asset.sha256, sourceURL: URL(string: row.item.url) ?? URL(fileURLWithPath: "/"))
    let file = cache.fileURL(for: request)
    if !FileManager.default.fileExists(atPath: file.path), let image = sampleImage() {
      try? FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let destination = CGImageDestinationCreateWithURL(
        file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
      {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
      }
    }
    return cache
  }()

  /// A diagonal gradient, top left to bottom right.
  private static func sampleImage() -> CGImage? {
    let side = 256
    guard
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    let stops = PinaxPalette.Settings.previewImageStops
    guard
      let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: stops.map(\.color.nsColor.cgColor) as CFArray,
        locations: stops.map(\.location))
    else { return nil }
    // CG's origin is the bottom left: top left is (0, side).
    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])
    return context.makeImage()
  }
}

/// The five source tag styles as cards, each its sample over its
/// name; the chosen one ringed in the system accent.
struct SourceTagCards: View {
  @Binding var selection: SourceTagStyle

  var body: some View {
    HStack(alignment: .top, spacing: Metrics.sourceCardSpacing) {
      ForEach(SourceTagStyle.allCases) { style in
        card(style)
      }
    }
    .padding(Metrics.sourceCardsPadding)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Source tag style")
  }

  private func card(_ style: SourceTagStyle) -> some View {
    let chosen = style == selection
    let shape = RoundedRectangle(cornerRadius: Metrics.sourceCardRadius, style: .continuous)
    return Button {
      selection = style
    } label: {
      VStack(spacing: Metrics.sourceCardNameSpacing) {
        SourceTagSample(style: style)
          .lineLimit(1)
          .frame(maxWidth: .infinity, minHeight: Metrics.sourceCardSampleHeight)
          .background(
            chosen ? PinaxPalette.Settings.chosenCardGround : PinaxPalette.Settings.cardSample,
            in: shape)
          .overlay(
            shape.strokeBorder(
              chosen ? PinaxPalette.Settings.chosenCard : PinaxPalette.Settings.cardRing,
              lineWidth: chosen ? Metrics.sourceCardSelectedRingWidth : Metrics.sourceCardRingWidth))
        Text(style.label)
          .pinaxSettingsCardName(chosen: chosen)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(style.label)
    .accessibilityAddTraits(chosen ? .isSelected : [])
  }
}

/// A small preview of one source-tag style, drawn by the same pure function
/// the grid cell uses, for a PicGo image at the large tier.
struct SourceTagSample: View {
  let style: SourceTagStyle

  var body: some View {
    let caption = SourceCaption.make(
      style: style, source: .picgo, tier: .large, showsFilename: true)
    HStack(spacing: DesignMetrics.spacing.xs) {
      switch caption?.placement {
      case .dateLine:
        Text("Jun 3")
        ColorSquare(
          size: .caption, color: caption?.tint.color ?? .secondary,
          content: .symbol(caption?.icon ?? ""))
      case .pill:
        HStack(spacing: DesignMetrics.spacing.xs) {
          Image(systemName: caption?.icon ?? "").foregroundStyle(caption?.tint.color ?? .secondary)
          Text(caption?.text ?? "")
        }
        .padding(.horizontal, DesignMetrics.spacing.xs)
        .background(.quaternary, in: Capsule())
      case .dot:
        Circle().fill(caption?.tint.color ?? .secondary)
          .frame(width: DesignMetrics.spacing.xs * 2, height: DesignMetrics.spacing.xs * 2)
        Text(caption?.text ?? "")
      case .beforeFilename, .beforeDate:
        Image(systemName: caption?.icon ?? "").foregroundStyle(caption?.tint.color ?? .secondary)
        Text("photo.png")
      case nil:
        Text("Jun 3")
      }
    }
    .pinaxCaption()
    .accessibilityHidden(true)
  }
}

extension View {
  /// A row's switch: the system switch, small, on in the main
  /// window's teal, its title kept for accessibility only.
  fileprivate func settingsSwitch() -> some View {
    toggleStyle(.switch)
      .tint(PinaxPalette.accentFill)
      .controlSize(.small)
      .labelsHidden()
  }
}
