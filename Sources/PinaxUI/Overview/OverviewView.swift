import CatalogCore
import Charts
import SwiftUI

/// Reports ▸ Overview: the current project's summary
/// — a hero band, Upload Activity, then the Uploads chart and Composition
/// beside the Library / Usage / Projects lists. Cards on a grey page — the
/// one page exempt from the app's "no cards" rule — each figure with one hue.
///
/// Every click and hover is a closure on the view that draws it, so the
/// tests read them as values (nothing hosted, nothing clicked).
struct OverviewView: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        OverviewContent(model: model, layout: OverviewLayout(pageWidth: proxy.size.width))
          .frame(maxWidth: DesignMetrics.overview.pageMaxWidth)
          .padding(DesignMetrics.spacing.xl)
          .frame(maxWidth: .infinity)
      }
    }
    .background(OverviewPalette.page)
  }
}

/// How the page folds at a width: the window lets the centre
/// column shrink to `GalleryWidthBudget.detailMin`, and nothing on the page
/// may be wider than what it is given.
struct OverviewLayout: Equatable {
  /// The cards' column: the page less its margins, at most `pageMaxWidth`.
  let contentWidth: CGFloat
  /// The hero band's cells to a row: 4, then 2, then 1.
  let heroColumns: Int
  /// The Uploads / Composition column beside the lists, or above them.
  let columnsSideBySide: Bool
  /// The heat map's cell pitch: the card's width over 53 columns, whole
  /// points, held within `heatMinPitch`…`heatMaxPitch`.
  let heatPitch: CGFloat
  /// Too narrow for the minimum pitch: the map scrolls sideways.
  let heatScrolls: Bool

  init(pageWidth: CGFloat) {
    let metrics = DesignMetrics.overview.self
    let width = max(0, min(pageWidth - DesignMetrics.spacing.xl * 2, metrics.pageMaxWidth))
    let gap = DesignMetrics.spacing.m
    contentWidth = width
    heroColumns =
      [4, 2].first { CGFloat($0) * metrics.metricMinWidth + CGFloat($0 - 1) * gap <= width } ?? 1
    columnsSideBySide =
      2 * DesignMetrics.overviewD.columnMinWidth + DesignMetrics.overviewD.columnGap <= width
    let heatRoom = width - 2 * metrics.cardHorizontalPadding - metrics.heatWeekdayWidth
    let fitting = (heatRoom / CGFloat(OverviewModel.heatWeeks)).rounded(.down)
    heatPitch = min(max(fitting, metrics.heatMinPitch), metrics.heatMaxPitch)
    heatScrolls = fitting < metrics.heatMinPitch
  }
}

/// The page, top to bottom, for one layout.
struct OverviewContent: View {
  @ObservedObject var model: GalleryModel
  let layout: OverviewLayout

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      if let overview = model.overview {
        OverviewHeroBand(cells: overview.hero, columns: layout.heroColumns)
        OverviewHeatmapCard(
          heatmap: overview.heatmap,
          pitch: layout.heatPitch,
          scrolls: layout.heatScrolls,
          hoverLine: hoverLine(overview.heatmap),
          hover: { model.overviewHoveredDay = $0 },
          open: { model.openOverviewDay($0) })
        columns(overview)
      } else if let error = model.overviewError {
        ContentUnavailableView("Overview Unavailable", systemImage: "chart.bar.xaxis", description: Text(error))
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
      }
    }
  }

  @ViewBuilder private func columns(_ overview: OverviewModel) -> some View {
    if layout.columnsSideBySide {
      HStack(alignment: .top, spacing: DesignMetrics.overviewD.columnGap) {
        left(overview).frame(maxWidth: .infinity, alignment: .leading)
        right(overview).frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
        left(overview)
        right(overview)
      }
    }
  }

  private func left(_ overview: OverviewModel) -> some View {
    VStack(alignment: .leading, spacing: DesignMetrics.overviewD.sectionGap) {
      OverviewUploadsCard(
        uploads: overview.uploads,
        calendar: model.overviewCalendar,
        choose: { model.setOverviewPeriodKind($0) },
        move: { model.moveOverviewPeriod(by: $0) },
        open: { model.openOverviewDay($0) })
      OverviewCompositionList(rows: overview.composition)
    }
  }

  private func right(_ overview: OverviewModel) -> some View {
    VStack(alignment: .leading, spacing: DesignMetrics.overviewD.sectionGap) {
      OverviewListGroup(title: "Library", rows: overview.library, open: { model.openOverview($0) })
      OverviewListGroup(title: "Usage", rows: overview.usage, open: { model.openOverview($0) })
      if !overview.projects.isEmpty {
        OverviewProjectsList(projects: overview.projects, open: { model.openOverviewProject($0, $1) })
      }
    }
  }

  private func hoverLine(_ heatmap: OverviewModel.Heatmap) -> String? {
    guard let day = model.overviewHoveredDay,
      let cell = heatmap.cells.first(where: { $0.day == day })
    else { return nil }
    return OverviewModel.dayLine(cell.day, count: cell.count, calendar: model.overviewCalendar)
  }
}

