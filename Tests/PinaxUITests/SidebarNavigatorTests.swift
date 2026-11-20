import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// The sidebar's navigators. The properties, not the outcomes:
///
/// 1. Switching navigator does not change the gallery's reload token unless
///    the projected selection really changed — going away and coming back
///    reloads nothing extra.
/// 2. The four navigators' selections are four independent slots.
/// 3. The jump bar and the sidebar name the same destination identically,
///    in every navigator (asserted in `JumpBarTests` against the row tree
///    itself; here at the model level, through the projection).
/// 9. The switcher hand-draws no chrome.
@MainActor
@Suite struct SidebarNavigatorTests {
  private let projects = [
    ProjectSummary(
      slug: "blog", name: "Blog", assetCount: 5, liveUsageCount: 3, lastScanAt: nil)
  ]
  private let tags = [TagSummary(name: "hero", assetCount: 2)]

  private func makeModel(uploadedAt stamps: [String] = []) throws -> (GalleryModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    for (index, stamp) in stamps.enumerated() {
      try seedAsset(database, index: index, uploadedAt: stamp)
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-navigator-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    return (model, directory)
  }

  // MARK: - 1. Switching reloads nothing extra

  /// The instrument is the gallery's own reload token — the value
  /// `.task(id:)` restarts on. Counting `page` calls through a fake catalog
  /// would need a protocol seam `ReadOnlyCatalog` does not have (it is a
  /// concrete class); the token is the thing that decides whether a reload
  /// happens at all, so it is the more direct measurement, not a weaker one.
  @Test("Switching navigator and back changes the reload token exactly once per real move")
  func navigatorSwitchDoesNotReloadTwice() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let view = GalleryView(model: model)

    model.select(.recent, in: .library)
    let atRecent = view.reloadToken

    // Away: the reports navigator's slot holds .orphans, a different
    // selection.
    model.navigator = .reports
    let atReports = view.reloadToken
    #expect(atReports != atRecent)

    // Back: the library slot still holds .recent, so the token is the one
    // it was — the round trip is one reload out and one back, never three.
    model.navigator = .library
    #expect(view.reloadToken == atRecent)
    #expect(model.sidebarSelection == .recent)

    // And a switch between two navigators whose slots agree is not a
    // reload at all: before the first load resolves them, library, time
    // and collections all hold .all.
    model.sidebarSelection = .all
    let atAll = view.reloadToken
    model.navigator = .time
    #expect(view.reloadToken == atAll)
    model.navigator = .collections
    #expect(view.reloadToken == atAll)
  }

