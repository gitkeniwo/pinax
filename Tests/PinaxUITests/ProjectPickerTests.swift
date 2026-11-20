import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// The title area's project picker. `ProjectPickerView`
/// is hosted in a plain window — never in a popover — over the gallery the
/// app's own `start()` wires; its rows, their click and their ⋯ menus are
/// read off the view as values (no popover, menu or click).
///   Blog (blog)        1 asset, sources, scanned 2026-08-20
///   Notes (notes)      no sources
///   Photo Log (camera) sources, never scanned
@MainActor
@Suite(.serialized) struct ProjectPickerTests {
  struct Fixture {
    let app: PinaxAppModel
    let gallery: GalleryModel
    let scans: ScanRecorder
    let directory: URL
  }

  static let now = Date(timeIntervalSince1970: 1_788_000_000)  // 2026-08-29

  func withFixture(_ body: (Fixture) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await database.write { db in
      try db.execute(sql: """
        INSERT INTO project
          (id, slug, name, key_prefix, backend_id, last_scan_id, created_at, updated_at)
        VALUES (3, 'camera', 'Photo Log', 'camera', 1, NULL,
                '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        """)
    }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "blog")
    try seedLiveUsage(database, projectSlug: "blog", sha256: String(format: "%064x", 1), count: 1)
    for slug in ["blog", "camera"] {
      let path = directory.path + "/\(slug)-src"
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
      try CatalogConfiguration.setProjectSources(
        slug: slug, [ProjectSource(label: "src", path: path)], in: database)
    }
    let scans = ScanRecorder()
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try #require(UserDefaults(suiteName: "pinaxui-picker-\(UUID().uuidString)")),
      databaseOpener: { database }, usageSynchronizer: { _ in scans },
      chooseSourceFolder: { _ in nil })
    await app.start()
    let gallery = try #require(app.gallery)
    await gallery.loadInitialData()
    await waitUntil { gallery.projects.count == 3 && gallery.sourcedProjects == ["blog", "camera"] }
    gallery.projectPickerNow = { Self.now }
    try await body(Fixture(app: app, gallery: gallery, scans: scans, directory: directory))
  }

  // MARK: - Reading the view

  /// The picker's row sections as its body declares them: each `ForEach`
  /// over `ProjectPickerRowView`s, in order.
  static func sections(_ picker: ProjectPickerView) -> [[ProjectPickerRowView]] {
    allViews(in: picker.body, typePrefix: "ForEach<Array<ProjectPickerRowView>").compactMap {
      Mirror(reflecting: $0).descendant("data") as? [ProjectPickerRowView]
    }
  }

  /// The popover's `isPresented` binding, read off the modifier's body.
  static func presented(_ popover: ProjectPickerPopover) -> Binding<Bool>? {
    let content = unsafeBitCast((), to: _ViewModifier_Content<ProjectPickerPopover>.self)
    let body = popover.body(content: content)
    return Mirror(reflecting: body).descendant("modifier", "provider", "_isPresented")
      as? Binding<Bool>
  }

  static func rows(_ gallery: GalleryModel) -> [ProjectPickerRowView] {
    sections(ProjectPickerView(model: gallery)).flatMap { $0 }
  }

  static func row(_ name: String, _ gallery: GalleryModel) -> ProjectPickerRowView? {
    rows(gallery).first { $0.row.name == name }
  }

  /// New Project… and Manage Projects…, as the view's footer lists them.
  static func footer(_ gallery: GalleryModel) -> [ProjectRowMenu.Item] {
    allViews(in: ProjectPickerView(model: gallery).body, typePrefix: "ForEach<Array<Item>")
      .compactMap { Mirror(reflecting: $0).descendant("data") as? [ProjectRowMenu.Item] }
      .first ?? []
  }

  private func names(_ rows: [ProjectPickerRowView]) -> [String] { rows.map(\.row.name) }

  // MARK: - Sections, rows, filter (hosted)

  @Test("The current row alone, then All Projects and the rest; two lines per row")
  func sectionsAndRows() async throws {
    try await withFixture { fixture in
      let gallery = fixture.gallery
      let window = host(ProjectPickerView(model: gallery))
      defer { window.orderOut(nil) }
      let projectNames = gallery.projects.map(\.name)

      var sections = Self.sections(ProjectPickerView(model: gallery))
      #expect(sections.count == 2)
      #expect(names(sections.first ?? []) == ["All Projects"])
      #expect(names(sections.last ?? []) == projectNames)

      let scanned = PinaxFormat.relativeDate("2026-08-20T13:00:00Z", now: Self.now)
      #expect(scanned != "2026-08-20T13:00:00Z")
      #expect(Self.row("All Projects", gallery)?.row.detail == "3 projects")
      #expect(Self.row("Blog", gallery)?.row.detail == "1 asset · Scanned \(scanned)")
      #expect(Self.row("Notes", gallery)?.row.detail == "0 assets · No sources")
      #expect(Self.row("Photo Log", gallery)?.row.detail == "0 assets · Never scanned")

      // Notes current: it moves up alone; All Projects leads the rest.
      PinaxCommands(app: fixture.app).projectItems.current = "notes"
      sections = Self.sections(ProjectPickerView(model: gallery))
      #expect(names(sections.first ?? []) == ["Notes"])
      #expect(names(sections.last ?? []) == ["All Projects"] + projectNames.filter { $0 != "Notes" })
      #expect(Self.row("Notes", gallery)?.isHighlighted == false, "nothing highlighted until opened")
      gallery.isProjectPickerPresented = true
      #expect(Self.row("Notes", gallery)?.isHighlighted == true, "opening highlights the current row")
    }
  }

  @Test("Find filters by name and slug, ignoring case; the highlight goes to the first row shown")
  func findFilters() async throws {
    try await withFixture { fixture in
      let gallery = fixture.gallery
      let window = host(ProjectPickerView(model: gallery))
      defer { window.orderOut(nil) }
      PinaxCommands(app: fixture.app).projectItems.current = "notes"
      gallery.isProjectPickerPresented = true

      gallery.projectPickerQuery = "LOG"
      var sections = Self.sections(ProjectPickerView(model: gallery))
      #expect(sections.count == 1, "the current row is filtered out with its section")
      #expect(names(sections.first ?? []) == ["Blog", "Photo Log"])
      #expect(Self.row("Blog", gallery)?.isHighlighted == true)

      gallery.projectPickerQuery = "camera"  // Photo Log's slug only
      #expect(names(Self.rows(gallery)) == ["Photo Log"])
      #expect(Self.row("Photo Log", gallery)?.isHighlighted == true)

      gallery.projectPickerQuery = "nOtE"
      sections = Self.sections(ProjectPickerView(model: gallery))
      #expect(sections.map(names) == [["Notes"]])

      gallery.projectPickerQuery = "all"
      #expect(names(Self.rows(gallery)) == ["All Projects"])

      gallery.projectPickerQuery = "zzz"
      #expect(Self.rows(gallery).isEmpty)

      // Reopening starts over.
      gallery.isProjectPickerPresented = false
      gallery.isProjectPickerPresented = true
      #expect(gallery.projectPickerQuery == "")
      #expect(Self.rows(gallery).count == 4)
    }
  }

  // MARK: - Choosing, ⋯ menus, footer

  @Test("Clicking a row makes it current and closes the picker")
  func clickChoosesAndCloses() async throws {
    try await withFixture { fixture in
      let gallery = fixture.gallery
      let zone = try #require(fixture.app.dropZone).model
      gallery.isProjectPickerPresented = true
      try #require(Self.row("Photo Log", gallery)).choose()
      #expect(fixture.app.preferences.currentProjectSlug == "camera")
      #expect(zone.selectedProjectSlug == "camera")
      #expect(!gallery.isProjectPickerPresented)

      gallery.isProjectPickerPresented = true
      try #require(Self.row("All Projects", gallery)).choose()
      #expect(fixture.app.preferences.currentProjectSlug == nil)
      #expect(!gallery.isProjectPickerPresented)
    }
  }

  @Test("The pointer moves the highlight to the row under it, as in a menu")
  func hoverMovesHighlight() async throws {
    try await withFixture { fixture in
      let gallery = fixture.gallery
      let photoLog = try #require(Self.row("Photo Log", gallery))
      #expect(gallery.projectPickerHighlight != photoLog.row.id)
      photoLog.hover()
      #expect(gallery.projectPickerHighlight == photoLog.row.id)
      #expect(try #require(Self.row("Photo Log", gallery)).isHighlighted)
      try #require(Self.row("All Projects", gallery)).hover()
      #expect(gallery.projectPickerHighlight == "")
    }
  }

  @Test("New Project… and Manage Projects… are menu rows — the project rows' inset, width and highlight")
  func footerRowsAreMenuRows() async throws {
    try await withFixture { fixture in
      let gallery = fixture.gallery
      // The footer draws each item as a ProjectPickerFooterRow…
      let forEach = try #require(
        allViews(in: ProjectPickerView(model: gallery).body, typePrefix: "ForEach<Array<Item>").first)
      #expect(String(describing: type(of: forEach)).contains("ProjectPickerFooterRow"))
      // …whose label wears the project rows' chrome.
      let item = try #require(Self.footer(gallery).first)
      let footerRow = ProjectPickerFooterRow(item: item)
      #expect(!allViews(in: footerRow.body, typePrefix: "ModifiedContent<")
        .filter { String(describing: type(of: $0)).contains("ProjectPickerRowChrome") }.isEmpty)
      let projectRow = try #require(Self.row("Photo Log", gallery))
      #expect(!allViews(in: projectRow.body, typePrefix: "ModifiedContent<")
        .filter { String(describing: type(of: $0)).contains("ProjectPickerRowChrome") }.isEmpty)

      // The chrome, hosted: the inset on both sides of the title, and a
      // highlight that draws.
      let bare = NSHostingView(rootView: Text(item.title).pinaxBody())
      let hosted = NSHostingView(rootView: footerRow)
      let inset = DesignMetrics.spacing.xs * 2
      #expect(hosted.fittingSize.height == bare.fittingSize.height + inset, "\(hosted.fittingSize)")
      #expect(hosted.fittingSize.width == bare.fittingSize.width + inset, "\(hosted.fittingSize)")
      #expect(Self.pixels(highlighted: true) != Self.pixels(highlighted: false))
    }
  }

  static func pixels(highlighted: Bool) -> Data? {
    let host = NSHostingView(
      rootView: Text("New Project…").pinaxBody()
        .modifier(ProjectPickerRowChrome(isHighlighted: highlighted))
        .frame(width: DesignMetrics.projectPicker.width))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.tiffRepresentation
  }

  @Test("A project row's ⋯ menu — Scan Now on that project, Project Settings… on its page; none on All Projects")
  func rowMenus() async throws {
    try await withFixture { fixture in
      let (app, gallery) = (fixture.app, fixture.gallery)
      #expect(Self.row("All Projects", gallery)?.menu == nil)
      let blog = try #require(Self.row("Blog", gallery)?.menu)
      #expect(blog.items.map(\.title) == ["Scan Now", "Project Settings…"])
      #expect(blog.items.map(\.isEnabled) == [true, true])
      #expect(blog.items.map(\.opensSettings) == [false, true])
      let notes = try #require(Self.row("Notes", gallery)?.menu)
      #expect(notes.items.map(\.isEnabled) == [false, true], "Notes has no sources")

      // Scan Now: that project, not the current one, through the one scan.
      gallery.isProjectPickerPresented = true
      try #require(Self.row("Photo Log", gallery)?.menu?.items.first).action()
      #expect(!gallery.isProjectPickerPresented)
      await waitUntil { fixture.scans.scans == ["camera"] }
      #expect(fixture.scans.scans == ["camera"])
      #expect(app.preferences.currentProjectSlug == nil, "scanning does not choose")

      try #require(blog.items.last).action()
      #expect(app.settingsTab == .projects)
      #expect(app.projectSettings?.requestedSlug == "blog")
    }
  }

  @Test("New Project… starts adding on Settings ▸ Projects; Manage Projects… opens it on the current project")
  func footerItems() async throws {
    try await withFixture { fixture in
      let (app, gallery) = (fixture.app, fixture.gallery)
      let footer = Self.footer(gallery)
      #expect(footer.map(\.title) == ["New Project…", "Manage Projects…"])
      #expect(footer.allSatisfy { $0.opensSettings })

      PinaxCommands(app: app).projectItems.current = "notes"
      try #require(footer.last).action()
      #expect(app.settingsTab == .projects)
      #expect(app.projectSettings?.requestedSlug == "notes")
      #expect(app.projectSettings?.additionDraft == nil)

      app.settingsTab = .general
      gallery.isProjectPickerPresented = true
      try #require(footer.first).action()
      #expect(!gallery.isProjectPickerPresented)
      #expect(app.settingsTab == .projects)
      #expect(app.projectSettings?.isAdditionPresented(by: .settings) == true)
    }
  }

  // MARK: - Choose Project… ⌃0 and the title area

  @Test("Project ▸ Choose Project… (⌃0) opens the picker the title area's popover shows")
  func chooseProjectCommand() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try #require(UserDefaults(suiteName: "pinaxui-picker-\(UUID().uuidString)")),
      databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    let isChoose: (Any) -> Bool = { "\($0)".contains("\"Choose Project…\"") }
    #expect(
      buttonIsEnabled(in: PinaxCommands(app: app).projectItems.body, label: isChoose) == false,
      "no gallery yet")
    await app.start()
    let gallery = try #require(app.gallery)
    let items = PinaxCommands(app: app).projectItems
    #expect(buttonIsEnabled(in: items.body, label: isChoose) == true)
    #expect(!gallery.isProjectPickerPresented)
    let choose = try #require(buttonAction(in: items.body, label: isChoose))
    choose()
    #expect(gallery.isProjectPickerPresented)

    // The title area is the gallery's toolbar item; its popover reads the
    // state the command set, and its project line toggles it.
    let item = try #require(
      firstView(in: GalleryView(model: gallery).body, typePrefix: "ProjectTitleItem")
        as? ProjectTitleItem)
    #expect(item.title.subtitle == "All Projects")
    let popover = try #require(
      firstView(in: item.body, typePrefix: "ProjectPickerPopover") as? ProjectPickerPopover)
    let isPresented = try #require(Self.presented(popover))
    #expect(isPresented.wrappedValue)
    isPresented.wrappedValue = false
    #expect(!gallery.isProjectPickerPresented)
    let toggle = try #require(
      buttonAction(in: item.body, label: { "\($0)".contains("All Projects") }))
    toggle()
    #expect(gallery.isProjectPickerPresented)
  }

  @Test("The Project menu the app installs carries Choose Project… on ⌃0")
  func chooseProjectShortcut() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try #require(UserDefaults(suiteName: "pinaxui-picker-\(UUID().uuidString)")),
      databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    let commands = PinaxCommands(app: app)
    // The `CommandMenu` closure is out of reach; its content type is not.
    let installed = String(reflecting: type(of: commands.body))
    #expect(installed.contains("PinaxUI.ProjectMenuItems"))
    let shortcut = buttonShortcut(
      in: commands.projectItems.body, label: { "\($0)".contains("\"Choose Project…\"") })
    #expect(shortcut == KeyboardShortcut("0", modifiers: .control))
  }

  // MARK: - Keyboard (hosted, key window)

  // Runs as `FocusSerial/ProjectPicker/keyboard()`.
  func keyboard() async throws {
    try await withFixture { fixture in
      let gallery = fixture.gallery
      gallery.isProjectPickerPresented = true
      let window = host(ProjectPickerView(model: gallery))
      defer { window.orderOut(nil) }
      window.makeKeyAndOrderFront(nil)
      await waitUntil { window.firstResponder is NSTextView }
      try #require(window.firstResponder is NSTextView, "Find never took focus on open")

      // Typing reaches Find: the field is focused on open.
      for character in "log" { await press(String(character), 0, in: window) }
      #expect(gallery.projectPickerQuery == "log")
      #expect(names(Self.rows(gallery)) == ["Blog", "Photo Log"])
      #expect(Self.row("Blog", gallery)?.isHighlighted == true)

      await press(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125, in: window)
      #expect(Self.row("Photo Log", gallery)?.isHighlighted == true)
      await press(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125, in: window)
      #expect(Self.row("Photo Log", gallery)?.isHighlighted == true, "stops at the end")
      await press(String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), 126, in: window)
      #expect(Self.row("Blog", gallery)?.isHighlighted == true)
      await press(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125, in: window)

      await press("\r", 36, in: window)
      #expect(fixture.app.preferences.currentProjectSlug == "camera")
      #expect(!gallery.isProjectPickerPresented)

      gallery.isProjectPickerPresented = true
      #expect(gallery.isProjectPickerPresented)
      await press("\u{1B}", 53, in: window)
      #expect(!gallery.isProjectPickerPresented)
      #expect(fixture.app.preferences.currentProjectSlug == "camera", "Esc chooses nothing")
    }
  }

  // MARK: - Helpers

  private func host<V: View>(_ view: V) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    return window
  }

  /// A key press through `NSApp.sendEvent`, where local monitors (Esc's)
  /// are consulted ahead of the field editor — serial suite only.
  private func press(_ characters: String, _ keyCode: UInt16, in window: NSWindow) async {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: keyCode)!
    NSApp.sendEvent(event)
    await spin(0.15)
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

  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
  }
}

