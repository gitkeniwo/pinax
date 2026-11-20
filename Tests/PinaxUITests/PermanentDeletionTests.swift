import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Delete Permanently… in the gallery. Every remote call
/// goes to `DeletionBucket`, a URLProtocol on a `.invalid` host whose DELETEs
/// outside the allowed keys land in `forbidden`; no Keychain is read.
@MainActor
@Suite(.serialized) struct PermanentDeletionTests {
  nonisolated static func sha(_ index: Int) -> String { String(format: "%064x", index + 1) }

  /// a (blog), b (blog + notes), c (notes, imported from PicGo) archived;
  /// d (blog) active.
  struct Fixture {
    let model: GalleryModel
    let database: DatabasePool
    let directory: URL
    let remoteCalls: RemoteCalls
  }

  final class RemoteCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
  }

  static func remote(_ calls: RemoteCalls) -> DeletionRemote {
    { backend in
      calls.record()
      return S3ObjectDeleter(
        backend: backend,
        credentials: BackendCredentials(accessKeyID: "AKIDT25", secretAccessKey: "t25"),
        session: DeletionBucket.session)
    }
  }

  static func seed() throws -> (DatabasePool, URL) {
    let (database, directory) = try makeUITestDatabase()
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", key: "blog/a.png")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", key: "blog/b.png")
    try seedAsset(
      database, index: 2, uploadedAt: "2026-08-03T00:00:00Z", projectSlug: "notes",
      key: "notes/c.png")
    try seedAsset(database, index: 3, uploadedAt: "2026-08-04T00:00:00Z", key: "blog/d.png")
    try database.write { db in
      try db.execute(sql: "UPDATE backend SET endpoint = 'https://\(DeletionBucket.host)' WHERE id = 1")
      try db.execute(
        sql: """
          INSERT INTO asset_project (asset_id, project_id, added_at)
          SELECT a.id, 2, '2026-08-02T00:00:00Z' FROM asset a WHERE a.sha256 = ?
          """, arguments: [sha(1)])
      try db.execute(
        sql: "UPDATE asset SET meta = '{\"imported_from\":\"picgo\"}' WHERE sha256 = ?",
        arguments: [sha(2)])
      try db.execute(
        sql: "UPDATE asset SET state = 'archived' WHERE sha256 IN (?, ?, ?)",
        arguments: [sha(0), sha(1), sha(2)])
    }
    return (database, directory)
  }

  func makeFixture(deleter: Bool = true) throws -> Fixture {
    let (database, directory) = try Self.seed()
    let calls = RemoteCalls()
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let originals = OriginalImageCache(
      cacheDirectory: directory.appendingPathComponent("originals", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      deleter: deleter
        ? DeletingCatalog(database: database, remote: Self.remote(calls)) : nil,
      thumbnails: thumbnails,
      quickLook: QuickLookController(thumbnails: thumbnails, originals: originals))
    // No key event: the command path's text-field check sees none.
    model.currentEvent = { nil }
    model.shareCacheFolder = directory.appendingPathComponent("share", isDirectory: true)
    DeletionBucket.reset(allow: [], objects: [:])
    return Fixture(model: model, database: database, directory: directory, remoteCalls: calls)
  }

  func show(_ selection: SidebarSelection, _ model: GalleryModel) async {
    model.select(selection, in: SidebarModel.navigator(for: selection))
    await model.reload()
  }

  func rowID(_ index: Int, _ model: GalleryModel) throws -> Int64 {
    try #require(model.rows.first { $0.item.asset.sha256 == Self.sha(index) }?.id)
  }

  func deleteTarget(_ items: [GalleryModel.ContextMenuItem]) -> (
    GalleryModel.ContextMenuTarget, Bool
  )? {
    for item in items {
      if case let .deletePermanently(target, isEnabled) = item { return (target, isEnabled) }
    }
    return nil
  }

  func states(_ database: DatabasePool) async throws -> [String: String] {
    try await database.read { db in
      Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT sha256, state FROM asset").map {
          ($0["sha256"] as String, $0["state"] as String)
        })
    }
  }

  func memberships(_ database: DatabasePool, _ index: Int) async throws -> [String] {
    try await database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT p.slug FROM asset_project ap JOIN project p ON p.id = ap.project_id
          JOIN asset a ON a.id = ap.asset_id WHERE a.sha256 = ? ORDER BY p.slug
          """, arguments: [Self.sha(index)])
    }
  }

  static let isDeleteItem: (Any) -> Bool = { "\($0)".contains("\"Delete Permanently…\"") }

  // MARK: - Entry

  @Test("Delete Permanently… is on Archived only, for an archived selection, ⌥⌘⌫; ⌘⌫ stays Archive")
  func entryOnArchivedOnly() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()

    await show(.all, model)
    let active = try #require(model.rows.first { $0.item.asset.sha256 == Self.sha(3) })
    #expect(!model.showsDeletePermanently)
    #expect(deleteTarget(model.contextMenuItems(for: active)) == nil)
    model.select(active)
    #expect(!model.canDeleteSelectionPermanently)
    // The menu item is always drawn, disabled off Archived.
    let offMenu = PinaxCommands.deleteItems(model).body
    #expect(
      buttonShortcut(in: offMenu, label: Self.isDeleteItem)
        == KeyboardShortcut(.delete, modifiers: [.option, .command]))
    #expect(buttonIsEnabled(in: offMenu, label: Self.isDeleteItem) == false)
    let activeID = active.id

    await show(.archived, model)
    #expect(model.showsDeletePermanently)
    let row = try #require(model.rows.first { $0.item.asset.sha256 == Self.sha(0) })
    let (target, enabled) = try #require(deleteTarget(model.contextMenuItems(for: row)))
    #expect(enabled)
    // The guard: an unarchived member (never on Archived) disables it.
    guard case var .row(member) = target else { Issue.record("\(target)"); return }
    member.isArchived = false
    #expect(!model.canDeletePermanently(.row(member)))
    #expect(!model.canDeletePermanently(.selection([activeID])))

    model.select(row)
    #expect(model.canDeleteSelectionPermanently)
    let menu = PinaxCommands.deleteItems(model).body
    #expect(
      buttonShortcut(in: menu, label: Self.isDeleteItem)
        == KeyboardShortcut(.delete, modifiers: [.option, .command]))
    #expect(buttonIsEnabled(in: menu, label: Self.isDeleteItem) == true)

    // Without a deleter (the app always passes one) there is no entry.
    let bare = try makeFixture(deleter: false)
    defer { try? FileManager.default.removeItem(at: bare.directory) }
    await bare.model.loadInitialData()
    await show(.archived, bare.model)
    #expect(!bare.model.showsDeletePermanently)
  }

  // MARK: - The sheet's data

  @Test("The sheet: count, bytes, referencing files with a warning, PicGo kept, Remove from <project> default")
  func sheetData() throws {
    let a = DeletionFacts(
      sha256: Self.sha(0), key: "blog/a.png", byteSize: 1_000_000, isArchived: true,
      backendSlug: "r2", bucket: "images", projects: ["blog"],
      usedInFiles: ["blog/posts/x.md", "blog/posts/y.md"], liveUsageByProject: ["blog": 2])
    let b = DeletionFacts(
      sha256: Self.sha(1), key: "blog/b.png", byteSize: 500_000, isArchived: true,
      backendSlug: "r2", bucket: "images", projects: ["blog", "notes"],
      usedInFiles: ["blog/posts/x.md"])
    let c = DeletionFacts(
      sha256: Self.sha(2), key: "notes/c.png", byteSize: 250_000, isArchived: true,
      backendSlug: "r2", bucket: "images", projects: ["notes"], importedFrom: "picgo")
    let names = ["blog": "Blog", "notes": "Notes"]

    // All, no project: delete a and b, keep c; two files reference them.
    let all = try #require(
      DeletionConfirmation.make(facts: [a, b, c], currentProject: nil, projectNames: names))
    #expect(all.imageCount == 3)
    #expect(all.byteTotal == 1_750_000)
    #expect(all.deleting == [Self.sha(0), Self.sha(1)])
    #expect(all.keeping == [Self.sha(2)])
    #expect(all.referencingFiles == ["blog/posts/x.md", "blog/posts/y.md"])
    #expect(all.usedImageCount == 2)
    #expect(all.notes.contains { $0.title == "2 images are still used in 2 files" })
    #expect(all.notes.contains { $0.title == "1 was imported from PicGo" })
    #expect(all.removal == nil)
    #expect(all.defaultButton == .cancel)
    #expect(all.finePrint.contains("can’t undo"))
    #expect(all.finePrint.contains("CDN and browser caches"))
    #expect(all.finePrint.contains("versioned bucket"))

    // No references: no warning.
    let quiet = try #require(
      DeletionConfirmation.make(facts: [c], currentProject: nil, projectNames: names))
    #expect(quiet.referencingFiles.isEmpty)
    #expect(!quiet.notes.contains { $0.title.contains("still used") })

    // In Blog with a shared image: Remove from Blog, the default; a's live
    // reference in Blog keeps it there (the core's guard, said in the sheet).
    let blog = try #require(
      DeletionConfirmation.make(facts: [a, b], currentProject: "blog", projectNames: names))
    #expect(blog.removeTitle == "Remove from Blog")
    #expect(blog.defaultButton == .removeFromProject)
    #expect(blog.removal?.members == [Self.sha(0), Self.sha(1)])
    #expect(blog.removal?.keptByUsage == 1)
    #expect(blog.notes.contains { $0.detail.contains("still used in Blog and stays there") })

    // In Blog with nothing shared: no Remove.
    let alone = try #require(
      DeletionConfirmation.make(facts: [a], currentProject: "blog", projectNames: names))
    #expect(alone.removal == nil)
    #expect(alone.defaultButton == .cancel)

    // A batch is capped at 100: 101 images — the first 100 now, one stays selected.
    let many = (0..<101).map { index in
      DeletionFacts(
        sha256: Self.sha(index), key: "blog/\(index).png", byteSize: 10, isArchived: true,
        backendSlug: "r2", bucket: "images", projects: ["blog"])
    }
    let capped = try #require(
      DeletionConfirmation.make(facts: many, currentProject: nil, projectNames: names))
    #expect(capped.imageCount == 100)
    #expect(capped.leftSelected == [Self.sha(100)])
    #expect(capped.title == "Delete 100 of 101 Images Permanently?")
    #expect(capped.subtitle.contains("at most 100 images per confirmation"))
  }

  @Test("The sheet's buttons: destructive Delete, never the default; Return is Cancel or Remove")
  func sheetButtons() throws {
    let shared = DeletionFacts(
      sha256: Self.sha(1), key: "blog/b.png", byteSize: 1, isArchived: true, backendSlug: "r2",
      bucket: "images", projects: ["blog", "notes"])
    let isCancel: (Any) -> Bool = { "\($0)".contains("\"Cancel\"") }
    let isDelete: (Any) -> Bool = { "\($0)".contains("\"Delete Permanently\"") }
    let isRemove: (Any) -> Bool = { "\($0)".contains("\"Remove from Blog\"") }
    for (project, defaultIs) in [(nil, isCancel), ("blog", isRemove)] as [(String?, (Any) -> Bool)] {
      let confirmation = try #require(
        DeletionConfirmation.make(
          facts: [shared], currentProject: project, projectNames: ["blog": "Blog"]))
      let sheet = DeletionConfirmationSheet(
        confirmation: confirmation, cancel: {}, delete: {}, removeFromProject: {}
      ).body
      #expect(buttonShortcut(in: sheet, label: defaultIs) == .defaultAction)
      #expect(buttonShortcut(in: sheet, label: isDelete) == nil)
      let delete = try #require(firstView(in: sheet, typePrefix: "Button<"))
      #expect("\(delete)".contains("\"Delete Permanently\""))
      #expect(Mirror(reflecting: delete).descendant("role") as? ButtonRole? == .destructive)
    }
  }

  // MARK: - Remove from project

  @Test("Remove from Blog: no request, still archived, other projects unchanged, a live reference stays")
  func removeFromProject() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    try seedLiveUsage(f.database, projectSlug: "blog", sha256: Self.sha(0), count: 1)
    await model.loadInitialData()
    model.currentProjectSlug = "blog"
    await show(.archived, model)
    model.selectedIDs = [try rowID(0, model), try rowID(1, model)]
    await model.deletePermanentlyFromCommand()
    let pending = try #require(model.pendingDeletion)
    #expect(pending.defaultButton == .removeFromProject)

    await model.confirmRemoveFromProject(pending)
    #expect(DeletionBucket.trace.isEmpty)
    #expect(f.remoteCalls.value == 0)
    #expect(model.pendingDeletion == nil)
    let states = try await states(f.database)
    #expect(states[Self.sha(0)] == "archived")
    #expect(states[Self.sha(1)] == "archived")
    #expect(try await memberships(f.database, 0) == ["blog"], "live in Blog: the core keeps it")
    #expect(try await memberships(f.database, 1) == ["notes"])
    #expect(try await memberships(f.database, 2) == ["notes"])
    #expect(model.deletionNotice == "1 image is still used in Blog and stays there.")
  }

  // MARK: - Delete

  @Test("Delete: HEAD, DELETE, HEAD per object, nothing forbidden; rows, caches and PicGo row go")
  func confirmDeletes() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    DeletionBucket.reset(
      allow: ["blog/a.png", "blog/b.png"],
      objects: ["blog/a.png": Self.sha(0), "blog/b.png": Self.sha(1), "notes/c.png": Self.sha(2)])
    await model.loadInitialData()
    await show(.archived, model)
    var removed: Set<String> = []
    model.onAssetsDeleted = { removed.formUnion($0) }

    // Cached files of a, by sha256.
    let thumbnail = f.directory.appendingPathComponent(
      "thumbnails/\(Self.sha(0).prefix(2))/\(Self.sha(0)).jpg")
    let original = f.directory.appendingPathComponent(
      "originals/\(Self.sha(0).prefix(2))/\(Self.sha(0))/original.png")
    let share = model.shareCacheFolder.appendingPathComponent("\(Self.sha(0))/a.png")
    for file in [thumbnail, original, share] {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: file)
    }

    model.selectedIDs = [try rowID(0, model), try rowID(1, model), try rowID(2, model)]
    await model.deletePermanentlyFromCommand()
    let pending = try #require(model.pendingDeletion)
    #expect(DeletionBucket.trace.isEmpty, "asking sends nothing")
    #expect(pending.keeping == [Self.sha(2)])
    await model.confirmDeletion(pending)

    // One object at a time, in the grid's order (newest first).
    #expect(
      DeletionBucket.trace == [
        "HEAD /images/blog/b.png", "DELETE /images/blog/b.png", "HEAD /images/blog/b.png",
        "HEAD /images/blog/a.png", "DELETE /images/blog/a.png", "HEAD /images/blog/a.png",
      ])
    #expect(DeletionBucket.forbidden.isEmpty)
    #expect(model.rows.isEmpty)
    #expect(model.selectedIDs.isEmpty)
    #expect(removed == [Self.sha(0), Self.sha(1), Self.sha(2)])
    for file in [thumbnail, original, share] {
      #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.path)")
    }
    #expect(model.unfinishedDeletions.isEmpty)
    #expect(model.deletionBanner == nil)
    #expect(model.deletionProgress == nil)
    let states = try await states(f.database)
    #expect(Set(states.keys) == [Self.sha(3)])
  }

  // MARK: - Failure and resume

  @Test("A 403 leaves a banner with a readable reason and a ⚠ badge; Retry resumes, Restore brings it back")
  func failureBannerRetryRestore() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    DeletionBucket.reset(
      allow: ["blog/a.png", "blog/b.png"],
      objects: ["blog/a.png": Self.sha(0), "blog/b.png": Self.sha(1)])
    DeletionBucket.deleteStatus = 403
    await model.loadInitialData()
    await show(.archived, model)
    model.selectedIDs = [try rowID(0, model)]
    await model.deletePermanentlyFromCommand()
    await model.confirmDeletion(try #require(model.pendingDeletion))

    #expect(DeletionBucket.forbidden.isEmpty)
    #expect(model.unfinishedDeletions.map(\.sha256) == [Self.sha(0)])
    let banner = try #require(model.deletionBanner)
    #expect(banner.title == "1 deletion didn’t finish")
    #expect(banner.detail.contains("The access key for images isn’t allowed to delete files (AccessDenied)."))
    #expect(!banner.detail.contains("ObjectDeleteError"))
    // A refused DELETE removed nothing, though the tombstone says it was sent.
    #expect(banner.detail.hasSuffix("their files are still in the bucket."))
    let archived = model.sidebarSections.flatMap(\.entries).first { $0.selection == .archived }
    #expect(archived?.warningCount == 1)

    // Closing hides the banner; the badge stays.
    model.dismissDeletionBanner()
    #expect(model.deletionBanner == nil)
    #expect(
      model.sidebarSections.flatMap(\.entries).first { $0.selection == .archived }?.warningCount
        == 1)

    // Retry: resume, through the banner's own button.
    DeletionBucket.deleteStatus = 204
    let traced = DeletionBucket.trace.count
    let view = DeletionBannerView(model: model, banner: banner).body
    let retry = try #require(buttonAction(in: view, label: { "\($0)".contains("\"Retry\"") }))
    retry()
    try await waitUntil { model.unfinishedDeletions.isEmpty && !model.isDeletionBusy }
    #expect(
      Array(DeletionBucket.trace.dropFirst(traced)) == [
        "HEAD /images/blog/a.png", "DELETE /images/blog/a.png", "HEAD /images/blog/a.png",
      ])
    #expect(model.deletionBanner == nil)

    // Another 403, then Restore to Library: b is archived again.
    DeletionBucket.deleteStatus = 403
    model.selectedIDs = [try rowID(1, model)]
    await model.deletePermanentlyFromCommand()
    await model.confirmDeletion(try #require(model.pendingDeletion))
    #expect(model.rows.map(\.item.asset.sha256) == [Self.sha(2)])
    let second = try #require(model.deletionBanner)
    let restore = try #require(
      buttonAction(
        in: DeletionBannerView(model: model, banner: second).body,
        label: { "\($0)".contains("\"Restore to Library\"") }))
    restore()
    try await waitUntil { model.unfinishedDeletions.isEmpty && !model.isDeletionBusy }
    #expect(model.rows.map(\.item.asset.sha256) == [Self.sha(2), Self.sha(1)])
    #expect(try await states(f.database)[Self.sha(1)] == "archived")
    #expect(model.deletionNotice == "Restored 1 image to Archived.")
    #expect(DeletionBucket.forbidden.isEmpty)
  }

  @Test("At launch, unfinished deletions show the banner and badge and send nothing")
  func launchSendsNothing() async throws {
    let (database, directory) = try Self.seed()
    defer { try? FileManager.default.removeItem(at: directory) }
    DeletionBucket.reset(allow: [], objects: ["blog/a.png": Self.sha(0)])
    // Left by an earlier run: staged, never purged.
    let staged = try DeletingCatalog(database: database, remote: Self.remote(RemoteCalls()))
      .stage(deleting: [Self.sha(0)], keeping: [])
    #expect(staged.count == 1)

    let calls = RemoteCalls()
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-t25-\(UUID().uuidString)"))
    let app = PinaxAppModel(
      dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database },
      credentialExists: { _ in false }, deletionRemote: Self.remote(calls))
    await app.start()
    let gallery = try #require(app.gallery)
    #expect(gallery.onAssetsDeleted != nil, "the drop zone's cards are wired to go")
    await gallery.loadInitialData()
    await show(.archived, gallery)

    #expect(gallery.unfinishedDeletions.map(\.sha256) == [Self.sha(0)])
    let banner = try #require(gallery.deletionBanner)
    #expect(banner.title == "1 deletion didn’t finish")
    #expect(banner.detail.contains("Pinax stopped before the files were deleted"))
    #expect(
      gallery.sidebarSections.flatMap(\.entries).first { $0.selection == .archived }?.warningCount
        == 1)
    #expect(DeletionBucket.trace.isEmpty)
    #expect(calls.value == 0)
    app.dropZone?.setEnabled(false)
  }

  @Test("A deleted image's drop zone card goes; another's stays")
  func dropZoneCardsGo() async throws {
    let model = DropZoneModel(
      service: OneShotUpload(),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-t25-zone-\(UUID().uuidString)", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    model.drop(fileURLs: [URL(fileURLWithPath: "/tmp/0.png"), URL(fileURLWithPath: "/tmp/1.png")])
    try await waitUntil {
      model.cards.count == 2
        && model.cards.allSatisfy { if case .done = $0.phase { true } else { false } }
    }
    model.removeCards(for: [Self.sha(0)])
    #expect(model.cards.map(\.phase).compactMap { phase -> String? in
      if case let .done(outcome) = phase { outcome.sha256 } else { nil }
    } == [Self.sha(1)])
  }

  @Test("The banner's and sheet's symbols exist")
  func symbols() {
    for name in ["exclamationmark.triangle.fill", "xmark"] {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("timed out")
  }
}

/// Uploads "/tmp/<n>.png" as sha(n), nowhere.
private struct OneShotUpload: DropZoneService {
  func projects() throws -> [Project] { [] }

  func upload(_ fileURL: URL, projectSlug: String?) async throws -> UploadOutcome {
    let index = Int(fileURL.deletingPathExtension().lastPathComponent) ?? 0
    return UploadOutcome(
      sha256: PermanentDeletionTests.sha(index), key: "blog/\(index).png",
      url: "https://img.example.com/blog/\(index).png", mime: "image/png",
      originalFilename: "\(index).png", byteSize: 1, width: 1, height: 1,
      uploadedAt: "2026-08-22T00:00:00Z", deduplicated: false, dryRun: false)
  }

  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws {}
}

/// A fake S3 bucket on this target's host: bucket `images`, path style.
private final class DeletionBucket: URLProtocol {
  static let host = "s3.t25.invalid"
  nonisolated(unsafe) private static var state = State()
  private static let lock = NSLock()

  struct State {
    var objects: [String: String?] = [:]
    var allow: Set<String> = []
    var trace: [String] = []
    var forbidden: [String] = []
    var deleteStatus = 204
  }

  static func reset(allow keys: Set<String>, objects: [String: String?]) {
    lock.withLock { state = State(objects: objects, allow: keys) }
  }

  static var trace: [String] { lock.withLock { state.trace } }
  static var forbidden: [String] { lock.withLock { state.forbidden } }
  static var deleteStatus: Int {
    get { lock.withLock { state.deleteStatus } }
    set { lock.withLock { state.deleteStatus = newValue } }
  }

  static var session: URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeletionBucket.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let method = request.httpMethod ?? "?"
    let path = request.url?.path(percentEncoded: true) ?? ""
    let key = String(path.dropFirst("/images/".count)).removingPercentEncoding ?? ""
    let (status, headers): (Int, [String: String]) = Self.lock.withLock {
      Self.state.trace.append("\(method) \(path)")
      guard request.url?.host == Self.host, path.hasPrefix("/images/") else {
        Self.state.forbidden.append("\(method) \(request.url?.absoluteString ?? "?")")
        return (418, [:])
      }
      switch method {
      case "HEAD":
        guard let sha = Self.state.objects[key] else { return (404, [:]) }
        var headers = ["Content-Length": "1"]
        if let sha { headers["x-amz-meta-sha256"] = sha }
        return (200, headers)
      case "DELETE":
        guard Self.state.allow.contains(key) else {
          Self.state.forbidden.append("DELETE \(path)")
          return (418, [:])
        }
        let status = Self.state.deleteStatus
        if (200..<300).contains(status) { Self.state.objects[key] = nil }
        return (status, [:])
      default:
        Self.state.forbidden.append("\(method) \(path)")
        return (418, [:])
      }
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
