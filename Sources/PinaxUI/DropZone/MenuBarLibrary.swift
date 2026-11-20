import CatalogCore
import Foundation

// The menu bar panel's statistics card and Library page, as values. Everything
// comes from one `CatalogStats` of the current project plus the drop zone's
// failed cards; the views only draw this, so the tests read the same thing
// without opening a panel.

/// What one bar of the menu bar's upload charts covers.
/// Stored as `pinax.menuBar.chartUnit`; an unknown value reads as Week.
public enum MenuBarChartUnit: String, CaseIterable, Identifiable, Sendable {
  case day, week, month, year

  public static let `default` = MenuBarChartUnit.week
  /// The Library page's segmented choice; Year is the card's only.
  static let libraryUnits: [MenuBarChartUnit] = [.day, .week, .month]

  public var id: String { rawValue }

  static func known(_ stored: String?) -> MenuBarChartUnit {
    stored.flatMap(MenuBarChartUnit.init(rawValue:)) ?? .default
  }

  public var name: String { rawValue.capitalized }

  /// The current bar, as the card's third cell names it.
  var current: String {
    switch self {
    case .day: return "today"
    case .week: return "this week"
    case .month: return "this month"
    case .year: return "this year"
    }
  }

  /// The Library page opens on the setting; Year opens as Month.
  var libraryUnit: MenuBarChartUnit { self == .year ? .month : self }

  var component: Calendar.Component {
    switch self {
    case .day: return .day
    case .week: return .weekOfYear
    case .month: return .month
    case .year: return .year
    }
  }

  /// The next longer unit, for the page's "4 this week · 9 this month".
  var longer: MenuBarChartUnit? {
    switch self {
    case .day: return .week
    case .week: return .month
    case .month: return .year
    case .year: return nil
    }
  }
}

struct MenuBarLibrary: Equatable {
  /// A Last scan row shows once the oldest scan is this old.
  static let staleScanAge: TimeInterval = 7 * 24 * 60 * 60
  /// The bars: the current period and the 13 before it.
  static let barCount = 14

  /// One bar: a calendar day, week, month or year (summed here from
  /// `CatalogStats.uploadsByDay`, weeks from the calendar's firstWeekday).
  struct Bar: Equatable {
    /// The start of the period in the calendar asked for.
    let start: Date
    let count: Int
    let isCurrent: Bool
  }

  /// The 14 bars in one unit, oldest first, the current period last.
  struct Chart: Equatable {
    let unit: MenuBarChartUnit
    let bars: [Bar]
    /// The current period's uploads.
    var current: Int { bars.last?.count ?? 0 }
    /// "UPLOADS · 14 WEEKS".
    var title: String { "UPLOADS · \(MenuBarLibrary.barCount) \(unit.rawValue.uppercased())S" }
    /// The bars' two ends: "Oct 8" … "Today", "Jul 19" … "This week".
    let firstLabel: String
    var lastLabel: String {
      unit == .day ? "Today" : unit.current.prefix(1).uppercased() + unit.current.dropFirst()
    }
  }

  /// One segment of the Library page's storage bar and its legend entry.
  struct Segment: Equatable {
    let name: String
    let bytes: Int64
    /// Of all the bytes in scope, 0…1.
    let fraction: Double

    var legend: String { "\(name) \(PinaxFormat.fileSize(bytes))" }
  }

  /// A Needs attention row, in the order the page lists them.
  enum Attention: Equatable {
    case failedUploads(Int)
    case orphanCandidates(Int)
    /// The oldest scan's age in whole days; nil = never scanned.
    case lastScan(daysAgo: Int?)

    var text: String {
      switch self {
      case .failedUploads(let count):
        return count == 1 ? "1 upload failed" : "\(count.formatted()) uploads failed"
      case .orphanCandidates(let count):
        return count == 1 ? "1 orphan candidate" : "\(count.formatted()) orphan candidates"
      case .lastScan(let days?):
        return "Last scan \(days.formatted()) \(days == 1 ? "day" : "days") ago"
      case .lastScan(nil):
        return "Never scanned"
      }
    }

