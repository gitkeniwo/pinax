import AppKit
import CatalogCore
import Foundation
import SwiftUI
@testable import PinaxUI
import Testing

/// Cards of recompressed uploads: the compressing phase, what the card knows
/// and when, and its words. The service is stepped by hand, so each phase
/// holds until the test lets it go; nothing leaves the process.
@MainActor
@Suite struct DropZoneCompressionCardTests {
  private typealias Status = DropZoneCardStatus
  private typealias Part = DropZoneLayoutKey.Part

  // MARK: The flow

  @Test("compressing → uploading → done; the sizes arrive with uploading and stay")
  func phaseOrder() async throws {
    let service = SteppedService()
    service.prepared = Self.compression()
    service.outcome = Self.outcome(facts: Self.facts(), bytes: 412_000)
    let model = makeModel(service)

    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/photo.jpg")])
    // From here to the end of the upload the progress must never clear.
    var counts: [UploadCounts?] = []
    model.onUploadCountsChange = { counts.append($0) }
    await waitUntil { model.cards.first?.phase == .compressing && service.prepares == 1 }
    #expect(model.cards[0].phase == .compressing)
    #expect(model.cards[0].phase.isPending)
    #expect(model.cards[0].compression == nil)
    #expect(model.uploadProgress == "Uploading photo.jpg…")
    #expect(model.uploadCounts != nil)
    #expect(meta(model.cards[0], model) == "")
    #expect(service.uploads == 0, "nothing is sent while compressing")

    service.finishPreparing()
    await waitUntil { model.cards.first?.phase == .uploading }
    #expect(model.cards[0].compression == Self.compression())
    #expect(
      meta(model.cards[0], model)
        == "\(PinaxFormat.fileSize(3_100_000)) → \(PinaxFormat.fileSize(412_000))")
    #expect(model.uploadCounts != nil)
    #expect(!counts.isEmpty)
    #expect(counts.allSatisfy { $0 != nil }, "\(counts)")

