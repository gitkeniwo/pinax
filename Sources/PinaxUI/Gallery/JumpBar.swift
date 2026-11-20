import CatalogCore
import SwiftUI

/// The jump bar: Xcode's editor path bar — `Projects › Blog
/// › IMG_3560.jpg` — pinned under the toolbar, above the find strip. It
/// answers "where am I, and what am I looking at".
///
/// Which control (recorded so the next reader does not "correct" it to
/// a standard one): `NSPathControl` has the exact chevron-segment
/// look but ONE menu for the whole control — no per-segment dropdown. The
/// whole value of a pickable jump bar for Pinax is switching project or
/// tag without going to the sidebar, so each segment here is a standard
/// `Menu` with a real list of sibling destinations; only the arrangement
/// (the chevron row) is ours. Inert segments — the group header, the
/// selected asset — are plain text: a segment with no destination to
/// offer is not drawn as a menu (no false affordance).
///
/// Identity: the bar is one stable container whose CONTENTS
/// change; components are keyed by their selection value, never by array
/// index, so a selection change swaps values, not identities. No
/// animation and no transition is attached — a flicker here would be a
/// destroyed identity to fix, not a missing transition to add.
///
/// Labels come from `SidebarModel.sections` — the same single source the
/// sidebar renders — so the bar and the sidebar can never name the same
/// destination differently. Destination icons carry that same
/// `SidebarEntry`, so their symbol names and tint categories cannot fork
/// either. Selecting a destination writes
/// `model.sidebarSelection` through the same published property the
/// sidebar's List binding writes; there is no second path to disagree.
///
/// Controls: Xcode's editor bar carries
/// ◀ ▶ at its leading end and its options at the trailing end, and so does
/// this one. They come from `controls(selection:viewMode:sort:canGoBack:
/// canGoForward:)` — one fixed list for every navigator, disabled in place
/// where they do not apply, never removed — so the bar cannot reflow.
struct JumpBar: View {
  @ObservedObject var model: GalleryModel

  /// The bar's path and controls, for the place the centre column draws
  /// — not the sidebar's highlight, which moves first.
  var path: [Component] {
    Self.components(
      selection: model.shownSelection,
      navigator: model.shownPlace.navigator,
      projects: model.projects,
      tags: model.tags,
      months: model.availableMonths,
      folderChildren: model.folderChildren,
      catalogRoots: model.domainBackends.map(CatalogRoot.init),
      labels: model.labels,
      libraryShortcuts: model.libraryShortcuts,
      projectFolders: model.projectFolders,
      usageFileName: model.usageContextFile?.name,
      selectedName: selectedAssetName)
  }

  var drawnControls: (leading: [ControlState], trailing: [ControlState]) {
    Self.controls(
      selection: model.shownSelection, navigator: model.shownPlace.navigator, viewMode: model.viewMode, sort: model.sort,
      canGoBack: model.canGoBack, canGoForward: model.canGoForward)
  }

  var body: some View {
    HStack(spacing: 4) {
      let controls = drawnControls
      ForEach(controls.leading) { control($0) }
      let components = path
      ForEach(components) { component in
        if component.id != components.first?.id {
          chevron
        }
        segment(component)
      }
      Spacer(minLength: 0)
      ForEach(controls.trailing) { control($0) }
    }
    .padding(.horizontal, ChromeMetrics.horizontalPadding)
    .frame(height: ChromeMetrics.stripHeight)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("gallery-jump-bar")
  }

  /// The display-options menu's items, over the gallery's own
  /// `gridOverlays` — the binding `PreferencesStoreTests` writes through to
  /// prove this menu and View ▸ Show read one state.
  var displayOptionsItems: GridOverlayMenuItems {
    GridOverlayMenuItems(overlays: $model.gridOverlays)
  }

  /// The sort menu's items, over the gallery's own `sort` — the binding the
  /// sort tests write through to prove this menu and View ▸ Sort By read
  /// one order.
  var sortItems: SortMenuItems {
    SortMenuItems(sort: $model.sort)
  }

