import AppKit
import CatalogCore
import Foundation
import PinaxUI
import Testing

/// The sidebar model. The property that matters: a project row and its
/// usage row are **distinct identities** — not "clicking works". The tag names here
/// deliberately collide with project slugs ("blog"), the nastiest case the
/// old per-section `id: \.slug` could produce.
@MainActor
@Suite struct SidebarModelTests {
  private let projects = [
    ProjectSummary(
      slug: "blog", name: "Blog", assetCount: 5, liveUsageCount: 4,
      lastScanAt: "2026-08-20T13:00:00Z"),
    ProjectSummary(
      slug: "notes", name: "Notes", assetCount: 3, liveUsageCount: 0, lastScanAt: nil),
  ]
  private let tags = [
    TagSummary(name: "hero", assetCount: 2),
    TagSummary(name: "blog", assetCount: 1),
  ]
  /// `availableMonths`' shape: `yyyy-MM`, newest first.
  private let months: [(month: String, count: Int)] = [
    ("2026-08", 3), ("2026-03", 2), ("2025-12", 1),
  ]

  /// The Catalog tree as far as it has been opened: the root and `blog`
  /// are loaded, `notes` and blog's two months have not been expanded yet
  /// and each has a level of its own under it.
  private let folderChildren: KeyPrefixChildren = [
    .r2(nil): [("blog", 3, true), ("notes", 1, true)],
    .r2("blog"): [("202603", 2, true), ("202604", 1, true)],
  ]