/// Upload Activity's card: a hued title, a line at its right end, the
/// content under it.
struct OverviewCard<Trailing: View, Content: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  @ViewBuilder let trailing: Trailing
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
        Label(title, systemImage: systemImage)
          .pinaxOverviewHeading()
          .foregroundStyle(tint)
        Spacer(minLength: DesignMetrics.spacing.s)
        trailing
      }
      content
    }
    .overviewCard()
  }
}

extension View {
  /// A card: the card ground, padded.
  func overviewCard() -> some View {
    padding(.vertical, DesignMetrics.overview.cardVerticalPadding)
      .padding(.horizontal, DesignMetrics.overview.cardHorizontalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overviewGroup()
  }

  /// The card / group ground: corner 10, a 0.5 pt rim.
  func overviewGroup() -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignMetrics.overviewD.cardRadius, style: .continuous)
    return background(OverviewPalette.card, in: shape)
      .clipShape(shape)
      .overlay(shape.strokeBorder(OverviewPalette.line, lineWidth: DesignMetrics.overviewD.rimWidth))
  }
}

// MARK: - Hero band

/// Assets, Storage, Uploads, Used side by side in one card,
/// `columns` to a row on a narrow page.
struct OverviewHeroBand: View {
  let cells: [OverviewModel.Hero]
  let columns: Int

