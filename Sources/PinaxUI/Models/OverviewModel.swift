import CatalogCore
import Foundation

/// Week | Month | Year and how far back: offset 0 is
/// the one holding "now", −1 the one before.
public struct OverviewPeriod: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Identifiable, Sendable {
    case week = "Week"
    case month = "Month"
    case year = "Year"

    public var id: String { rawValue }
  }

  public var kind: Kind
  public var offset: Int

  public init(kind: Kind = .week, offset: Int = 0) {
    self.kind = kind
    self.offset = offset
  }
}

/// What the Overview draws from `CatalogStats`, worked out for one "now",
/// one calendar and one period. Pure: every title, cell and bar is a value
/// the tests compare by hand.
public struct OverviewModel: Equatable {
  /// Days: the heat map's 53 weeks. Weeks start on `calendar.firstWeekday`.
  public static let heatWeeks = 53
  /// A month's name needs this many columns, its own included, before the
  /// map's right edge; a month starting later goes unnamed rather than cut.
  public static let monthLabelColumns = 2

  public struct HeatCell: Equatable, Identifiable {
    public let day: Date
    /// 0 = the oldest of the 53 columns.
    public let week: Int
    /// 0 = the calendar's first weekday.
    public let row: Int
    public let count: Int
    /// 0 none, then 1–2, 3–4, 5–7, 8 and more.
    public let level: Int
    /// In the period chosen below; the others are drawn faded.
    public let inPeriod: Bool

    public var id: Date { day }
  }

  public struct Heatmap: Equatable {
    /// Today and the days before it; the rest of this week is not drawn.
    public let cells: [HeatCell]
    /// A month's short name over the first column whose week starts in it,
    /// when `monthLabelColumns` columns are left for it.
    public let monthLabels: [Int: String]
    /// Mon, Wed and Fri, by row.
    public let weekdayLabels: [Int: String]
    public let total: Int
    /// The longest run of consecutive days with an upload, in the 53 weeks.
    public let longestStreak: Int

    public var header: String {
      "\(PinaxFormat.count(total, singular: "upload")) in the last 12 months · longest streak "
        + PinaxFormat.count(longestStreak, singular: "day")
    }
  }

  public struct Bar: Equatable, Identifiable {
    public let start: Date
    /// 0-based position, the chart's x.
    public let index: Int
    /// Under the bar: Mon…, a day of the month every week, a month's initial.
    public let tick: String
    /// "Oct 2, 2026" or "September 2026": the hover callout.
    public let title: String
    public let count: Int
    public let bytes: Int64
    /// Days to come are not drawn.
    public let isFuture: Bool

    public var id: Int { index }
  }

  public struct Uploads: Equatable {
    public let period: OverviewPeriod
    public let interval: DateInterval
    /// "This Week", "Last Week", "Sep 21 – 27", "Sep 28 – Oct 4"; "This
    /// Month", "September 2026"; "This Year", "2025".
    public let title: String
    /// The whole range: "Sep 28 – Oct 4, 2026".
    public let subtitle: String
    public let bars: [Bar]
    public let total: Int
    public let bytes: Int64
    /// Over the days (Year: months) gone by, today's included; nil when
    /// none has.
    public let average: Double?
    /// The average to one decimal at most in `calendar`'s locale, "—"
    /// without one: the card's figure and the hero band's.
    public let averageText: String
    /// "day", or "month" for a year: the average's unit.
    public let averageUnit: String
    /// The busiest bar gone by (the first of equals); nil when none has an
    /// upload. The chart draws it full and labels it.
    public let peak: Int?
    /// The chart's y scale is 0…scaleTop: the busiest bar, at least 2, so
    /// an empty or flat period still gets whole-number ticks.
    public let scaleTop: Int
    /// The dashed average rule's height; nil when the average is 0 or
    /// there is none, where it would only lie on the baseline.
    public let averageLine: Double?
    /// › is dimmed on the period holding now.
    public let canGoForward: Bool
  }

  /// Where a card's click goes: Library ▸ Favorites / Archived,
  /// Usage, Orphans, Externals ▸ Your Domains, Usage on Old Domains.
  public enum Destination: Equatable, Sendable {
    case favorites
    case archived
    case usage
    case orphans
    case yourDomains
    case oldDomains
  }

  /// A Usage by Project number's report.
  public enum ProjectColumn: CaseIterable, Sendable {
    case used, orphanCandidates, yourDomains, otherDomains
  }

