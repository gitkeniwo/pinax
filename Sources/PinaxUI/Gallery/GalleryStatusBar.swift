import SwiftUI

/// The status bar pinned to the bottom of the centre column
/// (Xcode's bottom bar is the reference). It spans the centre
/// column only — not the sidebar, not the inspector — and describes the
/// surface it sits under, or says nothing.
///
/// Constraints the shape exists to hold:
/// * Fixed height, set explicitly. A bar whose height depends on its
///   contents re-lays-out the grid above it on every page load, which
///   flickers. Every number is `monospacedDigit()` so widths
///   stay put too.
/// * Left: the surface's count, then the selection — Finder's "1,204
///   assets · 3 selected · 24.1 MB" (the window subtitle names the current
///   project); right: background activity. With both sides empty the bar
///   keeps its height — it never collapses. The grid controls live on the
///   toolbar.
/// * Honesty: the asset count is a real `COUNT` over the same query
///   builder (`GalleryModel.totalCount`), never `rows.count` — the pages
///   hold at most 120 rows and would understate on a long catalog. When the count is unavailable the bar
///   says what it actually knows: "N loaded".
/// * The report surfaces (Orphans, Externals, Usage) show no count and no
///   asset-filter claim on the left: their headers carry their own
///   numbers. A selection on the orphan grid still shows.
///
/// `leadingText` is the left side's one line, so the honesty properties are
/// asserted on the real string instead of OCR-ing a bitmap.
struct GalleryStatusBar: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      if model.shownSelection == .externals {
        // The page's own selection, as Orphans'.
        ExternalSelectionStatus(model: model.externals)
      } else if let leadingText {
        statusText(leadingText)
      }
      Spacer(minLength: DesignMetrics.spacing.m)
      // Every background activity in one slot —
      // the newest, `+N` for the rest; a result stays until the next one.
      // The page's own loading keeps its bare spinner beside it.
      if model.showsLoadingActivity, model.activity.current?.isRunning != true {
        ProgressView()
          .controlSize(.small)
          .help("Loading")
      }
      ActivitySlotView(center: model.activity)
      Divider()
        .frame(height: 16)
      ActivityPanelToggle(model: model)
    }
    .padding(.horizontal, ChromeMetrics.horizontalPadding)
    .frame(height: ChromeMetrics.barHeight, alignment: .center)
    .frame(maxWidth: .infinity)
    .background(Self.background(on: model.shownSelection))
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("gallery-status-bar")
  }

  /// The bar's ground: Overview's grouped page continues under it, so an
  /// empty bar there is not a white strip below a grey page.
  static func usesPageGround(on selection: SidebarSelection) -> Bool {
    selection == .overview
  }

  static func background(on selection: SidebarSelection) -> AnyShapeStyle {
    usesPageGround(on: selection) ? AnyShapeStyle(OverviewPalette.page) : AnyShapeStyle(.bar)
  }

  /// The left side: the asset count, then what is selected.
  var leadingText: String? {
    Self.leadingText(
      count: showsAssetCount
        ? WindowTitle.countSentence(
          totalCount: model.totalCount, unfilteredTotalCount: model.unfilteredTotalCount,
          rowsCount: model.rows.count)
        : "",
      selection: selectionSummary)
  }

  /// "1,204 assets · 3 selected · 24.1 MB", either half alone, or nothing.
  static func leadingText(count: String, selection: String?) -> String? {
    let parts = [count].filter { !$0.isEmpty } + [selection].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var showsAssetCount: Bool {
    switch model.shownSelection {
    case .overview, .orphans, .externals, .usage: return false
    default: return true
    }
  }

  /// What is selected, or nothing. Two or more: the count and the loaded
  /// members' total bytes. Empty on the surfaces that list references.
  var selectionSummary: String? {
    if model.shownSelection == .externals { return model.externals.selectionStatusText }
    guard model.showsAssetSelection else { return nil }
    let count = model.selectedIDs.count
    if count > 1 {
      return "\(count) selected · \(PinaxFormat.fileSize(model.selectedByteTotal))"
    }
    guard let details = model.selectedDetails else { return nil }
    return "1 selected · \(PinaxFormat.fileSize(details.item.asset.byteSize))"
  }

  /// The right side's sentence: the activity slot's current item.
  var activityText: String? {
    model.activity.current?.text
  }

  private func statusText(_ text: String) -> some View {
    ChromeMetrics.text(text)
  }
}