  var body: some View {
    VStack(spacing: DesignMetrics.spacing.none) {
      ForEach(Array(Self.rows(cells, columns: columns).enumerated()), id: \.offset) { index, row in
        if index > 0 { Divider() }
        HStack(spacing: DesignMetrics.spacing.none) {
          ForEach(Array(row.enumerated()), id: \.element.id) { column, cell in
            if column > 0 { Divider() }
            OverviewHeroCell(cell: cell)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .overviewGroup()
  }

  static func rows(_ cells: [OverviewModel.Hero], columns: Int) -> [[OverviewModel.Hero]] {
    let width = max(1, columns)
    return stride(from: 0, to: cells.count, by: width).map {
      Array(cells[$0..<min($0 + width, cells.count)])
    }
  }
}

struct OverviewHeroCell: View {
  let cell: OverviewModel.Hero

  var body: some View {
    let tint = Self.tint(cell.kind)
    HStack(alignment: .bottom, spacing: DesignMetrics.overviewD.heroSpacing) {
      VStack(alignment: .leading, spacing: DesignMetrics.overviewD.heroLineSpacing) {
        HStack(spacing: DesignMetrics.overviewD.heroTitleSpacing) {
          ColorSquare(size: .folder, color: tint, content: .symbol(Self.symbol(cell.kind)))
          Text(cell.title).pinaxOverviewLabel().foregroundStyle(tint).lineLimit(1)
        }
        Text(cell.value).pinaxHeroFigure().lineLimit(1).minimumScaleFactor(0.7)
        Text(cell.detail).pinaxSecondary().monospacedDigit().lineLimit(1)
      }
      Spacer(minLength: DesignMetrics.spacing.none)
      if let ratio = cell.ratio {
        OverviewSeam(segments: [(ratio, tint)])
          .frame(width: DesignMetrics.overviewD.ratioWidth)
          .padding(.bottom, DesignMetrics.spacing.xs)
      } else if !cell.sparkline.isEmpty {
        OverviewSparkline(values: cell.sparkline, highlighted: cell.highlighted, tint: tint)
      }
    }
    .padding(.vertical, DesignMetrics.overviewD.heroVerticalPadding)
    .padding(.horizontal, DesignMetrics.overviewD.heroHorizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func symbol(_ kind: OverviewModel.Hero.Kind) -> String {
    switch kind {
    case .assets: return "photo"
    case .storage: return "externaldrive.fill"
    case .uploads: return "arrow.up"
    case .used: return "arrow.up.right"
    }
  }

  static func tint(_ kind: OverviewModel.Hero.Kind) -> Color {
    switch kind {
    case .assets: return OverviewPalette.assets
    case .storage: return OverviewPalette.storage
    case .uploads: return OverviewPalette.uploads
    case .used: return OverviewPalette.used
    }
  }
}

/// A hero cell's mini bars: 3 wide and 2 apart, 24 high at the largest;
/// the highlighted one full, the rest at 45 %. More than a year's twelve
/// share the twelve's width.
struct OverviewSparkline: View {
  let values: [Double]
  let highlighted: Int?
  let tint: Color

  /// A bar's width and gap for `count` bars: 3 and 2 up to twelve, then
  /// the twelve's width shared out with 1 pt gaps (a month's 31: 0.9 pt).
  static func bar(count: Int) -> (width: CGFloat, gap: CGFloat) {
    let metrics = DesignMetrics.overviewD.self
    guard count > 12 else { return (metrics.sparkBarWidth, metrics.sparkBarGap) }
    let room = 12 * metrics.sparkBarWidth + 11 * metrics.sparkBarGap
    let gap = metrics.sparkBarMinimum
    return ((room - CGFloat(count - 1) * gap) / CGFloat(count), gap)
  }

  var body: some View {
    let largest = max(values.max() ?? 0, 1)
    let bar = Self.bar(count: values.count)
    HStack(alignment: .bottom, spacing: bar.gap) {
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        RoundedRectangle(cornerRadius: DesignMetrics.overviewD.sparkBarRadius)
          .fill(tint)
          .opacity(index == highlighted ? 1 : DesignMetrics.overviewD.sparkDimOpacity)
          .frame(
            width: bar.width,
            height: max(
              DesignMetrics.overviewD.sparkBarMinimum,
              DesignMetrics.overviewD.sparkHeight * CGFloat(value / largest)))
      }
    }
    .frame(height: DesignMetrics.overviewD.sparkHeight, alignment: .bottom)
    .accessibilityHidden(true)
  }
}

/// A seamless bar of shares on the empty track:
/// 10 high, corner 4.
struct OverviewSeam: View {
  let segments: [(fraction: Double, color: Color)]

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: DesignMetrics.spacing.none) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
          Rectangle()
            .fill(segment.color)
            .frame(width: geometry.size.width * CGFloat(min(1, max(0, segment.fraction))))
        }
        Spacer(minLength: DesignMetrics.spacing.none)
      }
    }
    .frame(height: DesignMetrics.overviewD.seamHeight)
    .background(OverviewPalette.track)
    .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.overviewD.seamRadius, style: .continuous))
    .accessibilityHidden(true)
  }
}

// MARK: - Upload Activity

/// The 53-week heat map, GitHub's: one column a week, one row a weekday.
/// Its cells are `pitch` apart — as wide as the card allows, within
/// `heatMinPitch`…`heatMaxPitch` — and the map is centred; below the
/// minimum it scrolls sideways with the newest weeks in view. The month and
/// weekday names are drawn here, on the same pitch, outside the chart's
/// plot, so they never sit on the cells.
/// `hover` gets the day under the pointer (nil on leaving); `open` the day
/// clicked — the Time navigator's month holding it.
struct OverviewHeatmapCard: View {
  let heatmap: OverviewModel.Heatmap
  let pitch: CGFloat
  let scrolls: Bool
  let hoverLine: String?
  let hover: (Date?) -> Void
  let open: (Date) -> Void

  var body: some View {
    OverviewCard(title: "Upload Activity", systemImage: "square.grid.3x3.fill", tint: OverviewPalette.activity) {
      Text(hoverLine ?? heatmap.header)
        .pinaxSecondary()
        .monospacedDigit()
    } content: {
      if scrolls {
        ScrollView(.horizontal, showsIndicators: false) { map }
          .defaultScrollAnchor(.trailing)
      } else {
        map.frame(maxWidth: .infinity)
      }
      HStack(spacing: DesignMetrics.spacing.xs) {
        Spacer()
        Text("Less").pinaxCaption()
        ForEach(OverviewPalette.heat.indices, id: \.self) { level in
          RoundedRectangle(cornerRadius: DesignMetrics.overviewD.heatLegendRadius)
            .fill(OverviewPalette.heat[level])
            .frame(width: DesignMetrics.overview.heatLegendCell, height: DesignMetrics.overview.heatLegendCell)
        }
        Text("More").pinaxCaption()
      }
    }
  }

