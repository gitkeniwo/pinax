import Foundation
import GRDB
import Testing

@testable import CatalogCore

/// A measuring run over a temporary catalog. The bucket is a fake held in
/// memory, and every host is `.invalid`.
@Suite struct OptimizeDryRunTests {
  /// Saves well over the threshold when recompressed.
  private static let big = jpeg(seed: 1, quality: 1.0)
  private static let otherBig = jpeg(seed: 2, quality: 1.0)
  /// Already compressed harder than the default quality.
  private static let small = jpeg(seed: 3, quality: 0.4)

  private static func jpeg(seed: UInt64, quality: Double) -> Data {
    try! CompressionFixtures.jpeg(
      CompressionFixtures.photo(width: 900, height: 600, seed: seed), quality: quality)
  }

  private static func copy(of data: Data) -> CompressedImage {
    ImageCompressor.compress(data, options: .default).compressedImage!
  }

  @Test("Only the backend's active JPEGs are selected; other types are only counted")
  func selection() throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    try catalog.add("p/a.jpg", bytes: 10)
    try catalog.add("p/b.png", bytes: 20, mime: "image/png")
    try catalog.add("p/c.gif", bytes: 30, mime: "image/gif")
    try catalog.add("p/archived.jpg", bytes: 40, state: "archived")
    try catalog.add("q/d.jpg", bytes: 50)
    try catalog.add("P/e.jpg", bytes: 60)
    try catalog.add("p/elsewhere.jpg", bytes: 70, backendID: 2)

