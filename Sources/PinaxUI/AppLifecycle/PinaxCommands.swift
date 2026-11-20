import CatalogCore
import SwiftUI
import UniformTypeIdentifiers

/// The app's menu commands and shortcuts. Everything here acts on
/// things that already exist: the app model for shell actions, the key
/// window's gallery model for view-state actions.
///
/// The gallery arrives through `@FocusedObject` — not `@FocusedValue` —
/// because commands must re-evaluate when the model publishes (selection
/// details landing, view mode changing). A plain focused value only notifies
/// when the value itself changes, and the model instance never does
/// (Copy URL/Markdown would stay frozen disabled).
public struct PinaxCommands: Commands {
  @FocusedObject var gallery: GalleryModel?
  @ObservedObject private var preferences: PreferencesStore
  /// Observed for the Project menu's project list and Scan Now's targets.
  @ObservedObject private var app: PinaxAppModel

  public init(app: PinaxAppModel) {
    _app = ObservedObject(wrappedValue: app)
    _preferences = ObservedObject(wrappedValue: app.preferences)
  }

  /// View ▸ Show / Hide Activity Panel.
  static func activityPanelTitle(isOpen: Bool) -> String {
    isOpen ? "Hide Activity Panel" : "Show Activity Panel"
  }

  /// View ▸ Show's grid-metadata items, over the preference store — the
  /// binding `PreferencesStoreTests` writes through to prove this menu and
  /// the jump bar's display options read one state.
  var showItems: GridOverlayMenuItems {
    GridOverlayMenuItems(overlays: $preferences.gridOverlays)
  }

  /// View ▸ Sort By's items, over the preference store — the binding the
  /// sort tests write through to prove this menu, the jump bar's sort menu
  /// and the table headers read one order.
  var sortItems: SortMenuItems {
    SortMenuItems(sort: $preferences.gallerySort)
  }

  /// The Project menu's items, over the app's one
  /// current project — the binding and closures the tests drive.
  var projectItems: ProjectMenuItems {
    ProjectMenuItems(
      projects: app.projects.map { ProjectMenuItems.Choice(slug: $0.slug, name: $0.name) },
      current: $preferences.currentProjectSlug,
      scanTitle: preferences.currentProjectSlug == nil ? "Scan All" : "Scan Now",
      canScan: app.usageSync != nil && !app.currentProjectScanTargets.isEmpty,
      canChoose: app.gallery != nil,
      chooseProject: { [app] in app.chooseProject() },
      scanNow: { [app] in app.scanCurrentProject() },
      showProjectSettings: { [app] in app.showCurrentProjectSettings() })
  }

  /// File ▸ Import / Export Catalog Backup…, over the
  /// app's one backup model — the closures the tests drive.
  var backupItems: CatalogBackupMenuItems {
    CatalogBackupMenuItems(
      canImport: app.backup != nil,
      canExport: app.isCatalogEmpty == false,
      importBackup: { [app] in await app.importCatalogBackup() },
      exportBackup: { [app] in await app.exportCatalogBackup() })
  }

  /// Edit ▸ Delete Permanently…, over the key
  /// window's gallery. Computed here, where the gallery is observed: the
  /// item receives values, so a change reaches it as a changed input
  /// — a model reference never changes, and SwiftUI kept the
  /// item's body until the app was reactivated.
  var deleteItems: DeletePermanentlyMenuItem { Self.deleteItems(gallery) }

  static func deleteItems(_ gallery: GalleryModel?) -> DeletePermanentlyMenuItem {
    DeletePermanentlyMenuItem(
      isEnabled: gallery?.canDeleteSelectionPermanently == true,
      deletePermanently: { [gallery] in await gallery?.deletePermanentlyFromCommand() })
  }

  /// View ▸ Make Bigger / Make Smaller, over the key window's gallery;
  /// values, as `deleteItems`.
  var sizeItems: SizeMenuItems { Self.sizeItems(gallery) }