  private var weekdayWidth: CGFloat { DesignMetrics.overview.heatWeekdayWidth }
  private var mapWidth: CGFloat { CGFloat(OverviewModel.heatWeeks) * pitch }
  private var mapHeight: CGFloat { 7 * pitch }

  private var map: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      ZStack(alignment: .topLeading) {
        ForEach(heatmap.monthLabels.keys.sorted(), id: \.self) { week in
          Text(heatmap.monthLabels[week] ?? "")
            .pinaxCaption()
            .fixedSize()
            .offset(x: weekdayWidth + CGFloat(week) * pitch)
        }
      }
      // Offsets take no room: the map's width is the row below alone.
      HStack(spacing: DesignMetrics.spacing.none) {
        ZStack(alignment: .topLeading) {
          ForEach(heatmap.weekdayLabels.keys.sorted(), id: \.self) { row in
            Text(heatmap.weekdayLabels[row] ?? "")
              .pinaxCaption()
              .frame(height: pitch)
              .offset(y: CGFloat(row) * pitch)
          }
        }
        .frame(width: weekdayWidth, height: mapHeight, alignment: .topLeading)
        chart
      }
    }
  }

  private var chart: some View {
    Chart(heatmap.cells) { cell in
      RectangleMark(
        x: .value("Week", String(cell.week)),
        y: .value("Day", String(cell.row)),
        width: .fixed(pitch - DesignMetrics.overview.heatGap),
        height: .fixed(pitch - DesignMetrics.overview.heatGap)
      )
      .foregroundStyle(OverviewPalette.heat[cell.level])
      .opacity(cell.inPeriod ? 1 : DesignMetrics.overview.fadedOpacity)
      .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.overviewD.heatCellRadius))
    }
    .chartXScale(domain: (0..<OverviewModel.heatWeeks).map(String.init))
    .chartYScale(domain: (0..<7).map(String.init))
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartPlotStyle { $0.frame(width: mapWidth, height: mapHeight) }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle()
          .fill(.clear)
          .contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let location): hover(day(at: location, proxy: proxy, geometry: geometry))
            case .ended: hover(nil)
            }
          }
          .onTapGesture { location in
            if let day = day(at: location, proxy: proxy, geometry: geometry) { open(day) }
          }
      }
    }
    .frame(width: mapWidth, height: mapHeight)
  }

  private func day(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
    guard let plot = proxy.plotFrame else { return nil }
    let origin = geometry[plot].origin
    let point = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
    guard let (week, row) = proxy.value(at: point, as: (String, String).self) else { return nil }
    return heatmap.cells.first { String($0.week) == week && String($0.row) == row }?.day
  }
}

// MARK: - Uploads

