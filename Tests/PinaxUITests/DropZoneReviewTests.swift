import AppKit
import CatalogCore
import Foundation
import SwiftUI
@testable import PinaxUI
import Testing

/// Review: a ⇧ drop (or Always review) holds the images, each with a
/// compress switch, until Upload or Cancel. The service hands out a fixed
/// prepared file per name and records what it is asked; nothing leaves
/// the process.
@MainActor
@Suite struct DropZoneReviewTests {
  private typealias Status = DropZoneCardStatus

  // MARK: Entering

  @Test("A drop with ⇧ held prepares for review and sends nothing; a plain one uploads")
  func shiftDropReviews() async {
    let service = ReviewService()
    let model = makeModel(service)

    model.drop(fileURLs: [Self.url("IMG_2817.jpg")], modifiers: [.shift])
    await waitUntil { model.cards.first?.phase.isReview == true }
    #expect(model.cards[0].phase == .review(useOriginal: false))
    #expect(!model.cards[0].phase.isPending)
    #expect(model.isReviewing)
    #expect(service.reviewPrepares == 1)
    #expect(service.prepares == 0)
    #expect(service.uploads.isEmpty)
    #expect(model.uploadProgress == nil, "a card in review is not under way")
    #expect(model.uploadCounts == nil)
    #expect(Status(card: model.cards[0]).kind == .review)

    model.drop(fileURLs: [Self.url("plain.jpg")], modifiers: [.command])
    await waitUntil { service.uploads.count == 1 }
    #expect(service.prepares == 1)
    await waitUntil { model.cards.first.map { !$0.phase.isPending } == true }
    #expect(model.reviewCards.map(\.filename) == ["IMG_2817.jpg"], "a plain drop does not join")
    #expect(model.cards.map(\.filename) == ["plain.jpg", "IMG_2817.jpg"])
  }

  @Test("Always review holds a drop without ⇧, and a ⇧ drop during review joins the batch")
  func alwaysReviewsAndJoining() async {
    let service = ReviewService()
    let model = makeModel(service)
    model.alwaysReviews = true

    model.drop(fileURLs: [Self.url("IMG_2817.jpg")])
    await waitUntil { model.cards.first?.phase.isReview == true }
    model.alwaysReviews = false
    model.drop(fileURLs: [Self.url("IMG_2041.heic")], modifiers: [.shift])
    await waitUntil { model.cards.allSatisfy(\.phase.isReview) && model.cards.count == 2 }
    #expect(model.reviewCards.map(\.filename) == ["IMG_2041.heic", "IMG_2817.jpg"])
    #expect(service.uploads.isEmpty)
  }

  @Test("While ⇧ is held in a drag, or Always review is on, the drag says Drop to review")
  func dragTitle() {
    let model = makeModel(ReviewService())
    let files = [Self.url("a.jpg")]
    func title() -> String {
      DropZoneDragOverlay(fileURLs: files, projectName: nil, reviews: model.dropReviews).title
    }
    model.dragDidChange(fileURLs: files, modifiers: [])
    #expect(title() == "Drop to upload")
    model.dragDidChange(fileURLs: files, modifiers: [.shift])
    #expect(title() == "Drop to review")
    model.dragDidChange(fileURLs: files, modifiers: [])
    #expect(title() == "Drop to upload", "letting go of ⇧ turns it back")
    model.dragDidChange(fileURLs: files, modifiers: [.shift])
    model.dragDidEnd()
    #expect(title() == "Drop to upload")
    model.alwaysReviews = true
    #expect(title() == "Drop to review")
  }

  // MARK: The switches

  @Test("Each switch starts as its project would send it; a card with no copy is off for good")
  func switchDefaults() async {
    let service = ReviewService()
    let model = makeModel(service)
    model.drop(
      fileURLs: ["IMG_2817.jpg", "notes.jpg", "screenshot-0412.png"].map(Self.url),
      modifiers: [.shift])
    await waitUntil { model.cards.count == 3 && model.cards.allSatisfy(\.phase.isReview) }
    func card(_ name: String) -> DropZoneModel.UploadCard {
      model.cards.first { $0.filename == name }!
    }
    #expect(card("IMG_2817.jpg").phase == .review(useOriginal: false))
    #expect(card("notes.jpg").phase == .review(useOriginal: true), "its project does not compress")
    #expect(card("notes.jpg").canCompress)
    #expect(card("screenshot-0412.png").phase == .review(useOriginal: true))
    #expect(!card("screenshot-0412.png").canCompress)
    #expect(!DropZoneReviewSwitch.isEnabled(card("screenshot-0412.png")))

    model.setCompresses(card("notes.jpg").id, true)
    #expect(card("notes.jpg").phase == .review(useOriginal: false))
    model.setCompresses(card("screenshot-0412.png").id, true)
    #expect(card("screenshot-0412.png").phase == .review(useOriginal: true))
  }

