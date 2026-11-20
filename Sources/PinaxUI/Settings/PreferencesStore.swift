import CatalogCore
import Foundation

/// Machine-local preferences: settings live in `UserDefaults`, never in the
/// catalog. One store for the whole app, injected with the same
/// `UserDefaults` the shell already used, so existing keys — and the user's
/// existing choices — carry over unchanged. Every pane adds its keys here;
/// none of them may ever write a catalog row.
@MainActor
public final class PreferencesStore: ObservableObject {
  /// Key kept from the earlier `PinaxAppModel` storage, so existing choices
  /// carry over.
  private static let dropZoneEnabledKey = "pinax.dropZone.enabled"
  private static let dropZoneCornerKey = "pinax.dropZone.corner"
  private static let dropZoneRequiresModifierKey = "pinax.dropZone.requiresModifier"
  private static let dropZoneModifierKey = "pinax.dropZone.modifier"
  private static let dropZoneFollowsCursorKey = "pinax.dropZone.followsCursor"
  private static let dropZoneAutoHideSecondsKey = "pinax.dropZone.autoHideSeconds"
  private static let copiesURLsOnUploadKey = "pinax.dropZone.copiesURLsOnUpload"
  private static let dropZoneAppearanceKey = "pinax.dropZone.appearance"
  private static let dropZoneLayoutKey = "pinax.dropZone.layout"
  private static let dropZoneUploadIntoKey = "pinax.dropZone.uploadInto"
  private static let dropZoneWidthKey = "pinax.dropZone.width"
  private static let dropZoneHeightKey = "pinax.dropZone.height"
  private static let gridColumnsKey = "pinax.grid.columns"
  private static let tableRowHeightKey = "pinax.table.rowHeight"
  /// Always / hoverOrSelected / off. Replaces the on/off key
  /// below, which is read once when this one is missing and never written.
  private static let gridMetadataVisibilityKey = "pinax.grid.metadata.visibility"
  private static let legacyGridMetadataEnabledKey = "pinax.grid.metadata.enabled"
  private static let gridUploadDateKey = "pinax.grid.metadata.uploadDate"
  private static let gridFilenameKey = "pinax.grid.metadata.filename"
  private static let sourceTagStyleKey = "pinax.grid.sourceTags.style"
  private static let sourceTagResumeKey = "pinax.grid.sourceTags.resume"
  private static let gridLeadingCornerKey = "pinax.grid.metadata.leadingCorner"
  private static let gridTrailingCornerKey = "pinax.grid.metadata.trailingCorner"
  private static let gridThumbnailSizingKey = "pinax.grid.thumbnailSizing"
  private static let sidebarNavigatorKey = "pinax.sidebar.navigator"
  /// One Bool per Library-tab shortcut section,
  /// `pinax.sidebar.library.projects` / `.time`.
  private static func libraryShortcutKey(_ shortcut: LibraryShortcut) -> String {
    "pinax.sidebar.library.\(shortcut.rawValue)"
  }
  private static let gridGroupsByMonthKey = "pinax.grid.groupsByMonth"
  private static let gallerySortKey = "pinax.gallery.sort"
  private static let externalsSortKey = "pinax.externals.sort"
  private static let externalsGroupsByFileKey = "pinax.externals.groupsByFile"
  private static let externalsTipDismissedKey = "pinax.externals.tipDismissed"
  private static let copyFormatsKey = "pinax.copy.formats"
  private static let defaultCopyFormatKey = "pinax.copy.defaultFormat"
  private static let downloadFolderKey = "pinax.download.folder"
  private static let currentProjectKey = "pinax.currentProject"
  private static let dockIconKey = "pinax.appearance.dockIcon"
  private static let dockIconMatchesSystemKey = "pinax.appearance.dockIcon.matchesSystem"
  private static let dockIconLightKey = "pinax.appearance.dockIcon.light"
  private static let dockIconDarkKey = "pinax.appearance.dockIcon.dark"
  private static let menuBarIconKey = "pinax.appearance.menuBarIcon"
  private static let menuBarChartUnitKey = "pinax.menuBar.chartUnit"
  private static let menuBarStorageSplitKey = "pinax.menuBar.storageSplit"
  /// The drop zone's former project key; read once, moved to
  /// `currentProjectKey`, and removed.
  private static let legacyDropZoneProjectKey = "pinax.dropZone.projectSlug"