  /// One of the hero band's four cells.
  public struct Hero: Equatable, Identifiable {
    public enum Kind: CaseIterable, Sendable {
      case assets, storage, uploads, used
    }

    public let kind: Kind
    public let title: String
    public let value: String
    /// Under the number: "+3 · This Week", "1.5 / day", "of 24 assets".
    public let detail: String
    /// The mini bars, one a bar of the period gone by: Assets and Storage
    /// the running total at each bar's end, Uploads each bar's count.
    /// Empty for Used, which has no history.
    public let sparkline: [Double]
    /// The one bar drawn full: the latest running total, or the period's
    /// busiest bar; nil when there is none.
    public let highlighted: Int?
    /// Used's share of the assets, 0...1, drawn as a bar; nil elsewhere.
    public let ratio: Double?

    public var id: Kind { kind }
  }

  /// A Library or Usage list row: a coloured square, a name,
  /// a figure, a › when it opens something.
  public struct ListRow: Equatable, Identifiable {
    public enum Kind: CaseIterable, Sendable {
      case favorites, archived, tagged, usedImages, orphanCandidates, domains
    }

    public let kind: Kind
    public let title: String
    public let value: String
    /// The figure is drawn in the tertiary grey.
    public let isZero: Bool
    /// nil: the row opens nothing and shows no ›.
    public let destination: Destination?

    public var id: Kind { kind }
  }

  /// A Composition row: a seamless bar of shares and its figures.
  public struct Composition: Equatable, Identifiable {
    public struct Segment: Equatable {
      public let name: String
      /// Of the row's whole, 0...1; the segments sum to at most 1, the rest
      /// is the empty track.
      public let fraction: Double
      public let hue: PinaxPalette.Token

      public init(name: String, fraction: Double, hue: PinaxPalette.Token) {
        self.name = name
        self.fraction = fraction
        self.hue = hue
      }
    }

    public let title: String
    public let segments: [Segment]
    /// "PNG 22 · JPEG 2", "r2 23 · b2 1", "4 tagged · 20 untagged".
    public let figures: String

    public var id: String { title }
  }

  /// A Usage by Project row.
  public struct ProjectRow: Equatable, Identifiable {
    public let slug: String
    public let name: String
    public let used: Int
    public let orphanCandidates: Int
    public let yourDomains: Int
    public let otherDomains: Int
    /// "Today 16:47", "Yesterday 09:12", "Oct 2, 2026", "Never scanned",
    /// "Not tracked".
    public let lastScan: String

    public var id: String { slug }
  }

  public let heatmap: Heatmap
  public let uploads: Uploads
  public let hero: [Hero]
  public let library: [ListRow]
  public let usage: [ListRow]
  public let composition: [Composition]
  public let projects: [ProjectRow]

  public init(stats: CatalogStats, period: OverviewPeriod, now: Date, calendar: Calendar) {
    let uploads = Self.uploads(stats.uploadsByDay, period: period, now: now, calendar: calendar)
    self.uploads = uploads
    heatmap = Self.heatmap(
      stats.uploadsByDay, period: uploads.interval, now: now, calendar: calendar)
    hero = Self.hero(stats, uploads: uploads)
    library = Self.library(stats)
    usage = Self.usage(stats)
    composition = Self.composition(stats)
    projects = stats.projects.map {
      ProjectRow(
        slug: $0.slug, name: $0.name, used: $0.used, orphanCandidates: $0.orphanCandidates,
        yourDomains: $0.yourDomains, otherDomains: $0.otherDomains,
        lastScan: Self.lastScan($0, now: now, calendar: calendar))
    }
  }

  // MARK: - Hero band and lists

  static func hero(_ stats: CatalogStats, uploads: Uploads) -> [Hero] {
    let past = uploads.bars.filter { !$0.isFuture }
    let running = runningTotals(
      stats.uploadsByDay, of: stats.assets, bars: past, end: uploads.interval.end)
    let last = running.isEmpty ? nil : running.count - 1
    let ratio =
      stats.assets.count == 0 ? 0 : min(1, Double(stats.usedImages) / Double(stats.assets.count))
    return [
      Hero(
        kind: .assets, title: "Assets", value: stats.assets.count.formatted(),
        detail: "+\(uploads.total.formatted()) · \(uploads.title)",
        sparkline: running.map { Double($0.count) }, highlighted: last, ratio: nil),
      Hero(
        kind: .storage, title: "Storage", value: PinaxFormat.fileSize(stats.assets.bytes),
        detail: "+\(PinaxFormat.fileSize(uploads.bytes)) · \(uploads.title)",
        sparkline: running.map { Double($0.bytes) }, highlighted: last, ratio: nil),
      Hero(
        kind: .uploads, title: "Uploads", value: uploads.total.formatted(),
        detail: "\(uploads.averageText) / \(uploads.averageUnit)",
        sparkline: past.map { Double($0.count) }, highlighted: uploads.peak, ratio: nil),
      Hero(
        kind: .used, title: "Used", value: stats.usedImages.formatted(),
        detail: "of \(PinaxFormat.count(stats.assets.count, singular: "asset"))",
        sparkline: [], highlighted: nil, ratio: ratio),
    ]
  }