    let under = try catalog.select(prefix: "p/")
    #expect(under.images.map(\.key) == ["p/a.jpg"])
    #expect(under.totals == OptimizeTotals(images: 1, bytes: 10))
    #expect(under.png == OptimizeTotals(images: 1, bytes: 20))
    #expect(under.other == OptimizeTotals(images: 1, bytes: 30))
    #expect(try catalog.select().images.map(\.key) == ["p/a.jpg", "q/d.jpg", "P/e.jpg"])
  }

  @Test("Names match the whole last component, case included, alone, together and with a prefix")
  func names() throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    for key in [
      "p/1/full.jpg", "p/1/sq.jpg", "p/1/w1024.jpg", "p/2/Full.jpg", "p/2/xfull.jpg",
      "s/1/full.jpg", "full.jpg", "full.jpg/other.jpg",
    ] {
      try catalog.add(key)
    }
    try catalog.add("p/1/sq-mask.png", mime: "image/png")

    #expect(
      try catalog.select(names: ["full.jpg"]).images.map(\.key)
        == ["p/1/full.jpg", "s/1/full.jpg", "full.jpg"])
    #expect(
      try catalog.select(names: ["full.jpg", "sq.jpg"]).images.map(\.key)
        == ["p/1/full.jpg", "p/1/sq.jpg", "s/1/full.jpg", "full.jpg"])
    #expect(
      try catalog.select(prefix: "p/", names: ["full.jpg", "sq.jpg"]).images.map(\.key)
        == ["p/1/full.jpg", "p/1/sq.jpg"])
    #expect(try catalog.select(names: ["FULL.JPG"]).images.isEmpty)
    #expect(try catalog.select(names: ["full.jpg"]).png.images == 0)
    #expect(try catalog.select(names: ["sq-mask.png"]).png.images == 1)
  }

  @Test("A seed names one sample; a different seed names another; nil takes everything")
  func sampling() throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    for index in 0..<40 { try catalog.add("p/\(index).jpg") }
    let selection = try catalog.select()
    let first = selection.sample(8, seed: 7).map(\.key)
    #expect(first.count == 8 && Set(first).count == 8)
    #expect(selection.sample(8, seed: 7).map(\.key) == first)
    #expect(selection.sample(8, seed: 8).map(\.key) != first)
    #expect(Set(selection.sample(nil, seed: 7).map(\.key)).count == 40)
    #expect(selection.sample(400, seed: 7).count == 40)
  }

  @Test("Each outcome is counted, skips count as saving nothing, and no row or object changes")
  func outcomes() async throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    let bucket = FakeBucket()
    func add(
      _ key: String, _ data: Data, contentType: String? = "image/jpeg",
      metadata: [String: String] = [:], headers: [String: String] = [:]
    ) throws {
      try catalog.add(key, data: data)
      bucket.put(
        key, data, contentType: contentType, metadata: metadata, headers: headers)
    }
    try add("smaller/full.jpg", Self.big, contentType: "image/jpeg; charset=binary",
      metadata: ["sha256": "x", "source-sha256": "y", "orig-filename": "a.jpg"])
    try add("small/full.jpg", Self.small)
    try add("served-as/full.jpg", Self.jpeg(seed: 4, quality: 1.0), contentType: "image/png")
    let png = try CompressionFixtures.png(
      CompressionFixtures.photo(width: 900, height: 600, seed: 5))
    try add("png-bytes/full.jpg", png)
    try add("untyped/full.jpg", Self.jpeg(seed: 6, quality: 1.0), contentType: nil)
    // Another row already holds the copy's hash, as an original's.
    try add("taken/full.jpg", Self.otherBig)
    try catalog.add(
      "holder.png", mime: "image/png", sourceSHA256: Hashing.sha256(of: Self.copy(of: Self.otherBig).data))
    // ...and as its own.
    let third = Self.jpeg(seed: 7, quality: 1.0)
    try add("taken-too/full.jpg", third)
    try catalog.add(
      "holder-too.png", sha: Hashing.sha256(of: Self.copy(of: third).data), mime: "image/png")
    try add("disposition/sq.jpg", Self.jpeg(seed: 8, quality: 1.0),
      headers: ["Content-Disposition": "inline"])
    try add("foreign-meta/sq.jpg", Self.jpeg(seed: 9, quality: 1.0), metadata: ["camera": "z"])
    try catalog.add("gzip/sq.jpg", bytes: 500)
    bucket.fail(
      "gzip/sq.jpg",
      ObjectReadError.lengthMismatch(
        key: "gzip/sq.jpg", expected: 40, received: 500, contentEncoding: "gzip"))
    try catalog.add("changed/sq.jpg", bytes: 700)
    bucket.put("changed/sq.jpg", Self.big)
    try catalog.add("gone/sq.jpg", bytes: 900)
    try catalog.add("broken/sq.jpg", bytes: 1100)
    bucket.fail("broken/sq.jpg", S3UploaderError.http(statusCode: 500, body: "secret body"))
    try catalog.add("short/sq.jpg", bytes: 1300)
    bucket.fail(
      "short/sq.jpg",
      ObjectReadError.lengthMismatch(
        key: "short/sq.jpg", expected: 9, received: 3, contentEncoding: nil))

    let rowsBefore = try catalog.assetRows()
    let result = try await catalog.run(bucket, sample: nil)
    let report = result.report
    #expect(try catalog.assetRows() == rowsBefore)

    let measured = try catalog.measured(result.runID)
    #expect(
      measured.mapValues(\.outcome) == [
        "smaller/full.jpg": .smaller, "small/full.jpg": .notSmaller,
        "served-as/full.jpg": .formatWouldChange, "png-bytes/full.jpg": .formatWouldChange,
        "untyped/full.jpg": .formatWouldChange, "taken/full.jpg": .duplicateHash,
        "taken-too/full.jpg": .duplicateHash, "disposition/sq.jpg": .unsupportedHeaders,
        "foreign-meta/sq.jpg": .unsupportedHeaders, "gzip/sq.jpg": .unsupportedHeaders,
        "changed/sq.jpg": .hashMismatch, "gone/sq.jpg": .notFound, "broken/sq.jpg": .readFailed,
        "short/sq.jpg": .readFailed,
      ])
    #expect(measured["disposition/sq.jpg"]?.detail == "Content-Disposition")
    #expect(measured["foreign-meta/sq.jpg"]?.detail == "x-amz-meta-camera")
    #expect(measured["gzip/sq.jpg"]?.detail == "Content-Encoding: gzip")
    #expect(measured["broken/sq.jpg"]?.detail == "HTTP 500")
    #expect(report.count(.notSmaller) == 1)
    #expect(report.count(.formatWouldChange) == 3)
    #expect(report.count(.duplicateHash) == 2)
    #expect(report.count(.unsupportedHeaders) == 3)
    #expect(report.count(.hashMismatch) == 1)
    #expect(report.count(.notFound) == 1 && report.count(.readFailed) == 2)

    let smaller = try #require(measured["smaller/full.jpg"])
    let expected = Self.copy(of: Self.big)
    #expect(smaller.bytesBefore == Int64(Self.big.count))
    #expect(smaller.bytesAfter == Int64(expected.byteSize))
    #expect(smaller.widthBefore == 900 && smaller.heightAfter == 600)
    #expect(smaller.sha256After == Hashing.sha256(of: expected.data))

    // The three reads that failed are in neither total.
    let rows = try catalog.select().images
    let unread: Set = ["gone/sq.jpg", "broken/sq.jpg", "short/sq.jpg"]
    let before = rows.filter { !unread.contains($0.key) }.reduce(Int64(0)) { $0 + $1.byteSize }
    #expect(report.sampled == 14 && report.savings.measured == 11)
    #expect(report.savings.bytesBefore == before)
    #expect(report.savings.bytesAfter == before - Int64(Self.big.count - expected.byteSize))
    #expect(report.png.images == 2)

    #expect(report.byName.map(\.name).sorted() == ["full.jpg", "sq.jpg"])
    let full = try #require(report.byName.first { $0.name == "full.jpg" })
    #expect(full.selection.images == 7 && full.sampled == 7 && full.savings.measured == 7)
    #expect(
      full.savings.bytesBefore - full.savings.bytesAfter
        == Int64(Self.big.count - expected.byteSize))
    let square = try #require(report.byName.first { $0.name == "sq.jpg" })
    #expect(square.sampled == 7 && square.savings.measured == 4)
    #expect(square.savings.savedRatio == 0)
    #expect(report.byName.first?.name == "full.jpg")
  }

  @Test("The estimate scales the sample's ratio to the whole selection")
  func estimate() async throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    let bucket = FakeBucket()
    try catalog.add("a.jpg", data: Self.big)
    try catalog.add("b.jpg", data: Self.otherBig)
    try catalog.add("c.jpg", data: Self.small)
    for (key, data) in [("a.jpg", Self.big), ("b.jpg", Self.otherBig), ("c.jpg", Self.small)] {
      bucket.put(key, data)
    }
    let report = try await catalog.run(bucket, sample: 2, seed: 3).report
    #expect(report.sampled == 2 && bucket.reads.count == 2)
    #expect(report.selection.images == 3)
    let total = Int64(Self.big.count + Self.otherBig.count + Self.small.count)
    let after = Int64(
      (Double(total) * Double(report.savings.bytesAfter) / Double(report.savings.bytesBefore))
        .rounded())
    #expect(report.estimatedBytesAfter == after)
    #expect(report.estimatedSavedBytes == total - after)
  }

  @Test("The run records its parameters, the whole selection, each sample and the report")
  func runLog() async throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    let bucket = FakeBucket()
    for index in 0..<6 {
      try catalog.add("p/\(index)/full.jpg", data: Self.small + Data([UInt8(index)]))
      bucket.put("p/\(index)/full.jpg", Self.small + Data([UInt8(index)]))
    }
    let options = CompressionOptions(longestEdge: nil, quality: 60, removesMetadata: false)
    let result = try await catalog.run(
      bucket, prefix: "p/", names: ["full.jpg"], options: options, sample: 3)

    let record = try #require(try RunLog.run(result.runID, in: catalog.database))
    #expect(record.kind == .optimize && record.dryRun && record.state == .finished)
    #expect(record.backendID == 1 && record.fromRunID == nil)
    let params = try JSONDecoder().decode(OptimizeRunParams.self, from: Data(record.params.utf8))
    #expect(params.backend == "r2" && params.prefix == "p/" && params.names == ["full.jpg"])
    #expect(params.fingerprint == "enone-q60-m0" && params.keepMetadata)
    #expect(params.sample == 3 && params.seed == nil)
    // With no seed given, the run's number is the seed.
    #expect(result.report.seed == UInt64(result.runID))

    let events = try RunLog.events(of: result.runID, in: catalog.database).map(\.event)
    #expect(
      events.map(\.type)
        == ["optimize_selected"] + Array(repeating: "object_measured", count: 3)
        + ["run_finished"])
    guard case let .optimizeSelected(selected) = events.first else {
      Issue.record("no selection")
      return
    }
    #expect(selected.images.count == 6 && selected.sample == 3)
    let first = try #require(try catalog.select().images.first)
    #expect(
      selected.images.first
        == OptimizeSelectedImage(
          assetID: first.id!, key: first.key, sha256: first.sha256, bytes: first.byteSize))
    #expect(Set(try catalog.measured(result.runID).keys) == Set(bucket.reads))
    let summary = try JSONDecoder().decode(
      RewriteRunSummary.self, from: Data(try #require(record.summary).utf8))
    #expect(summary.optimize == result.report)
    #expect(try await OptimizeRecovery.resumePending(in: catalog.database) == 0)
  }

  @Test("At most four objects are read at a time")
  func concurrency() async throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    let bucket = FakeBucket()
    bucket.delay = .milliseconds(20)
    for index in 0..<12 {
      try catalog.add("\(index).jpg", data: Data("not an image \(index)".utf8))
      bucket.put("\(index).jpg", Data("not an image \(index)".utf8))
    }
    let report = try await catalog.run(bucket, sample: nil).report
    #expect(report.count(.unreadable) == 12)
    #expect(bucket.mostInFlight == 4)
  }

  @Test("A run that can read nothing fails; an empty selection records no run")
  func nothing() async throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    try catalog.add("a.jpg", bytes: 5)
    try catalog.add("b.png", bytes: 5, mime: "image/png")
    await #expect(throws: OptimizeError.self) {
      _ = try await catalog.run(FakeBucket(), sample: nil)
    }
    let runs = try RunLog.runs(in: catalog.database)
    #expect(runs.map(\.state) == [.failed])
    #expect(runs.first?.summary != nil)

    await #expect(
      throws: OptimizeError.noImages(backend: "r2", prefix: "x/", names: [])
    ) {
      _ = try await catalog.run(FakeBucket(), prefix: "x/", sample: nil)
    }
    #expect(try RunLog.runs(in: catalog.database).count == 1)
  }

  @Test("A tenth of the sample mismatching is tolerated; more is flagged")
  func manyMismatches() async throws {
    for (mismatches, flagged) in [(1, false), (2, true)] {
      let catalog = try Catalog()
      defer { catalog.remove() }
      let bucket = FakeBucket()
      for index in 0..<10 {
        let data = Data("object \(index)".utf8)
        try catalog.add("\(index).jpg", data: data)
        bucket.put("\(index).jpg", index < mismatches ? Data("changed \(index)".utf8) : data)
      }
      let report = try await catalog.run(bucket, sample: nil).report
      #expect(report.count(.hashMismatch) == mismatches)
      #expect(report.hasManyHashMismatches == flagged)
    }
  }

  @Test("Past twenty names, the smallest are merged into one row")
  func mergedNames() async throws {
    let catalog = try Catalog()
    defer { catalog.remove() }
    let bucket = FakeBucket()
    for index in 0..<23 {
      let data = Data(repeating: UInt8(index), count: 100 + index)
      try catalog.add("p/n\(index).jpg", data: data)
      bucket.put("p/n\(index).jpg", data)
    }
    let rows = try await catalog.run(bucket, sample: nil).report.byName
    #expect(rows.count == 21)
    #expect(rows.first?.name == "n22.jpg" && rows.first?.mergedNames == nil)
    #expect(rows.map(\.selection.bytes).dropLast() == (103...122).reversed().map(Int64.init)[...])
    let merged = try #require(rows.last)
    #expect(merged.name == "other" && merged.mergedNames == 3)
    #expect(merged.selection == OptimizeTotals(images: 3, bytes: 303))
    #expect(merged.sampled == 3 && merged.savings.bytesBefore == 303)
  }

  @Test("The reader's session keeps no cache on disk")
  func uncachedSession() {
    #expect(OptimizeDryRun.uncachedSession().configuration.urlCache == nil)
  }
}