  private let defaults: UserDefaults

  @Published public var isDropZoneEnabled: Bool {
    didSet {
      // `@Published` fires didSet on every assignment, including no-op ones;
      // the hook below is a *change* hook, so equal re-sets are ignored.
      guard oldValue != isDropZoneEnabled else { return }
      defaults.set(isDropZoneEnabled, forKey: Self.dropZoneEnabledKey)
      onDropZoneEnabledChange?(isDropZoneEnabled)
    }
  }

  /// Drop zone defaults: bottom-**left** deliberately differs
  /// from Clop's bottom-right so the two panels do not overlap out of the
  /// box; the modifier gate is off; auto-hide is 30 s; URL copy is on.
  @Published public var dropZoneCorner: DropZoneCorner {
    didSet { defaults.set(dropZoneCorner.rawValue, forKey: Self.dropZoneCornerKey) }
  }

  @Published public var dropZoneRequiresModifier: Bool {
    didSet { defaults.set(dropZoneRequiresModifier, forKey: Self.dropZoneRequiresModifierKey) }
  }

  @Published public var dropZoneModifier: DropZoneModifier {
    didSet { defaults.set(dropZoneModifier.rawValue, forKey: Self.dropZoneModifierKey) }
  }

  @Published public var dropZoneFollowsCursor: Bool {
    didSet { defaults.set(dropZoneFollowsCursor, forKey: Self.dropZoneFollowsCursorKey) }
  }

  @Published public var dropZoneAutoHideSeconds: Int {
    didSet { defaults.set(dropZoneAutoHideSeconds, forKey: Self.dropZoneAutoHideSecondsKey) }
  }

  @Published public var copiesURLsOnUpload: Bool {
    didSet { defaults.set(copiesURLsOnUpload, forKey: Self.copiesURLsOnUploadKey) }
  }

  /// The panel's look — Match System and List by
  /// default. Applied by `DropZoneController`; the main window never reads
  /// them.
  @Published public var dropZoneAppearance: DropZoneAppearance {
    didSet { defaults.set(dropZoneAppearance.rawValue, forKey: Self.dropZoneAppearanceKey) }
  }

  @Published public var dropZoneLayout: DropZoneLayout {
    didSet { defaults.set(dropZoneLayout.rawValue, forKey: Self.dropZoneLayoutKey) }
  }

  /// Where the panel's uploads start — Current Project by default.
  /// `PinaxAppModel` applies it; the controller never reads it.
  @Published public var dropZoneUploadInto: DropZoneUploadInto {
    didSet {
      defaults.set(dropZoneUploadInto.rawValue, forKey: Self.dropZoneUploadIntoKey)
      onDropZoneUploadIntoChange?(dropZoneUploadInto)
    }
  }

  /// The panel's size, always inside `DropZoneSize`'s ranges —
  /// a value from the slider, the panel's edge or the store is clamped.
  @Published public private(set) var dropZoneSize: CGSize {
    didSet {
      defaults.set(Double(dropZoneSize.width), forKey: Self.dropZoneWidthKey)
      defaults.set(Double(dropZoneSize.height), forKey: Self.dropZoneHeightKey)
    }
  }

  public func setDropZoneSize(_ size: CGSize) {
    let clamped = DropZoneSize.clamped(size)
    if clamped != dropZoneSize { dropZoneSize = clamped }
  }

  public func resetDropZoneSize() {
    setDropZoneSize(DropZoneSize.defaultSize)
  }

