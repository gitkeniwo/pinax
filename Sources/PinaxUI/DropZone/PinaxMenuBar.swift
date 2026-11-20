import AppKit
import CatalogCore
import SwiftUI

/// The menu bar's content: a `.window` panel, 340 pt
/// wide — header, the clipboard card, RECENT 4 × 2, and the switches. The
/// status item still takes no drops. What the page shows comes from
/// `MenuBarSummary`; this view only draws it.
public struct PinaxMenuBarContent: View {
  /// The panel's pages: the Library page replaces the home page in
  /// the same panel, at the same width.
  enum Page { case home, library }

  static let width: CGFloat = 340

  @ObservedObject public var app: PinaxAppModel
  /// Observed directly so preference toggles re-render this panel even
  /// though the app model itself did not change.
  @ObservedObject private var preferences: PreferencesStore
  @StateObject private var panel = MenuBarPanelModel()
  @State private var page = Page.home
  /// Where the statistics card sits on the home page, and each page's
  /// height, in the panel's own space: the two ends of the card's open /
  /// close (a Control Center module opening into its detail).
  @State private var cardFrame = CGRect.zero
  @State private var heights: [Page: CGFloat] = [:]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  /// The panel's coordinate space: the card reports its frame in it.
  static let space = "pinaxMenuBarPanel"

  public init(app: PinaxAppModel) {
    self.app = app
    self.preferences = app.preferences
  }

  public var body: some View {
    let summary = MenuBarSummary(app: app, clipboard: panel.clipboard?.info)
    let library = summary.isFirstRun ? nil : MenuBarLibrary(app: app)
    let shown = page == .library && library != nil ? Page.library : .home
    let expanded = CGRect(
      x: 0, y: 0, width: Self.width, height: heights[.library] ?? heights[.home] ?? 0)
    ZStack(alignment: .topLeading) {
      // One platter for both pages: the card's on the home page, the whole
      // panel on the Library page. It springs between the two; nothing
      // under it is left once it grows (the home page has shrunk away).
      if library != nil {
        Color.clear
          .menuBarCard(border: shown == .home)
          .frame(
            width: shown == .home ? cardFrame.width : expanded.width,
            height: shown == .home ? cardFrame.height : expanded.height)
          .offset(
            x: shown == .home ? cardFrame.minX : expanded.minX,
            y: shown == .home ? cardFrame.minY : expanded.minY)
          .transaction { if reduceMotion { $0.animation = nil } }
          .accessibilityHidden(true)
      }
      switch (shown, library) {
      case (.library, let library?):
        VStack(alignment: .leading, spacing: DesignMetrics.menuBarLibrary.pageSpacing) {
          MenuBarLibraryPage(
            app: app, preferences: preferences, panel: panel, library: library,
            back: { go(.home) }, openGallery: openGallery)
        }
        .modifier(PageFrame(page: .library, heights: $heights, animation: animation))
        // The page unrolls with the platter: it shows only inside it. On
        // the way back it rolls up and is gone quickly — the spring's long
        // tail would otherwise leave it showing inside the card.
        .transition(
          reduceMotion
            ? .opacity
            : .asymmetric(
              insertion: reveal(expanded),
              removal: reveal(expanded).combined(
                with: .opacity.animation(
                  .easeIn(duration: DesignMetrics.menuBarLibrary.pageOutDuration)))))
      default:
        VStack(alignment: .leading, spacing: DesignMetrics.menuBarLibrary.homeSpacing) {
          MenuBarHome(
            app: app, preferences: preferences, panel: panel, summary: summary,
            library: library,
            placeCard: { frame in
              // The platter follows the card as it lays out (the panel's first
              // open, RECENT or the clipboard card arriving) without
              // animating: only opening and closing the page animate.
              var still = Transaction()
              still.disablesAnimations = true
              withTransaction(still) { cardFrame = frame }
            },
            openLibrary: {
              panel.openLibrary(preferences: preferences)
              go(.library)
            },
            openGallery: openGallery, openSettings: openSettingsWindow,
            setUpBackend: setUpBackend)
        }
        .modifier(PageFrame(page: .home, heights: $heights, animation: nil))
        // The rest of the panel shrinks and is gone before the platter has
        // grown; on the way back it settles in as the platter lands.
        .transition(
          reduceMotion
            ? .opacity
            : .asymmetric(
              insertion: .scale(scale: DesignMetrics.menuBarLibrary.homeScale)
                .combined(with: .opacity)
                .animation(
                  .easeOut(duration: DesignMetrics.menuBarLibrary.homeInDuration)
                    .delay(DesignMetrics.menuBarLibrary.homeInDelay)),
              removal: .scale(scale: DesignMetrics.menuBarLibrary.homeScale)
                .combined(with: .opacity)
                .animation(.easeIn(duration: DesignMetrics.menuBarLibrary.homeOutDuration))))
      }
    }
    // The panel takes the new page's height at once; a page leaving draws
    // past it and is clipped by the window (a window does not animate
    // its own resize here).
    .frame(width: Self.width, height: heights[shown], alignment: .topLeading)
    .coordinateSpace(name: Self.space)
    // ⌘D opens the gallery, ⌘, Settings: the panel closes, the window comes front.
    .background {
      Group {
        Button("Open Gallery") { openGallery() }.keyboardShortcut("d")
        Button("Settings") { openSettingsWindow() }.keyboardShortcut(",")
      }
      .hidden()
      .accessibilityHidden(true)
    }
    // The refresh point: the panel's own window becoming key.
    .background(PanelWindowReader { [panel, app] window in panel.attach(window: window, app: app) })
  }

