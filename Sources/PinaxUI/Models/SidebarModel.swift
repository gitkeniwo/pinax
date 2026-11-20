import CatalogCore
import Foundation

/// Which navigator the sidebar is showing. Xcode's navigator
/// panel: one row of icon buttons on top, one `.listStyle(.sidebar)` List
/// below whose contents change with the icon. File-level for the same
/// reason `SidebarSelection` is.
///
/// `time` holds the year › month tree alone. `rawValue` is the case name,
/// so a preference stored under a retired name such as `"folders"` no
/// longer resolves and falls back to `.library`.
public enum SidebarNavigator: String, CaseIterable, Hashable, Sendable {
  case library
  case time
  case collections
  case reports

  /// The navigator's symbol. `SidebarNavigatorTests` resolves each one
  /// through `NSImage(systemSymbolName:)`, as every new symbol must be.
  public var systemImage: String {
    switch self {
    case .library: return "folder"
    case .time: return "calendar"
    case .collections: return "square.stack.fill"
    case .reports: return "chart.bar.fill"
    }
  }

  /// The switcher's per-button help text and accessibility label,
  /// and nothing else reads it: the jump bar's
  /// first segment is the section's own title, `Projects`.
  public var title: String {
    switch self {
    case .library: return "Library"
    case .time: return "Time"
    case .collections: return "Projects and Tags"
    case .reports: return "Reports"
    }
  }
}

/// What the sidebar's selection means. File-level (not nested in the
/// @MainActor view model) so row types stay nonisolated and Sendable.
public enum SidebarSelection: Hashable, Sendable {
  case all
  case recent
  /// The favourites, and the archive — the one surface that
  /// shows archived assets.
  case favorites
  case archived
  case orphans
  case externals
  /// The dashboard, Reports' first row.
  case overview
  case project(String)
  /// The current project's usage — one leaf, no slug.
  case usage
  case tag(String)
  /// A year of the time navigator's tree, "2026".
  case year(String)
  /// A month of the time navigator's tree, "2026-03" — the `yyyy-MM`
  /// bucket `availableMonths` returns.
  case month(String)
  /// A physical key prefix under the library's Catalog group,
  /// "blog/202603" — no leading or trailing slash; the whole catalog is
  /// `.all`, not an empty prefix.
  case keyPrefix(String, backend: String)
  /// A Catalog root — one backend's whole
  /// bucket, by slug.
  case backend(String)
  /// A Finder colour label of the collections navigator's Labels group.
  case label(AssetLabel)
  /// One source directory of a project's live
  /// references — `directory` is `UsageFile.directory`, source label and
  /// all ("" for a file at the project's top).
  case projectFolder(String, directory: String)
  /// One referencing file — `path` is
  /// `UsageFile.path`.
  case projectFile(String, path: String)
}

/// One referencing file under a project row —
/// what the row draws and counts.
public struct ProjectUsageFileEntry: Equatable, Sendable {
  public let path: String
  public let name: String
  /// The distinct images the file references.
  public let imageCount: Int
}

/// One source directory under a project row: the
/// files directly in it, the path squeezed onto one row.
public struct ProjectUsageFolder: Equatable, Sendable {
  public let directory: String
  /// "src/content/blog": the display path (source label off), else the
  /// raw directory, else "/".
  public let label: String
  /// The distinct images the directory's files reference — not the sum of
  /// the files' counts.
  public let imageCount: Int
  public let files: [ProjectUsageFileEntry]

  /// The folders of `slug`'s files in `browser`, by label, each one's files
  /// by name.
  public static func folders(of slug: String, in browser: UsageBrowser) -> [ProjectUsageFolder] {
    let files = browser.files.filter { $0.projectSlug == slug }
    let byDirectory = Dictionary(grouping: files, by: \.directory)
    return byDirectory.map { directory, files in
      let display = UsageBrowser.displayDirectory(files[0], sources: browser.usage.projectSources)
      return ProjectUsageFolder(
        directory: directory,
        label: !display.isEmpty ? display : (!directory.isEmpty ? directory : "/"),
        imageCount: Set(files.flatMap { $0.images.map(\.assetID) }).count,
        files: files.map {
          ProjectUsageFileEntry(path: $0.path, name: $0.name, imageCount: $0.images.count)
        }.sorted { lhs, rhs in
          let order = lhs.name.localizedStandardCompare(rhs.name)
          return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        })
    }.sorted { lhs, rhs in
      let order = lhs.label.localizedStandardCompare(rhs.label)
      return order == .orderedSame ? lhs.directory < rhs.directory : order == .orderedAscending
    }
  }
}