    service.finishUploading()
    await waitUntil { model.cards.first?.phase.isPending == false }
    #expect(model.cards[0].compression == Self.compression())
    #expect(model.uploadProgress == nil)
    #expect(model.uploadCounts == nil)
    #expect(service.usedOriginal == [false])
    #expect(
      meta(model.cards[0], model)
        == "2048 × 1536 · \(PinaxFormat.fileSize(3_100_000)) → \(PinaxFormat.fileSize(412_000))")
  }

  @Test("A file that is not compressed shows no sizes while uploading, and its landed card is as before")
  func uncompressed() async throws {
    let service = SteppedService()
    service.outcome = Self.outcome(facts: nil, bytes: 96_000)
    let model = makeModel(service)
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/photo.jpg")])
    service.finishPreparing()
    await waitUntil { model.cards.first?.phase == .uploading }
    #expect(model.cards[0].compression == nil)
    #expect(meta(model.cards[0], model) == "")
    service.finishUploading()
    await waitUntil { model.cards.first?.phase.isPending == false }
    let status = Status(card: model.cards[0], now: model.cards[0].landedAt ?? Date())
    #expect(status.listText == "Just now")
    #expect(status.shelfText == "Just now")
    #expect(status.shelfHelp == status.help)
    #expect(meta(model.cards[0], model) == "2048 × 1536 · \(PinaxFormat.fileSize(96_000))")
  }

  @Test("A compressed copy already in the library says so, with its before → after")
  func reusedCopy() async throws {
    let service = SteppedService()
    // A copy found by its original: no new copy is made while preparing.
    service.outcome = Self.outcome(facts: Self.facts(), bytes: 412_000, deduplicated: true)
    let model = makeModel(service)
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/photo.jpg")])
    service.finishPreparing()
    service.finishUploading()
    await waitUntil { model.cards.first?.phase.isPending == false }
    let card = model.cards[0]
    #expect(Status(card: card).listText == "Already in library")
    #expect(Status(card: card).shelfText == "In library")
    #expect(card.compression == Self.compression())
    #expect(meta(card, model).hasSuffix(Self.compression().sizeChange))
  }

  @Test("What was stored has the last word: an original that was reused drops the prepared sizes")
  func storedOriginalDropsSizes() async throws {
    let service = SteppedService()
    service.prepared = Self.compression()
    service.outcome = Self.outcome(facts: nil, bytes: 3_100_000, deduplicated: true)
    let model = makeModel(service)
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/photo.jpg")])
    service.finishPreparing()
    service.finishUploading()
    await waitUntil { model.cards.first?.phase.isPending == false }
    #expect(model.cards[0].compression == nil)
  }

  @Test("The same bytes dropped again move the card up with the later drop's sizes")
  func mergedDuplicateTakesSizes() async throws {
    let service = SteppedService()
    service.outcome = Self.outcome(facts: nil, bytes: 412_000)
    service.finishPreparing()
    service.finishUploading()
    let model = makeModel(service)
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/photo.jpg")])
    await waitUntil { model.cards.first?.phase.isPending == false }
    let first = model.cards[0].id
    #expect(model.cards[0].compression == nil)

    service.outcome = Self.outcome(facts: Self.facts(), bytes: 412_000, deduplicated: true)
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/photo-again.jpg")])
    await waitUntil { model.cards.count == 1 && !model.cards[0].phase.isPending }
    #expect(model.cards.map(\.id) == [first])
    #expect(model.cards[0].compression == Self.compression())
  }

  @Test("A failed upload fails its card, and Retry starts again without the old sizes")
  func retryStartsClean() async throws {
    let service = SteppedService()
    service.prepared = Self.compression()
    service.outcome = nil
    service.finishPreparing()
    service.finishUploading()
    let model = makeModel(service)
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/photo.jpg")])
    await waitUntil { model.cards.first?.phase.isPending == false }
    #expect(Status(card: model.cards[0]).kind == .failed)

    service.holdPreparing()
    model.retry(model.cards[0].id)
    #expect(model.cards[0].compression == nil)
    await waitUntil { model.cards[0].phase == .compressing }
    #expect(model.cards[0].compression == nil)
    service.finishPreparing()
  }

  // MARK: Words

  @Test("Compressing, and a landed copy's time, saving and converted format, in both layouts")
  func statusWords() {
    let now = Date()
    let compressing = Status(card: card(.compressing), now: now)
    #expect(compressing.kind == .compressing)
    #expect(compressing.accessibilityLabel == "Compressing")
    #expect(compressing.listText == "Compressing…")
    #expect(compressing.shelfText == "Compressing")
    #expect(compressing.help == nil)

    let outcome = Self.outcome(facts: Self.facts(), bytes: 412_000)
    let same = Status(
      card: card(.done(outcome), landedAt: now, compression: Self.compression()), now: now)
    #expect(same.kind == .uploaded)
    #expect(same.listText == "Just now · −87%")
    #expect(same.shelfText == "Just now · −87%")
    #expect(same.help == outcome.url)
    #expect(
      same.shelfHelp
        == "2048 × 1536 · \(Self.compression().sizeChange)\n\(outcome.url)")

    let converted = Status(
      card: card(.done(outcome), landedAt: now, compression: Self.compression(from: "image/heic")),
      now: now)
    #expect(converted.listText == "Just now · −87% · HEIC → JPEG")
    #expect(converted.shelfText == "Just now · −87%")
    #expect(
      converted.shelfHelp
        == "2048 × 1536 · \(Self.compression().sizeChange) · HEIC → JPEG\n\(outcome.url)")

    // The drawn words read the same as the strings.
    #expect(Status(card: card(.waiting)).savings == nil)
    #expect(same.savings == Status.Savings(percent: "−87%", isSaving: true, formatChange: nil))
  }

  @Test("The percentage: a larger converted copy reads +, no change reads nothing, never −100%")
  func percentages() {
    func percent(_ source: Int64, _ bytes: Int64) -> String? {
      Self.compression(sourceBytes: source, bytes: bytes).percentChange
    }
    #expect(percent(1_000_000, 90_000) == "−91%")
    #expect(percent(1_000_000, 1_120_000) == "+12%")
    #expect(percent(1_000_000, 1_000_000) == nil)
    #expect(percent(1_000_000, 998_000) == nil)
    #expect(percent(100_000_000, 1_000) == "−99%")
    #expect(percent(0, 1_000) == nil)
    #expect(!Self.compression(sourceBytes: 1_000_000, bytes: 1_120_000).isSmaller)

    let now = Date()
    let unchanged = Status(
      card: card(
        .done(Self.outcome(facts: nil, bytes: 1)), landedAt: now,
        compression: Self.compression(from: "image/heic", sourceBytes: 1_000, bytes: 1_000)),
      now: now)
    #expect(unchanged.listText == "Just now · HEIC → JPEG")
    #expect(unchanged.shelfText == "Just now")
  }

  @Test("The tooltip names the longest edge, the quality and what happened to metadata")
  func settingsTooltip() {
    #expect(
      Self.compression().settingsSummary == "Longest edge 2048 · Quality 85% · metadata removed")
    #expect(
      Self.compression(
        options: CompressionOptions(longestEdge: nil, quality: 60, removesMetadata: false)
      ).settingsSummary == "Not resized · Quality 60% · metadata kept")
  }

  @Test("The synthetic init takes the sizes; without them there are none")
  func syntheticInit() {
    #expect(card(.uploading).compression == nil)
    #expect(card(.uploading, compression: Self.compression()).compression == Self.compression())
  }

  // MARK: Fixtures

  private static func compression(
    from sourceMime: String = "image/jpeg", sourceBytes: Int64 = 3_100_000,
    bytes: Int64 = 412_000, options: CompressionOptions = .default
  ) -> CardCompression {
    CardCompression(
      sourceByteSize: sourceBytes, sourceWidth: 4032, sourceHeight: 3024, sourceMime: sourceMime,
      byteSize: bytes, width: 2048, height: 1536, mime: "image/jpeg", options: options)
  }

  /// The stored facts matching `compression()`.
  private static func facts() -> UploadCompressionFacts {
    UploadCompressionFacts(
      options: .default, sourceSHA256: String(repeating: "0d", count: 32),
      sourceByteSize: 3_100_000, sourceWidth: 4032, sourceHeight: 3024, sourceMime: "image/jpeg",
      formatChanged: false)
  }

  private static func outcome(
    facts: UploadCompressionFacts?, bytes: Int64, deduplicated: Bool = false
  ) -> UploadOutcome {
    UploadOutcome(
      sha256: String(repeating: "0e", count: 32), key: "blog/photo.jpg",
      url: "https://img.example.com/blog/photo.jpg", mime: "image/jpeg",
      originalFilename: "photo.jpg", byteSize: bytes, width: 2048, height: 1536,
      uploadedAt: "2026-08-22T00:00:00Z", deduplicated: deduplicated, dryRun: false,
      compression: facts)
  }

  private func card(
    _ phase: DropZoneModel.UploadCard.Phase, landedAt: Date? = nil,
    compression: CardCompression? = nil
  ) -> DropZoneModel.UploadCard {
    DropZoneModel.UploadCard(
      filename: "photo.jpg", fileURL: URL(fileURLWithPath: "/pinax-dz/photo.jpg"), phase: phase,
      thumbnail: nil, landedAt: landedAt, projectSlug: nil, compression: compression)
  }

  private func meta(_ card: DropZoneModel.UploadCard, _ model: DropZoneModel) -> String {
    ResultCardView(card: card, model: model, state: DropZoneViewState()).metaText
  }

  private func makeModel(_ service: SteppedService) -> DropZoneModel {
    let thumbnails = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-squeeze-\(UUID().uuidString)", isDirectory: true),
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

/// Both steps hold until told to go on. `prepared` is the copy preparing
/// makes; `outcome` is what the upload lands with, or nil to fail it.
private final class SteppedService: DropZoneService, @unchecked Sendable {
  struct Refused: Error {}

  private let lock = NSLock()
  private var _prepared: CardCompression?
  private var _outcome: UploadOutcome?
  private var mayPrepare = false
  private var mayUpload = false
  private var prepareCount = 0
  private var originals: [Bool] = []

  var prepared: CardCompression? {
    get { lock.withLock { _prepared } }
    set { lock.withLock { _prepared = newValue } }
  }
  var outcome: UploadOutcome? {
    get { lock.withLock { _outcome } }
    set { lock.withLock { _outcome = newValue } }
  }
  var prepares: Int { lock.withLock { prepareCount } }
  var uploads: Int { lock.withLock { originals.count } }
  var usedOriginal: [Bool] { lock.withLock { originals } }

  func finishPreparing() { lock.withLock { mayPrepare = true } }
  func holdPreparing() { lock.withLock { mayPrepare = false } }
  func finishUploading() { lock.withLock { mayUpload = true } }

  func projects() throws -> [Project] { [] }

  func prepare(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    lock.withLock { prepareCount += 1 }
    await hold { self.mayPrepare }
    return PreparedDrop(fileURL: fileURL, projectSlug: projectSlug, compression: prepared)
  }

  func upload(_ drop: PreparedDrop, useOriginal: Bool) async throws -> UploadOutcome {
    lock.withLock { originals.append(useOriginal) }
    await hold { self.mayUpload }
    guard let outcome else { throw Refused() }
    return outcome
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
