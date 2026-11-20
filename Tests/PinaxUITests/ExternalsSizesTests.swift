import AppKit
@testable import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// Sizes from what a Load fetched — and only
/// from that — in the inspector, the table and the confirmation sheet; the
/// large line; Size dropping before Used In; the log's headings and
/// planned rows.
@MainActor
@Suite struct ExternalsSizesTests {
  static let rows: [ExternalReference] = [
    ExternalsPreviewsTests.row("posts/a.md#L1", "https://one.example.org/big.png"),
    ExternalsPreviewsTests.row("posts/a.md#L2", "https://one.example.org/small.png"),
    ExternalsPreviewsTests.row("posts/b.md#L1", "https://two.example.net/x.png"),
    ExternalsPreviewsTests.row("posts/b.md#L2", "https://two.example.net/y.png"),
  ]

  private struct StaticExternals: ExternalUsageReading {
    let rows: [ExternalReference]
    func externalReferences(project: String?) async throws -> ExternalReferenceSet {
      ExternalReferenceSet(references: rows, projectSources: [:])
    }
  }

  /// Serves a PNG per URL, padded to the byte count its name asks for, and
  /// counts every request.
  final class Host: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [URL] = []
    var urls: [URL] { lock.withLock { asked } }

    static let sizes = ["big.png": 1_000_000, "small.png": 999_999, "x.png": 2_000, "y.png": 3_000]

