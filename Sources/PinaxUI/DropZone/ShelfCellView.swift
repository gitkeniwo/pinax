import AppKit
import CatalogCore
import SwiftUI

/// One dropped item on the Shelf: a large status thumbnail, then the name, then
/// one status word and the project token. Under the pointer the actions float
/// on a glass bar inside the image's bottom edge, clear of the status; the full
/// words are in the tooltips.
struct ShelfCellView: View {
  let card: DropZoneModel.UploadCard
  @ObservedObject var model: DropZoneModel
  @ObservedObject var state: DropZoneViewState
  @Environment(\.colorScheme) private var colorScheme
  @State private var hovered = false

  private var palette: DropZonePalette { .of(colorScheme) }
  private typealias M = DesignMetrics.dropZone

  private var status: DropZoneCardStatus { DropZoneCardStatus(card: card) }

  private var isDone: Bool {
    if case .done = card.phase { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: M.textSpacing) {
      StatusThumbnail(
        card: card, width: nil, height: M.shelfThumbnail, radius: M.shelfThumbnailRadius,
        knob: M.knobShelf, reducesMotion: state.reducesMotion,
        retry: ResultCardView.retryAction(card.id, model)
      )
      .onContinuousHover(coordinateSpace: .named(DropZoneView.space)) { phase in
        state.thumbnailHover(
          phase, cardID: card.id,
          imageSize: card.thumbnail.map { CGSize(width: $0.width, height: $0.height) })
      }
      .overlay(alignment: .bottom) {
        if hovered { actionBar }
      }
      .overlay(alignment: .topTrailing) {
        if model.reviewBatch.contains(card.id) { reviewSwitch }
      }
      .dropZoneLayout(.thumbnail, card: card.id)
      Text(card.filename)
        .fontWeight(.semibold)
        .foregroundStyle(palette.primary)
        .pinaxSecondary()
        .lineLimit(1)
        .truncationMode(.middle)
        .help(card.fileURL.path)
        .dropZoneLayout(.filename, card: card.id)
      HStack(spacing: M.tokenGap + M.tokenGap) {
        statusWord
          .dropZoneLayout(.statusText, card: card.id)
        DropZoneProjectToken(card: card, model: model, canMove: isDone)
          .dropZoneLayout(.projectToken, card: card.id)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu {
      DropZoneCardContextMenu(
        card: card, model: model, actions: ResultCardView.actions(card.id, model),
        retry: ResultCardView.retryAction(card.id, model), canMove: isDone)
    }
    .dropZoneLayout(.card, card: card.id)
  }

  /// One word; a refused move or a failure in the failure hue,
  /// with the whole message in the tooltip.
  @ViewBuilder
  private var statusWord: some View {
    if let moveError = card.moveError {
      Text("Not moved")
        .foregroundStyle(palette.failed)
        .pinaxCaption()
        .help(moveError)
        .dropZoneLayout(.moveError, card: card.id)
    } else if status.kind == .failed {
      Text(status.shelfText)
        .foregroundStyle(palette.failed)
        .pinaxCaption()
        .help(status.help ?? "")
    } else if status.kind == .review {
      status.shelfWords(saving: palette.done, unsent: palette.tertiary)
        .foregroundStyle(palette.secondary)
        .pinaxCaption()
        .monospacedDigit()
        .lineLimit(1)
        .help(status.shelfHelp ?? "")
    } else if status.kind == .uploaded {
      TimelineView(.periodic(from: .now, by: 30)) { context in
        let current = DropZoneCardStatus(card: card, now: context.date)
        // The sizes do not fit a cell: they are in the tooltip. Beside a
        // long project name even the time gives way to the percentage.
        ViewThatFits(in: .horizontal) {
          current.shelfWords(saving: palette.done).lineLimit(1)
          current.shelfWords(saving: palette.done, short: true).lineLimit(1)
        }
        .foregroundStyle(palette.secondary)
        .pinaxCaption()
        .help(current.shelfHelp ?? "")
      }
    } else {
      Text(status.shelfText)
        .foregroundStyle(palette.secondary)
        .pinaxCaption()
        .help(status.shelfHelp ?? "")
    }
  }

  /// In review, always shown: the switch on a small capsule of the hover
  /// bar's dark glass, inside the image's top-right corner.
  private var reviewSwitch: some View {
    DropZoneReviewSwitch(card: card, model: model, showsLabel: false)
      .padding(M.reviewSwitchPadding)
      .background {
        Capsule().fill(.ultraThinMaterial)
          .overlay(Capsule().fill(Color.black.opacity(M.shelfBarScrim)))
      }
      .environment(\.colorScheme, .dark)
      .padding(M.reviewSwitchInset)
  }

  /// The hover bar: the List row's actions, white on a dark glass scrim
  /// inside the image's bottom edge. Moving is the token's (and the context
  /// menu's), as in List.
  private var actionBar: some View {
    HStack(spacing: M.iconButtonGap) {
      ForEach(ResultCardView.actions(card.id, model)) { action in
        Button(action: action.perform) {
          Image(systemName: action.symbol)
        }
        .buttonStyle(
          DropZoneIconButtonStyle(
            width: M.shelfBarButtonWidth, height: M.shelfBarButtonHeight, onImage: true))
        .help(action.help)
        .accessibilityLabel(action.help)
      }
    }
    .disabled(!isDone)
    .padding(M.shelfBarPadding)
    .frame(maxWidth: .infinity)
    .background {
      let shape = RoundedRectangle(cornerRadius: M.shelfBarRadius, style: .continuous)
      shape.fill(.ultraThinMaterial)
        .overlay(shape.fill(Color.black.opacity(M.shelfBarScrim)))
    }
    .environment(\.colorScheme, .dark)
    .padding(M.shelfBarInset)
    .dropZoneLayout(.shelfBar, card: card.id)
  }
}
