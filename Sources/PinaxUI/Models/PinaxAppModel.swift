import AppKit
import CatalogCore
import Combine
import Foundation
import GRDB

/// One row of the menu bar's "Recent Uploads" section: the newest assets in
/// the catalog, copied to the clipboard on click.
public struct RecentUpload: Identifiable, Hashable, Sendable {
  public let id: Int64
  public let filename: String
  public let url: String
  /// The thumbnail cache's key for the panel's grid.
  public let sha256: String

  public init(id: Int64, filename: String, url: String, sha256: String = "") {
    self.id = id
    self.filename = filename
    self.url = url
    self.sha256 = sha256
  }

  /// How many uploads the menu bar panel's RECENT grid shows (4 × 2).
  public static let limit = 8

  /// The newest `CatalogAssetItem`s become grid cells; filename falls
  /// back to the key when no original filename was recorded.
  public static func make(from items: [CatalogAssetItem]) -> [RecentUpload] {
    items.prefix(limit).map { item in
      RecentUpload(
        id: item.asset.id ?? 0,
        filename: item.asset.originalFilename
          ?? (item.asset.key as NSString).lastPathComponent,
        url: item.url,
        sha256: item.asset.sha256
      )
    }
  }
}

/// The app shell's model: owns the one `DatabasePool`, the thumbnail cache
/// shared by the gallery and the drop zone, and the drop zone itself. The
/// gallery is published once the catalog has opened.
@MainActor
public final class PinaxAppModel: ObservableObject {
  @Published public private(set) var gallery: GalleryModel?
  @Published public private(set) var dropZone: DropZoneController?
  /// The Projects settings pane's model. Absent until the catalog opens
  /// (and forever if it failed to) — the pane says so instead of guessing.
  @Published public private(set) var projectSettings: ProjectSettingsModel?
  @Published public private(set) var maintenance: MaintenanceModel?
  @Published public private(set) var backup: BackupModel?
  @Published public private(set) var usageSync: UsageSyncModel?
  @Published public private(set) var backends: BackendsModel?
  @Published public private(set) var openError: String?
  @Published public private(set) var recentUploads: [RecentUpload] = []
  /// The menu bar's statistics card and Library page: the
  /// current project's numbers, read wherever `recentUploads` is.
  @Published public private(set) var menuBarStats: CatalogStats?
  /// The Settings window's page; Add Source… and Open Project Settings…
  /// on the reports turn it to Projects.
  @Published public var settingsTab: SettingsTab = .general
  /// The catalog's projects, for the Project menu;
  /// mirrored from the drop zone's list, which the same menu writes into.
  @Published public private(set) var projects: [Project] = []
  /// The projects with sources — what the Project menu's Scan Now can scan.
  @Published public private(set) var sourcedProjects: Set<String> = []
  /// Whether the catalog is empty, mirrored from the
  /// backup model so File ▸ Import / Export re-evaluate.
  @Published public private(set) var isCatalogEmpty: Bool?
  /// The folder watcher and the schedule, from the moment the catalog opens.
  private(set) var autoScan: AutoScanEngine?
  /// How many times a restore has reloaded the catalog's readers.
  public private(set) var catalogRestoreReloads = 0

  /// Machine-local preferences. Views that bind to a preference observe
  /// the store directly; this model only wires its side effects.
  public let preferences: PreferencesStore
  /// What the menu bar icon shows besides the chosen
  /// image — upload progress, unseen failures, the ✓ after a copy.
  public let menuBarActivity = MenuBarActivity()

