import AppKit
import CatalogCore
import Foundation
import SwiftUI
@testable import PinaxUI
import Testing

/// The panel's own motion (window, drag-over, cards, review bar) and the
/// settings preview's Replay.
///
/// Serialized: hosted windows do not survive interleaving at suspension
/// points (LayoutStabilityTests).
@MainActor
@Suite(.serialized) struct DropZonePanelMotionTests {
  typealias Step = DropZonePreviewController.ReplayStep

  // MARK: - Panel motion

  @Test("Reduce Motion makes every panel animation instant; otherwise each one moves")
  func reduceMotionAnimations() {
    typealias M = DropZonePanelMotion
    for reduces in [false, true] {
      #expect((M.appear(reducesMotion: reduces) == nil) == reduces)
      #expect((M.disappear(reducesMotion: reduces) == nil) == reduces)
      #expect((M.drag(reducesMotion: reduces) == nil) == reduces)
      #expect((M.cardShift(reducesMotion: reduces) == nil) == reduces)
      #expect((M.status(reducesMotion: reduces) == nil) == reduces)
      for showing in [false, true] {
        #expect((M.reviewBar(showing: showing, reducesMotion: reduces) == nil) == reduces)
      }
      for index in 0..<12 {
        #expect((M.cardInsertion(index: index, reducesMotion: reduces) == nil) == reduces)
      }
    }
  }