  private var animation: Animation {
    reduceMotion
      ? .easeInOut(duration: DesignMetrics.menuBarLibrary.fadeDuration)
      : .spring(
        response: DesignMetrics.menuBarLibrary.morphResponse,
        dampingFraction: DesignMetrics.menuBarLibrary.morphDamping)
  }

  private func reveal(_ expanded: CGRect) -> AnyTransition {
    .modifier(active: MenuBarReveal(frame: cardFrame), identity: MenuBarReveal(frame: expanded))
  }

  private func go(_ target: Page) {
    withAnimation(animation) { page = target }
  }

  private func openGallery() {
    // Menu bar actions run in a tracking run loop, where a policy switch
    // alone often fails to register in the Dock — hence the double-hop
    // (the same workaround as Clop's BatchWindow).
    panel.dismiss()
    AppActivation.makeRegularNow()
    openWindow(id: "gallery")
    Self.bringFront { $0.identifier?.rawValue.lowercased().contains("gallery") == true }
  }

  private func openSettingsWindow() {
    panel.dismiss()
    AppActivation.makeRegularNow()
    openSettings()
    Self.bringFront { $0.identifier?.rawValue.lowercased().contains("settings") == true }
  }

  /// Raises and focuses the matching window once SwiftUI has shown it.
  private static func bringFront(_ match: @escaping (NSWindow) -> Bool) {
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first(where: match)?.makeKeyAndOrderFront(nil)
    }
  }

  private func setUpBackend() {
    app.settingsTab = .backends
    openSettingsWindow()
  }
}

// MARK: - Home and footer

private struct MenuBarHome: View {
  @ObservedObject var app: PinaxAppModel
  @ObservedObject var preferences: PreferencesStore
  @ObservedObject var panel: MenuBarPanelModel
  let summary: MenuBarSummary
  let library: MenuBarLibrary?
  /// Told where the statistics card sits in the panel.
  let placeCard: (CGRect) -> Void
  let openLibrary: () -> Void
  let openGallery: () -> Void
  let openSettings: () -> Void
  let setUpBackend: () -> Void

