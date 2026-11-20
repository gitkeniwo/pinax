import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Report headers:
///
/// - `ReportHeaderModel.compose` says "never scanned" exactly when a project
///   has no completed scan, and carries the old caveat and scan-health text
///   word for word.
/// - The hosted Orphans surface, through the app's own model, in the three
///   scan states: every project with assets never scanned (Usage Unknown, no
///   grid), some never scanned (the grid, the summary naming them, Open
///   Maintenance…), all scanned (the grid, neither).
/// - Its header bar is `sectionHeader.height`, and its cells are
///   `AssetGridView.cellWidth(columns:paneWidth:)` wide at the grid's own
///   column count.
/// - With some projects never scanned, candidates only in
///   those projects wait in a collapsed "Not yet scanned (N)" group; one also
///   in a scanned project stays in the grid.
@MainActor
@Suite(.serialized) struct ReportHeaderTests {
  // MARK: - The pure function

  private func health(_ status: OrphanScanHealth.Status, _ slug: String) -> OrphanScanHealth {
    OrphanScanHealth(
      status: status, name: slug.capitalized, slug: slug,
      lastScanAt: status == .neverScanned ? nil : "2026-09-01T10:00:00Z")
  }

  private func project(_ slug: String, assets: Int, scanned: Bool) -> ProjectSummary {
    ProjectSummary(
      slug: slug, name: slug.capitalized, assetCount: assets, liveUsageCount: 0,
      lastScanAt: scanned ? "2026-09-01T10:00:00Z" : nil)
  }

  @Test("compose names never-scanned projects in the summary, and only then")
  func composeSummary() {
    let some = ReportHeaderModel.compose(
      orphanCandidates: 38,
      health: [health(.scanned, "blog"), health(.neverScanned, "astro")],
      projects: [project("blog", assets: 40, scanned: true), project("astro", assets: 83, scanned: false)])
    #expect(some.header.summary == "38 candidates · Astro never scanned")
    #expect(some.header.offersMaintenance)
    #expect(some.content == .candidates)

    let two = ReportHeaderModel.compose(
      orphanCandidates: 38,
      health: [health(.neverScanned, "astro"), health(.neverScanned, "docs"), health(.scanned, "blog")],
      projects: [project("blog", assets: 40, scanned: true)])
    #expect(two.header.summary == "38 candidates · 2 projects never scanned")

    let none = ReportHeaderModel.compose(
      orphanCandidates: 1, health: [health(.scanned, "blog"), health(.underScanned, "notes")],
      projects: [project("blog", assets: 4, scanned: true)])
    #expect(none.header.summary == "1 candidate")
    #expect(!none.header.summary.contains("never scanned"))
    #expect(!none.header.offersMaintenance)

    let empty = ReportHeaderModel.compose(orphanCandidates: 0, health: [], projects: [])
    #expect(!empty.header.summary.contains("never scanned"))

    // Every project with assets unscanned: no count, the empty state.
    let unknown = ReportHeaderModel.compose(
      orphanCandidates: 83,
      health: [health(.neverScanned, "astro"), health(.scanned, "blog")],
      projects: [project("astro", assets: 83, scanned: false), project("blog", assets: 0, scanned: true)])
    #expect(unknown.content == .usageUnknown(projectNames: ["Astro"]))
    #expect(unknown.header.summary == "Astro never scanned")
    #expect(!unknown.header.offersMaintenance, "the empty state has the button")
    #expect(unknown.header.summary.rangeOfCharacter(from: .decimalDigits) == nil)
  }