  private let defaults: UserDefaults
  /// Opening the catalog is injected so tests can hand over a seeded
  /// temporary database; production keeps the real `Database.open()`.
  private let databaseOpener: () throws -> DatabasePool
  /// Scan Now's synchronizer and the Sources table's folder chooser are
  /// injected so tests record the scan and never open a panel.
  private let usageSynchronizer: ((DatabasePool) -> UsageSyncing)?
  /// Which commands this Mac allows, and what runs them: shared by every
  /// scan the app starts, an apply's rescans included.
  let commandApprovals: CommandApprovalStore
  private let commandRunner: CommandSourceRunning
  private let scanClock: ScanClock
  private let wakeNotifications: NotificationCenter
  private let chooseSourceFolder: @MainActor (String?) -> URL?
  private let chooseRunFolder: @MainActor (String?) -> URL?
  /// The backup panels and the credential lookup behind a restore's
  /// follow-ups: injected so tests open no panel and read no
  /// Keychain.
  private let chooseBackupFile: @MainActor () -> URL?
  private let chooseBackupDestination: @MainActor (String) -> URL?
  private let credentialExists: @Sendable (String) throws -> Bool
  /// How Delete Permanently reaches a bucket — the
  /// Keychain and `S3ObjectDeleter`; tests pass a stub on a `.invalid` host.
  private let deletionRemote: DeletionRemote
  private var backupCancellable: AnyCancellable?
  private var preferencesCancellable: AnyCancellable?
  private var projectCancellables: Set<AnyCancellable> = []

  /// Puts the chosen Dock icon on the tile from
  /// launch on, whichever window opens first — installed by `init`, which
  /// the app runs before any scene exists.
  public private(set) var dockIconApplier: DockIconApplier?

