import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// App-shell surfaces: the Dock-policy window predicate, the menu-command view
/// state on `GalleryModel`, recent-upload mapping, and the app model's
/// shell actions. AppKit objects are constructed, never rendered.
@MainActor
@Suite struct AppLifecycleTests {
  // MARK: - Dock policy predicate

  @Test("Only scene windows count as real windows")
  func activationPredicate() {
    // Identifiers below are the ones SwiftUI actually assigns, measured by
    // probing a real running app:
    // gallery scene window = "gallery", Settings scene window =
    // "com_apple_SwiftUI_Settings_window" (capital S — the predicate is
    // case-insensitive for that reason), the MenuBarExtra's NSStatusBarWindow
    // and the DropZonePanel both have no identifier at all.
    let gallery = NSWindow(
      contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    gallery.identifier = NSUserInterfaceItemIdentifier("gallery")
    let settings = NSWindow(
      contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    settings.identifier = NSUserInterfaceItemIdentifier(
      "com_apple_SwiftUI_Settings_window")
    let statusBar = NSWindow(
      contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    let panel = NSWindow(
      contentRect: .zero, styleMask: [], backing: .buffered, defer: false)

    #expect(gallery.isPinaxActivatingWindow)
    #expect(settings.isPinaxActivatingWindow)
    // The menu bar extra's own window and identifier-less panels (the drop
    // zone) must not hold a Dock tile alive.
    #expect(!statusBar.isPinaxActivatingWindow)
    #expect(!panel.isPinaxActivatingWindow)
  }

  // MARK: - Menu-command view state

  @Test("Sidebar, inspector, and search state toggle through the model")
  func commandViewState() async throws {
    try await withTempDatabase { database in
      let model = makeModel(database)
      #expect(model.isSidebarVisible)
      model.toggleSidebar()
      #expect(!model.isSidebarVisible)
      model.toggleSidebar()
      #expect(model.isSidebarVisible)

      // Closed at launch, and the toggle still round-trips.
      #expect(!model.showsInspector)
      model.toggleInspector()
      #expect(model.showsInspector)
      model.toggleInspector()
      #expect(!model.showsInspector)

      model.focusSearch()
      #expect(model.isSearchPresented)
    }
  }

  @Test("Copy Markdown mirrors the CLI's alt-text rule")
  func markdownMapping() {
    let item = CatalogAssetItem(
      asset: Asset(
        sha256: String(repeating: "a", count: 64),
        backendID: 1,
        key: "blog/shot].png",
        byteSize: 1,
        width: 1,
        height: 1,
        mime: "image/png",
        originalFilename: nil,
        uploadedAt: "2026-08-01T00:00:00Z",
        createdAt: "2026-08-01T00:00:00Z",
        updatedAt: "2026-08-01T00:00:00Z"
      ),
      backend: Backend(
        id: 1, slug: "r2", kind: "s3", endpoint: "https://e", bucket: "b",
        region: "auto", urlPrefix: "https://img.example.com", keychainRef: "backend.r2",
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z")
    )
    // No original filename: the key's last path component is the alt source,
    // a literal "]" in it is escaped exactly as the CLI escapes it, and the
    // URL side arrives percent-encoded from the URL resolver.
    #expect(GalleryModel.markdown(for: item) == "![shot\\]](https://img.example.com/blog/shot%5D.png)")
  }

  @Test("Copy URL and Markdown expose the current selection")
  func selectedCopyPayloads() async throws {
    try await withTempDatabase { database in
      try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
      let model = makeModel(database)
      await model.loadInitialData()
      guard let row = model.rows.first else {
        Issue.record("seeded asset is missing")
        return
      }
      model.selectedIDs = [row.id]
      await waitUntil { model.selectedDetails != nil }

      #expect(model.selectedURL == "https://img.example.com/blog/asset-0.png")
      #expect(model.selectedMarkdown == "![asset-0](https://img.example.com/blog/asset-0.png)")
    }
  }

  // MARK: - Recent uploads

  @Test("Recent uploads mapping is empty for an empty catalog page")
  func recentUploadMapping() {
    #expect(RecentUpload.make(from: []).isEmpty)
  }

  @Test("The app model loads the eight newest uploads from its catalog")
  func appModelRecentUploads() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<10 {
      try seedAsset(
        database, index: index,
        uploadedAt: String(format: "2026-08-%02dT00:00:00Z", index + 1))
    }
    let defaults = try #require(
      UserDefaults(suiteName: "pinaxui-appmodel-tests-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()

    #expect(app.gallery != nil)
    #expect(app.recentUploads.count == 8)
    // Newest first: the newest seeded asset is asset-9.
    #expect(app.recentUploads.first?.filename == "asset-9.png")
    #expect(app.recentUploads.first?.url == "https://img.example.com/blog/asset-9.png")
    #expect(app.recentUploads.last?.filename == "asset-2.png")

    // Re-running the refresh is stable — it is a pure read.
    await app.refreshRecentUploads()
    #expect(app.recentUploads.count == 8)
  }

  @Test("Reveal Catalog is a pure path computation, not a database open")
  func revealCatalogOpensNothing() {
    // locate() must not create or open anything; an override environment
    // points it at a path that has never existed.
    let path = "/tmp/pinax-reveal-test-\(UUID().uuidString)/catalog.sqlite"
    let url = DBLocation.locate(environment: ["PINAX_DB": path])
    #expect(url.path == path)
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  // MARK: - Wiring: preferences reach the zone model

  @Test("The shell pushes drop zone behaviour preferences into the zone model")
  func appModelSyncsDropZoneBehaviour() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(
      UserDefaults(suiteName: "pinaxui-h4-tests-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()

    // Defaults, pushed once at start. This pins the shell-to-zone wiring
    // itself, not the model logic beneath it — the seam a bug once hid in.
    let zone = try #require(app.dropZone?.model)
    #expect(zone.dragVisibilityModifier == nil)
    #expect(zone.autoHidesResultsAfter == 30)
    #expect(zone.copiesURLsAutomatically)
    #expect(zone.urlCopier != nil)

    // A runtime preference change reaches the model on the next main hop
    // (the store publishes before the change; the sink defers past it).
    app.preferences.dropZoneRequiresModifier = true
    app.preferences.dropZoneModifier = .command
    app.preferences.dropZoneAutoHideSeconds = 0
    app.preferences.copiesURLsOnUpload = false
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(zone.dragVisibilityModifier == .command)
    #expect(zone.autoHidesResultsAfter == 0)
    #expect(!zone.copiesURLsAutomatically)
  }

  // MARK: - Wiring: the projects settings pane's model

  @Test("start() exposes the projects settings model over the opened catalog")
  func appModelExposesProjectSettings() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(
      UserDefaults(suiteName: "pinaxui-h5-tests-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    #expect(app.projectSettings == nil)
    await app.start()

    // The pane appears pre-loaded from the same database the gallery uses —
    // the seeded projects with their backend resolved to a slug.
    let settings = try #require(app.projectSettings)
    let snapshot = try #require(settings.snapshot)
    #expect(snapshot.rows.map(\.slug) == ["blog", "notes"])
    #expect(snapshot.rows.map(\.backendSlug) == ["r2", "r2"])
    #expect(snapshot.backendSlugs == ["r2"])
  }

  // MARK: - Menu bar ▸ Show Drop Zone

  @Test("Menu bar ▸ Show Drop Zone with no uploads this run shows the catalog's 10 newest, done")
  func menuBarShowDropZoneShowsRecent() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let formatter = ISO8601DateFormatter()
    for index in 0..<12 {
      let when = Date().addingTimeInterval(-Double(12 - index) * 3600)
      try seedAsset(database, index: index, uploadedAt: formatter.string(from: when))
    }
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: try makeDefaults(), databaseOpener: { database })
    await app.start()
    let zone = try #require(app.dropZone?.model)
    let clock = FakeClock()
    zone.autoHideScheduler = clock.schedule
    #expect(!zone.isWindowVisible)

    // The menu the app installs (`MenuBarExtra { PinaxMenuBarContent(app:) }` → `MenuBarFooter`).
    let show = try #require(showDropZoneAction(app))
    show()
    await waitUntil { zone.isWindowVisible }
    #expect(zone.isWindowVisible)
    #expect(zone.cards.map(\.filename) == (2..<12).reversed().map { "asset-\($0).png" })
    #expect(zone.cards.allSatisfy { if case .done = $0.phase { true } else { false } })
    #expect(zone.cards.allSatisfy { $0.projectSlug == "blog" })
    #expect(zone.url(for: zone.cards[0]) == "https://img.example.com/blog/asset-11.png")

    // Shown from the menu, it counts down like a drop (default 30 s).
    clock.advance(by: 29)
    #expect(zone.isWindowVisible)
    clock.advance(by: 1)
    #expect(!zone.isWindowVisible)
  }

  @Test("Menu bar ▸ Show Drop Zone brings back this run's cards when there are any")
  func menuBarShowDropZoneShowsSession() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: ISO8601DateFormatter().string(from: Date()))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: try makeDefaults(), databaseOpener: { database })
    await app.start()
    let zone = try #require(app.dropZone?.model)
    // A file that cannot be read fails fast: a card of this run, no network.
    zone.drop(fileURLs: [URL(fileURLWithPath: "/nonexistent/pinax-\(UUID().uuidString).png")])
    await waitUntil { zone.cards.allSatisfy { !$0.phase.isPending } }
    zone.dismiss()
    #expect(!zone.isWindowVisible)

    let show = try #require(showDropZoneAction(app))
    show()
    await waitUntil { zone.isWindowVisible }
    #expect(zone.isWindowVisible)
    #expect(zone.cards.count == 1)
    #expect(zone.cards.first?.filename.hasPrefix("pinax-") == true)
  }

  @Test("Menu bar ▸ Show Drop Zone is clickable once the app has started, and not before")
  func menuBarShowDropZoneEnabled() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: try makeDefaults(), databaseOpener: { database })
    // No drop zone yet: the item the app installs is greyed out.
    #expect(app.dropZone == nil)
    #expect(showDropZoneEnabled(app) == false)
    await app.start()
    #expect(app.dropZone != nil)
    #expect(showDropZoneEnabled(app) == true)
  }