  static func sizeItems(_ gallery: GalleryModel?) -> SizeMenuItems {
    SizeMenuItems(
      canMakeBigger: gallery?.canMakeBigger == true,
      canMakeSmaller: gallery?.canMakeSmaller == true,
      makeBigger: { [gallery] in gallery?.makeBigger() },
      makeSmaller: { [gallery] in gallery?.makeSmaller() })
  }

  public var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Upload…") {
        app.pickFilesAndUpload()
      }
      .keyboardShortcut("u")
      .disabled(app.dropZone == nil)

      Button("Export Project Manifest…") {
        if let slug = gallery?.exportableProjectSlug {
          Task { await gallery?.exportManifest(project: slug) }
        }
      }
      .disabled(gallery?.exportableProjectSlug == nil || gallery?.manifestExport?.isExporting == true)

      // Photos' ⌥⇧⌘E ("Export Unmodified Original"); ⌥⌘D is
      // the system's Dock toggle and ⇧⌘D is Show Drop Zone.
      Button("Download Original") {
        Task { await gallery?.downloadSelection() }
      }
      .keyboardShortcut("e", modifiers: [.command, .option, .shift])
      .disabled(gallery?.canDownloadSelection != true)

      backupItems

      Button("Reveal Catalog in Finder…") {
        app.revealCatalogInFinder()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
    }

    CommandGroup(after: .pasteboard) {
      Button("Copy URL") {
        if let url = gallery?.selectedURL {
          Clipboard.copy(url)
        }
      }
      .keyboardShortcut("u", modifiers: [.command, .shift])
      .disabled(gallery?.selectedURL == nil)

      Button("Copy Markdown") {
        if let markdown = gallery?.selectedMarkdown {
          Clipboard.copy(markdown)
        }
      }
      .keyboardShortcut("m", modifiers: [.command, .shift])
      .disabled(gallery?.selectedMarkdown == nil)

      // The settings list, over the current selection in grid
      // order. ⌘C is the system Edit ▸ Copy, answered by the focused grid
      // in the default format (`AssetGridView`).
      Menu("Copy As") {
        ForEach(preferences.copyFormats) { format in
          Button(format.name) {
            gallery?.copySelection(as: format)
          }
        }
      }
      .disabled(gallery?.canCopySelection != true || preferences.copyFormats.isEmpty)

      Divider()

      // Photos' `.` for Favorite; ⌘⌫ archives (Put Back on
      // the Archived surface). Neither is taken elsewhere in the app.
      Button(gallery?.selectionIsFavorite == true ? "Unfavorite" : "Favorite") {
        Task { await gallery?.toggleFavoriteFromCommand() }
      }
      .keyboardShortcut(".", modifiers: [])
      .disabled(gallery?.canCurateSelection != true)

      Menu("Label") {
        ForEach(AssetLabel.allCases, id: \.self) { label in
          Button(label.title) {
            if let target = gallery?.selectionTargetIfAny {
              Task { await gallery?.toggleLabel(label, for: target) }
            }
          }
        }
      }
      .disabled(gallery?.canCurateSelection != true)

      Button(gallery?.selectionIsArchived == true ? "Put Back" : "Archive") {
        Task { await gallery?.archiveOrPutBackFromCommand() }
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(gallery?.canCurateSelection != true)

      deleteItems
    }

    // No CommandMenu("View") here: SwiftUI synthesizes its own View menu
    // (NavigationSplitView), and a second one appears beside it. Items join the
    // system View menu through its command
    // groups; replacing `.sidebar` also removes the system's ⌥⌘S variant,
    // leaving one sidebar switch with ⌃⌘S.
    CommandGroup(replacing: .sidebar) {
      Button("Toggle Sidebar") {
        gallery?.toggleSidebar()
      }
      .keyboardShortcut("s", modifiers: [.control, .command])
      .disabled(gallery == nil)
    }

    CommandGroup(after: .toolbar) {
      Picker("View Mode", selection: viewModeBinding) {
        Text("Grid").tag(GalleryModel.ViewMode.grid)
          .keyboardShortcut("1")
        Text("Table").tag(GalleryModel.ViewMode.table)
          .keyboardShortcut("2")
      }
      .disabled(gallery == nil)

      sizeItems

      Menu("Show") {
        // The same four items the jump bar's display-options menu shows,
        // over the same preference.
        showItems

        Divider()

        Toggle("Fill Grid Footprints", isOn: fillGridBinding)
      }

      Toggle("Show Source Tags", isOn: showSourceTagsBinding)

      Menu("Sort By") {
        sortItems
      }
      .disabled(gallery == nil)

      Button("Quick Look") {
        gallery?.toggleQuickLookFromCommand()
      }
      .keyboardShortcut(.space, modifiers: [])
      .disabled(gallery?.canQuickLook != true)

      Button("Toggle Inspector") {
        gallery?.toggleInspector()
      }
      .keyboardShortcut("i", modifiers: [.control, .command])
      .disabled(gallery == nil)

      // The activity panel, per window.
      Button(Self.activityPanelTitle(isOpen: gallery?.isActivityPanelOpen == true)) {
        gallery?.toggleActivityPanel()
      }
      .keyboardShortcut("y", modifiers: [.command, .shift])
      .disabled(gallery == nil)

      Divider()

      Picker("Library", selection: sidebarSelectionBinding) {
        Text("All Assets").tag(SidebarSelection.all)
          .keyboardShortcut("1", modifiers: [.command, .option])
        Text("Recent").tag(SidebarSelection.recent)
          .keyboardShortcut("2", modifiers: [.command, .option])
        Text("Orphans").tag(SidebarSelection.orphans)
          .keyboardShortcut("3", modifiers: [.command, .option])
        Text("Externals").tag(SidebarSelection.externals)
          .keyboardShortcut("4", modifiers: [.command, .option])
      }
      .disabled(gallery == nil)
    }

    // After View, before Navigate.
    CommandMenu("Project") {
      projectItems
    }

    // Xcode's Navigate menu: back and forward over the places the
    // sidebar has shown, the jump bar's ◀ ▶ under their Xcode shortcuts.
    CommandMenu("Navigate") {
      Button("Go Back") {
        gallery?.goBack()
      }
      .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
      .disabled(gallery?.canGoBack != true)

      Button("Go Forward") {
        gallery?.goForward()
      }
      .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
      .disabled(gallery?.canGoForward != true)

      Divider()

      Button("Focus Search") {
        gallery?.focusSearch()
      }
      .keyboardShortcut("f")
      .disabled(gallery == nil)
    }

    CommandGroup(after: .windowArrangement) {
      Button("Show Drop Zone") {
        app.revealDropZone()
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(app.dropZone == nil)
    }
  }

  /// Optional-model bindings: nil gallery renders the picker stateless; the
  /// commands above disable it in that case, so the binding's fallback is
  /// never actually surfaced.
  private var viewModeBinding: Binding<GalleryModel.ViewMode> {
    Binding(
      get: { gallery?.surfaceViewMode ?? .grid },
      set: { newValue in gallery?.surfaceViewMode = newValue }
    )
  }

  /// The Library menu's four items live in two trees: All Assets and
  /// Recent in Library, Orphans and Externals in Reports. Each write goes
  /// to the navigator whose tree has its row — writing it into whichever
  /// navigator happened to be showing would select a row that tree does
  /// not have —
  /// and the checkmark reads the current navigator's slot when that slot
  /// holds one of the four, else Library's.
  private var sidebarSelectionBinding: Binding<SidebarSelection> {
    Binding(
      get: {
        guard let gallery else { return .all }
        let current = gallery.sidebarSelection
        switch current {
        case .all, .recent, .orphans, .externals: return current
        default: return gallery.navigatorSelections[.library] ?? .all
        }
      },
      set: { newValue in
        gallery?.select(newValue, in: SidebarModel.navigator(for: newValue))
      }
    )
  }

  /// View ▸ Show Source Tags, computed here, not in a menu view: it
  /// reads and writes the one preference the Settings picker shares, and
  /// turning it off then on brings the prior style back.
  var showSourceTagsBinding: Binding<Bool> {
    Binding(
      get: { preferences.showsSourceTags },
      set: { newValue in
        if newValue != preferences.showsSourceTags { preferences.toggleSourceTags() }
      })
  }

  private var fillGridBinding: Binding<Bool> {
    Binding(
      get: { preferences.gridThumbnailSizing == .fillGrid },
      set: { preferences.gridThumbnailSizing = $0 ? .fillGrid : .originalAspect })
  }
}