/// The project rows' loaded levels, by slug. A project that
/// is absent has not been opened yet.
public typealias ProjectUsageTree = [String: [ProjectUsageFolder]]

/// One level of the Catalog tree: a backend's bucket under `prefix` (nil
/// = its root). Every level is one backend's,
/// so two buckets' same-named folders never merge.
public struct KeyPrefixLevel: Hashable, Sendable {
  public let backend: String
  public let prefix: String?

  public init(backend: String, prefix: String?) {
    self.backend = backend
    self.prefix = prefix
  }
}

/// The Catalog tree's loaded levels: for each level whose children
/// have been fetched, the next segment level with subtree counts. A level
/// that is absent has not been expanded yet.
public typealias KeyPrefixChildren = [KeyPrefixLevel: [(segment: String, assetCount: Int, hasSubPrefixes: Bool)]]

/// A Storage root row — one backend. Named by its slug, the bucket
/// after it in the secondary colour; the Current prefix lives in the tooltip, so a domain move
/// changes the tooltip and never the row's name.
public struct CatalogRoot: Equatable, Sendable {
  public let slug: String
  public let prefix: String
  public let assetCount: Int
  public let bucket: String

  public init(slug: String, prefix: String, assetCount: Int, bucket: String = "") {
    self.slug = slug
    self.prefix = prefix
    self.assetCount = assetCount
    self.bucket = bucket
  }

  public init(_ backend: DomainBackend) {
    self.init(
      slug: backend.slug, prefix: backend.current, assetCount: backend.assetCount,
      bucket: backend.bucket)
  }

  public var host: String { DomainHost.host(prefix) }
  /// "image-hosting · https://img.example.com"; the prefix alone when
  /// the bucket is not known.
  public var help: String { bucket.isEmpty ? prefix : "\(bucket) · \(prefix)" }
}

/// The Library tab's optional sections below
/// Storage, in drawing order. Which are shown is one preference
/// (`PreferencesStore.libraryShortcuts`), written by the header menu and by
/// Settings ▸ Appearance alike.
public enum LibraryShortcut: String, CaseIterable, Hashable, Sendable {
  case projects
  case time

  public var title: String {
    switch self {
    case .projects: return "Projects"
    case .time: return "Time"
    }
  }

  /// Projects on, Time off.
  public static let defaultShown: Set<LibraryShortcut> = [.projects]
}

/// What a Library-tab section header's context menu offers:
/// `Hide Section` on a shortcut section only, then `Show Section ›` with
/// the hidden ones — disabled when none is hidden.
public struct SidebarHeaderMenu: Equatable, Sendable {
  /// The section this header hides; nil on Library and Storage.
  public let hides: LibraryShortcut?
  /// The hidden sections, in drawing order.
  public let showable: [LibraryShortcut]

  public var canShow: Bool { !showable.isEmpty }
}

/// Tint categories enhance the already-distinct symbol shapes; no category
/// relies on color alone to communicate its meaning.
public enum SidebarIconTint: Hashable, Sendable {
  case library
  /// A Catalog key-prefix folder (aqua).
  case catalog
  /// A Catalog backend root (its own colour).
  case backendRoot
  case recent
  case favorites
  case archived
  case orphans
  case externals
  case overview
  case project
  /// A project's source directory or file — grey.
  case projectSource
  case usage
  case tag
  /// A label row is tinted with its own colour: the colour is the label.
  case label(AssetLabel)
}

