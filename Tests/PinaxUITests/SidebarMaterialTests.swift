import AppKit
import SwiftUI
@testable import PinaxUI
import Testing

/// Both side columns draw the translucent, behind-window sidebar
/// material: the navigation sidebar gets it from
/// the system, the inspector from `SidebarMaterialBackground`. Within-window
/// `.regularMaterial` over the opaque window reads as plain grey, so the
/// blending mode is what is asserted.
@MainActor
@Suite(.serialized) struct SidebarMaterialTests {
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

  /// Behind-window sidebar effect views under `root`, as window frames.
  private func sidebarGlass(in root: NSView) -> [CGRect] {
    var stack: [NSView] = [root]
    var frames: [CGRect] = []
    while let view = stack.popLast() {
      if let effect = view as? NSVisualEffectView, effect.material == .sidebar,
        effect.blendingMode == .behindWindow, effect.state == .followsWindowActiveState
      {
        frames.append(effect.convert(effect.bounds, to: nil))
      }
      stack.append(contentsOf: view.subviews)
    }
    return frames
  }

  private func splitItems(in window: NSWindow) -> [NSSplitViewItem] {
    var stack: [NSView] = window.contentView.map { [$0] } ?? []
    var items: [NSSplitViewItem] = []
    while let view = stack.popLast() {
      if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
        items += controller.splitViewItems
      }
      stack.append(contentsOf: view.subviews)
    }
    return items
  }

  @Test("The sidebar and the docked inspector both draw the behind-window sidebar material")
  func bothSideColumnsAreTranslucent() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbs"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    model.isSidebarVisible = true
    model.showsInspector = true

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1300, height: 720),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(0.8)

    let items = splitItems(in: window)
    let sidebar = try #require(items.first { $0.behavior == .sidebar && !$0.isCollapsed })
    let inspector = try #require(items.first { $0.behavior == .inspector && !$0.isCollapsed })
    for (name, item) in [("sidebar", sidebar), ("inspector", inspector)] {
      let pane = item.viewController.view
      let column = pane.convert(pane.bounds, to: nil)
      // The system's sidebar effect view wraps the pane rather than sitting
      // inside it, so search from the split item's wrapper.
      let glass = sidebarGlass(in: pane.superview?.superview ?? pane)
      #expect(
        glass.contains { $0.minX <= column.minX && $0.maxX >= column.maxX && $0.height >= column.height - 1 },
        "\(name) column \(column): glass \(glass)")
    }
  }
}
