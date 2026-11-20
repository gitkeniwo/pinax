import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// The surface that lists references, not assets — Externals — shows no
/// asset selection (Usage lists the library's own rows, and shows it): no jump-bar
/// asset segment, an empty status-bar left side, "No Selection" in the
/// inspector. The selection stays in the model and comes back with All
/// Assets. One pure function decides it; the three views are read through
/// their own bodies.
@MainActor
@Suite(.serialized) struct SurfaceSelectionTests {
  @Test("Only the reference surfaces and Overview hide the asset selection")
  func hidingSurfaces() {
    let shown: [SidebarSelection] = [
      .all, .recent, .favorites, .archived, .orphans, .usage, .project("blog"), .tag("x"),
      .year("2026"), .month("2026-08"), .keyPrefix("blog"), .label(.red),
    ]
    for selection in shown {
      #expect(GalleryModel.showsAssetSelection(on: selection), "\(selection)")
    }
    #expect(!GalleryModel.showsAssetSelection(on: .externals))
    // Overview draws no assets.
    #expect(!GalleryModel.showsAssetSelection(on: .overview))
  }

  /// The jump bar's last segment, as its body declares it.
  private func jumpBarLabels(_ model: GalleryModel) -> [String] {
    (firstView(in: JumpBar(model: model).body, typePrefix: "ForEach<Array<Component>")
      as? JumpBarComponentsForEach)?.labels() ?? []
  }

  /// Externals' column is its own: its empty state counts. The state is `InspectorEmptyState`; `inspectorEmptyKind` says
  /// which one.
  private func inspectorSaysNoSelection(_ model: GalleryModel) -> Bool {
    inspectorEmptyKind(model) != nil
  }

  private func inspectorEmptyKind(_ model: GalleryModel) -> EmptyStateKind? {
    let body = AssetInspectorView(model: model).body
    if let externals = collectViews(body, as: ExternalInspector.self).first {
      return collectViews(externals.body, as: InspectorEmptyState.self).first?.kind
    }
    return collectViews(body, as: InspectorEmptyState.self).first?.kind
  }

  private func settle(until condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("Usage and Externals show no asset selection; All Assets shows it again")
  func referenceSurfacesHideTheSelection() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<4 {
      try seedAsset(
        database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z",
        origFilename: "photo-\(index).png")
    }
    try seedLiveUsage(database, projectSlug: "blog", sha256: String(format: "%064x", 2), count: 1)
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await model.loadInitialData()

    // Not the first row: a surface that selected its own first row would
    // look the same otherwise.
    let picked = model.rows[2]
    #expect(picked.item.asset.originalFilename == "photo-1.png")
    model.select(picked, mode: .replace)
    try await settle { model.selectedDetails != nil }

    func expectShown(_ note: Comment) {
      #expect(jumpBarLabels(model).last == "photo-1.png", note)
      #expect(GalleryStatusBar(model: model).selectionSummary == "1 selected · 1 kB", note)
      #expect(!inspectorSaysNoSelection(model), note)
    }
    expectShown("All Assets")

    for surface: SidebarSelection in [.externals, .overview] {
      model.select(surface, in: SidebarModel.navigator(for: surface))
      await model.reload()
      #expect(model.sidebarSelection == surface)
      #expect(!jumpBarLabels(model).contains("photo-1.png"), "\(surface): jump bar")
      #expect(GalleryStatusBar(model: model).selectionSummary == nil, "\(surface): status bar")
      // Overview has nothing to inspect; Externals keeps its own words.
      #expect(
        inspectorEmptyKind(model) == (surface == .overview ? .nothingToInspect : .noReferenceSelected),
        "\(surface): inspector")
      #expect(model.selectedIDs == [picked.id], "\(surface): the model keeps the selection")
    }

    model.select(.all, in: .library)
    await model.reload()
    try await settle { model.selectedDetails != nil }
    expectShown("back on All Assets")

    // Orphans lists assets, so its own selection shows in all
    // three. Not its first candidate, and not photo-1 (in blog's scan, so
    // not an orphan) still held from All Assets.
    model.select(.orphans, in: SidebarModel.navigator(for: .orphans))
    await model.reload()
    let candidates = try #require(model.orphanReport).assets.map(GalleryModel.Row.init)
    #expect(candidates.count == 3)
    let orphan = candidates[1]
    let orphanName = try #require(orphan.item.asset.originalFilename)
    #expect(orphanName != "photo-1.png" && orphanName != candidates[0].item.asset.originalFilename)
    model.select(orphan, mode: .replace)
    try await settle { model.selectedDetails?.item.asset.originalFilename == orphanName }
    #expect(jumpBarLabels(model).last == orphanName, "Orphans: jump bar")
    #expect(GalleryStatusBar(model: model).selectionSummary == "1 selected · 1 kB", "Orphans: status bar")
    #expect(!inspectorSaysNoSelection(model), "Orphans: inspector")
  }
}

private protocol JumpBarComponentsForEach { func labels() -> [String] }
extension ForEach: JumpBarComponentsForEach where Data == [JumpBar.Component] {
  fileprivate func labels() -> [String] { data.map(\.label) }
}