/// One selectable sidebar row. `id` is derived from `selection` **and the
/// navigator that shows it**, so two rows can never share an identity unless
/// they select the same thing in the same navigator — `List` requires ids
/// unique across the whole list, and parallel Projects/Usage
/// `ForEach(model.projects, id: \.slug)` blocks keyed by slug alone would
/// collide. The navigator prefix is what lets two
/// navigators offer the same selection — a year row and All Assets both
/// widening to everything, say — and still be different rows.
public struct SidebarEntry: Identifiable, Hashable, Sendable {
  public let navigator: SidebarNavigator
  public let selection: SidebarSelection
  public let label: String
  public let systemImage: String
  public let iconTint: SidebarIconTint
  public let count: Int?
  public let countHelp: String
  /// Archived's ⚠ N — deletions that did not finish.
  public let warningCount: Int?
  /// Rows nested under this one — a year's months, a prefix's segments.
  /// Empty for a leaf. The tree lives here, not in the view, so the jump
  /// bar and the tests walk exactly the rows the sidebar draws.
  public let children: [SidebarEntry]
  /// The row can open but its children have not been fetched: a Catalog
  /// prefix with sub-prefixes before its first expansion (each level
  /// loads lazily). A prefix holding only files is a plain leaf from the
  /// start, never a triangle that opens onto nothing.
  public let expandsLazily: Bool
  /// The row's tooltip (a Catalog root's backend and prefix); nil: none.
  public let help: String?
  /// Secondary text after the label on the same line (a Storage root's
  /// bucket); nil: none.
  public let detail: String?

  /// Whether the sidebar draws this row with a disclosure control.
  public var isExpandable: Bool { expandsLazily || !children.isEmpty }

  public var id: String { SidebarModel.rowID(for: selection, in: navigator) }

  public init(
    navigator: SidebarNavigator,
    selection: SidebarSelection,
    label: String,
    systemImage: String,
    iconTint: SidebarIconTint,
    count: Int? = nil,
    countHelp: String = "",
    warningCount: Int? = nil,
    children: [SidebarEntry] = [],
    expandsLazily: Bool = false,
    help: String? = nil,
    detail: String? = nil
  ) {
    self.navigator = navigator
    self.selection = selection
    self.label = label
    self.systemImage = systemImage
    self.iconTint = iconTint
    self.count = count
    self.countHelp = countHelp
    self.warningCount = warningCount
    self.children = children
    self.expandsLazily = expandsLazily
    self.help = help
    self.detail = detail
  }

  /// This row and every row under it, depth first — the order the sidebar
  /// draws them in when everything is expanded.
  public var flattened: [SidebarEntry] {
    [self] + children.flatMap(\.flattened)
  }
}

public struct SidebarSection: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let entries: [SidebarEntry]
  public let action: SidebarSectionAction?
  /// A Library-tab shortcut section: its header opens and
  /// closes it and can hide it. Nil for every other section.
  public let shortcut: LibraryShortcut?

  public init(
    id: String, title: String, entries: [SidebarEntry],
    action: SidebarSectionAction? = nil, shortcut: LibraryShortcut? = nil
  ) {
    self.id = id
    self.title = title
    self.entries = entries
    self.action = action
    self.shortcut = shortcut
  }
}

/// Section-level actions are model data rather than inferred from rendered
/// SwiftUI text, which is not observable for `Button` in the test host.
public enum SidebarSectionAction: Hashable, Sendable {
  case addProject
  /// The existing Add Tag… popover, on the
  /// selected assets.
  case addTag
}

/// Builds the sidebar's whole row tree in one testable place. The view
/// renders this and attaches `.tag` to the row itself; the ids
/// here are what make the rows selectable at all.
public enum SidebarModel {
  /// The identity of a sidebar row, namespaced by navigator and then by
  /// section, so a project and its usage entry are distinct by construction
  /// and so are the same selection under two navigators.
  public static func rowID(for selection: SidebarSelection, in navigator: SidebarNavigator)
    -> String
  {
    "\(navigator.rawValue):\(sectionScopedID(for: selection))"
  }

