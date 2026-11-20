import AppKit
import CatalogCore
import SwiftUI

/// The split view's width budget, in one place. Invariant:
///
///     sidebarReserve + detailMin + inspectorReserve <= windowMinWidth
///     (sidebarMax + 1) + detailMin + (inspectorWidth + 1) = 261 + 338 + 301 = 900
///
/// With both side columns shown, every column minimum must fit inside the
/// smallest window the user may keep. Over-constrained (say 180 + 480 + 300
/// + 2 = 962 inside 900), AppKit pushes the entire split view 31 pt past
/// the window's left edge (measured in the running app). The detail minimum
/// is the lever that moves: the centre column is the one that absorbs
/// width. The sidebar is reserved at
/// its *max*: a sidebar the user dragged wider must still pass the check
/// below when it reopens.
///
/// The minimum width has two layers, and they must stay apart:
///
/// * SwiftUI's layer, `contentMinWidth`, follows the visible columns. Before
///   SwiftUI expands a side column it checks `window width − column width >=
///   current minimum`; when that fails it keeps the centre column's width
///   and asks the window to grow instead. The window does not grow, so the
///   split view overflows both window edges for the whole transition and
///   snaps back on its last frame (measured: 900 → 1121 pt at x −110).
///   A minimum that already excludes the closed column's room passes the
///   check in every state, so the centre column is squeezed frame by frame.
/// * The window's real floor, `windowMinWidth`, is an AppKit constraint on
///   the content view (`WindowMinimumWidthMount`).
///
/// Do not put a fixed `minWidth: windowMinWidth` back on any SwiftUI view:
/// at the minimum window width it fails SwiftUI's check for every side
/// column, which is the overflow above. Do not raise `windowMinWidth`
/// either: small screens need it.
enum GalleryWidthBudget {
  static let windowMinWidth: CGFloat = 900
  static let sidebarMin: CGFloat = 180
  static let sidebarIdeal: CGFloat = 220
  static let sidebarMax: CGFloat = 260
  static let detailMin: CGFloat = 338
  static let inspectorWidth: CGFloat = 300
  /// The live split views' dividers measured 1 pt each.
  static let dividerWidth: CGFloat = 1

  /// The room opening a side column needs: the column plus its divider.
  static var sidebarReserve: CGFloat { sidebarMax + dividerWidth }
  static var inspectorReserve: CGFloat { inspectorWidth + dividerWidth }

  /// SwiftUI's layer of the window minimum for the visible columns.
  static func contentMinWidth(sidebarVisible: Bool, inspectorVisible: Bool) -> CGFloat {
    detailMin
      + (sidebarVisible ? sidebarReserve : 0)
      + (inspectorVisible ? inspectorReserve : 0)
  }

  static var budgetCloses: Bool {
    sidebarReserve + detailMin + inspectorReserve <= windowMinWidth
  }
}

public struct GalleryView: View {
  /// Owned by `PinaxAppModel` for the app's lifetime, so observing (not
  /// owning) it here keeps one gallery model behind the window.
  @ObservedObject public var model: GalleryModel
  @State private var suppressFirstReloadToken = true
  /// The activity panel's switch, per window.
  @SceneStorage("activityPanelOpen") private var storedActivityPanelOpen = false
  // The panel's dragged height and run-list width, per window.
  @SceneStorage("activityPanelHeight") private var storedActivityPanelHeight =
    Double(ActivityPanelModel.defaultHeight)
  @SceneStorage("activityRunListWidth") private var storedActivityRunListWidth =
    Double(ActivityPanelModel.defaultRunListWidth)
  @State private var centerColumnHeight: CGFloat = 0
  private let inspectorPresentationIdentityProbe: ((UUID) -> Void)?

  @MainActor
  public init(model: GalleryModel) {
    self.model = model
    self.inspectorPresentationIdentityProbe = nil
  }

