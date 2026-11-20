import CatalogCore
@testable import PinaxUI
import Testing

/// The window title names the sidebar's leaf row for every selection. The
/// subtitle is the current project; the count's honesty rule is in
/// `GalleryStatusBarTests`.
@Suite struct WindowTitleTests {
  private let projects = [
    ProjectSummary(slug: "blog", name: "Blog", assetCount: 3, liveUsageCount: 1, lastScanAt: nil)
  ]
  private let tags = [TagSummary(name: "cover", assetCount: 2)]

  private func compose(
    _ selection: SidebarSelection, current: String? = nil
  ) -> WindowTitle {
    WindowTitle.compose(selection: selection, projects: projects, currentProjectSlug: current)
  }

  @Test("Every sidebar selection yields a non-empty title")
  func everySelectionHasATitle() {
    let selections: [SidebarSelection] = [
      .all, .recent, .orphans, .externals, .project("blog"), .project("gone"),
      .usage, .tag("cover"), .year("2026"), .month("2026-03"),
      .keyPrefix("blog/202603"),
    ]
    for selection in selections {
      #expect(!compose(selection).title.isEmpty, "\(selection)")
    }
    #expect(compose(.all).title == "All Assets")
    #expect(compose(.keyPrefix("blog/202603")).title == "202603")
    #expect(compose(.orphans).title == "Orphans")
    #expect(compose(.month("2026-03")).title == "March 2026")
    #expect(compose(.project("blog")).title == "Blog")
  }

  /// The title and the sidebar must not name one row two
  /// ways. `leafLabel` keeps a name table of its own, so every row of
  /// every navigator is walked — nested Catalog levels and months too
  /// (a month's title adds its year, the one sanctioned difference).
  @Test("The title is the sidebar row's own label, for every row of every navigator")
  func titleIsTheSidebarLabel() {
    let projects = [
      ProjectSummary(slug: "blog", name: "Blog", assetCount: 5, liveUsageCount: 3, lastScanAt: nil),
      ProjectSummary(slug: "shots", name: "Screenshots", assetCount: 2, liveUsageCount: 1, lastScanAt: nil),
    ]
    let labels = [LabelSummary(label: .red, assetCount: 2), LabelSummary(label: .blue, assetCount: 1)]
    let months: [(month: String, count: Int)] = [("2026-12", 2), ("2026-03", 1), ("2025-07", 4)]
    let folderChildren: KeyPrefixChildren = [
      .r2(nil): [("blog", 3, true), ("notes", 1, true)],
      .r2("blog"): [("202603", 2, true), ("202604", 1, true)],
    ]
    var checkedRows = 0
    for navigator in SidebarNavigator.allCases {
      let entries = SidebarModel.sections(
        navigator: navigator, projects: projects, tags: tags, months: months,
        folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labels
      ).flatMap(\.entries).flatMap(\.flattened)
      for entry in entries {
        checkedRows += 1
        let title = WindowTitle.compose(
          selection: entry.selection, projects: projects, currentProjectSlug: nil,
          backends: [DomainBackend(id: 1, slug: "r2", current: "https://img.example.com")]
        ).title
        // A month row sits under its year row and reads "March"; the
        // title has no parent to lean on, so it names the year too.
        let expected: String
        if case .month(let month) = entry.selection {
          expected = "\(entry.label) \(month.prefix(4))"
        } else {
          expected = entry.label
        }
        #expect(title == expected, "\(navigator.rawValue): \(entry.id)")
      }
    }
    // Same fixture as JumpBarTests' walk: 23 rows, the backend's root among them, Favorites and Archived
    // among the four library rows; Reports is Overview, Usage, Orphans,
    // Externals.
    #expect(checkedRows == 23)
  }

  /// The subtitle names the current project on every surface — asset and
  /// report alike — and is never empty.
  @Test("The subtitle is the current project's name, or All Projects")
  func subtitleIsTheCurrentProject() {
    for selection: SidebarSelection in [.all, .orphans, .externals, .usage, .tag("cover")] {
      #expect(compose(selection).subtitle == "All Projects", "\(selection)")
      #expect(compose(selection, current: "blog").subtitle == "Blog", "\(selection)")
    }
    // A slug whose name has not loaded yet shows the slug, not a blank.
    #expect(compose(.all, current: "notes").subtitle == "notes")
  }
}