  /// The grid's zoom rung — a column count on `GridZoom.columns`
  /// ([2, 3, 4, 5, 6, 8], default 4). Written only by the gallery model's
  /// zoom writeback, read once when the gallery is created. A stored value
  /// off the ladder (a future edit to the list, a manual `defaults write`)
  /// falls back to the default rung — the same garbage tolerance the drop
  /// zone's string enums have. Off-ladder writes are refused in memory too: the
  /// gallery cannot render a rung that is not on the ladder.
  @Published public var gridColumns: Int {
    didSet {
      guard oldValue != gridColumns else { return }
      if GridZoom.columns.contains(gridColumns) {
        defaults.set(gridColumns, forKey: Self.gridColumnsKey)
      } else {
        gridColumns = oldValue
      }
    }
  }

  /// The table's row-height rung, on `DesignMetrics.table.rowHeights`,
  /// default 44. Stored apart
  /// from `gridColumns`; the same off-ladder tolerance.
  @Published public var tableRowHeight: CGFloat {
    didSet {
      guard oldValue != tableRowHeight else { return }
      if DesignMetrics.table.rowHeights.contains(tableRowHeight) {
        defaults.set(Double(tableRowHeight), forKey: Self.tableRowHeightKey)
      } else {
        tableRowHeight = oldValue
      }
    }
  }

  /// The style View ▸ Show Source Tags brings back: the last one that was
  /// not Off (Date line until the user picks another).
  public private(set) var sourceTagResumeStyle: SourceTagStyle {
    didSet { defaults.set(sourceTagResumeStyle.rawValue, forKey: Self.sourceTagResumeKey) }
  }

  public var showsSourceTags: Bool { gridOverlays.sourceTagStyle != .off }

  /// View ▸ Show Source Tags: between the current style and Off.
  public func toggleSourceTags() {
    gridOverlays.sourceTagStyle = showsSourceTags ? .off : sourceTagResumeStyle
  }

  /// Migration from the old on/off switch: the new key wins, an
  /// unknown value reads as the default; with it missing, the old switch
  /// off is Never, on or missing is the default (hover or selection).
  static func metadataVisibility(
    stored: String?, legacyEnabled: Bool?
  ) -> GridOverlayOptions.MetadataVisibility {
    if let stored {
      return GridOverlayOptions.MetadataVisibility(rawValue: stored) ?? .default
    }
    return legacyEnabled == false ? .off : .default
  }

  @Published public var gridOverlays: GridOverlayOptions {
    didSet {
      guard oldValue != gridOverlays else { return }
      defaults.set(gridOverlays.metadataVisibility.rawValue, forKey: Self.gridMetadataVisibilityKey)
      defaults.set(gridOverlays.showsFilename, forKey: Self.gridFilenameKey)
      defaults.set(gridOverlays.showsUploadDateBelowImage, forKey: Self.gridUploadDateKey)
      defaults.set(gridOverlays.leadingCorner.rawValue, forKey: Self.gridLeadingCornerKey)
      defaults.set(gridOverlays.trailingCorner.rawValue, forKey: Self.gridTrailingCornerKey)
      defaults.set(gridOverlays.sourceTagStyle.rawValue, forKey: Self.sourceTagStyleKey)
      if gridOverlays.sourceTagStyle != .off {
        sourceTagResumeStyle = gridOverlays.sourceTagStyle
      }
      onGridOverlaysChange?(gridOverlays)
    }
  }

  @Published public var gridThumbnailSizing: GridThumbnailSizing {
    didSet {
      guard oldValue != gridThumbnailSizing else { return }
      defaults.set(gridThumbnailSizing.rawValue, forKey: Self.gridThumbnailSizingKey)
      onGridThumbnailSizingChange?(gridThumbnailSizing)
    }
  }

  /// The jump bar's month-grouping switch, on by
  /// default. Written by the gallery model's writeback, read once when the
  /// gallery is created — the zoom rung's shape.
  @Published public var gridGroupsByMonth: Bool {
    didSet {
      guard oldValue != gridGroupsByMonth else { return }
      defaults.set(gridGroupsByMonth, forKey: Self.gridGroupsByMonthKey)
    }
  }

