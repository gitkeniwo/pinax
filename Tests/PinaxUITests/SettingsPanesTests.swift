import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// The Settings window, through what the app installs:
///
/// - The menu bar's switch and Settings' are one preference.
/// - General, Drop Zone and Gallery fit their 568 pt page: no horizontal scrolling.
/// - The Gallery page's new Sort pickers write the one order the gallery
///   queries by.
///
/// Views are read as values (Mirror), never opened; a walk stops at any
/// class, so it never wanders into an object graph.
@MainActor
@Suite(.serialized) struct SettingsPanesTests {
  /// The value's children in order: `Toggle`, `Button` and `Divider` as
  /// items (a control's title from its label's text), anything else walked
  /// into.
  private func items(in value: Any) -> [String] {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .class { return [] }
    let typeName = String(describing: type(of: value))
    if typeName == "Divider" { return ["Divider"] }
    for kind in ["Toggle", "Button"] where typeName.hasPrefix("\(kind)<") {
      let description = "\(value)"
      let title = description.split(separator: "\"").dropFirst().first.map(String.init) ?? "?"
      return ["\(kind) \(title)"]
    }
    if typeName.hasPrefix("ModifiedContent<"), let content = mirror.descendant("content") {
      return items(in: content)
    }
    return mirror.children.flatMap { items(in: $0.value) }
  }

