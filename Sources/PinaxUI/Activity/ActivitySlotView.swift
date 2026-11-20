import SwiftUI

/// The status bar's activity slot: one activity, newest first, and `+N` for the others still
/// running. Its own view so the bar redraws on the center's changes.
struct ActivitySlotView: View {
  @ObservedObject var center: ActivityCenter

  static let progressWidth: CGFloat = 110

  var body: some View {
    if let item = center.current {
      HStack(spacing: DesignMetrics.spacing.s) {
        glyph(item.phase)
        // Idle's "· 2 min ago" moves on with the minute.
        TimelineView(.everyMinute) { context in
          let text = center.displayText(now: context.date) ?? item.text
          Text(text)
            .font(.caption)
            .foregroundStyle(item.phase == .finished ? .secondary : .primary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
        }
        if case let .running(fraction?, _) = item.phase {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .controlSize(.small)
            .frame(width: Self.progressWidth)
        }
        if let link = item.shownLink {
          Button(link.title) { center.perform(link) }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PinaxPalette.accent)
            .lineLimit(1)
            .fixedSize()
        }
        if let cancel = item.cancelHelp {
          Button {
            center.cancelCurrent()
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help(cancel)
          .accessibilityLabel(cancel)
        }
        if let badge = center.badge {
          Text(badge.text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .background(Capsule().fill(.quaternary))
            .fixedSize()
            .help(badge.help)
        }
      }
    }
  }

  @ViewBuilder private func glyph(_ phase: ActivityItem.Phase) -> some View {
    switch phase {
    case .running:
      ProgressView().controlSize(.small)
    case .finished:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .ready:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(PinaxPalette.accent)
    case .needsReview:
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
    case .warnings:
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    }
  }
}

/// The panel switch: Xcode's debug-area button, accent while the
/// panel is open, grey while closed.
struct ActivityPanelToggle: View {
  @ObservedObject var model: GalleryModel

  static let symbol = "rectangle.bottomthird.inset.filled"

  var body: some View {
    Button {
      withAnimation(ActivityPanelView.animation) { model.toggleActivityPanel() }
    } label: {
      Image(systemName: Self.symbol)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(model.isActivityPanelOpen ? AnyShapeStyle(PinaxPalette.accent) : AnyShapeStyle(.secondary))
    .help(model.isActivityPanelOpen ? "Hide the activity panel (⇧⌘Y)" : "Show the activity panel (⇧⌘Y)")
    .accessibilityLabel(model.isActivityPanelOpen ? "Hide Activity Panel" : "Show Activity Panel")
  }
}
