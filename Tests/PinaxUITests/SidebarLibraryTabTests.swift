import CatalogCore
import Foundation
@testable import PinaxUI
import Testing

/// The Library tab's Storage section, its Projects
/// and Time shortcut sections, the header menu, and the one preference the
/// menu and Settings ▸ Appearance share.
@MainActor
@Suite struct SidebarLibraryTabTests {
  private let projects = [
    ProjectSummary(
      slug: "blog", name: "Blog", assetCount: 5, liveUsageCount: 4,
      lastScanAt: "2026-08-20T13:00:00Z"),
    ProjectSummary(
      slug: "notes", name: "Notes", assetCount: 3, liveUsageCount: 0, lastScanAt: nil),
  ]
  private let months: [(month: String, count: Int)] = [
    ("2026-08", 3), ("2026-03", 2), ("2025-12", 1),
  ]
  private let root = CatalogRoot(
    slug: "r2", prefix: "https://img.example.com", assetCount: 4, bucket: "image-hosting")
  private let folderChildren: KeyPrefixChildren = [.r2(nil): [("202409", 4, false)]]

  private func library(
    _ shortcuts: Set<LibraryShortcut>, projects: [ProjectSummary]? = nil,
    months: [(month: String, count: Int)]? = nil
  ) -> [SidebarSection] {
    SidebarModel.sections(
      navigator: .library, projects: projects ?? self.projects, tags: [],
      months: months ?? self.months, folderChildren: folderChildren, catalogRoots: [root],
      libraryShortcuts: shortcuts)
  }

  private func path(
    _ selection: SidebarSelection, shortcuts: Set<LibraryShortcut> = LibraryShortcut.defaultShown
  ) -> [String] {
    JumpBar.components(
      selection: selection, navigator: .library, projects: projects, tags: [], months: months,
      folderChildren: folderChildren, catalogRoots: [root], libraryShortcuts: shortcuts,
      selectedName: nil
    ).map(\.label)
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-sidebar-s1-\(UUID().uuidString)"))
  }

  // MARK: - Item 1: Storage