    func fetch(_ url: URL) async throws -> Data {
      lock.withLock { asked.append(url) }
      var data = pngData(width: 40, height: 30)
      let wanted = Self.sizes[url.lastPathComponent] ?? data.count
      // Trailing bytes after IEND: ImageIO still reads the image.
      if wanted > data.count { data.append(Data(count: wanted - data.count)) }
      return data
    }
  }

  private func model(_ host: Host, cache: URL) async -> ExternalsModel {
    let model = ExternalsModel(
      reader: StaticExternals(rows: Self.rows),
      thumbnails: ThumbnailCache(cacheDirectory: cache, fetcher: { try await host.fetch($0) }))
    await model.selectProject("blog")
    model.domain = .other
    return model
  }

  private func until(seconds: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func row(_ name: String, in model: ExternalsModel) throws -> ExternalReference {
    try #require(model.groups.flatMap(\.rows).first { $0.rawURL.hasSuffix("/" + name) })
  }

  private static func cacheDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pinaxui-m6-\(UUID().uuidString)")
  }

  // MARK: - Data

  @Test("A Load brings back bytes, pixels and type; a cache hit has them too, with no request")
  func loadCarriesInfo() async throws {
    let host = Host()
    let cache = Self.cacheDirectory()
    defer { try? FileManager.default.removeItem(at: cache) }
    let model = await model(host, cache: cache)
    let big = try row("big.png", in: model)
    // Not loaded: no size, and nothing asked — drawing and reading sizes
    // ask nothing of the host.
    _ = model.selectionSizes(try #require(model.selectionSummary(Set(model.groups.flatMap(\.rows).map(\.id)))))
    _ = ExternalsView.cornerLabel(big, state: model.thumbnail(big))
    #expect(model.imageInfo(big) == nil)
    #expect(host.urls.isEmpty)

    model.loadPreview(big)
    await until { model.imageInfo(big) != nil }
    let info = try #require(model.imageInfo(big))
    #expect(info.bytes == 1_000_000)
    #expect(info.pixelWidth == 40 && info.pixelHeight == 30)
    #expect(info.type == .png)
    #expect(info.typeName == "PNG")
    #expect(host.urls.count == 1)

    // A new cache over the same folder (memory empty): the record beside
    // the thumbnail answers, and the host is not asked again.
    let again = await self.model(host, cache: cache)
    let bigAgain = try row("big.png", in: again)
    again.loadPreview(bigAgain)
    await until { again.imageInfo(bigAgain) != nil }
    #expect(again.imageInfo(bigAgain) == info)
    #expect(host.urls.count == 1)
  }

  @Test("A thumbnail cached without a size record asks its original once more, then never again")
  func backfillsOldCache() async throws {
    let host = Host()
    let cache = Self.cacheDirectory()
    defer { try? FileManager.default.removeItem(at: cache) }
    let first = await model(host, cache: cache)
    let big = try row("big.png", in: first)
    first.loadPreview(big)
    await until { first.imageInfo(big) != nil }
    // What an older cache looks like: the thumbnail without its record.
    let records = (FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)?.allObjects ?? [])
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    #expect(records.count == 1)
    for record in records { try FileManager.default.removeItem(at: record) }

    let old = await model(host, cache: cache)
    let bigOld = try row("big.png", in: old)
    old.loadPreview(bigOld)
    await until { old.imageInfo(bigOld) != nil }
    #expect(old.imageInfo(bigOld)?.bytes == 1_000_000)
    #expect(host.urls.count == 2)

    let later = await model(host, cache: cache)
    let bigLater = try row("big.png", in: later)
    later.loadPreview(bigLater)
    await until { later.imageInfo(bigLater) != nil }
    #expect(later.imageInfo(bigLater)?.bytes == 1_000_000)
    #expect(host.urls.count == 2, "the record written by the second ask answers the third")
  }

  @Test("The grid's corner reads size · type once loaded, the URL's extension before")
  func cornerLabel() throws {
    let row = Self.rows[0]
    #expect(ExternalsView.cornerLabel(row, state: nil) == "PNG")
    let image = try #require(ThumbnailCache.thumbnail(from: pngData(width: 4, height: 4)))
    let info = RemoteImageInfo(bytes: 412_000, pixelWidth: 4, pixelHeight: 4, typeIdentifier: "public.jpeg")
    #expect(
      ExternalsView.cornerLabel(row, state: .loaded(image, info))
        == "\(PinaxFormat.fileSize(412_000)) · JPEG")
  }

  // MARK: - several rows

  @Test("Several rows: the loaded total, the not-loaded count, each host's subtotal and large mark")
  func selectionSizes() async throws {
    let host = Host()
    let cache = Self.cacheDirectory()
    defer { try? FileManager.default.removeItem(at: cache) }
    let model = await model(host, cache: cache)
    let all = Set(model.groups.flatMap(\.rows).map(\.id))
    var sizes = model.selectionSizes(try #require(model.selectionSummary(all)))
    #expect(sizes.loadedBytes == nil)
    #expect(sizes.notLoaded == 4)
    #expect(sizes.notLoadedText == "4 not loaded")

    let big = try row("big.png", in: model)
    let x = try row("x.png", in: model)
    model.loadPreview(big)
    model.loadPreview(x)
    await until { model.imageInfo(big) != nil && model.imageInfo(x) != nil }
    sizes = model.selectionSizes(try #require(model.selectionSummary(all)))
    #expect(sizes.loadedBytes == 1_002_000)
    #expect(sizes.notLoaded == 2)
    #expect(sizes.hasLarge)
    #expect(sizes.hostBytes == ["one.example.org": 1_000_000, "two.example.net": 2_000])
    #expect(sizes.largeHosts == ["one.example.org"])

    let small = try row("small.png", in: model)
    let y = try row("y.png", in: model)
    model.loadPreview(small)
    model.loadPreview(y)
    await until { model.imageInfo(small) != nil && model.imageInfo(y) != nil }
    sizes = model.selectionSizes(try #require(model.selectionSummary([small.id, y.id])))
    #expect(sizes.notLoaded == 0)
    #expect(!sizes.hasLarge, "999,999 bytes is under the line")
    #expect(sizes.loadedBytes == 1_002_999)
  }

  // MARK: - the large line

  @Test("The large line: 999,999 bytes is not large, 1,000,000 is")
  func largeLine() {
    #expect(PinaxFormat.largeImageBytes == 1_000_000)
    #expect(!PinaxFormat.isLarge(999_999))
    #expect(PinaxFormat.isLarge(1_000_000))
    #expect(!RemoteImageInfo(bytes: 999_999, pixelWidth: 1, pixelHeight: 1, typeIdentifier: "public.png").isLarge)
    #expect(RemoteImageInfo(bytes: 1_000_000, pixelWidth: 1, pixelHeight: 1, typeIdentifier: "public.png").isLarge)
    let image = ExternalMigrationConfirmation.Image(url: "u", filename: "f", host: "h", bytes: 999_999)
    #expect(!image.isLarge)
  }

  // MARK: - Size before Used In

  @Test("Size goes before Used In, and a row with both fits the width Size needs")
  func sizeColumnGoesFirst() throws {
    #expect(ExternalsView.showsSize(tableWidth: 0))
    #expect(ExternalsView.sizeMinimumWidth > ExternalsView.usedInMinimumWidth)
    for width in stride(from: CGFloat(300), through: 700, by: 1) {
      if ExternalsView.showsSize(tableWidth: width) {
        #expect(ExternalsView.showsUsedIn(tableWidth: width), "Size shown without Used In at \(width)")
      }
    }
    #expect(!ExternalsView.showsSize(tableWidth: ExternalsView.sizeMinimumWidth - 1))
    #expect(ExternalsView.showsUsedIn(tableWidth: ExternalsView.sizeMinimumWidth - 1))
    #expect(ExternalsView.showsSize(tableWidth: ExternalsView.sizeMinimumWidth))
    // A loaded row at the narrowest width that keeps Size, less the rows'
    // 8 pt insets, with both columns.
    let image = try #require(ThumbnailCache.thumbnail(from: pngData(width: 4, height: 4)))
    let info = RemoteImageInfo(bytes: 999_000_000, pixelWidth: 4, pixelHeight: 4, typeIdentifier: "public.png")
    let width = ExternalsView.sizeMinimumWidth - 16
    let row = ExternalListRow(row: ExternalsMigrationTests.rows[0], state: .loaded(image, info))
      .environment(\.externalsShowsUsedIn, true)
      .environment(\.externalsShowsSize, true)
    let fitted = NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: width, height: 100)).width
    #expect(fitted <= width)
  }

  // MARK: - the sheet

  nonisolated static let a = "https://upload.wikimedia.org/a.jpg"
  nonisolated static let b = "https://i.imgur.com/b.png"
  nonisolated static let c = "https://i.imgur.com/c.png"
  nonisolated static let same = "https://i.imgur.com/c-copy.png"
  nonisolated static let reused = "https://i.imgur.com/r.png"

  static func preparation(reused reusedCount: Int = 1) -> ExternalMigrationPreparation {
    func download(_ url: String, _ sha: Character, _ bytes: Int64) -> RunEvent {
      .downloadFinished(
        DownloadFinishedEvent(
          url: url, host: URL(string: url)!.host!, sha256: String(repeating: sha, count: 64), bytes: bytes,
          mime: "image/png", filename: URL(string: url)!.lastPathComponent, sniffed: false, cachePath: "x"))
    }
    func plan(_ url: String, reusing: Int64? = nil) -> RunEvent {
      .migrationPlanned(MigrationPlannedEvent(url: url, sha256: "s", key: "k", newURL: "n", reusedAssetID: reusing))
    }
    var migration = ExternalMigrationSummary()
    migration.migratable = .init(images: 3, links: 4)
    migration.reused = .init(images: reusedCount, links: reusedCount)
    migration.skipped = .init(images: 1, links: 1)
    migration.bytes = 1_814_000
    migration.files = [.init(project: "astro", source: "astro-blog", files: 3, edits: 4)]
    migration.sampleKeys = ["202610/theflaminglips-ad044115ec92.jpg"]
    migration.hosts = [
      .init(host: "i.imgur.com", links: 3, urls: 3, tips: []),
      .init(host: "upload.wikimedia.org", links: 1, urls: 1, tips: ["Usually asks for attribution"]),
      .init(host: "m.media-amazon.com", links: 1, urls: 1, tips: ["404 · skipped"]),
    ]
    var summary = RewriteRunSummary()
    summary.migration = migration
    let events: [RunEvent] = [
      download(b, "b", 2_000), download(a, "a", 1_800_000), download(c, "c", 12_000),
      download(same, "c", 12_000), download(reused, "r", 50_000),
      .downloadFailed(
        DownloadFailedEvent(url: "https://m.media-amazon.com/x.jpg", host: "m.media-amazon.com", reason: .httpStatus,
          status: 404)),
      plan(b), plan(a), plan(c), plan(same), plan(reused, reusing: 3),
    ]
    return ExternalMigrationPreparation(
      result: ExternalMigrationResult(runID: 7, state: .finished, summary: summary, events: events),
      bucket: "image-hosting", storageKind: "r2")
  }

  @Test("Sheet: the images to upload, largest first, once per content, reused left out; the total and the closed line")
  func sheetImages() {
    let sheet = ExternalMigrationConfirmation.make(Self.preparation())
    #expect(sheet.images.map(\.url) == [Self.a, Self.c, Self.b])
    #expect(sheet.imagesBytes == 1_814_000)
    #expect(sheet.imagesTitle == "3 Images")
    #expect(sheet.imagesNote == "1 over \(PinaxFormat.fileSize(1_000_000))")
    var small = Self.preparation()
    small.result = ExternalMigrationResult(
      runID: 7, state: .finished, summary: small.result.summary,
      events: small.result.events.filter {
        if case let .downloadFinished(d) = $0 { return d.url != Self.a }
        return true
      })
    #expect(ExternalMigrationConfirmation.make(small).imagesNote == nil, "no large image: the count alone")
  }

  @Test("Sheet: hosts' subtotals, large marked, a broken host's left empty")
  func sheetHosts() {
    let hosts = ExternalMigrationConfirmation.make(Self.preparation()).hosts
    #expect(hosts.map(\.bytes) == [14_000, 1_800_000, nil])
    #expect(hosts.map(\.hasLarge) == [false, true, false])
  }

  @Test("Sheet: rows read None for zero, the bucket's kind as a tag, and a key's runs rejoin to the key")
  func sheetLines() {
    let lines = ExternalMigrationConfirmation.make(Self.preparation(reused: 0)).lines
    let values = Dictionary(uniqueKeysWithValues: lines.map { ($0.label, $0) })
    #expect(values["Already in library"]?.value == "None")
    #expect(values["Upload"]?.groups.first?.map(\.style) == [.figure, .unit])
    #expect(values["Bucket"]?.tag == "R2")
    #expect(lines.map(\.tone) == [.upload, .reused, .skipped, .files, .bucket, .keys])
    let key = "202610/theflaminglips-ad044115ec92.jpg"
    #expect(values["New keys"]?.value == key)
    #expect(
      ExternalMigrationConfirmation.keySegments(key).map(\.style) == [.faint, .plain, .hash, .faint])
    #expect(ExternalMigrationConfirmation.keySegments(key)[2].text == "-ad044115ec92")
    #expect(ExternalMigrationConfirmation.Line.text(ExternalMigrationConfirmation.keySegments("plain")) == "plain")
    var none = Self.preparation()
    var summary = none.result.summary
    summary.migration?.migratable = .init()
    summary.migration?.files = []
    none.result = ExternalMigrationResult(runID: 7, state: .finished, summary: summary, events: none.result.events)
    let empty = Dictionary(
      uniqueKeysWithValues: ExternalMigrationConfirmation.make(none).lines.map { ($0.label, $0.value) })
    #expect(empty["Upload"] == "None")
    #expect(empty["Files to change"] == "None")
  }

  // MARK: - the log

  private static func record(_ seq: Int, _ event: RunEvent) -> RunEventRecord {
    RunEventRecord(seq: seq, at: "2026-10-30T19:23:01Z", level: event.level, event: event)
  }

  @Test("Log: a preparation's headings say what was done; the start joins the first, the finish the last")
  func preparationSections() {
    let events: [RunEvent] = [
      .migrationStarted(MigrationStartedEvent(targets: [], backend: "r2", hosts: 2)),
      Self.preparation().result.events[0],
      .sourceStatus(SourceStatusEvent(project: "astro", source: "astro-blog", git: .clean)),
      Self.preparation().result.events[6],
      .filePlanned(FilePlannedEvent(project: "astro", source: "astro-blog", path: "a.md", sha256: "s", edits: 1,
        editsDigest: "d")),
      .runFinished(RewriteRunSummary()),
    ]
    let sections = ActivityPanelModel.sections(
      events.enumerated().map { Self.record($0.offset, $0.element) }, kind: .externalMigrate, dryRun: true)
    #expect(sections.map(\.title) == ["Downloaded and checked", "When you migrate"])
    #expect(sections.map { $0.records.map(\.seq) } == [[0, 1, 2], [3, 4, 5]])
    #expect(ActivityPanelModel.isPlanned(events[3]) && ActivityPanelModel.isPlanned(events[4]))
    #expect(!ActivityPanelModel.isPlanned(events[1]))
    #expect(ActivityPanelModel.isSummary(events[5]))
    #expect(!ActivityPanelModel.hasLargeDetail(events[1]), "2,000 bytes")
    #expect(ActivityPanelModel.hasLargeDetail(Self.preparation().result.events[1]), "1.8 MB")
  }

  @Test("Log: an apply's headings are Uploaded then Rewritten; a rewrite's are Checked then When you apply")
  func applySections() {
    let upload = RunEvent.uploadFinished(
      UploadFinishedEvent(url: Self.a, key: "k", newURL: "n", assetID: 1, bytes: 3))
    let written = RunEvent.fileWritten(
      FileWrittenEvent(project: "astro", source: "s", path: "a.md", beforeSHA256: "a", afterSHA256: "b", edits: 1,
        backupPath: nil))
    let rescan = RunEvent.rescanFinished(RescanFinishedEvent(project: "astro", refs: 1, files: 1))
    let apply = ActivityPanelModel.sections(
      [upload, written, rescan, .runFinished(RewriteRunSummary())].enumerated().map { Self.record($0.offset, $0.element) },
      kind: .externalMigrate, dryRun: false)
    #expect(apply.map(\.title) == ["Uploaded", "Rewritten"])
    #expect(apply.map(\.records.count) == [1, 3])

    let clean = RunEvent.sourceStatus(SourceStatusEvent(project: "blog", source: "s", git: .clean))
    let planned = RunEvent.filePlanned(
      FilePlannedEvent(project: "blog", source: "s", path: "a.md", sha256: "s", edits: 1, editsDigest: "d"))
    let preview = ActivityPanelModel.sections(
      [clean, planned].enumerated().map { Self.record($0.offset, $0.element) }, kind: .rewrite, dryRun: true)
    #expect(preview.map(\.title) == ["Checked", "When you apply"])
  }
}