/// A temporary catalog with backends `r2` (id 1) and `second` (id 2).
private struct Catalog {
  let directory: URL
  let database: DatabasePool

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-optimize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    for slug in ["r2", "second"] {
      _ = try CatalogConfiguration.addBackend(
        slug: slug, endpoint: "https://storage.pinax.invalid", bucket: "images", region: "auto",
        urlPrefix: "https://\(slug).pinax.invalid", keychainReference: "backend.\(slug)",
        to: database)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }

  /// With `data`, the row describes those bytes.
  func add(
    _ key: String, data: Data? = nil, sha: String? = nil, bytes: Int64 = 1,
    mime: String = "image/jpeg", state: String = "active", backendID: Int64 = 1,
    sourceSHA256: String? = nil
  ) throws {
    let date = "2026-01-01T00:00:00Z"
    try database.write { db in
      _ = try Asset(
        sha256: sha ?? Hashing.sha256(of: data ?? Data("row \(backendID) \(key)".utf8)),
        backendID: backendID, key: key, byteSize: data.map { Int64($0.count) } ?? bytes,
        mime: mime, state: state, uploadedAt: date, createdAt: date, updatedAt: date,
        sourceSHA256: sourceSHA256
      ).insertAndFetch(db)
    }
  }

  func select(prefix: String = "", names: [String] = []) throws -> OptimizeSelection {
    try OptimizeSelection.read(backendID: 1, prefix: prefix, names: names, in: database)
  }