  @Test("The total counts only what will be sent; Compress All and Use Originals act on every copy")
  func totalsAndAll() async {
    let service = ReviewService()
    let model = makeModel(service)
    model.drop(
      fileURLs: ["IMG_2817.jpg", "IMG_2041.heic", "banner-wide.jpg", "screenshot-0412.png"]
        .map(Self.url),
      modifiers: [.shift])
    await waitUntil { model.cards.count == 4 && model.cards.allSatisfy(\.phase.isReview) }
    let banner = model.cards.first { $0.filename == "banner-wide.jpg" }!.id
    model.setCompresses(banner, false)

    var summary = model.reviewSummary
    #expect(summary.text == "4 images · \(size(8_752_000)) → \(size(1_800_000))")
    #expect(summary.countText == "4 images")
    #expect(summary.canCompressAll && summary.canUseOriginals)

    model.setAllCompress(true)
    summary = model.reviewSummary
    #expect(summary.uploadBytes == 336_000 + 412_000 + 188_000 + 412_000)
    #expect(!summary.canCompressAll)
    #expect(summary.canUseOriginals)

    model.setAllCompress(false)
    summary = model.reviewSummary
    #expect(summary.uploadBytes == summary.sourceBytes)
    #expect(summary.text == "4 images · \(size(8_752_000))", "one size when nothing shrinks")
    #expect(summary.canCompressAll)
    #expect(!summary.canUseOriginals)
    #expect(model.cards.first { $0.filename == "screenshot-0412.png" }?.phase == .review(useOriginal: true))
  }

  // MARK: Cancel and Upload

  @Test("Cancel drops the batch and sends nothing; the other cards stay")
  func cancel() async {
    let service = ReviewService()
    let model = makeModel(service)
    model.drop(fileURLs: [Self.url("plain.jpg")])
    await waitUntil { model.cards.first.map { !$0.phase.isPending } == true }
    model.drop(fileURLs: ["IMG_2817.jpg", "IMG_2041.heic"].map(Self.url), modifiers: [.shift])
    await waitUntil { model.cards.count == 3 && model.reviewCards.allSatisfy(\.phase.isReview) }

    model.cancelReview()
    #expect(!model.isReviewing)
    #expect(model.cards.map(\.filename) == ["plain.jpg"])
    #expect(service.uploads.map(\.name) == ["plain.jpg"])
  }

