import AppKit
import CatalogCore
import Foundation
import SwiftUI
@testable import PinaxUI
import Testing

/// Section headers keep the system's fold triangle
/// off, and their controls end where the rows' count capsules end.
@MainActor
@Suite struct SidebarSectionHeaderTests {
  @Test("The system never folds a section; the header keeps a measured trailing inset")
  func configuration() {
    #expect(SidebarSectionHeader.systemFoldingEnabled == false)
    #expect(SidebarSectionHeader.trailingInset == 12.5)
  }

  private func hostedOutline(
    _ navigator: SidebarNavigator
  ) async throws -> (NSWindow, NSOutlineView, URL) {
    let (database, directory) = try makeUITestDatabase()
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-header-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await model.loadInitialData()
    model.navigator = navigator
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    var stack: [NSView] = [try #require(window.contentView)]
    while let next = stack.popLast() {
      if let outline = next as? NSOutlineView { return (window, outline, directory) }
      stack.append(contentsOf: next.subviews)
    }
    throw URLError(.cannotFindHost)
  }

  /// The right edge, in outline coordinates, of the drawn leaves under `view`.
  private func rightEdges(under view: NSView, in outline: NSOutlineView) -> [CGFloat] {
    var edges: [CGFloat] = []
    var stack = [view]
    while let next = stack.popLast() {
      // Small drawn leaves only: the full-width separator and plate views
      // would end every row on the sidebar's own edge.
      let frame = outline.convert(next.bounds, from: next)
      if next.subviews.isEmpty, frame.width <= 40 { edges.append(frame.maxX) }
      stack.append(contentsOf: next.subviews)
    }
    return edges
  }

  @Test("Every navigator's header holds no AppKit disclosure button; Projects' `+` ends on the capsules' edge")
  func headerControls() async throws {
    for navigator in SidebarNavigator.allCases {
      let (window, outline, directory) = try await hostedOutline(navigator)
      defer {
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
      }
      var capsuleEdge: CGFloat?
      var plusEdge: CGFloat?
      for row in 0..<outline.numberOfRows {
        guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) else { continue }
        var stack: [NSView] = [rowView]
        var isHeader = false
        var leaves: [NSView] = []
        while let next = stack.popLast() {
          if String(describing: type(of: next)).contains("HeaderView") { isHeader = true }
          if next.subviews.isEmpty { leaves.append(next) }
          stack.append(contentsOf: next.subviews)
        }
        if isHeader {
          #expect(
            !stack.isEmpty || leaves.allSatisfy { !($0 is NSButton) },
            "\(navigator): a button in header row \(row)")
        }
        if isHeader {
          if navigator == .collections, row == 0 {
            plusEdge = rightEdges(under: rowView, in: outline).max()
          }
        } else if capsuleEdge == nil {
          capsuleEdge = rightEdges(under: rowView, in: outline).max()
        }
      }
      if navigator == .collections {
        let plus = try #require(plusEdge, "no `+` on the Projects header")
        let capsule = try #require(capsuleEdge, "no row under it")
        #expect(abs(plus - capsule) <= 1.5, "`+` ends at \(plus), capsules at \(capsule), outline \(outline.frame.width)")
      }
    }
  }
}
