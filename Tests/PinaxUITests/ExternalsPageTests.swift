import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Externals' ⓘ, its first-visit card,
/// the four orders, Group by File and the list's column headers.
@MainActor
@Suite struct ExternalsPageTests {
  static let prefix = "https://img.pinax.invalid"

  // MARK: - The card

  @Test("The card shows on the first visit; after ✕ a rebuilt app shows it in no project")
  func tipOnceForTheApp() async throws {
    let (database, directory) = try makeCatalog()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "pinaxui-t34-tip-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await first.start()
    let externals = try #require(first.gallery).externals
    await externals.selectProject("blog")
    #expect(externals.showsTip)
    // Other Domains has nothing to import: no card there.
    externals.domain = .other
    #expect(!externals.showsTip)
    externals.domain = .yours
    externals.dismissTip()
    #expect(!externals.showsTip)
    #expect(defaults.object(forKey: "pinax.externals.tipDismissed") as? Bool == true)

    let second = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await second.start()
    let again = try #require(second.gallery).externals
    for project in ["blog", "notes", nil] as [String?] {
      await again.selectProject(project)
      #expect(again.count(.yours) > 0)
      #expect(!again.showsTip, "\(project ?? "All Projects")")
    }
  }

  // MARK: - ⓘ

  @Test("The popover's words, from one pure function")
  func infoWords() {
    let yours = "On your backends’ domains but not in the catalog — usually uploaded by another "
      + "tool, removed outside Pinax, or mistyped. Import them to track their usage."
    let other = "Hosted elsewhere. Pinax lists them and never loads them."
    let one = ExternalsModel.info(scope: "astro", hosts: 1, notFound: 1)
    #expect(one.notes == [
      ReportNote(heading: "Your Domains", lines: [yours]),
      ReportNote(heading: "Other Domains", lines: [other]),
    ])
    #expect(one.facts == "From the latest scan of astro · 1 host · 1 not found")
    #expect(
      ExternalsModel.info(scope: nil, hosts: 3, notFound: 0).facts
        == "From the latest scans of all projects · 3 hosts")
    #expect(
      ExternalsModel.info(scope: "blog", hosts: 0, notFound: 12).facts
        == "From the latest scan of blog · 0 hosts · 12 not found")
  }

  @Test("The page's popover counts the shown half's hosts and its not-found rows")
  func infoFromThePage() async {
    let model = ExternalsModel(reader: StaticExternals(Self.rows))
    await model.selectProject("blog")
    #expect(model.info.facts == "From the latest scan of blog · 1 host")
    model.importFailures[Self.rows[0].rawURL] = .notFound
    #expect(model.info.facts == "From the latest scan of blog · 1 host · 1 not found")
    model.domain = .other
    #expect(model.info.facts == "From the latest scan of blog · 2 hosts")
  }

  // MARK: - The four orders

  /// Your Domains: a.md at L9, L10, L100 — string order would put L10 and
  /// L100 before L9 — and b.md at L2; names and kinds that disagree with
  /// that order.
  static let rows: [ExternalReference] = [
    row("posts/b.md#L2", "zeta.png", "markdown"),
    row("posts/a.md#L10", "alpha.png", "html"),
    row("posts/a.md#L9", "Beta.png", "markdown"),
    row("posts/a.md#L100", "gamma.jpg", "markdown"),
    ExternalReference(
      projectSlug: "blog", sourceReference: "posts/c.md#L1",
      rawURL: "https://elsewhere.example.org/x.png", kind: "markdown", domain: .other),
    ExternalReference(
      projectSlug: "blog", sourceReference: "posts/c.md#L2",
      rawURL: "https://third.example.com/y.png", kind: "markdown", domain: .other),
  ]

  static func row(_ source: String, _ name: String, _ kind: String) -> ExternalReference {
    ExternalReference(
      projectSlug: "blog", sourceReference: source, rawURL: "\(prefix)/blog/\(name)", kind: kind,
      domain: .yours,
      match: ExternalDomainMatch(backendSlug: "r2", prefix: prefix, isCurrent: true))
  }

  private func names(_ model: ExternalsModel) -> [String] {
    model.groups.flatMap(\.rows).map(ExternalsView.filename)
  }

  @Test("Used In is the default — file, then line as a number")
  func usedInOrder() async {
    let model = ExternalsModel(reader: StaticExternals(Self.rows))
    await model.selectProject("blog")
    #expect(model.sort == ExternalSort(field: .usedIn, direction: .ascending))
    #expect(names(model) == ["Beta.png", "alpha.png", "gamma.jpg", "zeta.png"])
    model.sort.direction = .descending
    #expect(names(model) == ["zeta.png", "gamma.jpg", "alpha.png", "Beta.png"])
  }

  @Test("Name, case-insensitively, as Finder")
  func nameOrder() async {
    let model = ExternalsModel(reader: StaticExternals(Self.rows))
    await model.selectProject("blog")
    model.sort = ExternalSort(field: .name)
    #expect(names(model) == ["alpha.png", "Beta.png", "gamma.jpg", "zeta.png"])
  }

  @Test("Status puts the failed rows first, by import-failure category, the rest in Used In order")
  func statusOrder() async {
    let model = ExternalsModel(reader: StaticExternals(Self.rows))
    await model.selectProject("blog")
    model.importFailures = [
      "\(Self.prefix)/blog/gamma.jpg": .sameImage(existingKey: "blog/known.png"),
      "\(Self.prefix)/blog/zeta.png": .notFound,
    ]
    model.sort = ExternalSort(field: .status)
    #expect(names(model) == ["zeta.png", "gamma.jpg", "Beta.png", "alpha.png"])
  }

  @Test("Kind, then Used In within a kind")
  func kindOrder() async {
    let model = ExternalsModel(reader: StaticExternals(Self.rows))
    await model.selectProject("blog")
    model.sort = ExternalSort(field: .kind)
    #expect(names(model) == ["alpha.png", "Beta.png", "gamma.jpg", "zeta.png"])
    model.sort.direction = .descending
    #expect(names(model) == ["zeta.png", "gamma.jpg", "Beta.png", "alpha.png"])
  }

  // MARK: - Group by File

  @Test("Group by File — a group per file, headed by its path, rows by line; All Projects names the project")
  func groupByFile() async {
    let model = ExternalsModel(reader: StaticExternals(Self.rows))
    await model.selectProject("blog")
    model.groupsByFile = true
    #expect(model.groups.map(\.host) == ["posts/a.md", "posts/b.md"])
    #expect(model.groups.allSatisfy { $0.isFile })
    #expect(model.groups.map { $0.rows.map(ExternalsView.filename) } == [
      ["Beta.png", "alpha.png", "gamma.jpg"], ["zeta.png"],
    ])
    #expect(model.groups.map(\.note) == ["3", "1"])
    #expect(model.groups.allSatisfy { model.isExpanded($0) })
    #expect(ExternalsView.place(Self.rows[1], inFileGroup: true) == "L10")
    // Groups come in the order of their first row under the sort.
    model.sort = ExternalSort(field: .name, direction: .descending)
    #expect(model.groups.map(\.host) == ["posts/b.md", "posts/a.md"])
    #expect(model.groups.dropFirst().first?.rows.map(ExternalsView.filename) == ["gamma.jpg", "Beta.png", "alpha.png"])
    model.groupsByFile = false
    #expect(model.groups.map(\.host) == ["img.pinax.invalid"])

    let all = ExternalsModel(reader: StaticExternals(Self.rows), groupsByFile: true)
    await all.selectProject(nil)
    #expect(all.groups.map(\.host) == ["blog · posts/a.md", "blog · posts/b.md"])
  }

  // MARK: - One state: headers, menu, preferences

  @Test("The list's column headers and the jump bar's menu write one sort")
  func headersAndMenuShareTheSort() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gallery = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-t34-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }),
      externalReader: StaticExternals(Self.rows))
    let externals = gallery.externals
    await externals.selectProject("blog")
    let menu = JumpBar(model: gallery).externalSortItems.sort
    let headers = ExternalsListHeader(model: externals)

    #expect(headers.indicator(.usedIn) == "chevron.up")
    menu.wrappedValue = ExternalSort(field: .name)
    #expect(headers.indicator(.name) == "chevron.up")
    #expect(headers.indicator(.usedIn) == nil)
    headers.click(.name)
    #expect(menu.wrappedValue == ExternalSort(field: .name, direction: .descending))
    #expect(names(externals) == ["zeta.png", "gamma.jpg", "Beta.png", "alpha.png"])
    headers.click(.kind)
    #expect(menu.wrappedValue == ExternalSort(field: .kind, direction: .ascending))
    #expect(headers.indicator(.kind) == "chevron.up")
    #expect(ExternalsListHeader.columns == [.name, .usedIn, .kind, .refs])
    #expect(ExternalsListHeader.title(.name) == "Host")
    #expect(ExternalsListHeader.title(.refs) == "Refs")

    // Refs is the group count's order; its first click puts the largest
    // first, and a second turns it around (the count ordering itself is
    // pinned in ExternalsLayoutTests, where one half has two hosts).
    headers.click(.refs)
    #expect(menu.wrappedValue == ExternalSort(field: .refs, direction: .descending))
    #expect(headers.indicator(.refs) == "chevron.down")
    headers.click(.refs)
    #expect(menu.wrappedValue == ExternalSort(field: .refs, direction: .ascending))
  }

  @Test("On Externals the jump bar's sort and grouping switch are live; the switch is Group by File")
  func jumpBarControls() {
    let controls = JumpBar.controls(
      selection: .externals, viewMode: .grid, sort: AssetSort(), canGoBack: false,
      canGoForward: false)
    #expect(controls.trailing.map(\.control) == [.sort, .displayOptions, .groupByFile])
    #expect(controls.trailing.map(\.isEnabled) == [true, false, true])
    #expect(controls.trailing.last?.help == "Group by file")
    #expect(NSImage(systemSymbolName: JumpBar.Control.groupByFile.systemImage, accessibilityDescription: nil) != nil)
  }

  @Test("The order and Group by File survive a rebuilt app, through the app's own writeback")
  func sortAndGroupPersist() async throws {
    let (database, directory) = try makeCatalog()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "pinaxui-t34-sort-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await first.start()
    let gallery = try #require(first.gallery)
    #expect(gallery.externals.sort == ExternalSort())
    #expect(!gallery.externals.groupsByFile)
    ExternalsListHeader(model: gallery.externals).click(.kind)
    ExternalsListHeader(model: gallery.externals).click(.kind)
    gallery.externals.groupsByFile = true
    #expect(defaults.string(forKey: "pinax.externals.sort") == "kind.descending")
    #expect(defaults.object(forKey: "pinax.externals.groupsByFile") as? Bool == true)

    let second = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await second.start()
    let again = try #require(second.gallery).externals
    #expect(again.sort == ExternalSort(field: .kind, direction: .descending))
    #expect(again.groupsByFile)
    // The library's own order is not Externals'.
    #expect(second.preferences.gallerySort == AssetSort())
  }

  // MARK: - Fixtures

  /// Two projects on r2, each with one reference on r2's domain.
  private func makeCatalog() throws -> (DatabasePool, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-t34-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://s3.pinax.invalid", bucket: "images", region: "auto",
      urlPrefix: Self.prefix, keychainReference: "", to: database)
    for project in ["blog", "notes"] {
      _ = try CatalogConfiguration.addProject(
        slug: project, name: project.capitalized, keyPrefix: project, backendSlug: "r2",
        to: database)
      _ = try CatalogUsage.sync(
        UsageDocument(
          project: project,
          refs: [UsageReference(rawURL: "\(Self.prefix)/\(project)/a.png", sourceReference: "posts/a.md#L3")]),
        project: project, in: database)
    }
    return (database, directory)
  }
}

/// A fixed set of references, filtered by project as the catalog does.
private struct StaticExternals: ExternalUsageReading {
  let rows: [ExternalReference]
  init(_ rows: [ExternalReference]) { self.rows = rows }

  func externalReferences(project: String?) async throws -> ExternalReferenceSet {
    ExternalReferenceSet(
      references: rows.filter { project == nil || $0.projectSlug == project }, projectSources: [:])
  }
}
