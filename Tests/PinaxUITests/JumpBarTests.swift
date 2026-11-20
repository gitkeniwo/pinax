import AppKit
import CatalogCore
import Foundation
import SwiftUI
import Testing
@testable import PinaxUI

/// The jump bar EQUALS the model — for a given selection
/// and selected asset the rendered path is exactly the expected one, and
/// what a segment offers to select is exactly what the sidebar offers, so
/// the two surfaces can never disagree. Asserting the correspondence, not
/// that a bar appeared.
@MainActor
@Suite struct JumpBarTests {
  private let projects = [
    ProjectSummary(
      slug: "blog", name: "Blog", assetCount: 5, liveUsageCount: 3, lastScanAt: nil),
    ProjectSummary(
      slug: "shots", name: "Screenshots", assetCount: 2, liveUsageCount: 1, lastScanAt: nil),
  ]
  private let tags = [TagSummary(name: "screenshots", assetCount: 4)]
  /// Two labels in use, so Collections ▸ Labels has rows to name.
  private let labelSummaries = [
    LabelSummary(label: .red, assetCount: 2), LabelSummary(label: .blue, assetCount: 1),
  ]
  private let months: [(month: String, count: Int)] = [
    ("2026-12", 2), ("2026-03", 1), ("2025-07", 4),
  ]

  /// The Catalog tree as far as it has been opened: the root and `blog`
  /// are loaded, `notes` and blog's two months have not been expanded yet
  /// and each has a level of its own under it.
  private let folderChildren: KeyPrefixChildren = [
    .r2(nil): [("blog", 3, true), ("notes", 1, true)],
    .r2("blog"): [("202603", 2, true), ("202604", 1, true)],
  ]

  /// The navigator each selection lives under — the model's own routing,
  /// which `SidebarModelTests` checks against every row of every tree.
  private func navigator(for selection: SidebarSelection) -> SidebarNavigator {
    SidebarModel.navigator(for: selection)
  }

  private func labels(
    _ selection: SidebarSelection, selectedName: String? = nil
  ) -> [String] {
    JumpBar.components(
      selection: selection, navigator: navigator(for: selection),
      projects: projects, tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries, selectedName: selectedName
    ).map(\.label)
  }

