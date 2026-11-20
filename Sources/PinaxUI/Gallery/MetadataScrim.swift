import Observation
import SwiftUI

/// The grid's one hovered cell.
///
/// Per-cell hover state goes wrong: a tracking area moved by a zoom-step
/// relayout never sees its exit, and many cells stay "hovered".
/// Here the grid holds one ID, so at most one cell can ever read as
/// hovered. The grid tracks the pointer once for all its cells and names
/// the cell under it from the cell frames it already reports
/// (`pointer(at:in:)`); it clears the ID when the pointer leaves and on
/// every column change (`AssetGridView`). A tracking area per cell would
/// also break the grid's scroll restore (measured).
///
/// Every change runs in a transaction that disables animations: the
/// scrim appears and disappears in one frame.
@MainActor @Observable
final class GridHoverState {
  private(set) var hoveredID: GalleryModel.Row.ID?

  /// The transaction every hover change runs in.
  static var instant: Transaction {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    return transaction
  }

  /// The grid's pointer report: the cell whose frame holds `point` (both
  /// in the grid's scroll space) is hovered; over a gap or a header, none.
  func pointer(at point: CGPoint, in frames: [GalleryModel.Row.ID: CGRect]) {
    let id = frames.first { $0.value.contains(point) }?.key
    guard id != hoveredID else { return }
    withTransaction(Self.instant) { hoveredID = id }
  }

  func clear() {
    guard hoveredID != nil else { return }
    withTransaction(Self.instant) { hoveredID = nil }
  }
}

/// The merged metadata scrim at a thumbnail's bottom left.
/// Its own view, so a hover change re-evaluates only the scrims, not the
/// cells. The narrow text (one field) stands in when the footprint is too
/// narrow for both.
struct MetadataScrim: View {
  let id: GalleryModel.Row.ID
  let visibility: GridOverlayOptions.MetadataVisibility
  let isSelected: Bool
  let hover: GridHoverState?
  let full: Text?
  let narrow: Text?

  /// Tests only: sees every transaction the scrim's content is updated in,
  /// after the scrim's own animation stop.
  static var transactionProbe: (@MainActor (Transaction) -> Void)?

  var isShown: Bool {
    visibility.showsScrim(hovered: hover?.hoveredID == id, selected: isSelected)
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      if isShown, let full {
        ViewThatFits(in: .horizontal) {
          full.pinaxScrimChip()
          if let narrow { narrow.pinaxScrimChip() }
        }
      }
    }
    .padding(DesignMetrics.scrim.inset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    .allowsHitTesting(false)
    .transaction { Self.transactionProbe?($0) }
    // No implicit animation reaches the scrim, whatever the change
    // that shows it came wrapped in.
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }
}
