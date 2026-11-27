import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// The menu bar panel's statistics card and the Library page,
/// as values. Nothing opens a panel or pops a menu; the defaults are a
/// throwaway suite, the catalog a fixture, the pasteboard a private named
/// one, the notification centre a private one and the scanner a recorder.
@MainActor
@Suite(.serialized) struct MenuBarLibraryTests {
  typealias Total = CatalogStats.Total

  /// Wednesday 21 October 2026, 15:00 UTC; the week runs Sunday 18 – Saturday 24.
  static let now = ISO8601DateFormatter().date(from: "2026-10-21T15:00:00Z")!

  static var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }

  private static func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

  private static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

  private static func stats(
    orphans: Int = 0, backends: [CatalogStats.Share] = [], kinds: [CatalogStats.Share] = [],
    projectShares: [CatalogStats.Share] = [],
    projects: [CatalogStats.ProjectUsage] = [], uploadsByDay: [Date: Total] = [:]
  ) -> CatalogStats {
    CatalogStats(
      project: nil, assets: Total(count: 10, bytes: 10_000), favorites: 0, archived: 0,
      uploadsByDay: uploadsByDay, tags: [], tagged: 0, untagged: 0, kinds: kinds, backends: backends,
      usedImages: 0, orphanCandidates: Total(count: orphans, bytes: Int64(orphans) * 100),
      yourDomains: 0, oldDomains: 0, projects: projects, projectShares: projectShares)
  }

  private static func project(
    _ slug: String, lastScanAt: String?, tracking: UsageTracking = .tracked
  ) -> CatalogStats.ProjectUsage {
    CatalogStats.ProjectUsage(
      slug: slug, name: slug, used: 0, orphanCandidates: 0, yourDomains: 0, otherDomains: 0,
      lastScanAt: lastScanAt, usageTracking: tracking)
  }

  private func makeApp(
    sources: [String] = [], synchronizer: UsageSyncing? = nil
  ) async throws -> (app: PinaxAppModel, database: DatabasePool, directory: URL) {
    let (database, directory) = try makeUITestDatabase()
    for slug in sources {
      let folder = directory.appendingPathComponent("\(slug)-src", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try CatalogConfiguration.setProjectSources(
        slug: slug, [ProjectSource(label: "src", path: folder.path)], in: database)
    }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-t48-\(UUID().uuidString)"))
    let app: PinaxAppModel
    if let synchronizer {
      app = PinaxAppModel(
        dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database },
        usageSynchronizer: { _ in synchronizer }, chooseSourceFolder: { _ in nil })
    } else {
      app = PinaxAppModel(
        dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    }
    await app.start()
    await app.gallery?.refreshSourcedProjects()
    await waitUntil { app.sourcedProjects == Set(sources) }
    return (app, database, directory)
  }

  private static func source(_ path: String) throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(path),
      encoding: .utf8)
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - The card's three numbers and the 14 days

  @Test("The card's three numbers and 14 day bars equal CatalogStats: missing days are 0, today is the last bar")
  func cardEqualsStats() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Today 3, Mon 19 Oct 1 (this week), Fri 16 Oct 2 (last week), Sun 11
    // Oct 4, and 5 more 20 days back, outside the bars.
    let plan: [(days: Double, count: Int)] = [(0, 3), (2, 1), (5, 2), (10, 4), (20, 5)]
    var index = 0
    for (days, count) in plan {
      for _ in 0..<count {
        try seedAsset(
          database, index: index, uploadedAt: Self.stamp(Self.ago(days: days).addingTimeInterval(-3_600)))
        index += 1
      }
    }
    let stats = try await CatalogStats.load(project: nil, calendar: Self.utc, in: database)
    let library = MenuBarLibrary(
      stats: stats, failedUploads: 0, scanTargets: [], now: Self.now, calendar: Self.utc)

    #expect(library.images == 15)
    #expect(library.images == stats.assets.count)
    #expect(library.bytes == stats.assets.bytes)
    let days = library.chart(.day)
    #expect(days.current == 3)
    #expect(library.chart(.week).current == 4)
    #expect(days.bars.count == 14)
    // 8 Oct … 21 Oct.
    #expect(days.bars.map(\.count) == [0, 0, 0, 4, 0, 0, 0, 0, 2, 0, 0, 1, 0, 3])
    #expect(days.bars.map(\.isCurrent) == Array(repeating: false, count: 13) + [true])
    #expect(days.bars.last?.start == Self.utc.startOfDay(for: Self.now))
    for day in days.bars {
      #expect(day.count == stats.uploadsByDay[day.start]?.count ?? 0)
    }
    #expect(days.firstLabel == "Oct 8")
    #expect(library.uploadsLine(.day) == "3 today · 4 this week")
    // No scan anywhere: every image in blog is an orphan candidate.
    #expect(stats.orphanCandidates.count == 15)
    #expect(library.attention == [.orphanCandidates(15)])
    #expect(
      library.accessibilityLabel(.week)
        == "Library: 15 images, \(PinaxFormat.fileSize(stats.assets.bytes)), 4 this week. Show details.")
  }

  @Test("The app reads the current project's stats where it reads RECENT, and again when the project changes")
  func appStatsFollowCurrentProject() async throws {
    let (app, database, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", projectSlug: "notes")
    try seedAsset(database, index: 2, uploadedAt: "2026-08-03T00:00:00Z", projectSlug: "notes")
    await app.refreshRecentUploads()
    #expect(app.menuBarStats?.assets.count == 3)
    #expect(
      app.menuBarStats
        == (try await CatalogStats.load(project: nil, calendar: .current, in: database)))

    app.preferences.currentProjectSlug = "notes"
    await waitUntil { app.menuBarStats?.project == "notes" }
    #expect(app.menuBarStats?.assets.count == 2)
  }

  // MARK: - Needs attention; the card has no count

  @Test("Needs attention lists its rows; the card has no count and its label no attention")
  func attentionRowsNoBadge() throws {
    let stale = [Self.project("blog", lastScanAt: nil)]
    let none = MenuBarLibrary(
      stats: Self.stats(projects: stale), failedUploads: 0, scanTargets: [], now: Self.now,
      calendar: Self.utc)
    #expect(none.attention.isEmpty)
    #expect(none.accessibilityLabel(.week).hasSuffix("this week. Show details."))

    let all = MenuBarLibrary(
      stats: Self.stats(orphans: 12, projects: stale), failedUploads: 2, scanTargets: ["blog"],
      now: Self.now, calendar: Self.utc)
    #expect(all.attention == [.failedUploads(2), .orphanCandidates(12), .lastScan(daysAgo: nil)])
    #expect(all.attention.map(\.text) == ["2 uploads failed", "12 orphan candidates", "Never scanned"])
    #expect(all.attention.map(\.action) == ["Show Drop Zone", "Review", "Scan"])
    for unit in MenuBarChartUnit.allCases {
      #expect(!all.accessibilityLabel(unit).contains("attention"), "\(unit)")
    }

    let one = MenuBarLibrary(
      stats: Self.stats(orphans: 1), failedUploads: 0, scanTargets: [], now: Self.now,
      calendar: Self.utc)
    #expect(one.attention.map(\.text) == ["1 orphan candidate"])

    // The card draws no count: the badge view and the model's count are gone.
    let views = try Self.source("Sources/PinaxUI/DropZone/MenuBarLibraryViews.swift")
    let model = try Self.source("Sources/PinaxUI/DropZone/MenuBarLibrary.swift")
    #expect(!views.contains("Badge"))
    #expect(!views.contains("library.badge"))
    #expect(!model.contains("var badge"))
  }

  // MARK: - The Library page at the home page's height

  /// Everything the Library page can show: a storage bar and all three
  /// Needs attention rows, taller than the home page.
  static func fullLibrary() -> MenuBarLibrary {
    MenuBarLibrary(
      stats: stats(
        orphans: 12,
        kinds: [
          CatalogStats.Share(name: "image/png", total: Total(count: 3, bytes: 3_000)),
          CatalogStats.Share(name: "image/jpeg", total: Total(count: 2, bytes: 2_000)),
        ],
        projects: [project("blog", lastScanAt: nil)]),
      failedUploads: 2, scanTargets: ["blog"], now: now, calendar: utc)
  }

  @Test("Needs attention's three rows under the shortest home page: the footer stays in the panel, the middle scrolls")
  func fullPageScrollsInShortPanel() async throws {
    let (app, _, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(app.recentUploads.isEmpty)
    let full = Self.fullLibrary()
    #expect(full.attention.count == 3)
    #expect(!full.segments(app.preferences.menuBarStorageSplit).isEmpty)
    let hosted = HostedMenuBarPanel(app: app, library: full)
    defer { hosted.close() }
    await hosted.settle()
    let height = hosted.height
    await hosted.turn(to: .library)
    #expect(hosted.height == height)
    let button = try #require(hosted.overviewButton)
    #expect(hosted.frameInPanel(button).maxY <= height)
    let scroll = try #require(hosted.scrollView)
    let document = try #require(scroll.documentView)
    #expect(document.frame.height > scroll.contentView.bounds.height)
  }

  @Test("A short Library page keeps its footer at the bottom, level with the home page's Quit Pinax row")
  func shortPageFooterAtBottom() async throws {
    let (app, _, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let short = MenuBarLibrary(
      stats: Self.stats(), failedUploads: 0, scanTargets: [], now: Self.now, calendar: Self.utc)
    #expect(short.attention.isEmpty)
    let hosted = HostedMenuBarPanel(app: app, library: short)
    defer { hosted.close() }
    await hosted.settle()
    // Quit Pinax is the home page's last row, inside the panel's inset.
    let quitBottom = hosted.height - DesignMetrics.menuBarLibrary.panelPadding
    await hosted.turn(to: .library)
    let button = try #require(hosted.overviewButton)
    #expect(abs(hosted.frameInPanel(button).maxY - quitBottom) <= 1)
    let scroll = try #require(hosted.scrollView)
    let document = try #require(scroll.documentView)
    #expect(document.frame.height <= scroll.contentView.bounds.height)
  }

  // MARK: - Chart units

  /// Uploads on either side of a week, month and year boundary; no sum
  /// equals another. Wednesday 21 October 2026 is today.
  static let unitDays: [(String, Int)] = [
    ("2026-10-21", 3), ("2026-10-19", 1),  // Mon
    ("2026-10-18", 7),  // Sun: this week from Sunday, last week from Monday
    ("2026-10-17", 2),  // Sat
    ("2026-10-01", 12), ("2026-09-30", 14),  // month boundary
    ("2026-01-01", 17), ("2025-12-31", 19),  // year boundary
    ("2013-03-15", 23),  // the oldest year bar
    ("2012-06-01", 29),  // before it
  ]

  static func unitLibrary(_ calendar: Calendar) -> MenuBarLibrary {
    var days: [Date: Total] = [:]
    for (day, count) in unitDays {
      let date = ISO8601DateFormatter().date(from: "\(day)T00:00:00Z")!
      days[date] = Total(count: count, bytes: Int64(count) * 1_000)
    }
    return MenuBarLibrary(
      stats: Self.stats(uploadsByDay: days), failedUploads: 0, scanTargets: [], now: Self.now,
      calendar: calendar)
  }

  @Test("Each unit has 14 bars summed from uploadsByDay, the current period last")
  func unitBars() {
    let library = Self.unitLibrary(Self.utc)
    let zeros = { (n: Int) in Array(repeating: 0, count: n) }

    let day = library.chart(.day)
    #expect(day.bars.map(\.count) == zeros(9) + [2, 7, 1, 0, 3])
    #expect(day.firstLabel == "Oct 8")

    // Weeks from Sunday: 18 Oct 7+1+3; 11 Oct 2; 27 Sep 14+12.
    let week = library.chart(.week)
    #expect(week.bars.map(\.count) == zeros(10) + [26, 0, 2, 11])
    #expect(week.firstLabel == "Jul 19")
    #expect(week.bars.last?.start == ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z"))

    // Sep 2025 … Oct 2026: Dec 19, Jan 17, Sep 14, Oct 3+1+7+2+12.
    let month = library.chart(.month)
    #expect(month.bars.map(\.count) == [0, 0, 0, 19, 17] + zeros(7) + [14, 25])
    #expect(month.firstLabel == "Sep 2025")

    // 2013 … 2026; 2012 is outside.
    let year = library.chart(.year)
    #expect(year.bars.map(\.count) == [23] + zeros(11) + [19, 56])
    #expect(year.firstLabel == "2013")

    for chart in [day, week, month, year] {
      #expect(chart.bars.count == 14, "\(chart.unit)")
      #expect(chart.bars.map(\.isCurrent) == Array(repeating: false, count: 13) + [true])
      #expect(chart.bars.map(\.start) == chart.bars.map(\.start).sorted())
    }
    #expect([day, week, month].map(\.title) == [
      "UPLOADS · 14 DAYS", "UPLOADS · 14 WEEKS", "UPLOADS · 14 MONTHS",
    ])
    #expect([day, week, month, year].map(\.lastLabel) == [
      "Today", "This week", "This month", "This year",
    ])
  }

  @Test("Weeks start on the calendar's firstWeekday, as in Overview")
  func weeksFollowFirstWeekday() {
    var monday = Self.utc
    monday.firstWeekday = 2
    // Weeks from Monday: 19 Oct 1+3; 12 Oct 7+2; 28 Sep 14+12.
    let week = Self.unitLibrary(monday).chart(.week)
    #expect(week.bars.map(\.count) == Array(repeating: 0, count: 10) + [26, 0, 9, 4])
    #expect(week.firstLabel == "Jul 20")
  }

  @Test("The third number and its label follow the unit; the page line names it and the next longer one")
  func thirdCellFollowsUnit() {
    let library = Self.unitLibrary(Self.utc)
    let cells = MenuBarChartUnit.allCases.map { "\(library.chart($0).current) \($0.current)" }
    #expect(cells == ["3 today", "11 this week", "25 this month", "56 this year"])
    #expect(library.accessibilityLabel(.month).contains(", 25 this month. Show details."))
    #expect(library.uploadsLine(.day) == "3 today · 11 this week")
    #expect(library.uploadsLine(.week) == "11 this week · 25 this month")
    #expect(library.uploadsLine(.month) == "25 this month · 56 this year")
  }

  @Test("Menu Bar Chart defaults to Week, survives a restart, and reads an unknown value as Week")
  func chartUnitSetting() throws {
    let name = "pinaxui-t48b-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let first = PreferencesStore(defaults: defaults)
    #expect(first.menuBarChartUnit == .week)
    first.menuBarChartUnit = .month
    #expect(defaults.string(forKey: "pinax.menuBar.chartUnit") == "month")
    #expect(PreferencesStore(defaults: defaults).menuBarChartUnit == .month)
    for unit in MenuBarChartUnit.allCases {
      first.menuBarChartUnit = unit
      #expect(PreferencesStore(defaults: defaults).menuBarChartUnit == unit)
    }
    defaults.set("fortnight", forKey: "pinax.menuBar.chartUnit")
    #expect(PreferencesStore(defaults: defaults).menuBarChartUnit == .week)

    // Settings ▸ Appearance ▸ Menu bar: Each bar under Icon, on this key;
    // the card reads it.
    let pane = try Self.source("Sources/PinaxUI/Settings/AppearanceSettingsPane.swift")
    let icon = try #require(pane.range(of: "SettingsRow(\"Icon\")"))
    let chart = try #require(pane.range(of: "SettingsRow(\"Each bar\")"))
    #expect(icon.upperBound < chart.lowerBound)
    #expect(pane[chart.upperBound...].contains("$preferences.menuBarChartUnit"))
    let panel = try Self.source("Sources/PinaxUI/DropZone/PinaxMenuBar.swift")
    #expect(panel.contains("MenuBarStatsCard(library: library, unit: preferences.menuBarChartUnit"))
  }

  @Test("The Library page opens on the setting, Year as Month; switching there leaves the setting")
  func libraryUnitFromSetting() throws {
    let name = "pinaxui-t48b-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = PreferencesStore(defaults: defaults)
    let board = NSPasteboard(name: NSPasteboard.Name(name))
    defer { board.releaseGlobally() }
    let panel = MenuBarPanelModel(pasteboard: board, notificationCenter: NotificationCenter())

    let expected: [MenuBarChartUnit: MenuBarChartUnit] = [
      .day: .day, .week: .week, .month: .month, .year: .month,
    ]
    for (setting, page) in expected {
      preferences.menuBarChartUnit = setting
      panel.openLibrary(preferences: preferences)
      #expect(panel.libraryUnit == page, "\(setting)")
    }
    #expect(MenuBarChartUnit.libraryUnits == [.day, .week, .month])

    preferences.menuBarChartUnit = .week
    panel.openLibrary(preferences: preferences)
    panel.libraryUnit = .day
    #expect(preferences.menuBarChartUnit == .week)
    #expect(defaults.string(forKey: "pinax.menuBar.chartUnit") == "week")

    // The card opens the page through this.
    let source = try Self.source("Sources/PinaxUI/DropZone/PinaxMenuBar.swift")
    #expect(source.contains("panel.openLibrary(preferences: preferences)"))
  }

  @Test("A bar with no uploads keeps a short stub; a full one takes the strip")
  func zeroBarHasHeight() {
    let stub = DesignMetrics.menuBarLibrary.barMinHeight
    #expect(stub > 0)
    #expect(MenuBarUploadBars.barHeight(count: 0, tallest: 5, height: 22) == stub)
    #expect(MenuBarUploadBars.barHeight(count: 0, tallest: 0, height: 22) == stub)
    #expect(MenuBarUploadBars.barHeight(count: 5, tallest: 5, height: 22) == 22)
    #expect(MenuBarUploadBars.barHeight(count: 2, tallest: 4, height: 48) == 24)
  }

  @Test("Failed uploads are the drop zone's .failed cards")
  func failedUploadsAreFailedCards() async throws {
    let thumbnails = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-t48-\(UUID().uuidString)", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let zone = DropZoneModel(service: HalfFailingUpload(), thumbnails: thumbnails)
    zone.drop(fileURLs: ["ok-1.png", "bad-1.png", "ok-2.png", "bad-2.png", "bad-3.png"].map {
      URL(fileURLWithPath: "/nonexistent/\($0)")
    })
    await waitUntil { zone.cards.count == 5 && zone.cards.allSatisfy { !$0.phase.isPending } }
    #expect(MenuBarLibrary.failedUploads(zone.cards) == 3)
  }

  // MARK: - Backends

  @Test("The storage bar split by backend is CatalogStats.backends'")
  func backendShares() {
    let backends = [
      CatalogStats.Share(name: "r2", total: Total(count: 7, bytes: 3_000_000)),
      CatalogStats.Share(name: "s3", total: Total(count: 9, bytes: 1_000_000)),
    ]
    let library = MenuBarLibrary(
      stats: Self.stats(backends: backends), failedUploads: 0, scanTargets: [], now: Self.now,
      calendar: Self.utc)
    let segments = library.segments(.backend)
    #expect(segments.map(\.name) == ["r2", "s3"])
    #expect(segments.map(\.bytes) == [3_000_000, 1_000_000])
    #expect(segments.map(\.fraction) == [0.75, 0.25])
    #expect(
      segments.map(\.legend)
        == ["r2 \(PinaxFormat.fileSize(3_000_000))", "s3 \(PinaxFormat.fileSize(1_000_000))"])
    #expect(library.storedLine == "stored on 2 backends")
  }

  @Test("The storage bar by file type: subtype names, most bytes first, past four the rest is Other")
  func typeShares() {
    func share(_ name: String, _ bytes: Int64) -> CatalogStats.Share {
      CatalogStats.Share(name: name, total: Total(count: 1, bytes: bytes))
    }
    // CatalogStats orders kinds by count; the bar goes by bytes.
    let kinds = [
      share("image/png", 100), share("image/jpeg", 400), share("image/svg+xml", 50),
      share("image/gif", 30), share("image/webp", 20), share("", 10),
    ]
    let library = MenuBarLibrary(
      stats: Self.stats(kinds: kinds), failedUploads: 0, scanTargets: [], now: Self.now,
      calendar: Self.utc)
    let segments = library.segments(.type)
    #expect(segments.map(\.name) == ["JPEG", "PNG", "SVG", "Other"])
    #expect(segments.map(\.bytes) == [400, 100, 50, 60])
    #expect(abs(segments.map(\.fraction).reduce(0, +) - 1) < 1e-9)
    #expect(MenuBarStorageSplit.type.label("") == "Unknown")
    let four = MenuBarLibrary(
      stats: Self.stats(kinds: Array(kinds.prefix(4))), failedUploads: 0, scanTargets: [],
      now: Self.now, calendar: Self.utc)
    #expect(four.segments(.type).map(\.name) == ["JPEG", "PNG", "SVG", "GIF"])
  }

  @Test("The storage bar by project: CatalogStats.projectShares, no project as No Project")
  func projectSegments() {
    let shares = [
      CatalogStats.Share(name: "", total: Total(count: 2, bytes: 200)),
      CatalogStats.Share(name: "Blog", total: Total(count: 3, bytes: 600)),
    ]
    let library = MenuBarLibrary(
      stats: Self.stats(projectShares: shares), failedUploads: 0, scanTargets: [], now: Self.now,
      calendar: Self.utc)
    #expect(library.segments(.project).map(\.name) == ["Blog", "No Project"])
    #expect(library.segments(.project).map(\.fraction) == [0.75, 0.25])
    #expect(library.segments(.backend).isEmpty)
  }

  @Test("Storage Bar setting: File Type unless set, kept, unknown reads as File Type; the page reads it")
  func storageSplitSetting() throws {
    let name = "pinaxui-split-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let first = PreferencesStore(defaults: defaults)
    #expect(first.menuBarStorageSplit == .type)
    // From the default away and back: each change is written.
    for split in [MenuBarStorageSplit.backend, .project, .type] {
      first.menuBarStorageSplit = split
      #expect(defaults.string(forKey: "pinax.menuBar.storageSplit") == split.rawValue)
      #expect(PreferencesStore(defaults: defaults).menuBarStorageSplit == split)
    }
    defaults.set("color", forKey: "pinax.menuBar.storageSplit")
    #expect(PreferencesStore(defaults: defaults).menuBarStorageSplit == .type)

    let pane = try Self.source("Sources/PinaxUI/Settings/AppearanceSettingsPane.swift")
    let chart = try #require(pane.range(of: "SettingsRow(\"Storage bar\")"))
    #expect(pane[chart.upperBound...].contains("$preferences.menuBarStorageSplit"))
    let page = try Self.source("Sources/PinaxUI/DropZone/MenuBarLibraryViews.swift")
    #expect(page.contains("library.segments(preferences.menuBarStorageSplit)"))
  }

  // MARK: - Last scan

  @Test("Last scan shows at 7 days, not at 6 days 23 hours; never scanned shows; no sourced, tracked project, no row")
  func lastScanThreshold() {
    #expect(MenuBarLibrary.staleScanAge == 7 * 24 * 60 * 60)
    func row(_ projects: [CatalogStats.ProjectUsage], _ targets: [String])
      -> MenuBarLibrary.Attention?
    {
      MenuBarLibrary.lastScan(projects, targets: targets, now: Self.now)
    }
    let almost = Self.stamp(Self.ago(days: 7).addingTimeInterval(3_600))
    let week = Self.stamp(Self.ago(days: 7))
    let fresh = Self.stamp(Self.ago(days: 1))
    #expect(row([Self.project("blog", lastScanAt: almost)], ["blog"]) == nil)
    #expect(row([Self.project("blog", lastScanAt: week)], ["blog"]) == .lastScan(daysAgo: 7))
    #expect(row([Self.project("blog", lastScanAt: nil)], ["blog"]) == .lastScan(daysAgo: nil))
    // All Projects: the oldest of the sourced, tracked ones.
    let mixed = [
      Self.project("blog", lastScanAt: fresh), Self.project("notes", lastScanAt: week),
      Self.project("old", lastScanAt: Self.stamp(Self.ago(days: 30))),
    ]
    #expect(row(mixed, ["blog", "notes"]) == .lastScan(daysAgo: 7))
    #expect(row(mixed, ["blog"]) == nil)
    // No project with sources: no row, never-scanned ones included.
    #expect(row([Self.project("blog", lastScanAt: nil)], []) == nil)
    // Not tracked: not counted.
    #expect(row([Self.project("blog", lastScanAt: nil, tracking: .notTracked)], ["blog"]) == nil)
    #expect(MenuBarLibrary.Attention.lastScan(daysAgo: 7).text == "Last scan 7 days ago")
  }

  @Test("Last scan through the app: the row follows currentProjectScanTargets")
  func lastScanRowInApp() async throws {
    let (app, _, directory) = try await makeApp(sources: ["blog"])
    defer { try? FileManager.default.removeItem(at: directory) }
    await app.refreshRecentUploads()
    let all = try #require(MenuBarLibrary(app: app))
    #expect(all.attention.contains(.lastScan(daysAgo: nil)))
    app.preferences.currentProjectSlug = "notes"
    await waitUntil { app.menuBarStats?.project == "notes" }
    #expect(app.currentProjectScanTargets.isEmpty)
    let notes = try #require(MenuBarLibrary(app: app))
    #expect(!notes.attention.contains { if case .lastScan = $0 { return true } else { return false } })
  }

  // MARK: - Scan

  @Test("Scan calls scanNow on currentProjectScanTargets, presented by the gallery")
  func scanCallsScanNow() async throws {
    let recorder = RecordingScans()
    let (app, _, directory) = try await makeApp(sources: ["blog", "notes"], synchronizer: recorder)
    defer { try? FileManager.default.removeItem(at: directory) }
    let usageSync = try #require(app.usageSync)

    #expect(app.currentProjectScanTargets == ["blog", "notes"])
    let confirm = await app.scanFromMenuBar()
    #expect(!confirm)
    #expect(recorder.scans == ["blog", "notes"])
    #expect(usageSync.emptyScanPresenter == .gallery)

    app.preferences.currentProjectSlug = "notes"
    #expect(await app.scanFromMenuBar() == false)
    #expect(recorder.scans == ["blog", "notes", "notes"])

    // An empty scan over a nonempty one stops at the gallery's confirmation.
    recorder.rejectEmpty = true
    #expect(await app.scanFromMenuBar() == true)
    #expect(usageSync.isEmptyScanConfirmationPresented(by: .gallery))
  }

  @Test("Every symbol the card and the page draw exists")
  func symbolsExist() {
    for name in ["chevron.left", "chevron.right"] {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  // MARK: - The refresh point

  @Test("Another window becoming key refreshes nothing; the panel's own clears unseen failures and reads again")
  func refreshOnlyOnOwnWindow() async throws {
    let (app, database, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let board = NSPasteboard(name: NSPasteboard.Name("pinaxui-t48-\(UUID().uuidString)"))
    board.clearContents()
    defer { board.releaseGlobally() }
    let center = NotificationCenter()
    let panel = MenuBarPanelModel(pasteboard: board, notificationCenter: center)
    let own = NSObject()
    let other = NSObject()
    panel.attach(window: own, app: app)

    app.menuBarActivity.noteFailure()
    #expect(app.menuBarActivity.unseenFailures == 1)
    board.setString("text only", forType: .string)
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    #expect(app.menuBarStats?.assets.count == 0)

    center.post(name: NSWindow.didBecomeKeyNotification, object: other)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(app.menuBarActivity.unseenFailures == 1)
    #expect(app.menuBarStats?.assets.count == 0)

    center.post(name: NSWindow.didBecomeKeyNotification, object: own)
    await waitUntil {
      app.menuBarActivity.unseenFailures == 0 && app.menuBarStats?.assets.count == 1
    }
    #expect(app.menuBarActivity.unseenFailures == 0)
    #expect(app.menuBarStats?.assets.count == 1)
    #expect(app.recentUploads.count == 1)
  }
}

/// Files named bad-… fail; the rest land.
private struct HalfFailingUpload: DropZoneService {
  struct Refused: Error {}

  func projects() throws -> [Project] { [] }

  func prepare(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    PreparedDrop(fileURL: fileURL, projectSlug: projectSlug)
  }

  func upload(_ prepared: PreparedDrop, useOriginal: Bool) async throws -> UploadOutcome {
    let fileURL = prepared.fileURL
    let name = fileURL.lastPathComponent
    if name.hasPrefix("bad") { throw Refused() }
    return UploadOutcome(
      sha256: String(repeating: name.hasSuffix("1.png") ? "a" : "b", count: 64),
      key: "x/\(name)", url: "https://img.example.com/x/\(name)", mime: "image/png",
      originalFilename: name, byteSize: 1, width: 1, height: 1,
      uploadedAt: "2026-08-22T00:00:00Z", deduplicated: false, dryRun: false)
  }

  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws {}
}

/// Records each scan; with `rejectEmpty` it refuses like an empty scan
/// over a nonempty one.
private final class RecordingScans: UsageSyncing, @unchecked Sendable {
  private let lock = NSLock()
  private var _scans: [String] = []
  private var _rejectEmpty = false

  var scans: [String] { lock.withLock { _scans } }
  var rejectEmpty: Bool {
    get { lock.withLock { _rejectEmpty } }
    set { lock.withLock { _rejectEmpty = newValue } }
  }

  func projects() async throws -> [String] { ["blog", "notes"] }

  func sync(documentAt source: URL, project: String, allowEmpty: Bool) async throws
    -> UsageSyncResult
  {
    UsageSyncResult(scanID: 0, foundCount: 0)
  }

  func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome {
    lock.withLock { _scans.append(project) }
    if rejectEmpty && !allowEmpty {
      throw UsageCatalogError.emptyScanRejected(previousFoundCount: 4)
    }
    return UsageScanOutcome(sync: UsageSyncResult(scanID: 0, foundCount: 0), files: 0, skipped: 0)
  }
}