  @Test("The path is exactly the model's hierarchy, per selection")
  func pathMatchesTheSelection() {
    #expect(labels(.all) == ["Library", "All Assets"])
    #expect(labels(.recent) == ["Library", "Recent"])
    #expect(labels(.orphans) == ["Reports", "Orphans"])
    #expect(labels(.externals) == ["Reports", "Externals"])
    #expect(labels(.project("blog")) == ["Projects", "Blog"])
    #expect(labels(.usage) == ["Reports", "Usage"])
    #expect(labels(.tag("screenshots")) == ["Tags", "screenshots"])
    // A nested row names every level above it.
    let december = PinaxFormat.monthTitle("2026-12").month
    #expect(labels(.year("2026")) == ["Time", "2026"])
    #expect(labels(.month("2026-12")) == ["Time", "2026", december])

    // The trailing component is the selected asset — present when one is
    // selected, absent (not empty) when none is.
    #expect(labels(.project("blog"), selectedName: "IMG_3560.jpg")
      == ["Projects", "Blog", "IMG_3560.jpg"])
    #expect(labels(.all, selectedName: nil).count == 2)
  }

  /// A key prefix is one segment per level, each offering the rows
  /// the Catalog tree shows at that level — read from the same
  /// `folderChildren` the sidebar draws from.
  @Test("A key prefix names every level and offers each level's siblings")
  func keyPrefixPath() throws {
    #expect(labels(.keyPrefix("blog")) == ["Storage", "r2", "blog"])
    #expect(labels(.keyPrefix("blog/202603")) == ["Storage", "r2", "blog", "202603"])
    let path = JumpBar.components(
      selection: .keyPrefix("blog/202603"), navigator: .library, projects: projects,
      tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries, selectedName: nil)
    try #require(path.count == 4)
    #expect(path[0].destinations.isEmpty, "Catalog is the group header, not a menu")
    #expect(path[1].current == .backend("r2"), "the backend's root")
    #expect(path[2].destinations.map(\.selection) == [.keyPrefix("blog"), .keyPrefix("notes")])
    #expect(path[2].current == .keyPrefix("blog"))
    #expect(path[3].destinations.map(\.selection)
      == [.keyPrefix("blog/202603"), .keyPrefix("blog/202604")])
    // Orphans and Externals are Reports rows and are named the same there.
    #expect(navigator(for: .orphans) == .reports)
    #expect(labels(.externals) == ["Reports", "Externals"])
    // A prefix whose levels have not loaded still states where it is.
    #expect(labels(.keyPrefix("photos/2019")) == ["Storage", "2019"])
  }

  @Test("The sidebar's own display name wins over the raw slug")
  func sidebarLabelIsTheSingleSource() {
    // "Blog" (the project's name) not "blog" (its slug) — the label comes
    // from SidebarModel.sections, the same list the sidebar renders.
    #expect(labels(.project("blog")).last == "Blog")
    // A project the summaries have not (yet) loaded still shows its slug:
    // the bar states where it is, never nothing.
    #expect(labels(.project("unknown")) == ["Projects", "unknown"])
  }

  @Test("A segment offers exactly what the sidebar offers at that level")
  func destinationsMatchTheSidebarEntries() {
    func section(_ navigator: SidebarNavigator, _ id: String) -> [SidebarSelection] {
      SidebarModel.sections(navigator: navigator, projects: projects, tags: tags, months: months,
        folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries)
        .first { $0.id == id }?.entries.map(\.selection) ?? []
    }

    func destinations(_ selection: SidebarSelection) -> [SidebarSelection] {
      let components = JumpBar.components(
        selection: selection, navigator: navigator(for: selection),
        projects: projects, tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries, selectedName: nil)
      // The leaf is the pickable segment; the group header is inert by
      // design (no destinations to offer — no false affordance).
      return components.last(where: { !$0.destinations.isEmpty })?.destinations
        .map(\.selection) ?? []
    }

    #expect(destinations(.all) == section(.library, "library"))
    #expect(destinations(.project("blog")) == section(.collections, "projects"))
    #expect(destinations(.usage) == section(.reports, "reports"))
    #expect(destinations(.tag("screenshots")) == section(.collections, "tags"))
    #expect(destinations(.year("2025")) == section(.time, "time"))
    // A month offers its own year's months, not every month.
    #expect(destinations(.month("2026-03")) == [.month("2026-12"), .month("2026-03")])
    let monthPath = JumpBar.components(
      selection: .month("2026-03"), navigator: .time, projects: projects, tags: tags,
      months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries, selectedName: nil)
    #expect(monthPath[1].destinations.map(\.selection) == section(.time, "time"))
    #expect(monthPath[1].current == .year("2026"), "the year segment selects its year")

    // The inert segments really are inert.
    let projectComponents = JumpBar.components(
      selection: .project("blog"), navigator: .collections, projects: projects, tags: tags,
      months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries, selectedName: "x.png")
    #expect(projectComponents[0].destinations.isEmpty, "the group header offers no menu")
    #expect(projectComponents[2].destinations.isEmpty, "the selected asset offers no menu")
  }

  /// Both surfaces resolve the symbol through the same
  /// SidebarEntry. Equality is asserted per destination, not inferred from
  /// similar rendering.
  @Test("Sidebar and jump bar use the same symbol for every selection")
  func symbolsShareTheSidebarResolver() throws {
    // Across every row of every navigator, the bar resolves the same entry
    // — same label, same symbol, same row identity — so the two surfaces
    // cannot name one destination two ways. Every row is checked by name,
    // not by path shape. Nested rows are walked too: a month is a row the
    // sidebar draws, so it must be named the same way.
    var checkedRows = 0
    for navigator in SidebarNavigator.allCases {
      let entries = SidebarModel.sections(
        navigator: navigator, projects: projects, tags: tags, months: months,
        folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries
      ).flatMap(\.entries).flatMap(\.flattened)
      for sidebarEntry in entries {
        let components = JumpBar.components(
          selection: sidebarEntry.selection, navigator: navigator,
          projects: projects, tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries, selectedName: nil)
        checkedRows += 1
        let component = try #require(
          components.first { $0.current == sidebarEntry.selection },
          "\(navigator.rawValue): \(sidebarEntry.id) has no jump-bar segment")
        #expect(component.entry?.systemImage == sidebarEntry.systemImage)
        #expect(component.label == sidebarEntry.label)
        #expect(component.entry?.id == sidebarEntry.id)
      }
    }
    // 4 library rows + the backend's root + 4 Catalog prefixes + 2 years
    // + 3 months + 2 projects + 1 tag + 2 labels + 4 report rows (Usage and
    // Overview among them). The prefixes are checked by name like every
    // other row, the Catalog tree's nested levels included.
    #expect(checkedRows == 23)
  }

  /// The path is the row's ancestor chain in
  /// the sidebar — group header › … › row — for every row of every
  /// navigator. No segment the sidebar does not draw above the row: the
  /// old hard-coded "Catalog" root made All Assets read as a child of the
  /// Catalog group once that group existed.
  @Test("The path is the sidebar row's ancestor chain, group header first")
  func pathIsTheSidebarAncestorChain() {
    func walk(
      _ entries: [SidebarEntry], above: [String],
      _ visit: (SidebarEntry, [String]) -> Void
    ) {
      for entry in entries {
        let chain = above + [entry.label]
        visit(entry, chain)
        walk(entry.children, above: chain, visit)
      }
    }
    var checkedRows = 0
    for navigator in SidebarNavigator.allCases {
      let sections = SidebarModel.sections(
        navigator: navigator, projects: projects, tags: tags, months: months,
        folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries)
      for section in sections {
        walk(section.entries, above: [section.title]) { entry, chain in
          checkedRows += 1
          let path = JumpBar.components(
            selection: entry.selection, navigator: navigator,
            projects: projects, tags: tags, months: months, folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries,
            selectedName: nil
          ).map(\.label)
          #expect(path == chain, "\(entry.id)")
        }
      }
    }
    #expect(checkedRows == 23)
  }

  @Test("Selecting through a segment is the same write the sidebar makes")
  func selectingThroughTheBarReachesTheModel() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", projectSlug: "notes")
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-jumpbar-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()

    // The view's menu button body performs exactly this write — the same
    // published property the sidebar's List binding writes, so there is no
    // second path to keep in agreement.
    model.select(.project("notes"), in: .collections)
    await model.reload()
    #expect(model.sidebarSelection == .project("notes"))
    #expect(
      JumpBar.components(
        selection: model.sidebarSelection, navigator: model.navigator,
        projects: model.projects, tags: model.tags, months: model.availableMonths,
        folderChildren: model.folderChildren, catalogRoots: model.domainBackends.map(CatalogRoot.init), selectedName: nil
      ).map(\.label) == ["Projects", "Notes"],
      "the bar follows the model's own project summaries after the switch")
  }

  @Test("The jump bar's controls are the same everywhere, grayed in place off the asset grid")
  func controlsAreConstantAndGrayInPlace() {
    var checkedRows = 0
    for navigator in SidebarNavigator.allCases {
      let sections = SidebarModel.sections(
        navigator: navigator, projects: projects, tags: tags, months: months,
        folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], labels: labelSummaries)
      var entries = sections.flatMap(\.entries)
      while let entry = entries.popLast() {
        entries += entry.children
        for viewMode in [GalleryModel.ViewMode.grid, .table] {
          for (back, forward) in [(false, false), (true, false), (false, true)] {
          for sort in [AssetSort(), AssetSort(field: .name, direction: .ascending)] {
            checkedRows += 1
            let controls = JumpBar.controls(
              selection: entry.selection, navigator: navigator, viewMode: viewMode, sort: sort,
              canGoBack: back, canGoForward: forward)
            #expect(controls.leading.map(\.control) == [.back, .forward], "\(entry.id)")
            #expect(controls.leading.map(\.isEnabled) == [back, forward], "\(entry.id)")
            // Externals sorts its own rows, and
            // the month switch's place is its Group by File.
            if entry.selection == .externals {
              #expect(controls.trailing.map(\.control) == [.sort, .displayOptions, .groupByFile])
              #expect(controls.trailing.map(\.isEnabled) == [true, false, true])
              continue
            }
            #expect(
              controls.trailing.map(\.control) == [.sort, .displayOptions, .groupByMonth],
              "\(entry.id)")
            let isReport: Bool
            switch entry.selection {
            case .overview, .orphans, .externals, .usage: isReport = true
            default: isReport = false
            }
            // Usage's images are the library's grid, its display
            // options with it.
            let gridOptions = (!isReport || entry.selection == .usage) && viewMode == .grid
            // The month switch also needs upload-date order. The table has
            // month sections too, so the switch does not gray in table
            // mode — only on reports and off upload date.
            let byDate = sort.field == .uploadedAt
            // And only where months group at all.
            let groupable = !isReport
              && GalleryModel.isMonthGroupable(NavigationHistory.Place(navigator, entry.selection))
            #expect(
              controls.trailing.map(\.isEnabled)
                == [!isReport, gridOptions, groupable && byDate],
              "\(entry.id) \(viewMode) \(sort.field)")
            #expect(
              controls.trailing.last?.help
                == (!groupable
                  ? JumpBar.groupByMonthElsewhereHelp
                  : byDate ? JumpBar.groupByMonthHelp : JumpBar.groupByMonthNeedsDateHelp))
          }
          }
        }
      }
    }
    #expect(checkedRows == 23 * 2 * 3 * 2)
  }

  /// The pure `controls(...)` list above cannot see the view drop or hide
  /// one of them; this reads the controls the hosted bar actually drew, in
  /// every navigator and both view modes. SwiftUI
  /// backs each with an AppKit button but carries neither `.help` nor an
  /// accessibility identifier down to it (measured), so a control is found
  /// by what sets it apart from a path segment: an icon-only button, empty
  /// title — every segment menu is titled with its label.
  @Test("The rendered jump bar draws every control, in place, in every navigator and view mode")
  func renderedControlsAreConstantAndGrayInPlace() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "blog")
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-jumpbar-c-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()

    let host = NSHostingView(rootView: JumpBar(model: model).frame(width: 700))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: ChromeMetrics.stripHeight),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }

    // Back, forward: buttons; sort and display options: pop-up menus;
    // month grouping: a button-style toggle.
    let kinds = ["button", "button", "menu", "menu", "button"]
    var positions: Set<[CGFloat]> = []
    let selections: [SidebarSelection] = [.all, .month("2026-08"), .project("blog"), .orphans]
    #expect(Set(selections.map(navigator(for:))) == Set(SidebarNavigator.allCases))
    for selection in selections {
      for viewMode in [GalleryModel.ViewMode.grid, .table] {
        model.select(selection, in: navigator(for: selection))
        // The bar draws the place a reload has shown;
        // in the app GalleryView's reload task runs this.
        await model.reload()
        model.viewMode = viewMode
        await spin(0.3)

        var drawn: [(kind: String, minX: CGFloat, isEnabled: Bool)] = []
        var stack: [NSView] = [host]
        while let view = stack.popLast() {
          stack.append(contentsOf: view.subviews)
          guard let button = view as? NSButton, button.title.isEmpty,
            !button.isHiddenOrHasHiddenAncestor, button.alphaValue > 0,
            button.bounds.width > 0, button.bounds.height > 0
          else { continue }
          drawn.append((
            button is NSPopUpButton ? "menu" : "button",
            button.convert(button.bounds, to: nil).minX, button.isEnabled))
        }
        drawn.sort { $0.minX < $1.minX }

        let expected = JumpBar.controls(
          selection: selection, navigator: model.shownPlace.navigator, viewMode: viewMode, sort: model.sort,
          canGoBack: model.canGoBack, canGoForward: model.canGoForward)
        #expect(drawn.map(\.kind) == kinds, "\(selection) \(viewMode)")
        #expect(
          drawn.map(\.isEnabled) == (expected.leading + expected.trailing).map(\.isEnabled),
          "\(selection) \(viewMode)")
        positions.insert(drawn.map(\.minX))
      }
    }
    // Grayed in place: the same x for every control in all eight states.
    #expect(positions.count == 1, "\(positions)")
  }

  @Test("Every jump bar control symbol exists")
  func controlSymbolsExist() {
    for control in JumpBar.Control.allCases {
      #expect(
        NSImage(systemSymbolName: control.systemImage, accessibilityDescription: nil) != nil,
        "\(control.systemImage)")
    }
  }

  @Test("The jump bar's height is invariant across selections")
  func heightIsInvariantAcrossSelections() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "blog")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", projectSlug: "notes")
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-jumpbar-h-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()

    func renderedHeight(_ selection: SidebarSelection) -> Int? {
      model.select(selection, in: navigator(for: selection))
      let renderer = ImageRenderer(content: JumpBar(model: model).frame(width: 700))
      renderer.proposedSize = ProposedViewSize(width: 700, height: nil)
      return renderer.cgImage?.height
    }

    // The widest path (project) and the shortest (library leaf) must
    // render at the same height: the bar, like the strip and the status
    // bar, may not reflow the content below it.
    let heights = [
      renderedHeight(.all),
      renderedHeight(.project("blog")),
      renderedHeight(.tag("nonexistent")),
    ]
    let expected = Int(ChromeMetrics.stripHeight)
    #expect(heights.allSatisfy { $0 == expected }, "heights: \(heights.map { $0 ?? -1 })")
    #expect(heights.compactMap { $0 }.count == heights.count, "every state produced a bitmap")
  }

  /// Under any order but upload date the month switch the app's
  /// jump bar draws is grayed, and its stored value stays as it was — so
  /// back in upload-date order it is clickable and groups again. The
  /// switch starts ON (stored explicitly), so "unchanged" cannot be the
  /// default value by accident.
  @Test("Group by Month grays out off upload-date order and keeps its stored value")
  func monthSwitchFollowsTheSort() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-07-01T00:00:00Z")
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-jumpbar-s19b-\(UUID().uuidString)"))
    defaults.set(true, forKey: "pinax.grid.groupsByMonth")
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    await gallery.loadInitialData()
    #expect(gallery.groupsByMonth && gallery.groupsRowsByMonth)

    let host = NSHostingView(rootView: JumpBar(model: gallery).frame(width: 700))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: ChromeMetrics.stripHeight),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }

    /// The drawn month switch: the rightmost icon-only plain button.
    func monthSwitch() throws -> NSButton {
      var found: [NSButton] = []
      var stack: [NSView] = [host]
      while let view = stack.popLast() {
        stack.append(contentsOf: view.subviews)
        if let button = view as? NSButton, !(button is NSPopUpButton), button.title.isEmpty,
          !button.isHiddenOrHasHiddenAncestor, button.bounds.width > 0
        {
          found.append(button)
        }
      }
      return try #require(found.max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
    }
    func stored() -> Bool? { defaults.object(forKey: "pinax.grid.groupsByMonth") as? Bool }

    await spin(0.3)
    #expect(try monthSwitch().isEnabled, "upload-date order: clickable")

    // View ▸ Sort By, then the jump bar's own sort menu: grayed, value kept.
    PinaxCommands(app: app).sortItems.sort = AssetSort(field: .name, direction: .ascending)
    await spin(0.3)
    #expect(try !monthSwitch().isEnabled, "name order: grayed")
    #expect(gallery.groupsByMonth && app.preferences.gridGroupsByMonth && stored() == true)
    #expect(!gallery.groupsRowsByMonth)

    JumpBar(model: gallery).sortItems.sort = AssetSort(field: .byteSize, direction: .descending)
    await spin(0.3)
    #expect(try !monthSwitch().isEnabled, "size order: grayed")
    #expect(gallery.groupsByMonth && stored() == true)

    // Back to upload date: clickable, and the kept value groups again.
    JumpBar(model: gallery).sortItems.sort = AssetSort(field: .uploadedAt, direction: .ascending)
    await spin(0.3)
    #expect(try monthSwitch().isEnabled, "upload-date order again: clickable")
    #expect(gallery.groupsRowsByMonth && stored() == true)
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
}