  /// Every row of every navigator: the four trees together are what must
  /// stay identity-unique now that one selection can appear in two of them.
  private var allEntries: [SidebarEntry] {
    SidebarNavigator.allCases.flatMap {
      SidebarModel.sections(navigator: $0, projects: projects, tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root])
        .flatMap(\.entries).flatMap(\.flattened)
    }
  }

  private func entries(_ navigator: SidebarNavigator) -> [SidebarEntry] {
    SidebarModel.sections(navigator: navigator, projects: projects, tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root])
      .flatMap(\.entries).flatMap(\.flattened)
  }

  private func sectionIDs(_ navigator: SidebarNavigator) -> [String] {
    SidebarModel.sections(navigator: navigator, projects: projects, tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root])
      .map(\.id)
  }

  // MARK: - The Catalog tree and the Reports rows

  @Test("Library is All Assets, Recent and the loaded Catalog tree; unopened prefixes stay expandable")
  func catalogTreeShape() throws {
    let sections = SidebarModel.sections(
      navigator: .library, projects: projects, tags: tags, months: months,
      folderChildren: folderChildren, catalogRoots: [FixtureBackend.root])
    #expect(sections.map(\.id) == ["library", "catalog"])
    #expect(sections.map(\.title) == ["Library", "Storage"])
    // The native-selection test reads outline rows 1 and 2: the Library
    // group keeps them first; Favorites and Archived come after.
    #expect(sections[0].entries.map(\.selection) == [.all, .recent, .favorites, .archived])

    // The backend's root, its folders under it.
    let root = try #require(sections[1].entries.first)
    #expect(sections[1].entries.map(\.selection) == [.backend("r2")])
    #expect(root.label == "r2", "the backend's slug, not its host")
    let catalog = root.children
    #expect(catalog.map(\.selection) == [.keyPrefix("blog"), .keyPrefix("notes")])
    #expect(catalog.map(\.label) == ["blog", "notes"])
    #expect(catalog.map(\.count) == [3, 1])
    let blog = try #require(catalog.first)
    #expect(blog.children.map(\.selection) == [.keyPrefix("blog/202603"), .keyPrefix("blog/202604")])
    #expect(blog.children.map(\.label) == ["202603", "202604"], "a row is its segment name")
    #expect(blog.children.map(\.count) == [2, 1])
    #expect(!blog.expandsLazily && blog.isExpandable)
    // Not opened yet: expandable, nothing under them until they load.
    #expect(blog.children.allSatisfy { $0.expandsLazily && $0.children.isEmpty })
    #expect(catalog[1].expandsLazily)
    #expect(blog.children[0].id == "library:prefix:r2:blog/202603")

    // Opened and found to hold only files: a plain leaf.
    var opened = folderChildren
    opened[.r2("notes")] = []
    let notes = SidebarModel.sections(
      navigator: .library, projects: projects, tags: tags, months: months,
      folderChildren: opened, catalogRoots: [FixtureBackend.root])[1].entries[0].children[1]
    #expect(!notes.isExpandable)

    // No backend (an empty catalog): no bare "Catalog" header.
    #expect(SidebarModel.sections(
      navigator: .library, projects: projects, tags: tags, months: months,
      folderChildren: [:]).map(\.id) == ["library"])
  }

  /// Every row routes back to the
  /// navigator that draws it, so a writer that routes through
  /// `SidebarModel.navigator(for:)` — the Library menu's ⌥⌘1–⌥⌘4 — can only
  /// land a selection in a tree that has its row. Orphans and Externals are
  /// Reports rows only.
  @Test("Every row of every tree routes back to its own navigator")
  func everyRowRoutesToItsNavigator() {
    for navigator in SidebarNavigator.allCases {
      for entry in entries(navigator) {
        #expect(SidebarModel.navigator(for: entry.selection) == navigator, "\(entry.id)")
      }
    }
    let library = entries(.library).map(\.selection)
    #expect(!library.contains(.orphans) && !library.contains(.externals))
    let reports = entries(.reports).map(\.selection)
    #expect(reports.contains(.orphans) && reports.contains(.externals))
  }

  /// A project row in Collections counts its assets; the
  /// live-usage number belongs to the Usage row in Reports; the report rows
  /// carry no count (no report query runs for the sidebar).
  @Test("Project rows count assets, usage rows count live references, report rows count nothing")
  func countColumns() {
    let collections = entries(.collections).filter {
      if case .project = $0.selection { return true } else { return false }
    }
    #expect(collections.map(\.count) == [5, 3])
    #expect(collections.allSatisfy { $0.countHelp == "Assets in this project" })
    let reports = entries(.reports)
    // Usage is one leaf over the current project, no per-project rows and
    // no counts. Overview comes first.
    #expect(reports.map(\.selection) == [.overview, .usage, .orphans, .externals])
    #expect(reports.allSatisfy { $0.count == nil })
  }

  @Test("Row identities are unique across the entire list")
  func rowIdentitiesUnique() {
    let ids = allEntries.map(\.id)
    #expect(Set(ids).count == ids.count)
    // library: All Assets, Recent, Favorites, Archived + the backend's
    // root + 4 Catalog prefixes (blog, its two months, notes). time: 2 years + 3 months.
    // collections: 2 projects + 2 tags. reports: Overview, Usage, Orphans,
    // Externals.
    #expect(ids.count == 22)
    #expect(entries(.library).count == 9)
    #expect(entries(.time).count == 5)
    #expect(entries(.collections).count == 4)
    #expect(entries(.reports).count == 4)
  }

  @Test("A project row and its usage row are distinct identities")
  func projectAndUsageDistinct() throws {
    let entries = allEntries
    let project = try #require(entries.first { $0.selection == .project("blog") })
    let usage = try #require(entries.first { $0.selection == .usage })
    #expect(project.id == "collections:project:blog")
    #expect(usage.id == "reports:library:usage")
    #expect(project.id != usage.id)
    #expect(project.selection != usage.selection)
  }

  @Test("A tag named like a project stays distinct from it")
  func tagVersusProjectDistinct() {
    let tagID = SidebarModel.rowID(for: .tag("blog"), in: .collections)
    #expect(tagID != SidebarModel.rowID(for: .project("blog"), in: .collections))
    #expect(tagID != SidebarModel.rowID(for: .usage, in: .reports))
  }

  /// The same selection under two navigators is two row identities. No
  /// selection appears in two trees today, so the property is pinned on
  /// the id function itself.
  @Test("The same selection under two navigators is two row identities")
  func sameSelectionAcrossNavigatorsIsDistinct() throws {
    let inReports = try #require(entries(.reports).first { $0.selection == .orphans })
    #expect(inReports.id == "reports:library:orphans")
    #expect(SidebarModel.rowID(for: .orphans, in: .library) == "library:library:orphans")
    #expect(SidebarModel.rowID(for: .all, in: .library) != SidebarModel.rowID(for: .all, in: .time))
  }

  @Test("Every row id is derived from its own selection")
  func idDerivedFromSelection() {
    #expect(
      allEntries.allSatisfy {
        $0.id == SidebarModel.rowID(for: $0.selection, in: $0.navigator)
      })
    // And the mapping is injective across the interesting cases.
    let selections: [GalleryModel.SidebarSelection] = [
      .all, .recent, .orphans, .externals, .project("blog"), .usage, .tag("blog"),
      .project("notes"), .tag("hero"), .year("2026"), .month("2026-03"), .tag("2026"),
    ]
    let ids = selections.map { SidebarModel.rowID(for: $0, in: .collections) }
    #expect(Set(ids).count == ids.count)
  }

  @Test("Sections keep their order and every row carries its label and icon")
  func sectionShape() {
    #expect(sectionIDs(.library) == ["library", "catalog"])
    #expect(sectionIDs(.time) == ["time"])
    #expect(sectionIDs(.collections) == ["projects", "tags"])
    #expect(sectionIDs(.reports) == ["reports"])
    // No months, no time section — not a header over nothing.
    #expect(
      SidebarModel.sections(navigator: .time, projects: projects, tags: tags, months: [], folderChildren: folderChildren, catalogRoots: [FixtureBackend.root]).isEmpty)
    // The native-selection test reads outline rows 1 and 2 by index: the library tree's
    // first two rows under its header must stay All Assets and Recent.
    #expect(
      entries(.library).map(\.label) == [
        "All Assets", "Recent", "Favorites", "Archived", "r2", "blog", "202603", "202604", "notes",
      ])
    #expect(
      allEntries.allSatisfy { !$0.label.isEmpty && !$0.systemImage.isEmpty })
  }

  /// Years newest first, each holding its months newest
  /// first; a year's count is the sum of its months'. The month label is
  /// `PinaxFormat.monthTitle`'s month, compared through the same function so
  /// the test does not depend on the machine's locale.
  @Test("The time tree is year over month, and a year counts its months")
  func timeTreeShape() throws {
    let years = try #require(
      SidebarModel.sections(navigator: .time, projects: projects, tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root])
        .first
    ).entries
    #expect(years.map(\.selection) == [.year("2026"), .year("2025")])
    #expect(years.map(\.label) == ["2026", "2025"])
    #expect(years.map(\.count) == [5, 1])
    #expect(years[0].children.map(\.selection) == [.month("2026-08"), .month("2026-03")])
    #expect(
      years[0].children.map(\.label)
        == [PinaxFormat.monthTitle("2026-08").month, PinaxFormat.monthTitle("2026-03").month])
    #expect(years[0].children.map(\.count) == [3, 2])
    #expect(years[1].children.map(\.selection) == [.month("2025-12")])
    #expect(years.allSatisfy { $0.navigator == .time })
    #expect(years.flatMap(\.children).allSatisfy { $0.children.isEmpty && $0.navigator == .time })
  }

  /// Every resolved symbol is a real SF Symbol on the supported
  /// runtime. A guessed `.fill` spelling fails here instead of disappearing.
  @Test("Every filled sidebar symbol exists")
  func filledSymbolsExist() {
    for entry in allEntries {
      #expect(
        NSImage(
          systemSymbolName: entry.systemImage,
          accessibilityDescription: entry.label) != nil,
        "Missing SF Symbol: \(entry.systemImage)")
    }
  }
}