  var body: some View {
    header
    if let line = summary.uploadingLine {
      Button {
        panel.dismiss()
        Task { await app.showDropZoneFromMenuBar() }
      } label: {
        HStack {
          Text("\(line) · Show Drop Zone")
          Image(systemName: "chevron.right").imageScale(.small)
        }
        .pinaxSecondary()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    if summary.isFirstRun {
      firstRun
    } else {
      if let clipboard = panel.clipboard, summary.clipboard != nil {
        ClipboardCard(image: clipboard) {
          Task { await app.uploadFromClipboard() }
        }
      }
      RecentGrid(app: app, panel: panel, uploads: summary.recent)
      if let library {
        MenuBarStatsCard(library: library, unit: preferences.menuBarChartUnit, place: placeCard,
          open: openLibrary)
      }
    }
    Divider().padding(.horizontal, DesignMetrics.menuBarLibrary.footerDividerInset)
    MenuBarFooter(
      app: app, preferences: preferences, summary: summary, dismissPanel: panel.dismiss)
  }

  private var header: some View {
    HStack(spacing: DesignMetrics.menuBarLibrary.headerSpacing) {
      Text("Pinax").pinaxBody().bold()
      if summary.isFirstRun {
        Text("No backend").pinaxSecondary().foregroundStyle(.secondary)
      } else {
        ProjectMenu(app: app, preferences: preferences)
      }
      Spacer()
      Button(action: openGallery) { Image(systemName: "photo.on.rectangle") }
        .help("Open Gallery")
        .accessibilityLabel("Open Gallery")
        .disabled(app.gallery == nil)
      Button(action: openSettings) { Image(systemName: "gearshape") }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
    .buttonStyle(DropZoneIconButtonStyle())
    .padding(.horizontal, DesignMetrics.menuBarLibrary.headerInset)
  }

  private var firstRun: some View {
    VStack(spacing: 8) {
      Text("Connect a bucket to start").pinaxBody().bold()
      Text("Pinax uploads your images to a bucket you own.")
        .pinaxSecondary().foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Set Up Backend…", action: setUpBackend)
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity)
    .padding(16)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        .foregroundStyle(.secondary.opacity(0.5)))
  }
}

/// Hands the panel's window to `found` once the view is in one.
private struct PanelWindowReader: NSViewRepresentable {
  let found: @MainActor (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView { Probe(found: found) }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class Probe: NSView {
    let found: @MainActor (NSWindow) -> Void

    init(found: @escaping @MainActor (NSWindow) -> Void) {
      self.found = found
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { found(window) }
    }
  }
}

/// Pinax's current project — the same state as the Drop Zone's picker
/// (`PreferencesStore.currentProjectSlug`) — as the canvas's filled pill.
struct ProjectMenu: View {
  @ObservedObject var app: PinaxAppModel
  @ObservedObject var preferences: PreferencesStore

  private var name: String {
    preferences.currentProjectSlug == nil
      ? "All Projects"
      : dropZoneProjectName(preferences.currentProjectSlug, in: app.projects)
  }

  var body: some View {
    Menu {
      Toggle(
        "All Projects",
        isOn: Binding(
          get: { preferences.currentProjectSlug == nil },
          set: { _ in preferences.currentProjectSlug = nil }))
      ForEach(app.projects, id: \.slug) { project in
        Toggle(
          project.name,
          isOn: Binding(
            get: { preferences.currentProjectSlug == project.slug },
            set: { _ in preferences.currentProjectSlug = project.slug }))
      }
    } label: {
      HStack(spacing: DesignMetrics.menuBarLibrary.pillSpacing) {
        Image(systemName: "folder").imageScale(.small).foregroundStyle(.primary)
        Text(name).lineLimit(1).foregroundStyle(.primary)
        Image(systemName: "chevron.down").imageScale(.small)
      }
      .pinaxSecondary()
      .padding(.horizontal, DesignMetrics.menuBarLibrary.pillHorizontalPadding)
      .frame(height: DesignMetrics.menuBarLibrary.pillHeight)
      .background(
        MenuBarPalette.track,
        in: RoundedRectangle(cornerRadius: DesignMetrics.menuBarLibrary.pillRadius))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
    .accessibilityLabel("Project \(name)")
  }
}

// MARK: - Clipboard card

private struct ClipboardCard: View {
  let image: ClipboardImage
  let upload: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if let thumbnail = image.thumbnail {
          Image(decorative: thumbnail, scale: 2).resizable().scaledToFill()
        } else {
          Image(systemName: "photo").foregroundStyle(.secondary)
        }
      }
      .frame(width: 44, height: 44)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 2) {
        Text("Image on clipboard").pinaxBody().bold()
        Text(image.info.detailLine).pinaxSecondary().foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Button("Upload", action: upload).buttonStyle(.borderedProminent)
    }
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }
}

// MARK: - RECENT

private struct RecentGrid: View {
  @ObservedObject var app: PinaxAppModel
  @ObservedObject var panel: MenuBarPanelModel
  let uploads: [RecentUpload]

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("RECENT").pinaxSecondary().foregroundStyle(.secondary).fontWeight(.semibold)
      if uploads.isEmpty {
        Text("No uploads yet").pinaxSecondary().foregroundStyle(.secondary)
      } else {
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(uploads) { upload in
            RecentCell(app: app, panel: panel, upload: upload)
          }
        }
        // The line under the grid: which file the last copy took.
        Text(panel.copied?.filename ?? " ")
          .pinaxSecondary().foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
    }
  }
}

private struct RecentCell: View {
  @ObservedObject var app: PinaxAppModel
  @ObservedObject var panel: MenuBarPanelModel
  let upload: RecentUpload
  @State private var image: CGImage?
  @State private var hovered = false

  var body: some View {
    Button {
      panel.copyLink(upload)
    } label: {
      Color.clear
        .aspectRatio(1, contentMode: .fit)
        .overlay {
          if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
          } else {
            Rectangle().fill(.quaternary)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
          if hovered { actionBar }
        }
        .overlay {
          if let copied = panel.copied, copied.uploadID == upload.id {
            Text(copied.message)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.white)
              .multilineTextAlignment(.center)
              .padding(4)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
          }
        }
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(upload.filename)
    .accessibilityLabel("Copy link to \(upload.filename)")
    .task(id: upload.sha256) { await loadThumbnail() }
  }

