import SwiftUI

/// The grid's two toolbar controls, after the window title (Photos'
/// "square / original ratio" switch and zoom slider). The slider is
/// Photos' too: continuous with no tick marks, the grid following
/// the nearest `GridZoom` rung while dragging (a rung change is a
/// relayout, never a query), and the knob settling on that rung on release.
/// Its fill from the − end is the accent; the track itself is the system
/// slider's. The caller disables the group in place on report surfaces; it never moves.
///
/// In table mode the −, slider and + drive the table's row
/// height — the same rung View ▸ Make Bigger / Make Smaller moves, one
/// truth — and the aspect switch, a grid-only setting, grays in place.
struct GridToolbarControls: View {
  @ObservedObject var model: GalleryModel

  static let aspectSymbols = [
    "rectangle.arrowtriangle.2.inward", "rectangle.arrowtriangle.2.outward",
  ]

  var body: some View {
    // One control group: the aspect
    // switch, a rule, then the size controls; the slider's fill is the
    // accent.
    ControlGroupCapsule {
      Button {
        model.toggleGridThumbnailSizing()
      } label: {
        Image(
          systemName: model.gridThumbnailSizing == .fillGrid
            ? Self.aspectSymbols[1] : Self.aspectSymbols[0])
      }
      .buttonStyle(.borderless)
      .help(
        model.gridThumbnailSizing == .fillGrid
          ? "Show each image at its original aspect ratio"
          : "Fill each grid footprint")
      .accessibilityIdentifier("grid-aspect-toggle")
      .disabled(model.viewMode != .grid || model.shownSelection == .externals)

      ControlGroupDivider()

      Button { model.makeSmaller() } label: {
        Image(systemName: "minus")
      }
      .buttonStyle(.borderless)
      .disabled(!model.canMakeSmaller)
      .help(ladder == .table ? "Shorter rows" : "Smaller thumbnails")

      Slider(value: zoomBinding, in: 0...Double(rungCount - 1)) { editing in
        isDragging = editing
        if !editing { dragPosition = nil }
      }
      .tint(PinaxPalette.accent)
      .frame(width: DesignMetrics.spacing.xl * 4)
      .accessibilityLabel("Thumbnail size")

      Button { model.makeBigger() } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .disabled(!model.canMakeBigger)
      .help(ladder == .table ? "Taller rows" : "Larger thumbnails")
    }
  }

  /// Where the pointer holds the knob mid-drag; `nil` otherwise, so the
  /// knob shows the model's rung — which is what makes the release snap.
  /// Only a drag writes it: a keyboard or accessibility step lands on a
  /// rung directly.
  @State private var isDragging = false
  @State private var dragPosition: Double?

  /// The current mode's ladder length: grid columns, or table row heights.
  private var rungCount: Int {
    ladder == .table ? DesignMetrics.table.rowHeights.count : GridZoom.columns.count
  }

  /// The surface's ladder (`GalleryModel.zoomLadder`); Externals' list has
  /// none and the caller disables the group, so the grid's stands in.
  private var ladder: GalleryModel.ViewMode { model.zoomLadder ?? .grid }

  private var zoomBinding: Binding<Double> {
    Binding(
      get: {
        if let dragPosition { return dragPosition }
        switch ladder {
        case .grid: return GridZoom.sliderPosition(for: model.gridColumns)
        case .table: return Double(model.tableRowRung ?? 0)
        }
      },
      set: {
        if isDragging { dragPosition = $0 }
        switch ladder {
        case .grid:
          model.setGridColumns(GridZoom.columns(atSliderPosition: $0))
        case .table:
          let heights = DesignMetrics.table.rowHeights
          model.setTableRowHeight(heights[min(max(Int($0.rounded()), 0), heights.count - 1)])
        }
      })
  }
}