/// The Uploads chart: Week | Month | Year and ‹ period ›, the total and the
/// average over it, one bar a day (a month for a year), the average's
/// dashed rule and a label on the busiest bar — or on the one under the
/// pointer. `choose` picks the kind, `move` steps back (−1) or forward
/// (+1), `open` takes a bar's day — the Time navigator's month holding it.
struct OverviewUploadsCard: View {
  let uploads: OverviewModel.Uploads
  let calendar: Calendar
  let choose: (OverviewPeriod.Kind) -> Void
  let move: (Int) -> Void
  let open: (Date) -> Void
  @State private var selectedBar: String?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.overviewD.chartSpacing) {
      HStack(spacing: DesignMetrics.spacing.s) {
        Picker("Period", selection: Binding(get: { uploads.period.kind }, set: choose)) {
          ForEach(OverviewPeriod.Kind.allCases) { kind in
            Text(kind.rawValue).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer(minLength: DesignMetrics.spacing.s)
        ControlGroupCapsule {
          Button("Previous", systemImage: "chevron.left") { move(-1) }
          ControlGroupDivider()
          Text(uploads.title).pinaxOverviewName().monospacedDigit().lineLimit(1)
          ControlGroupDivider()
          Button("Next", systemImage: "chevron.right") { move(1) }
            .disabled(!uploads.canGoForward)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
      }
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
          HStack(spacing: DesignMetrics.overviewD.heroTitleSpacing) {
            ColorSquare(size: .folder, color: OverviewPalette.uploadsChart, content: .symbol("arrow.up"))
            Text("Uploads").pinaxOverviewCardTitle().foregroundStyle(OverviewPalette.uploadsChart)
          }
          HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.xs) {
            Text(uploads.total.formatted()).pinaxOverviewFigure()
            Text("uploads · \(PinaxFormat.fileSize(uploads.bytes))").pinaxSecondary().monospacedDigit()
          }
          Text(uploads.subtitle).pinaxCaption().monospacedDigit()
        }
        Spacer(minLength: DesignMetrics.spacing.s)
        VStack(alignment: .trailing, spacing: DesignMetrics.spacing.none) {
          Text("Avg / \(uploads.averageUnit)").pinaxOverviewCaps()
          Text(uploads.averageText).pinaxOverviewFigure()
        }
      }
      chart
    }
    .overviewCard()
  }

  private var selected: OverviewModel.Bar? {
    selectedBar.flatMap(Int.init).flatMap { index in uploads.bars.first { $0.index == index } }
  }

  /// The bar drawn full and labelled: the one under the pointer, else the
  /// period's busiest.
  private var highlighted: Int? { selected?.index ?? uploads.peak }

  private var chart: some View {
    Chart {
      ForEach(uploads.bars.filter { !$0.isFuture }) { bar in
        BarMark(x: .value("When", String(bar.index)), y: .value("Uploads", bar.count))
          .foregroundStyle(OverviewPalette.uploadsChart)
          .opacity(bar.index == highlighted ? 1 : DesignMetrics.overviewD.dimBarOpacity)
          .clipShape(
            UnevenRoundedRectangle(
              topLeadingRadius: DesignMetrics.overview.barCornerRadius,
              topTrailingRadius: DesignMetrics.overview.barCornerRadius))
          .annotation(
            position: .top, spacing: DesignMetrics.spacing.xs,
            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
          ) {
            if bar.index == highlighted, bar.count > 0 { callout(bar) }
          }
      }
      if let average = uploads.averageLine {
        RuleMark(y: .value("Average", average))
          .foregroundStyle(OverviewPalette.uploadsChart.opacity(DesignMetrics.overviewD.averageOpacity))
          .lineStyle(StrokeStyle(
            lineWidth: DesignMetrics.overviewD.averageLineWidth,
            dash: DesignMetrics.overview.averageLineDash))
      }
    }
    .chartXScale(domain: uploads.bars.map { String($0.index) })
    .chartYScale(domain: 0...uploads.scaleTop)
    .chartXAxis {
      AxisMarks(values: uploads.bars.map { String($0.index) }) { value in
        AxisValueLabel {
          if let index = value.as(String.self).flatMap(Int.init), index < uploads.bars.count {
            Text(uploads.bars[index].tick).pinaxCaption()
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
        AxisGridLine()
        AxisValueLabel()
      }
    }
    .chartXSelection(value: $selectedBar)
    .simultaneousGesture(
      TapGesture().onEnded {
        if let selected { open(selected.start) }
      })
    .frame(height: DesignMetrics.overviewD.chartHeight)
  }

  private func callout(_ bar: OverviewModel.Bar) -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignMetrics.overviewD.calloutRadius, style: .continuous)
    return HStack(spacing: DesignMetrics.spacing.xs) {
      Text(bar.count.formatted()).pinaxOverviewCalloutFigure()
      Text(bar.title).pinaxCaption()
    }
    .padding(.vertical, DesignMetrics.overviewD.calloutVerticalPadding)
    .padding(.horizontal, DesignMetrics.overviewD.calloutHorizontalPadding)
    .background(OverviewPalette.card, in: shape)
    .overlay(shape.strokeBorder(OverviewPalette.line, lineWidth: DesignMetrics.overviewD.rimWidth))
  }
}

// MARK: - Lists

/// A grouped list's title.
struct OverviewSectionTitle: View {
  let title: String

  var body: some View {
    Text(title)
      .pinaxSectionTitle()
      .padding(.horizontal, DesignMetrics.overviewD.sectionTitleInset)
      .padding(.bottom, DesignMetrics.overviewD.sectionTitleInset)
  }
}

/// Rows in one card, a hairline between them.
struct OverviewGroupRows<Row: Identifiable, Content: View>: View {
  let rows: [Row]
  @ViewBuilder let content: (Row) -> Content

  var body: some View {
    VStack(spacing: DesignMetrics.spacing.none) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 { Divider() }
        content(row)
      }
    }
    .overviewGroup()
  }
}