  @Test("The navigator itself is not a query input")
  func navigatorIsNotAQueryInput() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    let query = model.makeQuery()
    for navigator in SidebarNavigator.allCases {
      model.select(.all, in: navigator)
      let switched = model.makeQuery()
      #expect(switched.project == query.project)
      #expect(switched.tag == query.tag)
      #expect(switched.since == query.since)
      #expect(switched.until == query.until)
    }
  }

  // MARK: - 2. Independent slots

  @Test("Each navigator keeps its own selection")
  func everyNavigatorRemembersItsOwnSelection() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    let chosen: [SidebarNavigator: SidebarSelection] = [
      .library: .recent, .time: .all, .collections: .tag("hero"), .reports: .usage,
    ]
    for (navigator, selection) in chosen {
      model.select(selection, in: navigator)
    }
    // Written one at a time, they must all still be there: four slots, no
    // overwriting, in any visiting order.
    for (navigator, selection) in chosen {
      model.navigator = navigator
      #expect(model.sidebarSelection == selection, "\(navigator.rawValue)")
      #expect(model.navigatorSelections[navigator] == selection)
    }
    #expect(model.navigatorSelections.count == SidebarNavigator.allCases.count)
  }

  @Test("The defaults are one per navigator")
  func defaultsCoverEveryNavigator() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(model.navigator == .library)
    #expect(model.navigatorSelections[.library] == .all)
    #expect(model.navigatorSelections[.time] == .all)
    #expect(model.navigatorSelections[.collections] == .all)
    #expect(model.navigatorSelections[.reports] == .overview)
    // With project summaries in hand, collections starts on the first one;
    // with months, time starts on the newest year.
    #expect(
      GalleryModel.defaultNavigatorSelections(projects: projects)[.collections]
        == .project("blog"))
    #expect(
      GalleryModel.defaultNavigatorSelections(months: [("2025-12", 2), ("2026-03", 1)])[.time]
        == .year("2026"))
  }

  /// The selection a navigator holds is always a row that navigator has —
  /// the reason `select(_:in:)` exists rather than a bare write. No
  /// exception: Time's tree is years and months only,
  /// so its default is the newest year, not `.all`.
  @Test("Every navigator's default selects one of its own rows")
  func defaultsSelectRowsThatExist() {
    let months = [("2026-03", 1), ("2025-12", 1)]
    let defaults = GalleryModel.defaultNavigatorSelections(projects: projects, months: months)
    for navigator in SidebarNavigator.allCases {
      let selections = SidebarModel.sections(
        navigator: navigator, projects: projects, tags: tags,
        months: months, folderChildren: [.r2(nil): [("blog", 1, false)]], catalogRoots: [FixtureBackend.root]
      ).flatMap(\.entries).flatMap(\.flattened).map(\.selection)
      #expect(selections.contains(defaults[navigator]!), "\(navigator.rawValue)")
    }
  }

  /// The test above checks the overload
  /// that takes projects and months, which the running app never calls —
  /// at init neither has loaded, and collections and time start at `.all`,
  /// a selection with no row in either tree. This is the app's own path: a
  /// model, `loadInitialData`, then every slot is a row of its own tree.
  @Test("After the first load every navigator's selection is one of its own rows")
  func loadedSelectionsAreRows() async throws {
    let stamps = ["2025-12-01T00:00:00Z", "2026-03-01T00:00:00Z"]
    let (model, directory) = try makeModel(uploadedAt: stamps)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.navigatorSelections[.collections] == .all, "the placeholder before any load")
    #expect(model.navigatorSelections[.time] == .all, "the placeholder before any load")
    await model.loadInitialData()

    #expect(model.navigatorSelections[.collections] == .project("blog"))
    #expect(model.navigatorSelections[.time] == .year("2026"), "the newest year")
    for navigator in SidebarNavigator.allCases {
      let rows = SidebarModel.sections(
        navigator: navigator, projects: model.projects, tags: model.tags,
        months: model.availableMonths, folderChildren: model.folderChildren, catalogRoots: model.domainBackends.map(CatalogRoot.init)
      ).flatMap(\.entries).flatMap(\.flattened).map(\.selection)
      #expect(rows.contains(model.navigatorSelections[navigator]!), "\(navigator.rawValue)")
    }

    // A choice made before the summaries arrived is the user's: kept.
    let (chosen, chosenDirectory) = try makeModel(uploadedAt: stamps)
    defer { try? FileManager.default.removeItem(at: chosenDirectory) }
    chosen.navigatorSelections[.collections] = .project("notes")
    chosen.navigatorSelections[.time] = .month("2025-12")
    await chosen.loadInitialData()
    #expect(chosen.navigatorSelections[.collections] == .project("notes"))
    #expect(chosen.navigatorSelections[.time] == .month("2025-12"))

    // Launched onto Time: the year arrives through the projection, so the
    // grid is on it too.
    let (onTime, onTimeDirectory) = try makeModel(uploadedAt: stamps)
    defer { try? FileManager.default.removeItem(at: onTimeDirectory) }
    onTime.navigator = .time
    await onTime.loadInitialData()
    #expect(onTime.sidebarSelection == .year("2026"))
  }

  // MARK: - The switcher's four symbols

  @Test("Every navigator symbol exists and every navigator is named")
  func navigatorSymbolsExist() {
    #expect(
      SidebarNavigator.allCases.map(\.rawValue)
        == ["library", "time", "collections", "reports"])
    #expect(
      SidebarNavigator.allCases.map(\.title)
        == ["Library", "Time", "Projects and Tags", "Reports"])
    for navigator in SidebarNavigator.allCases {
      #expect(
        NSImage(systemSymbolName: navigator.systemImage, accessibilityDescription: navigator.title)
          != nil,
        "Missing SF Symbol: \(navigator.systemImage)")
    }
  }

  // MARK: - 9. The switcher draws no chrome of its own

  /// This property is a grep, so it is run as one — over the source file
  /// itself, not over a rendering. The rule it enforces: the two rules above and below the icon row are system
  /// `Divider()`s, and the selected state is a colour, never a plate, a
  /// capsule or an underline drawn by hand.
  @Test("The navigator switcher hand-draws no chrome")
  func switcherDrawsNoChrome() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PinaxUITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the package root
        .appendingPathComponent("Sources/PinaxUI/Sidebar/SidebarNavigatorPicker.swift"),
      encoding: .utf8)
    // Code only: the file's own doc comment names `Divider()` and would
    // otherwise satisfy the count on its own (measured — removing a real
    // divider left this test green until the comments were excluded).
    // Every comment marker, not just `///`: commenting a rule out is the
    // likeliest way to lose one, and `// Divider()` kept this green while
    // the real rule was gone (measured).
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    let handDrawn = ["Rectangle()", "RoundedRectangle(", "Capsule(", ".background(Color"]
    for (index, line) in lines.enumerated() {
      // A shape inside `.contentShape` is an invisible hit region, not
      // chrome: it is what makes the whole quarter clickable.
      // Every other use of a shape in this file is drawing.
      if line.contains(".contentShape(") { continue }
      for pattern in handDrawn {
        #expect(!line.contains(pattern), "line \(index + 1) hand-draws \(pattern): \(line)")
      }
    }
    #expect(
      lines.filter { $0.contains("Divider()") }.count >= 2,
      "the icon row needs a rule above and below it")
  }

  // MARK: - The preference round-trips

  @Test("The navigator survives a relaunch through PreferencesStore")
  func navigatorPersists() {
    let suite = "pinax.tests.navigator.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = PreferencesStore(defaults: defaults)
    #expect(store.sidebarNavigator == .library)
    store.sidebarNavigator = .reports
    #expect(defaults.string(forKey: "pinax.sidebar.navigator") == "reports")
    #expect(PreferencesStore(defaults: defaults).sidebarNavigator == .reports)

    // Garbage in the domain falls back rather than trapping — and so does
    // the retired "folders" case an older install may have stored.
    defaults.set("nonesuch", forKey: "pinax.sidebar.navigator")
    #expect(PreferencesStore(defaults: defaults).sidebarNavigator == .library)
    defaults.set("folders", forKey: "pinax.sidebar.navigator")
    #expect(PreferencesStore(defaults: defaults).sidebarNavigator == .library)
  }

  @Test("The model writes every navigator change back exactly once")
  func modelWritesTheNavigatorBack() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    var written: [SidebarNavigator] = []
    model.onNavigatorChange = { written.append($0) }
    model.navigator = .collections
    model.navigator = .collections
    model.navigator = .library
    #expect(written == [.collections, .library])
  }
}
