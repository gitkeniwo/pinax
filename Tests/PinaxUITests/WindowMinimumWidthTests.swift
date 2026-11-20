import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// The window's minimum width has
/// two layers. SwiftUI's layer — the one SwiftUI consults before it expands
/// a side column — follows the visible columns; the window's real floor of
/// 900 is a single AppKit constraint on the content view.
///
/// Measured before choosing the assertion (hosted window): a
/// `.frame(minWidth:)` on the hosted root is what SwiftUI writes to
/// `NSWindow.contentMinSize.width` (a 555 pt frame read back as 555 under
/// both `NSHostingView` and `NSHostingController` hosting), so that is the
/// value read here.
///
/// The model flags are set directly: they switch the columns without the
/// system's animation, which is all a minimum width needs. The animated
/// path (a real toolbar click) is measured in the running app instead —
/// unit tests synthesise no clicks.
@MainActor
@Suite(.serialized) struct WindowMinimumWidthTests {
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

  /// An empty catalog: no rows, so no thumbnail is ever fetched.
  private func makeModel() async throws -> (GalleryModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbs"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    return (model, directory)
  }

  private func host(_ model: GalleryModel, width: CGFloat) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.orderFront(nil)
    return window
  }

  private func show(_ model: GalleryModel, sidebar: Bool, inspector: Bool) async {
    model.isSidebarVisible = sidebar
    model.showsInspector = inspector
    await spin(0.5)
  }

  @Test("SwiftUI's minimum width follows the visible columns: 338 / 599 / 639 / 900")
  func swiftUIMinimumFollowsVisibleColumns() async throws {
    let (model, directory) = try await makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = host(model, width: 1400)
    defer { window.orderOut(nil) }
    await spin(0.5)

    var minimum: [String: CGFloat] = [:]
    for (sidebar, inspector) in [(false, false), (true, false), (false, true), (true, true)] {
      await show(model, sidebar: sidebar, inspector: inspector)
      minimum["\(sidebar)/\(inspector)"] = window.contentMinSize.width
    }
    #expect(minimum["false/false"] == 338)
    #expect(minimum["true/false"] == 599)
    #expect(minimum["false/true"] == 639)
    #expect(minimum["true/true"] == 900)

    // Opening any column from any state: the minimum before equals the
    // minimum after less that column's room (column plus its divider), the
    // condition SwiftUI checks to squeeze the centre column instead of
    // asking the window to grow.
    let sidebarRoom: CGFloat = 261
    let inspectorRoom: CGFloat = 301
    for inspector in [false, true] {
      let before = try #require(minimum["false/\(inspector)"])
      let after = try #require(minimum["true/\(inspector)"])
      #expect(before == after - sidebarRoom, "opening the sidebar, inspector \(inspector)")
    }
    for sidebar in [false, true] {
      let before = try #require(minimum["\(sidebar)/false"])
      let after = try #require(minimum["\(sidebar)/true"])
      #expect(before == after - inspectorRoom, "opening the inspector, sidebar \(sidebar)")
    }
  }

  @Test("With both side columns closed the window still cannot shrink below 900")
  func appKitConstraintHoldsTheWindowFloor() async throws {
    let (model, directory) = try await makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = host(model, width: 1100)
    defer { window.orderOut(nil) }
    await spin(0.5)
    for (sidebar, inspector) in [(true, true), (false, true), (true, false), (false, false)] {
      await show(model, sidebar: sidebar, inspector: inspector)
    }
    #expect(window.contentMinSize.width < 900)

    window.setContentSize(NSSize(width: 600, height: 720))
    await spin(0.5)
    #expect(window.frame.width == 900)

    let contentView = try #require(window.contentView)
    var stack: [NSView] = [contentView]
    var floors: [NSLayoutConstraint] = []
    var installers: [WindowMinimumWidthMount.Installer] = []
    while let view = stack.popLast() {
      floors += view.constraints.filter { $0.identifier == WindowMinimumWidthMount.identifier }
      if let installer = view as? WindowMinimumWidthMount.Installer { installers.append(installer) }
      stack.append(contentsOf: view.subviews)
    }
    // A model publish does not re-run the installer in this window
    // (measured: an installer without its lookup still left one constraint
    // here), but a re-attach or an update pass does; run it again directly.
    #expect(installers.count == 1)
    installers.forEach { $0.install(); $0.install() }
    #expect(contentView.constraints.filter { $0.identifier == WindowMinimumWidthMount.identifier }.count == 1)
    #expect(floors.count == 1)
    let floor = try #require(floors.first)
    #expect(floor.isActive)
    #expect(floor.firstItem === contentView)
    #expect(floor.firstAttribute == .width)
    #expect(floor.relation == .greaterThanOrEqual)
    #expect(floor.secondItem == nil)
    #expect(floor.constant == 900)
  }
}