  private func firstView(in value: Any, typePrefix: String) -> Any? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .class { return nil }
    if String(describing: type(of: value)).hasPrefix(typePrefix) { return value }
    for child in mirror.children {
      if let found = firstView(in: child.value, typePrefix: typePrefix) { return found }
    }
    return nil
  }

  private func makeApp() async throws -> (PinaxAppModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-settings-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    return (app, directory)
  }

  @Test("The menu bar's switch and Settings' switch are one preference, worded for their place")
  func menuBarSwitch() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The footer the panel installs: the switch, the command, a divider, Quit.
    let summary = MenuBarSummary(app: app, clipboard: nil)
    #expect(summary.footer == [.dropZoneWhileDragging, .showDropZone, .divider, .quit])
    let settings = allViews(
      in: DropZoneSettingsPane(preferences: app.preferences).body, typePrefix: "SettingsRowSwitch"
    ).compactMap { ($0 as? SettingsRowSwitch)?.title }
    #expect(settings.contains("Show drop zone while dragging"), "\(settings)")
    #expect(!settings.contains("Enable drop zone"))
  }

  @Test("General, Appearance, Drop Zone and Gallery fit the 568 pt page without scrolling sideways")
  func panesFitTheWidth() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preferences = app.preferences
    let panes: [(String, AnyView)] = [
      ("General", AnyView(GeneralSettingsPane(preferences: preferences))),
      ("Appearance", AnyView(AppearanceSettingsPane(preferences: preferences))),
      ("Drop Zone", AnyView(DropZoneSettingsPane(preferences: preferences))),
      ("Gallery", AnyView(GallerySettingsPane(preferences: preferences))),
    ]
    #expect(DesignMetrics.settings.contentWidth == 568)
    for (name, pane) in panes {
      let host = NSHostingView(rootView: pane)
      host.frame = NSRect(x: 0, y: 0, width: DesignMetrics.settings.contentWidth, height: 800)
      host.layoutSubtreeIfNeeded()
      #expect(host.fittingSize.width <= DesignMetrics.settings.contentWidth, "\(name): \(host.fittingSize)")
      #expect(host.fittingSize.width > 0, "\(name)")
    }
  }

  @Test("The Settings window is the sidebar plus the page (content 568, or list 210 + detail 538), and builds only the chosen page")
  func settingsWindowWidthFollowsThePage() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    typealias m = DesignMetrics.settings
    #expect(m.contentWidth == 568)
    #expect(m.listColumnWidth == 210 && m.detailWidth == 538)
    let panes: [SettingsTab: String] = [
      .general: "GeneralSettingsPane", .appearance: "AppearanceSettingsPane",
      .dropZone: "DropZoneSettingsPane", .gallery: "GallerySettingsPane",
      .projects: "ProjectsSettingsPane", .backends: "BackendsSettingsPane",
      .maintenance: "MaintenanceSettingsPane",
    ]
    for tab in SettingsTab.sidebarGroups.flatMap({ $0 }) {
      app.settingsTab = tab
      // The settings scene the app installs (`Settings { PinaxSettingsView(...) }`).
      let settings = PinaxSettingsView(preferences: app.preferences, app: app)
      let width = m.sidebarWidth + (tab == .projects || tab == .backends ? m.listColumnWidth + m.detailWidth : m.contentWidth)
      #expect(NSHostingView(rootView: settings).fittingSize.width == width, "\(tab)")
      for (other, name) in panes {
        #expect((firstView(in: settings.body, typePrefix: name) != nil) == (other == tab), "\(tab): \(name)")
      }
    }
  }

  @Test("The sidebar lists the seven pages in four groups and picking a row turns the page")
  func settingsSidebarTurnsThePage() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(SettingsTab.sidebarGroups.map { $0.map(\.title) } == [
      ["General", "Appearance"], ["Drop Zone", "Gallery"], ["Projects", "Backends"], ["Maintenance"],
    ])
    // The sidebar the app installs, its binding: a pick writes `settingsTab`,
    // which the menu bar's ⌘, and Show in Settings also write.
    let settings = PinaxSettingsView(preferences: app.preferences, app: app)
    let sidebar = try #require(firstView(in: settings.body, typePrefix: "SettingsSidebar") as? SettingsSidebar)
    sidebar.selection = .backends
    #expect(app.settingsTab == .backends)
    app.settingsTab = .maintenance
    #expect(sidebar.selection == .maintenance)
  }

  @Test("The Settings window's content runs under a transparent, titleless, lineless 52 pt bar; the user drags its height")
  func settingsWindowChrome() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The settings scene the app installs, in a window made as the scene
    // makes one: titled, no full-size content, no resize edge.
    let host = NSHostingView(rootView: PinaxSettingsView(preferences: app.preferences, app: app))
    host.frame = NSRect(x: 0, y: 0, width: 780, height: DesignMetrics.settings.minHeight)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(window.styleMask.contains(.fullSizeContentView) && window.styleMask.contains(.resizable))
    #expect(window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
    #expect(window.titlebarSeparatorStyle == .none)
    #expect(window.toolbar != nil && window.toolbarStyle == .unified)
    // The bar the toolbar makes is the page title's band.
    let bar = window.frame.height - window.contentLayoutRect.height
    #expect(bar == DesignMetrics.settings.titleBarHeight, "title bar \(bar)")
    // The page fixes the width and leaves the height to the user.
    #expect(window.contentMaxSize.height > 2000, "max \(window.contentMaxSize.height)")
    // Losing either (the scene re-fitting the window) puts it back.
    window.styleMask.remove([.fullSizeContentView, .resizable])
    #expect(window.styleMask.contains(.fullSizeContentView) && window.styleMask.contains(.resizable))
  }

  @Test("Icon proportions and colours, the ink group, the form's sizes")
  func settingsConfiguration() {
    typealias m = DesignMetrics.settings
    #expect(m.iconCornerRatio == 0.235 && m.iconGlyphRatio == 0.74)
    #expect(m.sidebarIconSize == 20 && m.listRowIconSize == 24)
    #expect(m.groupRadius == 10 && m.rowMinHeight == 40 && m.titleBarHeight == 52)
    let gradients = SettingsTab.sidebarGroups.flatMap { $0 }.map {
      let light = PinaxPalette.settingsIconGradient($0, dark: false)
      let dark = PinaxPalette.settingsIconGradient($0, dark: true)
      return "\(light.top)→\(light.bottom) \(dark.top)→\(dark.bottom)"
    }
    #expect(gradients == [
      "#a89984→#7c6f64 #bdae93→#928374", "#504945→#282828 #665c54→#3c3836",
      "#458588→#076678 #83a598→#458588", "#d65d0e→#af3a03 #fe8019→#d65d0e",
      "#689d6a→#427b58 #8ec07c→#689d6a", "#b16286→#8f3f71 #d3869b→#b16286",
      "#98971a→#79740e #b8bb26→#98971a",
    ])
    #expect(PinaxPalette.settingsIconGlyph(.gallery, dark: false).description == "#fbf1c7")
    #expect(PinaxPalette.settingsIconGlyph(.gallery, dark: true).description == "#282828")
    #expect(PinaxPalette.settingsIconGlyph(.appearance, dark: true).description == "#ebdbb2")
    let ink = PinaxPalette.Ink.allCases.map {
      "\(PinaxPalette.inkValue($0, dark: false)) \(PinaxPalette.inkValue($0, dark: true))"
    }
    #expect(ink == [
      "#9d0006 #fb4934", "#79740e #b8bb26", "#b57614 #fabd2f", "#076678 #83a598",
      "#8f3f71 #d3869b", "#427b58 #8ec07c", "#af3a03 #fe8019", "#7c6f64 #a89984",
    ])
  }

  @Test("The Gallery page's Sort pickers write the order the gallery queries")
  func gallerySortPickers() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gallery = try #require(app.gallery)
    #expect(gallery.sort == AssetSort())

    // The settings scene the app installs (`Settings { PinaxSettingsView(...) }`),
    // on the Gallery page.
    app.settingsTab = .gallery
    let settings = PinaxSettingsView(preferences: app.preferences, app: app)
    let pane = try #require(
      firstView(in: settings.body, typePrefix: "GallerySettingsPane") as? GallerySettingsPane)
    let field = try #require(
      firstView(in: pane.body, typePrefix: "Picker<Text, Field,")
        .flatMap { Mirror(reflecting: $0).descendant("selection", 0) as? Binding<AssetSort.Field> })
    let direction = try #require(
      firstView(in: pane.body, typePrefix: "Picker<Text, Direction,")
        .flatMap { Mirror(reflecting: $0).descendant("selection", 0) as? Binding<AssetSort.Direction> })

    field.wrappedValue = .byteSize
    direction.wrappedValue = .ascending
    let written = AssetSort(field: .byteSize, direction: .ascending)
    #expect(app.preferences.gallerySort == written)
    #expect(gallery.sort == written, "pushed to the gallery like View ▸ Sort By")
  }

  // MARK: - Projects

  /// Every `SettingsFooter` in a view value, as its lines.
  private func footers(in value: Any) -> [[String]] {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .class { return [] }
    if let footer = value as? SettingsFooter { return [footer.lines] }
    return mirror.children.flatMap { footers(in: $0.value) }
  }

  private func scrollViews(in view: NSView) -> [NSScrollView] {
    var found: [NSScrollView] = []
    var stack = [view]
    while let next = stack.popLast() {
      if let scroll = next as? NSScrollView { found.append(scroll) }
      stack.append(contentsOf: next.subviews)
    }
    return found
  }

  @Test("Projects: the 210 pt list column beside the page; the list marks the project shown; Storage's note and the ambiguity subtitle")
  func projectsPage() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-settings-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let model = try #require(app.projectSettings)
    model.load()
    let snapshot = try #require(model.snapshot)
    let blog = try #require(snapshot.rows.first { $0.slug == "blog" })

    let host = NSHostingView(
      rootView: ProjectsSettingsContent(model: model).environment(\.settingsDefaults, islandTestDefaults()))
    host.frame = NSRect(
      x: 0, y: 0, width: DesignMetrics.settings.listColumnWidth + DesignMetrics.settings.detailWidth,
      height: 420)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    for scroll in scrollViews(in: host) {
      let document = scroll.documentView?.frame.width ?? 0
      #expect(
        document <= scroll.contentView.bounds.width + 0.5,
        "\(type(of: scroll)) document \(document) in \(scroll.contentView.bounds.width)")
    }
    // The island is 196 wide at first, 12 in; the page takes the rest.
    let widths = scrollViews(in: host).map(\.frame.width)
    #expect(widths.contains(DesignMetrics.settings.islandDefaultWidth), "\(widths)")
    #expect(widths.contains(islandDetailWidth), "\(widths)")

    // The list: one row per project, "N sources" under its name; with
    // nothing picked, the first is marked and shown.
    let column = try #require(
      collectViews(ProjectsSettingsContent(model: model).body, as: SettingsListColumn<String>.self).first)
    #expect(column.rows.map(\.id) == snapshot.rows.map(\.slug))
    #expect(column.rows.map(\.subtitle) == snapshot.rows.map { ProjectsSettingsContent.sourceCount($0.sources.count) })
    #expect(column.selection == snapshot.rows.first?.slug)
    #expect(column.onRemove == nil, "nothing removes a project")
    #expect(ProjectsSettingsContent.sourceCount(1) == "1 source")
    #expect(ProjectsSettingsContent.sourceCount(2) == "2 sources")
    let shown = collectViews(ProjectsSettingsContent(model: model).body, as: ProjectEditorView.self)
    #expect(shown.map(\.row.slug) == [snapshot.rows.first?.slug])

    // Storage's note is one fixed sentence; the ambiguity shows only with
    // several backends and none picked.
    #expect(ProjectEditorView.storageNote == "Applies to new uploads only.")
    #expect(ProjectEditorView(row: blog, backendSlugs: ["r2"], model: model).backendSubtitle == nil)
    let orphan = ProjectSettingsRow(id: 0, slug: "x", name: "X", keyPrefix: "", backendSlug: nil)
    #expect(ProjectEditorView(row: orphan, backendSlugs: ["r2"], model: model).backendSubtitle == nil)
    #expect(
      ProjectEditorView(row: orphan, backendSlugs: ["r2", "b2"], model: model).backendSubtitle
        == ProjectEditorView.ambiguousBackendWarning)
    #expect(
      ProjectEditorView.headerSubtitle(
        ProjectSettingsRow(id: 0, slug: "astro", name: "astro", keyPrefix: "", backendSlug: nil, referenceCount: 318))
        == "Slug astro · 318 references")
  }

  // MARK: - Backends

  private func fieldValues(in view: NSView) -> [String] {
    var values: [String] = []
    var stack = [view]
    while let next = stack.popLast() {
      if let field = next as? NSTextField, !field.stringValue.isEmpty { values.append(field.stringValue) }
      stack.append(contentsOf: next.subviews)
    }
    return values
  }

  @Test("Backends: the 210 pt list column with each backend's kind; Connection's values selectable; the pill and the CLI chip")
  func backendsPage() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    // No keychain entry: "No credentials", never a secret.
    let keychain = Keychain(service: "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)")
    let model = BackendsModel(reader: CatalogBackendsReader(database: database, keychain: keychain))
    await model.load()
    let details = try #require(model.details)

    let host = NSHostingView(
      rootView: BackendsSettingsContent(model: model).environment(\.settingsDefaults, islandTestDefaults()))
    host.frame = NSRect(
      x: 0, y: 0, width: DesignMetrics.settings.listColumnWidth + DesignMetrics.settings.detailWidth,
      height: 600)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    let widths = scrollViews(in: host).map(\.frame.width)
    #expect(widths.contains(DesignMetrics.settings.islandDefaultWidth), "\(widths)")
    for scroll in scrollViews(in: host) {
      let document = scroll.documentView?.frame.width ?? 0
      #expect(document <= scroll.contentView.bounds.width + 0.5, "\(type(of: scroll))")
    }

    // The values stand alone — no "Label: value" strings — and each is
    // selectable text. The public URL lives in the Domains list, which
    // shows the host alone: the full prefix is not one of Connection's
    // values.
    let values = fieldValues(in: host)
    for value in [
      BackendConnectionSection.shortEndpoint(details.endpoint), details.bucket, details.region,
    ] {
      #expect(values.contains(value), "\(value) in \(values)")
    }
    #expect(!values.contains { $0.hasPrefix("Endpoint: ") || $0.hasPrefix("Bucket: ") })

    let column = try #require(
      collectViews(BackendsSettingsContent(model: model).body, as: SettingsListColumn<String>.self).first)
    #expect(column.rows.map(\.subtitle) == [BackendsSettingsContent.kindName(details.kind)])
    #expect(column.selection == details.slug)
    #expect(column.onRemove == nil, "nothing removes a backend")
    #expect(BackendsSettingsContent.kindName("s3") == "S3-compatible")

    #expect(BackendsSettingsContent.credentialsStatus(details) == ("No credentials", .warning))
    let pills = collectViews(BackendsSettingsContent(model: model).body, as: SettingsStatusPill.self)
    // collectViews meets a page's content twice per settings card container (stored
    // and in its body), so the drawn set is compared.
    #expect(Set(pills.map(\.text)) == ["No credentials"])
    let chips = collectViews(BackendsSettingsContent(model: model).body, as: SettingsCodeChip.self)
    #expect(Set(chips.map(\.code)) == ["pinax backend set-credentials --slug \(details.slug)"])
  }

  // MARK: - The width property

  /// Every view drawn in `host` that reaches past the page's sides or past
  /// a clip view it sits in — a row cut off, or a document wider than its
  /// clip view (sideways scrolling). Frames are compared, so a row the form
  /// lays out wider than the page is caught even though its scroll view
  /// never grows a scroller.
  private func clippedViews(in host: NSView, width: CGFloat) -> [String] {
    var found: [String] = []
    // The page's width, not the host's: a hosting view grows to fit.
    let page = NSRect(x: 0, y: host.bounds.minY, width: width, height: host.bounds.height)
    var stack: [(NSView, NSRect)] = [(host, page)]
    while let (view, visible) = stack.popLast() {
      if view.isHidden || view is NSScroller { continue }
      let frame = view.convert(view.bounds, to: host)
      if frame.width > 0, frame.height > 0,
        frame.minX < visible.minX - 0.5 || frame.maxX > visible.maxX + 0.5
      {
        found.append("\(type(of: view)) x \(frame.minX)–\(frame.maxX) in \(visible.minX)–\(visible.maxX)")
      }
      let inner = view is NSClipView ? visible.intersection(frame) : visible
      stack.append(contentsOf: view.subviews.map { ($0, inner) })
    }
    return found
  }

  @Test("The seven settings pages, as the app installs them, at their page width: no row cut off, nothing scrolls sideways")
  func noPageClipsAtTheWidth() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    typealias m = DesignMetrics.settings

    for (tab, name) in [
      (SettingsTab.general, "GeneralSettingsPane"), (.appearance, "AppearanceSettingsPane"),
      (.dropZone, "DropZoneSettingsPane"), (.gallery, "GallerySettingsPane"),
      (.projects, "ProjectsSettingsPane"), (.backends, "BackendsSettingsPane"),
      (.maintenance, "MaintenanceSettingsPane"),
    ] {
      app.settingsTab = tab
      let settings = PinaxSettingsView(preferences: app.preferences, app: app)
      // The width is the app's own frame, measured, not the constant.
      let pageWidth = NSHostingView(rootView: settings).fittingSize.width - m.sidebarWidth
      #expect(pageWidth == (tab.hasListColumn ? 748 : 568), "\(name)")
      let pane = try #require(firstView(in: settings.body, typePrefix: name) as? any View, "\(name)")
      let host = NSHostingView(
        rootView: AnyView(pane).environment(\.settingsDefaults, islandTestDefaults()))
      host.frame = NSRect(x: 0, y: 0, width: pageWidth, height: 800)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = host
      window.orderFront(nil)
      defer { window.orderOut(nil) }
      // Each page loads its rows on appear; it is measured once they are
      // in, not on its loading spinner.
      let loaded: () -> Bool =
        switch name {
        case "ProjectsSettingsPane": { app.projectSettings?.snapshot != nil }
        case "BackendsSettingsPane": { app.backends?.details != nil }
        case "MaintenanceSettingsPane": { app.maintenance?.report != nil }
        default: { true }
        }
      let deadline = Date().addingTimeInterval(5)
      while !loaded(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      #expect(loaded(), "\(name) never loaded")
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))

      // Backends is drawn, not its spinner: the 196 pt island on the left,
      // the page's Connection values on the right.
      if name == "BackendsSettingsPane", let details = app.backends?.details {
        let widths = scrollViews(in: host).map(\.frame.width)
        #expect(widths.contains(m.islandDefaultWidth), "Backends list: \(widths)")
        #expect(widths.contains(islandDetailWidth), "Backends page: \(widths)")
        let values = fieldValues(in: host)
        #expect(
          values.contains(BackendConnectionSection.shortEndpoint(details.endpoint))
            && values.contains(details.bucket), "\(values)")
      }

      let clipped = clippedViews(in: host, width: pageWidth)
      #expect(clipped.isEmpty, "\(name): \(clipped.count) views, first \(clipped.prefix(3))")
    }
  }

  // MARK: - Maintenance

  @Test("Doctor check names read as words, and only a slug-list usage-scans warning splits into never-scanned lines")
  func doctorWords() {
    #expect(DoctorCheckRow.title("database-location") == "Database location")
    #expect(DoctorCheckRow.title("backend-credentials") == "Backend credentials")
    #expect(DoctorCheckRow.title("usage-scans") == "Usage scans")
    func check(_ name: String, _ status: DoctorStatus, _ detail: String) -> DoctorCheck {
      DoctorCheck(name: name, status: status, detail: detail)
    }
    #expect(DoctorCheckRow.neverScannedProjects(check("usage-scans", .warning, "astro, my_docs")) == ["astro", "my_docs"])
    #expect(DoctorCheckRow.neverScannedProjects(check("usage-scans", .warning, "astro")) == ["astro"])
    #expect(DoctorCheckRow.neverScannedProjects(check("usage-scans", .warning, "One project needs a scan")) == nil)
    #expect(
      DoctorCheckRow.neverScannedProjects(
        check("usage-scans", .warning, "3 assets, 0 projects. Reindex does not restore projects, tags, or usage history."))
        == nil)
    #expect(DoctorCheckRow.neverScannedProjects(check("usage-scans", .pass, "astro")) == nil)
    #expect(DoctorCheckRow.neverScannedProjects(check("usage-membership", .warning, "astro")) == nil)
  }

  @Test("Maintenance through the app: in 568 pt, the never-scanned projects named with their action, each check in words")
  func maintenancePage() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The settings scene the app installs, its Maintenance page.
    app.settingsTab = .maintenance
    let pane = try #require(
      firstView(in: PinaxSettingsView(preferences: app.preferences, app: app).body,
        typePrefix: "MaintenanceSettingsPane") as? MaintenanceSettingsPane)
    let host = NSHostingView(rootView: pane)
    host.frame = NSRect(x: 0, y: 0, width: DesignMetrics.settings.contentWidth, height: 800)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let deadline = Date().addingTimeInterval(5)
    while app.maintenance?.report == nil, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let report = try #require(app.maintenance?.report, "the maintenance report never loaded")
    // Laid out, not slept on: wait until the form shows every check.
    let shown = Date().addingTimeInterval(15)
    while !report.checks.allSatisfy({ fieldValues(in: host).contains(DoctorCheckRow.title($0.name)) }),
      Date() < shown
    {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let usage = try #require(report.checks.first { $0.name == "usage-scans" })
    #expect(usage.status == .warning && usage.detail == "blog, notes", "the fixture's two unscanned projects")

    let values = fieldValues(in: host)
    #expect(values.contains("blog · never scanned") && values.contains("notes · never scanned"), "\(values)")
    #expect(!values.contains("blog, notes"), "the slug list is split, not repeated")
    // The ids are each row's help tag (see `SettingsAppearanceDropZoneTests`).
    for check in report.checks {
      #expect(values.contains(DoctorCheckRow.title(check.name)), "\(check.name) in words")
    }
    #expect(values.contains("Database location"))
    for scroll in scrollViews(in: host) {
      let document = scroll.documentView?.frame.width ?? 0
      #expect(document <= scroll.contentView.bounds.width + 0.5, "\(type(of: scroll))")
    }
  }
}