    var action: String {
      switch self {
      case .failedUploads: return "Show Drop Zone"
      case .orphanCandidates: return "Review"
      case .lastScan: return "Scan"
      }
    }

    /// Failures and orphans are the orange dot; an old scan is grey.
    var isWarning: Bool {
      if case .lastScan = self { return false }
      return true
    }
  }

  let images: Int
  let bytes: Int64
  /// How many backends hold the bytes in scope ("stored on 2 backends").
  let backendCount: Int
  private let shares: [MenuBarStorageSplit: [CatalogStats.Share]]
  let attention: [Attention]
  /// "Scanned 3 days ago" under the page; nil when no project in scope has
  /// a scan.
  let scanned: String?
  /// Uploads per local calendar day, for the charts.
  private let uploadsByDay: [Date: Int]
  private let now: Date
  private let calendar: Calendar

  init(
    stats: CatalogStats, failedUploads: Int, scanTargets: [String], now: Date,
    calendar: Calendar
  ) {
    images = stats.assets.count
    bytes = stats.assets.bytes
    uploadsByDay = stats.uploadsByDay.mapValues(\.count)
    self.now = now
    self.calendar = calendar
    backendCount = stats.backends.count
    shares = [.type: stats.kinds, .project: stats.projectShares, .backend: stats.backends]
    var attention: [Attention] = []
    if failedUploads > 0 { attention.append(.failedUploads(failedUploads)) }
    if stats.orphanCandidates.count > 0 {
      attention.append(.orphanCandidates(stats.orphanCandidates.count))
    }
    if let row = Self.lastScan(stats.projects, targets: scanTargets, now: now) {
      attention.append(row)
    }
    self.attention = attention
    scanned = stats.projects.compactMap { $0.lastScanAt.flatMap(Self.date) }.max().map {
      "Scanned \(PinaxFormat.relativeDate(Self.iso($0), now: now))"
    }
  }

  /// The 14 bars in `unit`: each the sum of its days, the current period
  /// last.
  func chart(_ unit: MenuBarChartUnit) -> Chart {
    let current =
      calendar.dateInterval(of: unit.component, for: now)?.start ?? calendar.startOfDay(for: now)
    let bars = (0..<Self.barCount).reversed().map { back -> Bar in
      let start = calendar.date(byAdding: unit.component, value: -back, to: current) ?? current
      let end = calendar.date(byAdding: unit.component, value: 1, to: start) ?? start
      let count = uploadsByDay.reduce(0) { sum, entry in
        entry.key >= start && entry.key < end ? sum + entry.value : sum
      }
      return Bar(start: start, count: count, isCurrent: back == 0)
    }
    return Chart(
      unit: unit, bars: bars,
      firstLabel: Self.label(bars.first?.start ?? current, unit, calendar: calendar))
  }

  /// "Oct 8" for a day or a week's first day, "Sep 2025", "2013".
  private static func label(_ start: Date, _ unit: MenuBarChartUnit, calendar: Calendar) -> String {
    switch unit {
    case .day, .week:
      return OverviewModel.monthDay(start, calendar: calendar)
    case .month:
      let month = calendar.component(.month, from: start)
      return "\(calendar.shortMonthSymbols[month - 1]) \(calendar.component(.year, from: start))"
    case .year:
      return String(calendar.component(.year, from: start))
    }
  }

  /// What the app installs: the stats the app model last read for the
  /// current project, the drop zone's failed cards and what Scan would
  /// scan. nil until the first read.
  @MainActor
  init?(app: PinaxAppModel, now: Date = Date(), calendar: Calendar = .current) {
    guard let stats = app.menuBarStats else { return nil }
    self.init(
      stats: stats, failedUploads: Self.failedUploads(app.dropZone?.model.cards ?? []),
      scanTargets: app.currentProjectScanTargets,
      now: now, calendar: calendar)
  }

  /// The drop zone's cards that failed.
  static func failedUploads(_ cards: [DropZoneModel.UploadCard]) -> Int {
    cards.filter {
      if case .failed = $0.phase { return true }
      return false
    }.count
  }