  private func showDropZoneEnabled(_ app: PinaxAppModel) -> Bool? {
    let summary = MenuBarSummary(app: app, clipboard: nil)
    let footer = MenuBarFooter(app: app, preferences: app.preferences, summary: summary)
    return buttonIsEnabled(in: footer.body, label: { "\($0)".contains("\"Show Drop Zone\"") })
  }

  // MARK: - Settings ▸ Drop Zone ▸ Auto hide after, through the app's picker

  @Test("Each Auto hide rung picked in the app's picker is stored and counted down as its seconds")
  func autoHidePickerReachesTheCountdown() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let zone = try #require(app.dropZone?.model)
    var scheduled: [TimeInterval] = []
    zone.autoHideScheduler = { delay, _ in
      scheduled.append(delay)
      return {}
    }

    // The settings scene the app installs (`Settings { PinaxSettingsView(...) }`),
    // on the Drop Zone page.
    app.settingsTab = .dropZone
    let settings = PinaxSettingsView(preferences: app.preferences, app: app)
    let pane = try #require(firstView(in: settings.body, typePrefix: "DropZoneSettingsPane") as? any View)
    let picker = try #require(firstView(in: openedBody(pane), typePrefix: "Picker<Text, Int,"))
    let mirror = Mirror(reflecting: picker)
    #expect("\(try #require(mirror.descendant("label")))".contains("\"Hide the panel after uploads finish\""))
    let selection = try #require(mirror.descendant("selection", 0) as? Binding<Int>)
    let forEach = try #require(mirror.descendant("content") as? any IntForEach)
    // Each row as the picker shows it: its visible label and its tag.
    let rows = forEach.rows().map { (label: textString(in: $0), tags: tags(in: $0)) }