  @Test("The old caveat and scan-health text move into the header's Details word for word")
  func detailsKeepEveryWord() {
    let notes = ReportHeaderModel.compose(
      orphanCandidates: 3,
      health: [health(.neverScanned, "astro"), health(.scanned, "blog"), health(.underScanned, "notes")],
      projects: []
    ).header.details
    let date = PinaxFormat.date("2026-09-01T10:00:00Z", style: .dayTime)
    #expect(notes == [
      ReportNote(
        heading: "Orphan candidates — read-only",
        lines: [
          "Live usage is a lower bound, not proof. An asset appears here when no project's "
            + "latest completed scan references it — a project that has not been scanned "
            + "recently makes its assets look orphaned. This list is read-only and can "
            + "never justify deleting anything from the object store."
        ]),
      ReportNote(
        heading: "Never scanned",
        lines: ["Astro: no usage scan has ever completed, so all of its assets may appear here."]),
      ReportNote(heading: "Fewer than two completed scans", lines: ["Notes: last scan \(date)."]),
      ReportNote(lines: ["Scanned recently: Blog (\(date))."]),
    ])
    let noProjects = ReportHeaderModel.compose(orphanCandidates: 0, health: [], projects: [])
    #expect(noProjects.header.details.last == ReportNote(lines: ["No projects are configured."]))
  }

  // MARK: - The hosted surface

  /// What the hosted surface reported through its preferences.
  @MainActor final class Measured {
    /// The header bar on screen now, by report title.
    var bars: [String: CGFloat] = [:]
    var barHeight: CGFloat { bars.count == 1 ? bars.values.first! : -1 }
    var cellWidths: [GalleryModel.Row.ID: CGFloat] = [:]
    var paneWidth: CGFloat = 0
  }

  private enum Scans { case none, blogOnly, both }

  /// Two assets in blog, two in notes, none of them live; `scans` decides
  /// which projects have two completed scans.
  private func makeApp(_ scans: Scans) async throws -> (PinaxAppModel, GalleryModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 2, uploadedAt: "2026-08-03T00:00:00Z", projectSlug: "notes")
    try seedAsset(database, index: 3, uploadedAt: "2026-08-04T00:00:00Z", projectSlug: "notes")
    let scanned: [Int] = switch scans {
    case .none: []
    case .blogOnly: [1]
    case .both: [1, 2]
    }
    try await database.write { db in
      for project in scanned {
        for scan in 0..<2 {
          let id = project * 10 + scan
          try db.execute(
            sql: """
              INSERT INTO scan (id, project_id, started_at, finished_at)
              VALUES (?, ?, '2026-09-0\(scan + 1)T10:00:00Z', '2026-09-0\(scan + 1)T10:05:00Z')
              """,
            arguments: [id, project])
          try db.execute(
            sql: "UPDATE project SET last_scan_id = ? WHERE id = ?", arguments: [id, project])
        }
        // One reference in the latest scan to a URL the catalog does not
        // have: an external reference, and the Usage table's one row.
        try db.execute(
          sql: """
            INSERT INTO usage (project_id, asset_id, raw_url, source_ref, kind, first_seen,
              last_seen, last_scan_id)
            VALUES (?, NULL, 'https://cdn.example.org/elsewhere-\(project).png', 'posts/\(project).md',
              'markdown', '2026-09-02T10:00:00Z', '2026-09-02T10:00:00Z', ?)
            """,
          arguments: [project, project * 10 + 1])
      }
    }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-report-\(UUID().uuidString)"))
    defaults.set(3, forKey: "pinax.grid.columns")
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    await gallery.loadInitialData()
    return (app, gallery, directory)
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private struct Drawn {
    var pushButtons = 0
    var fieldValues: [String] = []
  }

  private func drawn(_ window: NSWindow) -> Drawn {
    var result = Drawn()
    var stack: [NSView] = [window.contentView!]
    while let view = stack.popLast() {
      stack.append(contentsOf: view.subviews)
      guard !view.isHiddenOrHasHiddenAncestor else { continue }
      // The jump bar's and the header's other buttons are borderless
      // (bezel 2) or pop-ups; Open Maintenance… is the one bordered push
      // button here (measured: bezel 28, small). SwiftUI leaves the AppKit
      // title and the accessibility identifier empty in the test process.
      if let button = view as? NSButton, !(button is NSPopUpButton), button.bezelStyle.rawValue != 2 {
        result.pushButtons += 1
      }
      if let field = view as? NSTextField { result.fieldValues.append(field.stringValue) }
    }
    return result
  }

  /// The gallery, hosted with the orphans selected, and what it measured.
  private func hostOrphans(_ gallery: GalleryModel) async -> (NSWindow, Measured) {
    await host(gallery, showing: .orphans) {
      gallery.orphanReport != nil && !gallery.orphanHealth.isEmpty
    }
  }

  /// The gallery, hosted on one report surface, once `loaded` holds.
  private func host(
    _ gallery: GalleryModel, showing selection: SidebarSelection, until loaded: () -> Bool
  ) async -> (NSWindow, Measured) {
    let measured = Measured()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
      styleMask: [.titled], backing: .buffered, defer: false)
    let controller = NSHostingController(
      rootView: GalleryView(model: gallery)
        .onPreferenceChange(ReportHeaderBarHeightKey.self) { measured.bars = $0 }
        .onPreferenceChange(OrphanCellWidthsKey.self) { measured.cellWidths = $0 }
        .onPreferenceChange(OrphanPaneWidthKey.self) { measured.paneWidth = $0 })
    // Measured: left to size itself, the controller shrank the window to
    // 581 × 214, and the grid's second row never realised.
    controller.sizingOptions = []
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 1200, height: 900))
    window.makeKeyAndOrderFront(nil)
    gallery.select(selection, in: SidebarModel.navigator(for: selection))
    let deadline = Date().addingTimeInterval(5)
    while !loaded(), Date() < deadline {
      await spin(0.05)
    }
    await spin(0.5)
    return (window, measured)
  }

  /// Switches the hosted gallery to another report and waits for it.
  private func show(
    _ gallery: GalleryModel, _ selection: SidebarSelection, _ measured: Measured,
    until loaded: () -> Bool
  ) async {
    gallery.select(selection, in: SidebarModel.navigator(for: selection))
    let deadline = Date().addingTimeInterval(5)
    while !loaded(), Date() < deadline {
      await spin(0.05)
    }
    await spin(0.5)
  }

  /// The hosted tables' column titles (the gallery's own asset table is
  /// not on a report surface).
  private func tableColumns(_ window: NSWindow) -> [[String]] {
    var found: [[String]] = []
    var stack: [NSView] = [window.contentView!]
    while let view = stack.popLast() {
      stack.append(contentsOf: view.subviews)
      if let table = view as? NSTableView, table.tableColumns.count > 1 {
        found.append(table.tableColumns.map(\.title))
      }
    }
    return found
  }

  // MARK: - Usage and Externals

  @Test("compose(externals:) counts the references and explains the report")
  func composeExternals() {
    #expect(ReportHeaderModel.compose(externals: 1).summary == "1 external reference")
    #expect(ReportHeaderModel.compose(externals: 1).details == [
      ReportNote(
        heading: "External references — read-only",
        lines: [
          "URLs found in the latest completed usage scans that do not match any asset in "
            + "this catalog. This report does not change the catalog."
        ]),
      ReportNote(
        heading: "Your Domains",
        lines: [
          "On your backends' domains but not in the catalog: a typo, an object removed "
            + "outside Pinax, or one uploaded by another tool."
        ]),
    ])
  }

  @Test("Orphans keeps the one header bar, sectionHeader.height; Externals' scope bar and Usage's range bar replace theirs")
  func headersAreOneHeight() async throws {
    let (_, gallery, directory) = try await makeApp(.blogOnly)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (window, measured) = await hostOrphans(gallery)
    defer { window.orderOut(nil) }
    var heights = measured.bars
    #expect(heights.keys.sorted() == ["Orphans"])

    await show(gallery, .externals, measured) {
      if case .results = gallery.externals.presentation { return true }
      return gallery.externals.presentation == .empty
    }
    // No title row; the scope bar carries the counts
    // and no ReportHeader bar is drawn on Externals.
    #expect(gallery.externals.items?.isEmpty == false)
    #expect(!drawn(window).fieldValues.contains("1 external reference"))
    // Grouped by domain, a Grid or a List — no column table.
    #expect(tableColumns(window) == [])

    // Usage has the 38 pt range bar instead of a title row — no
    // ReportHeader bar to measure there.
    await show(gallery, .usage, measured) { gallery.usageBrowser != nil }
    heights.merge(measured.bars) { $1 }
    #expect(heights.keys.sorted() == ["Orphans"])
    #expect(
      Set(heights.values) == [DesignMetrics.sectionHeader.height], "\(heights)")
    #expect(
      gallery.usageBrowser?.rangeSummary(projects: gallery.reportScopeProjects).text
        .hasPrefix("0 refs · 0 files")
        == true)
  }

  @Test("Usage without a completed scan: no count, no table, No Completed Scan with its action")
  func usageWithoutScan() async throws {
    let (_, gallery, directory) = try await makeApp(.blogOnly)
    defer { try? FileManager.default.removeItem(at: directory) }
    gallery.currentProjectSlug = "notes"
    let (window, measured) = await host(gallery, showing: .usage) {
      gallery.usageBrowser?.usage.projectSources.keys.sorted() == ["notes"]
    }
    defer { window.orderOut(nil) }

    #expect(gallery.usageBrowser?.usage.scannedProjects.isEmpty == true)
    // The range bar says so, with no numbers.
    #expect(
      gallery.usageBrowser?.rangeSummary(projects: gallery.reportScopeProjects)
        == .noScan)
    #expect(
      gallery.usageBrowser?.rangeSummary(projects: gallery.reportScopeProjects).text
        == "No completed scan")
    let now = drawn(window)
    #expect(
      now.fieldValues.allSatisfy { $0.rangeOfCharacter(from: .decimalDigits) == nil },
      "no number anywhere: \(now.fieldValues)")
    #expect(tableColumns(window).isEmpty, "no table")
    #expect(now.pushButtons == 1, "the empty state's action")

    // A scanned project whose one reference matches nothing: the counts
    // and the scan, No References, no controls.
    gallery.currentProjectSlug = "blog"
    await show(gallery, .usage, measured) {
      gallery.usageBrowser?.usage.scannedProjects == ["blog"]
    }
    let scanned = drawn(window)
    #expect(
      gallery.usageBrowser?.rangeSummary(projects: gallery.reportScopeProjects).text
        .hasPrefix("0 refs · 0 files · scanned ")
        == true)
    #expect(scanned.pushButtons == 0)
  }

  @Test("Every project with assets never scanned: Usage Unknown, no grid, no count")
  func allNeverScanned() async throws {
    let (_, gallery, directory) = try await makeApp(.none)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (window, measured) = await hostOrphans(gallery)
    defer { window.orderOut(nil) }

    #expect(gallery.orphanReport?.assets.count == 4, "the report itself lists all four")
    #expect(measured.cellWidths.isEmpty, "no grid")
    let now = drawn(window)
    #expect(notYetScannedTitle(gallery) == nil, "no group either")
    #expect(now.fieldValues.contains("2 projects never scanned"), "\(now.fieldValues)")
    #expect(!now.fieldValues.contains { $0.contains("candidate") })
    #expect(now.pushButtons == 1, "Open Maintenance…, in the empty state")
    #expect(measured.barHeight == DesignMetrics.sectionHeader.height)
  }

  @Test("Some projects never scanned: the grid, the summary names them, Open Maintenance…")
  func someNeverScanned() async throws {
    let (_, gallery, directory) = try await makeApp(.blogOnly)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (window, measured) = await hostOrphans(gallery)
    defer { window.orderOut(nil) }

    let now = drawn(window)
    #expect(now.fieldValues.contains("4 candidates · Notes never scanned"), "\(now.fieldValues)")
    #expect(now.pushButtons == 1, "Open Maintenance… beside the Details")
    // Notes' two wait in the collapsed "Not yet scanned (2)".
    #expect(Set(measured.cellWidths.keys) == [1, 2])
    #expect(notYetScannedTitle(gallery) == "Not yet scanned (2)")
    #expect(measured.barHeight == DesignMetrics.sectionHeader.height)
  }

  @Test("Every project scanned: the grid in the main grid's cells, no never-scanned line")
  func allScanned() async throws {
    let (_, gallery, directory) = try await makeApp(.both)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (window, measured) = await hostOrphans(gallery)
    defer { window.orderOut(nil) }

    let now = drawn(window)
    #expect(now.fieldValues.contains("4 candidates"), "\(now.fieldValues)")
    #expect(now.pushButtons == 0, "no Open Maintenance…")
    #expect(measured.barHeight == DesignMetrics.sectionHeader.height)

    // The main grid's formula at the grid's own column count (3, not the
    // default 4), for every cell.
    #expect(gallery.gridColumns == 3)
    #expect(measured.paneWidth > 0)
    let expected = AssetGridView.cellWidth(columns: 3, paneWidth: measured.paneWidth)
    #expect(measured.cellWidths.count == 4)
    for width in measured.cellWidths.values {
      #expect(abs(width - expected) < 0.5, "\(width) vs \(expected) at pane \(measured.paneWidth)")
    }
  }

  // MARK: - Not yet scanned

  /// Three projects: blog with two completed scans, docs with one (under-
  /// scanned, but it has a completed scan), notes with none. No reference is
  /// live, so every asset is a candidate. Upload dates run against id order,
  /// so report order (uploaded_at, id) is 2, 5, 3, 4, 1, 6 — not id order —
  /// and asset 3 is in both blog and notes. `projectless` adds asset 7, in
  /// no project, uploaded between 2 and 5 — the shape of most real libraries.
  private func makeSharedApp(projectless: Bool = false) async throws
    -> (PinaxAppModel, GalleryModel, URL)
  {
    let (database, directory) = try makeUITestDatabase()
    try seedAsset(database, index: 0, uploadedAt: "2026-08-05T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "notes")
    try seedAsset(database, index: 2, uploadedAt: "2026-08-03T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 3, uploadedAt: "2026-08-04T00:00:00Z", projectSlug: "notes")
    try seedAsset(database, index: 4, uploadedAt: "2026-08-02T00:00:00Z", projectSlug: "blog")
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO project
            (id, slug, name, key_prefix, backend_id, last_scan_id, created_at, updated_at)
          VALUES (3, 'docs', 'Docs', 'docs', 1, NULL, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z')
          """)
    }
    try seedAsset(database, index: 5, uploadedAt: "2026-08-06T00:00:00Z", projectSlug: "docs")
    if projectless {
      try seedAsset(database, index: 6, uploadedAt: "2026-08-01T12:00:00Z", projectSlug: nil)
    }
    try await database.write { db in
      try db.execute(
        sql: "INSERT INTO asset_project (asset_id, project_id, added_at) VALUES (3, 2, '2026-08-03T00:00:00Z')")
      for (id, project, finished) in [(11, 1, "01"), (12, 1, "02"), (31, 3, "01")] {
        try db.execute(
          sql: """
            INSERT INTO scan (id, project_id, started_at, finished_at)
            VALUES (?, ?, '2026-09-\(finished)T10:00:00Z', '2026-09-\(finished)T10:05:00Z')
            """,
          arguments: [id, project])
        try db.execute(
          sql: "UPDATE project SET last_scan_id = ? WHERE id = ?", arguments: [id, project])
      }
    }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-report-\(UUID().uuidString)"))
    defaults.set(3, forKey: "pinax.grid.columns")
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    await gallery.loadInitialData()
    return (app, gallery, directory)
  }

  /// The "Not yet scanned" group's title as the app's `OrphanView` declares
  /// it. The hosted label draws as a CGDrawingView, not a text field, and the
  /// test process exposes no accessibility tree (measured), so it is read
  /// from the view's own body, stopping at class instances.
  private func notYetScannedTitle(_ gallery: GalleryModel) -> String? {
    guard let group = firstView(in: OrphanView(model: gallery).body, typePrefix: "DisclosureGroup<"),
      let label = firstView(in: group, typePrefix: "Text")
    else { return nil }
    return Mirror(reflecting: label).descendant("storage", "verbatim") as? String
  }

  @Test("The report carries each candidate's projects; split keeps report order")
  func orphanProjectMembership() async throws {
    let (_, gallery, directory) = try await makeSharedApp(projectless: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    gallery.select(.orphans, in: SidebarModel.navigator(for: .orphans))
    await gallery.reload()

    let report = try #require(gallery.orphanReport)
    #expect(report.assets.compactMap(\.asset.id) == [2, 7, 5, 3, 4, 1, 6])
    #expect(report.projectSlugs == [
      1: ["blog"], 2: ["notes"], 3: ["blog", "notes"], 4: ["notes"], 5: ["blog"], 6: ["docs"],
    ])
    let statuses = Dictionary(uniqueKeysWithValues: gallery.orphanHealth.map { ($0.slug, $0.status) })
    #expect(statuses == ["blog": .scanned, "docs": .underScanned, "notes": .neverScanned])

    let split = ReportHeaderModel.splitOrphans(report, health: gallery.orphanHealth)
    // 3 is in notes too, but blog was scanned: blog's verdict stands. 6 is
    // under-scanned docs': it has a completed scan, so it stays. 7 is in no
    // project: nothing says it waits on a scan, so it stays too.
    #expect(split.scanned.compactMap(\.asset.id) == [7, 5, 3, 1, 6])
    #expect(split.notYetScanned.compactMap(\.asset.id) == [2, 4])
  }

  @Test("Some projects never scanned: their-only candidates wait in a collapsed group")
  func notYetScannedGroup() async throws {
    let (_, gallery, directory) = try await makeSharedApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (window, measured) = await hostOrphans(gallery)
    defer { window.orderOut(nil) }

    // Collapsed: the grid draws the four scanned-side candidates only; the
    // group's title counts the two it holds.
    #expect(gallery.showsNotYetScannedOrphans == false)
    #expect(Set(measured.cellWidths.keys) == [5, 3, 1, 6])
    let collapsed = drawn(window)
    #expect(notYetScannedTitle(gallery) == "Not yet scanned (2)")
    #expect(collapsed.fieldValues.contains("6 candidates · Notes never scanned"), "\(collapsed.fieldValues)")
    // ⌘A and ranges cover what is drawn, in display order.
    gallery.selectAllLoaded()
    #expect(gallery.selectedIDs == [5, 3, 1, 6])
    let rows = try #require(gallery.orphanReport).assets.map(GalleryModel.Row.init)
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    gallery.select(try #require(byID[3]), mode: .replace)
    gallery.select(try #require(byID[6]), mode: .extend)
    #expect(gallery.selectedIDs == [3, 1, 6])

    // Opened through the view's own binding: the group's cells draw after
    // the grid's, and ranges run on into them.
    gallery.showsNotYetScannedOrphans = true
    await spin(0.5)
    #expect(Set(measured.cellWidths.keys) == [5, 3, 1, 6, 2, 4])
    gallery.select(try #require(byID[1]), mode: .replace)
    gallery.select(try #require(byID[2]), mode: .extend)
    #expect(gallery.selectedIDs == [1, 6, 2])
  }
}