  /// The sort menu's Show section, over the
  /// gallery's own `sourceFilter` — the one the find strip's Source popup
  /// writes. Grayed where the filter does not apply (Externals' menu).
  var sourceItems: some View {
    Section("Show") {
      sourceFilterItems.pickerStyle(.inline)
    }
    .disabled(!SourceFilterItems.applies(to: model.shownSelection))
  }

  /// The Show section's binding, for the tests (the section itself is
  /// an opaque view).
  var sourceFilterItems: SourceFilterItems {
    SourceFilterItems(source: $model.sourceFilter, counts: model.sourceCounts)
  }

  /// Externals' sort menu, over the page's own `sort` — the binding
  /// its column headers write too.
  var externalSortItems: ExternalSortMenuItems {
    ExternalSortMenuItems(externals: model.externals)
  }

  @ViewBuilder
  private func control(_ state: ControlState) -> some View {
    Group {
      switch state.control {
      case .back:
        Button(action: model.goBack) {
          Label("Go Back", systemImage: state.control.systemImage)
        }
        .foregroundStyle(.secondary)
        .help("Go Back")
      case .forward:
        Button(action: model.goForward) {
          Label("Go Forward", systemImage: state.control.systemImage)
        }
        .foregroundStyle(.secondary)
        .help("Go Forward")
      case .sort:
        Menu {
          if model.shownSelection == .externals { externalSortItems } else { sortItems }
          sourceItems
        } label: {
          Label("Sort By", systemImage: state.control.systemImage)
        }
        // The counts the Show section and the find strip's popup list; the
        // jump bar is always up, the strip only on demand.
        .task(id: SourceFilterItems.CountsKey(
          selection: model.sidebarSelection, total: model.totalCount,
          unfiltered: model.unfilteredTotalCount)
        ) {
          await model.refreshSourceCounts()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Sort By")
      case .displayOptions:
        Menu {
          displayOptionsItems
        } label: {
          Label("Display Options", systemImage: state.control.systemImage)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Choose the metadata shown around grid thumbnails")
      case .groupByMonth:
        // On is the soft plate with the accent
        // icon; the system's checked-button look underneath.
        Toggle(isOn: $model.groupsByMonth) {
          Label("Group by Month", systemImage: state.control.systemImage)
        }
        .toggleStyle(.button)
        .pinaxSoftToggleBackground(model.groupsByMonth && state.isEnabled)
        .help(state.help)
      case .groupByFile:
        ExternalsGroupByFileToggle(externals: model.externals, state: state)
      }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .controlSize(.small)
    .disabled(!state.isEnabled)
  }

  private func segment(_ component: Component) -> some View {
    Group {
      if component.destinations.isEmpty, let target = component.target {
        // The section header and Usage's file are
        // links — the section's first place, the file on Usage ▸ Files.
        Button {
          switch target {
          case .selection(let selection): model.sidebarSelection = selection
          case .usageFile: model.openUsageContextFile()
          }
        } label: {
          componentLabel(component)
        }
        .buttonStyle(.usageSegment)
        .help(component.help)
      } else if component.destinations.isEmpty {
        componentLabel(component)
          .help(component.help)
      } else {
        if Self.isCurrent(component, selection: model.shownSelection) {
          // A plain menu button, so the capsule and the ⌄ are drawn as the
          // label says (the borderless style draws its own title).
          Menu {
            destinationItems(component)
          } label: {
            HStack(spacing: DesignMetrics.spacing.xs) {
              componentLabel(component, isCurrent: true)
              Image(systemName: Self.currentIndicator)
                .imageScale(.small)
                .accessibilityHidden(true)
            }
            .pinaxCurrentSegmentPlate()
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
          .menuIndicator(.hidden)
          .fixedSize()
          .help(component.help)
        } else {
          Menu {
            destinationItems(component)
          } label: {
            componentLabel(component)
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help(component.help)
        }
      }
    }
  }

  @ViewBuilder
  private func destinationItems(_ component: Component) -> some View {
    ForEach(component.destinations) { destination in
      Button {
        model.sidebarSelection = destination.selection
      } label: {
        if destination.selection == component.current {
          Label(destination.label, systemImage: "checkmark")
        } else {
          Text(destination.label)
        }
      }
    }
  }

  @ViewBuilder
  private func componentLabel(_ component: Component, isCurrent: Bool = false) -> some View {
    if let entry = component.entry {
      HStack(spacing: 4) {
        SidebarEntryIcon(entry: entry)
        segmentText(component.label, isCurrent: isCurrent)
      }
    } else {
      segmentText(component.label, isCurrent: isCurrent)
    }
  }

  @ViewBuilder
  private func segmentText(_ label: String, isCurrent: Bool) -> some View {
    if isCurrent {
      Text(label)
        .pinaxBarCurrent()
        .lineLimit(1)
        .truncationMode(.middle)
    } else {
      ChromeMetrics.text(label)
    }
  }

  /// The segment that names the place shown ("All Assets ⌄") sits on a count capsule with a ⌄ after it.
  static func isCurrent(_ component: Component, selection: SidebarSelection) -> Bool {
    !component.destinations.isEmpty && component.current == selection
  }

  /// The ⌄ after the current segment.
  static let currentIndicator = "chevron.down"

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 8, weight: .semibold))
      .foregroundStyle(.tertiary)
      .imageScale(.small)
      .accessibilityHidden(true)
  }

  /// The asset segment, on the surfaces that show the selection.
  private var selectedAssetName: String? {
    guard model.showsAssetSelection, let details = model.selectedDetails else { return nil }
    return details.item.asset.originalFilename
      ?? (details.item.asset.key as NSString).lastPathComponent
  }

  // MARK: - The controls, pure and testable

  enum Control: String, CaseIterable, Identifiable {
    case back, forward, sort, displayOptions, groupByMonth
    /// Externals' grouping switch, in the month switch's place.
    case groupByFile

    var id: String { rawValue }

    /// Each checked by `NSImage(systemSymbolName:)` in `JumpBarTests`.
    var systemImage: String {
      switch self {
      case .back: return "chevron.left"
      case .forward: return "chevron.right"
      case .sort: return "arrow.up.arrow.down"
      case .displayOptions: return "slider.horizontal.3"
      case .groupByMonth: return "calendar"
      case .groupByFile: return ExternalsView.groupSymbol
      }
    }
  }

  struct ControlState: Identifiable, Hashable {
    let control: Control
    let isEnabled: Bool
    /// The hover text. Only the month switch varies: grayed by the sort,
    /// it says why.
    var help: String = ""
    var id: String { control.id }
  }

  static let groupByMonthHelp = "Group by month"
  static let groupByMonthNeedsDateHelp = "Months group only when sorted by Date Uploaded"
  static let groupByMonthElsewhereHelp = "Months group in All Assets, Recent and a year"
  static let groupByFileHelp = "Group by file"

  /// The bar's controls for a model state: the same controls in the same
  /// order everywhere. History follows its own two directions;
  /// the sort menu (first trailing place) grays out on the report
  /// surfaces, which list no assets to order; the display options gray
  /// out in place wherever there is no asset grid to apply them to — the
  /// report surfaces, and the table. The month switch applies to the grid
  /// and the table alike (the table has month sections too), so it
  /// grays out only on the report surfaces and under any order but upload
  /// date, where months would scatter; its stored value is left
  /// alone, so returning to upload date groups again as it was.
  static func controls(
    selection: SidebarSelection,
    navigator: SidebarNavigator = .library,
    viewMode: GalleryModel.ViewMode,
    sort: AssetSort,
    canGoBack: Bool,
    canGoForward: Bool
  ) -> (leading: [ControlState], trailing: [ControlState]) {
    let showsAssets: Bool
    switch selection {
    case .overview, .orphans, .externals, .usage: showsAssets = false
    default: showsAssets = true
    }
    // Usage's images are the library's grid: its display options
    // apply, the library's sort does not.
    let groupable = showsAssets && GalleryModel.isMonthGroupable(NavigationHistory.Place(navigator, selection))
    let showsAssetGrid = (showsAssets || selection == .usage) && viewMode == .grid
    // Externals orders its own rows, and its
    // grouping switch, in the same place, groups by file.
    if selection == .externals {
      return (
        leading: [
          ControlState(control: .back, isEnabled: canGoBack),
          ControlState(control: .forward, isEnabled: canGoForward),
        ],
        trailing: [
          ControlState(control: .sort, isEnabled: true),
          ControlState(control: .displayOptions, isEnabled: false),
          ControlState(control: .groupByFile, isEnabled: true, help: groupByFileHelp),
        ])
    }
    return (
      leading: [
        ControlState(control: .back, isEnabled: canGoBack),
        ControlState(control: .forward, isEnabled: canGoForward),
      ],
      trailing: [
        ControlState(control: .sort, isEnabled: showsAssets),
        ControlState(control: .displayOptions, isEnabled: showsAssetGrid),
        // Only where months group at all (All Assets,
        // Recent, a year): elsewhere — the Catalog, a project, a tag — a
        // live switch would do nothing.
        ControlState(
          control: .groupByMonth,
          isEnabled: groupable && sort.field == .uploadedAt,
          help: !groupable
            ? groupByMonthElsewhereHelp
            : sort.field == .uploadedAt ? groupByMonthHelp : groupByMonthNeedsDateHelp),
      ])
  }

  // MARK: - The path, pure and testable

  struct Destination: Identifiable, Hashable {
    let entry: SidebarEntry
    var selection: SidebarSelection { entry.selection }
    var label: String { entry.label }
    /// The row's own namespaced identity — the same string the sidebar's
    /// List uses, so the two surfaces cannot fork on identity either.
    var id: String { entry.id }
  }

  struct Component: Identifiable, Hashable {
    /// Stable per value (the selection it represents), never an index.
    let id: String
    let label: String
    let help: String
    /// The exact sidebar entry represented by this component, when it is a
    /// selectable destination. Inert hierarchy labels have no icon.
    let entry: SidebarEntry?
    /// Sibling destinations this segment offers; empty renders inert text.
    let destinations: [Destination]
    /// The selection this component represents, for the checkmark.
    let current: SidebarSelection?
    /// Where a click on a segment without destinations goes; nil leaves it
    /// plain text.
    var target: Target? = nil

    enum Target: Hashable {
      /// A section header: its first place ("Reports" → Overview).
      case selection(SidebarSelection)
      /// Usage's file segment: that file on Usage ▸ Files.
      case usageFile
    }

    static func inert(
      _ id: String, label: String, help: String? = nil, target: Target? = nil
    ) -> Component {
      Component(
        id: id, label: label, help: help ?? label, entry: nil,
        destinations: [], current: nil, target: target)
    }
  }

  /// The rendered path for a model state. The trailing component is the
  /// selected asset; with nothing selected it is absent, not empty.
  ///
  /// The whole path is read out of `SidebarModel.sections` for the current
  /// navigator, so the bar names every destination exactly as the
  /// sidebar does and follows the switcher without knowing anything about
  /// the individual trees. The path is the row's ancestor chain in the
  /// sidebar: the group header it sits under, then one
  /// segment per level — `Library › All Assets`, `Time › 2026 › March`,
  /// `Catalog › blog › 202603` — each level offering its own siblings, the
  /// rows the sidebar shows there (for a key prefix, the same
  /// `folderChildren` cache the sidebar draws from). There is no root
  /// segment above the group header: the sidebar draws none.
  static func components(
    selection: SidebarSelection,
    navigator: SidebarNavigator,
    projects: [ProjectSummary],
    tags: [TagSummary],
    months: [(month: String, count: Int)],
    folderChildren: KeyPrefixChildren,
    catalogRoots: [CatalogRoot] = [],
    labels: [LabelSummary] = [],
    libraryShortcuts: Set<LibraryShortcut> = [],
    projectFolders: ProjectUsageTree = [:],
    usageFileName: String? = nil,
    selectedName: String?
  ) -> [Component] {
    let sections = SidebarModel.sections(
      navigator: navigator, projects: projects, tags: tags, months: months,
      folderChildren: folderChildren, catalogRoots: catalogRoots, labels: labels,
      libraryShortcuts: libraryShortcuts, projectFolders: projectFolders)
    // The section that carries this selection — or, when the summaries have
    // not loaded it yet, the section that carries selections of its kind, so
    // the bar states where it is rather than nothing.
    let owning =
      sections.first { section in
        !chain(to: selection, in: section.entries).isEmpty
      } ?? sections.first { $0.id == fallbackSectionID(for: selection) }
    // A Library-tab shortcut row whose section has
    // since been hidden still reads as its own tab does (`Time › 2025`).
    let home = SidebarModel.navigator(for: selection)
    if owning == nil, home != navigator {
      return components(
        selection: selection, navigator: home, projects: projects, tags: tags, months: months,
        folderChildren: folderChildren, catalogRoots: catalogRoots, labels: labels,
        projectFolders: projectFolders, usageFileName: usageFileName, selectedName: selectedName)
    }

    var path: [Component] = []
    if let owning {
      path.append(
        Component.inert(
          "section:\(owning.id)", label: owning.title,
          help: owning.entries.first.map { "Go to \($0.label)" },
          target: owning.entries.first.map { .selection($0.selection) }))
      let links = chain(to: selection, in: owning.entries)
      if links.isEmpty {
        path.append(
          Component(
            id: "leaf:\(SidebarModel.rowID(for: selection, in: navigator))",
            label: fallbackLabel(selection),
            help: help(forSection: owning.id),
            entry: nil,
            destinations: owning.entries.map(Destination.init(entry:)),
            current: selection))
      }
      for link in links {
        path.append(
          Component(
            id: "leaf:\(link.entry.id)",
            label: link.entry.label,
            help: help(forSection: owning.id),
            entry: link.entry,
            destinations: link.siblings.map(Destination.init(entry:)),
            current: link.entry.selection))
      }
    }
    if selection == .usage, let usageFileName {
      path.append(
        Component.inert(
          "usageFile", label: usageFileName, help: "Show this file in Usage ▸ Files",
          target: .usageFile))
    }
    if let selectedName {
      path.append(
        Component.inert(
          "asset", label: selectedName, help: "The selected asset"))
    }
    return path
  }

  /// The rows from the top of `entries` down to the one that selects
  /// `selection`, each with the siblings it sits among. Empty when no row
  /// selects it.
  private static func chain(
    to selection: SidebarSelection, in entries: [SidebarEntry]
  ) -> [(entry: SidebarEntry, siblings: [SidebarEntry])] {
    for entry in entries {
      if entry.selection == selection { return [(entry, entries)] }
      let below = chain(to: selection, in: entry.children)
      if !below.isEmpty { return [(entry, entries)] + below }
    }
    return []
  }

  private static func fallbackSectionID(for selection: SidebarSelection) -> String {
    switch selection {
    case .all, .recent, .favorites, .archived: return "library"
    case .overview, .orphans, .externals, .usage: return "reports"
    case .project, .projectFolder, .projectFile: return "projects"
    case .tag: return "tags"
    case .label: return "labels"
    case .year, .month: return "time"
    case .keyPrefix, .backend: return "catalog"
    }
  }

  private static func fallbackLabel(_ selection: SidebarSelection) -> String {
    switch selection {
    case .all: return "All Assets"
    case .recent: return "Recent"
    case .favorites: return "Favorites"
    case .archived: return "Archived"
    case .orphans: return "Orphans"
    case .externals: return "Externals"
    case .overview: return "Overview"
    case .project(let slug): return slug
    case .usage: return "Usage"
    case .tag(let name): return name
    case .year(let year): return year
    case .month(let month): return PinaxFormat.monthTitle(month).month
    case .keyPrefix(let prefix, _): return (prefix as NSString).lastPathComponent
    case .backend(let slug): return slug
    case .label(let label): return label.title
    case .projectFolder(_, let directory): return directory.isEmpty ? "/" : directory
    case .projectFile(_, let path): return (path as NSString).lastPathComponent
    }
  }

  private static func help(forSection id: String) -> String {
    switch id {
    case "projects": return "Switch project"
    case "usage": return "Switch usage report"
    case "tags": return "Switch tag"
    case "labels": return "Switch label"
    case "reports": return "Switch report"
    case "time": return "Switch year or month"
    case "catalog": return "Switch folder"
    default: return "Switch library view"
    }
  }
}
