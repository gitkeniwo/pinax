import AppKit
import CatalogCore
import Combine
import Foundation

@MainActor
public final class GalleryModel: ObservableObject {
  /// Moved to the file-level `SidebarSelection` (SidebarModel.swift); the
  /// alias keeps the historical `GalleryModel.SidebarSelection` spelling.
  public typealias SidebarSelection = PinaxUI.SidebarSelection
  /// The searchable scope selection. Backed by `AssetQuery.searchField`,
  /// so each scope is a real query, not a decorative segment.
  public enum SearchScope: String, CaseIterable, Hashable {
    case all
    case filename
    case key
    case note

    public var field: SearchField {
      switch self {
      case .all: return .any
      case .filename: return .filename
      case .key: return .key
      case .note: return .note
      }
    }
  }

  public enum ViewMode: String, CaseIterable, Hashable {
    case grid
    case table
  }

  public enum TimeFilter: Hashable {
    case all
    case last7Days
    case last30Days
    case month(String)

    var label: String {
      switch self {
      case .all: return "All time"
      case .last7Days: return "Last 7 days"
      case .last30Days: return "Last 30 days"
      case let .month(value): return value
      }
    }
  }

  public enum ProjectAdditionAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
  }

  public struct ContextMenuProject: Identifiable, Equatable, Sendable {
    public let slug: String
    public let name: String
    public let isMember: Bool

    public var id: String { slug }
  }

  /// An immutable write target captured from the cell that constructed the
  /// menu. Context-menu writes use `identifier` directly; `rowID` is only for
  /// keeping the gallery selection and inspector aligned with that target.
  ///
  /// `.selection` is the whole multi-selection, produced when the
  /// right-clicked cell is already part of a selection of two or more.
  public enum ContextMenuTarget: Equatable, Sendable {
    case row(ContextMenuRow)
    case selection([Int64])
  }

  public struct ContextMenuRow: Equatable, Sendable {
    public let rowID: Int64
    public let identifier: String
    public let url: String
    public let note: String?
    public let copyFields: CopyFields
    public var isFavorite = false
    public var labels: [AssetLabel] = []
    public var isArchived = false
  }

  /// One colour of the Label submenu: on for every member, off for every
  /// member, or nil when mixed.
  public struct LabelChoice: Identifiable, Equatable, Sendable {
    public let label: AssetLabel
    public let state: Bool?

    public var id: String { label.rawValue }
  }

  public enum SelectionMode: Sendable {
    case replace
    case toggle
    case extend
  }

  /// The grid context menu's model-side contract. Views only render these
  /// cases; tests can therefore prove the menu exists without attempting to
  /// introspect SwiftUI's lazily constructed context-menu hierarchy.
  public enum ContextMenuItem: Identifiable, Equatable, Sendable {
    case copyURL(ContextMenuTarget)
    case copyAs(ContextMenuTarget, [CopyFormat])
    case downloadOriginal(ContextMenuTarget)
    case addTag(ContextMenuTarget)
    case addToProject(ContextMenuTarget, [ContextMenuProject])
    case editNote(ContextMenuTarget)
    /// `isFavorite` is true when every member already is.
    case favorite(ContextMenuTarget, isFavorite: Bool)
    case label(ContextMenuTarget, [LabelChoice])
    /// Archive, or Put Back when every member is archived already.
    case archive(ContextMenuTarget, putBack: Bool)
    /// Archived only; enabled when every member is
    /// archived.
    case deletePermanently(ContextMenuTarget, isEnabled: Bool)

    public var id: String {
      switch self {
      case .copyURL: return "copyURL"
      case .copyAs: return "copyAs"
      case .downloadOriginal: return "downloadOriginal"
      case .addTag: return "addTag"
      case .addToProject: return "addToProject"
      case .editNote: return "editNote"
      case .favorite: return "favorite"
      case .label: return "label"
      case .archive: return "archive"
      case .deletePermanently: return "deletePermanently"
      }
    }
  }

  public struct Row: Identifiable, Sendable {
    public let id: Int64
    public let item: CatalogAssetItem
    public let tags: [String]
    /// Catalog data, never object-store data.
    public var isFavorite: Bool
    public var labels: [AssetLabel]
    /// What Usage adds to a library row — its badges, or
    /// for a table child row the one reference it stands for.
    public var usage: UsageRowInfo?
    /// Usage ▸ Files' cell for an image the file already
    /// used higher up — its caption says "same as above".
    public var repeatsPreviousImage = false
    /// Usage ▸ Images' grid section — the file
    /// this cell sits under, and the image's first line in it.
    public var usageSection: UsageRowSection?

    // What a cell shows, worked out once from `item` (which never changes)
    // so drawing a cell formats nothing.
    /// Where the asset came from, parsed from its meta.
    public let source: AssetSource
    /// The upload day, as the cell's date line writes it.
    public let dayText: String
    /// The upload month, `yyyy-MM`: the grid's month-section key.
    public let monthKey: String
    /// The byte size, as a file size.
    public let sizeText: String
    /// The short file kind ("PNG", "JPEG", …).
    public let formatText: String
    /// "width × height", or nil when the catalog has no dimensions.
    public let dimensionsText: String?

    public init(_ item: CatalogAssetItem) {
      self.init(item, tags: [])
    }

    /// A reference row under an image in Usage's table: the image's item
    /// under an id of its own, outside the asset ids.
    init(reference: UsageReferenceRow, under parent: Row, index: Int) {
      self.id = -(parent.id << 16 | Int64(index + 1))
      self.item = parent.item
      self.source = parent.source
      self.dayText = parent.dayText
      self.monthKey = parent.monthKey
      self.sizeText = parent.sizeText
      self.formatText = parent.formatText
      self.dimensionsText = parent.dimensionsText
      self.tags = []
      self.isFavorite = false
      self.labels = []
      self.usage = .reference(reference)
    }

    /// Usage ▸ Files' second and later reference to an image: the same
    /// item under an id of its own, so both cells exist and select apart.
    init(repeatOf parent: Row, index: Int) {
      self.id = -(parent.id << 32 | Int64(index + 1))
      self.item = parent.item
      self.source = parent.source
      self.dayText = parent.dayText
      self.monthKey = parent.monthKey
      self.sizeText = parent.sizeText
      self.formatText = parent.formatText
      self.dimensionsText = parent.dimensionsText
      self.tags = []
      self.isFavorite = false
      self.labels = []
      self.usage = parent.usage
      self.usageSection = parent.usageSection
      self.repeatsPreviousImage = true
    }

    /// Usage's table children: one row per reference of an image row.
    public var usageChildren: [Row]? {
      guard case let .image(_, _, references) = usage else { return nil }
      return references.enumerated().map { Row(reference: $1, under: self, index: $0) }
    }

    /// `locale` exists for the tests; call sites omit it.
    public init(
      _ item: CatalogAssetItem, tags: [String], isFavorite: Bool = false,
      labels: [AssetLabel] = [], locale: Locale = .current
    ) {
      self.id = item.asset.id ?? 0
      self.item = item
      let asset = item.asset
      self.source = AssetSource.of(meta: asset.meta)
      self.dayText = PinaxFormat.date(asset.uploadedAt, style: .day, locale: locale)
      self.monthKey = String(asset.uploadedAt.prefix(7))
      self.sizeText = asset.byteSize.formatted(.byteCount(style: .file).locale(locale))
      self.formatText = PinaxFormat.shortKind(mime: asset.mime)
      if let width = asset.width, let height = asset.height {
        self.dimensionsText = "\(width) × \(height)"
      } else {
        self.dimensionsText = nil
      }
      self.tags = tags
      self.isFavorite = isFavorite
      self.labels = labels
    }

    public var isArchived: Bool { item.asset.state == AssetState.archived.rawValue }

    static func rows(from page: AssetPage) -> [Row] {
      page.items.map { item in
        let id = item.asset.id ?? 0
        return Row(
          item, tags: page.tagsByAssetID[id] ?? [],
          isFavorite: page.favoriteIDs.contains(id),
          labels: page.labelsByAssetID[id] ?? [])
      }
    }
  }

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  public let catalog: ReadOnlyCatalog
  public let thumbnails: ThumbnailCache
  public let quickLook: QuickLookController
  public let externals: ExternalsModel
  /// Externals' migration and the domain move
  /// share it.
  public let migrationLock: MigrationLock
  /// Flows A and B; nil in a read-only gallery.
  public let domainMigration: DomainMigrationModel?
  /// After a domain move: Settings' Domains list and Projects' Links use
  /// read again (the app sets it).
  public var onDomainsChanged: (() async -> Void)?
  /// The status bar's activity slot, fed by every
  /// background activity below (`wireActivity`), and the window's panel.
  public let activity = ActivityCenter()
  public let activityPanel: ActivityPanelModel
  /// The panel's switch (⇧⌘Y); the window's `@SceneStorage` mirrors it.
  @Published public var isActivityPanelOpen = false {
    didSet { activityPanel.setOpen(isActivityPanelOpen) }
  }
  var activityWiring: Set<AnyCancellable> = []
  /// Which of the two migrations the activity slot shows.
  var migrationSlot = MigrationSlot()
  public let manifestExport: ManifestExportModel?
  public let projectSettings: ProjectSettingsModel?
  /// Present when the gallery was opened writable; nil keeps every editing
  /// affordance out of the UI.
  public let editor: EditableCatalog?
  /// The one path to a permanent delete; nil keeps
  /// Delete Permanently… out of the UI.
  public let deleter: DeletingCatalog?

  // UI inputs. Reloading is driven by the view layer reacting to these
  // values; the setters themselves perform no work, so the model stays
  // deterministic.

  /// The Copy As list, pushed in from `PreferencesStore` by the
  /// shell whenever settings change it.
  @Published public var copyFormats: [CopyFormat] = CopyFormat.factory
  /// The format Edit ▸ Copy (⌘C) uses on the grid,
  /// pushed in alongside `copyFormats`; factory default URL.
  public var defaultCopyFormat: CopyFormat? = CopyFormat.factory.first

  /// Where Download Original saves, pushed in from
  /// `PreferencesStore` like `copyFormats`; the Downloads folder by default.
  public var downloadFolder: URL = OriginalDownloader.defaultFolder
  public var downloader = OriginalDownloader()
  /// Selects the saved files in Finder; replaced in tests.
  public var revealDownloads: ([URL]) -> Void = { urls in
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }
  @Published public private(set) var isDownloading = false
  /// The status bar's right side: progress while a download runs,
  /// then the failure sentence, if any, until the next download starts.
  @Published public private(set) var downloadProgress: String?
  @Published public private(set) var downloadError: String?
  /// The drop zone's upload progress, pushed by the app shell; the
  /// status bar shows it on its right side, beside the download line.
  @Published public var uploadProgress: String?
  /// Scan Now's running count, result or failure, pushed by
  /// the app shell from `UsageSyncModel`; the status bar's right side.
  @Published public var usageScanActivity: UsageScanActivity?
  /// The projects with at least one source folder — which of the reports'
  /// empty-state actions is Scan Now and which goes to Settings.
  @Published public private(set) var sourcedProjects: Set<String> = []
  /// The app's current project, pushed by the shell from
  /// `PreferencesStore`; nil = All Projects. It scopes the Orphans and
  /// Externals reports and nothing else — the sidebar still browses every
  /// asset.
  @Published public var currentProjectSlug: String? {
    didSet {
      guard oldValue != currentProjectSlug else { return }
      externals.selectedProjectSlug = currentProjectSlug
      switch sidebarSelection {
      case .overview, .orphans, .externals, .usage: Task { await reload() }
      default: break
      }
    }
  }
  /// Why Quick Look's current original did not load; the status
  /// bar shows it. Cleared when the next original starts loading.
  @Published public private(set) var quickLookErrorMessage: String?

  /// Which navigator the sidebar shows. Persisted through
  /// `PreferencesStore` by the shell's writeback, like the grid's zoom rung.
  @Published public var navigator: SidebarNavigator {
    didSet {
      guard oldValue != navigator else { return }
      onNavigatorChange?(navigator)
      recordPlace()
    }
  }
  /// Every navigator remembers its own selection, the way Xcode's do. This
  /// dictionary is the storage; `sidebarSelection` below is the read/write
  /// projection of the current navigator's slot, so every existing reader
  /// and writer of the selection keeps working unchanged.
  @Published public var navigatorSelections: [SidebarNavigator: SidebarSelection] {
    didSet {
      recordPlace()
      SwitchTiming.selectionChanged()
    }
  }
  /// The jump bar's ◀ ▶. Every write to the place — the sidebar's
  /// List, the switcher, the jump bar, the menus — lands in `navigator` or
  /// `navigatorSelections`, and both record here, so no writer can forget.
  @Published public private(set) var history: NavigationHistory
  /// Set while one move writes both halves of a place, so the half-way
  /// state is never recorded as a step of its own.
  private var isMovingPlace = false
  /// The current navigator's selection. Not `@Published` itself: the write
  /// goes into `navigatorSelections`, which is, so `objectWillChange` still
  /// fires on every change and no view needs to know about the indirection.
  public var sidebarSelection: SidebarSelection {
    get { navigatorSelections[navigator] ?? .all }
    set {
      // A Library-tab shortcut row (a project, a
      // year) keeps the Library tab and selects the same thing in its own
      // tab too, in one write — the tab does not switch.
      var selections = navigatorSelections
      selections[navigator] = newValue
      let home = SidebarModel.navigator(for: newValue)
      if navigator == .library, home != .library { selections[home] = newValue }
      navigatorSelections = selections
    }
  }
  /// The place the centre column is drawing. The sidebar
  /// highlights `sidebarSelection` the moment it moves; the jump bar, the
  /// title area, the surface and the grid's sections read this, which a
  /// reload moves in the same synchronous step as `rows`, `monthTotals` and
  /// the counts — so no frame draws the new place's layout over the old
  /// place's rows. An asset reload moves it when its rows arrive (a
  /// superseded or failed one never does); a report surface, which shows
  /// its own loading state, when its reload starts.
  @Published public private(set) var shownPlace: NavigationHistory.Place {
    didSet { groupingModeMayHaveChanged() }
  }
  public var shownSelection: SidebarSelection { shownPlace.selection }
  /// A switch past this long without its rows shows the status
  /// bar's spinner; before it the old place stays, unmarked.
  static let slowSwitchDelay: Duration = .milliseconds(300)
  /// An asset reload is waiting for its rows; `isSlowToShow` once it has
  /// waited `slowSwitchDelay`.
  @Published public private(set) var isAwaitingRows = false
  @Published public private(set) var isSlowToShow = false
  /// The status bar's spinner: paging and the reports at once, a reload
  /// only once it is slow.
  public var showsLoadingActivity: Bool {
    isLoadingPage && (!isAwaitingRows || isSlowToShow)
  }
  /// The surface's empty state. Once a place has been drawn, a
  /// reload keeps an empty one up until the new rows arrive; only
  /// the first load, with nothing drawn yet, shows a blank grid instead.
  public var showsEmptyAssets: Bool {
    rows.isEmpty && (!isLoadingPage || hasShownAssets)
  }
  private var hasShownAssets = false
  @Published public var searchText: String = ""
  @Published public var searchScope: SearchScope = .all
  /// The find strip's Source popup. Nil is All Sources;
  /// otherwise one `AssetSource`, the source classification as
  /// `AssetQuery.sources`. Stacks with the search text and its scope.
  /// All five sources, and the toolbar's sort
  /// menu writes this same value from its Show section.
  @Published public var sourceFilter: AssetSource?
  /// What each Source popup item counts: the sidebar selection with the
  /// search, time and source filters stripped — the basis of "M".
  @Published public private(set) var sourceCounts = SourceCounts()

  public struct SourceCounts: Equatable, Sendable {
    public var all = 0
    public var pinax = 0
    public var picgo = 0
    public var bucket = 0
    public var migrated = 0
    public var otherImport = 0

    public init(
      all: Int = 0, pinax: Int = 0, picgo: Int = 0, bucket: Int = 0,
      migrated: Int = 0, otherImport: Int = 0
    ) {
      self.all = all
      self.pinax = pinax
      self.picgo = picgo
      self.bucket = bucket
      self.migrated = migrated
      self.otherImport = otherImport
    }

    public subscript(source: AssetSource) -> Int {
      get {
        switch source {
        case .pinax: return pinax
        case .picgo: return picgo
        case .bucket: return bucket
        case .migrated: return migrated
        case .otherImport: return otherImport
        }
      }
      set {
        switch source {
        case .pinax: pinax = newValue
        case .picgo: picgo = newValue
        case .bucket: bucket = newValue
        case .migrated: migrated = newValue
        case .otherImport: otherImport = newValue
        }
      }
    }
  }
  /// The find strip's match controls. Both feed
  /// `AssetQuery` and the reload token — a mode change is a new result set,
  /// not a chrome-only change.
  @Published public var searchMatch: SearchMatch = .contains
  @Published public var searchCaseSensitive = false
  /// Kept for the query path, but no UI writes it: time is chosen in the Time
  /// navigator, not filtered on top.
  @Published public var timeFilter: TimeFilter = .all
  @Published public var viewMode: ViewMode = .grid {
    // Usage ▸ Images' grid is cut by file, its table by
    // image; the rows follow the mode with no reload.
    didSet {
      guard oldValue != viewMode else { return }
      groupingModeMayHaveChanged()
      showUsageImages()
    }
  }
  /// The asset order, a query input (`makeQuery`, the reload
  /// token). The jump bar's sort menu and the table's column headers write
  /// it; the shell mirrors it with `PreferencesStore.gallerySort`, which
  /// View ▸ Sort By writes and the next launch reads.
  @Published public var sort: AssetSort {
    didSet {
      guard oldValue != sort else { return }
      onSortChange?(sort)
    }
  }
  @Published public var gridOverlays: GridOverlayOptions {
    didSet {
      guard oldValue != gridOverlays else { return }
      onGridOverlaysChange?(gridOverlays)
    }
  }
  @Published public var gridThumbnailSizing: GridThumbnailSizing {
    didSet {
      guard oldValue != gridThumbnailSizing else { return }
      onGridThumbnailSizingChange?(gridThumbnailSizing)
    }
  }
  /// The grid's zoom rung: a column count on
  /// `GridZoom.columns`, moved only by `zoomIn()`/`zoomOut()`. Pure view
  /// state — it is not an input to `makeQuery`, and a property test
  /// pins the consequence: stepping the whole ladder fires no query and
  /// leaves the selection alone.
  @Published public private(set) var gridColumns: Int {
    didSet {
      guard oldValue != gridColumns else { return }
      onGridColumnsChange?(gridColumns)
    }
  }

  /// The table's row height, a rung on
  /// `DesignMetrics.table.rowHeights` — the table's counterpart of
  /// `gridColumns`, persisted on its own. View state, not a query input.
  @Published public private(set) var tableRowHeight: CGFloat {
    didSet {
      guard oldValue != tableRowHeight else { return }
      onTableRowHeightChange?(tableRowHeight)
    }
  }

  /// The shell's writeback into `PreferencesStore`; nil keeps the
  /// model standalone-usable, like the store's own hooks.
  public var onGridColumnsChange: ((Int) -> Void)?
  public var onTableRowHeightChange: ((CGFloat) -> Void)?
  /// The No Assets state's Upload…: the shell's File → New Upload….
  public var onRequestUpload: (() -> Void)?
  /// The No Assets state's Restore from Backup…, shown
  /// only while the catalog is empty — the shell pushes both in.
  @Published public var showsCatalogRestore = false
  public var onRequestRestore: (() async -> Void)?
  /// The reports' Scan Now — `UsageSyncModel.scanNow` as the
  /// shell installs it, presented in the main window.
  public var onScanNow: (([String]) -> Void)?
  /// Add Source… and Open Project Settings…: Settings ▸ Projects with this
  /// project selected. The view opens the window; this selects the page.
  public var onOpenProjectSettings: ((String) -> Void)?
  public var onNavigatorChange: ((SidebarNavigator) -> Void)?
  public var onGridOverlaysChange: ((GridOverlayOptions) -> Void)?
  public var onGridThumbnailSizingChange: ((GridThumbnailSizing) -> Void)?
  public var onGroupsByMonthChange: ((Bool) -> Void)?
  /// The header menu's Hide / Show Section,
  /// written back to the one store Settings ▸ Appearance writes too.
  public var onLibraryShortcutsChange: ((Set<LibraryShortcut>) -> Void)?
  public var onSortChange: ((AssetSort) -> Void)?
  /// Menu-command view state. `isSidebarVisible` maps onto the split
  /// view's column visibility in the view layer, so this model needs no
  /// SwiftUI types. `isSearchPresented` drives the macOS 14+ searchable
  /// presentation binding used by Navigate ▸ Focus Search.
  @Published public var isSidebarVisible = true
  /// Collapsed at launch: the inspector is
  /// for one asset, and a launch shows none. Not persisted — "collapsed
  /// when the app opens" is the whole rule, so the state is
  /// view state like `isSearchPresented`, not a preference.
  @Published public var showsInspector = false
  @Published public var isSearchPresented = false

  // MARK: - The project picker

  /// The title area's popover. Opening it clears the Find text and puts
  /// the highlight on the first row — the current project.
  @Published public var isProjectPickerPresented = false {
    didSet {
      guard isProjectPickerPresented, !oldValue else { return }
      projectPickerQuery = ""
      projectPickerHighlight = projectPickerSections.rows.first?.id
    }
  }
  /// The picker's Find text; a change moves the highlight to the first
  /// row still shown.
  @Published public var projectPickerQuery = "" {
    didSet {
      guard oldValue != projectPickerQuery else { return }
      projectPickerHighlight = projectPickerSections.rows.first?.id
    }
  }
  /// The row ↑ ↓ move to and Return chooses (`ProjectPickerRow.id`).
  @Published public private(set) var projectPickerHighlight: String?
  /// Choosing a row: the shell writes the app's one current project.
  public var onChooseProject: ((String?) -> Void)?
  /// New Project… and Manage Projects…: Settings ▸ Projects, the first
  /// straight into adding one. The view opens the window.
  public var onNewProject: (() -> Void)?
  public var onManageProjects: (() -> Void)?
  var projectPickerNow: () -> Date = Date.init

  var projectPickerSections: ProjectPickerSections {
    ProjectPicker.sections(
      projects: projects, sourced: sourcedProjects, current: currentProjectSlug,
      query: projectPickerQuery, now: projectPickerNow())
  }

  /// ↑ / ↓: the next shown row, stopping at either end.
  func moveProjectPickerHighlight(by delta: Int) {
    let rows = projectPickerSections.rows
    guard !rows.isEmpty else { return }
    let index = rows.firstIndex { $0.id == projectPickerHighlight } ?? (delta > 0 ? -1 : rows.count)
    projectPickerHighlight = rows[min(max(index + delta, 0), rows.count - 1)].id
  }

  /// The pointer entered a row: the highlight follows it, as in a menu.
  func highlightProjectPickerRow(_ id: String) {
    projectPickerHighlight = id
  }

  /// A row clicked, or Return: that project becomes current and the
  /// popover closes.
  func chooseProject(_ slug: String?) {
    isProjectPickerPresented = false
    onChooseProject?(slug)
  }

  func chooseHighlightedProject() {
    guard let row = projectPickerSections.rows.first(where: { $0.id == projectPickerHighlight })
    else { return }
    chooseProject(row.slug)
  }

  /// A project row's ⋯ menu: Scan Now (that project, when it has sources)
  /// and Project Settings… (Settings ▸ Projects on it).
  func projectRowMenu(for slug: String) -> ProjectRowMenu {
    ProjectRowMenu(items: [
      .init(
        title: "Scan Now",
        isEnabled: onScanNow != nil && sourcedProjects.contains(slug),
        opensSettings: false,
        action: { [weak self] in
          self?.isProjectPickerPresented = false
          self?.onScanNow?([slug])
        }),
      .init(
        title: "Project Settings…", isEnabled: true, opensSettings: true,
        action: { [weak self] in
          self?.isProjectPickerPresented = false
          self?.onOpenProjectSettings?(slug)
        }),
    ])
  }

  /// New Project… and Manage Projects… below the rows.
  func projectPickerFooter() -> ProjectRowMenu {
    ProjectRowMenu(items: [
      .init(
        title: "New Project…", isEnabled: true, opensSettings: true,
        action: { [weak self] in
          self?.isProjectPickerPresented = false
          self?.onNewProject?()
        }),
      .init(
        title: "Manage Projects…", isEnabled: true, opensSettings: true,
        action: { [weak self] in
          self?.isProjectPickerPresented = false
          self?.onManageProjects?()
        }),
    ])
  }

  @Published public private(set) var rows: [Row] = [] {
    didSet { rowsDidChange(from: oldValue) }
  }

  /// The Library tab's shown shortcut sections.
  /// Mirrored both ways with `PreferencesStore.libraryShortcuts` by the
  /// shell, like the grid overlays.
  @Published public var libraryShortcuts: Set<LibraryShortcut> {
    didSet {
      guard oldValue != libraryShortcuts else { return }
      onLibraryShortcutsChange?(libraryShortcuts)
    }
  }

  /// Hide Section and Show Section ›.
  public func setLibraryShortcut(_ shortcut: LibraryShortcut, shown: Bool) {
    if shown {
      libraryShortcuts.insert(shortcut)
    } else {
      libraryShortcuts.remove(shortcut)
    }
  }

  /// The jump bar's month-grouping switch: a preference, on by
  /// default, persisted through `PreferencesStore` like the zoom rung.
  @Published public var groupsByMonth: Bool {
    didSet {
      guard oldValue != groupsByMonth else { return }
      onGroupsByMonthChange?(groupsByMonth)
    }
  }

  /// Whether the grid shows month sections: Library's All
  /// and Recent, and a year in the Time navigator, while the switch is on —
  /// and only in upload-date order: any other order scatters a
  /// month across the grid.
  public var groupsRowsByMonth: Bool {
    groupsByMonth && isMonthGroupable && sort.field == .uploadedAt
  }

  /// `groupsRowsByMonth` for the place being drawn: what the grid,
  /// the table and the keyboard cut `rows` by, so the sections change in
  /// the same step as the rows they cut.
  public var showsRowsByMonth: Bool {
    groupsByMonth && Self.isMonthGroupable(shownPlace) && sort.field == .uploadedAt
  }

  /// Usage ▸ Images' grid is cut into one section
  /// per referencing file, its header pinned like a month's.
  public var showsUsageFileSections: Bool {
    shownSelection == .usage && usagePage == .images && viewMode == .grid
  }

  /// Whether the grid draws sections — months, or Usage's files.
  public var showsRowSections: Bool { showsRowsByMonth || showsUsageFileSections }

  /// The groupable views. A month is one section already; Collections
  /// and the Catalog tree do not group. The month totals are fetched for
  /// these whether or not the switch is on, so turning it on is a view
  /// change with correct header counts, not a reload.
  public var isMonthGroupable: Bool {
    Self.isMonthGroupable(.init(navigator, sidebarSelection))
  }

  static func isMonthGroupable(_ place: NavigationHistory.Place) -> Bool {
    switch (place.navigator, place.selection) {
    // A year from the Library tab's Time shortcut
    // groups as the Time tab's does.
    case (.library, .all), (.library, .recent), (.time, .year), (.library, .year): return true
    default: return false
    }
  }

  /// `rows` cut into month sections on the client. Grouping only
  /// happens in upload-date order, so each month is one contiguous run and the cut
  /// is a single pass — the query and the paging sentinel do not change.
  /// The month key is `uploadedAt`'s first seven characters, the same
  /// `yyyy-MM` that `availableMonths` groups by.
  /// A month header's number: the query's total for that month, never the
  /// rows paged in so far. `loaded` stands in only for a
  /// month the totals have not seen — a row that arrived after the reload.
  public func monthHeaderCount(_ month: String, loaded: Int) -> Int {
    monthTotals[month] ?? loaded
  }

  /// Stored, not computed on each read: cut again whenever `rows` or
  /// the cut's mode (`showsUsageFileSections`) changes, in the same
  /// synchronous step, so a reader never sees a stale cut. It needs no
  /// publisher of its own — every change to it comes with one to `rows`,
  /// `shownPlace`, `usagePage` or `viewMode`.
  public private(set) var groupedRows: [(month: String, rows: [Row])] = []
  /// Whether `groupedRows` was cut by Usage file (else by month).
  private var groupedRowsByFile = false
  /// How many times `groupedRows` has been cut from scratch — the tests'
  /// proof that a change outside the cut does not redo it.
  private(set) var groupedRowsCutCount = 0

  static func groupKey(_ row: Row, byFile: Bool) -> String {
    // Usage ▸ Images cuts by file instead (the key is the file's id).
    byFile ? row.usageSection?.fileID ?? "" : row.monthKey
  }

  private func cutGroupedRows() {
    groupedRowsCutCount += 1
    let byFile = showsUsageFileSections
    groupedRowsByFile = byFile
    var groups: [(month: String, rows: [Row])] = []
    for row in rows {
      let key = Self.groupKey(row, byFile: byFile)
      if groups.last?.month == key {
        groups[groups.count - 1].rows.append(row)
      } else {
        groups.append((key, [row]))
      }
    }
    groupedRows = groups
  }

  /// The cut's mode inputs changed: cut again only if the mode did.
  private func groupingModeMayHaveChanged() {
    if showsUsageFileSections != groupedRowsByFile { cutGroupedRows() }
  }

  /// A change that keeps every row in place under the same key — a
  /// favourite, a label — swaps the new rows into the existing sections
  /// instead of cutting again.
  private func rowsDidChange(from old: [Row]) {
    let byFile = groupedRowsByFile
    guard byFile == showsUsageFileSections, old.count == rows.count,
      zip(old, rows).allSatisfy({
        $0.id == $1.id && Self.groupKey($0, byFile: byFile) == Self.groupKey($1, byFile: byFile)
      })
    else { return cutGroupedRows() }
    var offset = 0
    for index in groupedRows.indices {
      let count = groupedRows[index].rows.count
      groupedRows[index].rows = Array(rows[offset..<offset + count])
      offset += count
    }
  }
  /// The status bar's counts, refreshed on the same reload
  /// as `rows` so the bar can never describe a stale surface. `totalCount`
  /// is the current query — filters included, limit excluded.
  /// `unfilteredTotalCount` is the same sidebar selection with the search
  /// and time filters stripped, so the bar can say "1 of 3" honestly; nil
  /// when no filter is active (it would equal `totalCount`). Both nil on
  /// the report surfaces — those show their own numbers — and left at
  /// their previous value while a reload is in flight, so the count line
  /// never flickers between states.
  @Published public private(set) var totalCount: Int?
  @Published public private(set) var unfilteredTotalCount: Int?
  @Published public private(set) var tags: [TagSummary] = []
  /// The colour labels in use on active assets, for Collections ▸ Labels.
  @Published public private(set) var labels: [LabelSummary] = []
  @Published public private(set) var projects: [ProjectSummary] = []
  @Published public private(set) var projectAdditionMessage: String?
  /// Every month in the catalog, for the sidebar's Time tree only.
  @Published public private(set) var availableMonths: [(month: String, count: Int)] = []
  /// The grouped grid's month header counts: the
  /// current query's total per `yyyy-MM`, fetched with `rows` on a reload
  /// and left alone by paging, so a header never grows as pages arrive.
  @Published public private(set) var monthTotals: [String: Int] = [:]
  /// The Catalog tree's loaded levels: the root at
  /// `loadInitialData`, every other prefix the first time its row opens.
  /// Each prefix is fetched once per state of the catalog — counted by
  /// `folderChildrenFetchCount` — and every loaded level is fetched again
  /// once when `changeStamp` moves.
  @Published public private(set) var folderChildren: KeyPrefixChildren = [:]
  /// Real `keyPrefixChildren` queries issued, for the cache property test.
  private(set) var folderChildrenFetchCount = 0
  private var folderChildrenInFlight: Set<KeyPrefixLevel> = []
  /// Every backend with its domains — the
  /// Catalog roots and the Usage domain menu read it.
  @Published public private(set) var domainBackends: [DomainBackend] = []
  /// The catalog's `changeStamp` when `folderChildren` was last known good.
  private var folderChildrenStamp: String?
  @Published public private(set) var isLoadingPage = false
  @Published public private(set) var canLoadMore = false
  @Published public private(set) var errorMessage: String?

  /// Orphan-view state (read-only). `orphanHealth` is derived at
  /// load time so the caveat header can name every project whose scan history
  /// is missing or thin.
  @Published public private(set) var orphanReport: OrphanReport?
  @Published public private(set) var orphanHealth: [OrphanScanHealth] = []
  /// Whether the orphan grid's "Not yet scanned (N)" group is open.
  /// Collapsed by default; view state, not persisted.
  @Published public var showsNotYetScannedOrphans = false

  /// Usage: the current project's live references, by
  /// image or by file. Images are `rows` themselves — the library's grid
  /// and table over them, its selection and ⌘C; Files puts the selected
  /// file's images there.
  /// Files is the page Usage opens on.
  @Published public var usagePage: UsagePage = .files {
    didSet {
      guard oldValue != usagePage else { return }
      groupingModeMayHaveChanged()
      reloadUsageIfShown()
    }
  }
  /// Only the references on an old domain.
  /// The Overview's numbers for the current project; nil
  /// until the first read lands.
  @Published public private(set) var overviewStats: CatalogStats?
  @Published public private(set) var overviewError: String?
  /// Week | Month | Year and how far back; the heat map fades the rest.
  @Published public var overviewPeriod = OverviewPeriod()
  /// The heat-map day under the pointer: its line replaces the card's right end.
  @Published public var overviewHoveredDay: Date?
  /// The Overview's "now" and calendar — the system's in the app, fixed in
  /// the tests. Weeks start on `overviewCalendar.firstWeekday`.
  var overviewNow: () -> Date = Date.init
  var overviewCalendar: Calendar = .autoupdatingCurrent

  /// Everything the Overview draws, for the period chosen; nil before the
  /// first read.
  public var overview: OverviewModel? {
    overviewStats.map {
      OverviewModel(
        stats: $0, period: overviewPeriod, now: overviewNow(), calendar: overviewCalendar)
    }
  }

  /// A heat-map day or an Uploads bar: the Time navigator's month holding
  /// it. Months are the navigator's own (`availableMonths`); a month with
  /// no uploads has no row, so the click does nothing.
  public func openOverviewDay(_ day: Date) {
    let parts = overviewCalendar.dateComponents([.year, .month], from: day)
    guard let year = parts.year, let month = parts.month else { return }
    let key = String(format: "%04d-%02d", year, month)
    guard availableMonths.contains(where: { $0.month == key }) else { return }
    select(.month(key), in: .time)
  }

  /// A card's click: Library ▸ Favorites / Archived, Usage,
  /// Orphans, Externals ▸ Your Domains, Usage on Old Domains.
  public func openOverview(_ destination: OverviewModel.Destination) {
    switch destination {
    case .favorites: select(.favorites, in: .library)
    case .archived: select(.archived, in: .library)
    case .usage:
      usageOldDomainsOnly = false
      select(.usage, in: .reports)
    case .orphans: select(.orphans, in: .reports)
    case .yourDomains:
      externals.domain = .yours
      select(.externals, in: .reports)
    case .oldDomains:
      usageOldDomainsOnly = true
      select(.usage, in: .reports)
    }
  }

  /// A Tags row: Collections ▸ that tag.
  public func openOverviewTag(_ name: String) {
    select(.tag(name), in: .collections)
  }

  /// A number in Usage by Project: that project becomes the current one —
  /// a deliberate side effect — and the report behind the number opens.
  public func openOverviewProject(_ slug: String, _ column: OverviewModel.ProjectColumn) {
    onChooseProject?(slug)
    switch column {
    case .used: openOverview(.usage)
    case .orphanCandidates: openOverview(.orphans)
    case .yourDomains: openOverview(.yourDomains)
    case .otherDomains:
      externals.domain = .other
      select(.externals, in: .reports)
    }
  }

  /// ‹ and ›: one period back or forward, never past the one holding now.
  public func moveOverviewPeriod(by step: Int) {
    overviewPeriod.offset = min(0, overviewPeriod.offset + step)
  }

  /// Week | Month | Year: a new kind starts at the current period.
  public func setOverviewPeriodKind(_ kind: OverviewPeriod.Kind) {
    overviewPeriod = OverviewPeriod(kind: kind)
  }

  @Published public var usageOldDomainsOnly = false {
    didSet {
      guard oldValue != usageOldDomainsOnly else { return }
      if usageOldDomainsOnly { usageDomain = nil }
      reloadUsageIfShown()
    }
  }
  /// The Usage domain menu's choice, a prefix;
  /// nil is All Domains. Choosing one ends the Overview's Old Domains
  /// filter, and the other way round.
  @Published public var usageDomain: String? {
    didSet {
      guard oldValue != usageDomain else { return }
      if usageDomain != nil { usageOldDomainsOnly = false }
      reloadUsageIfShown()
    }
  }
  @Published public private(set) var usageBrowser: UsageBrowser?
  /// The domain menu's figures, by prefix — the
  /// scope's links in the latest scans, in the catalog or not.
  @Published public private(set) var usageDomainLinks: [String: Int] = [:]
  /// Usage's Open Backends Settings (the app sets it).
  public var onOpenBackendSettings: ((String) -> Void)?

  /// One domain of the Usage menu.
  public struct UsageDomainItem: Identifiable, Equatable, Sendable {
    public let backend: String
    public let prefix: String
    public let isCurrent: Bool
    /// The scope's links under it, in the catalog or not.
    public let links: Int
    public var id: String { prefix }
    public var host: String { DomainHost.host(prefix) }
    public var isUnused: Bool { links == 0 }
  }

  /// The menu: a section per backend, Current first.
  public var usageDomainSections: [(backend: String, items: [UsageDomainItem])] {
    domainBackends.map { backend in
      (
        backend.slug,
        backend.prefixes.map { prefix in
          UsageDomainItem(
            backend: backend.slug, prefix: prefix, isCurrent: prefix == backend.current,
            links: usageDomainLinks[prefix] ?? 0)
        }
      )
    }
  }

  /// The chosen domain's item; nil on All Domains.
  public var usageDomainItem: UsageDomainItem? {
    guard let usageDomain else { return nil }
    return usageDomainSections.lazy.flatMap(\.items).first { $0.prefix == usageDomain }
  }

  /// All Domains' figure: the scope's references.
  public var usageAllDomainsLinks: Int { usageBrowser?.usage.references.count ?? 0 }

  /// Move N Links to Current… in the bar: an Old domain with links.
  public var usageMoveTitle: String? {
    guard let item = usageDomainItem, !item.isCurrent, item.links > 0, domainMigration != nil else { return nil }
    return "Move \(PinaxFormat.count(item.links, singular: "Link")) to Current…"
  }

  public func moveUsageDomainToCurrent() {
    guard let item = usageDomainItem, !item.isCurrent, let domain = domainMigration, !migrationLock.isBusy else {
      return
    }
    Task { await domain.beginMoveToCurrent(backend: item.backend, oldDomain: item.prefix, links: item.links) }
  }
  /// Files: the file whose images fill `rows`.
  @Published public var usageSelectedFileID: UsageFile.ID? {
    didSet { if oldValue != usageSelectedFileID { showUsageFileImages() } }
  }
  /// The file list's order — Images' sections
  /// follow it too. View state, not persisted.
  @Published public var usageFileSort = UsageFileSort.standard {
    didSet { if oldValue != usageFileSort { showUsageImages() } }
  }
  /// The referencing files' dates on disk, read on each Usage reload.
  @Published public private(set) var usageFileDates: [UsageFile.ID: UsageFileDates] = [:]
  /// How a file's dates are read: the file system in the app, a table in
  /// the tests.
  var usageFileDateReader: (URL) -> UsageFileDates = UsageFileDates.read
  /// The folder the file list is narrowed to (a group header's segment);
  /// nil is every file in scope.
  @Published public var usageFolderScope: UsageFolderScope? {
    didSet { if oldValue != usageFolderScope { keepUsageFileSelectionVisible() } }
  }
  /// The list's collapsed groups, by `UsageFileListGroup.id`.
  @Published public var usageCollapsedGroups: Set<String> = []
  /// "Group by Folder": off, the list is the files alone.
  @Published public var usageGroupsByFolder = true {
    didSet {
      guard oldValue != usageGroupsByFolder else { return }
      keepUsageFileSelectionVisible()
      showUsageImages()
    }
  }
  /// The file list's width; its divider drags it. View state, not
  /// persisted.
  @Published public var usageFilesListWidth: CGFloat = DesignMetrics.usage.filesWidth
  /// Images ▸ Table: the image rows showing their references.
  @Published public var usageExpandedIDs: Set<Int64> = []
  /// The inspector's Used In for the single selection, across every
  /// project; nil with nothing, or more than one, selected.
  @Published public private(set) var usedIn: UsedInState?

  /// The selection is a set; `selectionAnchor` is the
  /// fixed end of a ⇧ range and moves only on `.replace` / `.toggle`.
  /// Deliberately not a query input: `GalleryView.reloadToken` never reads it.
  @Published public var selectedIDs: Set<Int64> = [] {
    didSet {
      Task { await loadDetails() }
      guard Self.single(oldValue) != selectedID else { return }
      let entries = quickLookEntries
      quickLook.selectionDidChange(to: entries?.items ?? [], at: entries?.index)
    }
  }
  @Published public private(set) var selectionAnchor: Int64?
  /// Where the keyboard stands: the row the last click or arrow
  /// reached. ⇧-arrows move it while the anchor stays put.
  public private(set) var selectionCursor: Int64?

  /// Read-only derivation: the one selected id when exactly one row is
  /// selected, otherwise nil. Every single-item path — inspector details,
  /// Copy URL, Quick Look — keeps reading this and nothing else.
  public var selectedID: Int64? { Self.single(selectedIDs) }

  private static func single(_ ids: Set<Int64>) -> Int64? {
    ids.count == 1 ? ids.first : nil
  }
  @Published public private(set) var selectedDetails: CatalogAssetDetails?
  /// Draft text for the inspector's note editor; committed explicitly via
  /// `saveNote()`. Repopulated whenever details load.
  @Published public var noteDraft: String = ""
  @Published public private(set) var isSavingEdit = false

  private var nextCursor: AssetCursor?
  private var generation = 0
  private var detailsGeneration = 0
  /// The asset whose stored note currently backs `noteDraft`; used to avoid
  /// clobbering an in-progress draft when unrelated edits refresh details.
  private var noteDraftOwner: String?
  private struct ContextMenuMetadata {
    let memberSlugs: Set<String>
    let note: String?
  }

  /// Per-cell metadata loaded independently of selection. Context menus are
  /// constructed for unselected rows, so membership must never be inferred
  /// from `selectedDetails`.
  @Published private var contextMenuMetadata: [String: ContextMenuMetadata] = [:]

  public init(
    catalog: ReadOnlyCatalog,
    editor: EditableCatalog? = nil,
    deleter: DeletingCatalog? = nil,
    thumbnails: ThumbnailCache,
    quickLook: QuickLookController? = nil,
    externalReader: ExternalUsageReading? = nil,
    externalsClaimer: ExternalsClaiming? = nil,
    externalsMigrator: ExternalsMigrating? = nil,
    domainMigrator: DomainMigrating? = nil,
    manifestExport: ManifestExportModel? = nil,
    projectSettings: ProjectSettingsModel? = nil,
    gridOverlays: GridOverlayOptions = GridOverlayOptions(),
    gridThumbnailSizing: GridThumbnailSizing = .fillGrid,
    gridColumns: Int = GridZoom.defaultColumns,
    tableRowHeight: CGFloat = DesignMetrics.table.defaultRowHeight,
    groupsByMonth: Bool = true,
    libraryShortcuts: Set<LibraryShortcut> = LibraryShortcut.defaultShown,
    sort: AssetSort = AssetSort(),
    navigator: SidebarNavigator = .library,
    externalsSort: ExternalSort = ExternalSort(),
    externalsGroupsByFile: Bool = false,
    externalsTipDismissed: Bool = false
  ) {
    self.catalog = catalog
    self.editor = editor
    self.deleter = deleter
    self.thumbnails = thumbnails
    self.quickLook = quickLook ?? QuickLookController(thumbnails: thumbnails)
    let lock = MigrationLock()
    self.migrationLock = lock
    self.externals = ExternalsModel(
      reader: externalReader ?? catalog, thumbnails: thumbnails, claimer: externalsClaimer,
      migrator: externalsMigrator, sort: externalsSort, groupsByFile: externalsGroupsByFile,
      isTipDismissed: externalsTipDismissed, migrationLock: lock)
    self.domainMigration = domainMigrator.map { DomainMigrationModel(migrator: $0, lock: lock) }
    self.activityPanel = ActivityPanelModel(reader: catalog)
    // A migration preview's Show Changes… in the panel.
    if let externalsMigrator {
      self.activityPanel.diff = { try await externalsMigrator.diff(ofRun: $0) }
    }
    // Rewrite and domain_migrate previews too.
    if let domainMigrator {
      self.activityPanel.rewriteDiff = { try await domainMigrator.diff(ofRun: $0) }
    }
    self.manifestExport = manifestExport
    self.projectSettings = projectSettings
    self.gridOverlays = gridOverlays
    self.gridThumbnailSizing = gridThumbnailSizing
    _gridColumns = Published(
      wrappedValue: GridZoom.columns.contains(gridColumns)
        ? gridColumns : GridZoom.defaultColumns)
    _tableRowHeight = Published(
      wrappedValue: DesignMetrics.table.rowHeights.contains(tableRowHeight)
        ? tableRowHeight : DesignMetrics.table.defaultRowHeight)
    _groupsByMonth = Published(wrappedValue: groupsByMonth)
    _libraryShortcuts = Published(wrappedValue: libraryShortcuts)
    _sort = Published(wrappedValue: sort)
    _navigator = Published(wrappedValue: navigator)
    let selections = Self.defaultNavigatorSelections()
    _navigatorSelections = Published(wrappedValue: selections)
    _shownPlace = Published(wrappedValue: .init(navigator, selections[navigator] ?? .all))
    _history = Published(
      wrappedValue: NavigationHistory(
        start: .init(navigator, selections[navigator] ?? .all)))
    // Show in Usage, a same image's Show in Library, and the
    // gallery's own reads after a batch (the library gained assets).
    externals.onShowInUsage = { [weak self] in self?.showImportedInUsage() }
    externals.onShowInLibrary = { [weak self] key in await self?.showInLibrary(key: key) }
    externals.onImportFinished = { [weak self] in await self?.reloadAfterExternalsImport() }
    // The panel reads the run as it grows; an apply added assets.
    externals.onMigrationProgress = { [weak self] in
      guard let panel = self?.activityPanel else { return }
      Task { await panel.refresh() }
    }
    externals.onMigrationFinished = { [weak self] in await self?.reloadAfterExternalsImport() }
    wireDomainMigration()
    wireActivity()
    projectSettings?.onAdditionCommitted = { [weak self] _, created in
      guard let self else { return }
      await self.refreshProjects()
      // Projects live in the collections navigator, so revealing the new
      // one means going there — writing it into whichever navigator
      // happened to be showing would put a project row in the library tree.
      self.select(.project(created.slug), in: .collections)
    }
  }

  public var exportableProjectSlug: String? {
    guard case let .project(slug) = sidebarSelection else { return nil }
    return slug
  }

  public var sidebarSections: [SidebarSection] {
    SidebarModel.sections(
      navigator: navigator, projects: projects, tags: tags, months: availableMonths,
      folderChildren: folderChildren, catalogRoots: domainBackends.map(CatalogRoot.init), labels: labels,
      unfinishedDeletions: unfinishedDeletions.count, libraryShortcuts: libraryShortcuts,
      projectFolders: projectFolders)
  }

  /// The opened project rows' source folders and
  /// files, by slug, from each project's live usage — fetched the first
  /// time the row opens, again when the catalog changes.
  @Published public private(set) var projectFolders: ProjectUsageTree = [:]
  /// The live usage those rows were cut from: the folder and file rows'
  /// grid comes from its assets, with no further query.
  private(set) var projectUsage: [String: UsageBrowser] = [:]
  /// Real `liveUsage` reads issued for project rows, for the lazy-load test.
  private(set) var projectUsageFetchCount = 0
  private var projectUsageInFlight: Set<String> = []

  /// Loads `slug`'s folders unless they are loaded or on their way.
  public func loadProjectFolders(_ slug: String) async {
    guard projectUsage[slug] == nil, !projectUsageInFlight.contains(slug) else { return }
    await fetchProjectUsage(slug)
  }

  private func fetchProjectUsage(_ slug: String) async {
    projectUsageInFlight.insert(slug)
    defer { projectUsageInFlight.remove(slug) }
    projectUsageFetchCount += 1
    do {
      let browser = UsageBrowser(try await catalog.liveUsage(project: slug))
      projectUsage[slug] = browser
      projectFolders[slug] = ProjectUsageFolder.folders(of: slug, in: browser)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// A folder or file row's images: each distinct one once, in the order
  /// the file list first uses it.
  private func reloadProjectSourceRows() async {
    let slug: String
    let matches: (UsageFile) -> Bool
    switch sidebarSelection {
    case let .projectFolder(project, directory):
      slug = project
      matches = { $0.directory == directory }
    case let .projectFile(project, path):
      slug = project
      matches = { $0.path == path }
    default:
      return
    }
    generation += 1
    let currentGeneration = generation
    if projectUsage[slug] == nil { await loadProjectFolders(slug) }
    guard generation == currentGeneration else { return }
    let browser = projectUsage[slug]
    let files = (browser?.files ?? [])
      .filter { $0.projectSlug == slug && matches($0) }
      .sorted { $0.path < $1.path }
    var seen: Set<Int64> = []
    let loadedRows = files.flatMap(\.images).compactMap { image -> Row? in
      guard seen.insert(image.assetID).inserted,
        let item = browser?.usage.assets[image.assetID]
      else { return nil }
      return Row(item)
    }
    let loadedDetails = (try? await fetchContextMenuMetadata(for: loadedRows)) ?? [:]
    guard generation == currentGeneration else { return }
    contextMenuMetadata.merge(loadedDetails) { _, fresh in fresh }
    errorMessage = nil
    orphanReport = nil
    orphanHealth = []
    usageBrowser = nil
    monthTotals = [:]
    rows = loadedRows
    nextCursor = nil
    canLoadMore = false
    totalCount = loadedRows.count
    unfilteredTotalCount = nil
    showReportPlace()
    hasShownAssets = true
    isLoadingPage = false
    selectedIDs = selectedIDs.filter { id in rows.contains { $0.id == id } }
    if selectedID != nil { await loadDetails() }
  }

  /// The Tags header's `+` opens the Add Tag…
  /// popover the asset context menu opens, on the selected assets; with
  /// nothing selected there is nothing to tag.
  public var canBeginTagAddition: Bool { selectionTargetIfAny != nil }

  public func beginTagAddition() {
    guard let target = selectionTargetIfAny, let anchor = orderedSelection.first else { return }
    beginContextTagEditing(for: target, anchor: anchor)
  }

  /// Loads the next level under `prefix` (nil = the root) unless it is
  /// already cached or on its way — the sidebar calls this every time a
  /// Catalog row opens, and only the first call for a prefix queries.
  public func loadFolderChildren(under level: KeyPrefixLevel) async {
    guard folderChildren[level] == nil, !folderChildrenInFlight.contains(level),
      let backendID = backendID(level.backend)
    else {
      return
    }
    folderChildrenInFlight.insert(level)
    defer { folderChildrenInFlight.remove(level) }
    folderChildrenFetchCount += 1
    do {
      folderChildren[level] = try await catalog.keyPrefixChildren(under: level.prefix, backendID: backendID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// A backend's id by slug, from the loaded roots.
  func backendID(_ slug: String) -> Int64? {
    domainBackends.first { $0.slug == slug }?.id
  }

  /// The Time tab's year row that starts open.
  public var timeDefaultOpenRowID: String? {
    SidebarModel.defaultOpenYear(months: availableMonths).map {
      SidebarModel.rowID(for: .year($0), in: .time)
    }
  }

  /// The Catalog roots' row ids: the sidebar opens each once by default.
  public var catalogRootRowIDs: [String] {
    domainBackends.map { SidebarModel.rowID(for: .backend($0.slug), in: .library) }
  }

  /// The backends and their domains read
  /// again — after a domain move, a Switch, an Old domain added or
  /// removed, and whenever the catalog changed. A root the tree had not
  /// loaded yet gets its first level.
  public func refreshDomainBackends() async {
    guard let backends = try? await catalog.domainBackends() else { return }
    if backends != domainBackends { domainBackends = backends }
    let slugs = Set(backends.map(\.slug))
    for level in folderChildren.keys where !slugs.contains(level.backend) { folderChildren[level] = nil }
    for backend in backends {
      await loadFolderChildren(under: KeyPrefixLevel(backend: backend.slug, prefix: nil))
    }
    if let domain = usageDomain, !backends.contains(where: { $0.prefixes.contains(domain) }) {
      usageDomain = nil
    }
  }

  /// An upload, archive or delete in this session — here
  /// or from the CLI — moves the catalog's stamp, and every level the tree
  /// has loaded is fetched once more, in place, so open rows stay open. The
  /// stamp is read before the levels, so a change landing in between only
  /// costs one more refetch on the next check, never a stale count. Runs
  /// on every `reload`; with the stamp unchanged it issues no tree query.
  private func refreshFolderChildrenIfCatalogChanged() async {
    guard let stamp = try? await catalog.changeStamp(), stamp != folderChildrenStamp else {
      return
    }
    folderChildrenStamp = stamp
    if let backends = try? await catalog.domainBackends(), backends != domainBackends {
      domainBackends = backends
    }
    for level in Array(folderChildren.keys) where !folderChildrenInFlight.contains(level) {
      guard let backendID = backendID(level.backend) else { continue }
      folderChildrenInFlight.insert(level)
      defer { folderChildrenInFlight.remove(level) }
      folderChildrenFetchCount += 1
      do {
        folderChildren[level] = try await catalog.keyPrefixChildren(under: level.prefix, backendID: backendID)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
    // The opened project rows too.
    for slug in Array(projectUsage.keys) where !projectUsageInFlight.contains(slug) {
      await fetchProjectUsage(slug)
    }
  }

  /// Selects a destination in the navigator that shows it. Every
  /// writer outside the sidebar's own List goes through this, so a
  /// selection can never land in a tree that has no row for it.
  public func select(_ selection: SidebarSelection, in navigator: SidebarNavigator) {
    movePlace {
      self.navigator = navigator
      sidebarSelection = selection
    }
  }

  // MARK: - History

  public var canGoBack: Bool { history.canGoBack }
  public var canGoForward: Bool { history.canGoForward }

  public func goBack() {
    var moved = history
    guard let place = moved.goBack() else { return }
    history = moved
    restore(place)
  }

  public func goForward() {
    var moved = history
    guard let place = moved.goForward() else { return }
    history = moved
    restore(place)
  }

  /// Puts a recorded place back without recording it. The slot is written
  /// before the navigator switches, so the shown selection goes from the
  /// old place straight to the new one — never through whatever the
  /// target navigator's slot held in between (one reload
  /// per real move).
  private func restore(_ place: NavigationHistory.Place) {
    isMovingPlace = true
    defer { isMovingPlace = false }
    navigatorSelections[place.navigator] = place.selection
    navigator = place.navigator
  }

  private func movePlace(_ body: () -> Void) {
    isMovingPlace = true
    body()
    isMovingPlace = false
    recordPlace()
  }

  private func recordPlace() {
    guard !isMovingPlace else { return }
    let place = NavigationHistory.Place(navigator, sidebarSelection)
    guard place != history.current else { return }
    history.visit(place)
  }

  /// The default selection, one per navigator. Collections resolves to the first
  /// project and Time to the newest year when they are known; at init the
  /// summaries have not loaded yet, so in the running app both start at
  /// `.all` — a placeholder `loadInitialData` resolves — and the user's own
  /// choice takes over from there.
  public static func defaultNavigatorSelections(
    projects: [ProjectSummary] = [],
    months: [(month: String, count: Int)] = []
  ) -> [SidebarNavigator: SidebarSelection] {
    [
      .library: .all,
      .time: newestYear(in: months).map { .year($0) } ?? .all,
      .collections: projects.first.map { .project($0.slug) } ?? .all,
      .reports: .overview,
    ]
  }

  private static func newestYear(in months: [(month: String, count: Int)]) -> String? {
    months.map { String($0.month.prefix(4)) }.max()
  }

  public var projectAdditionAvailability: ProjectAdditionAvailability {
    guard projectSettings?.canBeginAddition == true else {
      return .unavailable(ProjectSettingsModel.backendRequiredMessage)
    }
    return .available
  }

  public var projectAdditionDraft: NewProjectDraft? {
    projectSettings?.additionDraft
  }

  public var isProjectAdditionPresented: Bool {
    projectSettings?.isAdditionPresented(by: .sidebar) == true
  }

  public var canSubmitProjectAddition: Bool {
    projectSettings?.canSubmitAddition == true
  }

  public func beginProjectAddition() {
    guard case .available = projectAdditionAvailability, let projectSettings else {
      projectAdditionMessage = ProjectSettingsModel.backendRequiredMessage
      return
    }
    projectAdditionMessage = nil
    projectSettings.beginAddition(presenter: .sidebar)
  }

  public func updateProjectAdditionDraft(_ update: (inout NewProjectDraft) -> Void) {
    projectSettings?.updateAdditionDraft(update)
  }

  public func cancelProjectAddition() {
    projectSettings?.cancelAddition(presenter: .sidebar)
    projectAdditionMessage = nil
  }

  public func dismissProjectAdditionMessage() {
    projectAdditionMessage = nil
  }

  public func submitProjectAddition() async {
    guard let projectSettings else { return }
    await projectSettings.submitAddition(presenter: .sidebar)
  }

  public func refreshProjects() async {
    do {
      projects = try await catalog.projectSummaries()
    } catch {
      errorMessage = error.localizedDescription
    }
    resolveCollectionsDefault()
  }

  /// At init the project summaries have not loaded, so the
  /// collections slot starts at `.all` — a selection its tree has no row
  /// for. Once projects are known, that placeholder becomes the real
  /// default, the first project. A choice the user already made is kept,
  /// and with no projects `.all` stays.
  private func resolveCollectionsDefault() {
    guard navigatorSelections[.collections] == .all, let first = projects.first else { return }
    resolvePlaceholder(.collections, to: .project(first.slug))
  }

  /// The same shape for Time: `.all` has no row in the
  /// years-and-months tree, so once the months are known the placeholder
  /// becomes the newest year. A year or month the user already picked is
  /// kept; an empty catalog has no year, and `.all` stays.
  private func resolveTimeDefault() {
    guard navigatorSelections[.time] == .all,
      let year = Self.newestYear(in: availableMonths)
    else { return }
    // Through the published slot, so when Time is showing the change
    // publishes like any other selection and the grid reloads onto the year.
    resolvePlaceholder(.time, to: .year(year))
  }

  /// A launch placeholder becoming its navigator's default is not a step
  /// the user took: history rewrites the placeholder instead of recording
  /// a move away from it.
  private func resolvePlaceholder(_ navigator: SidebarNavigator, to selection: SidebarSelection) {
    isMovingPlace = true
    navigatorSelections[navigator] = selection
    isMovingPlace = false
    history.replace(.init(navigator, .all), with: .init(navigator, selection))
  }

  public func exportManifest(project: String) async {
    await manifestExport?.export(project: project)
  }

  // MARK: - Menu command actions

  public func toggleSidebar() {
    isSidebarVisible.toggle()
  }

  public func toggleInspector() {
    showsInspector.toggle()
  }

  public func focusSearch() {
    isSearchPresented = true
  }

  /// View → Quick Look. The space shortcut goes back to the text while
  /// AppKit's field editor or the note editor owns focus
  /// (`handKeyBackToText`); choosing the menu item with the pointer remains
  /// available.
  public func toggleQuickLookFromCommand() {
    if handKeyBackToText() { return }
    if sidebarSelection == .externals {
      // The one image Other Domains ever loads is the one asked for.
      guard let request = externals.quickLookRequest else { return }
      quickLook.navigator = self
      quickLook.toggleExternal(request)
      return
    }
    guard let entries = quickLookEntries else { return }
    quickLook.navigator = self
    quickLook.toggleRemote(entries.items, at: entries.index)
  }

  /// A cell's double-click: Quick Look on the selection, through
  /// the same entries as Space, but opening only — on the image it already
  /// shows, the panel stays open.
  public func openQuickLook() {
    guard let entries = quickLookEntries else { return }
    quickLook.navigator = self
    quickLook.openRemote(entries.items, at: entries.index)
  }

  /// What the Quick Look panel pages through: the rows loaded on
  /// this surface, in display order, standing on the selected one.
  private var quickLookEntries: (items: [CatalogAssetItem], index: Int)? {
    guard let selectedID else { return nil }
    let rows = selectableRows
    if let index = rows.firstIndex(where: { $0.id == selectedID }) {
      return (rows.map(\.item), index)
    }
    return selectedCatalogItem.map { ([$0], 0) }
  }

  /// The grid's own arrow-key entry (`AssetGridView.moveSelection`, which
  /// also scrolls the row in), installed while the grid is on screen. Keys
  /// the Quick Look panel hands over go through it.
  var gridKeyboardMove: ((GridMove) -> Void)?

  public var canQuickLook: Bool {
    sidebarSelection == .externals
      ? externals.quickLookRequest != nil : selectedCatalogItem != nil
  }

  /// The toolbar's and View ▸ View Mode's Grid | Table: Externals' shown
  /// half keeps its own, every other surface the library's.
  public var surfaceViewMode: ViewMode {
    get { sidebarSelection == .externals ? externals.viewMode : viewMode }
    set {
      if sidebarSelection == .externals {
        externals.viewMode = newValue
      } else {
        viewMode = newValue
      }
    }
  }

  /// The event being handled; replaced in tests, whose process cannot
  /// dequeue events the way the app's run loop does.
  var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

  /// Space, `.` and ⌘⌫ are menu shortcuts (Quick Look, Favorite, Archive).
  /// When one arrives as a key press while a text field or the note editor
  /// has focus, the key is the text's: it is re-delivered to the focused
  /// text view — typed, or ⌘⌫'s delete to line start — and the command does
  /// nothing. The window is the key event's own, so the check holds for
  /// whichever window the key was typed into. Chosen with the pointer, the
  /// menu item still acts.
  private func handKeyBackToText() -> Bool {
    guard let event = currentEvent(), event.type == .keyDown,
      let window = event.window ?? NSApp.keyWindow,
      QuickLookController.textInputHasFocus(in: window),
      let responder = window.firstResponder
    else { return false }
    responder.keyDown(with: event)
    return true
  }

  private var selectedCatalogItem: CatalogAssetItem? {
    guard let selectedID else { return nil }
    if let row = rows.first(where: { $0.id == selectedID }) { return row.item }
    if let orphan = orphanReport?.assets.first(where: { $0.asset.id == selectedID }) {
      return CatalogAssetItem(asset: orphan.asset, backend: orphan.backend)
    }
    return selectedDetails?.item
  }

  /// Clears only the time predicate, never the search text. No button
  /// calls it now.
  public func clearTimeFilter() {
    timeFilter = .all
  }

  // MARK: - Grid zoom

  /// One rung toward bigger cells (fewer columns); saturates at the 2-column
  /// end of the ladder. `canZoomIn` exists so callers disable their
  /// affordances there — saturation is a state to surface, not swallow.
  public func zoomIn() {
    guard let index = GridZoom.columns.firstIndex(of: gridColumns), index > 0 else { return }
    gridColumns = GridZoom.columns[index - 1]
  }

  /// One rung toward smaller cells (more columns); saturates at the 8-column end.
  public func zoomOut() {
    guard let index = GridZoom.columns.firstIndex(of: gridColumns),
      index < GridZoom.columns.count - 1
    else { return }
    gridColumns = GridZoom.columns[index + 1]
  }

  public func setGridColumns(_ columns: Int) {
    guard GridZoom.columns.contains(columns) else { return }
    gridColumns = columns
  }

  public func toggleGridThumbnailSizing() {
    gridThumbnailSizing = gridThumbnailSizing == .fillGrid ? .originalAspect : .fillGrid
  }

  public var canZoomIn: Bool {
    GridZoom.columns.firstIndex(of: gridColumns).map { $0 > 0 } ?? false
  }

  public var canZoomOut: Bool {
    GridZoom.columns.firstIndex(of: gridColumns)
      .map { $0 < GridZoom.columns.count - 1 } ?? false
  }

  /// The No Assets state's Upload… button: the same picker as File → New Upload….
  public func requestUpload() {
    onRequestUpload?()
  }

  /// The empty catalog's Restore from Backup…: the backup model's restore,
  /// as the shell installs it.
  public func requestRestore() async {
    await onRequestRestore?()
  }

  // MARK: - Make Bigger / Make Smaller

  /// The ladder ⌘+ / ⌘− and the toolbar's slider move on the surface shown:
  /// the grid's columns or the table's rows; on Externals the
  /// shown half's Grid moves the library's columns and its list none.
  public var zoomLadder: ViewMode? {
    guard sidebarSelection == .externals else { return viewMode }
    return externals.viewMode == .grid ? .grid : nil
  }

  /// View ▸ Make Bigger (⌘+), Finder's: a grid rung in the grid, a row
  /// rung in the table. The two ladders never move each other.
  public func makeBigger() {
    switch zoomLadder {
    case .grid: zoomIn()
    case .table: stepTableRowHeight(by: 1)
    case nil: break
    }
  }

  /// View ▸ Make Smaller (⌘−).
  public func makeSmaller() {
    switch zoomLadder {
    case .grid: zoomOut()
    case .table: stepTableRowHeight(by: -1)
    case nil: break
    }
  }

  /// False at the current ladder's big end, so the menu item grays there.
  public var canMakeBigger: Bool {
    switch zoomLadder {
    case .grid: return canZoomIn
    case .table: return tableRowRung.map { $0 < DesignMetrics.table.rowHeights.count - 1 } ?? false
    case nil: return false
    }
  }

  public var canMakeSmaller: Bool {
    switch zoomLadder {
    case .grid: return canZoomOut
    case .table: return tableRowRung.map { $0 > 0 } ?? false
    case nil: return false
    }
  }

  public func setTableRowHeight(_ height: CGFloat) {
    guard DesignMetrics.table.rowHeights.contains(height) else { return }
    tableRowHeight = height
  }

  /// `tableRowHeight`'s index on the ladder.
  public var tableRowRung: Int? {
    DesignMetrics.table.rowHeights.firstIndex(of: tableRowHeight)
  }

  private func stepTableRowHeight(by step: Int) {
    let heights = DesignMetrics.table.rowHeights
    guard let rung = tableRowRung, heights.indices.contains(rung + step) else { return }
    tableRowHeight = heights[rung + step]
  }

  /// The selection's public URL, or nil with no selection.
  public var selectedURL: String? {
    selectedDetails?.item.url
  }

  /// The selection's `![alt](url)` line, with the same alt-text rule the CLI
  /// and the drop zone use (original filename minus extension, `]` escaped);
  /// nil with no selection.
  public var selectedMarkdown: String? {
    selectedDetails.map { Self.markdown(for: $0.item) }
  }

  public static func markdown(for item: CatalogAssetItem) -> String {
    let source = item.asset.originalFilename ?? (item.asset.key as NSString).lastPathComponent
    let alt = URL(fileURLWithPath: source)
      .deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: "]", with: "\\]")
    return "![\(alt)](\(item.url))"
  }

  /// The identifier used by write APIs — the full sha256 of the selection.
  /// Falls back to the orphan report: an orphan picked in the orphan view is
  /// not in `rows`, but its details load through the same read path.
  public var selectedIdentifier: String? {
    guard let selectedID else { return nil }
    if let row = rows.first(where: { $0.id == selectedID }) {
      return row.item.asset.sha256
    }
    if let orphan = orphanReport?.assets.first(where: { $0.asset.id == selectedID }) {
      return orphan.asset.sha256
    }
    return nil
  }

  // MARK: - Grid context menu

  /// Finder's rule carried to sets: a right-click on a cell outside the
  /// selection targets that cell alone (the action then selects only it); a
  /// right-click inside a selection of two or more targets the selection.
  public func contextMenuItems(for row: Row) -> [ContextMenuItem] {
    let target = contextMenuTarget(for: row)
    let destinations = projects.map {
      ContextMenuProject(
        slug: $0.slug,
        name: $0.name,
        isMember: membership(ofProject: $0.slug, in: target) == true
      )
    }
    return [
      .copyURL(target),
      .copyAs(target, copyFormats),
      .downloadOriginal(target),
      .addTag(target),
      .addToProject(target, destinations),
      .editNote(target),
      .favorite(target, isFavorite: favoriteState(of: target) == true),
      .label(target, labelChoices(for: target)),
      .archive(target, putBack: isArchived(target)),
    ] + (showsDeletePermanently
      ? [.deletePermanently(target, isEnabled: canDeletePermanently(target))] : [])
  }

  public func beginContextAction(for target: ContextMenuTarget) {
    selectContextTarget(target)
  }

  public func copyURL(
    for target: ContextMenuTarget, to pasteboard: NSPasteboard = .general
  ) {
    selectContextTarget(target)
    let urls = members(of: target).map(\.url)
    guard !urls.isEmpty else { return }
    PasteboardWriter.copy(urls.joined(separator: "\n"), to: pasteboard)
  }

  /// One rendered line per member, in grid order.
  public func copy(
    _ format: CopyFormat, for target: ContextMenuTarget, to pasteboard: NSPasteboard = .general
  ) {
    selectContextTarget(target)
    let fields = members(of: target).map(\.copyFields)
    guard !fields.isEmpty else { return }
    PasteboardWriter.copy(CopyTemplate.render(format.template, lines: fields), to: pasteboard)
  }

  /// Edit ▸ Copy As: the current selection, in grid order.
  public func copySelection(as format: CopyFormat, to pasteboard: NSPasteboard = .general) {
    copy(format, for: .selection(orderedSelection), to: pasteboard)
  }

  public var canCopySelection: Bool {
    !orderedSelection.isEmpty
  }

  /// Edit ▸ Copy (⌘C) while the grid has focus: the
  /// selection in the default format. A text field's ⌘C never gets here —
  /// the field editor answers `copy:` first in the responder chain.
  public func copySelectionInDefaultFormat(to pasteboard: NSPasteboard = .general) {
    guard let format = defaultCopyFormat ?? copyFormats.first else { return }
    copySelection(as: format, to: pasteboard)
  }

  // MARK: - Drag out

  /// What a drag started on `row` carries: the whole selection in grid order
  /// when `row` is part of a multiple selection, else `row` alone — the
  /// context menu's rule. The text is the default format's rendering, the
  /// same function ⌘C uses. Only strings: nothing is fetched and the
  /// selection is left as it is.
  public func dragItemProvider(for row: Row) -> NSItemProvider? {
    guard let format = defaultCopyFormat ?? copyFormats.first else { return nil }
    let targetMembers = members(of: contextMenuTarget(for: row))
    guard !targetMembers.isEmpty else { return nil }
    return AssetDrag.itemProvider(
      text: CopyTemplate.render(format.template, lines: targetMembers.map(\.copyFields)),
      urls: targetMembers.map(\.url))
  }

  /// The table's drag: its outline view asks once for every row it drags —
  /// the whole selection when the drag starts inside it — so the
  /// selection's first row in grid order carries the drag and the other
  /// selected rows carry nothing, instead of each repeating the text.
  public func tableDragItemProvider(for row: Row) -> NSItemProvider? {
    if selectedIDs.count > 1, selectedIDs.contains(row.id), orderedSelection.first != row.id {
      return nil
    }
    return dragItemProvider(for: row)
  }

  // MARK: - Download Original

  /// Saves each member's original into `downloadFolder`, in grid order, one
  /// at a time. A failed item is recorded and the rest carry on; the status
  /// bar's right side shows progress while running and the failure sentence
  /// after. Whatever was saved is then selected in Finder.
  public func downloadOriginals(for target: ContextMenuTarget) async {
    selectContextTarget(target)
    let saved = await fetchOriginals(of: members(of: target)) { _ in downloadFolder }
    if !saved.isEmpty {
      revealDownloads(saved)
    }
  }

  /// The one fetch path for originals, shared by Download Original and
  /// the toolbar's Share: each member in order through `downloader`
  /// — so its bytes are checked against the catalog's sha256 — with progress,
  /// then the failure sentence, on the status bar's right side. A failed
  /// member is left out of the result. `folder` picks where each one lands.
  private func fetchOriginals(
    of targetMembers: [ContextMenuRow], into folder: (ContextMenuRow) -> URL
  ) async -> [URL] {
    guard !isDownloading else { return [] }
    let requests = targetMembers.map { member in
      (
        member: member,
        name: member.copyFields.filename,
        request: URL(string: member.url).map {
          DownloadRequest(
            sha256: member.identifier, sourceURL: $0,
            filename: OriginalDownloader.downloadFilename(
              member.copyFields.filename, key: member.copyFields.key))
        }
      )
    }
    guard !requests.isEmpty else { return [] }
    isDownloading = true
    downloadError = nil
    var saved: [URL] = []
    var failures: [(name: String, reason: String)] = []
    for (index, item) in requests.enumerated() {
      downloadProgress =
        requests.count == 1
        ? "Downloading \(item.name)…" : "Downloading \(index + 1) of \(requests.count)…"
      do {
        guard let request = item.request else { throw OriginalDownloadError.invalidURL }
        saved.append(try await downloader.download(request, to: folder(item.member)))
      } catch {
        failures.append((item.name, UserFacingErrorMessage.resolve(error)))
      }
    }
    downloadProgress = nil
    isDownloading = false
    if let first = failures.first {
      downloadError =
        requests.count == 1
        ? "Couldn't download \(first.name): \(first.reason)"
        : "Couldn't download \(failures.count) of \(requests.count) — \(first.name): \(first.reason)"
    }
    return saved
  }

  /// File ▸ Download Original: the current selection, in grid order.
  public func downloadSelection() async {
    await downloadOriginals(for: .selection(orderedSelection))
  }

  public var canDownloadSelection: Bool {
    !orderedSelection.isEmpty && !isDownloading
  }

  // MARK: - Share

  /// Where Share keeps the originals it fetched: one folder per sha256 in
  /// the app's caches, never the Downloads folder.
  public var shareCacheFolder: URL =
    (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    ?? FileManager.default.temporaryDirectory)
    .appendingPathComponent("Pinax/Shared Originals", isDirectory: true)
  /// Shows the system share menu for the files; replaced in tests.
  public var presentShare: ([URL]) -> Void = { urls in
    ShareAnchor.present(urls)
  }

  /// The toolbar's Share: the members' original files, fetched first through
  /// Download Original's path when not cached yet, then handed to the system share menu. A
  /// member that fails to fetch is left out; its sentence is in the status bar.
  public func shareOriginals(for target: ContextMenuTarget) async {
    selectContextTarget(target)
    guard !isDownloading else { return }
    let targetMembers = members(of: target)
    let missing = targetMembers.filter { cachedOriginal(of: $0) == nil }
    if !missing.isEmpty {
      _ = await fetchOriginals(of: missing) { member in
        shareCacheFolder.appendingPathComponent(member.identifier, isDirectory: true)
      }
    }
    let files = targetMembers.compactMap(cachedOriginal(of:))
    if !files.isEmpty {
      presentShare(files)
    }
  }

  public func shareSelection() async {
    await shareOriginals(for: .selection(orderedSelection))
  }

  public var canShareSelection: Bool {
    canDownloadSelection
  }

  /// The file a previous Share fetched for this member, if any; only the
  /// downloader writes into the member's folder, after checking the sha256.
  private func cachedOriginal(of member: ContextMenuRow) -> URL? {
    let folder = shareCacheFolder.appendingPathComponent(member.identifier, isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.sorted().first.map { folder.appendingPathComponent($0) }
  }

  // MARK: - Archive, favourite, labels

  /// A multi-item archive, or one with live usage, waiting for its one
  /// confirmation. The remote objects are never deleted (README hard rule
  /// 1), which is why a live reference keeps working — the dialog says so.
  public struct ArchiveConfirmation: Equatable, Sendable {
    public let count: Int
    public let name: String
    public let liveUsageCount: Int
    let target: ContextMenuTarget

    public var title: String {
      count == 1 ? "Archive “\(name)”?" : "Archive \(count) items?"
    }
    public var message: String {
      let place = "Archived items leave every view but Archived, and every project's manifest export; Put Back restores them."
      guard liveUsageCount > 0 else { return place }
      let referenced =
        count == 1
        ? "It is still referenced by scanned documents"
        : "\(liveUsageCount) of them are still referenced by scanned documents"
      return "\(referenced) — links won't break, because the remote files are not deleted. \(place)"
    }
  }

  @Published public private(set) var pendingArchive: ArchiveConfirmation?

  /// The Delete Permanently… sheet's contents while it
  /// is up; the deletes that did not finish (banner and sidebar badge);
  /// and the status bar's progress, notice and failure.
  @Published public private(set) var pendingDeletion: DeletionConfirmation?
  @Published public private(set) var unfinishedDeletions: [UnfinishedDeletion] = []
  @Published public private(set) var isDeleting = false
  @Published public private(set) var isRestoringDeletions = false
  @Published public private(set) var deletionProgress: String?
  @Published public private(set) var deletionNotice: String?
  @Published public private(set) var deletionError: String?
  @Published public private(set) var isDeletionBannerDismissed = false
  /// The banner's Show Files.
  @Published public var showsUnfinishedFiles = false
  /// The shell lets the drop zone drop the deleted images' cards.
  public var onAssetsDeleted: ((Set<String>) -> Void)?

  /// ⌘⌫ / Archive: one unreferenced item goes at once; a batch, or anything
  /// with live usage, asks first. Nothing here reaches the object store.
  public func archive(_ target: ContextMenuTarget) async {
    selectContextTarget(target)
    guard editor != nil else { return }
    let targetMembers = members(of: target).filter { !$0.isArchived }
    guard !targetMembers.isEmpty else { return }
    let live =
      (try? await catalog.liveUsageAssetCount(identifiers: targetMembers.map(\.identifier))) ?? 0
    guard targetMembers.count == 1, live == 0 else {
      pendingArchive = ArchiveConfirmation(
        count: targetMembers.count, name: targetMembers[0].copyFields.filename,
        liveUsageCount: live, target: target)
      return
    }
    await setState(.archived, of: targetMembers)
  }

  /// Takes the presented value: the dialog's dismissal clears
  /// `pendingArchive` before the button's task gets to run.
  public func confirmArchive(_ pending: ArchiveConfirmation) async {
    pendingArchive = nil
    await setState(.archived, of: members(of: pending.target).filter { !$0.isArchived })
  }

  public func cancelArchive() {
    pendingArchive = nil
  }

  public func putBack(_ target: ContextMenuTarget) async {
    selectContextTarget(target)
    await setState(.active, of: members(of: target).filter(\.isArchived))
  }

  /// Favourite every member, or — when every member already is — none.
  public func toggleFavorite(_ target: ContextMenuTarget) async {
    selectContextTarget(target)
    guard let editor else { return }
    let targetMembers = members(of: target)
    guard !targetMembers.isEmpty else { return }
    let favorite = favoriteState(of: target) != true
    await performEdit {
      try await editor.setFavorite(favorite, for: targetMembers.map(\.identifier))
    }
    await afterCuration(of: targetMembers) { $0.isFavorite = favorite }
  }

  /// Apply `label` to every member, or — when every member has it — remove it.
  public func toggleLabel(_ label: AssetLabel, for target: ContextMenuTarget) async {
    selectContextTarget(target)
    guard let editor else { return }
    let targetMembers = members(of: target)
    guard !targetMembers.isEmpty else { return }
    let applied = labelState(label, of: target) != true
    await performEdit {
      try await editor.setLabel(label, applied, for: targetMembers.map(\.identifier))
    }
    await afterCuration(of: targetMembers) { row in
      var labels = Set(row.labels)
      if applied { labels.insert(label) } else { labels.remove(label) }
      row.labels = AssetLabel.allCases.filter(labels.contains)
    }
  }

  /// True when every member is a favourite, false when none is, nil when mixed.
  public func favoriteState(of target: ContextMenuTarget) -> Bool? {
    let flags = Set(members(of: target).map(\.isFavorite))
    return flags.count == 1 ? flags.first : nil
  }

  public func labelState(_ label: AssetLabel, of target: ContextMenuTarget) -> Bool? {
    let flags = Set(members(of: target).map { $0.labels.contains(label) })
    return flags.count == 1 ? flags.first : nil
  }

  public func labelChoices(for target: ContextMenuTarget) -> [LabelChoice] {
    AssetLabel.allCases.map { LabelChoice(label: $0, state: labelState($0, of: target)) }
  }

  private func isArchived(_ target: ContextMenuTarget) -> Bool {
    let targetMembers = members(of: target)
    return !targetMembers.isEmpty && targetMembers.allSatisfy(\.isArchived)
  }

  // The menu-bar and inspector forms act on the current selection.

  public var selectionTargetIfAny: ContextMenuTarget? {
    orderedSelection.isEmpty ? nil : .selection(orderedSelection)
  }

  /// Edit ▸ Archive / Put Back (⌘⌫). While a text field is being edited the
  /// key is the text field's — delete to the start of the line — not an
  /// archive of whatever happens to be selected.
  public func archiveOrPutBackFromCommand() async {
    if handKeyBackToText() { return }
    guard let target = selectionTargetIfAny else { return }
    if isArchived(target) {
      await putBack(target)
    } else {
      await archive(target)
    }
  }

  /// Edit ▸ Favorite (`.`, Photos' key). Typing a full stop into a text field
  /// stays typing, as space does for Quick Look.
  public func toggleFavoriteFromCommand() async {
    if handKeyBackToText() { return }
    guard let target = selectionTargetIfAny else { return }
    await toggleFavorite(target)
  }

  public var canCurateSelection: Bool {
    editor != nil && !orderedSelection.isEmpty
  }

  /// Edit ▸ Favorite's title and the toolbar ♥ read this one value:
  /// true only when every selected item is a favourite.
  public var selectionIsFavorite: Bool {
    selectionTargetIfAny.map { favoriteState(of: $0) == true } ?? false
  }

  public var selectionIsArchived: Bool {
    selectionTargetIfAny.map(isArchived) ?? false
  }

  // MARK: - Delete Permanently

  /// The context-menu item exists on Archived only, and
  /// only when the gallery was opened with a deleter. The Edit menu's is
  /// always there, disabled off Archived.
  public var showsDeletePermanently: Bool {
    deleter != nil && sidebarSelection == .archived
  }

  /// Every member archived (Archived shows nothing else; still checked),
  /// and no delete or restore already running.
  public func canDeletePermanently(_ target: ContextMenuTarget) -> Bool {
    showsDeletePermanently && !isDeletionBusy && isArchived(target)
  }

  /// Edit ▸ Delete Permanently… (⌥⌘⌫).
  public var canDeleteSelectionPermanently: Bool {
    selectionTargetIfAny.map(canDeletePermanently) ?? false
  }

  /// Asks first, always: the sheet's facts are read from the catalog, and
  /// nothing is written or sent until `confirmDeletion`.
  public func deletePermanently(_ target: ContextMenuTarget) async {
    selectContextTarget(target)
    guard let deleter, canDeletePermanently(target) else { return }
    let targetMembers = members(of: target)
    do {
      let facts = try await deleter.facts(for: targetMembers.map(\.identifier))
      guard facts.allSatisfy(\.isArchived) else { return }
      pendingDeletion = DeletionConfirmation.make(
        facts: facts, currentProject: currentProjectSlug,
        projectNames: Dictionary(
          projects.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }))
    } catch {
      deletionError = UserFacingErrorMessage.resolve(error)
    }
  }

  public func deletePermanentlyFromCommand() async {
    if handKeyBackToText() { return }
    guard let target = selectionTargetIfAny else { return }
    await deletePermanently(target)
  }

  public func cancelDeletion() {
    pendingDeletion = nil
  }

  /// The sheet's Delete: one catalog transaction (the rows leave the grid
  /// at once), the caches let go of them, then each object in turn with
  /// the status bar counting. The rest of the selection stays
  /// selected.
  public func confirmDeletion(_ pending: DeletionConfirmation) async {
    pendingDeletion = nil
    guard let deleter, !isDeletionBusy else { return }
    isDeleting = true
    defer { isDeleting = false }
    deletionError = nil
    deletionNotice = nil
    let owed: [Int64]
    do {
      owed = try deleter.stage(deleting: pending.deleting, keeping: pending.keeping)
    } catch {
      deletionError = UserFacingErrorMessage.resolve(error)
      return
    }
    let gone = Set(pending.deleting + pending.keeping)
    removeLeavingRows(Set(rows.filter { gone.contains($0.item.asset.sha256) }.map(\.id)))
    await forgetCachedFiles(for: gone)
    onAssetsDeleted?(gone)
    await reload()
    await refreshProjects()
    let buckets = Dictionary(
      ((try? await deleter.unfinished()) ?? []).map { ($0.id, $0.bucket) },
      uniquingKeysWith: { first, _ in first })
    for (index, id) in owed.enumerated() {
      deletionProgress = "Deleting from \(buckets[id] ?? "the bucket")… \(index + 1) of \(owed.count)"
      _ = try? await deleter.purge(id)
    }
    deletionProgress = nil
    await refreshUnfinishedDeletions()
  }

  /// The selection leaves the current project, catalog only —
  /// nothing reaches the bucket and every image stays archived. A live
  /// reference in the project keeps that one there (the core's guard).
  public func confirmRemoveFromProject(_ pending: DeletionConfirmation) async {
    pendingDeletion = nil
    guard let editor, let removal = pending.removal else { return }
    var kept = 0
    await performEdit {
      for identifier in removal.members {
        do {
          try await editor.removeFromProject(removal.slug, identifier: identifier)
        } catch AssetCatalogError.unlinkBlockedByLiveUsage {
          kept += 1
        }
      }
    }
    if kept > 0 {
      deletionNotice =
        "\(DeletionConfirmation.images(kept)) \(kept == 1 ? "is" : "are") still used in "
        + "\(removal.name) and \(kept == 1 ? "stays" : "stay") there."
    }
    await reload()
  }

  /// The banner's Retry: `CatalogDeletion.resume`, every owed delete.
  public func retryUnfinishedDeletions() async {
    guard let deleter, !isDeletionBusy, !unfinishedDeletions.isEmpty else { return }
    isDeleting = true
    defer { isDeleting = false }
    let count = unfinishedDeletions.count
    let buckets = Array(Set(unfinishedDeletions.map(\.bucket))).sorted().joined(separator: ", ")
    deletionNotice = nil
    deletionProgress = "Deleting from \(buckets)… \(count.formatted()) \(count == 1 ? "file" : "files")"
    _ = try? await deleter.resume()
    deletionProgress = nil
    isDeletionBannerDismissed = false
    await refreshUnfinishedDeletions()
  }

  /// The banner's Restore to Library: each tombstone back as an archived
  /// row. One whose delete was sent is first checked against the bucket
  /// (4′, "Checking …"); `restore` refuses it when the file is gone.
  public func restoreUnfinishedDeletions() async {
    guard let deleter, !isDeletionBusy, !unfinishedDeletions.isEmpty else { return }
    isRestoringDeletions = true
    defer { isRestoringDeletions = false }
    let items = unfinishedDeletions
    let checks = items.contains { $0.phase == .deleteSent }
    deletionNotice = nil
    var restored = 0
    var gone = 0
    var notOurs = 0
    var failures: [String] = []
    for (index, item) in items.enumerated() {
      deletionProgress =
        checks
        ? "Checking \(item.bucket)… \(index + 1) of \(items.count)"
        : "Restoring… \(index + 1) of \(items.count)"
      do {
        try await deleter.restore(item.id)
        restored += 1
      } catch CatalogDeletionError.objectGone {
        gone += 1
      } catch CatalogDeletionError.objectNotOurs {
        notOurs += 1
      } catch {
        failures.append(
          DeletionBanner.reason(
            for: UnfinishedDeletion(
              id: item.id, key: item.key, sha256: item.sha256, bucket: item.bucket,
              phase: item.phase, lastError: String(describing: error))))
      }
    }
    deletionProgress = nil
    deletionNotice = Self.restoreSentence(
      restored: restored, gone: gone, notOurs: notOurs, failures: failures)
    await reload()
    await refreshProjects()
    await refreshUnfinishedDeletions()
  }

  /// "Restored 2 images to Archived." and, for what stayed out, why.
  static func restoreSentence(restored: Int, gone: Int, notOurs: Int, failures: [String]) -> String {
    var parts: [String] = []
    if restored > 0 {
      parts.append("Restored \(DeletionConfirmation.images(restored)) to Archived.")
    }
    if gone > 0 {
      parts.append(
        gone == 1
          ? "1 file is already gone from the bucket, so it can’t come back; Retry clears its record."
          : "\(gone) files are already gone from the bucket, so they can’t come back; Retry clears their records.")
    }
    if notOurs > 0 {
      parts.append(
        "\(notOurs == 1 ? "1 file" : "\(notOurs) files") at the same key \(notOurs == 1 ? "isn’t" : "aren’t") "
          + "the one Pinax deleted, so \(notOurs == 1 ? "it stays" : "they stay") out of the library.")
    }
    var seen: [String] = []
    for failure in failures where !seen.contains(failure) { seen.append(failure) }
    parts += seen
    return parts.joined(separator: " ")
  }

  public func dismissDeletionBanner() {
    isDeletionBannerDismissed = true
  }

  /// Read only; never sends a request.
  public func refreshUnfinishedDeletions() async {
    guard let deleter else { return }
    let fresh = (try? await deleter.unfinished()) ?? unfinishedDeletions
    if Set(fresh.map(\.id)) != Set(unfinishedDeletions.map(\.id)) {
      isDeletionBannerDismissed = false
      showsUnfinishedFiles = false
    }
    unfinishedDeletions = fresh
  }

  public var isDeletionBusy: Bool { isDeleting || isRestoringDeletions }

  /// Board 4 on Archived, until closed; it comes back when the set of
  /// unfinished deletions changes. The sidebar badge stays regardless.
  public var deletionBanner: DeletionBanner? {
    guard sidebarSelection == .archived, !isDeleting, !isDeletionBannerDismissed else { return nil }
    return DeletionBanner.make(
      unfinishedDeletions,
      checking: isRestoringDeletions && unfinishedDeletions.contains { $0.phase == .deleteSent })
  }

  /// Thumbnail, original and Share caches, by sha256: a deleted image's
  /// bytes do not linger on this Mac either.
  private func forgetCachedFiles(for sha256s: Set<String>) async {
    for sha256 in sha256s {
      await thumbnails.forget(sha256: sha256)
      await quickLook.forgetOriginal(sha256: sha256)
      try? FileManager.default.removeItem(
        at: shareCacheFolder.appendingPathComponent(sha256, isDirectory: true))
    }
  }

  private func setState(_ state: AssetState, of targetMembers: [ContextMenuRow]) async {
    guard let editor, !targetMembers.isEmpty else { return }
    let changed = await performEdit {
      try await editor.setState(state, for: targetMembers.map(\.identifier))
    }
    // The members leave this surface (Archived shows only archived, every
    // other surface only active), so they leave the rows with the selection
    // handing off, and the grid, its counts and the tree counts
    // reload. A failed change leaves everything where it was.
    if changed { removeLeavingRows(Set(targetMembers.map(\.rowID))) }
    await reload()
  }

  /// Rows that left the surface go from `rows` and the
  /// selection hands off in one synchronous step, before the reload — no
  /// frame draws the selection on the next row while the one that left is
  /// still there. A row that left from outside the loaded pages changes
  /// nothing here; counts and month headers follow with the reload.
  private func removeLeavingRows(_ removed: Set<Int64>) {
    let order = selectableRows.map(\.id)
    if rows.contains(where: { removed.contains($0.id) }) {
      rows.removeAll { removed.contains($0.id) }
    }
    handOffSelection(leaving: removed, order: order)
  }

  /// Rows that left the surface leave the selection.
  /// What stays selected stays; when nothing does, the row after the last
  /// one that left — else the one before it — takes the selection, anchor
  /// and cursor, so ⌘⌫ / ⌥⌘⌫ can go again. `order` is the display order
  /// the user was looking at, read before the rows left.
  private func handOffSelection(leaving removed: Set<Int64>, order: [Int64]) {
    let remaining = selectedIDs.subtracting(removed)
    guard remaining.isEmpty, !selectedIDs.isDisjoint(with: removed) else {
      if remaining != selectedIDs { selectedIDs = remaining }
      return
    }
    guard let next = Self.handOff(order: order, removed: removed) else {
      clearSelection()
      return
    }
    selectedIDs = [next]
    selectionAnchor = next
    selectionCursor = next
  }

  /// The row that takes over when `removed` leaves `order` (as in
  /// Mail / Photos): the first row after the last removed one, else the
  /// nearest row before it; nil when none is left, or none of `removed` is
  /// in `order`.
  static func handOff(order: [Int64], removed: Set<Int64>) -> Int64? {
    guard let last = order.lastIndex(where: removed.contains) else { return nil }
    return order[(last + 1)...].first { !removed.contains($0) }
      ?? order[..<last].last { !removed.contains($0) }
  }

  /// A favourite or label change: surfaces filtered by it reload (the
  /// member may leave them); elsewhere the loaded rows are patched in place,
  /// so the grid keeps its pages and scroll position.
  private func afterCuration(
    of targetMembers: [ContextMenuRow], _ change: (inout Row) -> Void
  ) async {
    switch sidebarSelection {
    case .favorites, .label:
      await reload()
    default:
      let ids = Set(targetMembers.map(\.rowID))
      // One assignment, so the change publishes once.
      var patched = rows
      for index in patched.indices where ids.contains(patched[index].id) {
        change(&patched[index])
      }
      rows = patched
    }
  }

  /// Seeds the existing inspector note draft from the right-clicked row and
  /// changes its owner at the same time. The asynchronous details refresh
  /// triggered by selection must not replace text the user starts entering.
  public func beginContextNoteEditing(for target: ContextMenuTarget) {
    selectContextTarget(target)
    let members = members(of: target)
    // A selection shares a draft only when every member's note agrees.
    let notes = Set(members.map { $0.note ?? "" })
    noteDraftOwner = members.count == 1 ? members[0].identifier : nil
    noteDraft = notes.count == 1 ? notes.first ?? "" : ""
  }

  // MARK: - Context editor popover

  /// The Add Tag… / Edit Note… popover a context-menu item opened: which
  /// cell or row it hangs from — the right-clicked one — and the target it
  /// edits. One per gallery: every grid cell, orphan cell and table row
  /// presents its popover exactly when this names it.
  public struct ContextEditor: Equatable, Sendable {
    public enum Kind: Sendable { case tag, note }
    public let kind: Kind
    public let anchor: Row.ID
    public let target: ContextMenuTarget
  }

  /// One line of the Add Tag popover's list: a catalog tag, checked when
  /// every member of the target already has it.
  public struct ContextTagSuggestion: Identifiable, Equatable, Sendable {
    public let name: String
    public let isOnTarget: Bool

    public var id: String { name }
  }

  @Published public private(set) var contextEditor: ContextEditor?
  /// The Add Tag popover's field.
  @Published public var contextTagQuery = ""
  /// The list line ↑↓ moved to; Return adds it instead of the typed text.
  @Published public private(set) var contextTagHighlight: String?
  /// Tags added while this popover is open: the rows' tag lists are a page
  /// snapshot, so these keep their checkmarks honest until it closes.
  private var contextTagsAdded: Set<String> = []
  /// The save a dismissed Edit Note popover started, for tests to await.
  private(set) var contextEditorSave: Task<Void, Never>?
  /// The note draft the Edit Note popover opened with. A draft still equal
  /// to it is not saved: for a selection whose notes differ it is "", which
  /// stands for "they differ", and writing it would wipe every member's note.
  private var contextNoteOpened: String?

  public func beginContextTagEditing(for target: ContextMenuTarget, anchor: Row.ID) {
    selectContextTarget(target)
    contextTagQuery = ""
    contextTagHighlight = nil
    contextTagsAdded = []
    contextEditor = ContextEditor(kind: .tag, anchor: anchor, target: target)
  }

  public func beginContextNoteEditing(for target: ContextMenuTarget, anchor: Row.ID) {
    beginContextNoteEditing(for: target)
    contextNoteOpened = noteDraft
    contextEditor = ContextEditor(kind: .note, anchor: anchor, target: target)
  }

  /// Closes the popover. A note is saved unless `saving` is false (Esc) or
  /// the draft is the one it opened with; clicking outside saves, as
  /// ⌘Return does.
  public func dismissContextEditor(saving: Bool) {
    guard let editor = contextEditor else { return }
    let opened = contextNoteOpened
    contextEditor = nil
    contextNoteOpened = nil
    contextTagQuery = ""
    contextTagHighlight = nil
    contextTagsAdded = []
    guard saving, editor.kind == .note, noteDraft != opened else { return }
    contextEditorSave = Task { await saveNote(for: editor.target) }
  }

  /// The popover closed itself: a click outside saves, as
  /// above, but Esc reaching the popover before the Cancel button — the
  /// event being handled is that key — discards.
  public func contextEditorDidClose() {
    dismissContextEditor(saving: !Self.isEscape(currentEvent()))
  }

  static func isEscape(_ event: NSEvent?) -> Bool {
    event?.type == .keyDown && event?.keyCode == 53  // kVK_Escape
  }

  /// The Add Tag list: `tags` in their order, those containing
  /// `query` (case-insensitive) when it is not blank; checked when on the
  /// target.
  public static func tagSuggestions(
    _ tags: [String], query: String, onTarget: Set<String>
  ) -> [ContextTagSuggestion] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return tags
      .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
      .map { ContextTagSuggestion(name: $0, isOnTarget: onTarget.contains($0)) }
  }

  public var contextTagSuggestions: [ContextTagSuggestion] {
    guard let editor = contextEditor, editor.kind == .tag else { return [] }
    return Self.tagSuggestions(
      tags.map(\.name), query: contextTagQuery, onTarget: tagsOnAllMembers(of: editor.target))
  }

  private func tagsOnAllMembers(of target: ContextMenuTarget) -> Set<String> {
    let ids = members(of: target).map(\.rowID)
    let byID = Dictionary(selectableRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let common = ids.map { Set(byID[$0]?.tags ?? []) }.reduce(nil) { (all: Set<String>?, tags) in
      all.map { $0.intersection(tags) } ?? tags
    }
    return (common ?? []).union(contextTagsAdded)
  }

  /// ↑↓ in the Add Tag field: moves through the list, from the end it
  /// entered by.
  public func moveContextTagHighlight(by step: Int) {
    let names = contextTagSuggestions.map(\.name)
    guard !names.isEmpty else { return }
    guard let current = contextTagHighlight, let index = names.firstIndex(of: current) else {
      contextTagHighlight = step > 0 ? names.first : names.last
      return
    }
    contextTagHighlight = names[min(max(index + step, 0), names.count - 1)]
  }

  /// Return in the Add Tag field: adds the highlighted line, else the typed
  /// name, to the target — not again when every member has it — then
  /// clears the field. The popover stays open for the next tag.
  public func submitContextTag() async {
    guard let editor = contextEditor, editor.kind == .tag else { return }
    let suggestions = contextTagSuggestions
    let highlighted = suggestions.first { $0.name == contextTagHighlight }
    let name =
      highlighted?.name ?? contextTagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    contextTagQuery = ""
    contextTagHighlight = nil
    guard !name.isEmpty, !tagsOnAllMembers(of: editor.target).contains(name) else { return }
    contextTagsAdded.insert(name)
    await addTag(name, to: editor.target)
  }

  // MARK: - Editing

  public func addTag(_ name: String) async {
    guard let editor, let identifier = selectedIdentifier else { return }
    await addTag(name, identifier: identifier, editor: editor)
  }

  public func addTag(_ name: String, to target: ContextMenuTarget) async {
    selectContextTarget(target)
    guard let editor else { return }
    for member in members(of: target) {
      await addTag(name, identifier: member.identifier, editor: editor)
    }
  }

  /// The inspector's multi-selection Tags row: adds to every member.
  public func addTagToSelection(_ name: String) async {
    guard let target = selectionTarget else { return }
    await addTag(name, to: target)
  }

  public func removeTag(_ name: String) async {
    guard let editor, let identifier = selectedIdentifier else { return }
    await performEdit { try await editor.removeTag(name, from: identifier) }
  }

  public func saveNote() async {
    guard let editor, let identifier = selectedIdentifier else { return }
    await saveNote(identifier: identifier, editor: editor)
  }

  public func saveNote(for target: ContextMenuTarget) async {
    selectContextTarget(target)
    guard let editor else { return }
    for member in members(of: target) {
      await saveNote(identifier: member.identifier, editor: editor)
    }
  }

  public func setProjectMembership(
    _ member: Bool, slug: String, confirmedUnlink: Bool = false
  ) async {
    guard let editor, let identifier = selectedIdentifier else { return }
    await setProjectMembership(
      member,
      slug: slug,
      confirmedUnlink: confirmedUnlink,
      identifier: identifier,
      editor: editor
    )
  }

  public func setProjectMembership(
    _ member: Bool,
    slug: String,
    for target: ContextMenuTarget,
    confirmedUnlink: Bool = false
  ) async {
    selectContextTarget(target)
    guard let editor else { return }
    let targetMembers = members(of: target)
    for item in targetMembers {
      await setProjectMembership(
        member,
        slug: slug,
        confirmedUnlink: confirmedUnlink,
        identifier: item.identifier,
        editor: editor
      )
    }
    // `loadDetails` refreshes only a single selection; a set's memberships
    // are re-read here, or its checkboxes and menus keep the old state.
    guard case .selection = target else { return }
    await refreshMemberships(of: Set(targetMembers.map(\.rowID)))
  }

  private func refreshMemberships(of rowIDs: Set<Int64>) async {
    let affected = selectableRows.filter { rowIDs.contains($0.id) }
    guard let memberships = try? await catalog.projectMemberships(
      assetIDs: affected.map(\.id))
    else { return }
    for row in affected {
      let identifier = row.item.asset.sha256
      contextMenuMetadata[identifier] = ContextMenuMetadata(
        memberSlugs: memberships[row.id] ?? [],
        note: contextMenuMetadata[identifier]?.note ?? row.item.asset.note
      )
    }
  }

  /// A multi-selection unlink waiting for the one confirmation it gets.
  /// Worded as the single-asset dialog, titled with the count.
  public struct SelectionUnlink: Equatable, Sendable {
    public let slug: String
    public let name: String
    public let count: Int
    let target: ContextMenuTarget

    public var title: String { "Remove \(count) items from “\(name)”?" }
    public var confirmLabel: String {
      "Remove anyway — the images will disappear from this project's manifest"
    }
    public var message: String {
      "The site may still reference some of these images. Removing membership hides them "
        + "from this project's export immediately, and re-scanning will not restore them."
    }
  }

  @Published public private(set) var pendingSelectionUnlink: SelectionUnlink?

  /// The inspector's multi-selection project checkbox. Checking acts
  /// at once; unchecking only asks (`pendingSelectionUnlink`), and the
  /// confirmed unlink then covers members with live usage too.
  public func setProjectMembershipForSelection(_ member: Bool, slug: String) async {
    guard let target = selectionTarget else { return }
    guard member else {
      pendingSelectionUnlink = SelectionUnlink(
        slug: slug,
        name: projects.first(where: { $0.slug == slug })?.name ?? slug,
        count: members(of: target).count,
        target: target
      )
      return
    }
    await setProjectMembership(true, slug: slug, for: target)
  }

  /// Takes the presented value: the dialog's dismissal clears
  /// `pendingSelectionUnlink` before the button's task gets to run.
  public func confirmSelectionUnlink(_ pending: SelectionUnlink) async {
    pendingSelectionUnlink = nil
    await setProjectMembership(
      false, slug: pending.slug, for: pending.target, confirmedUnlink: true)
  }

  public func cancelSelectionUnlink() {
    pendingSelectionUnlink = nil
  }

  /// True when every member of the multi-selection is in the project, false
  /// when none is, nil when mixed (the inspector shows "—") or when fewer
  /// than two rows are selected.
  public func selectionMembership(ofProject slug: String) -> Bool? {
    guard let target = selectionTarget else { return nil }
    return membership(ofProject: slug, in: target)
  }

  private func membership(ofProject slug: String, in target: ContextMenuTarget) -> Bool? {
    let flags = Set(members(of: target).map {
      contextMenuMetadata[$0.identifier]?.memberSlugs.contains(slug) ?? false
    })
    return flags.count == 1 ? flags.first : nil
  }

  private var selectionTarget: ContextMenuTarget? {
    guard selectedIDs.count > 1 else { return nil }
    return .selection(orderedSelection)
  }

  private func contextMenuTarget(for row: Row) -> ContextMenuTarget {
    if selectedIDs.count > 1, selectedIDs.contains(row.id) {
      return .selection(orderedSelection)
    }
    return .row(contextMenuRow(for: row))
  }

  private func contextMenuRow(for row: Row) -> ContextMenuRow {
    let identifier = row.item.asset.sha256
    return ContextMenuRow(
      rowID: row.id,
      identifier: identifier,
      url: row.item.url,
      note: contextMenuMetadata[identifier]?.note ?? row.item.asset.note,
      copyFields: CopyFields(
        item: row.item,
        projects: (contextMenuMetadata[identifier]?.memberSlugs).map { $0.sorted() } ?? []),
      isFavorite: row.isFavorite,
      labels: row.labels,
      isArchived: row.isArchived
    )
  }

  /// A selection target resolves its ids against the rows showing now (grid
  /// rows, or the orphan report's); an id that left the surface is skipped.
  private func members(of target: ContextMenuTarget) -> [ContextMenuRow] {
    switch target {
    case let .row(row):
      return [row]
    case let .selection(ids):
      let visible = Dictionary(
        selectableRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      return ids.compactMap { visible[$0].map(contextMenuRow(for:)) }
    }
  }

  /// Acting on an unselected cell selects only it; acting on the
  /// selection leaves the selection alone.
  private func selectContextTarget(_ target: ContextMenuTarget) {
    guard case let .row(row) = target else { return }
    selectedIDs = [row.rowID]
    selectionAnchor = row.rowID
    selectionCursor = row.rowID
  }

  private func addTag(
    _ name: String, identifier: String, editor: EditableCatalog
  ) async {
    await performEdit { try await editor.addTag(name, to: identifier) }
  }

  private func saveNote(identifier: String, editor: EditableCatalog) async {
    await performEdit { try await editor.setNote(self.noteDraft, for: identifier) }
  }

  private func setProjectMembership(
    _ member: Bool,
    slug: String,
    confirmedUnlink: Bool,
    identifier: String,
    editor: EditableCatalog
  ) async {
    await performEdit {
      if member {
        try await editor.addToProject(slug, identifier: identifier)
      } else {
        try await editor.removeFromProject(slug, identifier: identifier, confirmed: confirmedUnlink)
      }
    }
  }

  /// Edits are serialised, never dropped: each change chains onto the previous
  /// one's task, so rapid clicks all land in order instead of the second being
  /// discarded while a first is still in flight.
  private var editChain: Task<Bool, Never>?

  /// True when the change went through; false when it threw (the error is
  /// on `errorMessage`).
  @discardableResult
  private func performEdit(_ change: @escaping () async throws -> Void) async -> Bool {
    let prior = editChain
    let task = Task { [weak self] () -> Bool in
      _ = await prior?.value
      guard let self else { return false }
      return await self.runEdit(change)
    }
    editChain = task
    return await task.value
  }

  private func runEdit(_ change: () async throws -> Void) async -> Bool {
    isSavingEdit = true
    defer { isSavingEdit = false }
    do {
      try await change()
      await loadDetails()
      async let tagsTask = catalog.tagSummaries()
      async let projectsTask = catalog.projectSummaries()
      async let labelsTask = catalog.labelSummaries()
      tags = (try? await tagsTask) ?? tags
      projects = (try? await projectsTask) ?? projects
      labels = (try? await labelsTask) ?? labels
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// The one place that turns UI state into an `AssetQuery`. The sidebar selection,
  /// search field, and time filter compose here and nowhere else.
  ///
  /// `stripTimeBounds` removes only the time-filter contribution: a `.recent`,
  /// `.year` or `.month` selection keeps its own bounds, so the unfiltered
  /// count stays scoped to the selection.
  public func makeQuery(
    after cursor: AssetCursor? = nil,
    stripTimeBounds: Bool = false
  ) -> AssetQuery {
    var query = AssetQuery()
    query.limit = 120
    var sidebarSince: String?
    var sidebarUntil: String?
    switch sidebarSelection {
    case .project(let slug), .projectFolder(let slug, _), .projectFile(let slug, _):
      query.project = slug
    case .tag(let name):
      query.tag = name
    case .recent:
      let since = Self.iso8601.string(from: Date().addingTimeInterval(-30 * 24 * 3600))
      sidebarSince = since
      query.since = Self.later(query.since, since)
    case .year(let year):
      sidebarSince = "\(year)-01-01T00:00:00Z"
      sidebarUntil = Self.endOfYearExclusive(year)
      query.since = sidebarSince
      query.until = sidebarUntil
    case .month(let month):
      sidebarSince = "\(month)-01T00:00:00Z"
      sidebarUntil = Self.endOfMonthExclusive(month)
      query.since = sidebarSince
      query.until = sidebarUntil
    case let .keyPrefix(prefix, backend):
      query.keyPrefix = prefix
      query.backendID = backendID(backend) ?? -1
    case let .backend(slug):
      query.backendID = backendID(slug) ?? -1
    case .favorites:
      query.favoritesOnly = true
    case .label(let label):
      query.label = label
    case .overview, .orphans, .externals, .usage, .all, .archived:
      break
    }
    // Archived assets leave every default view — its grid, its
    // counts, and through them the tree counts — and show only
    // under Archived.
    query.state = sidebarSelection == .archived ? .archived : .active
    switch timeFilter {
    case .all:
      break
    case .last7Days:
      let since = Self.iso8601.string(from: Date().addingTimeInterval(-7 * 24 * 3600))
      query.since = Self.later(query.since, since)
    case .last30Days:
      let since = Self.iso8601.string(from: Date().addingTimeInterval(-30 * 24 * 3600))
      query.since = Self.later(query.since, since)
    case let .month(value):
      query.since = "\(value)-01T00:00:00Z"
      query.until = Self.endOfMonthExclusive(value)
    }
    if stripTimeBounds {
      query.since = sidebarSince
      query.until = sidebarUntil
    }
    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      query.search = searchText
      query.searchField = searchScope.field
      query.searchMatch = searchMatch
      query.searchCaseSensitive = searchCaseSensitive
    }
    if let sourceFilter {
      query.sources = [sourceFilter]
    }
    query.sort = sort
    query.after = cursor
    return query
  }

  /// Fills the Source popup's counts, on the basis "M" uses.
  public func refreshSourceCounts() async {
    var base = makeQuery(stripTimeBounds: true)
    base.search = nil
    base.searchField = .any
    base.sources = []
    base.after = nil
    do {
      var counts = SourceCounts()
      counts.all = try await catalog.count(base)
      for source in AssetSource.allCases {
        var query = base
        query.sources = [source]
        counts[source] = try await catalog.count(query)
      }
      sourceCounts = counts
    } catch {}
  }

  private static func later(_ current: String?, _ candidate: String) -> String? {
    guard let current else { return candidate }
    return candidate > current ? candidate : current
  }

  public static func endOfMonthExclusive(_ month: String) -> String {
    let parts = month.split(separator: "-")
    guard parts.count == 2,
      let year = Int(parts[0]),
      let monthNumber = Int(parts[1]), (1...12).contains(monthNumber)
    else {
      return month
    }
    let nextYear = monthNumber == 12 ? year + 1 : year
    let nextMonth = monthNumber == 12 ? 1 : monthNumber + 1
    return String(format: "%04d-%02d-01T00:00:00Z", nextYear, nextMonth)
  }

  /// The exclusive upper bound of a `yyyy` year: the first instant of the
  /// next one, so December is inside it.
  public static func endOfYearExclusive(_ year: String) -> String {
    guard let value = Int(year) else { return year }
    return String(format: "%04d-01-01T00:00:00Z", value + 1)
  }

  public func loadInitialData() async {
    await reload()
    async let tagsTask = catalog.tagSummaries()
    async let projectsTask = catalog.projectSummaries()
    async let labelsTask = catalog.labelSummaries()
    do {
      tags = try await tagsTask
      projects = try await projectsTask
      labels = try await labelsTask
    } catch {
      errorMessage = error.localizedDescription
    }
    resolveCollectionsDefault()
    // A launch onto a report surface loads no asset page, so no months yet.
    if availableMonths.isEmpty { await refreshMonths() }
    resolveTimeDefault()
    await refreshDomainBackends()
    // Read only: a launch shows what did not finish and sends nothing
    // (README rule 1 — no delete without a confirmed request).
    await refreshUnfinishedDeletions()
  }

  /// After Scan Now ingests a scan: the project list's scan times and the
  /// report being shown, read again — a usage sync does not move
  /// `changeStamp`, which fingerprints the asset table only.
  public func reloadAfterUsageScan() async {
    await refreshProjects()
    await refreshSourcedProjects()
    switch sidebarSelection {
    case .overview, .orphans, .externals, .usage: await reload()
    default: break
    }
  }

  /// The projects the scoped reports speak for: the current one, or all.
  public var reportScopeProjects: [ProjectSummary] {
    guard let slug = currentProjectSlug else { return projects }
    return projects.filter { $0.slug == slug }
  }

  /// The report scope less its not-tracked projects: their
  /// assets are not candidates, so Orphans neither counts them as never
  /// scanned nor lets them make the list Usage Unknown.
  public var orphanScopeProjects: [ProjectSummary] {
    let notTracked = Set(orphanReport?.notTrackedProjects ?? [])
    return reportScopeProjects.filter { !notTracked.contains($0.slug) }
  }

  private func reloadOverview() async {
    generation += 1
    let currentGeneration = generation
    showReportPlace()
    do {
      let stats = try await catalog.overviewStats(
        project: currentProjectSlug, calendar: overviewCalendar)
      guard generation == currentGeneration else { return }
      overviewStats = stats
      overviewError = nil
    } catch {
      guard generation == currentGeneration else { return }
      overviewError = error.localizedDescription
    }
  }

  public func refreshSourcedProjects() async {
    if let sourced = try? await catalog.sourcedProjects() { sourcedProjects = sourced }
  }

  public func reload() async {
    switch sidebarSelection {
    case .overview:
      await reloadOverview()
    case .orphans:
      await reloadOrphans()
    case .externals:
      await reloadExternals()
    case .usage:
      await reloadUsage()
    case .projectFolder, .projectFile:
      await reloadProjectSourceRows()
    default:
      await reloadAssets()
    }
    await refreshFolderChildrenIfCatalogChanged()
  }

  private func reloadAssets() async {
    generation += 1
    let currentGeneration = generation
    let place = NavigationHistory.Place(navigator, sidebarSelection)
    // Nothing the centre column draws changes until the rows are
    // here — the old place, its rows, its report snapshots and its error
    // stay up; the spinner waits for `slowSwitchDelay`.
    isLoadingPage = true
    isAwaitingRows = true
    isSlowToShow = false
    defer {
      if generation == currentGeneration {
        isLoadingPage = false
        isAwaitingRows = false
        isSlowToShow = false
      }
    }
    Task { [weak self] in
      try? await Task.sleep(for: Self.slowSwitchDelay)
      guard let self, self.generation == currentGeneration, self.isAwaitingRows else { return }
      self.isSlowToShow = true
    }
    SwitchTiming.begin("\(place.navigator) \(place.selection)")
    do {
      let query = makeQuery()
      let catalog = catalog
      let groupable = isMonthGroupable
      // Every query the first screen needs runs at once; each is a
      // millisecond or so (measured), so the counts come in with the page
      // and the status bar changes with the grid.
      async let pageTask = SwitchTiming.timed("page") { try await catalog.page(query) }
      async let countTask = SwitchTiming.timed("count") { try await catalog.count(query) }
      async let unfilteredTask = SwitchTiming.timed("unfiltered") {
        try await self.countUnfilteredSelection()
      }
      async let monthTotalsTask = SwitchTiming.timed("totals") {
        groupable ? try await catalog.availableMonths(matching: query) : []
      }
      let page = try await pageTask
      SwitchTiming.mark("page")
      guard generation == currentGeneration else { return }
      let loadedRows = Row.rows(from: page)
      let loadedDetails = try await SwitchTiming.timed("metadata") {
        try await fetchContextMenuMetadata(for: loadedRows)
      }
      SwitchTiming.mark("metadata")
      guard generation == currentGeneration else { return }
      let loadedMonthTotals = try await monthTotalsTask
      let count = try? await countTask
      let unfiltered = try? await unfilteredTask
      SwitchTiming.mark("counts")
      guard generation == currentGeneration else { return }
      // One synchronous step: SwiftUI draws all of it in one frame.
      contextMenuMetadata.merge(loadedDetails) { _, fresh in fresh }
      errorMessage = nil
      // Leaving the orphan/usage selections invalidates their snapshots: the
      // details fallback must not find items from a view that is no longer shown.
      orphanReport = nil
      orphanHealth = []
      usageBrowser = nil
      monthTotals = Dictionary(uniqueKeysWithValues: loadedMonthTotals.map { ($0.month, $0.count) })
      rows = loadedRows
      nextCursor = page.next
      canLoadMore = page.next != nil
      totalCount = count
      unfilteredTotalCount = unfiltered
      if shownPlace != place { shownPlace = place }
      hasShownAssets = true
      isLoadingPage = false
      isAwaitingRows = false
      isSlowToShow = false
      SwitchTiming.committed()
      if loadedRows.isEmpty { SwitchTiming.endWithoutCells() }
      // Not on the first screen: the inspector, then the Time tree's months.
      if selectedID != nil {
        await loadDetails()
        SwitchTiming.mark("details")
      }
      await SwitchTiming.timed("refreshMonths") { await refreshMonths() }
      SwitchTiming.mark("refreshMonths")
    } catch {
      guard generation == currentGeneration else { return }
      errorMessage = error.localizedDescription
      SwitchTiming.endWithoutCells()
    }
  }

  /// A report surface draws its own loading state, so it is shown from the
  /// moment its reload starts.
  private func showReportPlace() {
    let place = NavigationHistory.Place(navigator, sidebarSelection)
    if shownPlace != place { shownPlace = place }
    // An asset reload this one superseded left its wait behind.
    isAwaitingRows = false
    isSlowToShow = false
  }

  /// The count the bar's "N of M" needs: the same sidebar selection with
  /// the search and time filters stripped. Nil when no filter is active —
  /// it would equal the plain count — so the common case runs one query.
  private func countUnfilteredSelection() async throws -> Int? {
    guard searchOrTimeFilterIsActive else { return nil }
    var stripped = makeQuery(stripTimeBounds: true)
    stripped.search = nil
    stripped.searchField = .any
    stripped.sources = []
    stripped.after = nil
    return try await catalog.count(stripped)
  }

  /// True when the query the bar would describe is narrower than its
  /// selection — the only state in which "N of M" is a meaningful sentence.
  private var searchOrTimeFilterIsActive: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || timeFilter != .all
      || sourceFilter != nil
  }

  /// The orphan list considers every project, so its caveat must account for
  /// every project's scan history. The report supplies the under-scanned
  /// slugs; `projectSummaries` supplies the last-scan timestamps.
  private func reloadOrphans() async {
    generation += 1
    let currentGeneration = generation
    showReportPlace()
    isLoadingPage = true
    errorMessage = nil
    rows = []
    nextCursor = nil
    canLoadMore = false
    usageBrowser = nil
    // The report surfaces carry their own numbers; an asset count here
    // would describe a surface that is not being shown.
    totalCount = nil
    unfilteredTotalCount = nil
    defer { if generation == currentGeneration { isLoadingPage = false } }
    do {
      async let reportTask = catalog.orphans(project: currentProjectSlug)
      async let projectsTask = catalog.projectSummaries()
      async let sourcedTask = catalog.sourcedProjects()
      let report = try await reportTask
      guard generation == currentGeneration else { return }
      let loadedDetails = try await fetchContextMenuMetadata(
        for: report.assets.map(Row.init))
      guard generation == currentGeneration else { return }
      contextMenuMetadata.merge(loadedDetails) { _, fresh in fresh }
      orphanReport = report
      projects = (try? await projectsTask) ?? projects
      sourcedProjects = (try? await sourcedTask) ?? sourcedProjects
      orphanHealth = OrphanScanHealth.assess(
        projects: orphanScopeProjects,
        underScannedSlugs: report.unscannedProjects
      )
      if selectedID != nil {
        await loadDetails()
      }
    } catch {
      guard generation == currentGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func reloadUsageIfShown() {
    guard sidebarSelection == .usage else { return }
    Task { await reload() }
  }

  /// Usage over the current project — or all: the live
  /// references, cut by `UsageBrowser`; Images puts the referenced assets
  /// in `rows`, most used first, Files the selected file's.
  private func reloadUsage() async {
    generation += 1
    let currentGeneration = generation
    showReportPlace()
    isLoadingPage = true
    errorMessage = nil
    nextCursor = nil
    canLoadMore = false
    orphanReport = nil
    orphanHealth = []
    totalCount = nil
    unfilteredTotalCount = nil
    defer { if generation == currentGeneration { isLoadingPage = false } }
    do {
      async let usageTask = catalog.liveUsage(project: currentProjectSlug)
      async let domainLinksTask = catalog.domainLinks(
        prefixes: domainBackends.flatMap(\.prefixes), project: currentProjectSlug)
      async let projectsTask = catalog.projectSummaries()
      async let sourcedTask = catalog.sourcedProjects()
      let browser = UsageBrowser(
        try await usageTask, oldDomainsOnly: usageOldDomainsOnly, domain: usageDomain)
      guard generation == currentGeneration else { return }
      let assetRows = browser.usage.assets.values.map(Row.init)
      let loadedDetails = try await fetchContextMenuMetadata(for: assetRows)
      guard generation == currentGeneration else { return }
      contextMenuMetadata.merge(loadedDetails) { _, fresh in fresh }
      projects = (try? await projectsTask) ?? projects
      sourcedProjects = (try? await sourcedTask) ?? sourcedProjects
      usageFileDates = Dictionary(
        uniqueKeysWithValues: browser.files.compactMap { file in
          UsageSourceFile.url(
            project: file.projectSlug, path: file.path, sources: browser.usage.projectSources
          ).map { (file.id, usageFileDateReader($0)) }
        })
      usageDomainLinks = (try? await domainLinksTask) ?? [:]
      usageBrowser = browser
      if let scope = usageFolderScope, !browser.files.contains(where: { $0.projectSlug == scope.project }) {
        usageFolderScope = nil
      }
      switch usagePage {
      case .images:
        showUsageImages()
      case .files:
        if usageVisibleFiles.contains(where: { $0.id == usageSelectedFileID }) {
          showUsageFileImages()
        } else {
          usageSelectedFileID = usageVisibleFiles.first?.id
        }
      }
      if selectedID != nil {
        await loadDetails()
      }
    } catch {
      guard generation == currentGeneration else { return }
      usageBrowser = nil
      rows = []
      errorMessage = error.localizedDescription
    }
  }

  /// Images: grid, one section per file in the list's order, each file's
  /// images in the order they first appear in it (an image in two files
  /// stands in both, the second under an id of its own); table, one row
  /// per image, most used first, its references beneath.
  private func showUsageImages() {
    guard sidebarSelection == .usage, usagePage == .images, let browser = usageBrowser else {
      return
    }
    func imageRow(_ image: UsageImage) -> Row? {
      guard let item = browser.usage.assets[image.assetID] else { return nil }
      var row = Row(item)
      row.usage = .image(
        uses: image.uses, hasOldDomain: image.hasOldDomain, references: image.references)
      return row
    }
    guard viewMode == .grid else {
      rows = browser.images.compactMap(imageRow)
      selectedIDs = selectedIDs.filter { id in rows.contains { $0.id == id } }
      return
    }
    let images = Dictionary(uniqueKeysWithValues: browser.images.map { ($0.assetID, $0) })
    var seen: Set<Int64> = []
    var built: [Row] = []
    // The list's order with every folder open and no scope: grouped, the
    // directories in turn.
    let files =
      usageGroupsByFolder
      ? browser.fileListGroups(sort: usageFileSort, dates: usageFileDates, scope: nil)
        .flatMap(\.files)
      : browser.sortedFiles(by: usageFileSort, dates: usageFileDates)
    for file in files {
      for image in file.images {
        guard let usage = images[image.assetID], var row = imageRow(usage) else { continue }
        row.usageSection = UsageRowSection(fileID: file.id, line: image.line)
        if !seen.insert(image.assetID).inserted {
          row = Row(repeatOf: row, index: built.count)
          row.repeatsPreviousImage = false
        }
        built.append(row)
      }
    }
    rows = built
    selectedIDs = selectedIDs.filter { id in rows.contains { $0.id == id } }
  }

  /// The file list as drawn: the files in the folder scope, grouped
  /// by directory when the list groups, in `usageFileSort`'s order.
  public var usageFileListGroups: [UsageFileListGroup] {
    usageBrowser?.fileListGroups(
      sort: usageFileSort, dates: usageFileDates, scope: usageFolderScope) ?? []
  }

  /// The files the list shows, top to bottom — what ↑ ↓ walk. A collapsed
  /// group's files are hidden; ungrouped, every file in scope shows.
  public var usageVisibleFiles: [UsageFile] {
    let groups = usageFileListGroups
    guard usageGroupsByFolder else {
      return usageBrowser?.sortedFiles(by: usageFileSort, dates: usageFileDates)
        .filter { file in groups.contains { $0.files.contains(file) } } ?? []
    }
    return groups.filter { !usageCollapsedGroups.contains($0.id) }.flatMap(\.files)
  }

  /// ↑ ↓ in the file list: the next visible file, stopping at the ends.
  public func moveUsageFileSelection(by step: Int) {
    let files = usageVisibleFiles
    guard !files.isEmpty else { return }
    guard let index = files.firstIndex(where: { $0.id == usageSelectedFileID }) else {
      usageSelectedFileID = files[step > 0 ? 0 : files.count - 1].id
      return
    }
    usageSelectedFileID = files[min(max(index + step, 0), files.count - 1)].id
  }

  /// A group's folder glyph: open ⇄ closed.
  public func toggleUsageGroup(_ id: String) {
    if usageCollapsedGroups.contains(id) {
      usageCollapsedGroups.remove(id)
    } else {
      usageCollapsedGroups.insert(id)
    }
  }

  /// A narrowed list keeps its selection only when the file still shows.
  private func keepUsageFileSelectionVisible() {
    let files = usageVisibleFiles
    if !files.contains(where: { $0.id == usageSelectedFileID }) {
      usageSelectedFileID = files.first?.id
    }
  }

  /// The file a Usage cell belongs to: Files' selected file, or the grid
  /// section an Images cell sits in — the jump bar's file segment.
  public var usageContextFile: UsageFile? {
    guard shownSelection == .usage, let browser = usageBrowser else { return nil }
    switch usagePage {
    case .files:
      return browser.files.first { $0.id == usageSelectedFileID }
    case .images:
      guard let id = selectedID, let section = rows.first(where: { $0.id == id })?.usageSection
      else { return nil }
      return browser.files.first { $0.id == section.fileID }
    }
  }

  /// The jump bar's file segment: that file on Usage ▸ Files, the image
  /// selection cleared.
  public func openUsageContextFile() {
    guard let file = usageContextFile else { return }
    usageFolderScope = nil
    usageCollapsedGroups.remove(
      usageFileListGroups.first { $0.files.contains(file) }?.id ?? "")
    if usagePage != .files { usagePage = .files }
    usageSelectedFileID = file.id
    clearSelection()
  }

  /// An Images section's "Show in Files".
  public func showUsageFileInFiles(_ id: UsageFile.ID) {
    usageFolderScope = nil
    usagePage = .files
    usageSelectedFileID = id
  }

  /// Files: the selected file's references in `rows`, in line order, each
  /// with its line (an image used twice shows twice; its
  /// later cells are marked for "same as above").
  private func showUsageFileImages() {
    guard sidebarSelection == .usage, usagePage == .files, let browser = usageBrowser else {
      return
    }
    let file = browser.files.first { $0.id == usageSelectedFileID }
    var seen: Set<Int64> = []
    rows = (file?.occurrences ?? []).enumerated().compactMap { index, occurrence in
      guard let item = browser.usage.assets[occurrence.assetID] else { return nil }
      var row = Row(item)
      row.usage = .line(occurrence.line)
      if seen.contains(occurrence.assetID) {
        row = Row(repeatOf: row, index: index)
      }
      seen.insert(occurrence.assetID)
      return row
    }
    selectedIDs = selectedIDs.filter { id in rows.contains { $0.id == id } }
  }

  private func reloadExternals() async {
    generation += 1
    let currentGeneration = generation
    showReportPlace()
    isLoadingPage = true
    errorMessage = nil
    rows = []
    nextCursor = nil
    canLoadMore = false
    orphanReport = nil
    orphanHealth = []
    usageBrowser = nil
    totalCount = nil
    unfilteredTotalCount = nil
    defer { if generation == currentGeneration { isLoadingPage = false } }
    async let projectsTask = catalog.projectSummaries()
    await externals.load()
    guard generation == currentGeneration else { return }
    projects = (try? await projectsTask) ?? projects
  }

  /// Called when a cell becomes visible near the end of the list. Positions in
  /// `rows` decide nearness — database ids are neither contiguous nor ordered by
  /// position (`uploaded_at DESC, id DESC` puts the largest id first, and
  /// `reindex` assigns ids in listing order).
  public func loadNextPageIfNearEnd(visibleRowID: Int64) {
    guard canLoadMore, !isLoadingPage,
      let index = rows.firstIndex(where: { $0.id == visibleRowID }),
      index >= rows.count - 20
    else { return }
    Task { await loadNextPage() }
  }

  public func loadNextPage() async {
    guard canLoadMore, !isLoadingPage, let cursor = nextCursor else { return }
    isLoadingPage = true
    let requestGeneration = generation
    defer { if generation == requestGeneration { isLoadingPage = false } }
    do {
      let page = try await catalog.page(makeQuery(after: cursor))
      guard generation == requestGeneration else { return }
      let known = Set(rows.map(\.id))
      let appendedRows = Row.rows(from: page).filter { !known.contains($0.id) }
      let loadedDetails = try await fetchContextMenuMetadata(for: appendedRows)
      guard generation == requestGeneration else { return }
      contextMenuMetadata.merge(loadedDetails) { _, fresh in fresh }
      rows.append(contentsOf: appendedRows)
      nextCursor = page.next
      canLoadMore = page.next != nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// The time navigator's tree is built from these, so they cover the whole
  /// catalog: scoped to the selection, selecting a month would prune
  /// every other month out of the tree it was selected from.
  private func refreshMonths() async {
    do {
      var active = AssetQuery()
      active.state = .active
      let months = try await catalog.availableMonths(matching: active)
      // A view switch does not change the catalog's months; an
      // unchanged list must not publish (every observer of the model would
      // draw again — measured 50 ms on the Time navigator).
      guard !months.elementsEqual(availableMonths, by: { $0 == $1 }) else { return }
      availableMonths = months
    } catch {
      if !availableMonths.isEmpty { availableMonths = [] }
    }
  }

  /// Rows are not published to either grid until their menu details exist.
  /// This removes the race where a fast secondary click could construct a
  /// submenu before a per-cell task learned its project membership.
  private func fetchContextMenuMetadata(
    for rows: [Row]
  ) async throws -> [String: ContextMenuMetadata] {
    let missing = rows.filter { contextMenuMetadata[$0.item.asset.sha256] == nil }
    guard !missing.isEmpty else { return [:] }
    let memberships = try await catalog.projectMemberships(assetIDs: missing.map(\.id))
    var loaded: [String: ContextMenuMetadata] = [:]
    for row in missing {
      let identifier = row.item.asset.sha256
      loaded[identifier] = ContextMenuMetadata(
        memberSlugs: memberships[row.id] ?? [],
        note: row.item.asset.note
      )
    }
    return loaded
  }

  private func loadDetails() async {
    detailsGeneration += 1
    let requestGeneration = detailsGeneration
    guard let identifier = selectedIdentifier else {
      selectedDetails = nil
      usedIn = nil
      return
    }
    do {
      let details = try await catalog.details(identifier)
      var usage: LiveUsageSet?
      if let assetID = details.item.asset.id {
        usage = try? await catalog.liveUsage(assetID: assetID)
      }
      guard detailsGeneration == requestGeneration else { return }
      selectedDetails = details
      usedIn = usage.map(UsedInState.init)
      contextMenuMetadata[identifier] = ContextMenuMetadata(
        memberSlugs: Set(details.projects.map(\.slug)),
        note: details.item.asset.note
      )
      if noteDraftOwner != identifier {
        // Repopulate only when the selection itself changes; an unrelated edit
        // must never clobber in-progress note text.
        noteDraftOwner = identifier
        noteDraft = details.item.asset.note ?? ""
      }
    } catch is CancellationError {
      return
    } catch {
      guard detailsGeneration == requestGeneration else { return }
      selectedDetails = nil
      usedIn = nil
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - Usage actions

  /// What Usage adds to a row's menu. Images: Show in Library, and Copy New
  /// URL when a reference is on an old domain; a table child row adds Open
  /// File / Reveal for its own reference. Files: Open File / Reveal for the
  /// selected file, Copy New URL when this image's lines in it are old.
  public func usageMenuItems(for row: Row) -> [UsageMenuItem] {
    guard sidebarSelection == .usage, let usage = row.usage, let browser = usageBrowser else {
      return []
    }
    let references: [UsageReferenceRow]
    var file: (project: String, path: String)?
    switch usage {
    case let .image(_, _, all):
      references = all
    case let .reference(reference):
      references = [reference]
      file = (reference.reference.projectSlug, reference.file)
    case .line:
      guard let selected = browser.files.first(where: { $0.id == usageSelectedFileID }) else {
        return []
      }
      references = (browser.image(row.item.asset.id ?? 0)?.references ?? []).filter {
        $0.reference.projectSlug == selected.projectSlug && $0.file == selected.path
      }
      file = (selected.projectSlug, selected.path)
    }
    var items: [UsageMenuItem] = []
    if let file,
      let url = UsageSourceFile.url(
        project: file.project, path: file.path, sources: browser.usage.projectSources)
    {
      items += [.openFile(url), .revealInFinder(url)]
    }
    if references.contains(where: \.reference.isOldDomain) {
      items.append(.copyNewURL(URLResolver.url(for: row.item.asset, backend: row.item.backend)))
    }
    if usagePage == .images, let id = row.item.asset.id {
      items.append(.showInLibrary(id))
    }
    return items
  }

  /// Files: the selected file, when the Open File rule lets Pinax open it.
  public func usageFileURL(_ file: UsageFile) -> URL? {
    guard let browser = usageBrowser else { return nil }
    return UsageSourceFile.url(
      project: file.projectSlug, path: file.path, sources: browser.usage.projectSources)
  }

  /// The import result bar's Show in Usage — Usage ▸ Images,
  /// where the imported images now are, with no Scan Now.
  public func showImportedInUsage() {
    usageOldDomainsOnly = false
    usagePage = .images
    select(.usage, in: .reports)
  }

  /// Show in Library by key (a same image's inspector).
  public func showInLibrary(key: String) async {
    guard let id = try? await catalog.details(key).item.asset.id else { return }
    await showInLibrary(assetID: id)
  }

  /// After an Externals import — new assets, relinked usage — the
  /// project counts and the folder tree are read again.
  func reloadAfterExternalsImport() async {
    await refreshProjects()
    await refreshFolderChildrenIfCatalogChanged()
    // Externals reloaded itself; another report shown meanwhile reads again.
    switch sidebarSelection {
    case .overview, .orphans, .usage: await reload()
    default: break
    }
  }

  /// Show in Library: Library ▸ All Assets with the asset selected, paging
  /// until it is loaded.
  public func showInLibrary(assetID: Int64) async {
    select(.all, in: .library)
    await reload()
    while !rows.contains(where: { $0.id == assetID }), canLoadMore {
      await loadNextPage()
    }
    if let row = rows.first(where: { $0.id == assetID }) {
      select(row, mode: .replace)
    }
  }

  /// Used In ▸ Show All (N): Usage ▸ Images as a table, this image selected
  /// and its row open. The current project stays unless it does not use
  /// the image; then All Projects.
  public func showAllUsage(of assetID: Int64) async {
    if case let .used(_, _, projects) = usedIn, let slug = currentProjectSlug,
      !projects.contains(slug)
    {
      currentProjectSlug = nil
    }
    usagePage = .images
    viewMode = .table
    usageExpandedIDs.insert(assetID)
    select(.usage, in: .reports)
    await reload()
    if let row = rows.first(where: { $0.id == assetID }) {
      select(row, mode: .replace)
    }
  }

  // MARK: - Selection

  /// `.replace` and `.toggle` move the anchor to `row`; `.extend` keeps it
  /// and adds anchor…row in display order. The anchor is the last clicked
  /// row, not the first selected one: A, ⌘C, ⇧E is A + C…E, not A…E.
  public func select(_ row: Row, mode: SelectionMode) {
    selectionCursor = row.id
    switch mode {
    case .replace:
      selectedIDs = [row.id]
      selectionAnchor = row.id
    case .toggle:
      if selectedIDs.contains(row.id) {
        selectedIDs.remove(row.id)
      } else {
        selectedIDs.insert(row.id)
      }
      selectionAnchor = row.id
    case .extend:
      let order = selectableRows.map(\.id)
      guard let anchor = selectionAnchor,
            let from = order.firstIndex(of: anchor),
            let to = order.firstIndex(of: row.id)
      else {
        select(row, mode: .replace)
        return
      }
      let range = order[min(from, to)...max(from, to)]
      selectedIDs.formUnion(range)
    }
  }

  public func select(_ row: Row) {
    select(row, mode: .replace)
  }

  /// What a cell click does: the selection action from its
  /// modifiers — ⇧ extends from the anchor, ⌘ toggles, a plain click
  /// replaces; ⇧ wins when both are held, as in Finder — and whether it
  /// opens Quick Look: a plain double-click does, after selecting exactly
  /// as its first click did. Read off the click's own event, so a cell
  /// carries one tap gesture and a single click waits for nothing.
  public struct CellClick: Equatable, Sendable {
    public let mode: SelectionMode
    public let opensQuickLook: Bool
  }

  public static func cellClick(
    clickCount: Int, modifiers: NSEvent.ModifierFlags
  ) -> CellClick {
    let mode: SelectionMode =
      modifiers.contains(.shift) ? .extend : modifiers.contains(.command) ? .toggle : .replace
    return CellClick(mode: mode, opensQuickLook: clickCount >= 2 && mode == .replace)
  }

  /// Every asset grid's cell tap — ungrouped, by month, Orphans: `cellClick`
  /// of the event being handled. `clickCount` is read only off a mouse
  /// event (AppKit raises on any other); anything else counts as one click.
  public func clickCell(_ row: Row) {
    let event = currentEvent()
    let mouse: Set<NSEvent.EventType> = [
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
    ]
    let clickCount = event.flatMap { mouse.contains($0.type) ? $0.clickCount : nil } ?? 1
    let click = Self.cellClick(clickCount: clickCount, modifiers: event?.modifierFlags ?? [])
    select(row, mode: click.mode)
    if click.opensQuickLook { openQuickLook() }
  }

  /// Whether a surface shows the asset selection: not Usage or
  /// Externals, which list references, not assets. The selection itself
  /// stays; the jump bar, the status bar and the inspector ask this.
  public static func showsAssetSelection(on surface: SidebarSelection) -> Bool {
    switch surface {
    // Overview draws no assets: a selection made elsewhere is not its own.
    case .externals, .overview: return false
    default: return true
    }
  }

  public var showsAssetSelection: Bool { Self.showsAssetSelection(on: shownSelection) }

  /// ⌘A selects the rows loaded so far — "120 selected" on a long catalog is
  /// the honest answer; the rest of the library is not fetched.
  public func selectAllLoaded() {
    selectedIDs = Set(selectableRows.map(\.id))
  }

  public func clearSelection() {
    selectedIDs = []
    selectionAnchor = nil
    selectionCursor = nil
  }

  // MARK: - Keyboard navigation

  public enum GridMove: Sendable {
    case left, right, up, down, home, end
  }

  /// One key on the focused grid: moves the cursor and selects the row it
  /// lands on — `.extend` from the unchanged anchor when ⇧ is held. Returns
  /// the row to scroll into view, nil when nothing moved. Pure selection
  /// state: nothing here is a query input.
  @discardableResult
  public func moveSelection(_ move: GridMove, extending: Bool = false) -> Row? {
    guard let target = moveTarget(move) else { return nil }
    select(target, mode: extending ? .extend : .replace)
    return target
  }

  /// ← → walk the display order across month sections; ↑ ↓ keep the column
  /// on the rows the grid actually draws — each month section wraps on its
  /// own — and land on a shorter row's last cell. With nothing
  /// selected, any key starts at the first row.
  func moveTarget(_ move: GridMove) -> Row? {
    let order = rows
    guard let first = order.first, let last = order.last else { return nil }
    guard let cursor = selectionCursor ?? selectionAnchor,
      let index = order.firstIndex(where: { $0.id == cursor })
    else {
      return move == .end ? last : first
    }
    switch move {
    case .home: return first
    case .end: return last
    case .left: return index > 0 ? order[index - 1] : nil
    case .right: return index + 1 < order.count ? order[index + 1] : nil
    case .up, .down:
      let lines = visualLines
      guard
        let line = lines.firstIndex(where: { $0.contains { $0.id == cursor } }),
        let column = lines[line].firstIndex(where: { $0.id == cursor })
      else { return nil }
      let next = move == .up ? line - 1 : line + 1
      guard lines.indices.contains(next) else { return nil }
      return lines[next][min(column, lines[next].count - 1)]
    }
  }

  /// The grid's drawn rows: `gridColumns` wide, cut per month section when
  /// the grid groups (a section's last row may be short).
  private var visualLines: [[Row]] {
    let columns = max(1, gridColumns)
    let sections = showsRowSections ? groupedRows.map(\.rows) : [rows]
    return sections.flatMap { section in
      stride(from: 0, to: section.count, by: columns).map {
        Array(section[$0..<min($0 + columns, section.count)])
      }
    }
  }

  /// Total bytes of the selected rows that are loaded on this surface; the
  /// status bar's multi-selection summary.
  public var selectedByteTotal: Int64 {
    selectableRows.filter { selectedIDs.contains($0.id) }
      .reduce(0) { $0 + $1.item.asset.byteSize }
  }

  /// The rows a selection ranges over, in display order: the orphan grid's
  /// on the orphan surface (the "Not yet scanned" group only while open;
  /// the whole report, as before, while Usage Unknown stands in for the
  /// grid), otherwise the query's.
  private var selectableRows: [Row] {
    if sidebarSelection == .orphans, let report = orphanReport {
      let notTracked = Set(report.notTrackedProjects)
      let content = ReportHeaderModel.compose(
        orphanCandidates: report.assets.count, health: orphanHealth,
        projects: projects.filter { !notTracked.contains($0.slug) }
      ).content
      guard content == .candidates else { return report.assets.map(Row.init) }
      let split = ReportHeaderModel.splitOrphans(report, health: orphanHealth)
      return (split.scanned + (showsNotYetScannedOrphans ? split.notYetScanned : []))
        .map(Row.init)
    }
    return rows
  }

  /// The selection in display order, for `.selection` targets.
  private var orderedSelection: [Int64] {
    selectableRows.map(\.id).filter(selectedIDs.contains)
  }
}

// MARK: - Quick Look panel → selection

extension GalleryModel: QuickLookNavigator {
  func quickLookMove(_ move: GridMove) {
    if let gridKeyboardMove {
      gridKeyboardMove(move)
    } else {
      moveSelection(move)
    }
  }

  func quickLookToggle() {
    toggleQuickLookFromCommand()
  }

  /// The panel stepped to a neighbour (◀ ▶, ← →): the grid takes the same
  /// step, scrolling with it; any other jump selects the row outright.
  func quickLookDidMove(to id: Int64) {
    let rows = selectableRows
    guard let target = rows.firstIndex(where: { $0.id == id }) else { return }
    let current = selectedID.flatMap { selected in rows.firstIndex { $0.id == selected } }
    if gridKeyboardMove != nil, let current, abs(target - current) == 1 {
      quickLookMove(target > current ? .right : .left)
    } else {
      select(rows[target])
    }
  }

  func quickLookError(_ message: String?) {
    quickLookErrorMessage = message
  }
}
