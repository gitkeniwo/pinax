import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// The metadata scrim's three settings and their
/// migration, the grid's one hovered cell and its instant scrim, and the
/// configured numbers of the scrim, caption, ring and jump bar.
@MainActor
@Suite(.serialized) struct GridScrimTests {
  typealias Visibility = GridOverlayOptions.MetadataVisibility

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-gui6-grid-\(UUID().uuidString)"))
  }

  // MARK: - 1. Migration

  @Test("The visibility key migrates from the old switch: missing, on, off; unknown reads as the default")
  func migration() throws {
    // Missing both: the default, hover or selection.
    let fresh = try makeDefaults()
    #expect(PreferencesStore(defaults: fresh).gridOverlays.metadataVisibility == .hoverOrSelected)

    let on = try makeDefaults()
    on.set(true, forKey: "pinax.grid.metadata.enabled")
    #expect(PreferencesStore(defaults: on).gridOverlays.metadataVisibility == .hoverOrSelected)

    let off = try makeDefaults()
    off.set(false, forKey: "pinax.grid.metadata.enabled")
    #expect(PreferencesStore(defaults: off).gridOverlays.metadataVisibility == .off)

    // The new key wins over the old one; an unknown value is the default.
    let unknown = try makeDefaults()
    unknown.set(false, forKey: "pinax.grid.metadata.enabled")
    unknown.set("sometimes", forKey: "pinax.grid.metadata.visibility")
    #expect(PreferencesStore(defaults: unknown).gridOverlays.metadataVisibility == .hoverOrSelected)

    let newWins = try makeDefaults()
    newWins.set(false, forKey: "pinax.grid.metadata.enabled")
    newWins.set("always", forKey: "pinax.grid.metadata.visibility")
    #expect(PreferencesStore(defaults: newWins).gridOverlays.metadataVisibility == .always)
  }

  @Test("Each visibility round-trips under the new key; the old key is never written")
  func roundTrip() throws {
    for visibility in Visibility.allCases {
      let defaults = try makeDefaults()
      let store = PreferencesStore(defaults: defaults)
      // Through a second field first, so the default value is written too.
      store.gridOverlays.showsFilename = false
      store.gridOverlays.metadataVisibility = visibility
      #expect(defaults.string(forKey: "pinax.grid.metadata.visibility") == visibility.rawValue)
      #expect(defaults.object(forKey: "pinax.grid.metadata.enabled") == nil, "\(visibility)")
      #expect(PreferencesStore(defaults: defaults).gridOverlays.metadataVisibility == visibility)
    }
    #expect(Visibility.allCases.map(\.rawValue) == ["always", "hoverOrSelected", "off"])
    #expect(GridOverlayOptions().metadataVisibility == .hoverOrSelected)
  }

  // MARK: - 2. Visibility at rest, hovered, selected

  @Test("Three settings × rest, hover, selection: who draws the scrim")
  func visibilityMatrix() {
    let hover = GridHoverState()
    func shown(_ visibility: Visibility, hovered: Bool, selected: Bool) -> Bool {
      if hovered {
        hover.pointer(at: CGPoint(x: 5, y: 5), in: [7: CGRect(x: 0, y: 0, width: 10, height: 10)])
      } else {
        hover.clear()
      }
      return MetadataScrim(
        id: 7, visibility: visibility, isSelected: selected, hover: hover,
        full: Text("553 kB · JPEG"), narrow: Text("553 kB")
      ).isShown
    }
    let states = [(false, false), (true, false), (false, true)]  // rest, hover, selected
    #expect(states.map { shown(.always, hovered: $0.0, selected: $0.1) } == [true, true, true])
    #expect(states.map { shown(.hoverOrSelected, hovered: $0.0, selected: $0.1) } == [false, true, true])
    #expect(states.map { shown(.off, hovered: $0.0, selected: $0.1) } == [false, false, false])
    // No hover state at all (the frozen copy, a report grid): at rest.
    #expect(
      !MetadataScrim(
        id: 7, visibility: .hoverOrSelected, isSelected: false, hover: nil,
        full: Text("x"), narrow: nil
      ).isShown)
  }

  @Test("The grid holds one hovered cell, the one whose frame is under the pointer")
  func oneHoveredCell() {
    let hover = GridHoverState()
    let frames: [GalleryModel.Row.ID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 10, height: 10),
      2: CGRect(x: 20, y: 0, width: 10, height: 10),
    ]
    hover.pointer(at: CGPoint(x: 5, y: 5), in: frames)
    #expect(hover.hoveredID == 1)
    hover.pointer(at: CGPoint(x: 25, y: 5), in: frames)  // moving on replaces it
    #expect(hover.hoveredID == 2)
    hover.pointer(at: CGPoint(x: 15, y: 5), in: frames)  // the gap between cells
    #expect(hover.hoveredID == nil)
    hover.pointer(at: CGPoint(x: 25, y: 5), in: frames)
    hover.clear()  // the pointer left the grid, or the columns changed
    #expect(hover.hoveredID == nil)
    #expect(GridHoverState.instant.disablesAnimations)
  }

  // MARK: - 3. No animation

  private final class CellHarnessState: ObservableObject {
    @Published var selected = false
  }

  private struct CellHarness: View {
    let row: GalleryModel.Row
    let cache: ThumbnailCache
    let hover: GridHoverState
    @ObservedObject var state: CellHarnessState

    var body: some View {
      AssetGridCell(
        row: row, cache: cache, overlays: GridOverlayOptions(),
        isSelected: state.selected, hover: hover)
        .frame(width: 160)
    }
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  @Test("Hovering or selecting inside withAnimation reaches the cell's scrim with no animation")
  func scrimChangesCarryNoAnimation() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T13:00:00Z")
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-gui6-grid-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await model.loadInitialData()
    let row = try #require(model.rows.first)

    let hover = GridHoverState()
    let state = CellHarnessState()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: CellHarness(row: row, cache: model.thumbnails, hover: hover, state: state))
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      MetadataScrim.transactionProbe = nil
    }
    await spin(0.3)

    var seen: [(animated: Bool, disabled: Bool)] = []
    MetadataScrim.transactionProbe = { transaction in
      seen.append((transaction.animation != nil, transaction.disablesAnimations))
    }
    func check(_ what: String, _ change: () -> Void) async {
      seen = []
      withAnimation(.linear(duration: 1)) { change() }
      await spin(0.3)
      #expect(!seen.isEmpty, "\(what): the scrim was never updated")
      #expect(seen.allSatisfy { !$0.animated && $0.disabled }, "\(what): \(seen)")
    }
    let frames = [row.id: CGRect(x: 0, y: 0, width: 160, height: 160)]
    await check("hover in") { hover.pointer(at: CGPoint(x: 80, y: 80), in: frames) }
    await check("hover out") { hover.pointer(at: CGPoint(x: -5, y: 80), in: frames) }
    await check("select") { state.selected = true }
    await check("deselect") { state.selected = false }
  }

  // MARK: - 4. Configured numbers

  @Test("Scrim, caption, ring and jump-bar numbers are the configured ones")
  func configuredNumbers() {
    // The scrim: 5 pt inset, 6 × 2 padding, radius 5, 55 % opacity.
    #expect(DesignMetrics.scrim.inset == 5)
    #expect(DesignMetrics.scrim.horizontalPadding == 6)
    #expect(DesignMetrics.scrim.verticalPadding == 2)
    #expect(DesignMetrics.scrim.radius == 5)
    #expect(DesignMetrics.scrim.opacity == 0.55)
    // The selection ring: a 2.5 pt accent outline, offset 2 pt; its corner
    // formula is the grid's usual one.
    #expect(DesignMetrics.selection.ringWidth == 2.5)
    #expect(DesignMetrics.selection.ringGap == 2)
    #expect(DesignMetrics.selection.ringRadius == 10.5)
    // The caption: the date plate, the 13 × 13 source square.
    #expect(DesignMetrics.gridCaption.datePlatePadding == 5)
    #expect(DesignMetrics.colorSquare.caption == 13)
    #expect(DesignMetrics.colorSquare.captionRadius == 3.5)
    // The jump bar.
    #expect(DesignMetrics.jumpBar.currentVerticalPadding == 1)
    #expect(DesignMetrics.jumpBar.currentHorizontalPadding == 7)
    #expect(DesignMetrics.jumpBar.currentRadius == 5)
    #expect(DesignMetrics.jumpBar.toggleHeight == 20)
    #expect(DesignMetrics.jumpBar.toggleHorizontalPadding == 6)
    #expect(DesignMetrics.jumpBar.toggleRadius == 5)
    // F's default content: "553 kB · JPEG".
    #expect(GridOverlayOptions().leadingCorner == .fileSize)
    #expect(GridOverlayOptions().trailingCorner == .format)
    #expect(NSImage(systemSymbolName: JumpBar.currentIndicator, accessibilityDescription: nil) != nil)
  }

  @Test("Only the segment naming the place shown is the current one")
  func currentSegment() {
    let components = JumpBar.components(
      selection: .all, navigator: .library, projects: [], tags: [], months: [],
      folderChildren: [:], catalogRoots: [FixtureBackend.root], selectedName: "IMG_4103.jpeg")
    let current = components.filter { JumpBar.isCurrent($0, selection: .all) }
    #expect(current.map(\.label) == ["All Assets"], "\(components.map(\.label))")
    // Storage ▸ blog ▸ 202603: blog is a menu too, but only the last level
    // names the place shown.
    let folderChildren: KeyPrefixChildren = [
      .r2(nil): [("blog", 3, true), ("notes", 1, true)],
      .r2("blog"): [("202603", 2, true), ("202604", 1, true)],
    ]
    let nested = JumpBar.components(
      selection: .keyPrefix("blog/202603"), navigator: .library, projects: [], tags: [],
      months: [], folderChildren: folderChildren, catalogRoots: [FixtureBackend.root], selectedName: nil)
    #expect(nested.map(\.label) == ["Storage", "r2", "blog", "202603"])
    #expect(
      nested.map { JumpBar.isCurrent($0, selection: .keyPrefix("blog/202603")) }
        == [false, false, false, true])
  }

  @Test("Source tints are gruvbox: PicGo orange, Bucket aqua")
  func sourceTints() {
    #expect(SourceTint.picgo.color == PinaxPalette.orange)
    #expect(SourceTint.bucket.color == PinaxPalette.aqua)
  }
}
