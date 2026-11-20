import SwiftUI

/// A month section's header in the grouped grid: the month
/// bold, the year tertiary at the same size, the section's count in a
/// capsule right after the year, not pushed to the row's far end. Two
/// states, the text fixed across both:
///
/// - **At rest** it is bare text in the content, no plate, its leading edge
///   on the first column's (the header lays out in the grid's padded frame
///   with no inset of its own).
/// - **Pinned** it gains a plate of the bar material with a divider along
///   its bottom edge, so the cells scrolling under it stay out of the text.
///   The plate reaches back over the grid's inset on both sides, so it
///   spans the scroll area edge to edge.
///
/// Pinned means the header's top has reached the scroll area's top: the
/// grid's named scroll space starts at the visible region (see
/// `AssetGridView.scrollSpace`), and a pinned header is held at 0 there —
/// or pushed above it by the next month's header. The plate switches with
/// no animation; the text never moves, so
/// there is no jump to hide.
/// The height is a minimum, not a fixed value, so a larger accessibility
/// text size grows the header instead of clipping it.
struct MonthSectionHeader: View {
  let month: String
  let year: String
  let count: Int
  /// The copy `StickyMonthHeader` draws over the scroll view is always
  /// pinned; the in-flow headers decide from where they sit.
  var alwaysPinned = false

  /// How far the plate reaches past the header on each side: the grid's
  /// own padding (`AssetGridView` pads its layer by `gridInset / 2`).
  static let plateBleed = AssetGridView.gridInset / 2

  /// Whether a header whose top sits at `minY` in the grid's scroll space
  /// is pinned. Half a point of slack for pixel rounding.
  static func isPinned(minY: CGFloat) -> Bool {
    minY < 0.5
  }

  /// "· 8", how the table's month rows end (the grid's header puts the
  /// count in a capsule instead).
  static func countText(_ count: Int) -> String {
    "· \(count)"
  }

  var body: some View {
    HStack(alignment: .center, spacing: DesignMetrics.spacing.s) {
      HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
        Text(month)
          .pinaxMonthTitle()
        Text(year)
          .pinaxMonthYear()
      }
      CountCapsule(count)
        .help("Assets in this month")
    }
    .pinnedSectionPlate(alwaysPinned: alwaysPinned)
  }
}

extension View {
  /// A pinned section header's two states (`MonthSectionHeader`): bare
  /// text at rest, the bar plate with its bottom divider once pinned, the
  /// plate bleeding over the grid's inset. For a header in a grid whose
  /// scroll view names `AssetGridView.scrollSpace` and pads by
  /// `AssetGridView.gridInset / 2` — the library's and Externals'.
  func pinnedSectionPlate(alwaysPinned: Bool = false) -> some View {
    frame(
      maxWidth: .infinity, minHeight: DesignMetrics.sectionHeader.height,
      alignment: .leading
    )
    .background {
      GeometryReader { geo in
        if alwaysPinned
          || MonthSectionHeader.isPinned(minY: geo.frame(in: .named(AssetGridView.scrollSpace)).minY)
        {
          Color.clear
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
      }
      .padding(.horizontal, -MonthSectionHeader.plateBleed)
    }
  }
}

/// Which month header is pinned, from where the
/// in-flow headers sit. The headers report on every scroll frame; the two
/// observed values change only when a header crosses the top edge or pushes
/// the pinned one, so only `StickyMonthHeader` redraws, and only then —
/// never the grid.
@MainActor @Observable
final class StickyMonthHeaderState {
  /// The month whose header has scrolled to or above the top; nil while
  /// the first header still rests below it.
  private(set) var pinnedMonth: String?
  /// How far the next month's header pushes the pinned one up (≤ 0).
  private(set) var push: CGFloat = 0
  @ObservationIgnored private var minYs: [String: CGFloat] = [:]

  func report(month: String, minY: CGFloat) {
    minYs[month] = minY
    update()
  }

  /// A header that left the hierarchy (its month filtered away, the layer
  /// rebuilt) no longer competes for the top.
  func forget(month: String) {
    minYs[month] = nil
    update()
  }

  private func update() {
    // Pinned: the lowest header at or above the top. Next: the highest one
    // below it; once its top is inside the header's height it pushes.
    let pinned = minYs.filter { MonthSectionHeader.isPinned(minY: $0.value) }
      .max { $0.value < $1.value }?.key
    var nextPush: CGFloat = 0
    if pinned != nil,
      let next = minYs.values.filter({ !MonthSectionHeader.isPinned(minY: $0) }).min(),
      next < DesignMetrics.sectionHeader.height
    {
      nextPush = next - DesignMetrics.sectionHeader.height
    }
    if pinned != pinnedMonth { pinnedMonth = pinned }
    if nextPush != push { push = nextPush }
  }
}

/// The pinned month header, drawn over the grid's scroll view with the
/// pinned plate: the month stack is a plain `VStack`, which pins no
/// section headers of its own.
struct StickyMonthHeader: View {
  let state: StickyMonthHeaderState
  @ObservedObject var model: GalleryModel

  var body: some View {
    if let month = state.pinnedMonth,
      let group = model.groupedRows.first(where: { $0.month == month })
    {
      GridSectionHeader(model: model, key: group.month, loaded: group.rows.count, alwaysPinned: true)
        .offset(y: state.push)
    }
  }
}

/// A grid section's header: a month's, or on Usage ▸ Images the file's
/// strip. Every place a header is drawn — in
/// flow, the pinned copy, the frozen layer — goes through here.
struct GridSectionHeader: View {
  @ObservedObject var model: GalleryModel
  let key: String
  let loaded: Int
  var alwaysPinned = false

  var body: some View {
    if model.showsUsageFileSections {
      if let file = model.usageBrowser?.files.first(where: { $0.id == key }) {
        UsageFileSectionHeader(model: model, file: file)
      }
    } else {
      let title = PinaxFormat.monthTitle(key)
      MonthSectionHeader(
        month: title.month, year: title.year,
        count: model.monthHeaderCount(key, loaded: loaded),
        alwaysPinned: alwaysPinned)
    }
  }
}