  /// - Parameter dockIcon: builds the Dock icon applier. The default sets
  ///   the real tile and follows the system; tests pass their own setter.
  public init(
    dockIcon: @MainActor (PreferencesStore) -> DockIconApplier = DockIconApplier.system,
    defaults: UserDefaults = .standard,
    databaseOpener: @escaping () throws -> DatabasePool = { try PinaxAppModel.openCatalog() },
    usageSynchronizer: ((DatabasePool) -> UsageSyncing)? = nil,
    commandRunner: CommandSourceRunning = ShellCommandRunner(),
    scanClock: ScanClock = SystemScanClock(),
    wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
    chooseSourceFolder: @escaping @MainActor (String?) -> URL? = SourceFolderOpenPanel.choose,
    chooseRunFolder: @escaping @MainActor (String?) -> URL? =
      SourceFolderOpenPanel.chooseRunFolder,
    chooseBackupFile: @escaping @MainActor () -> URL? = BackupOpenPanel.choose,
    chooseBackupDestination: @escaping @MainActor (String) -> URL? = BackupSavePanel.choose(
      defaultFilename:),
    credentialExists: @escaping @Sendable (String) throws -> Bool = {
      try Keychain().load(for: $0) != nil
    },
    deletionRemote: @escaping DeletionRemote = { try DeletingCatalog.keychainRemote($0) }
  ) {
    self.deletionRemote = deletionRemote
    self.chooseBackupFile = chooseBackupFile
    self.chooseBackupDestination = chooseBackupDestination
    self.credentialExists = credentialExists
    self.defaults = defaults
    self.databaseOpener = databaseOpener
    self.usageSynchronizer = usageSynchronizer
    self.commandApprovals = CommandApprovalStore(defaults: defaults)
    self.commandRunner = commandRunner
    self.scanClock = scanClock
    self.wakeNotifications = wakeNotifications
    self.chooseSourceFolder = chooseSourceFolder
    self.chooseRunFolder = chooseRunFolder
    let preferences = PreferencesStore(defaults: defaults)
    self.preferences = preferences
    Clipboard.onCopy = { [weak self] in self?.menuBarActivity.noteCopy() }
    preferences.onDropZoneEnabledChange = { [weak self] enabled in
      self?.dropZone?.setEnabled(enabled)
    }
    // The zone model reads its behaviour inputs at decision time (drag
    // sample, batch settle), but owns no preferences: the shell pushes the
    // store's values in whenever any preference changes.
    preferencesCancellable = preferences.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.syncDropZoneBehaviour() }
    let applier = dockIcon(preferences)
    applier.start()
    dockIconApplier = applier
  }

  /// Opens the catalog and brings its schema up to date, as every CLI
  /// command does: launching the app is an implicit `migrate`. A catalog created before a new
  /// migration — `v2_favorite_label`, say — otherwise opens without its tables, and the
  /// first query that reads them fails.
  nonisolated public static func openCatalog(at url: URL? = nil) throws -> DatabasePool {
    let database = try Database.open(at: url)
    try Database.migrate(database)
    return database
  }

  public func start() async {
    guard gallery == nil, openError == nil else { return }
    do {
      let database = try databaseOpener()
      let thumbnails = ThumbnailCache()
      let quickLook = QuickLookController(thumbnails: thumbnails)
      let manifestExport = ManifestExportModel(
        exporter: CatalogManifestExporter(database: database),
        chooseDestination: ManifestSavePanel.choose(defaultFilename:))
      let settings = ProjectSettingsModel(
        store: CatalogProjectSettingsStore(database: database),
        chooseFolder: chooseSourceFolder, chooseRunFolder: chooseRunFolder)
      settings.load()
      let galleryModel = GalleryModel(
        catalog: ReadOnlyCatalog(database: database),
        editor: EditableCatalog(database: database),
        deleter: DeletingCatalog(database: database, remote: deletionRemote),
        thumbnails: thumbnails,
        quickLook: quickLook,
        externalsClaimer: CatalogExternalsClaimer(database: database),
        externalsMigrator: CatalogExternalsMigrator(
          database: database, commands: commandApprovals.policy, runner: commandRunner),
        domainMigrator: CatalogDomainMigrator(
          database: database, commands: commandApprovals.policy, runner: commandRunner),
        manifestExport: manifestExport,
        projectSettings: settings,
        gridOverlays: preferences.gridOverlays,
        gridThumbnailSizing: preferences.gridThumbnailSizing,
        gridColumns: preferences.gridColumns,
        tableRowHeight: preferences.tableRowHeight,
        groupsByMonth: preferences.gridGroupsByMonth,
        libraryShortcuts: preferences.libraryShortcuts,
        sort: preferences.gallerySort,
        navigator: preferences.sidebarNavigator,
        externalsSort: preferences.externalsSort,
        externalsGroupsByFile: preferences.externalsGroupsByFile,
        externalsTipDismissed: preferences.externalsTipDismissed
      )
      // Same writeback shape as the zoom rung — the window owns
      // the navigator while running, the store remembers it for next launch.
      galleryModel.onNavigatorChange = { [preferences] navigator in
        preferences.sidebarNavigator = navigator
      }
      // The gallery owns the rung while running; every change writes
      // back to the one store, so the next launch resumes at the same zoom.
      galleryModel.onGridColumnsChange = { [preferences] columns in
        preferences.gridColumns = columns
      }
      galleryModel.onRequestUpload = { [weak self] in
        self?.pickFilesAndUpload()
      }
      // The table's row rung, the same way and apart from it.
      galleryModel.onTableRowHeightChange = { [preferences] height in
        preferences.tableRowHeight = height
      }
      galleryModel.onGroupsByMonthChange = { [preferences] groups in
        preferences.gridGroupsByMonth = groups
      }
      // The header menu writes the gallery,
      // Settings writes the store; each carries it to the other.
      galleryModel.onLibraryShortcutsChange = { [preferences] shortcuts in
        preferences.libraryShortcuts = shortcuts
      }
      preferences.onLibraryShortcutsChange = { [weak galleryModel] shortcuts in
        galleryModel?.libraryShortcuts = shortcuts
      }
      // Externals' order, Group by File and the
      // card's ✕, written back the same way.
      galleryModel.externals.onSortChange = { [preferences] sort in
        preferences.externalsSort = sort
      }
      galleryModel.externals.onGroupsByFileChange = { [preferences] groups in
        preferences.externalsGroupsByFile = groups
      }
      galleryModel.externals.onTipDismissed = { [preferences] in
        preferences.externalsTipDismissed = true
      }
      galleryModel.onGridOverlaysChange = { [preferences] overlays in
        preferences.gridOverlays = overlays
      }
      galleryModel.onGridThumbnailSizingChange = { [preferences] sizing in
        preferences.gridThumbnailSizing = sizing
      }
      preferences.onGridOverlaysChange = { [weak galleryModel] overlays in
        galleryModel?.gridOverlays = overlays
      }
      preferences.onGridThumbnailSizingChange = { [weak galleryModel] sizing in
        galleryModel?.gridThumbnailSizing = sizing
      }
      // One order, mirrored both ways like the overlays —
      // View ▸ Sort By writes the store, the jump bar and the table
      // headers write the gallery, and the store carries it to next launch.
      galleryModel.onSortChange = { [preferences] sort in
        preferences.gallerySort = sort
      }
      preferences.onGallerySortChange = { [weak galleryModel] sort in
        galleryModel?.sort = sort
      }
      galleryModel.copyFormats = preferences.copyFormats
      galleryModel.defaultCopyFormat = preferences.defaultCopyFormat
      preferences.onCopyFormatsChange = { [weak galleryModel] formats, defaultFormat in
        galleryModel?.copyFormats = formats
        galleryModel?.defaultCopyFormat = defaultFormat
      }
      galleryModel.downloadFolder = preferences.downloadFolder
      preferences.onDownloadFolderChange = { [weak galleryModel] folder in
        galleryModel?.downloadFolder = folder
      }
      let zoneModel = DropZoneModel(
        service: UploadCatalog(database: database),
        thumbnails: thumbnails,
        quickLook: quickLook
      )
      zoneModel.onUploadsSettled = { [weak galleryModel, weak self] in
        guard let galleryModel else { return }
        Task {
          await galleryModel.loadInitialData()
          await self?.refreshRecentUploads()
          await self?.backup?.refreshCatalogState()
        }
      }
      zoneModel.urlCopier = { Clipboard.copy($0) }
      zoneModel.onUploadCountsChange = { [weak self] counts in
        self?.menuBarActivity.setUploads(counts)
      }
      zoneModel.onUploadFailed = { [weak self] in
        self?.menuBarActivity.noteFailure()
      }
      zoneModel.onWindowDidShow = { [weak self] in
        self?.menuBarActivity.markFailuresSeen()
      }
      // A permanent delete takes the images' cards out
      // of the drop zone, and the menu bar's Recent Uploads re-reads.
      galleryModel.onAssetsDeleted = { [weak zoneModel, weak self] sha256s in
        zoneModel?.removeCards(for: sha256s)
        Task { await self?.refreshRecentUploads() }
      }
      // The drop zone's uploads show in the main window's status bar.
      zoneModel.onUploadProgressChange = { [weak galleryModel] progress in
        galleryModel?.uploadProgress = progress
      }
      let controller = DropZoneController(model: zoneModel, preferences: preferences)
      // One current project. The store holds it; the drop
      // zone's picker and the gallery's report scope mirror it, and the
      // picker writes back. Loading the projects turns a deleted project
      // into All Projects through the same write-back.
      zoneModel.selectedProjectSlug = preferences.currentProjectSlug
      galleryModel.currentProjectSlug = preferences.currentProjectSlug
      // Upload into: with Current Project (the default) all of the
      // above holds; with a fixed choice the panel starts there each time
      // it appears and its picker changes only that appearance.
      zoneModel.onSelectedProjectChange = { [weak self, preferences] slug in
        guard self?.dropZoneMirrorsCurrentProject ?? true else { return }
        preferences.currentProjectSlug = slug
      }
      preferences.onCurrentProjectChange = { [weak self, weak zoneModel, weak galleryModel] slug in
        if self?.dropZoneMirrorsCurrentProject ?? true {
          zoneModel?.selectedProjectSlug = slug
        }
        galleryModel?.currentProjectSlug = slug
        Task { await self?.refreshMenuBarStats() }
      }
      zoneModel.onWindowWillShow = { [weak self] in self?.startDropZoneAppearance() }
      // Back to Current Project: the zone mirrors it again at once. A new
      // fixed choice waits for the panel's next appearance.
      preferences.onDropZoneUploadIntoChange = { [weak self, weak zoneModel, preferences] _ in
        guard self?.dropZoneMirrorsCurrentProject ?? false else { return }
        zoneModel?.selectedProjectSlug = preferences.currentProjectSlug
      }
      zoneModel.loadProjects()
      zoneModel.$projects
        .sink { [weak self, weak zoneModel, preferences] projects in
          // Before the zone drops a vanished selection: a fixed project
          // that is gone reads as Current Project from here on, so the
          // zone goes back to mirroring the current project first.
          let wasMirroring = self?.dropZoneMirrorsCurrentProject ?? true
          self?.projects = projects
          if !wasMirroring, self?.dropZoneMirrorsCurrentProject == true {
            zoneModel?.selectedProjectSlug = preferences.currentProjectSlug
          }
        }
        .store(in: &projectCancellables)
      // A project added in Settings joins the menu and the picker; one
      // removed leaves them (and stops being current).
      galleryModel.$projects
        .map { $0.map(\.slug) }
        .removeDuplicates()
        .dropFirst()
        .sink { [weak zoneModel] _ in zoneModel?.loadProjects() }
        .store(in: &projectCancellables)
      galleryModel.$sourcedProjects
        .sink { [weak self] sourced in self?.sourcedProjects = sourced }
        .store(in: &projectCancellables)
      // Project ▸ Scan Now reads which projects have sources from launch,
      // whether or not the gallery window has loaded or shown a report.
      await galleryModel.refreshSourcedProjects()
      // The settings pane reads and writes project rows through the same
      // CatalogConfiguration calls the CLI makes. Backend and prefix changes
      // take effect on the next upload without further wiring — the upload
      // path re-resolves projects per request.
      projectSettings = settings
      maintenance = MaintenanceModel(
        reader: CatalogMaintenanceReader(
          database: database,
          databaseURL: URL(fileURLWithPath: database.path)))
      // One model behind Settings ▸ Backup, File ▸ Import /
      // Export Catalog Backup… and the empty catalog's Restore from Backup….
      let backupModel = BackupModel(
        creator: CatalogBackupWriter(database: database),
        restorer: CatalogRestorer(database: database, credentialExists: credentialExists),
        chooseBackupFile: chooseBackupFile,
        isBusy: { [weak self] in
          self?.dropZone?.model.cards.contains { $0.phase.isPending } == true
            || self?.usageSync?.isSyncing == true
        },
        chooseDestination: chooseBackupDestination)
      backupModel.onRestored = { [weak self] in await self?.reloadAfterCatalogRestore() }
      backupCancellable = backupModel.$isCatalogEmpty
        .sink { [weak self, weak galleryModel] empty in
          self?.isCatalogEmpty = empty
          galleryModel?.showsCatalogRestore = empty == true
        }
      galleryModel.onRequestRestore = { [weak backupModel] in
        await backupModel?.beginRestore(presenter: .gallery)
      }
      backup = backupModel
      let scanMarks = AutomaticScanMarks(defaults: defaults)
      let usageSyncModel = UsageSyncModel(
        synchronizer: usageSynchronizer?(database)
          ?? CatalogUsageSynchronizer(
            database: database, approvals: commandApprovals, runner: commandRunner),
        approvals: commandApprovals,
        scanMarks: scanMarks,
        chooseSource: UsageDocumentOpenPanel.choose)
      usageSync = usageSyncModel
      // One Scan Now. The Projects page and the reports'
      // empty states all reach `scanNow`; its activity goes to the status
      // bar, and a finished scan reloads the report being shown and the
      // Projects page's last-scan line.
      settings.scanNow = { [weak usageSyncModel] slug in
        Task { await usageSyncModel?.scanNow(projects: [slug], presenter: .settings) }
      }
      settings.testCommand = { [weak usageSyncModel] slug, source in
        Task {
          await usageSyncModel?.testCommand(project: slug, source: source, presenter: .settings)
        }
      }
      usageSyncModel.onCommandTestsChange = { [weak settings] tests in
        settings?.commandTests = tests
      }
      settings.automaticScanID = { scanMarks.scanID(project: $0) }
      galleryModel.onScanNow = { [weak usageSyncModel] slugs in
        Task { await usageSyncModel?.scanNow(projects: slugs, presenter: .gallery) }
      }
      usageSyncModel.onScanActivityChange = { [weak galleryModel, weak settings] activity in
        galleryModel?.usageScanActivity = activity
        settings?.scanActivity = activity
      }
      usageSyncModel.onScanCompleted = { [weak self, weak galleryModel, weak settings] in
        settings?.load()
        await galleryModel?.reloadAfterUsageScan()
        await self?.backends?.loadDomainLinks()
      }
      settings.onSourcesChange = { [weak galleryModel] in
        Task { await galleryModel?.refreshSourcedProjects() }
      }
      settings.onUsageTrackingChange = { [weak galleryModel] in
        Task { await galleryModel?.reloadAfterUsageScan() }
      }
      galleryModel.onOpenProjectSettings = { [weak self, weak settings] slug in
        settings?.requestedSlug = slug
        self?.settingsTab = .projects
      }
      // The title-area picker writes the one current
      // project the Project menu and the drop zone write; its New Project…
      // and Manage Projects… land on Settings ▸ Projects.
      galleryModel.onChooseProject = { [preferences] slug in
        preferences.currentProjectSlug = slug
      }
      galleryModel.onNewProject = { [weak self, weak settings] in
        self?.settingsTab = .projects
        settings?.beginAddition(presenter: .settings)
      }
      galleryModel.onManageProjects = { [weak self] in
        self?.showCurrentProjectSettings()
      }
      backends = BackendsModel(
        reader: CatalogBackendsReader(database: database),
        reindexer: CatalogReindexRunner(database: database),
        picGoImporter: CatalogPicGoGalleryImporter(database: database),
        bucketImporter: CatalogBucketImporter(database: database))
      backends?.unreferenced.onShowOrphans = { [weak galleryModel] in
        galleryModel?.openOverview(.orphans)
      }
      wireDomains(gallery: galleryModel, settings: settings)
      gallery = galleryModel
      dropZone = controller
      await backupModel.refreshCatalogState()
      controller.setEnabled(preferences.isDropZoneEnabled)
      syncDropZoneBehaviour()
      await refreshRecentUploads()
      startAutoScan(database: database, usageSync: usageSyncModel, settings: settings)
    } catch {
      openError = error.localizedDescription
    }
  }

  /// Watches and schedules from here on. Every read of the Projects page —
  /// after an edit, a new project, a finished scan or a restore — rebuilds
  /// the watches; the schedule's own checks catch what changes outside the app.
  private func startAutoScan(
    database: DatabasePool, usageSync: UsageSyncModel, settings: ProjectSettingsModel
  ) {
    let engine = AutoScanEngine(
      database: database, usageSync: usageSync, clock: scanClock,
      wakeNotifications: wakeNotifications)
    autoScan = engine
    // The snapshot is only the signal: the engine reads the catalog itself.
    settings.$snapshot
      .dropFirst()
      .sink { [weak engine] _ in engine?.reload() }
      .store(in: &projectCancellables)
    engine.start()
  }

  /// Settings' two Move buttons hand over to the main
  /// window's sheet; the Domains list greys on the shared lock; a move, a
  /// Switch or an Old domain edit makes every reader of the domains read
  /// again; a finished scan refreshes the link counts.
  private func wireDomains(gallery: GalleryModel, settings: ProjectSettingsModel) {
    guard let backends else { return }
    backends.migrationLock = gallery.migrationLock
    if let domain = gallery.domainMigration {
      backends.onMoveToNewDomain = { [weak domain] slug in
        Task { await domain?.beginNewDomain(backend: slug) }
      }
      backends.onMoveToCurrent = { [weak domain, weak backends] slug, old in
        let links = backends?.domainRows.first { $0.prefix == old }?.links ?? 0
        Task { await domain?.beginMoveToCurrent(backend: slug, oldDomain: old, links: links) }
      }
    }
    backends.onDomainsChanged = { [weak gallery, weak settings] in
      settings?.load()
      await gallery?.refreshDomainBackends()
    }
    // The one Scan Now; its completion reads the
    // Domains counts, Links use and the Usage menu again.
    backends.onScanBackend = { [weak self, weak settings] slug in
      guard let usageSync = self?.usageSync, let settings else { return }
      if settings.snapshot == nil { settings.load() }
      let targets = settings.snapshot?.scanTargets(uploadingTo: slug) ?? []
      guard !targets.isEmpty else { return }
      Task { await usageSync.scanNow(projects: targets, presenter: .settings) }
    }
    gallery.onOpenBackendSettings = { [weak self] slug in self?.showBackendSettings(slug: slug) }
    gallery.onDomainsChanged = { [weak backends, weak settings] in
      settings?.load()
      await backends?.load()
    }
  }

  /// The menu bar's RECENT grid: newest first, at most `RecentUpload.limit`.
  /// Read-only, so it can never disturb the gallery's own query state.
  public func refreshRecentUploads() async {
    guard let gallery else { return }
    var query = AssetQuery()
    query.limit = RecentUpload.limit
    guard let page = try? await gallery.catalog.page(query) else { return }
    recentUploads = RecentUpload.make(from: page.items)
    recentItems = Dictionary(
      page.items.prefix(RecentUpload.limit).compactMap { item in
        item.asset.id.map { ($0, item) }
      }, uniquingKeysWith: { first, _ in first })
    await refreshMenuBarStats()
  }

  /// The menu bar's Library numbers for the current project (nil = All
  /// Projects). Read-only, one `CatalogStats.load`.
  public func refreshMenuBarStats() async {
    guard let gallery else { return }
    let slug = preferences.currentProjectSlug
    guard let stats = try? await gallery.catalog.overviewStats(project: slug, calendar: .current),
      slug == preferences.currentProjectSlug
    else { return }
    menuBarStats = stats
  }

  /// The catalog rows behind `recentUploads`, for Quick Look.
  private var recentItems: [Int64: CatalogAssetItem] = [:]

  /// The panel's eye button: Quick Look on a recent upload, through the
  /// drop zone's controller like its cards'.
  public func quickLookRecent(_ id: Int64) {
    guard let item = recentItems[id], let dropZone else { return }
    dropZone.model.quickLook.toggleRemote([item], at: 0)
  }

  /// Pushes the drop zone's behaviour preferences into the zone model.
  /// Run once at start and again whenever any preference changes.
  private func syncDropZoneBehaviour() {
    guard let zoneModel = dropZone?.model else { return }
    zoneModel.dragVisibilityModifier =
      preferences.dropZoneRequiresModifier ? preferences.dropZoneModifier : nil
    zoneModel.autoHidesResultsAfter = TimeInterval(preferences.dropZoneAutoHideSeconds)
    zoneModel.copiesURLsAutomatically = preferences.copiesURLsOnUpload
  }

  // MARK: - Shell actions (menu commands and the menu bar)

  /// File → New Upload…: an image picker whose choices enter the drop zone
  /// like a manual drop — cards, thumbnails, and results all included.
  public func pickFilesAndUpload() {
    guard let dropZone else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.image]
    panel.message = "Choose images to upload"
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    dropZone.model.drop(fileURLs: panel.urls)
  }

  /// Menu bar → Upload from Clipboard. The pasteboard is read off the main
  /// thread; whatever it yields enters the drop zone like a drop.
  public func uploadFromClipboard() async {
    guard let dropZone else { return }
    let files = await PasteboardUploads.collectImageFiles()
    guard !files.isEmpty else { return }
    dropZone.model.drop(fileURLs: files)
  }

  // MARK: - The current project

  /// What the Project menu's Scan Now scans: the current project when it
  /// has sources; under All Projects every project with sources (Scan All).
  public var currentProjectScanTargets: [String] {
    if let slug = preferences.currentProjectSlug {
      return sourcedProjects.contains(slug) ? [slug] : []
    }
    return sourcedProjects.sorted()
  }

  /// Project ▸ Scan Now / Scan All — the one `scanNow`.
  public func scanCurrentProject() {
    let targets = currentProjectScanTargets
    guard let usageSync, !targets.isEmpty else { return }
    Task { await usageSync.scanNow(projects: targets, presenter: .gallery) }
  }

  /// The menu bar's Library ▸ Last scan ▸ Scan: the same one
  /// `scanNow` over the same targets, then the Library numbers again. true
  /// when the scan stopped at a confirmation (an empty scan, or a command
  /// not yet allowed), which the gallery shows — the caller opens the gallery.
  public func scanFromMenuBar() async -> Bool {
    let targets = currentProjectScanTargets
    guard let usageSync, !targets.isEmpty else { return false }
    await usageSync.scanNow(projects: targets, presenter: .gallery)
    await refreshMenuBarStats()
    return usageSync.isEmptyScanConfirmationPresented(by: .gallery)
      || usageSync.isCommandApprovalPresented(by: .gallery)
  }

  /// Project ▸ Choose Project… (⌃0): the title area's project picker.
  public func chooseProject() {
    gallery?.isProjectPickerPresented = true
  }

  /// Project ▸ Project Settings…: Settings ▸ Projects on the current project
  /// (the caller opens the window).
  /// Upload into resolved against today's projects.
  private var dropZoneUploadInto: DropZoneUploadInto {
    preferences.dropZoneUploadInto.resolved(projects: projects.map(\.slug))
  }

  /// The single source of the current project holds — the panel's picker is the current
  /// project — unless Upload into names a fixed target that still exists.
  private var dropZoneMirrorsCurrentProject: Bool {
    dropZoneUploadInto == .currentProject
  }

  /// Every appearance of the panel starts at the fixed target, if any.
  private func startDropZoneAppearance() {
    guard let zone = dropZone?.model else { return }
    switch dropZoneUploadInto {
    case .currentProject: zone.selectedProjectSlug = preferences.currentProjectSlug
    case .noProject: zone.selectedProjectSlug = nil
    case .project(let slug): zone.selectedProjectSlug = slug
    }
  }

  public func showCurrentProjectSettings() {
    projectSettings?.requestedSlug = preferences.currentProjectSlug
    settingsTab = .projects
  }

  /// After a restore, without a restart: everything that read the
  /// empty catalog reads it again — the same readers a finished scan and a
  /// settled upload refresh, plus the Settings pages.
  func reloadAfterCatalogRestore() async {
    catalogRestoreReloads += 1
    projectSettings?.load()
    dropZone?.model.loadProjects()
    if let gallery {
      await gallery.loadInitialData()
      await gallery.refreshSourcedProjects()
    }
    await backends?.load()
    await maintenance?.load()
    await usageSync?.loadProjects()
    await refreshRecentUploads()
  }

  /// File ▸ Import Catalog Backup…: the one restore, shown in the main
  /// window.
  public func importCatalogBackup() async {
    await backup?.beginRestore(presenter: .gallery)
  }

  /// File ▸ Export Catalog Backup…: Settings' Save Backup….
  public func exportCatalogBackup() async {
    await backup?.create()
  }

  /// Catalog Restored ▸ Open Backends: Settings ▸ Backends on that backend
  /// (the caller opens the window).
  public func showBackendSettings(slug: String) {
    settingsTab = .backends
    if let backends { Task { await backends.select(slug) } }
  }

  /// Catalog Restored ▸ Locate…: Settings ▸ Projects on that project.
  public func showProjectSettings(slug: String) {
    projectSettings?.requestedSlug = slug
    settingsTab = .projects
  }

  /// Window → Show Drop Zone: enable the zone (if off) and reveal the panel
  /// on demand, so the command is visible feedback rather than a silent flag.
  public func revealDropZone() {
    if !preferences.isDropZoneEnabled {
      preferences.isDropZoneEnabled = true
    }
    dropZone?.model.revealOnDemand()
  }

  /// Menu bar ▸ Show Drop Zone: this run's cards if there are
  /// any, else the catalog's 10 newest by Library ▸ Recent's measure (last
  /// 30 days, newest first) as done cards. Enables the zone like ⌘⇧D does —
  /// the shown panel is a live drop target.
  public func showDropZoneFromMenuBar() async {
    guard let dropZone, let gallery else { return }
    if !preferences.isDropZoneEnabled {
      preferences.isDropZoneEnabled = true
    }
    let zone = dropZone.model
    if zone.hasSessionUploads {
      zone.presentSession()
      return
    }
    var query = AssetQuery()
    query.limit = 10
    query.since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 24 * 3600))
    guard let page = try? await gallery.catalog.page(query) else { return }
    let memberships =
      (try? await gallery.catalog.projectMemberships(
        assetIDs: page.items.compactMap(\.asset.id))) ?? [:]
    zone.presentRecent(page.items, memberships: memberships)
  }

  /// File → Reveal Catalog in Finder. `locate` is a pure path computation —
  /// no database is opened, and a not-yet-created file still reveals its
  /// (selected) parent folder.
  public func revealCatalogInFinder() {
    NSWorkspace.shared.activateFileViewerSelecting([DBLocation.locate()])
  }
}
