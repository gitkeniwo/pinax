import CatalogCore
import SwiftUI

/// Shared icon rendering for every surface that presents a sidebar
/// destination outside the sidebar itself — the jump bar, the project
/// picker's rows: the entry's symbol in its category's
/// hue. The sidebar draws the same hue as a square (`SidebarEntrySquare`).
struct SidebarEntryIcon: View {
  let systemImage: String
  let tint: SidebarIconTint

  init(entry: SidebarEntry) {
    self.init(systemImage: entry.systemImage, tint: entry.iconTint)
  }

  init(systemImage: String, tint: SidebarIconTint) {
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    Image(systemName: systemImage)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(tint.color)
  }
}

/// A sidebar row's icon: the entry's symbol in
/// white on a square of its category's colour — 20 pt, or 18 pt for a
/// Catalog folder — rimmed in white on the selected row.
/// A closed row that opens stacks a second
/// square of its colour behind, 3 right and 3 up, parted from the front by
/// a ring of the sidebar's ground; an open Catalog folder shows `folder`
/// (SF Symbols has no open folder) and no stack.
struct SidebarEntrySquare: View {
  enum State {
    case plain, stacked, open
  }

  let entry: SidebarEntry
  let isSelected: Bool
  var state: State = .plain
  @Environment(\.colorScheme) private var colorScheme

  static func size(for tint: SidebarIconTint) -> ColorSquare.Size {
    // A Catalog root takes its folders' square, so the tree lines its
    // children draw meet its middle.
    tint == .catalog || tint == .backendRoot ? .folder : .sidebar
  }

  /// The open Catalog folder's symbol: SF Symbols has no open folder, so
  /// the closest one.
  static let openFolderSymbol = "folder"
  /// A Catalog root open: the cloud drawn in outline, as the folder is.
  static let openRootSymbol = "cloud"

  static func stackOpacity(isSelected: Bool, dark: Bool) -> Double {
    let row = DesignMetrics.sidebarRow.self
    if isSelected { return row.stackOpacitySelected }
    return dark ? row.stackOpacityDark : row.stackOpacityLight
  }

  var body: some View {
    let size = Self.size(for: entry.iconTint)
    let row = DesignMetrics.sidebarRow.self
    let symbol =
      // A project and its source folders open as
      // a Catalog folder does.
      state == .open
        && [.catalog, .project, .projectSource].contains(entry.iconTint)
        && entry.systemImage == "folder.fill"
      ? Self.openFolderSymbol
      : state == .open && entry.iconTint == .backendRoot ? Self.openRootSymbol : entry.systemImage
    PinaxStackedSquare(
      side: size.side, radius: size.radius,
      backColor: isSelected ? .white : entry.iconTint.color,
      showsStack: state == .stacked,
      stackOpacity: Self.stackOpacity(isSelected: isSelected, dark: colorScheme == .dark),
      ringColor: PinaxPalette.sidebarGround,
      ringWidth: isSelected ? 0 : row.stackRing,
      offset: row.stackOffset
    ) {
      ColorSquare(
        size: size, color: entry.iconTint.color, content: .symbol(symbol), rimmed: isSelected)
    }
  }
}