  @Test("The hosted panel reports its surface motion still under Reduce Motion, moving otherwise")
  func hostedReport() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = DropZoneModel.preview(directory: directory)
    model.seedPreview(
      cards: DropZonePreviewSamples.cards(
        for: .results, pictures: DropZonePreviewSamples.pictures(in: directory),
        projectSlug: nil, now: Date()),
      draggedFileURLs: [], projects: [], selectedProjectSlug: nil)
    for reduces in [false, true] {
      let state = DropZoneViewState()
      state.reducesMotion = reduces
      let window = host(DropZoneView(model: model, state: state))
      defer { window.orderOut(nil) }
      await spin { state.panelMotion != nil }
      let report = try #require(state.panelMotion)
      #expect(report.dragFades == !reduces, "\(report)")
      #expect(report.cardsSlideIn == !reduces, "\(report)")
      #expect(report.statusFades == !reduces, "\(report)")
      #expect(report.reviewBarSlides == !reduces, "\(report)")
    }
  }

  @Test("The starting numbers: 0.18 s in, 0.12 s out, 0.2 s drag, 30 ms between cards")
  func cardStagger() {
    typealias M = DropZonePanelMotion
    #expect(abs(M.cardStagger - 0.03) < 0.0001)
    #expect(M.staggeredCards > 0)
    #expect(abs(M.appearDuration - 0.18) < 0.0001)
    #expect(abs(M.disappearDuration - 0.12) < 0.0001)
    #expect(abs(M.dragDuration - 0.2) < 0.0001)
  }

  @Test("The panel slides 8 pt out of its own corner")
  func appearOffsetFollowsCorner() {
    for corner in DropZoneCorner.allCases {
      let offset = DropZonePanelMotion.appearOffset(corner: corner)
      #expect(abs((offset.dx * offset.dx + offset.dy * offset.dy).squareRoot() - 8) < 0.001)
      let left = corner == .topLeft || corner == .bottomLeft
      let top = corner == .topLeft || corner == .topRight
      #expect((offset.dx < 0) == left, "\(corner)")
      // AppKit's y grows upward.
      #expect((offset.dy > 0) == top, "\(corner)")
    }
  }

  @Test("Under Reduce Motion the window shows and goes at once; otherwise it fades, and goes once the fade ends")
  func windowShowAndHide() async throws {
    for reduces in [true, false] {
      let model = DropZoneModel(
        service: MotionSpyService(),
        thumbnails: ThumbnailCache(
          cacheDirectory: makeDirectory(), fetcher: { _ in throw URLError(.unsupportedURL) }))
      model.copiesURLsAutomatically = false
      let defaults = try #require(UserDefaults(suiteName: "pinaxui-motion-\(UUID().uuidString)"))
      let controller = DropZoneController(
        model: model, preferences: PreferencesStore(defaults: defaults))
      controller.viewState.reducesMotion = reduces

      model.revealOnDemand()
      await spin { controller.panelWindow?.isVisible == true }
      #expect(controller.windowChanges == [.appeared(animated: !reduces)])

      model.dismiss()
      await spin { controller.windowChanges.count == 2 }
      #expect(controller.windowChanges.last == .disappeared(animated: !reduces))
      if reduces {
        #expect(controller.panelWindow?.isVisible == false)
      } else {
        // Still fading right after the hide; gone once the fade ends.
        #expect(controller.panelWindow?.isVisible == true)
        await spin { controller.panelWindow?.isVisible == false }
        #expect(controller.panelWindow?.isVisible == false)
        #expect(controller.panelWindow?.alphaValue == 1)
      }
      controller.panelWindow?.orderOut(nil)
    }
  }

  // MARK: - Replay

  @Test("Replay: cards drop in, compress, upload and finish, in that order, and it ends on Results")
  func replayOrderAndEnd() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (preview, service, copied) = makePreview(directory)
    preview.show(.review, projects: [], projectSlug: nil)
    var seen: [(steps: [Step], phases: [DropZoneModel.UploadCard.Phase], ids: [UUID])] = []
    preview.replayPause = { _ in
      seen.append((preview.replaySteps, preview.model.cards.map(\.phase), preview.model.cards.map(\.id)))
      await Task.yield()
    }

    await preview.runReplay(projects: [], projectSlug: nil)

    #expect(preview.replaySteps == [.inserted, .compressing, .uploading, .done])
    // The empty lead, then a hold after each step but the last.
    #expect(seen.map(\.steps.count) == [0, 1, 2, 3])
    #expect(seen.first?.phases.isEmpty == true)
    #expect(seen.dropFirst().allSatisfy { $0.phases.count == 3 })
    #expect(seen[1].phases.allSatisfy { $0 == .waiting })
    #expect(seen[2].phases.allSatisfy { $0 == .compressing })
    #expect(seen[3].phases.allSatisfy { $0 == .uploading })
    // The same three cards throughout: only their state changes.
    #expect(Set(seen.dropFirst().map(\.ids)).count == 1)
    #expect(seen.last?.ids == preview.model.cards.map(\.id))

    #expect(preview.stage == .results)
    #expect(!preview.isReplaying)
    #expect(!preview.model.isReviewing)
    let cards = preview.model.cards
    try #require(cards.count == 3)
    let outcomes = cards.compactMap { card -> UploadOutcome? in
      if case .done(let outcome) = card.phase { return outcome }
      return nil
    }
    #expect(outcomes.count == 3)
    #expect(cards[0].compression != nil, "one copy smaller")
    #expect(cards[1].compression == nil && outcomes[1].deduplicated == false, "one sent as it was")
    #expect(outcomes[2].deduplicated, "one already in the library")

    #expect(service.uploads == 0)
    #expect(service.prepares == 0)
    #expect(service.moves == 0)
    #expect(copied.strings.isEmpty)
  }

  @Test("While a replay runs the button waits and a second press does nothing; after, it can run again")
  func replayDisablesButton() async {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (preview, _, _) = makePreview(directory)
    #expect(preview.canReplay)
    var duringRun: [Bool] = []
    preview.replayPause = { _ in
      duringRun.append(preview.canReplay)
      // A press mid-run.
      preview.replay(projects: [], projectSlug: nil)
      await Task.yield()
    }

    await preview.runReplay(projects: [], projectSlug: nil)

    #expect(duringRun.count == 4)
    #expect(duringRun.allSatisfy { !$0 })
    #expect(preview.replaySteps == [.inserted, .compressing, .uploading, .done])
    #expect(preview.canReplay)
  }

  @Test("Choosing a state mid-replay ends the replay there and shows that state")
  func choosingStateStopsReplay() async {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (preview, _, _) = makePreview(directory)
    preview.replayPause = { _ in
      if preview.replaySteps == [.inserted, .compressing] {
        preview.show(.empty, projects: [], projectSlug: nil)
      }
      await Task.yield()
    }

    await preview.runReplay(projects: [], projectSlug: nil)

    #expect(preview.replaySteps == [.inserted, .compressing])
    #expect(preview.stage == .empty)
    #expect(preview.model.cards.isEmpty)
    #expect(preview.canReplay)
  }

  // MARK: - Helpers

  private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-panel-motion-\(UUID().uuidString)", isDirectory: true)
  }

  private func makePreview(
    _ directory: URL
  ) -> (DropZonePreviewController, MotionSpyService, MotionCopySpy) {
    let service = MotionSpyService()
    let copied = MotionCopySpy()
    let preview = DropZonePreviewController(
      directory: directory, service: service, urlCopier: { copied.strings.append($0) })
    return (preview, service, copied)
  }

  private func host(_ view: some View) -> NSWindow {
    let window = NSPanel(
      contentRect: NSRect(origin: .zero, size: DropZonePanel.defaultSize),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: view)
    window.orderFrontRegardless()
    return window
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.02))
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

private final class MotionSpyService: DropZoneService, @unchecked Sendable {
  private let lock = NSLock()
  private var counts = (uploads: 0, prepares: 0, moves: 0)

  var uploads: Int { lock.withLock { counts.uploads } }
  var prepares: Int { lock.withLock { counts.prepares } }
  var moves: Int { lock.withLock { counts.moves } }

  func projects() throws -> [Project] { [] }

  func prepare(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    lock.withLock { counts.prepares += 1 }
    return PreparedDrop(fileURL: fileURL, projectSlug: projectSlug)
  }

  func upload(_ prepared: PreparedDrop, useOriginal: Bool) async throws -> UploadOutcome {
    lock.withLock { counts.uploads += 1 }
    throw CancellationError()
  }

  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws {
    lock.withLock { counts.moves += 1 }
  }
}

@MainActor
private final class MotionCopySpy {
  var strings: [String] = []
}