  /// The drop zone cards' three buttons, small and over the image.
  private var actionBar: some View {
    HStack(spacing: 0) {
      actionButton(
        DropZoneCardActionStyle.linkSymbol, DropZoneCardActionStyle.linkHelp
      ) { panel.copyLink(upload) }
      actionButton(
        DropZoneCardActionStyle.markdownSymbol, DropZoneCardActionStyle.markdownHelp
      ) { panel.copyMarkdown(upload) }
      actionButton(
        DropZoneCardActionStyle.quickLookSymbol, DropZoneCardActionStyle.quickLookHelp
      ) { app.quickLookRecent(upload.id) }
    }
    .frame(maxWidth: .infinity)
    .background(.black.opacity(0.55))
  }

  private func actionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) { Image(systemName: symbol).imageScale(.small) }
      .buttonStyle(DropZoneIconButtonStyle(width: 22, height: 20, onImage: true))
      .help(help)
      .accessibilityLabel(help)
  }

  private func loadThumbnail() async {
    guard let cache = app.gallery?.thumbnails, !upload.sha256.isEmpty,
      let url = URL(string: upload.url)
    else { return }
    let request = ThumbnailRequest(sha256: upload.sha256, sourceURL: url)
    if let cached = await cache.cachedImage(for: request) {
      image = cached
    } else {
      image = try? await cache.image(for: request)
    }
  }
}

/// The rows under the divider, in the order `MenuBarSummary.footer` gives:
/// whole-width rows like menu items, the switch on the right.
struct MenuBarFooter: View {
  @ObservedObject var app: PinaxAppModel
  @ObservedObject var preferences: PreferencesStore
  let summary: MenuBarSummary
  /// Closes the menu bar panel before Show Drop Zone brings the zone up.
  var dismissPanel: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
      if summary.footer.contains(.dropZoneWhileDragging) {
        HStack {
          Text("Drop Zone While Dragging")
          Spacer()
          Toggle("Drop Zone While Dragging", isOn: $preferences.isDropZoneEnabled)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(MenuBarPalette.accentFill)
        }
        .menuBarFooterRow()
      }
      if summary.footer.contains(.showDropZone) {
        Button {
          dismissPanel()
          Task { await app.showDropZoneFromMenuBar() }
        } label: {
          Text("Show Drop Zone").menuBarFooterRow()
        }
        .disabled(app.dropZone == nil)
      }
      if summary.footer.contains(.divider) {
        Divider().padding(DesignMetrics.menuBarLibrary.footerDividerInset)
      }
      Button {
        NSApp.terminate(nil)
      } label: {
        HStack {
          Text("Quit Pinax")
          Spacer()
          Text("⌘Q").foregroundStyle(.secondary)
        }
        .menuBarFooterRow()
      }
      .keyboardShortcut("q")
    }
    .pinaxBody()
    .buttonStyle(.plain)
  }
}

extension View {
  /// One footer row: the canvas's 26 pt, inset 6, as wide as the panel.
  fileprivate func menuBarFooterRow() -> some View {
    padding(.horizontal, DesignMetrics.menuBarLibrary.footerRowPadding)
      .frame(
        maxWidth: .infinity, minHeight: DesignMetrics.menuBarLibrary.footerRowHeight,
        alignment: .leading)
      .contentShape(Rectangle())
  }
}

/// A page at the panel's width and its own height, which it reports so
/// the panel can take it at once when the page comes in.
private struct PageFrame: ViewModifier {
  let page: PinaxMenuBarContent.Page
  @Binding var heights: [PinaxMenuBarContent.Page: CGFloat]
  /// The Library page's height can first arrive while the platter is
  /// still growing toward it, so it retargets the spring; the home page's
  /// is only ever taken as it is.
  let animation: Animation?

  func body(content: Content) -> some View {
    content
      .padding(DesignMetrics.menuBarLibrary.panelPadding)
      .frame(width: PinaxMenuBarContent.width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
        withAnimation(animation) { heights[page] = height }
      }
  }
}

/// The Library page seen only inside the platter: as the platter grows
/// from the card to the panel the page unrolls with it, and rolls back up
/// into the card on the way home.
private struct MenuBarReveal: ViewModifier {
  let frame: CGRect

  func body(content: Content) -> some View {
    content.mask(alignment: .topLeading) {
      MenuBarPalette.cardShape
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }
  }
}