  /// The library's size at the end of each bar: today's total less what
  /// came after the bar. Counted back from the total, so an asset without
  /// an upload date is in every bar and the last bar is the total.
  static func runningTotals(
    _ days: [Date: CatalogStats.Total], of total: CatalogStats.Total, bars: [Bar], end: Date
  ) -> [CatalogStats.Total] {
    bars.indices.map { index in
      let barEnd = index + 1 < bars.count ? bars[index + 1].start : end
      var running = total
      for (day, upload) in days where day >= barEnd {
        running.count -= upload.count
        running.bytes -= upload.bytes
      }
      return running
    }
  }

  static func library(_ stats: CatalogStats) -> [ListRow] {
    let active = stats.tagged + stats.untagged
    return [
      ListRow(
        kind: .favorites, title: "Favorites", value: stats.favorites.formatted(),
        isZero: stats.favorites == 0, destination: .favorites),
      ListRow(
        kind: .archived, title: "Archived", value: stats.archived.formatted(),
        isZero: stats.archived == 0, destination: .archived),
      ListRow(
        kind: .tagged, title: "Tagged",
        value: "\(stats.tagged.formatted()) / \(active.formatted())",
        isZero: stats.tagged == 0, destination: nil),
    ]
  }

  static func usage(_ stats: CatalogStats) -> [ListRow] {
    [
      ListRow(
        kind: .usedImages, title: "Used Images", value: stats.usedImages.formatted(),
        isZero: stats.usedImages == 0, destination: .usage),
      ListRow(
        kind: .orphanCandidates, title: "Orphan Candidates",
        value: stats.orphanCandidates.count.formatted(),
        isZero: stats.orphanCandidates.count == 0, destination: .orphans),
      ListRow(
        kind: .domains, title: "Domains",
        value: "\(stats.yourDomains.formatted()) yours · \(stats.oldDomains.formatted()) old",
        isZero: stats.yourDomains == 0 && stats.oldDomains == 0, destination: .yourDomains),
    ]
  }

  static func composition(_ stats: CatalogStats) -> [Composition] {
    let kindName = { (mime: String) in PinaxFormat.shortKind(mime: mime) }
    let backendName = { (name: String) in name }
    let active = stats.tagged + stats.untagged
    let tagged =
      stats.tagged == 0 || active == 0
      ? []
      : [
        Composition.Segment(
          name: "Tagged", fraction: Double(stats.tagged) / Double(active), hue: OverviewPalette.tagged)
      ]
    return [
      Composition(
        title: "Kind",
        segments: segments(stats.kinds, name: kindName) { PinaxPalette.formatToken(mime: $1) },
        figures: figures(stats.kinds, name: kindName)),
      Composition(
        title: "Backend",
        segments: segments(stats.backends, name: backendName) { index, _ in
          OverviewPalette.backendHues[index % OverviewPalette.backendHues.count]
        },
        figures: figures(stats.backends, name: backendName)),
      Composition(
        title: "Tags", segments: tagged,
        figures: stats.tagged == 0
          ? "\(stats.untagged.formatted()) untagged"
          : "\(stats.tagged.formatted()) tagged · \(stats.untagged.formatted()) untagged"),
    ]
  }

  /// Each share of the list's whole, in the list's order.
  static func segments(
    _ list: [CatalogStats.Share], name: (String) -> String,
    hue: (Int, String) -> PinaxPalette.Token
  ) -> [Composition.Segment] {
    let whole = list.reduce(0) { $0 + $1.total.count }
    guard whole > 0 else { return [] }
    return list.enumerated().map { index, share in
      Composition.Segment(
        name: name(share.name), fraction: Double(share.total.count) / Double(whole),
        hue: hue(index, share.name))
    }
  }

