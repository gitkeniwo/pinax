import SwiftUI

/// The navigator switcher: Xcode's row of bare icon buttons above
/// the sidebar's List, with a `Divider()` above and below it.
///
/// Standard `Button`s and the system `Divider()` — nothing here is drawn
/// by hand. A segmented `Picker` is the obvious standard control for
/// "one of a small fixed set", but its per-segment capsules are too heavy
/// inside a 180pt sidebar. There is no
/// standard control for "a row of tinted icon buttons with no chrome", so
/// only the arrangement is ours: the selected state is a foreground style
/// and nothing else (no plate, capsule or underline), and the buttons divide
/// the width with `frame(maxWidth: .infinity)` rather than a written-down
/// spacing.
///
/// `.plain`, not `.borderless`: rendered at 180pt wide, `.borderless` paints every icon
/// the same colour — rgba(255,204,0) in all four quarters, selected and
/// unselected alike — because the style tints the label itself and covers
/// the `foregroundStyle`. `.plain` leaves it alone: the selected icon comes
/// out rgba(0,109,228) opaque and the other three stay under the secondary
/// style's alpha.
///
/// Buttons give up the segmented picker's keyboard traversal;
/// `.accessibilityAddTraits(.isSelected)` restores the state to VoiceOver,
/// and the ⌘1–⌘4 menu shortcuts switch navigators from the keyboard.
struct SidebarNavigatorPicker: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    HStack(spacing: DesignMetrics.navigatorSwitcher.spacing) {
      ForEach(SidebarNavigator.allCases, id: \.self) { navigator in
        Button {
          model.navigator = navigator
        } label: {
          Image(systemName: navigator.systemImage)
            // The selected quarter on the accent's soft
            // plate in accent ink, the others secondary.
            .pinaxSoftPlate(navigator == model.navigator)
            // The whole quarter is the target, not just the glyph: with
            // no fill behind it, hit testing otherwise stops at the
            // symbol's own bounds and clicking beside it does nothing
            // (measured). An invisible hit region, not chrome.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(navigator.title)
        .accessibilityLabel(navigator.title)
        .accessibilityAddTraits(navigator == model.navigator ? .isSelected : [])
      }
    }
    // The jump bar's height, dividers overlaid as it overlays its own, so
    // the two rows' edges line up across the column split.
    .padding(.horizontal, DesignMetrics.navigatorSwitcher.horizontalPadding)
    .frame(height: ChromeMetrics.stripHeight)
    .overlay(alignment: .top) { Divider() }
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityIdentifier("sidebar-navigator-picker")
  }
}