  func run(
    _ bucket: FakeBucket, prefix: String = "", names: [String] = [],
    options: CompressionOptions = .default, sample: Int?, seed: UInt64? = nil
  ) async throws -> OptimizeDryRunResult {
    try await OptimizeDryRun.run(
      backend: try CatalogConfiguration.backend(slug: "r2", in: database), prefix: prefix,
      names: names, options: options, sample: sample, seed: seed, reader: bucket,
      database: database)
  }

  func assetRows() throws -> [String] {
    try database.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM asset ORDER BY id").map(\.description)
    }
  }

  func measured(_ runID: Int64) throws -> [String: ObjectMeasuredEvent] {
    var byKey: [String: ObjectMeasuredEvent] = [:]
    for record in try RunLog.events(of: runID, in: database) {
      if case let .objectMeasured(event) = record.event { byKey[event.key] = event }
    }
    return byKey
  }
}

/// A bucket in memory. It is also an uploader that stops the process, so
/// anything that tried to write through it would be caught. A key it does not
/// hold is not found.
private final class FakeBucket: ObjectReading, Uploader, @unchecked Sendable {
  private let lock = NSLock()
  private var objects: [String: Result<S3StoredObject, Error>] = [:]
  private var read: [String] = []
  private var inFlight = 0
  private var most = 0
  var delay: Duration?