  private static func sectionScopedID(for selection: SidebarSelection) -> String {
    switch selection {
    case .all: return "library:all"
    case .recent: return "library:recent"
    case .favorites: return "library:favorites"
    case .archived: return "library:archived"
    case .orphans: return "library:orphans"
    case .externals: return "library:externals"
    case .overview: return "library:overview"
    case let .project(slug): return "project:\(slug)"
    case .usage: return "library:usage"
    case let .tag(name): return "tag:\(name)"
    case let .year(year): return "year:\(year)"
    case let .month(month): return "month:\(month)"
    case let .keyPrefix(prefix, backend): return "prefix:\(backend):\(prefix)"
    case let .backend(slug): return "backend:\(slug)"
    case let .label(label): return "label:\(label.rawValue)"
    case let .projectFolder(slug, directory): return "pfolder:\(slug):\(directory)"
    case let .projectFile(slug, path): return "pfile:\(slug):\(path)"
    }
  }

  /// The navigator whose tree has the row for `selection` — where a writer
  /// from outside the sidebar (the Library menu's shortcuts) must put it,
  /// so a selection never lands in a tree without its row.
  /// `SidebarModelTests` walks every row of every tree back through this.
  public static func navigator(for selection: SidebarSelection) -> SidebarNavigator {
    switch selection {
    case .all, .recent, .favorites, .archived, .keyPrefix, .backend: return .library
    case .year, .month: return .time
    case .project, .tag, .label, .projectFolder, .projectFile: return .collections
    case .overview, .orphans, .externals, .usage: return .reports
    }
  }