/// Every view under `view` whose type starts with `prefix`, in body order;
/// stops at class instances.
func allViews(in view: Any, typePrefix prefix: String) -> [Any] {
  if String(describing: type(of: view)).hasPrefix(prefix) { return [view] }
  let mirror = Mirror(reflecting: view)
  if mirror.displayStyle == .class { return [] }
  return mirror.children.flatMap { allViews(in: $0.value, typePrefix: prefix) }
}

/// Records each Scan Now's project; every scan succeeds.
final class ScanRecorder: UsageSyncing, @unchecked Sendable {
  private let lock = NSLock()
  private var _scans: [String] = []

  var scans: [String] { lock.withLock { _scans } }

  func projects() async throws -> [String] { [] }

  func sync(documentAt source: URL, project: String, allowEmpty: Bool) async throws
    -> UsageSyncResult
  {
    UsageSyncResult(scanID: 0, foundCount: 0)
  }

  func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome {
    lock.withLock { _scans.append(project) }
    return UsageScanOutcome(sync: UsageSyncResult(scanID: 0, foundCount: 1), files: 1, skipped: 0)
  }
}

extension FocusSerial {
  @MainActor
  @Suite struct ProjectPicker {
    @Test("↑ ↓ move, Return chooses and closes, Esc closes; Find has focus on open")
    func keyboard() async throws { try await ProjectPickerTests().keyboard() }
  }
}
