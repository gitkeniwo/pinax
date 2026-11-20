import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Settings ▸ Backends ▸ <backend> ▸
/// Unreferenced Objects. The section and the sheet are pure data, asserted
/// line by line; the flow runs on a fake importer, the production importer
/// on a stub inventory and fetcher — never a real bucket or Keychain.
@MainActor
@Suite struct UnreferencedObjectsTests {
  static let footer =
    "Objects in image-hosting that aren’t in the catalog and that no project’s pages use. Imported images show up in Orphans. Objects stay in the bucket."

  // MARK: - Section content

  @Test("① Not checked yet: Find Objects, the footer; without credentials, disabled with the hint")
  func notChecked() {
    let ready = section(.notChecked)
    #expect(ready.status == "Not checked yet")
    #expect(ready.findTitle == "Find Objects" && ready.findEnabled)
    #expect(ready.importTitle == nil && ready.details.isEmpty && !ready.showsCancel)
    #expect(ready.footer == Self.footer)
    let locked = section(.notChecked, credentials: false)
    #expect(!locked.findEnabled)
    #expect(locked.details == ["Configure credentials before finding objects in this backend."])
  }

  @Test("② After the List: the count, Find Again, Import N Objects…; singular and zero read right")
  func found() {
    let many = section(.found(found(23)))
    #expect(many.status == "23 objects aren’t in the catalog")
    #expect(many.findTitle == "Find Again" && many.findEnabled)
    #expect(many.importTitle == "Import 23 Objects…")
    let one = section(.found(found(1)))
    #expect(one.status == "1 object isn’t in the catalog")
    #expect(one.importTitle == "Import 1 Object…")
    let none = section(.found(found(0)))
    #expect(none.status == "Every object is in the catalog")
    #expect(none.importTitle == nil)
    let finding = section(.finding)
    #expect(finding.status == "Listing objects in image-hosting…")
    #expect(finding.showsSpinner && finding.findTitle == nil)
  }

  @Test("④ Importing: Importing k of N…, a spinner, a bar, Cancel, no other button")
  func importing() {
    let content = section(.importing(completed: 9, total: 23))
    #expect(content.status == "Importing 9 of 23…")
    #expect(content.showsSpinner && content.showsCancel)
    #expect(content.progress == 9.0 / 23.0)
    #expect(content.findTitle == nil && content.importTitle == nil && !content.showsOrphansLink)
  }

  @Test("⑤ Done: Imported N objects, Show in Orphans, the reindex note; failures counted in words")
  func imported() {
    let clean = section(.imported(result(claimed: 23, candidates: 23)))
    #expect(clean.status == "Imported 23 objects")
    #expect(clean.showsOrphansLink)
    #expect(
      clean.details == [
        "Reindex can’t rebuild imported images from the bucket; catalog backups keep them."
      ])
    #expect(clean.findTitle == "Find Again" && clean.importTitle == nil && !clean.isError)