  /// The one row tree, per navigator. Library is All Assets and Recent plus
  /// the Catalog group, the key-prefix tree built from `folderChildren` as
  /// far as it has been loaded. Orphans and Externals
  /// live only in Reports, beside one usage row per project. Collections
  /// is Projects + Tags. The time navigator is year › month, built from
  /// `months` — `availableMonths` over the whole
  /// catalog, so the tree does not change with the selection.
  ///
  /// Catalog is a group header, not a row: nothing selects "the whole
  /// catalog by prefix" — that is All Assets. It is a root group, so the
  /// jump bar's own leading "Catalog" is its segment.
  ///
  /// There is deliberately no "Catalog" root row: it would select `.all`,
  /// exactly what "All Assets" selects, and a row's identity is
  /// `navigator:sectionScopedID(selection)` — inside one navigator the two
  /// rows would share the id `library:library:all`. The Catalog group has
  /// real prefix rows under it and does not need a root row to stand for
  /// the whole catalog.
  public static func sections(
    navigator: SidebarNavigator,
    projects: [ProjectSummary],
    tags: [TagSummary],
    months: [(month: String, count: Int)],
    folderChildren: KeyPrefixChildren,
    catalogRoots: [CatalogRoot] = [],
    labels: [LabelSummary] = [],
    unfinishedDeletions: Int = 0,
    libraryShortcuts: Set<LibraryShortcut> = [],
    projectFolders: ProjectUsageTree = [:]
  ) -> [SidebarSection] {
    switch navigator {
    case .library:
      // A root per backend, even with one; its
      // key folders hang under it.
      let catalog = catalogRoots.map { root in
        let level = KeyPrefixLevel(backend: root.slug, prefix: nil)
        return SidebarEntry(
          navigator: .library, selection: .backend(root.slug), label: root.slug,
          systemImage: "cloud.fill", iconTint: .backendRoot, count: root.assetCount,
          countHelp: "Assets in this backend",
          children: prefixEntries(under: level, folderChildren),
          expandsLazily: folderChildren[level] == nil && root.assetCount > 0,
          help: root.help, detail: root.bucket.isEmpty ? nil : root.bucket)
      }
      // Below Storage, the shown shortcuts that have rows —
      // the Collections tab's project rows and the Time tab's years, with
      // `library:` ids and no children. An empty one draws no header.
      let shortcuts = LibraryShortcut.allCases.filter(libraryShortcuts.contains).compactMap {
        shortcut -> SidebarSection? in
        let entries: [SidebarEntry]
        switch shortcut {
        case .projects:
          entries = projectEntries(projects, navigator: .library)
        case .time:
          entries = yearEntries(months, navigator: .library, withMonths: false)
        }
        guard !entries.isEmpty else { return nil }
        return SidebarSection(
          id: shortcut.rawValue, title: shortcut.title, entries: entries, shortcut: shortcut)
      }
      return [
        SidebarSection(id: "library", title: "Library", entries: [
          SidebarEntry(
            navigator: navigator, selection: .all, label: "All Assets",
            systemImage: "photo.on.rectangle.angled.fill", iconTint: .library),
          SidebarEntry(
            navigator: navigator, selection: .recent, label: "Recent",
            systemImage: "clock.fill", iconTint: .recent),
          SidebarEntry(
            navigator: navigator, selection: .favorites, label: "Favorites",
            systemImage: "heart.fill", iconTint: .favorites),
          SidebarEntry(
            navigator: navigator, selection: .archived, label: "Archived",
            systemImage: "archivebox.fill", iconTint: .archived,
            warningCount: unfinishedDeletions > 0 ? unfinishedDeletions : nil),
        ])
      ] + (catalog.isEmpty ? [] : [
        // Storage; the id stays `catalog`.
        SidebarSection(id: "catalog", title: "Storage", entries: catalog)
      ]) + shortcuts
    case .time:
      // No months, no section: an empty List draws nothing, while a bare
      // "Time" header over no rows would be a group with nothing in it.
      guard !months.isEmpty else { return [] }
      return [
        SidebarSection(
          id: "time", title: "Time", entries: yearEntries(months, navigator: .time, withMonths: true))
      ]
    case .collections:
      return [
        SidebarSection(
          id: "projects", title: "Projects",
          entries: projectEntries(projects, navigator: navigator, folders: projectFolders),
          action: .addProject),
        SidebarSection(
          id: "tags", title: "Tags",
          entries: tags.map { tag in
            SidebarEntry(
              navigator: navigator,
              selection: .tag(tag.name),
              label: tag.name,
              systemImage: "tag.fill",
              iconTint: .tag,
              count: tag.assetCount,
              countHelp: "Assets carrying this tag")
          },
          action: .addTag),
      ] + (labels.isEmpty ? [] : [
        // Only the colours in use, Finder's order.
        SidebarSection(
          id: "labels", title: "Labels",
          entries: labels.map { summary in
            SidebarEntry(
              navigator: navigator,
              selection: .label(summary.label),
              label: summary.label.title,
              systemImage: "circle.fill",
              iconTint: .label(summary.label),
              count: summary.assetCount,
              countHelp: "Assets with this label")
          })
      ])
    case .reports:
      return [
        SidebarSection(id: "reports", title: "Reports", entries: [
          SidebarEntry(
            navigator: navigator, selection: .overview, label: "Overview",
            systemImage: "chart.bar.xaxis", iconTint: .overview),
          SidebarEntry(
            navigator: navigator, selection: .usage, label: "Usage",
            systemImage: "link.circle.fill", iconTint: .usage),
          SidebarEntry(
            navigator: navigator, selection: .orphans, label: "Orphans",
            systemImage: "questionmark.folder.fill", iconTint: .orphans),
          SidebarEntry(
            navigator: navigator, selection: .externals, label: "Externals",
            systemImage: "link.badge.plus", iconTint: .externals),
        ])
      ]
    }
  }

  /// What a Library-tab section header's menu offers, for the shown
  /// shortcuts.
  public static func headerMenu(
    for section: SidebarSection, shown: Set<LibraryShortcut>
  ) -> SidebarHeaderMenu {
    SidebarHeaderMenu(
      hides: section.shortcut,
      showable: LibraryShortcut.allCases.filter { !shown.contains($0) })
  }