/// View ▸ Make Bigger (⌘+) and Make Smaller (⌘−), Finder's:
/// one rung per command on the current mode's ladder — grid columns in the
/// grid, row height in the table. `.disabled` at the ladder's ends so
/// saturation shows in the menu instead of being swallowed. A
/// SwiftUI item takes one shortcut, and AppKit fires a "+" item on ⌘+ only
/// (measured), so ⌘= is not bound.
struct SizeMenuItems: View {
  let canMakeBigger: Bool
  let canMakeSmaller: Bool
  let makeBigger: () -> Void
  let makeSmaller: () -> Void

  var body: some View {
    Button("Make Bigger") {
      makeBigger()
    }
    .keyboardShortcut("+", modifiers: .command)
    .disabled(!canMakeBigger)

    Button("Make Smaller") {
      makeSmaller()
    }
    .keyboardShortcut("-", modifiers: .command)
    .disabled(!canMakeSmaller)
  }
}

/// File ▸ Import Catalog Backup… / Export Catalog Backup…: one group with a
/// separator on each side. Import fills an empty
/// catalog, or replaces one after asking twice; Export only from one with
/// something in it.
struct CatalogBackupMenuItems: View {
  let canImport: Bool
  let canExport: Bool
  let importBackup: () async -> Void
  let exportBackup: () async -> Void