  @Test("Upload sends each card as set, and the links are copied once the batch has landed")
  func uploadThenCopy() async {
    let service = ReviewService()
    let model = makeModel(service)
    var copied: [String] = []
    model.copiesURLsAutomatically = true
    model.urlCopier = { copied.append($0) }
    model.drop(
      fileURLs: ["IMG_2817.jpg", "banner-wide.jpg"].map(Self.url), modifiers: [.shift])
    await waitUntil { model.cards.count == 2 && model.cards.allSatisfy(\.phase.isReview) }
    model.setCompresses(model.cards.first { $0.filename == "banner-wide.jpg" }!.id, false)
    #expect(copied.isEmpty, "nothing is copied while the batch waits")

    service.holdUploads()
    model.uploadReviewed()
    #expect(!model.isReviewing)
    #expect(model.cards.allSatisfy { $0.phase == .uploading })
    #expect(model.uploadCounts?.total == 2)
    let banner = model.cards.first { $0.filename == "banner-wide.jpg" }!
    #expect(banner.compression == nil, "the original is what goes up")
    await waitUntil { service.uploads.count == 2 }
    #expect(copied.isEmpty, "nothing is copied before the batch lands")

    service.releaseUploads()
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(
      Set(service.uploads.map { "\($0.name) \($0.useOriginal)" })
        == ["IMG_2817.jpg false", "banner-wide.jpg true"])
    #expect(copied.count == 1)
    #expect(Set(copied[0].split(separator: "\n").map(String.init)) == [
      "https://img.example.com/IMG_2817.jpg", "https://img.example.com/banner-wide.jpg",
    ])
  }

  @Test("Upload while a card is still compressing sends it as soon as it is ready")
  func uploadWhileCompressing() async {
    let service = ReviewService()
    let model = makeModel(service)
    service.holdPreparing(for: "IMG_2041.heic")
    model.drop(
      fileURLs: ["IMG_2817.jpg", "IMG_2041.heic"].map(Self.url), modifiers: [.shift])
    await waitUntil {
      model.cards.first { $0.filename == "IMG_2817.jpg" }?.phase.isReview == true
        && model.cards.first { $0.filename == "IMG_2041.heic" }?.phase == .compressing
    }
    let summary = model.reviewSummary
    #expect(summary.count == 2)
    #expect(summary.sourceBytes == 4_600_000, "only ready cards have sizes")

    model.uploadReviewed()
    await waitUntil { service.uploads.count == 1 }
    #expect(service.uploads.map(\.name) == ["IMG_2817.jpg"])
    service.releasePreparing()
    await waitUntil { service.uploads.count == 2 }
    #expect(service.uploads.last.map { "\($0.name) \($0.useOriginal)" } == "IMG_2041.heic false")
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.cards.allSatisfy { if case .done = $0.phase { true } else { false } })
  }

  // MARK: The panel

  @Test("The countdown waits while cards are in review and starts once they land")
  func countdownWaits() async {
    let service = ReviewService()
    let model = makeModel(service)
    let clock = FakeClock()
    model.autoHideScheduler = clock.schedule
    model.autoHidesResultsAfter = 30

    model.drop(fileURLs: [Self.url("IMG_2817.jpg")], modifiers: [.shift])
    await waitUntil { model.cards.first?.phase.isReview == true }
    #expect(clock.pendingCount == 0)
    model.pointerDidEnter()
    model.pointerDidExit()
    #expect(clock.pendingCount == 0, "the pointer leaving does not start it either")
    clock.advance(by: 60)
    #expect(model.isWindowVisible)

    model.uploadReviewed()
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(clock.pendingCount == 1)
    clock.advance(by: 30)
    #expect(!model.isWindowVisible)
  }

  @Test("× only hides the panel: the batch is still there for Show Drop Zone")
  func closeKeepsBatch() async {
    let model = makeModel(ReviewService())
    model.drop(fileURLs: [Self.url("IMG_2817.jpg")], modifiers: [.shift])
    await waitUntil { model.cards.first?.phase.isReview == true }

    model.dismiss()
    #expect(!model.isWindowVisible)
    #expect(model.isReviewing)
    #expect(model.hasSessionUploads)
    model.presentSession()
    #expect(model.isWindowVisible)
    #expect(model.reviewCards.map(\.filename) == ["IMG_2817.jpg"])
    #expect(model.cards[0].phase == .review(useOriginal: false))
  }

  // MARK: The words

  @Test("A reviewed card says what each choice sends")
  func reviewWords() async {
    let model = makeModel(ReviewService())
    model.drop(
      fileURLs: ["IMG_2817.jpg", "IMG_2041.heic", "banner-wide.jpg", "screenshot-0412.png"]
        .map(Self.url),
      modifiers: [.shift])
    await waitUntil { model.cards.count == 4 && model.cards.allSatisfy(\.phase.isReview) }
    model.setCompresses(model.cards.first { $0.filename == "banner-wide.jpg" }!.id, false)
    func words(_ name: String) -> (list: String, shelf: String, meta: String, help: String?) {
      let card = model.cards.first { $0.filename == name }!
      let status = Status(card: card)
      return (
        status.listText, status.shelfText,
        ResultCardView(card: card, model: model, state: DropZoneViewState()).metaText,
        status.shelfHelp
      )
    }
    let forest = words("IMG_2817.jpg")
    #expect(forest.list == "\(size(4_600_000)) → \(size(336_000)) · −93%")
    #expect(forest.shelf == "\(size(336_000)) · −93%")
    #expect(forest.meta == "6000 × 4000 → 2048 × 1365")
    let heic = words("IMG_2041.heic")
    #expect(heic.list == "\(size(3_100_000)) → \(size(412_000)) · −87% · HEIC → JPEG")
    #expect(heic.help == "\(size(3_100_000)) → \(size(412_000)) · 2048 × 1536 · HEIC → JPEG")
    let banner = words("banner-wide.jpg")
    #expect(banner.list == "\(size(640_000)) → \(size(188_000))")
    #expect(banner.shelf == "\(size(640_000)) → \(size(188_000))")
    #expect(banner.meta == "1920 × 480")
    let shot = words("screenshot-0412.png")
    #expect(shot.list == "Original · not smaller")
    #expect(shot.shelf == "Not smaller")
    #expect(shot.meta == "2880 × 1800 · \(size(412_000))")
  }

  @Test("Always review is off by default and kept in its own key")
  func preference() throws {
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-review-\(UUID().uuidString)"))
    let store = PreferencesStore(defaults: defaults)
    #expect(!store.dropZoneAlwaysReviews)
    store.dropZoneAlwaysReviews = true
    #expect(defaults.bool(forKey: "pinax.dropZone.alwaysReviews"))
    #expect(PreferencesStore(defaults: defaults).dropZoneAlwaysReviews)
  }

  // MARK: Fixtures

  private func size(_ bytes: Int64) -> String { PinaxFormat.fileSize(bytes) }

  private static func url(_ name: String) -> URL {
    URL(fileURLWithPath: "/pinax-dz-review/\(name)")
  }

  private func makeModel(_ service: ReviewService) -> DropZoneModel {
    let thumbnails = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-review-\(UUID().uuidString)", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let model = DropZoneModel(service: service, thumbnails: thumbnails)
    model.copiesURLsAutomatically = false
    return model
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

/// Prepares each file by its name as the samples describe it, and lands
/// every upload. Preparing one name, or every upload, can be held.
private final class ReviewService: DropZoneService, @unchecked Sendable {
  struct Upload {
    let name: String
    let useOriginal: Bool
  }

  private let lock = NSLock()
  private var prepareCount = 0
  private var reviewPrepareCount = 0
  private var sent: [Upload] = []
  private var heldName: String?
  private var uploadsHeld = false

  var prepares: Int { lock.withLock { prepareCount } }
  var reviewPrepares: Int { lock.withLock { reviewPrepareCount } }
  var uploads: [Upload] { lock.withLock { sent } }

  func holdPreparing(for name: String) { lock.withLock { heldName = name } }
  func releasePreparing() { lock.withLock { heldName = nil } }
  func holdUploads() { lock.withLock { uploadsHeld = true } }
  func releaseUploads() { lock.withLock { uploadsHeld = false } }

  func projects() throws -> [Project] { [] }

  func prepare(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    lock.withLock { prepareCount += 1 }
    return PreparedDrop(fileURL: fileURL, projectSlug: projectSlug)
  }

  func prepareForReview(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    lock.withLock { reviewPrepareCount += 1 }
    let name = fileURL.lastPathComponent
    await hold { self.heldName != name }
    func copy(
      _ sourceBytes: Int64, _ sw: Int, _ sh: Int, _ bytes: Int64, _ w: Int, _ h: Int,
      mime: String = "image/jpeg"
    ) -> CardCompression {
      CardCompression(
        sourceByteSize: sourceBytes, sourceWidth: sw, sourceHeight: sh, sourceMime: mime,
        byteSize: bytes, width: w, height: h, mime: "image/jpeg", options: .default)
    }
    switch name {
    case "IMG_2817.jpg":
      return PreparedDrop(
        fileURL: fileURL, projectSlug: projectSlug,
        compression: copy(4_600_000, 6000, 4000, 336_000, 2048, 1365))
    case "IMG_2041.heic":
      return PreparedDrop(
        fileURL: fileURL, projectSlug: projectSlug,
        compression: copy(3_100_000, 4032, 3024, 412_000, 2048, 1536, mime: "image/heic"))
    case "banner-wide.jpg":
      return PreparedDrop(
        fileURL: fileURL, projectSlug: projectSlug,
        compression: copy(640_000, 1920, 480, 188_000, 1920, 480))
    case "notes.jpg":
      return PreparedDrop(
        fileURL: fileURL, projectSlug: projectSlug,
        compression: copy(900_000, 3000, 2000, 200_000, 2048, 1365), compressesByDefault: false)
    default:
      return PreparedDrop(
        fileURL: fileURL, projectSlug: projectSlug, sourceByteSize: 412_000, sourceWidth: 2880,
        sourceHeight: 1800, originalReason: .notSmaller)
    }
  }

  func upload(_ prepared: PreparedDrop, useOriginal: Bool) async throws -> UploadOutcome {
    let name = prepared.fileURL.lastPathComponent
    lock.withLock { sent.append(Upload(name: name, useOriginal: useOriginal)) }
    await hold { !self.uploadsHeld }
    return UploadOutcome(
      sha256: String(repeating: "0", count: 63) + "\(name.count % 10)",
      key: name, url: "https://img.example.com/\(name)", mime: "image/jpeg",
      originalFilename: name, byteSize: 100_000, width: 2048, height: 1365,
      uploadedAt: "2026-08-22T00:00:00Z", deduplicated: false, dryRun: false)
  }

  /// Gives up after ten seconds, so a broken test fails instead of hanging.
  private func hold(until open: @escaping () -> Bool) async {
    for _ in 0..<2_000 {
      if lock.withLock(open) { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws {}
}