  /// One row per project: the Collections tab's, and the Library tab's
  /// Projects shortcut — the same data, icon and count.
  /// In the Projects tab (`folders` given) a project with live
  /// references opens, Storage's way, onto its source directories and
  /// their files, loaded the first time it opens; the shortcut's rows
  /// stay leaves.
  private static func projectEntries(
    _ projects: [ProjectSummary], navigator: SidebarNavigator,
    folders: ProjectUsageTree? = nil
  ) -> [SidebarEntry] {
    projects.map { project in
      let loaded = folders?[project.slug]
      return SidebarEntry(
        navigator: navigator,
        selection: .project(project.slug),
        label: project.name,
        systemImage: "folder.fill",
        iconTint: .project,
        count: project.assetCount,
        countHelp: "Assets in this project",
        children: (loaded ?? []).map { folderEntry($0, project: project.slug) },
        expandsLazily: folders != nil && loaded == nil && project.liveUsageCount > 0)
    }
  }

  private static func folderEntry(_ folder: ProjectUsageFolder, project: String) -> SidebarEntry {
    SidebarEntry(
      navigator: .collections,
      selection: .projectFolder(project, directory: folder.directory),
      label: folder.label, systemImage: "folder.fill", iconTint: .projectSource,
      count: folder.imageCount, countHelp: "Images used in this folder",
      children: folder.files.map { file in
        SidebarEntry(
          navigator: .collections,
          selection: .projectFile(project, path: file.path),
          label: file.name, systemImage: "doc.text.fill", iconTint: .projectSource,
          count: file.imageCount, countHelp: "Images used in this file",
          help: file.path)
      },
      help: folder.directory.isEmpty ? nil : folder.directory)
  }

  /// The Time tab's year that starts open — the
  /// current one, or the newest when the current year has no uploads.
  public static func defaultOpenYear(
    months: [(month: String, count: Int)], now: Date = Date(), calendar: Calendar = .current
  ) -> String? {
    let years = months.map { PinaxFormat.monthTitle($0.month).year }.filter { !$0.isEmpty }
    let current = String(calendar.component(.year, from: now))
    return years.contains(current) ? current : years.first
  }

  /// The Catalog rows under `parent` (nil = the root), recursively as deep
  /// as `folderChildren` has been loaded. Labels are segment names, counts
  /// are subtree asset counts.
  private static func prefixEntries(
    under parent: KeyPrefixLevel, _ folderChildren: KeyPrefixChildren
  ) -> [SidebarEntry] {
    (folderChildren[parent] ?? []).map { child in
      let path = parent.prefix.map { "\($0)/\(child.segment)" } ?? child.segment
      let level = KeyPrefixLevel(backend: parent.backend, prefix: path)
      return SidebarEntry(
        navigator: .library, selection: .keyPrefix(path, backend: parent.backend), label: child.segment,
        systemImage: "folder.fill", iconTint: .catalog,
        count: child.assetCount,
        countHelp: "Assets under this prefix",
        children: prefixEntries(under: level, folderChildren),
        expandsLazily: folderChildren[level] == nil && child.hasSubPrefixes)
    }
  }

  /// Years newest first, each holding its months newest first — the order
  /// `availableMonths` already returns. A year's count is the sum of its
  /// months' counts, not a separate query.
  /// The Library tab's Time shortcut takes the years alone.
  private static func yearEntries(
    _ months: [(month: String, count: Int)], navigator: SidebarNavigator, withMonths: Bool
  ) -> [SidebarEntry] {
    var years: [String] = []
    var monthsByYear: [String: [(month: String, count: Int)]] = [:]
    for entry in months {
      let year = PinaxFormat.monthTitle(entry.month).year
      guard !year.isEmpty else { continue }
      if monthsByYear[year] == nil { years.append(year) }
      monthsByYear[year, default: []].append(entry)
    }
    return years.map { year in
      let yearMonths = monthsByYear[year] ?? []
      return SidebarEntry(
        navigator: navigator, selection: .year(year), label: year,
        systemImage: "calendar", iconTint: .recent,
        count: yearMonths.reduce(0) { $0 + $1.count },
        countHelp: "Assets uploaded this year",
        children: !withMonths ? [] : yearMonths.map { entry in
          SidebarEntry(
            navigator: .time, selection: .month(entry.month),
            label: PinaxFormat.monthTitle(entry.month).month,
            systemImage: "calendar", iconTint: .recent,
            count: entry.count,
            countHelp: "Assets uploaded this month")
        })
    }
  }
}
