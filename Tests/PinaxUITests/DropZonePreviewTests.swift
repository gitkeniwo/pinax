import AppKit
import CatalogCore
import Foundation
import ImageIO
import SwiftUI
@testable import PinaxUI
import Testing

/// Settings ▸ Drop Zone's preview: its model does nothing that reaches a
/// backend or the clipboard, its samples are built per state and can be
/// shown again, and the mini desktop's arithmetic. Every file goes into a
/// directory of the test's own.
@MainActor
@Suite struct DropZonePreviewTests {
  private typealias Kind = DropZoneCardStatus.Kind

  private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-dz-preview-\(UUID().uuidString)", isDirectory: true)
  }

  private func project(_ slug: String, _ name: String) -> Project {
    Project(slug: slug, name: name, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
  }

  /// Lets the hosted panels lay out.
  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  // MARK: The model

  @Test("A preview's drop, retry, copy, move, Quick Look, pin and close reach neither the service nor the copier")
  func previewModelDoesNothing() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = SpyService()
    let copied = CopySpy()
    let preview = DropZonePreviewController(
      directory: directory, service: service, urlCopier: { copied.strings.append($0) })
    preview.show(.results, projects: [project("astro", "astro")], projectSlug: "astro")
    let model = preview.model
    let before = model.cards.map(\.id)
    let done = try #require(model.cards.first { DropZoneCardStatus(card: $0).kind == .uploaded })
    let failed = try #require(model.cards.first { DropZoneCardStatus(card: $0).kind == .failed })

    model.drop(fileURLs: [URL(fileURLWithPath: "/nonexistent/a.png")])
    model.retry(failed.id)
    model.copyURL(done.id)
    model.copyMarkdown(done.id)
    model.changeProject(done.id, to: nil)
    model.quickLook(done.id)
    model.togglePin()
    model.dismiss()
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(service.uploads == 0)
    #expect(service.moves == 0)
    #expect(copied.strings.isEmpty)
    #expect(model.cards.map(\.id) == before)
    #expect(!model.isPinned)
  }

  @Test("A preview's project picker stays where its seed put it and tells no one")
  func previewPickerHolds() {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preview = DropZonePreviewController(directory: directory, service: SpyService())
    var told: [String?] = []
    preview.model.onSelectedProjectChange = { told.append($0) }
    let projects = [project("astro", "astro"), project("blog", "Blog")]
    preview.show(.results, projects: projects, projectSlug: "astro")

    preview.model.selectedProjectSlug = "blog"

    #expect(preview.model.selectedProjectSlug == "astro")
    #expect(told.isEmpty)
  }

  // MARK: Samples

  @Test("Results: six cards, compressing, uploading, two just landed, in library, failed, with their words")
  func resultsSamples() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pictures = DropZonePreviewSamples.pictures(in: directory)
    let now = Date()
    let cards = DropZonePreviewSamples.cards(
      for: .results, pictures: pictures, projectSlug: "astro", now: now)

    #expect(
      cards.map(\.filename) == [
        "IMG_2817.jpg", "hero-sunset.jpg", "pier-dawn.jpg", "trail-map.png", "cover-2024.webp",
        "IMG_2041.heic",
      ])
    let statuses = cards.map { DropZoneCardStatus(card: $0, now: now) }
    #expect(
      statuses.map(\.kind)
        == [Kind.compressing, .uploading, .uploaded, .uploaded, .inLibrary, .failed])
    #expect(statuses[2].listText == "Just now · −91%")
    #expect(statuses[3].listText == "Just now")
    #expect(statuses[4].listText == "Already in library")
    #expect(cards[2].landedAt == now)
    #expect(cards[3].landedAt == now)
    #expect(cards.map { $0.compression != nil } == [false, true, true, false, false, false])
    #expect(cards.allSatisfy { $0.thumbnail != nil })
    #expect(cards.allSatisfy { $0.projectSlug == "astro" })
    guard case .failed(let message) = cards[5].phase else {
      Issue.record("the last card is not a failure")
      return
    }
    #expect(message == "The network connection was lost.")

    let model = DropZoneModel.preview(directory: directory)
    let state = DropZoneViewState()
    #expect(ResultCardView(card: cards[0], model: model, state: state).metaText == "")
    #expect(
      ResultCardView(card: cards[1], model: model, state: state).metaText
        == "\(PinaxFormat.fileSize(4_100_000)) → \(PinaxFormat.fileSize(298_000))")
    #expect(
      ResultCardView(card: cards[2], model: model, state: state).metaText
        == "2048 × 1365 · \(PinaxFormat.fileSize(3_800_000)) → \(PinaxFormat.fileSize(342_000))")
    #expect(
      ResultCardView(card: cards[3], model: model, state: state).metaText
        == "1600 × 1000 · \(PinaxFormat.fileSize(284_000))")
    #expect(
      ResultCardView(card: cards[4], model: model, state: state).metaText
        == "1200 × 630 · \(PinaxFormat.fileSize(96_000))")
  }

  @Test("Review: four cards held with their switches and the bar's total")
  func reviewSamples() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(DropZonePreviewStage.allCases.map(\.label) == ["Empty", "Dragging", "Review", "Results"])
    let preview = DropZonePreviewController(directory: directory, service: SpyService())
    preview.show(.review, projects: [], projectSlug: "astro")

    let cards = preview.model.cards
    #expect(
      cards.map(\.filename)
        == ["IMG_2817.jpg", "IMG_2041.heic", "banner-wide.jpg", "screenshot-0412.png"])
    #expect(
      cards.map(\.phase) == [
        .review(useOriginal: false), .review(useOriginal: false), .review(useOriginal: true),
        .review(useOriginal: true),
      ])
    #expect(cards.map(\.canCompress) == [true, true, true, false])
    #expect(cards.allSatisfy { $0.thumbnail != nil })
    #expect(preview.model.isReviewing)
    #expect(!preview.state.isDropTargeted)
    let state = DropZoneViewState()
    #expect(
      cards.map { DropZoneCardStatus(card: $0).listText } == [
        "\(PinaxFormat.fileSize(4_600_000)) → \(PinaxFormat.fileSize(336_000)) · −93%",
        "\(PinaxFormat.fileSize(3_100_000)) → \(PinaxFormat.fileSize(412_000)) · −87% · HEIC → JPEG",
        "\(PinaxFormat.fileSize(640_000)) → \(PinaxFormat.fileSize(188_000))",
        "Original · not smaller",
      ])
    #expect(
      cards.map { ResultCardView(card: $0, model: preview.model, state: state).metaText } == [
        "6000 × 4000 → 2048 × 1365", "4032 × 3024 → 2048 × 1536", "1920 × 480",
        "2880 × 1800 · \(PinaxFormat.fileSize(412_000))",
      ])
    #expect(
      preview.model.reviewSummary.text
        == "4 images · \(PinaxFormat.fileSize(8_752_000)) → \(PinaxFormat.fileSize(1_800_000))")

    // The bar's buttons do nothing here, as the cards' do not.
    preview.model.setAllCompress(true)
    preview.model.uploadReviewed()
    preview.model.cancelReview()
    #expect(preview.model.cards.map(\.phase) == cards.map(\.phase))

    preview.show(.results, projects: [], projectSlug: "astro")
    #expect(!preview.model.isReviewing)
  }

  @Test("The pictures are PNG files in the given directory; a second showing leaves them as they are")
  func picturesWrittenOnce() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = DropZonePreviewSamples.pictures(in: directory)
    #expect(first.urls.count == 8)
    for url in first.urls.values {
      #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
      #expect(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) } as String? == "public.png")
    }
    let marked = try #require(first.urls[.map])
    try Data("kept".utf8).write(to: marked)

    _ = DropZonePreviewSamples.pictures(in: directory)

    #expect(try Data(contentsOf: marked) == Data("kept".utf8))
  }

  @Test("The header's project is Upload into resolved: Current Project, No Project, a fixed one, a fixed one that is gone")
  func headerProjectFollowsUploadInto() {
    let projects = [project("astro", "astro"), project("blog", "Blog")]
    func slug(_ choice: DropZoneUploadInto, current: String?) -> String? {
      DropZonePreviewSamples.projectSlug(uploadInto: choice, currentProjectSlug: current, projects: projects)
    }
    #expect(slug(.currentProject, current: "astro") == "astro")
    #expect(slug(.currentProject, current: nil) == nil)
    #expect(slug(.noProject, current: "astro") == nil)
    #expect(slug(.project("blog"), current: "astro") == "blog")
    #expect(slug(.project("gone"), current: "astro") == "astro")
  }

  @Test("Upload into changing moves the header and every card's project without starting over")
  func retargetKeepsCards() {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preview = DropZonePreviewController(directory: directory, service: SpyService())
    let projects = [project("astro", "astro"), project("blog", "Blog")]
    preview.show(.results, projects: projects, projectSlug: "astro")
    let ids = preview.model.cards.map(\.id)
    let landed = preview.model.cards.map(\.landedAt)

    preview.retarget(projects: projects, projectSlug: "blog")

    #expect(preview.model.selectedProjectSlug == "blog")
    #expect(preview.model.cards.allSatisfy { $0.projectSlug == "blog" })
    #expect(preview.model.cards.map(\.id) == ids)
    #expect(preview.model.cards.map(\.landedAt) == landed)
  }

  // MARK: States

  @Test("Results by default; Dragging targets the panel with three files over the results; Empty has no cards")
  func stages() {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preview = DropZonePreviewController(directory: directory, service: SpyService())
    #expect(preview.stage == .results)

    preview.show(.dragging, projects: [], projectSlug: nil)
    #expect(preview.state.isDropTargeted)
    #expect(preview.model.draggedFileURLs.count == 3)
    #expect(preview.model.cards.count == 6)

    preview.show(.empty, projects: [], projectSlug: nil)
    #expect(!preview.state.isDropTargeted)
    #expect(preview.model.cards.isEmpty)
    #expect(preview.model.draggedFileURLs.isEmpty)

    preview.show(.results, projects: [], projectSlug: nil)
    #expect(!preview.state.isDropTargeted)
    #expect(preview.model.cards.count == 6)
  }

  @Test("Choosing the shown state again builds new cards whose landing counts from then")
  func showingAgainReplays() {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preview = DropZonePreviewController(directory: directory, service: SpyService())
    let first = Date(timeIntervalSince1970: 1_800_000_000)
    let second = first.addingTimeInterval(90)
    preview.show(.results, projects: [], projectSlug: nil, now: first)
    let ids = Set(preview.model.cards.map(\.id))

    preview.show(.results, projects: [], projectSlug: nil, now: second)

    #expect(Set(preview.model.cards.map(\.id)).isDisjoint(with: ids))
    #expect(preview.model.cards[2].landedAt == second)
    #expect(preview.model.cards[3].landedAt == second)
  }

  // MARK: The mini desktop

  @Test("340 × 420 shows whole; 560 × 800 shrinks to 62 % and says so")
  func scaleAndLabel() {
    typealias G = DropZonePreviewGeometry
    #expect(G.available == CGSize(width: 356, height: 496))
    #expect(G.scale(for: CGSize(width: 340, height: 420)) == 1)
    #expect(G.sizeLabel(for: CGSize(width: 340, height: 420)) == "340 × 420 pt")
    #expect(G.scale(for: CGSize(width: 560, height: 800)) < 1)
    #expect(G.sizeLabel(for: CGSize(width: 560, height: 800)) == "560 × 800 pt · 62%")
  }

  @Test("The panel sits at its corner, 12 from the desktop's edges and the menu bar")
  func panelCorners() {
    typealias G = DropZonePreviewGeometry
    let size = CGSize(width: 340, height: 420)
    let topRight = G.panelFrame(for: size, corner: .topRight)
    #expect(topRight.maxX == 368)
    #expect(topRight.minY == 28)
    let bottomLeft = G.panelFrame(for: size, corner: .bottomLeft)
    #expect(bottomLeft.minX == 12)
    #expect(bottomLeft.maxY == 524)
  }

  @Test("A grip drag adds what moved over the shrink to Size; the store keeps it in range")
  func gripDrag() throws {
    typealias G = DropZonePreviewGeometry
    let resized = G.resized(
      from: CGSize(width: 340, height: 420), by: CGSize(width: 31, height: -62), scale: 0.62)
    #expect(resized == CGSize(width: 390, height: 320))

    let defaults = try #require(UserDefaults(suiteName: "pinaxui-dz-preview-\(UUID().uuidString)"))
    let store = PreferencesStore(defaults: defaults)
    store.setDropZoneSize(
      G.resized(from: store.dropZoneSize, by: CGSize(width: 900, height: -900), scale: 1))
    #expect(store.dropZoneSize == CGSize(width: 560, height: 320))
  }

  @Test("Drop Zone's window is wider by the preview column and its margin; the other pages are not")
  func windowWidth() {
    typealias m = DesignMetrics.settings
    #expect(SettingsTab.dropZone.hasPreviewColumn)
    #expect(m.windowWidth(for: .dropZone) == 1146)
    #expect(m.windowWidth(for: .general) == m.sidebarWidth + m.contentWidth)
    #expect(m.windowWidth(for: .gallery) == m.sidebarWidth + m.contentWidth)
    #expect(m.windowWidth(for: .projects) == m.sidebarWidth + m.listColumnWidth + m.detailWidth)
  }

  @Test("The preview's panel reports nothing back; the app's panel still reports its layout")
  func previewPanelReportsNothing() async {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preview = DropZonePreviewController(directory: directory, service: SpyService())
    preview.show(.results, projects: [], projectSlug: nil)
    let appState = DropZoneViewState()
    let appModel = DropZoneModel(
      service: SpyService(),
      thumbnails: ThumbnailCache(cacheDirectory: directory.appendingPathComponent("app-thumbs")))

    var windows: [NSWindow] = []
    for root in [
      AnyView(DropZoneView(model: preview.model, state: preview.state, isPreview: true)),
      AnyView(DropZoneView(model: appModel, state: appState)),
    ] {
      let window = NSPanel(
        contentRect: NSRect(origin: .zero, size: DropZonePanel.defaultSize),
        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: root)
      window.orderFrontRegardless()
      windows.append(window)
    }
    defer { windows.forEach { $0.orderOut(nil) } }
    let deadline = Date().addingTimeInterval(5)
    while appState.layoutFrames.isEmpty, Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }

    #expect(!appState.layoutFrames.isEmpty)
    #expect(preview.state.layoutFrames.isEmpty)
    #expect(preview.state.motions.isEmpty)
  }
}

private final class SpyService: DropZoneService, @unchecked Sendable {
  private let lock = NSLock()
  private var uploadCount = 0
  private var moveCount = 0

  var uploads: Int { lock.withLock { uploadCount } }
  var moves: Int { lock.withLock { moveCount } }

  func projects() throws -> [Project] { [] }

  func prepare(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    PreparedDrop(fileURL: fileURL, projectSlug: projectSlug)
  }

  func upload(_ prepared: PreparedDrop, useOriginal: Bool) async throws -> UploadOutcome {
    lock.withLock { uploadCount += 1 }
    throw CancellationError()
  }

  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws {
    lock.withLock { moveCount += 1 }
  }
}

@MainActor
private final class CopySpy {
  var strings: [String] = []
}