  /// The page's line over the bars: "9 today · 37 this week", the unit's
  /// current period and the next longer one's.
  func uploadsLine(_ unit: MenuBarChartUnit) -> String {
    var parts = ["\(chart(unit).current.formatted()) \(unit.current)"]
    if let longer = unit.longer {
      parts.append("\(chart(longer).current.formatted()) \(longer.current)")
    }
    return parts.joined(separator: " · ")
  }

  /// "stored on 3 backends".
  var storedLine: String {
    "stored on \(backendCount.formatted()) \(backendCount == 1 ? "backend" : "backends")"
  }

  /// The storage bar has room for this many segments (and their legend on
  /// one line); past it the smallest fold into Other.
  static let segmentLimit = 4

  /// The storage bar split by `split`, most bytes first.
  func segments(_ split: MenuBarStorageSplit) -> [Segment] {
    var named = (shares[split] ?? [])
      .map { (name: split.label($0.name), bytes: $0.total.bytes) }
      .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    if named.count > Self.segmentLimit {
      let rest = named[(Self.segmentLimit - 1)...].reduce(Int64(0)) { $0 + $1.bytes }
      named = Array(named.prefix(Self.segmentLimit - 1)) + [(name: "Other", bytes: rest)]
    }
    let total = named.reduce(Int64(0)) { $0 + $1.bytes }
    return named.map {
      Segment(
        name: $0.name, bytes: $0.bytes, fraction: total > 0 ? Double($0.bytes) / Double(total) : 0)
    }
  }

  /// The whole card's one label; the third number follows the card's unit.
  /// No attention count: the card has none.
  func accessibilityLabel(_ unit: MenuBarChartUnit) -> String {
    let parts = [
      "\(images.formatted()) images", PinaxFormat.fileSize(bytes),
      "\(chart(unit).current.formatted()) \(unit.current)",
    ]
    return "Library: \(parts.joined(separator: ", ")). Show details."
  }

  /// Among the projects Scan would scan that track usage, the oldest
  /// scan — a row when it is `staleScanAge` old or one was never scanned;
  /// no row without such a project.
  static func lastScan(
    _ projects: [CatalogStats.ProjectUsage], targets: [String], now: Date
  ) -> Attention? {
    let tracked = projects.filter { targets.contains($0.slug) && $0.usageTracking == .tracked }
    guard !tracked.isEmpty else { return nil }
    var oldest: Date?
    for project in tracked {
      guard let at = project.lastScanAt.flatMap(date) else { return .lastScan(daysAgo: nil) }
      oldest = min(oldest ?? at, at)
    }
    guard let oldest, now.timeIntervalSince(oldest) >= staleScanAge else { return nil }
    return .lastScan(daysAgo: Int(now.timeIntervalSince(oldest) / (24 * 60 * 60)))
  }

  private static func date(_ stored: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return parser.date(from: stored) ?? ISO8601DateFormatter().date(from: stored)
  }

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

/// What the Library page's storage bar splits the bytes by: Settings ▸
/// Appearance ▸ Menu Bar Chart. File type unless set; an unknown stored
/// value reads as that.
public enum MenuBarStorageSplit: String, CaseIterable, Identifiable {
  case type, project, backend

  public static let `default` = MenuBarStorageSplit.type

  public var id: String { rawValue }

  static func known(_ raw: String?) -> MenuBarStorageSplit {
    raw.flatMap(MenuBarStorageSplit.init(rawValue:)) ?? .default
  }

  var name: String {
    switch self {
    case .type: return "File Type"
    case .project: return "Project"
    case .backend: return "Backend"
    }
  }

  /// A share's name as the legend shows it: "image/svg+xml" is SVG, the
  /// assets in no project are No Project.
  func label(_ name: String) -> String {
    switch self {
    case .type:
      let subtype = name.split(separator: "/").last.map(String.init) ?? name
      let kind = subtype.split(separator: "+").first.map(String.init) ?? subtype
      return kind.isEmpty ? "Unknown" : kind.uppercased()
    case .project:
      return name.isEmpty ? "No Project" : name
    case .backend:
      return name
    }
  }
}
