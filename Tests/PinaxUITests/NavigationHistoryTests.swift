import Combine
import CatalogCore
import Foundation
@testable import PinaxUI
import Testing

/// The jump bar's ◀ ▶ walk the
/// places the sidebar has shown. Asserted on the gallery model, through the
/// same writes the sidebar, the switcher and the menus make.
@MainActor
@Suite struct NavigationHistoryTests {
  private func makeModel() throws -> (GalleryModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-history-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    return (model, directory)
  }

  private func place(_ model: GalleryModel) -> NavigationHistory.Place {
    .init(model.navigator, model.sidebarSelection)
  }

  @Test("Back and forward walk the visits; a visit after going back cuts the forward run")
  func backAndForwardWalkTheVisits() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    // A, B, C — through the sidebar's own write, the jump bar's write and
    // the menus' `select(_:in:)`.
    model.sidebarSelection = .recent
    let a = place(model)
    model.select(.tag("hero"), in: .collections)
    let b = place(model)
    model.sidebarSelection = .project("blog")
    let c = place(model)
    #expect(!model.canGoForward)
    let length = model.history.places.count

    model.goBack()
    #expect(place(model) == b)
    model.goBack()
    #expect(place(model) == a)
    model.goForward()
    #expect(place(model) == b)
    #expect(model.history.places.count == length, "back and forward add no entry")
    #expect(model.canGoBack && model.canGoForward)

    // D after going back: the forward run (C) is gone and forward grays.
    model.select(.orphans, in: .reports)
    #expect(!model.canGoForward)
    #expect(!model.history.places.contains(c))
    model.goBack()
    #expect(place(model) == b)
  }

  @Test("Going back across navigators restores both halves in one move of the shown selection")
  func crossNavigatorBackMovesOnce() throws {
    let (model, directory) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let view = GalleryView(model: model)

    // A = Library › Recent, B = Reports › Orphans (the switcher's write),
    // C = Library › All straight from Reports (the View ▸ Library menu's
    // write), so Library's slot holds .all when a back leaves B for A.
    model.sidebarSelection = .recent
    let a = place(model)
    let atA = view.reloadToken
    model.navigator = .reports
    let b = place(model)
    let atB = view.reloadToken
    model.select(.all, in: .library)
    #expect(model.history.places.count == 4, "\(model.history.places)")

    // Every value the shown selection takes while a back runs — the
    // reload token's input.
    var shown: [SidebarSelection] = []
    let watch = model.$navigatorSelections.combineLatest(model.$navigator)
      .map { selections, navigator in selections[navigator] ?? .all }
      .sink { shown.append($0) }
    defer { watch.cancel() }

    model.goBack()
    #expect(place(model) == b)
    #expect(view.reloadToken == atB)
    shown.removeAll()
    model.goBack()
    #expect(place(model) == a)
    #expect(view.reloadToken == atA)
    #expect(model.navigatorSelections[.library] == .recent)

    // One reload per selection, through history: going from B back to A passes
    // through Library's slot (which held .all) only if the navigator
    // switched before the slot was restored — one extra reload.
    let moves = zip(shown, shown.dropFirst()).filter { $0.0 != $0.1 }.count
    #expect(!shown.contains(.all), "shown: \(shown)")
    #expect(moves <= 1, "shown: \(shown)")
  }

  @Test("A launch placeholder resolving to its default is not a step")
  func resolvingDefaultsRecordsNothing() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", projectSlug: "blog")
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-history-launch-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }),
      navigator: .time)

    await model.loadInitialData()
    #expect(model.sidebarSelection == .year("2026"))
    #expect(model.history.places == [.init(.time, .year("2026"))])
    #expect(!model.canGoBack)
  }
}