  /// The asset order, stored as
  /// `field.direction` ("byteSize.descending"). Mirrored both ways with the
  /// gallery model by `PinaxAppModel`, the `gridOverlays` shape: View ▸
  /// Sort By writes here, the jump bar and the table headers write the
  /// gallery. Garbage reads as the default order.
  @Published public var gallerySort: AssetSort {
    didSet {
      guard oldValue != gallerySort else { return }
      defaults.set(
        "\(gallerySort.field.rawValue).\(gallerySort.direction.rawValue)",
        forKey: Self.gallerySortKey)
      onGallerySortChange?(gallerySort)
    }
  }

  /// Externals' own order and Group by File,
  /// the month switch's shape — the gallery's writeback, read once when the
  /// gallery is created.
  @Published public var externalsSort: ExternalSort {
    didSet {
      guard oldValue != externalsSort else { return }
      defaults.set(externalsSort.stored, forKey: Self.externalsSortKey)
    }
  }

  @Published public var externalsGroupsByFile: Bool {
    didSet {
      guard oldValue != externalsGroupsByFile else { return }
      defaults.set(externalsGroupsByFile, forKey: Self.externalsGroupsByFileKey)
    }
  }

  /// The Externals card was closed — once, for the app,
  /// whatever the project.
  @Published public var externalsTipDismissed: Bool {
    didSet {
      guard oldValue != externalsTipDismissed else { return }
      defaults.set(externalsTipDismissed, forKey: Self.externalsTipDismissedKey)
    }
  }

  /// The Library tab's shown shortcut sections,
  /// one value for every window. Settings ▸ Appearance ▸ Library tab and
  /// the sidebar's header menu both write it.
  @Published public var libraryShortcuts: Set<LibraryShortcut> {
    didSet {
      guard oldValue != libraryShortcuts else { return }
      for shortcut in LibraryShortcut.allCases {
        defaults.set(libraryShortcuts.contains(shortcut), forKey: Self.libraryShortcutKey(shortcut))
      }
      onLibraryShortcutsChange?(libraryShortcuts)
    }
  }

  /// Which sidebar navigator the window opens on. A stored value that is
  /// not one of the four falls back to `.library`, the same garbage
  /// tolerance the drop zone's string enums have — and where a stored
  /// `"folders"`, a retired case, lands.
  @Published public var sidebarNavigator: SidebarNavigator {
    didSet {
      guard oldValue != sidebarNavigator else { return }
      defaults.set(sidebarNavigator.rawValue, forKey: Self.sidebarNavigatorKey)
    }
  }

  /// The Copy As list, stored as JSON. Garbage or a
  /// missing key reads as the factory list (URL, Markdown, HTML).
  @Published public var copyFormats: [CopyFormat] {
    didSet {
      guard oldValue != copyFormats else { return }
      defaults.set(try? JSONEncoder().encode(copyFormats), forKey: Self.copyFormatsKey)
      onCopyFormatsChange?(copyFormats, defaultCopyFormat)
    }
  }

  /// The format ⌘C will use. May name a format no longer in the list;
  /// `defaultCopyFormat` resolves that to the list's first entry.
  @Published public var defaultCopyFormatID: UUID {
    didSet {
      guard oldValue != defaultCopyFormatID else { return }
      defaults.set(defaultCopyFormatID.uuidString, forKey: Self.defaultCopyFormatKey)
      onCopyFormatsChange?(copyFormats, defaultCopyFormat)
    }
  }

  /// Where Download Original saves; nil = Downloads.
  @Published public var downloadFolderPath: String? {
    didSet {
      guard oldValue != downloadFolderPath else { return }
      defaults.set(downloadFolderPath, forKey: Self.downloadFolderKey)
      onDownloadFolderChange?(downloadFolder)
    }
  }

  /// The current project — where uploads go, what the
  /// reports cover, what Scan Now scans. nil = All Projects. The Project
  /// menu and the drop zone read and write this one value; a slug no
  /// longer in the catalog is turned into nil by the app shell, which
  /// knows the project list.
  @Published public var currentProjectSlug: String? {
    didSet {
      guard oldValue != currentProjectSlug else { return }
      defaults.set(currentProjectSlug, forKey: Self.currentProjectKey)
      onCurrentProjectChange?(currentProjectSlug)
    }
  }