    let mixed = section(
      .imported(
        result(
          claimed: 21, candidates: 23,
          skipped: ["fetch_failed", "not_found", "same_content", "fetch_failed"])))
    #expect(mixed.status == "Imported 21 objects")
    #expect(
      mixed.details.first
        == "1 not found · 2 couldn’t be downloaded · 1 already in the catalog under another name")

    let cancelled = section(.imported(result(claimed: 9, candidates: 23, cancelled: 14)))
    #expect(cancelled.status == "Imported 9 of 23 objects")
    #expect(cancelled.importTitle == "Import 14 Objects…")

    let refused = section(.imported(result(claimed: 0, candidates: 23, refused: true)))
    #expect(refused.status == "Nothing imported")
    #expect(refused.isError && !refused.showsOrphansLink)
    #expect(
      refused.details == [
        "The CDN changed the bytes of images Pinax uploaded, so nothing was imported."
      ])
  }

  // MARK: - Sheet

  @Test("The sheet: title, From <bucket>, three rows, the Orphans and objects-stay lines, Cancel / Import")
  func sheet() {
    let sheet = ImportObjectsSheetContent.make(count: 23, bucket: "image-hosting", cdnSamples: 11)
    #expect(sheet.title == "Import 23 Objects into the Catalog?")
    #expect(
      sheet.message
        == "From image-hosting. Pinax downloads each object once to fingerprint it, then adds it to the catalog at the address it already has.")
    #expect(
      sheet.rows == [
        .init(label: "Objects", value: "23"),
        .init(label: "Downloads", value: "about 23 downloads"),
        .init(label: "Project", value: "none — they’ll appear in Orphans"),
      ])
    #expect(sheet.cdnWarning == nil)
    #expect(sheet.note == "Objects stay where they are; nothing is uploaded or deleted.")
    #expect(sheet.cancelTitle == "Cancel" && sheet.confirmTitle == "Import")

    let unchecked = ImportObjectsSheetContent.make(count: 1, bucket: "image-hosting", cdnSamples: 0)
    #expect(unchecked.title == "Import 1 Object into the Catalog?")
    #expect(unchecked.rows.map(\.value) == ["1", "about 1 download", "none — it’ll appear in Orphans"])
    #expect(unchecked.cdnWarning == "Pinax can’t check whether the CDN changes bytes on this domain.")
    #expect(NSImage(systemSymbolName: ImportObjectsSheet.symbol, accessibilityDescription: nil) != nil)
  }

  @Test("No UI string says Claim")
  func importIsTheOnlyVerb() {
    var strings: [String] = []
    for state: UnreferencedObjectsState in [
      .notChecked, .finding, .found(found(3)), .importing(completed: 1, total: 3),
      .imported(result(claimed: 2, candidates: 3, skipped: ["not_found"])),
      .imported(result(claimed: 0, candidates: 3, refused: true)), .failed("x"),
    ] {
      let content = section(state)
      strings += [content.status, content.footer] + content.details
      strings += [content.findTitle, content.importTitle].compactMap { $0 }
    }
    let sheet = ImportObjectsSheetContent.make(count: 3, bucket: "b", cdnSamples: 0)
    strings += [sheet.title, sheet.message, sheet.note, sheet.cdnWarning ?? ""]
    strings += sheet.rows.flatMap { [$0.label, $0.value] }
    strings += [UnreferencedObjectsSectionContent.header]
    #expect(!strings.contains { $0.lowercased().contains("claim") })
  }

  // MARK: - Flow

  @Test("Find, then Import N Objects… asks; Import runs, reports progress, lands on the result")
  func flow() async throws {
    let importer = FakeBucketImporter(found: found(3), result: result(claimed: 3, candidates: 3))
    let model = UnreferencedObjectsModel(importer: importer)
    await model.find(backendSlug: "r2")
    #expect(model.state == .found(found(3)))
    #expect(importer.imports == 0)
    model.requestImport(bucket: "image-hosting")
    #expect(model.confirmation?.title == "Import 3 Objects into the Catalog?")
    #expect(model.confirmation?.cdnWarning == nil)
    model.dismissConfirmation()
    #expect(model.confirmation == nil)
    #expect(importer.imports == 0)

    model.requestImport(bucket: "image-hosting")
    importer.onImport = { @MainActor in
      #expect(model.state == .importing(completed: 0, total: 3))
    }
    await model.confirmImport(backendSlug: "r2")
    #expect(importer.imports == 1)
    #expect(model.confirmation == nil)
    #expect(model.state == .imported(result(claimed: 3, candidates: 3)))

    var shown = 0
    model.onShowOrphans = { shown += 1 }
    model.showOrphans()
    #expect(shown == 1)
    model.reset()
    #expect(model.state == .notChecked)
  }

  @Test("The production importer: a 403 List and missing credentials read in words, nothing crashes")
  func productionErrors() async throws {
    let (database, directory) = try invalidHostDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let refusing = UnreferencedObjectsModel(
      importer: CatalogBucketImporter(
        database: database, loadCredentials: { _ in Self.credentials },
        inventoryFactory: { _, _ in StubInventory(error: S3UploaderError.http(statusCode: 403, body: "AccessDenied")) },
        fetcher: StubFetcher()))
    await refusing.find(backendSlug: "r2")
    #expect(
      refusing.state
        == .failed(
          "images refused to list its objects (HTTP 403). The credentials for r2 need permission to list the bucket."))
    let failed = section(refusing.state)
    #expect(failed.isError && failed.findTitle == "Find Objects" && failed.findEnabled)

    let noCredentials = UnreferencedObjectsModel(
      importer: CatalogBucketImporter(
        database: database, loadCredentials: { _ in nil },
        inventoryFactory: { _, _ in StubInventory(keys: ["2024/a.png"]) }, fetcher: StubFetcher()))
    await noCredentials.find(backendSlug: "r2")
    #expect(noCredentials.state == .failed("Configure credentials before finding objects in this backend."))
  }

  @Test("The production importer finds, imports with no project and the bucket provenance, then finds none")
  func productionImport() async throws {
    let (database, directory) = try invalidHostDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fetcher = StubFetcher()
    let model = UnreferencedObjectsModel(
      importer: CatalogBucketImporter(
        database: database, loadCredentials: { _ in Self.credentials },
        inventoryFactory: { _, _ in StubInventory(keys: ["2024/a.png", "2024/b.png"]) },
        fetcher: fetcher))
    await model.find(backendSlug: "r2")
    #expect(section(model.state).status == "2 objects aren’t in the catalog")
    #expect(fetcher.count == 0)
    model.requestImport(bucket: "images")
    // No Pinax-uploaded asset to sample: the no-sample line is on the sheet.
    #expect(model.confirmation?.cdnWarning != nil)
    await model.confirmImport(backendSlug: "r2")
    #expect(section(model.state).status == "Imported 2 objects")
    #expect(fetcher.count == 2)
    let rows = try database.read { db -> [Row] in
      try Row.fetchAll(
        db,
        sql: """
          SELECT a.key, a.meta, (SELECT COUNT(*) FROM asset_project p WHERE p.asset_id = a.id) AS links
          FROM asset a ORDER BY a.key
          """)
    }
    #expect(rows.map { $0["key"] as String } == ["2024/a.png", "2024/b.png"])
    #expect(rows.allSatisfy { ($0["meta"] as String) == "{\"imported_from\":\"bucket\"}" })
    #expect(rows.allSatisfy { ($0["links"] as Int) == 0 })
    await model.find(backendSlug: "r2")
    #expect(section(model.state).status == "Every object is in the catalog")
    #expect(fetcher.count == 2)
  }

  @Test("Selecting another backend forgets the last one's List")
  func switchingBackendResets() async throws {
    let importer = FakeBucketImporter(found: found(3), result: result(claimed: 3, candidates: 3))
    let model = BackendsModel(reader: TwoBackends(), bucketImporter: importer)
    await model.load()
    await model.unreferenced.find(backendSlug: "r2")
    #expect(model.unreferenced.state == .found(found(3)))
    await model.select("b2")
    #expect(model.unreferenced.state == .notChecked)
  }

  // MARK: - The app's own wiring

  @Test("PinaxAppModel gives Backends an importer, and Show in Orphans opens Reports ▸ Orphans")
  func appWiring() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-t32-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let backends = try #require(app.backends)
    let gallery = try #require(app.gallery)
    #expect(backends.unreferenced.canImport)
    #expect(gallery.sidebarSelection != .orphans)
    backends.unreferenced.showOrphans()
    #expect(gallery.sidebarSelection == .orphans)
    // The section draws the app's own model.
    let view = BackendUnreferencedObjectsControls(
      details: details(), model: backends.unreferenced)
    #expect(view.content.findTitle == "Find Objects")
  }

  // MARK: - Helpers

  nonisolated static let credentials = BackendCredentials(accessKeyID: "test", secretAccessKey: "test")

  private func details(credentials: Bool = true) -> BackendDetails {
    BackendDetails(
      slug: "r2", kind: "s3", endpoint: "https://s3.pinax.invalid", bucket: "image-hosting",
      region: "auto", urlPrefix: "https://img.pinax.invalid", keychainReference: "",
      credentialsConfigured: credentials)
  }

  private func section(_ state: UnreferencedObjectsState, credentials: Bool = true)
    -> UnreferencedObjectsSectionContent
  {
    .make(
      state: state, bucket: "image-hosting", credentialsConfigured: credentials, canImport: true)
  }

  private func found(_ n: Int) -> UnreferencedObjects {
    let objects = (0..<n).map { S3ObjectSummary(key: "2024/\($0).png", byteSize: 1) }
    return UnreferencedObjects(
      backend: "r2", objects: objects, candidates: objects, alreadyInCatalog: 0,
      pendingDeletion: [], badKeys: [], referenced: [], cdnSamples: 11)
  }

  private func result(
    claimed: Int, candidates: Int, skipped: [String] = [], cancelled: Int = 0,
    refused: Bool = false
  ) -> BucketClaimResult {
    BucketClaimResult(
      dryRun: false, backend: "r2", listed: candidates, alreadyInCatalog: 0, referenced: [],
      candidates: candidates,
      claimed: (0..<claimed).map {
        ExternalsClaimedItem(
          key: "2024/\($0).png", url: "https://img.pinax.invalid/2024/\($0).png", sha256: "s",
          byteSize: 1, projects: [])
      },
      skipped: skipped.map { ExternalsClaimSkip(reason: $0, url: "https://img.pinax.invalid/x") },
      cdnCheck: [], refused: refused, cancelled: cancelled > 0, remaining: cancelled)
  }

  /// The UI fixture with every host `.invalid` and no Keychain reference.
  private func invalidHostDatabase() throws -> (DatabasePool, URL) {
    let (database, directory) = try makeUITestDatabase()
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE backend SET endpoint = 'https://s3.pinax.invalid',
            url_prefix = 'https://img.pinax.invalid', keychain_ref = ''
          """)
    }
    return (database, directory)
  }
}

// MARK: - Doubles

private struct TwoBackends: BackendsReading {
  func backends() async throws -> [BackendListRow] {
    ["r2", "b2"].map { BackendListRow(slug: $0, kind: "s3", bucket: $0, urlPrefix: "https://\($0).invalid") }
  }

  func backend(slug: String) async throws -> BackendDetails {
    BackendDetails(
      slug: slug, kind: "s3", endpoint: "https://s3.invalid", bucket: slug, region: "auto",
      urlPrefix: "https://\(slug).invalid", keychainReference: "", credentialsConfigured: true)
  }
}

@MainActor
private final class FakeBucketImporter: BucketImporting, @unchecked Sendable {
  let found: UnreferencedObjects
  let result: BucketClaimResult
  var imports = 0
  var onImport: (@MainActor () -> Void)?

  init(found: UnreferencedObjects, result: BucketClaimResult) {
    self.found = found
    self.result = result
  }

  nonisolated func find(backendSlug: String) async throws -> UnreferencedObjects {
    await MainActor.run { found }
  }

  nonisolated func importObjects(
    _ found: UnreferencedObjects, backendSlug: String,
    cancellation: ExternalsClaimCancellation,
    progress: @escaping @Sendable (ExternalsClaimProgress) -> Void
  ) async throws -> BucketClaimResult {
    await MainActor.run {
      imports += 1
      onImport?()
      return result
    }
  }
}

private struct StubInventory: ObjectInventory {
  var keys: [String] = []
  var error: S3UploaderError?

  func listObjects() async throws -> [S3ObjectSummary] {
    if let error { throw error }
    return keys.map { S3ObjectSummary(key: $0, byteSize: 1) }
  }

  func headObject(key: String) async throws -> S3ObjectHead {
    Issue.record("HEAD \(key)")
    return S3ObjectHead(key: key, byteSize: 1, mime: nil, lastModified: nil, metadata: [:])
  }
}

/// A distinct tiny body per URL; counts GETs. No network.
private final class StubFetcher: PublicObjectFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var requests = 0

  var count: Int { lock.withLock { requests } }

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    lock.withLock { requests += 1 }
    let data = Data(url.absoluteString.utf8)
    return (data, "image/png", Int64(data.count))
  }
}