  var body: some View {
    Divider()
    Button("Import Catalog Backup…") { Task { await importBackup() } }
      .disabled(!canImport)
    Button("Export Catalog Backup…") { Task { await exportBackup() } }
      .disabled(!canExport)
    Divider()
  }
}

/// Project ▸: Choose Project… (⌃0, Xcode's Choose
/// Scheme), All Projects and every project with the current one checked,
/// then Scan Now — Scan All under All Projects — and Project Settings….
/// Choose Project… opens the title area's project picker.
struct ProjectMenuItems: View {
  struct Choice: Hashable {
    let slug: String
    let name: String
  }

  let projects: [Choice]
  @Binding var current: String?
  let scanTitle: String
  let canScan: Bool
  let canChoose: Bool
  let chooseProject: () -> Void
  let scanNow: () -> Void
  let showProjectSettings: () -> Void

  var body: some View {
    Button("Choose Project…", action: chooseProject)
      .keyboardShortcut("0", modifiers: .control)
      .disabled(!canChoose)

    Divider()

    Picker("Project", selection: $current) {
      Text("All Projects").tag(String?.none)
      ForEach(projects, id: \.slug) { project in
        Text(project.name).tag(String?.some(project.slug))
      }
    }
    .pickerStyle(.inline)
    .labelsHidden()

    Divider()

    Button(scanTitle, action: scanNow)
      .disabled(!canScan)

    ProjectSettingsLinkButton(title: "Project Settings…", action: showProjectSettings)
  }
}

/// Edit ▸ Delete Permanently…: ⌥⌘⌫, Finder's Delete
/// Immediately key; ⌘⌫ stays Archive / Put Back. Always in the menu: the menu
/// bar did not redraw an item inserted conditionally, and the
/// key went with it. Enabled on Archived when every selected item is
/// archived and no delete or restore is running.
struct DeletePermanentlyMenuItem: View {
  let isEnabled: Bool
  let deletePermanently: () async -> Void

  var body: some View {
    Button("Delete Permanently…") {
      Task { await deletePermanently() }
    }
    .keyboardShortcut(.delete, modifiers: [.option, .command])
    .disabled(!isEnabled)
  }
}