/// Library or Usage: a square, a name, a figure, a ›. `open`
/// gets a row's destination; a row without one is not a button.
struct OverviewListGroup: View {
  let title: String
  let rows: [OverviewModel.ListRow]
  let open: (OverviewModel.Destination) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
      OverviewSectionTitle(title: title)
      OverviewGroupRows(rows: rows) { row in
        if let destination = row.destination {
          Button { open(destination) } label: { label(row) }
            .buttonStyle(.plain)
        } else {
          label(row)
        }
      }
    }
  }

  private func label(_ row: OverviewModel.ListRow) -> some View {
    HStack(spacing: DesignMetrics.overviewD.rowSpacing) {
      ColorSquare(
        size: .sidebar, color: PinaxPalette.color(OverviewPalette.token(row.kind)),
        content: .symbol(Self.symbol(row.kind)))
      Text(row.title).pinaxBody().lineLimit(1)
      Spacer(minLength: DesignMetrics.spacing.s)
      Text(row.value)
        .pinaxOverviewValue()
        .foregroundStyle(row.isZero ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .lineLimit(1)
      // A row that opens nothing keeps the ›'s room, so the figures line up.
      Image(systemName: "chevron.right")
        .pinaxGlyph(DesignMetrics.overviewD.chevron, weight: .semibold)
        .foregroundStyle(.tertiary)
        .opacity(row.destination == nil ? 0 : 1)
        .accessibilityHidden(row.destination == nil)
    }
    .padding(.horizontal, DesignMetrics.overviewD.rowPadding)
    .frame(height: DesignMetrics.overviewD.rowHeight)
    .contentShape(Rectangle())
  }

  static func symbol(_ kind: OverviewModel.ListRow.Kind) -> String {
    switch kind {
    case .favorites: return "heart.fill"
    case .archived: return "archivebox.fill"
    case .tagged: return "number"
    case .usedImages: return "arrow.up.right"
    case .orphanCandidates: return "questionmark"
    case .domains: return "globe"
    }
  }
}

/// Kind, Backend and Tags as seamless bars.
struct OverviewCompositionList: View {
  let rows: [OverviewModel.Composition]

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
      OverviewSectionTitle(title: "Composition")
      OverviewGroupRows(rows: rows) { row in
        HStack(spacing: DesignMetrics.overviewD.rowSpacing) {
          Text(row.title)
            .pinaxBody()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: DesignMetrics.overviewD.compositionLabelWidth, alignment: .leading)
          OverviewSeam(segments: row.segments.map { ($0.fraction, PinaxPalette.color($0.hue)) })
          Text(row.figures)
            .pinaxSecondary()
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: DesignMetrics.overviewD.compositionFigureWidth, alignment: .trailing)
            .layoutPriority(1)
        }
        .padding(.horizontal, DesignMetrics.overviewD.rowPadding)
        .frame(height: DesignMetrics.overviewD.rowHeight)
      }
    }
  }
}

/// One row a project in scope. `open` gets the
/// project and the number's column: each number on the second line opens
/// its report.
struct OverviewProjectsList: View {
  let projects: [OverviewModel.ProjectRow]
  let open: (String, OverviewModel.ProjectColumn) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
      OverviewSectionTitle(title: "Projects")
      OverviewGroupRows(rows: projects) { project in
        HStack(spacing: DesignMetrics.overviewD.rowSpacing) {
          Image(systemName: "folder.fill")
            .pinaxGlyph(DesignMetrics.overviewD.projectIcon)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
            Text(project.name).pinaxOverviewName().lineLimit(1)
            HStack(spacing: DesignMetrics.spacing.none) {
              number(project.used, "used") { open(project.slug, .used) }
              Text(" · ")
              number(project.orphanCandidates, "orphan") { open(project.slug, .orphanCandidates) }
              Text(" · ")
              number(project.otherDomains, "other domains") { open(project.slug, .otherDomains) }
            }
            .pinaxSecondary()
            .monospacedDigit()
            .lineLimit(1)
          }
          Spacer(minLength: DesignMetrics.spacing.s)
          Text(project.lastScan).pinaxSecondary().monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, DesignMetrics.overviewD.rowPadding)
        .frame(height: DesignMetrics.overviewD.projectRowHeight)
      }
    }
  }

  private func number(_ value: Int, _ noun: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text("\(value.formatted()) \(noun)")
    }
    .buttonStyle(.plain)
  }
}
