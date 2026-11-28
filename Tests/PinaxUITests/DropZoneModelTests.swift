import AppKit
import CatalogCore
import CoreGraphics
import Foundation
import GRDB
import PinaxUI
import Testing

@MainActor
@Suite struct DropZoneModelTests {
  @Test("A drop creates one card per file and uploads into the selected project")
  func dropUploadsEveryFile() async throws {
    let service = StubUploadService()
    let model = makeModel(service: service)

    model.selectedProjectSlug = "blog"

    let files = (0..<3).map { URL(fileURLWithPath: "/tmp/shot-\($0).png") }
    model.drop(fileURLs: files)

    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.cards.count == 3)
    #expect(model.cards.allSatisfy { $0.phase.isDone })
    #expect(service.uploadedProjects.count == 3)
    #expect(service.uploadedProjects.allSatisfy { $0 == "blog" })
    #expect(model.isWindowVisible)
  }

  /// The zone's selection is the current
  /// project (`CurrentProjectTests.oneValue` pins that wiring); a card takes
  /// it at the drop and keeps it when the current project changes after.
  @Test("A new card takes the current project; changing it afterwards leaves the card")
  func dropSnapshotsCurrentProject() async throws {
    let service = StubUploadService()
    let model = makeModel(service: service)
    model.selectedProjectSlug = "notes"

    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/shot-a.png")])
    #expect(model.cards.map(\.projectSlug) == ["notes"])
    model.selectedProjectSlug = "blog"
    #expect(model.cards.map(\.projectSlug) == ["notes"])
    model.selectedProjectSlug = nil
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.cards.map(\.projectSlug) == ["notes"])
    #expect(service.uploadedProjects == ["notes"])

    // All Projects: the next card goes into no project.
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/shot-b.png")])
    #expect(model.cards.first?.projectSlug == nil)
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(service.uploadedProjects == ["notes", nil])
  }

  @Test("One failing upload out of three fails on its own card only")
  func partialFailureIsVisible() async throws {
    let service = StubUploadService()
    service.uploadHandler = { url in
      if url.lastPathComponent.contains("bad") {
        throw UploadPipelineError.unsupportedFileType(url.lastPathComponent)
      }
      return StubUploadService.outcome(filename: url.lastPathComponent)
    }
    let model = makeModel(service: service)

    model.drop(fileURLs: [
      URL(fileURLWithPath: "/tmp/good-a.png"),
      URL(fileURLWithPath: "/tmp/bad.png"),
      URL(fileURLWithPath: "/tmp/good-b.png"),
    ])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }

    let failed = model.cards.filter {
      if case .failed = $0.phase { return true }
      return false
    }
    #expect(failed.count == 1)
    #expect(failed[0].filename == "bad.png")
    if case let .failed(message) = failed[0].phase {
      #expect(message.contains("bad.png"))
    }
    #expect(model.cards.filter(\.phase.isDone).count == 2)
    #expect(model.isWindowVisible)
  }

  @Test("A large drop keeps uploads bounded and every item settles")
  func largeDropStaysBounded() async throws {
    let service = StubUploadService()
    let tracker = ConcurrencyTracker()
    service.uploadHandler = { url in
      await tracker.run {
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return StubUploadService.outcome(filename: url.lastPathComponent)
    }
    let model = makeModel(service: service)

    let files = (0..<24).map { URL(fileURLWithPath: "/tmp/bulk-\($0).png") }
    model.drop(fileURLs: files)
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }

    #expect(model.cards.count == 24)
    #expect(model.cards.allSatisfy { $0.phase.isDone })
    let peak = await tracker.peak
    #expect(peak <= 4)
    #expect(peak >= 2)
  }

  @Test("Window visibility follows the drag, then the cards")
  func visibilityLifecycle() async throws {
    let model = makeModel(service: StubUploadService())
    #expect(!model.isWindowVisible)

    model.dragDidChange(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")], modifiers: [])
    #expect(model.isWindowVisible)

    // Drag released away from the zone with no results: hide again.
    model.dragDidEnd()
    #expect(!model.isWindowVisible)

    model.dragDidChange(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")], modifiers: [])
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    model.dragDidEnd()
    #expect(model.isWindowVisible)

    model.dismiss()
    #expect(!model.isWindowVisible)
    // This run's cards outlive × for the menu bar's Show Drop Zone.
    #expect(model.cards.count == 1)
  }

  @Test("Retry re-enqueues a failed card and it can succeed")
  func retryFailedCard() async throws {
    let service = StubUploadService()
    let gate = FailureGate()
    service.uploadHandler = { url in
      try gate.check(url.lastPathComponent)
      return StubUploadService.outcome(filename: url.lastPathComponent)
    }
    let model = makeModel(service: service)
    let url = URL(fileURLWithPath: "/tmp/flaky.png")

    model.drop(fileURLs: [url])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.cards[0].phase == .failed("upload failed once"))

    gate.stopFailing()
    model.retry(model.cards[0].id)
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.cards[0].phase.isDone)
    #expect(model.cards[0].phase != .failed("upload failed once"))
  }

  @Test("Changing a landed card's project moves the asset; a refusal reverts")
  func changeProjectMovesAsset() async throws {
    let service = StubUploadService()
    let model = makeModel(service: service)
    model.selectedProjectSlug = "blog"  // the zone does not default to the first project
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/shot.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let card = model.cards[0]
    #expect(card.projectSlug == "blog")

    model.changeProject(card.id, to: "notes")
    await waitUntil { !service.moveCalls.isEmpty }
    #expect(service.moveCalls[0].from == "blog")
    #expect(service.moveCalls[0].to == "notes")
    #expect(model.cards[0].projectSlug == "notes")

    // A refused move reverts the picker and shows the reason on the card.
    service.moveError = UploadPipelineError.missingBackendID
    model.changeProject(model.cards[0].id, to: nil)
    await waitUntil { model.cards[0].moveError != nil }
    #expect(model.cards[0].projectSlug == "notes")
    #expect(model.cards[0].moveError?.isEmpty == false)
  }

  /// The zone stores nothing; its project is the app's
  /// current project (persisted by `PreferencesStore`, tested in
  /// `CurrentProjectTests`). Nothing chosen is All Projects, and a project
  /// that is gone reads as All Projects rather than the first one.
  @Test("The zone starts on All Projects and a vanished project reads as All Projects")
  func projectDefaultIsAllProjects() async throws {
    let model = makeModel(service: StubUploadService())
    #expect(model.projects.map(\.slug) == ["blog", "notes"])
    #expect(model.selectedProjectSlug == nil)

    model.selectedProjectSlug = "notes"
    model.loadProjects()
    #expect(model.selectedProjectSlug == "notes")

    model.selectedProjectSlug = "ghost"
    model.loadProjects()
    #expect(model.selectedProjectSlug == nil)
  }

  @Test("A drop's thumbnail is generated locally and lands in the cache")
  func droppedFileThumbnailIsFree() async throws {
    let jpeg = try #require(makeJPEGData())
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-thumb-\(UUID().uuidString).jpg")
    try jpeg.write(to: file, options: .atomic)
    defer { try? FileManager.default.removeItem(at: file) }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-zone-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let thumbnails = ThumbnailCache(cacheDirectory: directory, fetcher: { _ in
      Issue.record("the fetcher must not run — the bytes are local")
      throw URLError(.unsupportedURL)
    })
    let service = StubUploadService()
    service.uploadHandler = { url in
      StubUploadService.outcome(filename: url.lastPathComponent, sha256: Hashing.sha256(of: jpeg))
    }
    let model = DropZoneModel(service: service, thumbnails: thumbnails)

    model.drop(fileURLs: [file])
    await waitUntil { model.cards[0].thumbnail != nil }
    #expect(model.cards[0].thumbnail != nil)

    let sha = Hashing.sha256(of: jpeg)
    let cached = directory.appendingPathComponent("\(sha.prefix(2))/\(sha).jpg")
    #expect(FileManager.default.fileExists(atPath: cached.path))
  }

  @Test("Settling a batch fires the gallery-refresh hook once")
  func uploadsSettledFiresOnce() async throws {
    let model = makeModel(service: StubUploadService())
    let counter = CounterBox()
    model.onUploadsSettled = { counter.increment() }

    model.drop(fileURLs: (0..<3).map { URL(fileURLWithPath: "/tmp/s-\($0).png") })
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    // Let any duplicate settle notifications drain before asserting.
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(counter.value == 1)
  }

  @Test("Reveal on demand keeps the panel up without a drag or cards")
  func revealOnDemandShowsPanel() async throws {
    let model = makeModel(service: StubUploadService())
    #expect(!model.isWindowVisible)

    model.revealOnDemand()
    #expect(model.isShownOnDemand)
    #expect(model.isWindowVisible)

    // A drag ending does not take the on-demand panel with it.
    model.dragDidEnd()
    #expect(model.isWindowVisible)

    model.dismiss()
    #expect(!model.isShownOnDemand)
    #expect(!model.isWindowVisible)
  }

  @Test("An on-demand panel stays while a drop's cards are still undismissed")
  func onDemandSurvivesDrop() async throws {
    let model = makeModel(service: StubUploadService())
    model.revealOnDemand()
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }

    // Dismissing clears both causes at once; nothing may keep the panel up.
    model.dismiss()
    #expect(!model.isWindowVisible)
  }

  @Test("Disabling the zone retracts an on-demand panel")
  func disableRetractsOnDemand() async throws {
    let model = makeModel(service: StubUploadService())
    model.revealOnDemand()
    #expect(model.isWindowVisible)

    // A drag ending alone must not take the on-demand panel with it…
    model.dragDidEnd()
    #expect(model.isWindowVisible)

    // …but disabling the feature must: a revealed panel carries a live
    // dropDestination that bypasses the stopped monitor.
    model.disable()
    #expect(!model.isShownOnDemand)
    #expect(!model.isWindowVisible)
  }

  @Test("The controller hides a revealed panel when the zone is disabled")
  func controllerDisableHidesRevealedPanel() async throws {
    let model = makeModel(service: StubUploadService())
    let controller = DropZoneController(
      model: model, preferences: PreferencesStore(defaults: try makeDefaults()))

    model.revealOnDemand()
    #expect(model.isWindowVisible)

    // The seam a bug once hid in: the controller's disable path, not just
    // the model's. Stopping a never-started monitor is a guarded no-op.
    controller.setEnabled(false)
    #expect(!model.isShownOnDemand)
    #expect(!model.isWindowVisible)
  }

  // MARK: - Modifier gate ("Require modifier to show")

  @Test("A gated drag surfaces the zone only while its modifier is held")
  func modifierGate() async throws {
    let model = makeModel(service: StubUploadService())
    model.dragVisibilityModifier = .option
    let files = [URL(fileURLWithPath: "/tmp/x.png")]

    // Qualifying drag, modifier not held: invisible.
    model.dragDidChange(fileURLs: files, modifiers: [])
    #expect(!model.isWindowVisible)

    // Same drag, option now held: visible.
    model.dragDidChange(fileURLs: files, modifiers: .option)
    #expect(model.isWindowVisible)

    // A different modifier does not open an option gate.
    model.dragDidChange(fileURLs: files, modifiers: .command)
    #expect(!model.isWindowVisible)

    // Gate off: every qualifying drag shows, as if there were no gate.
    model.dragVisibilityModifier = nil
    model.dragDidChange(fileURLs: files, modifiers: [])
    #expect(model.isWindowVisible)
    model.dragDidEnd()
    #expect(!model.isWindowVisible)
  }

  @Test("A mid-drag modifier press and release reach the model through the real monitor")
  func midDragModifierSamplingThroughMonitor() async throws {
    // A past defect lived in this exact path — the changeCount gate
    // let one drag produce one sample, so the gate only ever judged the first
    // frame. This test must not shortcut the model, or it tests nothing.
    let pasteboard = CountingPasteboard()
    let model = makeModel(service: StubUploadService())
    model.dragVisibilityModifier = .option
    let monitor = DragMonitor(
      pasteboard: pasteboard,
      onSample: { model.dragDidChange(fileURLs: $0, modifiers: $1) },
      onDragEnded: { model.dragDidEnd() }
    )
    monitor.baselinePasteboard()
    pasteboard.advance(dropping: [URL(fileURLWithPath: "/tmp/a.png")])

    // Drag starts with no modifier held: gate closed.
    monitor.dragEventOccurred(flags: [])
    await waitUntil { pasteboard.readCount == 1 }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(!model.isWindowVisible)

    // ⌥ pressed mid-drag — the natural Clop interaction order: zone appears,
    // with no extra pasteboard read.
    monitor.dragEventOccurred(flags: .option)
    await waitUntil { model.isWindowVisible }
    #expect(pasteboard.readCount == 1)

    // ⌥ released mid-drag: zone retracts, same session.
    monitor.dragEventOccurred(flags: [])
    await waitUntil { !model.isWindowVisible }
    #expect(pasteboard.readCount == 1)

    // Session over: a later modifier-held mouse drag with an untouched
    // pasteboard resurrects nothing.
    monitor.mouseUpOccurred()
    monitor.dragEventOccurred(flags: .option)
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(!model.isWindowVisible)
    #expect(pasteboard.readCount == 1)
  }

  @Test("The drag-over count comes from the monitor's one read — the pasteboard is still read once per session")
  func dragOverCountReadsNoMore() async throws {
    let pasteboard = CountingPasteboard()
    let model = makeModel(service: StubUploadService())
    model.dragVisibilityModifier = .option
    let monitor = DragMonitor(
      pasteboard: pasteboard,
      onSample: { model.dragDidChange(fileURLs: $0, modifiers: $1) },
      onDragEnded: { model.dragDidEnd() }
    )
    monitor.baselinePasteboard()
    let files = ["a", "b", "c"].map { URL(fileURLWithPath: "/pinax-dz/\($0).png") }
    pasteboard.advance(dropping: files)

    monitor.dragEventOccurred(flags: .option)
    await waitUntil { model.draggedFileURLs.count == 3 }
    #expect(model.draggedFileURLs == files)
    monitor.dragEventOccurred(flags: [])
    monitor.dragEventOccurred(flags: .option)
    await waitUntil { model.isWindowVisible }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(model.draggedFileURLs.count == 3)
    #expect(pasteboard.readCount == 1)

    monitor.mouseUpOccurred()
    await waitUntil { model.draggedFileURLs.isEmpty }
    #expect(model.draggedFileURLs.isEmpty)
    #expect(pasteboard.readCount == 1)
  }

  // MARK: - Auto-hide results

  @Test("Settled results hide the panel after the delay; 0 means never")
  func autoHideDismissesResults() async throws {
    let model = makeModel(service: StubUploadService())
    let clock = FakeClock()
    model.autoHideScheduler = clock.schedule
    model.autoHidesResultsAfter = 30

    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.isWindowVisible)

    clock.advance(by: 30)
    #expect(!model.isWindowVisible)

    // 0 = never: settled results stay on screen.
    let patient = makeModel(service: StubUploadService())
    patient.drop(fileURLs: [URL(fileURLWithPath: "/tmp/y.png")])
    await waitUntil { patient.cards.allSatisfy { !$0.phase.isPending } }
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(patient.isWindowVisible)
    #expect(!patient.cards.isEmpty)
  }

  @Test("The countdown ends the presentation but not the on-demand standing zone")
  func autoHideSparesOnDemandZone() async throws {
    // ⌘⇧D while a batch's auto-hide is pending must not lose
    // the standing drop target when the results collect.
    let model = makeModel(service: StubUploadService())
    let clock = FakeClock()
    model.autoHideScheduler = clock.schedule
    model.autoHidesResultsAfter = 30
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }

    model.revealOnDemand()
    clock.advance(by: 30)
    #expect(!model.isPresenting)
    #expect(model.isShownOnDemand)
    #expect(model.isWindowVisible)
  }

  // MARK: - Auto-copy URLs

  @Test("A settled batch copies its successful URLs once, failures skipped")
  func autoCopySettledURLs() async throws {
    let service = StubUploadService()
    service.uploadHandler = { url in
      if url.lastPathComponent.contains("bad") {
        throw UploadPipelineError.unsupportedFileType(url.lastPathComponent)
      }
      return StubUploadService.outcome(filename: url.lastPathComponent)
    }
    let model = makeModel(service: service)
    let copies = CopiedStrings()
    model.urlCopier = { copies.append($0) }

    model.drop(fileURLs: [
      URL(fileURLWithPath: "/tmp/good-a.png"),
      URL(fileURLWithPath: "/tmp/bad.png"),
    ])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    // Let any spurious duplicate settle transitions drain before asserting.
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(copies.values == ["https://img.example.com/blog/good-a.png"])

    // Turned off: a later batch copies nothing.
    model.copiesURLsAutomatically = false
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/good-b.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(copies.values.count == 1)
  }

  @Test("A batch whose only file fails copies nothing, even with an earlier batch's done cards still listed")
  func failedBatchDoesNotRecopy() async throws {
    let service = StubUploadService()
    service.uploadHandler = { url in
      if url.lastPathComponent.contains("bad") {
        throw UploadPipelineError.unsupportedFileType(url.lastPathComponent)
      }
      return StubUploadService.outcome(filename: url.lastPathComponent)
    }
    let model = makeModel(service: service)
    let copies = CopiedStrings()
    model.urlCopier = { copies.append($0) }

    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/good-a.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(copies.values == ["https://img.example.com/blog/good-a.png"])

    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/bad.md")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(model.cards.count == 2)
    #expect(copies.values == ["https://img.example.com/blog/good-a.png"])

    // A later batch with a success copies again: every done card, card order.
    model.drop(fileURLs: [
      URL(fileURLWithPath: "/tmp/good-b.png"), URL(fileURLWithPath: "/tmp/bad-2.png"),
    ])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(copies.values.count == 2)
    #expect(copies.values.last == """
      https://img.example.com/blog/good-b.png
      https://img.example.com/blog/good-a.png
      """)
  }

  @Test("onWindowDidShow fires once per hidden-to-visible transition, not on refreshes while visible")
  func windowDidShowOnTransitionOnly() async throws {
    let model = makeModel(service: StubUploadService())
    let shows = CounterBox()
    model.onWindowDidShow = { shows.increment() }

    model.revealOnDemand()
    #expect(shows.value == 1)
    model.revealOnDemand()
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/shot-a.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    model.dragDidEnd()
    #expect(model.isWindowVisible)
    #expect(shows.value == 1)

    model.dismiss()
    #expect(!model.isWindowVisible)
    #expect(shows.value == 1)
    model.revealOnDemand()
    #expect(shows.value == 2)
  }

  @Test("Multiple successes copy newline-joined, in card order")
  func autoCopyJoinsMultipleURLs() async throws {
    let model = makeModel(service: StubUploadService())
    let copies = CopiedStrings()
    model.urlCopier = { copies.append($0) }

    model.drop(fileURLs: [
      URL(fileURLWithPath: "/tmp/shot-a.png"),
      URL(fileURLWithPath: "/tmp/shot-b.png"),
    ])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(copies.values == [
      "https://img.example.com/blog/shot-a.png\nhttps://img.example.com/blog/shot-b.png"
    ])
  }

  // MARK: - Placement

  @Test("A visible panel re-places itself when the corner preference changes")
  func cornerChangeReplacesVisiblePanel() async throws {
    let screen = try #require(NSScreen.main)
    let model = makeModel(service: StubUploadService())
    let preferences = PreferencesStore(defaults: try makeDefaults())
    #expect(preferences.dropZoneCorner == .bottomLeft)
    let controller = DropZoneController(model: model, preferences: preferences)

    model.revealOnDemand()
    await waitUntil { controller.placementRecomputations >= 1 }
    // The panel slides into place as it appears; read it once there.
    await waitUntil { !controller.isAppearing }

    // Default placement: bottom-left of the main screen's visible frame.
    let visible = screen.visibleFrame
    let first = try #require(controller.panelFrame)
    #expect(abs(first.minX - (visible.minX + 24)) < 1)
    #expect(abs(first.minY - (visible.minY + 24)) < 1)

    // Live preference change while visible: the panel moves corners.
    let before = controller.placementRecomputations
    preferences.dropZoneCorner = .topRight
    await waitUntil { controller.placementRecomputations > before }
    let second = try #require(controller.panelFrame)
    #expect(abs(second.maxX - (visible.maxX - 24)) < 1)
    #expect(abs(second.maxY - (visible.maxY - 24)) < 1)
  }

  @Test("A screen-parameters change re-runs placement, still inside the visible frame")
  func screenChangeReplacesPanel() async throws {
    let model = makeModel(service: StubUploadService())
    let preferences = PreferencesStore(defaults: try makeDefaults())
    let controller = DropZoneController(model: model, preferences: preferences)

    model.revealOnDemand()
    await waitUntil { controller.placementRecomputations >= 1 }

    // The mechanism a real undock/resolution change arrives through. The
    // property: placement is *recomputed* — never trusted from cache.
    let before = controller.placementRecomputations
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    await waitUntil { controller.placementRecomputations > before }

    let visible = try #require(NSScreen.main).visibleFrame
    let frame = try #require(controller.panelFrame)
    #expect(frame.minX >= visible.minX - 1)
    #expect(frame.maxX <= visible.maxX + 1)
    #expect(frame.minY >= visible.minY - 1)
    #expect(frame.maxY <= visible.maxY + 1)

    controller.setEnabled(false)
  }

  // MARK: - Helpers

  private func makeModel(service: StubUploadService) -> DropZoneModel {
    let thumbnails = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-zone-\(UUID().uuidString)", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) }
    )
    let model = DropZoneModel(service: service, thumbnails: thumbnails)
    model.loadProjects()
    return model
  }

  private func makeDefaults() throws -> UserDefaults {
    let name = "pinaxui-zone-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    return defaults
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

private extension DropZoneModel.UploadCard.Phase {
  var isDone: Bool {
    if case .done = self { return true }
    return false
  }
}

private final class StubUploadService: DropZoneService, @unchecked Sendable {
  private let lock = NSLock()
  private var uploadedSlugs: [String?] = []
  private var moves: [(from: String?, to: String?)] = []
  var moveError: Error?

  var uploadHandler: @Sendable (URL) async throws -> UploadOutcome = { url in
    StubUploadService.outcome(filename: url.lastPathComponent)
  }

  func projects() throws -> [Project] {
    [
      Project(
        slug: "blog", name: "Blog", keyPrefix: "blog", backendID: 1,
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z"),
      Project(
        slug: "notes", name: "Notes", keyPrefix: "notes", backendID: 1,
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z"),
    ]
  }

  func prepare(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    PreparedDrop(fileURL: fileURL, projectSlug: projectSlug)
  }

  func upload(_ prepared: PreparedDrop, useOriginal: Bool) async throws -> UploadOutcome {
    let fileURL = prepared.fileURL
    let projectSlug = prepared.projectSlug
    let handler = lock.withLock { uploadHandler }
    let outcome = try await handler(fileURL)
    lock.withLock { uploadedSlugs.append(projectSlug) }
    return outcome
  }

  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws {
    if let moveError {
      throw moveError
    }
    lock.withLock { moves.append((fromProject, toProject)) }
  }

  var uploadedProjects: [String?] {
    lock.withLock { uploadedSlugs }
  }

  var moveCalls: [(from: String?, to: String?)] {
    lock.withLock { moves }
  }

  static func outcome(filename: String, sha256: String = String(repeating: "0a", count: 32))
    -> UploadOutcome
  {
    UploadOutcome(
      sha256: sha256,
      key: "blog/\(filename)",
      url: "https://img.example.com/blog/\(filename)",
      mime: "image/png",
      originalFilename: filename,
      byteSize: 1234,
      width: 800,
      height: 600,
      uploadedAt: "2026-08-22T00:00:00Z",
      deduplicated: false,
      dryRun: false
    )
  }
}

private actor ConcurrencyTracker {
  private var active = 0
  private(set) var peak = 0

  func run(_ body: @escaping @Sendable () async -> Void) async {
    active += 1
    peak = max(peak, active)
    await body()
    active -= 1
  }
}

private final class FailureGate: @unchecked Sendable {
  private let lock = NSLock()
  private var failing = true

  func stopFailing() {
    lock.withLock { failing = false }
  }

  func check(_ name: String) throws {
    if lock.withLock({ failing }) {
      throw StubError("upload failed once")
    }
  }
}

private struct StubError: LocalizedError {
  let message: String
  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

private final class CounterBox: @unchecked Sendable {
  private let lock = NSLock()
  private var backing = 0

  var value: Int {
    lock.withLock { backing }
  }

  func increment() {
    lock.withLock { backing += 1 }
  }
}

private final class CopiedStrings: @unchecked Sendable {
  private let lock = NSLock()
  private var backing: [String] = []

  var values: [String] {
    lock.withLock { backing }
  }

  func append(_ value: String) {
    lock.withLock { backing.append(value) }
  }
}

/// The minimum pasteboard fake the mid-drag test needs: a changeCount that
/// only moves when a new drag session writes, and a read counter to prove the
/// cached re-sampling never reads the pasteboard.
private final class CountingPasteboard: DragPasteboardReading, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var urls: [URL] = []
  private var fileReads = 0

  var changeCount: Int { lock.withLock { count } }
  var readCount: Int { lock.withLock { fileReads } }

  func advance(dropping urls: [URL]) {
    lock.withLock {
      count += 1
      self.urls = urls
    }
  }

  func fileURLs() -> [URL] {
    lock.withLock {
      fileReads += 1
      return urls
    }
  }
}

/// The panel stays after a drop, counts down only once the last
/// upload has ended, pauses under the pointer, never hides while pinned, and
/// × hides at once and unpins. Every countdown runs on `FakeClock` — no test
/// here waits in real time for the timer (uploads still settle on their own).
@MainActor
@Suite struct DropZoneStayTests {
  @Test("The countdown starts when the last upload ends, and hides the panel N seconds later")
  func countdownFromLastUpload() async throws {
    let clock = FakeClock()
    let gate = ReleaseGate()
    let service = StubUploadService()
    service.uploadHandler = { url in
      if url.lastPathComponent == "b.png" { await gate.wait() }
      return StubUploadService.outcome(filename: url.lastPathComponent)
    }
    let model = makeModel(service: service, clock: clock)
    model.autoHidesResultsAfter = 60

    model.dragDidChange(fileURLs: [URL(fileURLWithPath: "/tmp/a.png")], modifiers: [])
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
    model.dragDidEnd()
    await waitUntil { model.cards.first?.phase.isPending == false }
    clock.advance(by: 600)
    #expect(model.isWindowVisible, "b is still uploading: no countdown yet")

    gate.release()
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    clock.advance(by: 59)
    #expect(model.isWindowVisible)
    clock.advance(by: 1)
    #expect(!model.isWindowVisible)
    #expect(model.cards.count == 2, "hiding keeps this run's cards for Show Drop Zone")
  }

  @Test("A drag ending after the drop leaves the panel up (either event order)")
  func dragEndDoesNotHide() async throws {
    let model = makeModel(service: StubUploadService(), clock: FakeClock())
    model.dragDidChange(fileURLs: [URL(fileURLWithPath: "/tmp/a.png")], modifiers: [])
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/a.png")])
    model.dragDidEnd()
    #expect(model.isWindowVisible)
    model.pointerDidEnter()
    model.pointerDidExit()
    #expect(model.isWindowVisible, "the pointer leaving is not a hide either")
  }

  @Test("The pointer inside pauses the countdown; leaving restarts it from the top")
  func pointerPausesCountdown() async throws {
    let clock = FakeClock()
    let model = try await settledModel(clock: clock, delay: 30)
    clock.advance(by: 20)
    model.pointerDidEnter()
    clock.advance(by: 3600)
    #expect(model.isWindowVisible)
    model.pointerDidExit()
    clock.advance(by: 29)
    #expect(model.isWindowVisible, "restarted from 30, not resumed from 10")
    clock.advance(by: 1)
    #expect(!model.isWindowVisible)
  }

  @Test("Pinned never hides; unpinning restarts the countdown from the top")
  func pinnedNeverHides() async throws {
    let clock = FakeClock()
    let model = try await settledModel(clock: clock, delay: 30)
    clock.advance(by: 20)
    model.togglePin()
    #expect(model.isPinned)
    clock.advance(by: 100_000)
    #expect(model.isWindowVisible)
    model.togglePin()
    clock.advance(by: 29)
    #expect(model.isWindowVisible)
    clock.advance(by: 1)
    #expect(!model.isWindowVisible)
  }

  @Test("× hides at once and unpins")
  func closeHidesAndUnpins() async throws {
    let clock = FakeClock()
    let model = try await settledModel(clock: clock, delay: 30)
    model.togglePin()
    model.dismiss()
    #expect(!model.isWindowVisible)
    #expect(!model.isPinned)
    // The next presentation counts down again (it is not still pinned).
    model.presentSession()
    #expect(model.isWindowVisible)
    clock.advance(by: 30)
    #expect(!model.isWindowVisible)
  }

  @Test("The header's pin symbols exist")
  func pinSymbolsExist() {
    for name in ["pin", "pin.fill", "xmark.circle.fill"] {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  @Test("Never (0) arms no countdown at all")
  func neverArmsNothing() async throws {
    let clock = FakeClock()
    let model = try await settledModel(clock: clock, delay: 0)
    clock.advance(by: 100_000)
    #expect(model.isWindowVisible)
    #expect(clock.pendingCount == 0)
  }

  @Test("The panel's own tracking area moves the pointer state the countdown reads")
  func trackingAreaDrivesPointerState() async throws {
    let model = makeModel(service: StubUploadService(), clock: FakeClock())
    let controller = DropZoneController(
      model: model, preferences: PreferencesStore(defaults: try makeDefaults()))
    model.revealOnDemand()
    await waitUntil { controller.panelContentView != nil }
    let view = try #require(controller.panelContentView)
    func send(_ type: NSEvent.EventType) throws {
      let event = try #require(
        NSEvent.enterExitEvent(
          with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
      for area in view.trackingAreas where area.options.contains(.mouseEnteredAndExited) {
        let owner = area.owner as? NSResponder
        type == .mouseEntered ? owner?.mouseEntered(with: event) : owner?.mouseExited(with: event)
      }
    }
    try send(.mouseEntered)
    #expect(model.isPointerInside)
    try send(.mouseExited)
    #expect(!model.isPointerInside)
  }

  @Test("The panel's header pin and × buttons pin, unpin and close the zone")
  func headerButtonsDriveTheModel() async throws {
    let model = try await settledModel(clock: FakeClock(), delay: 30)
    // The body the panel hosts (`DropZoneController` → `DropZoneView(model:)`).
    func press(_ symbol: String) throws {
      let action = buttonAction(
        in: DropZoneView(model: model).body,
        label: { Mirror(reflecting: $0).descendant("provider", "base", "name") as? String == symbol })
      let pressed = try #require(action, "\(symbol)")
      pressed()
    }
    try press("pin")
    #expect(model.isPinned)
    try press("pin.fill")
    #expect(!model.isPinned)
    try press("pin")
    try press("xmark.circle.fill")
    #expect(!model.isWindowVisible)
    #expect(!model.isPinned)
  }

  private func settledModel(clock: FakeClock, delay: TimeInterval) async throws -> DropZoneModel {
    let model = makeModel(service: StubUploadService(), clock: clock)
    model.autoHidesResultsAfter = delay
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/x.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.isWindowVisible)
    return model
  }

  private func makeModel(service: StubUploadService, clock: FakeClock) -> DropZoneModel {
    let thumbnails = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-zone-\(UUID().uuidString)", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) }
    )
    let model = DropZoneModel(service: service, thumbnails: thumbnails)
    model.autoHideScheduler = clock.schedule
    model.loadProjects()
    return model
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-zone-stay-\(UUID().uuidString)"))
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

/// A manual clock for the auto-hide countdown: `advance(by:)` fires every
/// timer that has come due, in deadline order; cancelling removes it.
@MainActor
final class FakeClock {
  private var now: TimeInterval = 0
  private var nextID = 0
  private var timers: [(id: Int, due: TimeInterval, action: @MainActor () -> Void)] = []

  var pendingCount: Int { timers.count }

  func schedule(
    after delay: TimeInterval, _ action: @escaping @MainActor () -> Void
  ) -> @MainActor () -> Void {
    let id = nextID
    nextID += 1
    timers.append((id, now + delay, action))
    return { [weak self] in self?.timers.removeAll { $0.id == id } }
  }

  func advance(by seconds: TimeInterval) {
    now += seconds
    while let index = timers.indices.filter({ timers[$0].due <= now })
      .min(by: { timers[$0].due < timers[$1].due })
    {
      timers.remove(at: index).action()
    }
  }
}

/// Holds one upload open until released.
private final class ReleaseGate: @unchecked Sendable {
  private let lock = NSLock()
  private var released = false

  func release() { lock.withLock { released = true } }

  func wait() async {
    while !lock.withLock({ released }) {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
  }
}

/// The placement arithmetic in isolation. The property "the panel
/// re-places itself after a screen change" — decomposes into: placement is
/// computed purely from the *current* visible frame (these tests), and the
/// controller re-runs it when screens change (the controller tests above).
/// A cached origin can never survive this shape.
@Suite struct DropZonePlacementTests {
  /// A realistic docked frame: 1440×900 display with menu bar and Dock.
  private let visible = NSRect(x: 40, y: 25, width: 1360, height: 850)
  private let panel = CGSize(width: 340, height: 420)

  @Test("Every corner lands margin-in from that corner of the visible frame")
  func cornerOrigins() {
    #expect(
      DropZonePlacement.origin(corner: .topLeft, panelSize: panel, visibleFrame: visible)
        == CGPoint(x: 64, y: 431))
    #expect(
      DropZonePlacement.origin(corner: .topRight, panelSize: panel, visibleFrame: visible)
        == CGPoint(x: 1036, y: 431))
    #expect(
      DropZonePlacement.origin(corner: .bottomLeft, panelSize: panel, visibleFrame: visible)
        == CGPoint(x: 64, y: 49))
    #expect(
      DropZonePlacement.origin(corner: .bottomRight, panelSize: panel, visibleFrame: visible)
        == CGPoint(x: 1036, y: 49))
  }

  @Test("Whatever the corner, the panel stays wholly inside the visible frame")
  func panelNeverLeavesVisibleFrame() {
    for corner in DropZoneCorner.allCases {
      let origin = DropZonePlacement.origin(corner: corner, panelSize: panel, visibleFrame: visible)
      #expect(origin.x >= visible.minX)
      #expect(origin.x + panel.width <= visible.maxX)
      #expect(origin.y >= visible.minY)
      #expect(origin.y + panel.height <= visible.maxY)
    }
  }

  @Test("A smaller visible frame re-places the panel — nothing is inherited")
  func smallerFrameReplaces() {
    // The undock scenario shrunk to arithmetic: the visible frame changes,
    // and the new origin comes from the new frame alone.
    let smaller = NSRect(x: 0, y: 25, width: 1470, height: 906)
    let origin = DropZonePlacement.origin(corner: .bottomLeft, panelSize: panel, visibleFrame: smaller)
    #expect(origin == CGPoint(x: 24, y: 49))
    #expect(origin.x < visible.minX)  // a genuinely different answer, not the old one
  }
}