  /// The Dock icon. A stored id no longer offered reads as
  /// the slot's default.
  @Published public var dockIconID: String {
    didSet {
      guard oldValue != dockIconID else { return }
      defaults.set(dockIconID, forKey: Self.dockIconKey)
      onDockIconChange?()
    }
  }

  /// The first time this turns on, Light takes the current icon (Dark
  /// already defaults to Ivory Glyph).
  @Published public var dockIconMatchesSystem: Bool {
    didSet {
      guard oldValue != dockIconMatchesSystem else { return }
      if dockIconMatchesSystem, dockIconLightID == nil { dockIconLightID = dockIconID }
      defaults.set(dockIconMatchesSystem, forKey: Self.dockIconMatchesSystemKey)
      onDockIconChange?()
    }
  }

  /// nil until Match System Appearance is first turned on; until then the
  /// Light slot shows the current icon.
  @Published public var dockIconLightID: String? {
    didSet {
      guard oldValue != dockIconLightID else { return }
      defaults.set(dockIconLightID, forKey: Self.dockIconLightKey)
      onDockIconChange?()
    }
  }

  @Published public var dockIconDarkID: String {
    didSet {
      guard oldValue != dockIconDarkID else { return }
      defaults.set(dockIconDarkID, forKey: Self.dockIconDarkKey)
      onDockIconChange?()
    }
  }

  public var effectiveDockIconLightID: String { dockIconLightID ?? dockIconID }

  /// The menu bar icon. A stored id no longer offered reads
  /// as the default. The item's label observes this store, so no hook.
  @Published public var menuBarIconID: String {
    didSet {
      guard oldValue != menuBarIconID else { return }
      defaults.set(menuBarIconID, forKey: Self.menuBarIconKey)
    }
  }

  /// What one bar of the menu bar's statistics card
  /// covers. An unknown stored value reads as Week.
  @Published public var menuBarChartUnit: MenuBarChartUnit {
    didSet {
      guard oldValue != menuBarChartUnit else { return }
      defaults.set(menuBarChartUnit.rawValue, forKey: Self.menuBarChartUnitKey)
    }
  }

  /// What the menu bar's Library page splits its storage bar by. File
  /// type unless set; an unknown stored value reads as that.
  @Published public var menuBarStorageSplit: MenuBarStorageSplit {
    didSet {
      guard oldValue != menuBarStorageSplit else { return }
      defaults.set(menuBarStorageSplit.rawValue, forKey: Self.menuBarStorageSplitKey)
    }
  }

  public var downloadFolder: URL {
    downloadFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? OriginalDownloader.defaultFolder
  }

  public var defaultCopyFormat: CopyFormat? {
    copyFormats.first { $0.id == defaultCopyFormatID } ?? copyFormats.first
  }

