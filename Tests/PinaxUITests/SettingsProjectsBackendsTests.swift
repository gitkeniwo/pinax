import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Settings ▸ Projects and Backends, through the panes the Settings window builds:
///
/// - Picking a project or a backend shows that one's page.
/// - Projects' Backend menu and Usage switch still write the project's
///   configuration.
/// - The panes' sizes and the list selection's colour are pinned.
///
/// Menus and sheets are read as values (Mirror), never opened.
@MainActor
@Suite struct SettingsProjectsBackendsTests {
  private func makeApp() async throws -> (PinaxAppModel, DatabasePool, URL) {
    let (database, directory) = try makeUITestDatabase()
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-gui7s4-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    return (app, database, directory)
  }

  /// Hosts `view` at the two-column width and returns the text the
  /// selectable texts and fields draw, once its `.task` has run.
  private func drawnValues(_ view: some View, until loaded: () -> Bool) async -> [String] {
    let host = NSHostingView(rootView: view.environment(\.settingsDefaults, islandTestDefaults()))
    host.frame = NSRect(
      x: 0, y: 0, width: DesignMetrics.settings.listColumnWidth + DesignMetrics.settings.detailWidth,
      height: 900)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let deadline = Date().addingTimeInterval(3)
    repeat {
      pump(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    } while !loaded() && Date() < deadline
    pump(until: Date().addingTimeInterval(0.3))
    var values: [String] = []
    var stack: [NSView] = [host]
    while let next = stack.popLast() {
      if let field = next as? NSTextField, !field.stringValue.isEmpty { values.append(field.stringValue) }
      stack.append(contentsOf: next.subviews)
    }
    return values
  }

  nonisolated private func pump(until date: Date) {
    RunLoop.main.run(until: date)
  }

  @Test("A project picked (Open Project Settings… on a report) is the page shown, and the list marks it")
  func pickedProjectIsShown() async throws {
    let (app, _, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(app.projectSettings)
    model.load()
    // Blog is first; with nothing picked its prefix is the field's.
    let first = await drawnValues(ProjectsSettingsContent(model: model)) { model.snapshot != nil }
    #expect(first.contains("blog") && !first.contains("notes"), "\(first)")

    // A second app: the first page, still alive, would take the request.
    let (other, _, otherDirectory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: otherDirectory) }
    let requested = try #require(other.projectSettings)
    requested.requestedSlug = "notes"
    let picked = await drawnValues(ProjectsSettingsContent(model: requested)) {
      requested.requestedSlug == nil
    }
    #expect(picked.contains("notes") && !picked.contains("blog"), "\(picked)")
  }

  @Test("The backend picked in the list is the page shown")
  func pickedBackendIsShown() async throws {
    let (app, database, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          VALUES
            (2, 'archive', 's3', 'https://archive.example.com', 'old-images', 'eu',
             'https://old.example.com', 'backend.archive', '{}',
             '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z')
          """)
    }
    let model = try #require(app.backends)
    await model.load()
    let column = try #require(
      collectViews(BackendsSettingsContent(model: model).body, as: SettingsListColumn<String>.self).first)
    #expect(column.rows.map(\.id).sorted() == ["archive", "r2"])
    // Load shows the first; the list's own binding picks the other.
    let first = try #require(model.details?.slug)
    let other = first == "archive" ? "r2" : "archive"
    column.$selection.wrappedValue = other
    let deadline = Date().addingTimeInterval(3)
    while model.details?.slug != other, Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(model.selectedSlug == other)
    let drawn = await drawnValues(BackendsSettingsContent(model: model)) { model.details != nil }
    let (shown, hidden) =
      other == "archive"
      ? (["archive.example.com", "old-images"], "storage.example.com")
      : (["storage.example.com", "images"], "archive.example.com")
    #expect(shown.allSatisfy(drawn.contains) && !drawn.contains(hidden), "\(drawn)")
  }

  @Test("Storage's Backend menu and Usage's switch write the project, Inherit / none included")
  func projectControlsWrite() async throws {
    let (app, database, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(app.projectSettings)
    model.load()
    let blog = try #require(model.snapshot?.rows.first { $0.slug == "blog" })
    let editor = ProjectEditorView(row: blog, backendSlugs: ["r2"], model: model)

    // The menu keeps its picker as a value; its binding is the commit.
    let selection = try #require(
      firstView(in: editor.body, typePrefix: "Picker<Text, Optional<String>")
        .flatMap { Mirror(reflecting: $0).descendant("selection", 0) as? Binding<String?> })
    #expect(selection.wrappedValue == "r2")
    selection.wrappedValue = nil
    let stored = try await database.read { db in
      try Int64.fetchOne(db, sql: "SELECT backend_id FROM project WHERE slug = 'blog'")
    }
    #expect(stored == nil)
    #expect(model.snapshot?.rows.first { $0.slug == "blog" }?.backendSlug == nil)

    let usage = try #require(
      collectViews(editor.body, as: ProjectUsageTrackingSection.self).first)
    let toggle = try #require(collectViews(usage.body, as: SettingsRowSwitch.self).first)
    #expect(toggle.title == "Track where images are used")
    #expect(toggle.isOn)
    toggle.$isOn.wrappedValue = false
    #expect(try CatalogConfiguration.projectSettings(slug: "blog", in: database).usageTracking == .notTracked)
  }

  @Test("Island: margins, padding, rows, width range and default; icon and + on the title's edge")
  func islandValues() {
    typealias m = DesignMetrics.settings
    #expect(m.islandDefaultWidth == 196 && m.islandMinWidth == 160 && m.islandMaxWidth == 280)
    #expect(m.islandLeadingInset == 12 && m.islandBottomInset == 12)
    #expect(m.islandTopInset == m.pageTopInset)
    #expect(m.islandDetailGap == 16)
    #expect(m.islandPadding == 8 && m.islandRadius == 12 && m.islandRingWidth == 0.5)
    #expect(m.islandRowHeight == 38 && m.islandRowSpacing == 2)
    #expect(m.islandRowHorizontalPadding == 8 && m.islandRowRadius == 6)
    #expect(m.islandFooterHeight == 28 && m.islandResizeHitWidth == 10)
    // The row's icon and the footer's + start where the page title does.
    #expect(m.islandLeadingInset + m.islandPadding + m.islandRowHorizontalPadding == m.pageInset)
    #expect(m.islandLeadingInset + m.islandFooterLeadingPadding == m.pageInset)

    for (name, ground, ring) in [
      (NSAppearance.Name.aqua, (255.0, 255.0, 255.0), (0.0, 0.0, 0.0)),
      (.darkAqua, (44.0, 44.0, 46.0), (255.0, 255.0, 255.0)),
    ] {
      var island = NSColor.clear
      var edge = NSColor.clear
      NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        island = NSColor(PinaxPalette.Settings.island).usingColorSpace(.sRGB)!
        edge = NSColor(PinaxPalette.Settings.islandRing).usingColorSpace(.sRGB)!
      }
      #expect(abs(island.redComponent * 255 - ground.0) < 1 && abs(island.blueComponent * 255 - ground.2) < 1, "\(name)")
      #expect(abs(island.alphaComponent - 0.5) < 0.01, "\(name)")
      #expect(abs(edge.redComponent * 255 - ring.0) < 1 && abs(edge.alphaComponent - 0.08) < 0.01, "\(name)")
    }
  }

  @Test("Island: a dragged width is kept within 160–280, remembered per page, and drawn next time")
  func islandWidthIsRemembered() async throws {
    let defaults = islandTestDefaults()
    let projects = SettingsListWidth.page(.projects, defaults: defaults)
    let backends = SettingsListWidth.page(.backends, defaults: defaults)
    #expect(projects.stored == 196 && backends.stored == 196)
    #expect(projects.store(400) == 280 && projects.stored == 280)
    #expect(projects.store(90) == 160 && projects.stored == 160)
    projects.store(230)
    #expect(projects.stored == 230)
    #expect(backends.stored == 196, "each page keeps its own")
    defaults.set(1_000.0, forKey: backends.key)
    #expect(backends.stored == 280, "a stored value out of range is clamped on read")

    // The page draws the remembered width.
    let (app, _, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(app.projectSettings)
    model.load()
    let host = NSHostingView(
      rootView: ProjectsSettingsContent(model: model).environment(\.settingsDefaults, defaults))
    host.frame = NSRect(
      x: 0, y: 0, width: DesignMetrics.settings.listColumnWidth + DesignMetrics.settings.detailWidth,
      height: 600)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    pump(until: Date().addingTimeInterval(0.5))
    var widths: [CGFloat] = []
    var stack: [NSView] = [host]
    while let next = stack.popLast() {
      if let scroll = next as? NSScrollView { widths.append(scroll.frame.width) }
      stack.append(contentsOf: next.subviews)
    }
    #expect(widths.contains(230), "\(widths)")
  }

  @Test("Endpoint shows its host; the full URL stays for the tooltip and the copy")
  func endpointShowsItsHost() {
    #expect(
      BackendConnectionSection.shortEndpoint("https://3bd8c2.r2.cloudflarestorage.com")
        == "3bd8c2.r2.cloudflarestorage.com")
    #expect(BackendConnectionSection.shortEndpoint("https://s3.example.com:9000/") == "s3.example.com")
    #expect(BackendConnectionSection.shortEndpoint("not a url") == "not a url")
  }

  @Test("The panes' sizes; a picked list row is the main window's teal at 12 %")
  func pinnedValues() {
    typealias m = DesignMetrics.settings
    #expect(m.keyPrefixFieldWidth == 300)
    #expect(m.sourceFolderIconSize == 18)
    #expect(m.copyIconSize == 14)
    #expect(m.endpointValueMaxWidth == 240)
    #expect(m.windowWidth(for: .projects) == m.sidebarWidth + m.listColumnWidth + m.detailWidth)
    #expect(m.windowWidth(for: .backends) == m.sidebarWidth + m.listColumnWidth + m.detailWidth)
    #expect(m.windowWidth(for: .general) == m.sidebarWidth + m.contentWidth)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = NSAppearance(named: name)!
      var selection = NSColor.clear
      var teal = NSColor.clear
      appearance.performAsCurrentDrawingAppearance {
        selection = NSColor(PinaxPalette.Settings.listSelection).usingColorSpace(.sRGB)!
        teal = NSColor(PinaxPalette.accentFill).usingColorSpace(.sRGB)!
      }
      #expect(abs(selection.redComponent - teal.redComponent) < 0.01, "\(name)")
      #expect(abs(selection.greenComponent - teal.greenComponent) < 0.01, "\(name)")
      #expect(abs(selection.blueComponent - teal.blueComponent) < 0.01, "\(name)")
      #expect(abs(selection.alphaComponent - 0.12) < 0.01, "\(name)")
    }
  }
}