  @Test("Storage: the root row is the slug, the bucket after it, bucket · prefix as its tooltip")
  func storageRoot() throws {
    let storage = try #require(library([]).first { $0.id == "catalog" })
    #expect(storage.title == "Storage")
    let row = try #require(storage.entries.first)
    #expect(row.label == "r2")
    #expect(row.detail == "image-hosting")
    #expect(row.help == "image-hosting · https://img.example.com")
    // A domain move: the name stays, the tooltip follows the Current prefix.
    let moved = CatalogRoot(
      slug: "r2", prefix: "https://img2.example.com", assetCount: 4, bucket: "image-hosting")
    let after = try #require(
      SidebarModel.sections(
        navigator: .library, projects: [], tags: [], months: [], folderChildren: folderChildren,
        catalogRoots: [moved]
      ).first { $0.id == "catalog" }?.entries.first)
    #expect(after.label == "r2")
    #expect(after.help == "image-hosting · https://img2.example.com")
    // No bucket known: no secondary text, the prefix alone.
    let bare = CatalogRoot(slug: "r2", prefix: "https://img.example.com", assetCount: 0)
    #expect(bare.help == "https://img.example.com")
    // The jump bar and the window title.
    #expect(path(.keyPrefix("202409")) == ["Storage", "r2", "202409"])
    #expect(path(.backend("r2")) == ["Storage", "r2"])
    #expect(
      WindowTitle.compose(
        selection: .backend("r2"), projects: projects, currentProjectSlug: nil,
        backends: [DomainBackend(id: 1, slug: "r2", current: "https://img.example.com", bucket: "image-hosting")]
      ).title == "r2")
  }

  // MARK: - Item 2: the shortcut sections

  @Test("Shortcuts: Projects alone by default; each one comes and goes with the preference")
  func shortcutPresence() throws {
    #expect(LibraryShortcut.defaultShown == [.projects])
    #expect(PreferencesStore(defaults: try makeDefaults()).libraryShortcuts == [.projects])
    #expect(library(LibraryShortcut.defaultShown).map(\.id) == ["library", "catalog", "projects"])
    #expect(library([]).map(\.id) == ["library", "catalog"])
    #expect(library([.time]).map(\.id) == ["library", "catalog", "time"])
    #expect(library([.projects, .time]).map(\.id) == ["library", "catalog", "projects", "time"])
    #expect(library([.projects, .time]).map(\.title) == ["Library", "Storage", "Projects", "Time"])
    #expect(library([.projects, .time]).map(\.shortcut) == [nil, nil, .projects, .time])
    // Nothing in it: no section, not a bare header.
    #expect(library([.projects, .time], projects: [], months: []).map(\.id) == ["library", "catalog"])
  }

  @Test("Shortcut rows: the other tab's data, years only, no children, library: ids")
  func shortcutRows() throws {
    let sections = library([.projects, .time])
    let shortcutProjects = try #require(sections.first { $0.shortcut == .projects }).entries
    let tabProjects = try #require(
      SidebarModel.sections(
        navigator: .collections, projects: projects, tags: [], months: months, folderChildren: [:]
      ).first { $0.id == "projects" }).entries
    #expect(shortcutProjects.map(\.selection) == tabProjects.map(\.selection))
    #expect(shortcutProjects.map(\.label) == tabProjects.map(\.label))
    #expect(shortcutProjects.map(\.count) == tabProjects.map(\.count))
    #expect(shortcutProjects.map(\.systemImage) == tabProjects.map(\.systemImage))
    #expect(shortcutProjects.allSatisfy { $0.children.isEmpty && !$0.isExpandable })
    #expect(shortcutProjects.map(\.id) == ["library:project:blog", "library:project:notes"])

    let years = try #require(sections.first { $0.shortcut == .time }).entries
    #expect(years.map(\.selection) == [.year("2026"), .year("2025")])
    #expect(years.map(\.count) == [5, 1])
    #expect(years.allSatisfy { $0.children.isEmpty && !$0.isExpandable })
    #expect(years.map(\.id) == ["library:year:2026", "library:year:2025"])
    // The Time tab keeps its months.
    #expect(
      SidebarModel.sections(
        navigator: .time, projects: [], tags: [], months: months, folderChildren: [:]
      ).first?.entries.first?.children.count == 2)

    // Unique within the tab and apart from the other tabs' rows.
    let ids = sections.flatMap(\.entries).flatMap(\.flattened).map(\.id)
    #expect(Set(ids).count == ids.count)
    let others = [SidebarNavigator.time, .collections].flatMap {
      SidebarModel.sections(navigator: $0, projects: projects, tags: [], months: months, folderChildren: [:])
        .flatMap(\.entries).flatMap(\.flattened).map(\.id)
    }
    #expect(Set(ids).isDisjoint(with: others))
  }

  @Test("A shortcut row selects in place: the tab stays, its own tab shares the choice, the path reads as there")
  func shortcutSelection() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gallery = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-s1-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    #expect(gallery.libraryShortcuts == [.projects], "the model's default")
    gallery.navigator = .library
    gallery.sidebarSelection = .year("2026")
    #expect(gallery.navigator == .library)
    #expect(gallery.sidebarSelection == .year("2026"))
    #expect(gallery.navigatorSelections[.time] == .year("2026"))
    #expect(SidebarModel.navigator(for: .year("2026")) == .time, "still the row's own tab")
    #expect(GalleryModel.isMonthGroupable(.init(.library, .year("2026"))))
    gallery.sidebarSelection = .project("notes")
    #expect(gallery.navigator == .library)
    #expect(gallery.navigatorSelections[.collections] == .project("notes"))
    // A Library row writes its own slot only.
    gallery.sidebarSelection = .all
    #expect(gallery.navigatorSelections[.collections] == .project("notes"))

    #expect(path(.year("2026"), shortcuts: [.time]) == ["Time", "2026"])
    #expect(path(.project("blog")) == ["Projects", "Blog"])
    // Hidden since: still named as its own tab names it.
    #expect(path(.year("2026"), shortcuts: []) == ["Time", "2026"])
    #expect(
      WindowTitle.compose(selection: .year("2026"), projects: projects, currentProjectSlug: nil)
        .title == "2026")
  }

  // MARK: - Item 3: the header menu

  @Test("Header menu: Hide Section on a shortcut only; Show Section lists the hidden, disabled when none")
  func headerMenu() throws {
    let both = library([.projects, .time])
    let projectsHeader = try #require(both.first { $0.shortcut == .projects })
    let menu = SidebarModel.headerMenu(for: projectsHeader, shown: [.projects, .time])
    #expect(menu.hides == .projects)
    #expect(menu.showable.isEmpty)
    #expect(!menu.canShow)
    for id in ["library", "catalog"] {
      let header = try #require(both.first { $0.id == id })
      let fixed = SidebarModel.headerMenu(for: header, shown: [.projects])
      #expect(fixed.hides == nil, "\(id) cannot be hidden")
      #expect(fixed.showable == [.time])
      #expect(fixed.canShow)
    }
    let hiddenBoth = try #require(library([]).first)
    #expect(SidebarModel.headerMenu(for: hiddenBoth, shown: []).showable == [.projects, .time])
  }

  // MARK: - Items 2–4: one preference

  @Test("The header menu and Settings write one value, through the app's wiring, kept across a relaunch")
  func onePreference() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try makeDefaults()
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let preferences = app.preferences
    let gallery = try #require(app.gallery)
    #expect(gallery.libraryShortcuts == [.projects])
    await gallery.refreshProjects()
    gallery.navigator = .library
    #expect(gallery.sidebarSections.contains { $0.shortcut == .projects }, "Blog and Notes")

    // Show Section › Time in the header menu.
    gallery.setLibraryShortcut(.time, shown: true)
    #expect(preferences.libraryShortcuts == [.projects, .time])
    #expect(defaults.object(forKey: "pinax.sidebar.library.time") as? Bool == true)
    let pane = AppearanceSettingsPane(preferences: preferences)
    #expect(pane.libraryShortcutBinding(.time).wrappedValue)

    // Settings unticks Projects: the sidebar loses the section.
    pane.libraryShortcutBinding(.projects).wrappedValue = false
    #expect(gallery.libraryShortcuts == [.time])
    gallery.navigator = .library
    #expect(gallery.sidebarSections.allSatisfy { $0.shortcut != .projects })

    // Hide Section on Time: both gone, and a relaunch reads the same.
    gallery.setLibraryShortcut(.time, shown: false)
    #expect(preferences.libraryShortcuts.isEmpty)
    #expect(PreferencesStore(defaults: defaults).libraryShortcuts.isEmpty)
    gallery.setLibraryShortcut(.projects, shown: true)
    #expect(PreferencesStore(defaults: defaults).libraryShortcuts == [.projects])
  }
}
