import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// The Overview page — periods, heat map, Uploads —
/// against `OverviewFixture` (absolute dates; `now` Tue 2026-10-06 12:00
/// UTC; weeks from Monday and from Sunday). Every number is by hand.
@MainActor
@Suite("Overview")
struct OverviewTests {
  nonisolated static let monday = OverviewFixture.calendar(firstWeekday: 2)
  nonisolated static let sunday = OverviewFixture.calendar(firstWeekday: 1)

  static func day(_ ymd: String) -> Date { OverviewFixture.date(ymd + "T00:00:00Z") }

  static func model(
    _ stats: CatalogStats, _ kind: OverviewPeriod.Kind = .week, _ offset: Int = 0,
    calendar: Calendar = monday
  ) -> OverviewModel {
    OverviewModel(
      stats: stats, period: OverviewPeriod(kind: kind, offset: offset), now: OverviewFixture.now,
      calendar: calendar)
  }

  static func withStats(
    project: String? = nil, calendar: Calendar = monday, _ body: (CatalogStats) throws -> Void
  ) async throws {
    try await OverviewFixture.withDatabase { database in
      try body(try await CatalogStats.load(project: project, calendar: calendar, in: database))
    }
  }

  // MARK: - Periods

  @Test("Week titles — This Week, Last Week, within a month, across two — weeks from Monday")
  func weekTitlesMonday() async throws {
    try await Self.withStats { stats in
      let titles = [0, -1, -2, -5].map { Self.model(stats, .week, $0).uploads }
      #expect(titles.map(\.title) == ["This Week", "Last Week", "Sep 21 – 27", "Aug 31 – Sep 6"])
      #expect(
        titles.map(\.subtitle)
          == ["Oct 5 – 11, 2026", "Sep 28 – Oct 4, 2026", "Sep 21 – 27, 2026", "Aug 31 – Sep 6, 2026"])
      #expect(titles.map(\.canGoForward) == [false, true, true, true])
    }
  }

  @Test("Week titles — weeks from Sunday")
  func weekTitlesSunday() async throws {
    try await Self.withStats(calendar: Self.sunday) { stats in
      let titles = [0, -1, -2, -5].map { Self.model(stats, .week, $0, calendar: Self.sunday).uploads }
      #expect(titles.map(\.title) == ["This Week", "Last Week", "Sep 20 – 26", "Aug 30 – Sep 5"])
      #expect(
        titles.map(\.subtitle)
          == ["Oct 4 – 10, 2026", "Sep 27 – Oct 3, 2026", "Sep 20 – 26, 2026", "Aug 30 – Sep 5, 2026"])
    }
  }

  @Test("Month and year titles")
  func monthYearTitles() async throws {
    try await Self.withStats { stats in
      let months = [0, -1].map { Self.model(stats, .month, $0).uploads }
      #expect(months.map(\.title) == ["This Month", "September 2026"])
      #expect(months.map(\.subtitle) == ["Oct 1 – 31, 2026", "Sep 1 – 30, 2026"])
      let years = [0, -1].map { Self.model(stats, .year, $0).uploads }
      #expect(years.map(\.title) == ["This Year", "2025"])
      #expect(years.map(\.subtitle) == ["Jan – Dec 2026", "Jan – Dec 2025"])
      // The design's "Avg / month" names the unit only.
      #expect(years.map(\.averageUnit) == ["month", "month"])
      #expect(months.map(\.averageUnit) == ["day", "day"])
    }
  }

  // MARK: - Uploads bars

  @Test("This week's bars, total and average — Sunday's upload changes week with firstWeekday")
  func weekBars() async throws {
    try await Self.withStats { stats in
      let week = Self.model(stats).uploads
      #expect(week.bars.map(\.tick) == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
      #expect(week.bars.map(\.count) == [2, 1, 0, 0, 0, 0, 0])
      #expect(week.bars.map(\.isFuture) == [false, false, true, true, true, true, true])
      #expect(week.total == 3)
      #expect(week.bytes == 3_018)
      // Over Monday and today, not the seven days.
      #expect(week.average == 1.5)

      let last = Self.model(stats, .week, -1).uploads
      #expect(last.bars.map(\.count) == [1, 0, 0, 0, 0, 0, 1])
      #expect(last.average == 2.0 / 7)
    }
    try await Self.withStats(calendar: Self.sunday) { stats in
      let week = Self.model(stats, calendar: Self.sunday).uploads
      #expect(week.bars.map(\.tick) == ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])
      #expect(week.bars.map(\.count) == [1, 2, 1, 0, 0, 0, 0])
      #expect(week.total == 4)
      #expect(week.average == 4.0 / 3)
    }
  }

  @Test("Month bars by day, year bars by month; future ones not counted")
  func monthYearBars() async throws {
    try await Self.withStats { stats in
      let month = Self.model(stats, .month).uploads
      #expect(month.bars.count == 31)
      #expect(month.bars.filter { $0.count > 0 }.map { ($0.index, $0.count) }.map { "\($0.0):\($0.1)" } == ["3:1", "4:2", "5:1"])
      #expect(month.bars.map(\.tick).filter { !$0.isEmpty } == ["1", "8", "15", "22", "29"])
      #expect(month.bars.filter { !$0.isFuture }.count == 6)
      #expect(month.total == 4)
      #expect(month.average == 4.0 / 6)
      #expect(month.bars[1].title == "Oct 2, 2026")

      let september = Self.model(stats, .month, -1).uploads
      #expect(september.total == 4)
      #expect(september.average == 4.0 / 30)

      let year = Self.model(stats, .year).uploads
      #expect(year.bars.map(\.tick) == ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"])
      #expect(year.bars.map(\.count) == [0, 0, 0, 0, 0, 0, 8, 5, 4, 4, 0, 0])
      #expect(year.bars.map(\.isFuture) == Array(repeating: false, count: 10) + [true, true])
      #expect(year.bars[8].title == "September 2026")
      #expect(year.total == 21)
      #expect(year.average == 2.1)

      let lastYear = Self.model(stats, .year, -1).uploads
      #expect(lastYear.bars.map(\.count) == [0, 0, 1, 0, 0, 0, 0, 0, 0, 2, 0, 0])
      #expect(lastYear.total == 3)
      #expect(lastYear.bytes == 3_010)
      #expect(lastYear.average == 0.25)
    }
  }

  // MARK: - Heat map

  @Test("53 weeks from Monday — the day before is out, the boundary day is the first cell")
  func heatmapMonday() async throws {
    try await Self.withStats { stats in
      let heat = Self.model(stats).heatmap
      // 52 full weeks, then Monday and today.
      #expect(heat.cells.count == 366)
      #expect(heat.cells.first?.day == Self.day("2025-10-06"))
      #expect(heat.cells.first.map { [$0.week, $0.row, $0.count] } == [0, 0, 1])
      #expect(heat.cells.last.map { [$0.week, $0.row] } == [52, 1])
      #expect(heat.total == 22)
      #expect(heat.longestStreak == 3)
      #expect(heat.header == "22 uploads in the last 12 months · longest streak 3 days")
      #expect(heat.weekdayLabels == [0: "Mon", 2: "Wed", 4: "Fri"])
      #expect(
        heat.monthLabels == [
          4: "Nov", 8: "Dec", 13: "Jan", 17: "Feb", 21: "Mar", 26: "Apr", 30: "May", 34: "Jun",
          39: "Jul", 43: "Aug", 48: "Sep",
        ])
      // October starts in the last column: one column is no room for its
      // name, so it goes unnamed rather than cut.
      #expect(heat.monthLabels[52] == nil)
      // This week is the period: only its days are drawn full.
      #expect(heat.cells.filter(\.inPeriod).map(\.day) == [Self.day("2026-10-05"), Self.day("2026-10-06")])
    }
  }

  @Test("53 weeks from Sunday — the same upload is the first cell")
  func heatmapSunday() async throws {
    try await Self.withStats(calendar: Self.sunday) { stats in
      let heat = Self.model(stats, calendar: Self.sunday).heatmap
      #expect(heat.cells.count == 367)
      #expect(heat.cells.first?.day == Self.day("2025-10-05"))
      #expect(heat.cells.prefix(2).map(\.count) == [1, 1])
      #expect(heat.total == 23)
      #expect(heat.weekdayLabels == [1: "Mon", 3: "Wed", 5: "Fri"])
      #expect(heat.monthLabels[9] == "Dec")
      #expect(heat.monthLabels[35] == "Jun")
      #expect(heat.monthLabels[8] == nil)
      #expect(
        heat.cells.filter(\.inPeriod).map(\.day)
          == [Self.day("2026-10-04"), Self.day("2026-10-05"), Self.day("2026-10-06")])
    }
  }

  @Test("A month starting with exactly monthLabelColumns columns left is named; one starting with fewer is not — both calendars")
  func monthLabelEdge() {
    #expect(OverviewModel.monthLabelColumns == 2)
    let period = DateInterval(start: Self.day("2026-10-01"), duration: 86_400)
    func labels(_ calendar: Calendar, now: String) -> [Int: String] {
      OverviewModel.heatmap([:], period: period, now: Self.day(now), calendar: calendar).monthLabels
    }
    // October's first week column is the last but one (51 of 0...52): its
    // own column and the last make two, the room a name needs — named. The
    // last column then continues October and is not a new month.
    // Monday weeks: Oct 5 starts column 51; this week is Oct 12.
    let mondayEdge = labels(Self.monday, now: "2026-10-14")
    #expect(mondayEdge[51] == "Oct")
    #expect(mondayEdge[52] == nil)
    #expect(mondayEdge.keys.max() == 51)
    // Sunday weeks: Oct 4 starts column 51; this week is Oct 11.
    let sundayEdge = labels(Self.sunday, now: "2026-10-14")
    #expect(sundayEdge[51] == "Oct")
    #expect(sundayEdge[52] == nil)
    #expect(sundayEdge.keys.max() == 51)
    // One day on from the old fixture: October starts in the very last
    // column, only one is left — unnamed — and September, two columns
    // earlier at 48, is still named.
    let mondayLast = labels(Self.monday, now: "2026-10-06")
    #expect(mondayLast[52] == nil)
    #expect(mondayLast[51] == nil)
    #expect(mondayLast[48] == "Sep")
    // Sunday weeks, Oct 4 = last column (this week is Oct 4): same, one left.
    let sundayLast = labels(Self.sunday, now: "2026-10-04")
    #expect(sundayLast[52] == nil)
    #expect(sundayLast[51] == nil)
    #expect(sundayLast.keys.max().map { $0 < 51 } == true)
  }

  @Test("The five levels — 0, 1–2, 3–4, 5–7, 8+ — on the fixture's days")
  func heatLevels() async throws {
    try await Self.withStats { stats in
      let cells = Dictionary(uniqueKeysWithValues: Self.model(stats).heatmap.cells.map { ($0.day, $0) })
      #expect(cells[Self.day("2026-01-01")]?.level == 0)
      #expect(cells[Self.day("2026-10-05")].map { [$0.count, $0.level] } == [2, 1])
      #expect(cells[Self.day("2026-09-15")].map { [$0.count, $0.level] } == [3, 2])
      #expect(cells[Self.day("2026-08-20")].map { [$0.count, $0.level] } == [5, 3])
      #expect(cells[Self.day("2026-07-01")].map { [$0.count, $0.level] } == [8, 4])
      #expect([0, 1, 2, 3, 4, 5, 7, 8, 40].map(OverviewModel.level) == [0, 1, 1, 2, 2, 3, 3, 4, 4])
      // The period fades the rest: a year holds Jul 1.
      let year = Self.model(stats, .year).heatmap
      #expect(year.cells.first { $0.day == Self.day("2026-07-01") }?.inPeriod == true)
      #expect(year.cells.first { $0.day == Self.day("2025-12-31") }?.inPeriod == false)
    }
  }

  // MARK: - Through the app

  private func start(_ database: DatabasePool) async throws -> (PinaxAppModel, GalleryModel) {
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try #require(UserDefaults(suiteName: "pinaxui-t09-\(UUID().uuidString)")),
      databaseOpener: { database },
      chooseSourceFolder: { _ in nil })
    await app.start()
    let gallery = try #require(app.gallery)
    gallery.overviewNow = { OverviewFixture.now }
    gallery.overviewCalendar = Self.monday
    // What the window's `.task` runs at launch: the summaries and Time's months.
    await gallery.loadInitialData()
    return (app, gallery)
  }

  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func showOverview(_ gallery: GalleryModel) async {
    gallery.select(.overview, in: .reports)
    await gallery.reload()
  }

  @Test("All Projects and one project — the page reads the current project's numbers")
  func scopes() async throws {
    try await OverviewFixture.withDatabase { database in
      let (app, gallery) = try await start(database)
      await showOverview(gallery)
      #expect(gallery.overview?.uploads.total == 3)
      #expect(gallery.overview?.heatmap.total == 22)

      // The app's own write: the shell pushes it and the page re-reads.
      app.preferences.currentProjectSlug = "blog"
      await waitUntil { gallery.overviewStats?.project == "blog" }
      #expect(gallery.overviewStats?.project == "blog")
      // Blog this week: 5 on Monday, 7 today. In 53 weeks: 1 3 4 5 7.
      #expect(gallery.overview?.uploads.bars.map(\.count) == [1, 1, 0, 0, 0, 0, 0])
      #expect(gallery.overview?.heatmap.total == 5)
    }
  }

  /// The page's content as `OverviewView` lays it out in a wide window.
  static func page(_ gallery: GalleryModel, width: CGFloat = 1_300) -> OverviewContent {
    OverviewContent(model: gallery, layout: OverviewLayout(pageWidth: width))
  }

  private func heatCard(_ gallery: GalleryModel) throws -> OverviewHeatmapCard {
    try #require(collectViews(Self.page(gallery), as: OverviewHeatmapCard.self).first)
  }

  private func uploadsCard(_ gallery: GalleryModel) throws -> OverviewUploadsCard {
    try #require(collectViews(Self.page(gallery), as: OverviewUploadsCard.self).first)
  }

  @Test("Heat-map hover shows the day's line; a click opens its month in Time")
  func heatmapClosures() async throws {
    try await OverviewFixture.withDatabase { database in
      let (_, gallery) = try await start(database)
      await showOverview(gallery)
      #expect(try heatCard(gallery).hoverLine == nil)

      try heatCard(gallery).hover(Self.day("2026-07-01"))
      #expect(try heatCard(gallery).hoverLine == "Jul 1, 2026 · 8 uploads")
      try heatCard(gallery).hover(Self.day("2026-10-06"))
      #expect(try heatCard(gallery).hoverLine == "Oct 6, 2026 · 1 upload")
      try heatCard(gallery).hover(nil)
      #expect(try heatCard(gallery).hoverLine == nil)

      try heatCard(gallery).open(Self.day("2026-08-20"))
      #expect(gallery.navigator == .time)
      #expect(gallery.sidebarSelection == .month("2026-08"))

      // A month with no uploads has no row in Time: nothing moves.
      gallery.select(.overview, in: .reports)
      try heatCard(gallery).open(Self.day("2026-01-14"))
      #expect(gallery.sidebarSelection == .overview)
    }
  }

  @Test("Week | Month | Year, ‹ ›, and a bar's click, through the card's closures")
  func uploadsClosures() async throws {
    try await OverviewFixture.withDatabase { database in
      let (_, gallery) = try await start(database)
      await showOverview(gallery)

      try uploadsCard(gallery).move(1)
      #expect(gallery.overviewPeriod == OverviewPeriod(kind: .week, offset: 0))
      try uploadsCard(gallery).move(-1)
      #expect(try uploadsCard(gallery).uploads.title == "Last Week")
      try uploadsCard(gallery).choose(.year)
      #expect(gallery.overviewPeriod == OverviewPeriod(kind: .year, offset: 0))
      // The heat map fades by the same period.
      #expect(try heatCard(gallery).heatmap.cells.filter(\.inPeriod).count == 279)

      let september = try #require(try uploadsCard(gallery).uploads.bars.first { $0.title == "September 2026" })
      try uploadsCard(gallery).open(september.start)
      #expect(gallery.sidebarSelection == .month("2026-09"))
    }
  }

  // MARK: - Cards

  @Test("The hero band on All Projects — values, details, running totals, Used's share")
  func heroAll() async throws {
    try await Self.withStats { stats in
      let hero = Self.model(stats).hero
      #expect(hero.map(\.kind) == OverviewModel.Hero.Kind.allCases)
      #expect(hero.map(\.title) == ["Assets", "Storage", "Uploads", "Used"])
      // 24 active (8 is archived), 24,292 B; 3 uploads this week; 2 live-used.
      #expect(hero.map(\.value) == ["24", "24 kB", "3", "2"])
      #expect(hero.map(\.detail) == ["+3 · This Week", "+3 kB · This Week", "1.5 / day", "of 24 assets"])
      // Monday 5 and 6, Tuesday 7: the library at Monday's end is today's
      // less Tuesday's one, 1,007 B.
      #expect(hero[0].sparkline == [23, 24])
      #expect(hero[1].sparkline == [23_285, 24_292])
      #expect(hero[2].sparkline == [2, 1])
      #expect(hero.map(\.highlighted) == [1, 1, 0, nil])
      #expect(hero[3].sparkline.isEmpty)
      #expect(hero.map(\.ratio) == [nil, nil, nil, 2.0 / 24])
    }
  }

  @Test("Running totals count back from today's — a year by month, and last year")
  func heroRunningTotals() async throws {
    try await Self.withStats { stats in
      // 2026: Jul 8, Aug 5, Sep 4, Oct 4 = 21 of 24; 0, 1 and 9 are older.
      let year = Self.model(stats, .year).hero
      #expect(year[0].sparkline == [3, 3, 3, 3, 3, 3, 11, 16, 20, 24])
      #expect(year[0].highlighted == 9)
      #expect(year[2].sparkline == [0, 0, 0, 0, 0, 0, 8, 5, 4, 4])
      #expect(year[2].highlighted == 6)
      #expect(year[2].detail == "2.1 / month")
      // 2025: 9 in March, 0 and 1 in October; the 21 of 2026 come after.
      let lastYear = Self.model(stats, .year, -1).hero
      #expect(lastYear[0].sparkline == [0, 0, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3])
      #expect(lastYear[1].sparkline.last == 3_010)
      #expect(lastYear[0].value == "24")
      #expect(lastYear[0].detail == "+3 · 2025")
    }
  }

  @Test("The average's text — one decimal at most, the calendar's locale, the card's and the hero's alike")
  func averageText() async throws {
    try await Self.withStats { stats in
      // This week: 3 uploads over Monday and Tuesday; 2026 by month: 21 over 10.
      #expect(Self.model(stats).uploads.averageText == "1.5")
      #expect(Self.model(stats, .year).uploads.averageText == "2.1")
      // Last week: 2 over 7 days.
      #expect(Self.model(stats, .week, -1).uploads.averageText == "0.3")
      var german = Self.monday
      german.locale = Locale(identifier: "de_DE")
      let model = Self.model(stats, calendar: german)
      #expect(model.uploads.averageText == "1,5")
      #expect(model.hero[2].detail == "1,5 / day")
    }
  }

  @Test("The chart's scale starts at 0 and reaches at least 2; no average line at 0")
  func chartScale() async throws {
    try await Self.withStats { stats in
      // This week: Monday 2, Tuesday 1 — the scale is the busiest's, 2.
      let week = Self.model(stats).uploads
      #expect(week.scaleTop == 2)
      #expect(week.averageLine == 1.5)
      // 2026 by month: July's 8.
      #expect(Self.model(stats, .year).uploads.scaleTop == 8)
      // Last week: 1 and 1 — still 0…2, so the axis has whole ticks.
      #expect(Self.model(stats, .week, -1).uploads.scaleTop == 2)
      // Sep 7 – 13: nothing. The scale stays 0…2 and the line is not drawn
      // (Charts centres an all-zero scale on 0, floating the line midway).
      let empty = Self.model(stats, .week, -4).uploads
      #expect(empty.scaleTop == 2)
      #expect(empty.average == 0)
      #expect(empty.averageLine == nil)
    }
  }

  @Test("The peak is the first of the busiest bars, nil with none")
  func uploadsPeak() async throws {
    try await Self.withStats { stats in
      #expect(Self.model(stats).uploads.peak == 0)
      // Last week: Monday 1, Sunday 1 — the first.
      #expect(Self.model(stats, .week, -1).uploads.peak == 0)
      #expect(Self.model(stats, .year, -1).uploads.peak == 9)
      // Sep 7 – 13: no uploads.
      #expect(Self.model(stats, .week, -4).uploads.peak == nil)
      #expect(Self.model(stats, .week, -4).hero[2].highlighted == nil)
      #expect(Self.model(stats, .week, -4).hero[1].detail == "+0 bytes · Sep 7 – 13")
    }
  }

  @Test("The hero band on one project")
  func heroBlog() async throws {
    try await Self.withStats(project: "blog") { stats in
      let hero = Self.model(stats).hero
      // blog: 0, 1, 3, 4, 5, 7 active; Monday 5, Tuesday 7.
      #expect(hero.map(\.value) == ["6", "6 kB", "2", "2"])
      #expect(hero[0].sparkline == [5, 6])
      #expect(hero[2].detail == "1 / day")
      #expect(hero[3].detail == "of 6 assets")
      #expect(hero[3].ratio == 2.0 / 6)
    }
  }

  @Test("Library and Usage rows — figures, zero greys, destinations")
  func listRows() async throws {
    try await Self.withStats { stats in
      let model = Self.model(stats)
      #expect(model.library.map(\.title) == ["Favorites", "Archived", "Tagged"])
      // travel on 2, 3, 7; cover on 4 and 7: 4 tagged of 24.
      #expect(model.library.map(\.value) == ["1", "1", "4 / 24"])
      #expect(model.library.map(\.destination) == [.favorites, .archived, nil])
      #expect(model.usage.map(\.title) == ["Used Images", "Orphan Candidates", "Domains"])
      #expect(model.usage.map(\.value) == ["2", "22", "2 yours · 1 old"])
      #expect(model.usage.map(\.destination) == [.usage, .orphans, .yourDomains])
      #expect((model.library + model.usage).allSatisfy { !$0.isZero })
    }
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<3 {
      try seedAsset(database, index: index, uploadedAt: "2026-09-01T10:00:00Z")
    }
    let stats = try await CatalogStats.load(calendar: Self.monday, in: database)
    let model = Self.model(stats)
    #expect(model.library.map(\.isZero) == [true, true, true])
    #expect(model.library[2].value == "0 / 3")
    // Nothing used: all three are orphan candidates.
    #expect(model.usage.map(\.value) == ["0", "3", "0 yours · 0 old"])
    #expect(model.usage.map(\.isZero) == [true, false, true])
    #expect(model.composition[2].segments.isEmpty)
    #expect(model.composition[2].figures == "3 untagged")
  }

  @Test("Composition — each share of its whole, format and backend hues")
  func composition() async throws {
    try await Self.withStats { stats in
      let rows = Self.model(stats).composition
      #expect(rows.map(\.title) == ["Kind", "Backend", "Tags"])
      typealias Segment = OverviewModel.Composition.Segment
      #expect(
        rows[0].segments == [
          Segment(name: "PNG", fraction: 22.0 / 24, hue: .aqua),
          Segment(name: "JPEG", fraction: 2.0 / 24, hue: .blue),
        ])
      #expect(rows[0].figures == "PNG 22 · JPEG 2")
      #expect(
        rows[1].segments == [
          Segment(name: "r2", fraction: 23.0 / 24, hue: .orange),
          Segment(name: "b2", fraction: 1.0 / 24, hue: .yellow),
        ])
      #expect(rows[1].figures == "r2 23 · b2 1")
      #expect(rows[2].segments == [Segment(name: "Tagged", fraction: 4.0 / 24, hue: .purple)])
      #expect(rows[2].figures == "4 tagged · 20 untagged")
    }
    try await Self.withStats(project: "notes") { stats in
      let rows = Self.model(stats).composition
      // notes: 2, 4, 7 PNG and 9 JPEG, all on r2 (4,022 B); 3 of 4 tagged.
      #expect(rows[0].figures == "PNG 3 · JPEG 1")
      #expect(rows[1].segments == [OverviewModel.Composition.Segment(name: "r2", fraction: 1, hue: .orange)])
      #expect(rows[1].figures == "r2 4 · 4 kB")
      #expect(rows[2].segments.map(\.fraction) == [0.75])
      #expect(rows[2].figures == "3 tagged · 1 untagged")
    }
  }

  @Test("Usage by Project — numbers per project, Last Scan in the calendar's zone")
  func projectsCard() async throws {
    try await Self.withStats { stats in
      let rows = Self.model(stats).projects
      #expect(rows.map(\.slug) == ["blog", "notes"])
      #expect(rows.map { [$0.used, $0.orphanCandidates, $0.yourDomains, $0.otherDomains] } == [[2, 4, 2, 1], [0, 4, 0, 0]])
      #expect(rows.map(\.lastScan) == ["Today 10:01", "Never scanned"])
      let tomorrow = OverviewModel(
        stats: stats, period: OverviewPeriod(), now: OverviewFixture.date("2026-10-07T08:00:00Z"),
        calendar: Self.monday)
      #expect(tomorrow.projects.map(\.lastScan) == ["Yesterday 10:01", "Never scanned"])
      let later = OverviewModel(
        stats: stats, period: OverviewPeriod(), now: OverviewFixture.date("2026-10-08T08:00:00Z"),
        calendar: Self.monday)
      #expect(later.projects.first?.lastScan == "Oct 6, 2026")
    }
    let west = OverviewFixture.calendar(firstWeekday: 2, timeZone: TimeZone(secondsFromGMT: -3_600)!)
    try await Self.withStats(calendar: west) { stats in
      #expect(Self.model(stats, calendar: west).projects.first?.lastScan == "Today 09:01")
    }
    try await Self.withStats(project: "blog") { stats in
      #expect(Self.model(stats).projects.map(\.slug) == ["blog"])
    }
    try await UsageNotTrackedTests.withFixture { database in
      let stats = try await CatalogStats.load(calendar: Self.monday, in: database)
      let rows = Self.model(stats).projects
      let notTracked = Set(stats.projects.filter { $0.usageTracking == .notTracked }.map(\.slug))
      #expect(notTracked == ["desk", "press", "social", "wire"])
      #expect(
        rows.filter { notTracked.contains($0.slug) }.map(\.lastScan)
          == Array(repeating: "Not tracked", count: 4))
    }
  }

  @Test("The page hands each part the model's values")
  func cardsThroughTheView() async throws {
    try await OverviewFixture.withDatabase { database in
      let (_, gallery) = try await start(database)
      await showOverview(gallery)
      let overview = try #require(gallery.overview)
      let view = Self.page(gallery)
      #expect(try #require(collectViews(view, as: OverviewHeroBand.self).first).cells == overview.hero)
      let lists = collectViews(view, as: OverviewListGroup.self).sorted { $0.title < $1.title }
      #expect(lists.map(\.title) == ["Library", "Usage"])
      #expect(lists.map(\.rows) == [overview.library, overview.usage])
      #expect(try #require(collectViews(view, as: OverviewCompositionList.self).first).rows == overview.composition)
      #expect(try #require(collectViews(view, as: OverviewProjectsList.self).first).projects == overview.projects)
    }
  }

  // MARK: - Default leaf and clicks

  @Test("Overview is Reports' default leaf")
  func overviewIsReportsDefault() async throws {
    #expect(GalleryModel.defaultNavigatorSelections()[.reports] == .overview)
    try await OverviewFixture.withDatabase { database in
      let (_, gallery) = try await start(database)
      gallery.navigator = .reports
      #expect(gallery.sidebarSelection == .overview)
      // The window's reload token drives this in the app.
      await gallery.reload()
      #expect(gallery.overview?.heatmap.total == 22)
    }
  }

  @Test("A list row opens its page — through the list's closure")
  func cardAndTagClicks() async throws {
    try await OverviewFixture.withDatabase { database in
      let (_, gallery) = try await start(database)
      await showOverview(gallery)
      let view = Self.page(gallery)
      let grid = try #require(collectViews(view, as: OverviewListGroup.self).first)
      // Old Domains before Usage: Usage must clear what Old Domains set.
      let expected: [(OverviewModel.Destination, SidebarNavigator, SidebarSelection, Bool)] = [
        (.favorites, .library, .favorites, false), (.archived, .library, .archived, false),
        (.oldDomains, .reports, .usage, true), (.usage, .reports, .usage, false),
        (.orphans, .reports, .orphans, false),
      ]
      for (destination, navigator, selection, oldDomainsOnly) in expected {
        await showOverview(gallery)
        grid.open(destination)
        #expect(gallery.navigator == navigator, "\(destination)")
        #expect(gallery.sidebarSelection == selection, "\(destination)")
        #expect(gallery.usageOldDomainsOnly == oldDomainsOnly, "\(destination)")
      }
      await showOverview(gallery)
      gallery.externals.domain = .other
      grid.open(.yourDomains)
      #expect(gallery.navigator == .reports)
      #expect(gallery.sidebarSelection == .externals)
      #expect(gallery.externals.domain == .yours)
    }
  }

  @Test("A Usage by Project number makes its project current and opens its report")
  func projectNumberClicks() async throws {
    try await OverviewFixture.withDatabase { database in
      let (app, gallery) = try await start(database)
      await showOverview(gallery)
      let card = try #require(collectViews(Self.page(gallery), as: OverviewProjectsList.self).first)
      #expect(card.projects.map(\.slug) == ["blog", "notes"])
      let cases: [(String, OverviewModel.ProjectColumn, SidebarSelection, ExternalDomain?)] = [
        ("notes", .orphanCandidates, .orphans, nil), ("blog", .used, .usage, nil),
        ("notes", .yourDomains, .externals, .yours), ("blog", .otherDomains, .externals, .other),
      ]
      for (slug, column, selection, domain) in cases {
        gallery.usageOldDomainsOnly = true
        card.open(slug, column)
        #expect(app.preferences.currentProjectSlug == slug, "\(slug) \(column)")
        await waitUntil { gallery.currentProjectSlug == slug }
        #expect(gallery.currentProjectSlug == slug, "\(slug) \(column)")
        #expect(gallery.navigator == .reports, "\(slug) \(column)")
        #expect(gallery.sidebarSelection == selection, "\(slug) \(column)")
        if let domain { #expect(gallery.externals.domain == domain, "\(slug) \(column)") }
        if selection == .usage { #expect(!gallery.usageOldDomainsOnly) }
      }
    }
  }

  // MARK: - Width

  @Test("The page folds — 4, 2, 1 hero cells to a row; the lists under the chart when narrow")
  func layoutFolds() {
    let widths: [CGFloat] = [400, 680, 900, 1_300]
    #expect(widths.map { OverviewLayout(pageWidth: $0).contentWidth } == [352, 632, 852, 1_240])
    #expect(widths.map { OverviewLayout(pageWidth: $0).heroColumns } == [2, 2, 4, 4])
    #expect(widths.map { OverviewLayout(pageWidth: $0).columnsSideBySide } == [false, false, true, true])
    // 4 × 160 + 3 × 12 = 676 is the four-cell edge; 2 × 160 + 12 the two.
    #expect(OverviewLayout(pageWidth: 676 + 48).heroColumns == 4)
    #expect(OverviewLayout(pageWidth: 675 + 48).heroColumns == 2)
    #expect(OverviewLayout(pageWidth: 331 + 48).heroColumns == 1)
    // 2 × 320 + 14 = 654 is the two-column edge.
    #expect(OverviewLayout(pageWidth: 654 + 48).columnsSideBySide)
    #expect(!OverviewLayout(pageWidth: 653 + 48).columnsSideBySide)
  }

  @Test("The hero cells go in rows of `columns`")
  func metricRows() async throws {
    try await Self.withStats { stats in
      let hero = Self.model(stats).hero
      #expect(OverviewHeroBand.rows(hero, columns: 4).map(\.count) == [4])
      #expect(OverviewHeroBand.rows(hero, columns: 2).map(\.count) == [2, 2])
      #expect(OverviewHeroBand.rows(hero, columns: 1).count == 4)
      #expect(OverviewHeroBand.rows(hero, columns: 2).flatMap { $0 } == hero)
    }
  }

  @Test("At every width down to the detail column's minimum, the page fits")
  func pageFitsItsWidth() async throws {
    try await OverviewFixture.withDatabase { database in
      let (_, gallery) = try await start(database)
      await showOverview(gallery)
      #expect(gallery.overview != nil)
      for pageWidth: CGFloat in [GalleryWidthBudget.detailMin, 680, 1_300] {
        let layout = OverviewLayout(pageWidth: pageWidth)
        // The page sits in a vertical ScrollView, which proposes no height:
        // the vertical fixedSize asks the same question.
        let host = NSHostingController(
          rootView: Self.page(gallery, width: pageWidth).fixedSize(horizontal: false, vertical: true))
        let size = host.sizeThatFits(in: CGSize(width: layout.contentWidth, height: 100_000))
        #expect(size.width <= layout.contentWidth + 0.5, "page \(pageWidth): \(size)")
        // Cards that fill their row must not stretch the page without end.
        #expect(size.height < 5_000, "page \(pageWidth): \(size)")
      }
    }
  }

  @Test("The heat map's five levels — grey, then gruvbox green at 30, 50, 75, 100 %")
  func heatPalette() {
    typealias RGBA = PinaxPalette.RGBA
    #expect(
      (0..<5).map { OverviewPalette.heatValue($0, dark: false) } == [
        RGBA(0, 0, 0, 0.06), RGBA(152, 151, 26, 0.30), RGBA(152, 151, 26, 0.50),
        RGBA(152, 151, 26, 0.75), RGBA(152, 151, 26),
      ])
    #expect(
      (0..<5).map { OverviewPalette.heatValue($0, dark: true) } == [
        RGBA(255, 255, 255, 0.07), RGBA(184, 187, 38, 0.30), RGBA(184, 187, 38, 0.50),
        RGBA(184, 187, 38, 0.75), RGBA(184, 187, 38),
      ])
    // A count's level picks its colour: the view indexes `heat` by level.
    #expect(OverviewPalette.heat.count == 5)
    #expect([0, 2, 4, 7, 8].map(OverviewModel.level) == [0, 1, 2, 3, 4])
  }

  @Test("The page, card and rim colours, and the key sizes")
  func boardValues() {
    #expect(OverviewPalette.value(.page, dark: false).description == "#e9e9ec")
    #expect(OverviewPalette.value(.page, dark: true).description == "#1c1c1e")
    #expect(OverviewPalette.value(.card, dark: false).description == "#f4f4f6")
    #expect(OverviewPalette.value(.card, dark: true).description == "#2c2c2e")
    #expect(OverviewPalette.value(.line, dark: false).description == "#000000@0.08")
    #expect(OverviewPalette.value(.line, dark: true).description == "#ffffff@0.08")
    let d = DesignMetrics.overviewD.self
    #expect([d.cardRadius, d.rimWidth, d.columnGap] == [10, 0.5, 14])
    #expect([d.sparkBarWidth, d.sparkBarGap, d.sparkHeight, d.sparkBarRadius] == [3, 2, 24, 1.5])
    #expect([d.heatCellRadius, d.heatLegendRadius, DesignMetrics.overview.heatLegendCell] == [3, 2.5, 10])
    #expect([d.chartHeight, d.averageLineWidth, DesignMetrics.overview.barCornerRadius] == [104, 1.5, 4])
    #expect([d.rowHeight, d.projectRowHeight, d.seamHeight, d.seamRadius] == [34, 42, 10, 4])
    #expect([d.compositionLabelWidth, d.compositionFigureWidth] == [56, 104])
    #expect(OverviewSparkline.bar(count: 12) == (3, 2))
    // A month's 31 bars share the twelve's 58 pt with 1 pt gaps.
    #expect(OverviewSparkline.bar(count: 31) == ((58 - 30) / 31, 1))
  }

  @Test("Every hero and list symbol exists")
  func symbolsExist() {
    let names =
      OverviewModel.Hero.Kind.allCases.map(OverviewHeroCell.symbol)
      + OverviewModel.ListRow.Kind.allCases.map(OverviewListGroup.symbol)
      + ["square.grid.3x3.fill", "folder.fill", "chevron.left", "chevron.right"]
    for name in names {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  @Test("The heat map's pitch follows the card, 14…22, and scrolls only below 14")
  func heatPitch() {
    // Room = content − 2 × 16 card padding − 32 weekday column, over 53.
    let widths: [CGFloat] = [400, 680, 900, 1_100, 1_300]
    #expect(widths.map { OverviewLayout(pageWidth: $0).heatPitch } == [14, 14, 14, 18, 22])
    #expect(widths.map { OverviewLayout(pageWidth: $0).heatScrolls } == [true, true, false, false, false])
    // 53 × 14 + 32 + 32 = 806 content is the edge where scrolling stops.
    #expect(!OverviewLayout(pageWidth: 806 + 48).heatScrolls)
    #expect(OverviewLayout(pageWidth: 805 + 48).heatScrolls)
  }

  @Test("The weekday names have their own column; cells start after it")
  func heatWeekdayColumn() async throws {
    try await Self.withStats { stats in
      let heatmap = Self.model(stats).heatmap
      for pitch: CGFloat in [14, 22] {
        let card = OverviewHeatmapCard(
          heatmap: heatmap, pitch: pitch, scrolls: false, hoverLine: nil, hover: { _ in }, open: { _ in })
        let size = NSHostingController(rootView: card.fixedSize()).sizeThatFits(
          in: CGSize(width: 100_000, height: 100_000))
        let expected =
          DesignMetrics.overview.heatWeekdayWidth + CGFloat(OverviewModel.heatWeeks) * pitch
          + 2 * DesignMetrics.overview.cardHorizontalPadding
        #expect(abs(size.width - expected) < 0.5, "pitch \(pitch): \(size.width) vs \(expected)")
      }
    }
  }

  @Test("The status bar under Overview is the page's grey, elsewhere the bar")
  func statusBarGround() {
    #expect(GalleryStatusBar.usesPageGround(on: .overview))
    for selection: SidebarSelection in [.all, .usage, .orphans, .externals, .month("2026-08")] {
      #expect(!GalleryStatusBar.usesPageGround(on: selection), "\(selection)")
    }
  }
}