  var reads: [String] { lock.withLock { read } }
  var mostInFlight: Int { lock.withLock { most } }

  func put(
    _ key: String, _ data: Data, contentType: String? = "image/jpeg",
    metadata: [String: String] = [:], headers: [String: String] = [:]
  ) {
    let object = S3StoredObject(
      key: key, data: data, etag: "\"e\"", contentType: contentType, cacheControl: nil,
      contentLength: Int64(data.count), lastModified: nil, metadata: metadata,
      otherHeaders: headers)
    lock.withLock { objects[key] = .success(object) }
  }

  func fail(_ key: String, _ error: Error) {
    lock.withLock { objects[key] = .failure(error) }
  }

  func getObject(key: String) async throws -> S3StoredObject {
    lock.withLock {
      read.append(key)
      inFlight += 1
      most = max(most, inFlight)
    }
    defer { lock.withLock { inFlight -= 1 } }
    if let delay { try await Task.sleep(for: delay) }
    guard let result = lock.withLock({ objects[key] }) else {
      throw ObjectReadError.notFound(key)
    }
    return try result.get()
  }

  func upload(_ request: UploadRequest) async throws -> UploadResult {
    fatalError("A dry run uploaded \(request.key)")
  }

  func exists(key: String) async throws -> Bool {
    fatalError("A dry run asked an uploader about \(key)")
  }
}
