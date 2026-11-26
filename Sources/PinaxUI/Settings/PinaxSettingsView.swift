import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// The Settings scene. The panes act on `UserDefaults` through the preferences
/// store, on pure path computations, or — Projects — on `project` rows via
/// `CatalogConfiguration`, writing only when the user commits a change —
/// never as a side effect of being displayed.
///
/// A sidebar and the selected page, the page's name over
/// it; 780 wide, 960 on the two pages with a list column; the height the
/// user's, the page scrolling inside it.
///
/// Both columns run to the window's top edge under a transparent bar: the
/// sidebar's material behind the traffic lights, the
/// page's title band on the page's own ground with no line under it.
public struct PinaxSettingsView: View {
  @ObservedObject public var preferences: PreferencesStore
  /// Observed so the Projects pane appears once the catalog has opened; the
  /// model itself stays absent if `start()` failed, and the pane says so.
  @ObservedObject public var app: PinaxAppModel

  public init(preferences: PreferencesStore, app: PinaxAppModel) {
    self.preferences = preferences
    self.app = app
  }

  /// The sidebar's width, which the user drags at its edge; the page keeps
  /// its width and the window follows.
  @State private var sidebarWidth = Metrics.sidebarWidth
  @State private var dragStartWidth: CGFloat?

  public var body: some View {
    HStack(spacing: DesignMetrics.spacing.none) {
      SettingsSidebar(selection: $app.settingsTab, width: sidebarWidth)
        .overlay(alignment: .trailing) {
          Rectangle()
            .fill(PinaxPalette.Settings.columnDivider)
            .frame(width: Metrics.columnDividerWidth)
        }
        .overlay(alignment: .trailing) { sidebarEdge }
        // Above the page, so the edge's page-side half still takes the drag.
        .zIndex(1)
      VStack(spacing: DesignMetrics.spacing.none) {
        Text(app.settingsTab.title)
          .pinaxSettingsPageTitle()
          .padding(.horizontal, Metrics.pageInset)
          .frame(maxWidth: .infinity, minHeight: Metrics.titleBarHeight, maxHeight: Metrics.titleBarHeight, alignment: .leading)
        page
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .background(PinaxPalette.Settings.window)
    }
    .ignoresSafeArea(.container, edges: .top)
    .frame(width: Metrics.windowWidth(for: app.settingsTab, sidebar: sidebarWidth))
    .frame(minHeight: Metrics.minHeight, idealHeight: Metrics.idealHeight, maxHeight: .infinity)
    .background(SettingsWindowChrome())
    // On the window, not a page: a Scan Now from Backends asks here too.
    .commandApprovalSheet(app.usageSync, presenter: .settings)
  }

  /// A strip astride the sidebar's edge that drags its width.
  private var sidebarEdge: some View {
    Color.clear
      .frame(width: Metrics.sidebarEdgeHitWidth)
      .contentShape(Rectangle())
      .offset(x: Metrics.sidebarEdgeHitWidth / 2)
      .onHover { inside in
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let start = dragStartWidth ?? sidebarWidth
            dragStartWidth = start
            sidebarWidth = min(
              max(start + drag.translation.width, Metrics.sidebarMinWidth), Metrics.sidebarMaxWidth)
          }
          .onEnded { _ in dragStartWidth = nil })
  }

  /// The selected page only: the others are not built until chosen.
  @ViewBuilder private var page: some View {
    switch app.settingsTab {
    case .general: GeneralSettingsPane(preferences: preferences)
    case .appearance: AppearanceSettingsPane(preferences: preferences)
    case .dropZone: DropZoneSettingsPane(preferences: preferences, projects: app.projects)
    case .gallery: GallerySettingsPane(preferences: preferences)
    case .projects: ProjectsSettingsPane(app: app)
    case .backends: BackendsSettingsPane(app: app)
    case .maintenance: MaintenanceSettingsPane(app: app)
    }
  }
}

/// The Settings scene's window: content under a transparent title bar with no
/// title and no line under it; an empty unified toolbar makes that bar the
/// title band's 52 pt, which seats the traffic lights where the design has
/// them. The scene gives no resize edge; this adds one — each page fixes the
/// width, so only the height drags.
struct SettingsWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { ChromeProbe() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  static let required: NSWindow.StyleMask = [.fullSizeContentView, .resizable]

  static func apply(to window: NSWindow) {
    if !window.styleMask.isSuperset(of: required) {
      window.styleMask.formUnion(required)
    }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    if window.toolbar == nil {
      window.toolbar = NSToolbar(identifier: "pinax.settings")
    }
    window.toolbar?.showsBaselineSeparator = false
    window.toolbarStyle = .unified
  }

  private final class ChromeProbe: NSView {
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observation = nil
      guard let window else { return }
      SettingsWindowChrome.apply(to: window)
      // Turning the page re-fits the window and may reset the mask; put
      // the full-size content and the resize edge back.
      observation = window.observe(\.styleMask) { window, _ in
        guard !window.styleMask.isSuperset(of: SettingsWindowChrome.required) else { return }
        MainActor.assumeIsolated { SettingsWindowChrome.apply(to: window) }
      }
    }
  }
}

/// The Settings window's pages, in sidebar order.
public enum SettingsTab: Hashable, Sendable {
  case general, appearance, dropZone, gallery, projects, backends, maintenance
}
