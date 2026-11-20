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
  @StateObject private var pager: MenuBarPager
  /// Where the statistics card sits on the home page, and the home page's
  /// height, in the panel's own space: the card is where the platter
  /// starts, the panel (as tall as the home page on both pages) where it
  /// ends (a Control Center module opening into its detail).
  @State private var cardFrame = CGRect.zero
  @State private var homeHeight: CGFloat?
  /// The Library page's contents when given; otherwise read from the app.
  private let fixedLibrary: MenuBarLibrary?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  /// The panel's coordinate space: the card reports its frame in it.
  static let space = "pinaxMenuBarPanel"

  public init(app: PinaxAppModel) {
    self.init(app: app, pager: MenuBarPager())
  }

  /// Takes the page from `pager`, so a test can turn the page as the card
  /// and Back do, and the Library page's contents from `library` when
  /// given.
  init(
    app: PinaxAppModel, pager: @autoclosure @escaping () -> MenuBarPager,
    library: MenuBarLibrary? = nil
  ) {
    self.app = app
    self.preferences = app.preferences
    self._pager = StateObject(wrappedValue: pager())
    self.fixedLibrary = library
  }

  public var body: some View {
    let summary = MenuBarSummary(app: app, clipboard: panel.clipboard?.info)
    let library = summary.isFirstRun ? nil : fixedLibrary ?? MenuBarLibrary(app: app)
    // The Library page lays out in the home page's height, so it waits
    // for that (the panel's first frame, before anything can be clicked).
    let canTurn = library != nil && homeHeight != nil
    // The one value the page turn animates: 0 the home page, 1 the
    // Library page. Everything that moves is worked out from it.
    let progress: CGFloat = pager.page == .library && canTurn ? 1 : 0
    let bounds = CGRect(x: 0, y: 0, width: Self.width, height: homeHeight ?? 0)
    // With Reduce Motion the platter and the page's outline jump straight
    // to where the turn ends; only the fades run.
    let still: CGFloat? = reduceMotion ? progress : nil
    ZStack(alignment: .topLeading) {
      // One platter for both pages: the card's on the home page, the whole
      // panel on the Library page.
      if library != nil {
        Color.clear
          .modifier(
            MenuBarPlatter(progress: progress, card: cardFrame, panel: bounds))
          .transaction { if reduceMotion { $0.animation = nil } }
          .accessibilityHidden(true)
      }
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
      .modifier(HomeFrame(height: $homeHeight))
      .modifier(
        MenuBarHomeMorph(
          progress: progress, card: cardFrame, panel: bounds, reduceMotion: reduceMotion))
      if let library, canTurn {
        MenuBarLibraryPage(
          app: app, preferences: preferences, panel: panel, library: library,
          back: { go(.home) }, openGallery: openGallery
        )
        .padding(DesignMetrics.menuBarLibrary.panelPadding)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(
          MenuBarLibraryMorph(progress: progress, still: still, card: cardFrame, panel: bounds))
      }
    }
    // Both pages, and the panel, are as tall as the home page, before,
    // during and after a turn: the window never resizes for one (it cannot
    // animate its own resize here).
    .frame(width: Self.width, height: homeHeight, alignment: .topLeading)
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

  /// One spring each way; with Reduce Motion, a cross-fade.
  private func animation(to target: Page) -> Animation {
    let metrics = DesignMetrics.menuBarLibrary.self
    if reduceMotion { return .easeInOut(duration: metrics.fadeDuration) }
    return target == .library
      ? .spring(response: metrics.expandResponse, dampingFraction: metrics.expandDamping)
      : .spring(response: metrics.collapseResponse, dampingFraction: metrics.collapseDamping)
  }

  /// Turns the page. A turn mid-way simply retargets the spring, which
  /// turns back from wherever it is.
  private func go(_ target: Page) {
    withAnimation(animation(to: target)) { pager.page = target }
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

/// Which page the panel shows.
@MainActor final class MenuBarPager: ObservableObject {
  @Published var page = PinaxMenuBarContent.Page.home
}

/// The home page at the panel's width and its own height, which it
/// reports: the panel takes it, on both pages. The home page is also the
/// space the card reports its frame in, so the page shrinking during a
/// turn does not move where the platter starts.
private struct HomeFrame: ViewModifier {
  @Binding var height: CGFloat?

  func body(content: Content) -> some View {
    content
      .padding(DesignMetrics.menuBarLibrary.panelPadding)
      .frame(width: PinaxMenuBarContent.width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .coordinateSpace(name: PinaxMenuBarContent.space)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { value in
        withAnimation(nil) { height = value }
      }
  }
}

// MARK: - The page turn

/// Everything the page turn moves, worked out from one progress: 0 is the
/// home page, 1 the Library page. A spring can carry the progress a little
/// past either end; fades and the shrink stop at their ends, the platter's
/// frame follows it past them (that is the bounce).
enum MenuBarMorph {
  struct Values: Equatable {
    /// The platter: its frame in the panel, its corner, its outline.
    var platter: CGRect
    var platterRadius: CGFloat
    var platterBorder: Double
    /// The card's three numbers, bars and ›.
    var cardContent: Double
    /// The rest of the home page, and its scale about the panel's centre.
    var home: Double
    var homeScale: CGFloat
    var library: Double
    /// Which page takes clicks: one, never both.
    var homeTakesClicks: Bool
    var libraryTakesClicks: Bool
  }

  /// 0 below `from`, 1 above `to`, a smoothstep between.
  static func window(_ progress: Double, from: Double, to: Double) -> Double {
    let t = min(1, max(0, (progress - from) / (to - from)))
    return t * t * (3 - 2 * t)
  }

  static func values(progress: CGFloat, card: CGRect, panel: CGRect) -> Values {
    let metrics = DesignMetrics.menuBarLibrary.self
    let p = Double(progress)
    let clamped = min(1, max(0, p))
    func mix(_ from: CGFloat, _ to: CGFloat, _ t: Double) -> CGFloat {
      from + (to - from) * CGFloat(t)
    }
    let platter = CGRect(
      x: mix(card.minX, panel.minX, p), y: mix(card.minY, panel.minY, p),
      width: mix(card.width, panel.width, p), height: mix(card.height, panel.height, p))
    return Values(
      platter: platter,
      platterRadius: mix(metrics.cardRadius, metrics.panelRadius, clamped),
      platterBorder: 1 - window(p, from: 0, to: metrics.borderFadeEnd),
      cardContent: 1 - window(p, from: 0, to: metrics.cardFadeEnd),
      home: 1 - window(p, from: 0, to: metrics.homeFadeEnd),
      homeScale: mix(1, metrics.homeShrunkScale, window(p, from: 0, to: metrics.homeScaleEnd)),
      library: window(p, from: metrics.libraryFadeStart, to: metrics.libraryFadeEnd),
      homeTakesClicks: clamped < 0.5,
      libraryTakesClicks: clamped >= 0.5)
  }
}

/// The platter: the card's fill and outline, from the card to the panel.
private struct MenuBarPlatter: ViewModifier, Animatable {
  var progress: CGFloat
  let card: CGRect
  let panel: CGRect

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let values = MenuBarMorph.values(progress: progress, card: card, panel: panel)
    let shape = RoundedRectangle(cornerRadius: values.platterRadius, style: .continuous)
    content
      .background(
        ZStack {
          shape.fill(MenuBarPalette.card)
          shape.strokeBorder(MenuBarPalette.cardBorder).opacity(values.platterBorder)
        })
      .frame(width: max(0, values.platter.width), height: max(0, values.platter.height))
      .offset(x: values.platter.minX, y: values.platter.minY)
  }
}

/// The home page leaving and coming back: it fades and shrinks a little
/// about the panel's centre, the card's contents fading first.
private struct MenuBarHomeMorph: ViewModifier, Animatable {
  var progress: CGFloat
  let card: CGRect
  let panel: CGRect
  let reduceMotion: Bool

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let values = MenuBarMorph.values(progress: progress, card: card, panel: panel)
    content
      .environment(\.menuBarCardFade, values.cardContent)
      .scaleEffect(reduceMotion ? 1 : values.homeScale, anchor: .center)
      .opacity(values.home)
      .allowsHitTesting(values.homeTakesClicks)
      .accessibilityHidden(!values.homeTakesClicks)
  }
}

/// The Library page seen only inside the platter, fading in as the
/// platter grows: it unrolls with it, and rolls back up into the card on
/// the way home. It never moves or scales.
private struct MenuBarLibraryMorph: ViewModifier, Animatable {
  var progress: CGFloat
  /// With Reduce Motion, where the platter already is (it does not move).
  let still: CGFloat?
  let card: CGRect
  let panel: CGRect

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let values = MenuBarMorph.values(progress: progress, card: card, panel: panel)
    let outline = still.map { MenuBarMorph.values(progress: $0, card: card, panel: panel) } ?? values
    content
      .mask(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: outline.platterRadius, style: .continuous)
          .frame(width: max(0, outline.platter.width), height: max(0, outline.platter.height))
          .offset(x: outline.platter.minX, y: outline.platter.minY)
      }
      .opacity(values.library)
      .allowsHitTesting(values.libraryTakesClicks)
      .accessibilityHidden(!values.libraryTakesClicks)
  }
}

extension EnvironmentValues {
  /// The statistics card's contents' opacity: they fade first as the card
  /// opens into the Library page.
  @Entry var menuBarCardFade: Double = 1
}
