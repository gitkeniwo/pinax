import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PinaxUI

/// The window's bars share ONE metrics source,
/// `ChromeMetrics` — height, padding, text style — so a later tweak to one
/// bar cannot drift from the others. The assertion is on rendered bitmaps,
/// not on the enum reading itself back: a bar that hardcodes its own
/// constant renders at that constant and this goes red.
@MainActor
@Suite struct ChromeMetricsTests {
  private func renderedHeight<V: View>(_ view: V, width: CGFloat = 700) -> Int? {
    let renderer = ImageRenderer(content: view.frame(width: width))
    renderer.proposedSize = ProposedViewSize(width: width, height: nil)
    return renderer.cgImage?.height
  }

  private func makeModel() throws -> (GalleryModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-metrics-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    return (model, directory)
  }

  @Test("The find strip's height is invariant across its content states")
  func findStripHeightIsInvariant() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    var heights = [renderedHeight(FindStrip(model: model))]

    // The clear button appears with text; the caveat + disabled controls
    // appear on a report surface; neither may change the row's height.
    model.searchText = "shot"
    heights.append(renderedHeight(FindStrip(model: model)))

    model.sidebarSelection = .orphans
    heights.append(renderedHeight(FindStrip(model: model)))

    model.searchCaseSensitive = true
    model.searchMatch = .ends
    heights.append(renderedHeight(FindStrip(model: model)))

    let expected = Int(ChromeMetrics.stripHeight)
    #expect(heights.allSatisfy { $0 == expected }, "heights: \(heights.map { $0 ?? -1 })")
    #expect(heights.compactMap { $0 }.count == heights.count, "every state produced a bitmap")
  }

  /// The sidebar's navigator row and the jump bar sit side by side under
  /// the toolbar; their bottom edges line up only if both render at the
  /// strip height, as in Xcode.
  @Test("The navigator switcher row renders at the jump bar's height")
  func navigatorRowMatchesJumpBar() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let expected = Int(ChromeMetrics.stripHeight)
    #expect(renderedHeight(JumpBar(model: model)) == expected)
    #expect(renderedHeight(SidebarNavigatorPicker(model: model), width: 260) == expected)
  }

  @Test("The bars agree: strip height shared by top chrome, bar height by the status bar")
  func barsShareTheMetricsSource() {
    // The contract itself, as readable facts: two heights (top chrome and
    // bottom bar) and one horizontal inset, defined exactly once.
    #expect(ChromeMetrics.stripHeight > ChromeMetrics.barHeight)
    #expect(ChromeMetrics.horizontalPadding > 0)
  }
}