  /// The shell's reaction to the toggle (start/stop the drag monitor).
  /// Assignment happens once during app-model init, before any toggle can
  /// fire; nil is tolerated so the store stays usable standalone.
  public var onDropZoneEnabledChange: ((Bool) -> Void)?
  public var onGridOverlaysChange: ((GridOverlayOptions) -> Void)?
  public var onLibraryShortcutsChange: ((Set<LibraryShortcut>) -> Void)?
  public var onGridThumbnailSizingChange: ((GridThumbnailSizing) -> Void)?
  public var onGallerySortChange: ((AssetSort) -> Void)?
  public var onCopyFormatsChange: (([CopyFormat], CopyFormat?) -> Void)?
  public var onDownloadFolderChange: ((URL) -> Void)?
  public var onCurrentProjectChange: ((String?) -> Void)?
  public var onDropZoneUploadIntoChange: ((DropZoneUploadInto) -> Void)?
  public var onDockIconChange: (() -> Void)?

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    _isDropZoneEnabled = Published(
      wrappedValue: defaults.object(forKey: Self.dropZoneEnabledKey) as? Bool ?? true)
    _dropZoneCorner = Published(
      wrappedValue: DropZoneCorner(
        rawValue: defaults.string(forKey: Self.dropZoneCornerKey) ?? "") ?? .bottomLeft)
    _dropZoneRequiresModifier = Published(
      wrappedValue: defaults.object(forKey: Self.dropZoneRequiresModifierKey) as? Bool ?? false)
    _dropZoneModifier = Published(
      wrappedValue: DropZoneModifier(
        rawValue: defaults.string(forKey: Self.dropZoneModifierKey) ?? "") ?? .option)
    _dropZoneFollowsCursor = Published(
      wrappedValue: defaults.object(forKey: Self.dropZoneFollowsCursorKey) as? Bool ?? false)
    _dropZoneAutoHideSeconds = Published(
      wrappedValue: DropZoneAutoHide.normalized(
        defaults.object(forKey: Self.dropZoneAutoHideSecondsKey) as? Int ?? 30))
    _copiesURLsOnUpload = Published(
      wrappedValue: defaults.object(forKey: Self.copiesURLsOnUploadKey) as? Bool ?? true)
    _dropZoneAppearance = Published(
      wrappedValue: DropZoneAppearance(
        rawValue: defaults.string(forKey: Self.dropZoneAppearanceKey) ?? "") ?? .system)
    _dropZoneLayout = Published(
      wrappedValue: DropZoneLayout(
        rawValue: defaults.string(forKey: Self.dropZoneLayoutKey) ?? "") ?? .list)
    _dropZoneUploadInto = Published(
      wrappedValue: DropZoneUploadInto(
        rawValue: defaults.string(forKey: Self.dropZoneUploadIntoKey) ?? ""))
    _dropZoneSize = Published(
      wrappedValue: DropZoneSize.clamped(
        CGSize(
          width: defaults.object(forKey: Self.dropZoneWidthKey) as? Double
            ?? DropZoneSize.defaultSize.width,
          height: defaults.object(forKey: Self.dropZoneHeightKey) as? Double
            ?? DropZoneSize.defaultSize.height)))
    let storedColumns =
      defaults.object(forKey: Self.gridColumnsKey) as? Int ?? GridZoom.defaultColumns
    _gridColumns = Published(
      wrappedValue: GridZoom.columns.contains(storedColumns)
        ? storedColumns : GridZoom.defaultColumns)
    let storedRowHeight = CGFloat(
      defaults.object(forKey: Self.tableRowHeightKey) as? Double
        ?? Double(DesignMetrics.table.defaultRowHeight))
    _tableRowHeight = Published(
      wrappedValue: DesignMetrics.table.rowHeights.contains(storedRowHeight)
        ? storedRowHeight : DesignMetrics.table.defaultRowHeight)
    _gridOverlays = Published(wrappedValue: GridOverlayOptions(
      metadataVisibility: Self.metadataVisibility(
        stored: defaults.string(forKey: Self.gridMetadataVisibilityKey),
        legacyEnabled: defaults.object(forKey: Self.legacyGridMetadataEnabledKey) as? Bool),
      showsFilename: defaults.object(forKey: Self.gridFilenameKey) as? Bool ?? true,
      showsUploadDateBelowImage:
        defaults.object(forKey: Self.gridUploadDateKey) as? Bool ?? true,
      leadingCorner: GridOverlayOptions.CornerField(
        rawValue: defaults.string(forKey: Self.gridLeadingCornerKey) ?? "")
        ?? GridOverlayOptions.defaultLeadingCorner,
      trailingCorner: GridOverlayOptions.CornerField(
        rawValue: defaults.string(forKey: Self.gridTrailingCornerKey) ?? "")
        ?? GridOverlayOptions.defaultTrailingCorner,
      sourceTagStyle: SourceTagStyle(
        rawValue: defaults.string(forKey: Self.sourceTagStyleKey) ?? "") ?? .dateLine))
    let storedResume = SourceTagStyle(
      rawValue: defaults.string(forKey: Self.sourceTagResumeKey) ?? "")
    sourceTagResumeStyle = storedResume.flatMap { $0 == .off ? nil : $0 } ?? .dateLine
    _gridThumbnailSizing = Published(wrappedValue: GridThumbnailSizing(
      rawValue: defaults.string(forKey: Self.gridThumbnailSizingKey) ?? "") ?? .fillGrid)
    _gridGroupsByMonth = Published(
      wrappedValue: defaults.object(forKey: Self.gridGroupsByMonthKey) as? Bool ?? true)
    _gallerySort = Published(wrappedValue: Self.sort(from: defaults.string(forKey: Self.gallerySortKey)))
    _externalsSort = Published(
      wrappedValue: ExternalSort(stored: defaults.string(forKey: Self.externalsSortKey)))
    _externalsGroupsByFile = Published(
      wrappedValue: defaults.bool(forKey: Self.externalsGroupsByFileKey))
    _externalsTipDismissed = Published(
      wrappedValue: defaults.bool(forKey: Self.externalsTipDismissedKey))
    _libraryShortcuts = Published(
      wrappedValue: Set(LibraryShortcut.allCases.filter { shortcut in
        defaults.object(forKey: Self.libraryShortcutKey(shortcut)) as? Bool
          ?? LibraryShortcut.defaultShown.contains(shortcut)
      }))
    _sidebarNavigator = Published(wrappedValue: SidebarNavigator(
      rawValue: defaults.string(forKey: Self.sidebarNavigatorKey) ?? "") ?? .library)
    _copyFormats = Published(wrappedValue: defaults.data(forKey: Self.copyFormatsKey)
      .flatMap { try? JSONDecoder().decode([CopyFormat].self, from: $0) } ?? CopyFormat.factory)
    _defaultCopyFormatID = Published(wrappedValue: defaults.string(forKey: Self.defaultCopyFormatKey)
      .flatMap(UUID.init(uuidString:)) ?? CopyFormat.url.id)
    _downloadFolderPath = Published(wrappedValue: defaults.string(forKey: Self.downloadFolderKey))
    // One-time move of the drop zone's project: the old key goes, so
    // choosing All Projects (which removes the new key) is not undone by a
    // second migration on the next launch.
    if defaults.object(forKey: Self.currentProjectKey) == nil,
      let legacy = defaults.string(forKey: Self.legacyDropZoneProjectKey)
    {
      defaults.set(legacy, forKey: Self.currentProjectKey)
    }
    defaults.removeObject(forKey: Self.legacyDropZoneProjectKey)
    _currentProjectSlug = Published(wrappedValue: defaults.string(forKey: Self.currentProjectKey))
    _dockIconID = Published(
      wrappedValue: DockIconCatalog.known(defaults.string(forKey: Self.dockIconKey))
        ?? DockIconCatalog.bundleID)
    _dockIconMatchesSystem = Published(
      wrappedValue: defaults.bool(forKey: Self.dockIconMatchesSystemKey))
    _dockIconLightID = Published(
      wrappedValue: DockIconCatalog.known(defaults.string(forKey: Self.dockIconLightKey)))
    _dockIconDarkID = Published(
      wrappedValue: DockIconCatalog.known(defaults.string(forKey: Self.dockIconDarkKey))
        ?? DockIconCatalog.darkDefaultID)
    _menuBarIconID = Published(
      wrappedValue: MenuBarIconCatalog.known(defaults.string(forKey: Self.menuBarIconKey))
        ?? MenuBarIconCatalog.defaultID)
    _menuBarChartUnit = Published(
      wrappedValue: MenuBarChartUnit.known(defaults.string(forKey: Self.menuBarChartUnitKey)))
    _menuBarStorageSplit = Published(
      wrappedValue: MenuBarStorageSplit.known(defaults.string(forKey: Self.menuBarStorageSplitKey)))
  }

  private static func sort(from stored: String?) -> AssetSort {
    let parts = (stored ?? "").split(separator: ".").map(String.init)
    guard parts.count == 2,
      let field = AssetSort.Field(rawValue: parts[0]),
      let direction = AssetSort.Direction(rawValue: parts[1])
    else { return AssetSort() }
    return AssetSort(field: field, direction: direction)
  }
}