  /// "PNG 22 · JPEG 2"; a single share also gives its size: "r2 23 · 23 kB".
  static func figures(_ list: [CatalogStats.Share], name: (String) -> String) -> String {
    if list.count == 1, let only = list.first {
      return
        "\(name(only.name)) \(only.total.count.formatted()) · \(PinaxFormat.fileSize(only.total.bytes))"
    }
    return list.map { "\(name($0.name)) \($0.total.count.formatted())" }.joined(separator: " · ")
  }

  /// The Last Scan column, in `calendar`'s time zone, 24-hour.
  static func lastScan(_ project: CatalogStats.ProjectUsage, now: Date, calendar: Calendar) -> String {
    if project.usageTracking == .notTracked { return "Not tracked" }
    guard let stored = project.lastScanAt else { return "Never scanned" }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let at = parser.date(from: stored) ?? ISO8601DateFormatter().date(from: stored) else {
      return stored
    }
    let time = calendar.dateComponents([.hour, .minute], from: at)
    let clock = String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
    if calendar.isDate(at, inSameDayAs: now) { return "Today \(clock)" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(at, inSameDayAs: yesterday)
    {
      return "Yesterday \(clock)"
    }
    return dayTitle(at, calendar: calendar)
  }

  // MARK: - Heat map

  public static func level(_ count: Int) -> Int {
    switch count {
    case ..<1: return 0
    case 1...2: return 1
    case 3...4: return 2
    case 5...7: return 3
    default: return 4
    }
  }

  /// The first day of the 53 columns: the start of this week, 52 weeks back.
  public static func heatStart(now: Date, calendar: Calendar) -> Date {
    let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
    return calendar.date(byAdding: .weekOfYear, value: -(heatWeeks - 1), to: thisWeek) ?? thisWeek
  }

  static func heatmap(
    _ days: [Date: CatalogStats.Total], period: DateInterval, now: Date, calendar: Calendar
  ) -> Heatmap {
    let today = calendar.startOfDay(for: now)
    var day = heatStart(now: now, calendar: calendar)
    var cells: [HeatCell] = []
    var monthLabels: [Int: String] = [:]
    var lastMonth: Int?
    var streak = 0
    var longest = 0
    var index = 0
    while day <= today {
      let count = days[day]?.count ?? 0
      let week = index / 7
      if index % 7 == 0 {
        let month = calendar.component(.month, from: day)
        if lastMonth != nil, month != lastMonth, week + monthLabelColumns <= heatWeeks {
          monthLabels[week] = calendar.shortMonthSymbols[month - 1]
        }
        lastMonth = month
      }
      cells.append(
        HeatCell(
          day: day, week: week, row: index % 7, count: count, level: level(count),
          inPeriod: day >= period.start && day < period.end))
      streak = count > 0 ? streak + 1 : 0
      longest = max(longest, streak)
      index += 1
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    // Rows are counted from the first weekday; Monday is weekday 2.
    var weekdayLabels: [Int: String] = [:]
    for weekday in [2, 4, 6] {
      let row = (weekday - calendar.firstWeekday + 7) % 7
      weekdayLabels[row] = calendar.shortWeekdaySymbols[weekday - 1]
    }
    return Heatmap(
      cells: cells, monthLabels: monthLabels, weekdayLabels: weekdayLabels,
      total: cells.reduce(0) { $0 + $1.count }, longestStreak: longest)
  }

  // MARK: - Uploads

  static func uploads(
    _ days: [Date: CatalogStats.Total], period: OverviewPeriod, now: Date, calendar: Calendar
  ) -> Uploads {
    let component: Calendar.Component
    switch period.kind {
    case .week: component = .weekOfYear
    case .month: component = .month
    case .year: component = .year
    }
    let current = calendar.dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
    let start = calendar.date(byAdding: component, value: period.offset, to: current.start) ?? current.start
    let interval = calendar.dateInterval(of: component, for: start) ?? current
    let today = calendar.startOfDay(for: now)
    let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start

    var bars: [Bar] = []
    if period.kind == .year {
      var month = interval.start
      while month < interval.end {
        let end = calendar.date(byAdding: .month, value: 1, to: month) ?? interval.end
        let total = sum(days, from: month, to: end)
        let number = calendar.component(.month, from: month)
        bars.append(
          Bar(
            start: month, index: bars.count,
            tick: String(calendar.shortMonthSymbols[number - 1].prefix(1)),
            title: "\(calendar.monthSymbols[number - 1]) \(calendar.component(.year, from: month))",
            count: total.count, bytes: total.bytes, isFuture: month > today))
        month = end
      }
    } else {
      var day = interval.start
      while day < interval.end {
        let total = days[day] ?? CatalogStats.Total()
        let tick: String
        if period.kind == .week {
          tick = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
        } else {
          let number = calendar.component(.day, from: day)
          tick = (number - 1) % 7 == 0 ? String(number) : ""
        }
        bars.append(
          Bar(
            start: day, index: bars.count, tick: tick, title: dayTitle(day, calendar: calendar),
            count: total.count, bytes: total.bytes, isFuture: day > today))
        day = calendar.date(byAdding: .day, value: 1, to: day) ?? interval.end
      }
    }
    let past = bars.filter { !$0.isFuture }
    let total = past.reduce(0) { $0 + $1.count }
    let average = past.isEmpty ? nil : Double(total) / Double(past.count)

    let title: String
    let subtitle: String
    switch period.kind {
    case .week:
      let range = weekRange(interval.start, last, calendar: calendar)
      title = period.offset == 0 ? "This Week" : period.offset == -1 ? "Last Week" : range
      let startYear = calendar.component(.year, from: interval.start)
      let endYear = calendar.component(.year, from: last)
      subtitle =
        startYear == endYear
        ? "\(range), \(endYear)"
        : "\(monthDay(interval.start, calendar: calendar)), \(startYear) – "
          + "\(monthDay(last, calendar: calendar)), \(endYear)"
    case .month:
      let number = calendar.component(.month, from: interval.start)
      let year = calendar.component(.year, from: interval.start)
      title = period.offset == 0 ? "This Month" : "\(calendar.monthSymbols[number - 1]) \(year)"
      subtitle = "\(weekRange(interval.start, last, calendar: calendar)), \(year)"
    case .year:
      let year = calendar.component(.year, from: interval.start)
      title = period.offset == 0 ? "This Year" : String(year)
      subtitle =
        "\(calendar.shortMonthSymbols[0]) – \(calendar.shortMonthSymbols[11]) \(year)"
    }
    return Uploads(
      period: period, interval: interval, title: title, subtitle: subtitle, bars: bars,
      total: total, bytes: past.reduce(0) { $0 + $1.bytes },
      average: average,
      averageText: average.map {
        $0.formatted(.number.precision(.fractionLength(0...1)).locale(calendar.locale ?? .current))
      } ?? "—",
      averageUnit: period.kind == .year ? "month" : "day",
      peak: peak(past),
      scaleTop: max(2, past.map(\.count).max() ?? 0),
      averageLine: average.flatMap { $0 > 0 ? $0 : nil },
      canGoForward: period.offset < 0)
  }

  /// The first of the busiest bars, if any has an upload.
  static func peak(_ bars: [Bar]) -> Int? {
    var best: Bar?
    for bar in bars where bar.count > (best?.count ?? 0) { best = bar }
    return best?.index
  }

  private static func sum(_ days: [Date: CatalogStats.Total], from start: Date, to end: Date)
    -> CatalogStats.Total
  {
    days.reduce(into: CatalogStats.Total()) { total, entry in
      guard entry.key >= start, entry.key < end else { return }
      total.count += entry.value.count
      total.bytes += entry.value.bytes
    }
  }

  /// "Sep 28"
  static func monthDay(_ day: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.month, .day], from: day)
    return "\(calendar.shortMonthSymbols[(parts.month ?? 1) - 1]) \(parts.day ?? 1)"
  }

  /// "Oct 2, 2026"
  public static func dayTitle(_ day: Date, calendar: Calendar) -> String {
    "\(monthDay(day, calendar: calendar)), \(calendar.component(.year, from: day))"
  }

  /// "Sep 21 – 27" within a month, "Sep 28 – Oct 4" across two.
  static func weekRange(_ first: Date, _ last: Date, calendar: Calendar) -> String {
    calendar.component(.month, from: first) == calendar.component(.month, from: last)
      ? "\(monthDay(first, calendar: calendar)) – \(calendar.component(.day, from: last))"
      : "\(monthDay(first, calendar: calendar)) – \(monthDay(last, calendar: calendar))"
  }

  /// The heat map's hover line: "Oct 2, 2026 · 9 uploads".
  public static func dayLine(_ day: Date, count: Int, calendar: Calendar) -> String {
    "\(dayTitle(day, calendar: calendar)) · \(PinaxFormat.count(count, singular: "upload"))"
  }
}
