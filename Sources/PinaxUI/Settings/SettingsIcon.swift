import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// A settings page's icon, drawn as the main window's sidebar draws its
/// rows' (`ColorSquare`): a white filled SF Symbol on a flat square of the
/// page's colour — the darker stop of its gradient. Follows the
/// appearance.
struct SettingsIcon: View {
  let kind: SettingsTab
  let size: CGFloat
  /// A selected sidebar row's icon wears the main sidebar's 1 pt white rim.
  var rimmed = false

  var body: some View {
    let glyph = size * Metrics.iconGlyphRatio * Metrics.iconGlyphExtent
    RoundedRectangle(cornerRadius: size * Metrics.iconCornerRatio, style: .continuous)
      .fill(PinaxPalette.settingsIconColors(kind).bottom)
      .overlay {
        Image(systemName: kind.symbolName)
          .resizable()
          .scaledToFit()
          .fontWeight(.semibold)
          .foregroundStyle(.white)
          .frame(width: glyph, height: glyph)
      }
      .overlay {
        if rimmed {
          RoundedRectangle(cornerRadius: size * Metrics.iconCornerRatio, style: .continuous)
            .strokeBorder(
              .white.opacity(DesignMetrics.sidebarRow.selectedRimOpacity),
              lineWidth: DesignMetrics.sidebarRow.selectedRimWidth)
            .padding(-DesignMetrics.sidebarRow.selectedRimWidth)
        }
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

extension SettingsTab {
  /// Filled symbols, as the main sidebar's; Projects carries a gear so it
  /// does not read as a Catalog folder there.
  var symbolName: String {
    switch self {
    case .general: "gearshape.fill"
    case .appearance: "circle.lefthalf.filled"
    case .dropZone: "tray.and.arrow.down.fill"
    case .gallery: "square.grid.2x2.fill"
    case .projects: "folder.fill.badge.gearshape"
    case .backends: "externaldrive.fill"
    case .maintenance: "checkmark.shield.fill"
    }
  }
}