  /// Tests observe the inspector's root `@State` across window resizes.
  @MainActor
  init(model: GalleryModel, inspectorPresentationIdentityProbe: @escaping (UUID) -> Void) {
    self.model = model
    self.inspectorPresentationIdentityProbe = inspectorPresentationIdentityProbe
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: splitVisibility) {
      SidebarView(model: model)
        // An explicit max stops the split view from renegotiating the
        // sidebar's width whenever the inspector appears or disappears; only
        // the centre column absorbs width changes. The three values are part
        // of the width budget (GalleryWidthBudget) — change them there.
        .navigationSplitViewColumnWidth(
          min: GalleryWidthBudget.sidebarMin,
          ideal: GalleryWidthBudget.sidebarIdeal,
          max: GalleryWidthBudget.sidebarMax)
    } detail: {
      centerColumn
        .frame(minWidth: GalleryWidthBudget.detailMin)
    }
    // Docked at every width. The column's show/hide is the system's own
    // split-view transition; the minimum below keeps it smooth at 900 pt.
    .inspector(isPresented: $model.showsInspector) {
      AssetInspectorView(
        model: model,
        presentationIdentityProbe: inspectorPresentationIdentityProbe,
        usesMaterialBackground: true
      )
      .inspectorColumnWidth(GalleryWidthBudget.inspectorWidth)
      // The title, in the column's strip under the toolbar, on
      // the toggle's row.
      .overlay(alignment: .topLeading) {
        InspectorTitleBar(model: model)
      }
    }
    // SwiftUI's layer of the window minimum; the 900 pt floor is the AppKit
    // constraint below. See GalleryWidthBudget for why the two are apart.
    .frame(
      minWidth: GalleryWidthBudget.contentMinWidth(
        sidebarVisible: model.isSidebarVisible,
        inspectorVisible: model.showsInspector))
    .background(WindowMinimumWidthMount(width: GalleryWidthBudget.windowMinWidth))
    // The inspector toggle and its tracking separator.
    .background(InspectorToggleMount(model: model))
    // The scene's focusable object, not a plain focused value: menu commands
    // must re-evaluate when the model publishes (selection, view mode), which
    // `@FocusedValue` does not subscribe to.
    .focusedSceneObject(model)
    .alert(
      "Project Export",
      isPresented: Binding(
        get: { model.manifestExport?.notice != nil },
        set: { shown in if !shown { model.manifestExport?.dismissNotice() } })
    ) {
      Button("OK") { model.manifestExport?.dismissNotice() }
    } message: {
      Text(model.manifestExport?.notice ?? "")
    }
  }

  /// The model stores a plain Bool; only this view knows the SwiftUI
  /// visibility enum. Collapsing the sidebar by dragging its divider writes
  /// back through the binding, so the ⌃⌘S state never disagrees with reality.
  private var splitVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { model.isSidebarVisible ? .all : .detailOnly },
      set: { model.isSidebarVisible = $0 != .detailOnly }
    )
  }

  /// One value summarizing every input that should restart the asset query.
  /// The search text and scope are excluded on the report surfaces —
  /// `reloadOrphans`/`reloadUsage` do not read them, so counting them there
  /// meant every keystroke re-ran a full scan for nothing.
  /// Internal rather than private so the tests can assert on the value
  /// itself: switching navigator must not change it unless the
  /// projected selection really changed. Deliberately does **not** carry the
  /// navigator — the navigator is not a query input.
  var reloadToken: ReloadToken {
    let isReportSurface: Bool
    switch model.sidebarSelection {
    case .overview, .orphans, .externals, .usage: isReportSurface = true
    default: isReportSurface = false
    }
    return ReloadToken(
      selection: model.sidebarSelection,
      timeFilter: model.timeFilter,
      searchText: isReportSurface ? nil : model.searchText,
      searchScope: isReportSurface ? nil : model.searchScope,
      searchMatch: isReportSurface ? nil : model.searchMatch,
      searchCaseSensitive: isReportSurface ? nil : model.searchCaseSensitive,
      sourceFilter: isReportSurface ? nil : model.sourceFilter,
      sort: isReportSurface ? nil : model.sort
    )
  }

  struct ReloadToken: Equatable {
    let selection: GalleryModel.SidebarSelection
    let timeFilter: GalleryModel.TimeFilter
    /// Nil on the report surfaces: those reloads do not read them.
    let searchText: String?
    let searchScope: GalleryModel.SearchScope?
    let searchMatch: SearchMatch?
    let searchCaseSensitive: Bool?
    /// A new source is a new result set; nil on the report
    /// surfaces, which do not read it.
    let sourceFilter: AssetSource?
    /// A new order is a new first page. Nil on the report
    /// surfaces, which do not read it.
    let sort: AssetSort?
  }

  /// The strip pops out on ⌘F (Navigate ▸ Focus Search) and stays up while a
  /// filter is active, so the filter state stays visible through the
  /// strip itself instead of a second indicator.
  var showsFilterBar: Bool {
    model.isSearchPresented
    || !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    || model.sourceFilter != nil
  }

  /// The switch over the sidebar selection sits inside a `ZStack` — a
  /// container whose identity survives branch changes — and every modifier
  /// that must survive a selection change (`.navigationTitle`, `.toolbar`,
  /// the reload tasks) attaches outside it. A `Group` is transparent, so
  /// attaching them to a switch-wrapping group left the toolbar riding on
  /// whichever branch was showing.
  ///
  /// Search lives in the pop-out find strip at the top of this column
  /// (`FindStrip`), not in `.searchable`: measured on macOS 15, the
  /// searchable field is pinned to the window toolbar's right edge —
  /// visually over the inspector — and the API that anchors it to the
  /// centre section (`ToolbarSpacer`) needs macOS 26. The strip uses
  /// standard controls only; only the placement is bespoke.
  private var centerColumn: some View {
    VStack(spacing: 0) {
      // Xcode's editor-area order: jump bar directly under
      // the toolbar, find strip under the jump bar, status strip at the
      // bottom.
      JumpBar(model: model)
      if showsFilterBar {
        FindStrip(model: model)
      }
      // Archived's deletions that did not finish.
      if let banner = model.deletionBanner {
        DeletionBannerView(model: model, banner: banner)
      }
      GallerySurface(model: model)
      // The count and the selection on the left,
      // background activity on the right.
      GalleryStatusBar(model: model)
        // The bar's top edge is the panel's, and drags its height.
        .overlay(alignment: .top) {
          if model.isActivityPanelOpen {
            ActivityPanelResizeHandle(height: $storedActivityPanelHeight, windowHeight: centerColumnHeight)
          }
        }
      // The panel rises under the bar and the content above gives
      // way — one height animation, no split view.
      ActivityPanelView(model: model.activityPanel, runListWidth: $storedActivityRunListWidth)
        .frame(
          height: model.isActivityPanelOpen
            ? ActivityPanelModel.clampedHeight(CGFloat(storedActivityPanelHeight), windowHeight: centerColumnHeight)
            : 0)
        .clipped()
        .opacity(model.isActivityPanelOpen ? 1 : 0)
        .accessibilityHidden(!model.isActivityPanelOpen)
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { centerColumnHeight = $0 }
    .animation(ActivityPanelView.animation, value: model.isActivityPanelOpen)
    .onAppear { model.isActivityPanelOpen = storedActivityPanelOpen }
    .onChange(of: model.isActivityPanelOpen) { _, open in storedActivityPanelOpen = open }
    .navigationTitle(windowTitle.title)
    // The current project, never empty (AppKit draws an empty
    // subtitle as one centred line and the title jumps).
    .navigationSubtitle(windowTitle.subtitle)
    // A batch archive, or one with live usage, asks once.
    .confirmationDialog(
      model.pendingArchive?.title ?? "",
      isPresented: Binding(
        get: { model.pendingArchive != nil },
        set: { if !$0 { model.cancelArchive() } }
      ),
      titleVisibility: .visible,
      presenting: model.pendingArchive
    ) { pending in
      Button(pending.count == 1 ? "Archive" : "Archive \(pending.count) Items") {
        Task { await model.confirmArchive(pending) }
      }
      Button("Cancel", role: .cancel) { model.cancelArchive() }
    } message: { pending in
      Text(pending.message)
    }
    // Delete Permanently…'s sheet.
    .sheet(
      isPresented: Binding(
        get: { model.pendingDeletion != nil },
        set: { if !$0 { model.cancelDeletion() } })
    ) {
      if let pending = model.pendingDeletion {
        DeletionConfirmationSheet(
          confirmation: pending,
          cancel: { model.cancelDeletion() },
          delete: { Task { await model.confirmDeletion(pending) } },
          removeFromProject: { Task { await model.confirmRemoveFromProject(pending) } })
      }
    }
    // The domain move's sheet, over Usage.
    .modifier(DomainMigrationSheetMount(domain: model.domainMigration))
    .task { await model.loadInitialData() }
    .task(id: reloadToken) {
      if suppressFirstReloadToken {
        suppressFirstReloadToken = false
        return
      }
      await model.reload()
    }
    .toolbar {
      // The items are stable in count and position under every
      // navigator — disabled in place on the report surfaces (and the grid
      // pair in table mode), never removed, so the toolbar cannot reflow.
      // The window title leads; view mode is the centred item;
      // the trailing side reads grid pair → Share → ♥ → Search, ahead of
      // the inspector toggle the mount appends. `.automatic` keeps the pair
      // out of the navigational items AppKit places before the title, and
      // no placement puts it right after the title (measured). AppKit
      // centres the centred item in the content section, between the
      // sidebar and a docked inspector, not in the window (measured). A
      // window too narrow for them all overflows into AppKit's own menu.
      // Items slide with the system's own transition when the inspector
      // shows/hides.
      // The title area — the leaf row over the current
      // project, which opens the project picker — in place of the system
      // title the window's toolbar style hides.
      ToolbarItem(placement: .navigation) {
        ProjectTitleItem(model: model, title: windowTitle)
      }
      ToolbarItemGroup(placement: .automatic) {
        GridToolbarControls(model: model)
          // Both Usage pages' grids follow the zoom rung.
          .disabled(!showsAssetToolbar && !showsUsageImages && !zoomsExternals)
      }
      // View mode is the toolbar's centred item, Photos' Years /
      // Months / All Photos.
      ToolbarItem(placement: .principal) {
        ViewModePicker(model: model, externals: model.externals)
          .disabled(
            !showsAssetToolbar && !(showsUsageImages && model.usagePage == .images)
              && model.shownSelection != .externals)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        ShareToolbarButton(model: model)
          .disabled(!showsAssetToolbar && !showsUsageImages)
        FavoriteToolbarButton(model: model)
          .disabled(!showsAssetToolbar && !showsUsageImages)
        searchButton
          .disabled(!showsAssetToolbar)
      }
    }
  }

  /// The title area's text, for the place being drawn.
  var windowTitle: WindowTitle {
    WindowTitle.compose(
      selection: model.shownSelection, projects: model.projects,
      currentProjectSlug: model.currentProjectSlug, backends: model.domainBackends)
  }

  /// The asset toolbar items only drive asset queries; the orphan and
  /// usage views are report surfaces with their own controls.
  private var showsAssetToolbar: Bool {
    switch model.shownSelection {
    case .overview, .orphans, .externals, .usage: return false
    default: return true
    }
  }

  /// Usage shows the library's own grid and table, so
  /// the items that drive them — not search or sort, which Usage does not
  /// read — work there too; Grid | Table only on Images.
  private var showsUsageImages: Bool {
    model.shownSelection == .usage
  }

  /// Externals' Grid zooms with the library's columns; its list
  /// has nothing to zoom.
  private var zoomsExternals: Bool {
    model.shownSelection == .externals && model.zoomLadder != nil
  }

  /// Same state ⌘F sets, through the same model call; a second click
  /// dismisses the strip the way Escape does.
  private var searchButton: some View {
    Button {
      if model.isSearchPresented {
        model.isSearchPresented = false
      } else {
        model.focusSearch()
      }
    } label: {
      Label("Search", systemImage: "magnifyingglass")
    }
    .help("Search")
  }

}