    let rungs: [(label: String, seconds: Int)] = [
      ("Never", 0), ("30 s", 30), ("1 min", 60), ("2 min", 120), ("3 min", 180),
      ("4 min", 240), ("5 min", 300), ("10 min", 600),
    ]
    #expect(rows.map(\.label) == rungs.map(\.label))
    for rung in rungs {
      let shown = try #require(rows.first { $0.label == rung.label }, "no row \(rung.label)")
      let tag = try #require(shown.tags.first, "row \(rung.label) has no tag")
      #expect(Set(shown.tags).count == 1, "\(rung.label): \(shown.tags)")
      selection.wrappedValue = tag

      #expect(defaults.integer(forKey: "pinax.dropZone.autoHideSeconds") == rung.seconds, "\(rung.label)")
      #expect(app.preferences.dropZoneAutoHideSeconds == rung.seconds, "\(rung.label)")
      await waitUntil { zone.autoHidesResultsAfter == TimeInterval(rung.seconds) }
      #expect(zone.autoHidesResultsAfter == TimeInterval(rung.seconds), "\(rung.label)")

      // The countdown the model actually starts once a drop settles.
      scheduled.removeAll()
      zone.drop(fileURLs: [URL(fileURLWithPath: "/nonexistent/pinax-\(UUID().uuidString).png")])
      await waitUntil { zone.cards.allSatisfy { !$0.phase.isPending } }
      if rung.seconds == 0 {
        #expect(scheduled.isEmpty, "Never started a countdown: \(scheduled)")
      } else {
        #expect(scheduled.last == TimeInterval(rung.seconds), "\(rung.label): \(scheduled)")
      }
      zone.dismiss()
    }
  }

  private func openedBody<V: View>(_ view: V) -> Any { view.body }

  /// A row's visible string: the `Text` it is built from, verbatim or keyed.
  private func textString(in row: Any) -> String? {
    guard let text = firstView(in: row, typePrefix: "Text") else { return nil }
    if let verbatim = Mirror(reflecting: text).descendant("storage", "verbatim") as? String {
      return verbatim
    }
    let description = "\(text)"
    return description.split(separator: "\"").dropFirst().first.map(String.init)
  }

  /// Every `.tag(_:)` value a row carries (`TagValueTraitKey<…>.Value.tagged`).
  private func tags(in value: Any) -> [Int] {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .class { return [] }
    return mirror.children.flatMap { child -> [Int] in
      if child.label == "tagged", let tag = child.value as? Int { return [tag] }
      return tags(in: child.value)
    }
  }

  private func showDropZoneAction(_ app: PinaxAppModel) -> (() -> Void)? {
    let summary = MenuBarSummary(app: app, clipboard: nil)
    let footer = MenuBarFooter(app: app, preferences: app.preferences, summary: summary)
    return buttonAction(in: footer.body, label: { "\($0)".contains("\"Show Drop Zone\"") })
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-lifecycle-\(UUID().uuidString)"))
  }

  // MARK: - Helpers

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-lifecycle-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func withTempDatabase(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(database)
  }
}

/// A `ForEach` over `[Int]`, opened so a test can build the rows it declares.
private protocol IntForEach { func rows() -> [Any] }
extension ForEach: IntForEach where Data == [Int] {
  fileprivate func rows() -> [Any] { data.map { content($0) } }
}