/// The toolbar's centred Grid | Table. It observes Externals too:
/// there it is the shown half's own view.
struct ViewModePicker: View {
  @ObservedObject var model: GalleryModel
  @ObservedObject var externals: ExternalsModel

  var body: some View {
    Picker("View mode", selection: $model.surfaceViewMode) {
      Label("Grid", systemImage: "square.grid.2x2").tag(GalleryModel.ViewMode.grid)
      Label("Table", systemImage: "list.bullet.rectangle").tag(GalleryModel.ViewMode.table)
    }
    .pickerStyle(.segmented)
    // Words, like Photos' Years / Months / All Photos: with images, the
    // toolbar draws the segments as loose icon buttons, not one control.
    .labelStyle(.titleOnly)
    .accessibilityIdentifier("view-mode-picker")
  }
}

/// Escape in the filter bar clears the text and dismisses the bar, as a
/// searchable field's would. Measured (and covered by a test):
/// AppKit's field editor consumes Escape as `cancelOperation:` before
/// SwiftUI's `onKeyPress` ever fires, so the delivery rides a local key
/// monitor — consulted in `NSApp.sendEvent` ahead of the responder chain —
/// scoped to the filter field's focus state and this view's window.
struct EscapeMonitor: NSViewRepresentable {
  let focus: FocusState<Bool>.Binding
  let onEscape: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.owner = view
    context.coordinator.handler = onEscape
    context.coordinator.focus = focus
    context.coordinator.install()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.handler = onEscape
    context.coordinator.focus = focus
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  final class Coordinator {
    weak var owner: NSView?
    var focus: FocusState<Bool>.Binding?
    var handler: () -> Void = {}
    private var monitor: Any?

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self,
          event.keyCode == 53,  // Escape
          self.focus?.wrappedValue == true,
          let window = self.owner?.window,
          event.window === window
        else { return event }
        self.handler()
        return nil  // consumed
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// The centre column between the jump bar and the status bar: the report
/// surface the sidebar chose, or the asset grid / table, or its empty
/// state. It takes the whole height the column leaves it — an empty state's
/// natural height must not let the column shrink to it and float the jump
/// bar and status bar into the middle (Archived with nothing in it).
struct GallerySurface: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    ZStack {
      switch model.shownSelection {
      case .overview:
        OverviewView(model: model)
      case .orphans:
        OrphanView(model: model)
      case .externals:
        ExternalsView(
          model: model.externals, columns: model.gridColumns,
          zoom: { $0 > 0 ? model.zoomIn() : model.zoomOut() })
      case .usage:
        UsageView(model: model)
      default:
        if model.showsEmptyAssets {
          emptyAssets
        } else {
          switch model.viewMode {
          case .grid:
            AssetGridView(model: model)
          case .table:
            AssetTableView(model: model)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// An asset view with nothing in it — the failure if the query
  /// failed, the system's search state while searching, an empty folder
  /// under a key prefix, and otherwise No Assets with Upload….
  @ViewBuilder
  private var emptyAssets: some View {
    let search = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if let message = model.errorMessage {
      FailureStateView(message: message)
    } else if !search.isEmpty {
      ContentUnavailableView.search(text: search)
    } else if case .keyPrefix = model.shownSelection {
      ContentUnavailableView(.emptyFolder)
    } else {
      NoAssetsState(model: model)
    }
  }
}

/// No Assets. On an empty catalog Restore from
/// Backup… leads and Upload… follows; otherwise Upload… alone.
struct NoAssetsState: View {
  @ObservedObject var model: GalleryModel

  var showsRestore: Bool { model.showsCatalogRestore }

  /// The Restore button's action: the one restore every entry calls.
  var restoreAction: () async -> Void {
    { [model] in await model.requestRestore() }
  }

  var body: some View {
    ContentUnavailableView(.noAssets) {
      if showsRestore {
        HStack {
          Button("Restore from Backup…") { Task { await restoreAction() } }
            .buttonStyle(.borderedProminent)
          Button("Upload…") { model.requestUpload() }
        }
      } else {
        Button("Upload…") { model.requestUpload() }
      }
    }
  }
}
