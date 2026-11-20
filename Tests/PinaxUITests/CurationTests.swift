import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Archive, favourites and labels. Properties:
///
/// 1. An archived asset leaves every default view, every count (the grid's,
///    the summaries', the Catalog tree's — per prefix row — and the time
///    tree's) and shows under Archived; Put Back returns every one of them
///    exactly, favourite and labels included.
/// 2. Archive and Put Back send no object-store request: the gallery's
///    storage seams are counting fakes and stay at zero, and the edit path
///    holds a database and nothing else.
/// 3. Favourites and labels survive a restart; Labels lists only the colours
///    in use, in Finder's order.
/// 4. A batch, or anything with live usage, asks once; the dialog carries
///    the count and says the links keep working.
@MainActor
@Suite(.serialized) struct CurationTests {
  /// Every object-store read the gallery can make — originals and
  /// thumbnails — lands here.
  final class CountingStore: PublicObjectFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var requests: [URL] { lock.withLock { urls } }

    func record(_ url: URL) {
      lock.withLock { urls.append(url) }
    }

    func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
      record(url)
      throw PublicObjectFetchError.notFound(url)
    }
  }

  private static let iso8601 = ISO8601DateFormatter()

  /// Four assets; the target (index 0) is recent, in `blog/sub` beside one
  /// other, tagged `hero`, in project blog. The others keep every surface
  /// the target is on non-empty, so "left the view" is visible as a count
  /// that drops by one rather than a view that empties.
  private func makeModel(
    store: CountingStore = CountingStore()
  ) throws -> (GalleryModel, DatabasePool, URL, String) {
    let (database, directory) = try makeUITestDatabase()
    let recent = Self.iso8601.string(from: Date().addingTimeInterval(-24 * 3600))
    // One second apart, so both land in one month (an hour apart, they split
    // across a month boundary for the first hour of every month's 2nd day).
    let recentOther = Self.iso8601.string(from: Date().addingTimeInterval(-24 * 3600 - 1))
    try seedAsset(database, index: 0, uploadedAt: recent, tag: "hero", key: "blog/sub/a.png")
    try seedAsset(database, index: 1, uploadedAt: recentOther, tag: "hero", key: "blog/sub/b.png")
    try seedAsset(database, index: 2, uploadedAt: "2026-07-10T00:00:00Z", key: "blog/c.png")
    try seedAsset(
      database, index: 3, uploadedAt: "2026-07-11T00:00:00Z", projectSlug: "notes",
      key: "notes/d.png")
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { url in
          store.record(url)
          throw URLError(.unsupportedURL)
        }))
    model.downloader = OriginalDownloader(fetcher: store)
    return (model, database, directory, recent)
  }

  private func show(_ selection: SidebarSelection, _ model: GalleryModel) async {
    model.select(selection, in: SidebarModel.navigator(for: selection))
    await model.reload()
  }

  private func id(_ index: Int, _ model: GalleryModel) async throws -> Int64 {
    await show(.all, model)
    let sha = String(format: "%064x", index + 1)
    return try #require(model.rows.first { $0.item.asset.sha256 == sha }?.id)
  }

  /// Everything a user can read off the default surfaces: each surface's
  /// rows (with favourite and labels) and total, the sidebar summaries, the
  /// loaded Catalog levels and the time tree.
  private func snapshot(
    _ model: GalleryModel, surfaces: [SidebarSelection]
  ) async -> [String: [String]] {
    var result: [String: [String]] = [:]
    for surface in surfaces {
      await show(surface, model)
      result["\(surface)"] =
        model.rows.map { row in
          "\(row.id)\(row.isFavorite ? "♥" : "")\(row.labels.map(\.rawValue))"
        } + ["total \(model.totalCount ?? -1)"]
    }
    result["tags"] = model.tags.map { "\($0.name):\($0.assetCount)" }
    result["projects"] = model.projects.map { "\($0.slug):\($0.assetCount)" }
    result["labels"] = model.labels.map { "\($0.label.rawValue):\($0.assetCount)" }
    let levels: [KeyPrefixLevel] = Array(model.folderChildren.keys)
    var tree: [String] = []
    for level in levels.sorted(by: { ($0.prefix ?? "") < ($1.prefix ?? "") }) {
      let key = level.prefix ?? ""
      for child in model.folderChildren[level] ?? [] {
        tree.append("\(key)>\(child.segment):\(child.assetCount)")
      }
    }
    result["tree"] = tree
    result["months"] = model.availableMonths.map { "\($0.month):\($0.count)" }
    return result
  }

  // MARK: - property 1

  @Test("Archive leaves every default view and count; Put Back returns them exactly")
  func archiveAndPutBack() async throws {
    let (model, _, directory, recent) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.loadInitialData()
    await model.loadFolderChildren(under: "blog")
    let target = try await id(0, model)
    await model.toggleFavorite(.selection([target]))
    await model.toggleLabel(.red, for: .selection([target]))

    let year = String(recent.prefix(4))
    let month = String(recent.prefix(7))
    let surfaces: [SidebarSelection] = [
      .all, .recent, .favorites, .label(.red), .project("blog"), .tag("hero"),
      .year(year), .month(month), .keyPrefix("blog"), .keyPrefix("blog/sub"),
    ]
    let before = await snapshot(model, surfaces: surfaces)
    #expect(before["\(SidebarSelection.favorites)"] == ["\(target)♥[\"red\"]", "total 1"])

    await show(.all, model)
    await model.archive(.selection([target]))
    #expect(model.pendingArchive == nil, "one unreferenced item goes at once")

    let archived = await snapshot(model, surfaces: surfaces)
    for surface in surfaces {
      let rows = archived["\(surface)"] ?? []
      #expect(!rows.contains { $0.hasPrefix("\(target)") }, "\(surface) still shows it")
      let total = (before["\(surface)"]?.last).flatMap { Int($0.dropFirst(6)) } ?? 0
      #expect(rows.last == "total \(total - 1)", "\(surface)")
    }
    #expect(archived["tags"] == ["hero:1"])
    #expect(archived["projects"] == ["blog:2", "notes:1"])
    #expect(archived["labels"] == [], "red's only asset is archived: no Labels row")
    #expect(archived["tree"] == [">blog:2", ">notes:1", "blog>sub:1"])
    #expect(archived["months"]?.contains("\(month):1") == true)

    await show(.archived, model)
    #expect(model.rows.map(\.id) == [target])
    #expect(model.totalCount == 1)

    await model.putBack(.selection([target]))
    #expect(model.rows.isEmpty, "Put Back leaves the Archived surface")
    let restored = await snapshot(model, surfaces: surfaces)
    #expect(restored == before)
  }

  // MARK: - property 2

  @Test("Archive and Put Back send no object-store request")
  func noObjectStoreRequests() async throws {
    let store = CountingStore()
    let (model, database, directory, _) = try makeModel(store: store)
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.loadInitialData()
    let first = try await id(0, model)
    let second = try await id(1, model)
    try seedLiveUsage(database, projectSlug: "blog", sha256: String(format: "%064x", 2), count: 1)

    await show(.all, model)
    await model.archive(.selection([first]))
    await model.archive(.selection([second]))
    let pending = try #require(model.pendingArchive)
    await model.confirmArchive(pending)
    await show(.archived, model)
    #expect(Set(model.rows.map(\.id)) == [first, second])
    await model.putBack(.selection([first, second]))

    #expect(store.requests == [])
  }

  /// The edit path's only stored property is the database: a backend, an
  /// uploader or a fetcher added to it would be a way for an edit to reach
  /// the object store, and would turn this red.
  @Test("The edit path holds a database and nothing else")
  func editorHoldsOnlyTheDatabase() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let children = Mirror(reflecting: EditableCatalog(database: database)).children
    #expect(children.count == 1)
    #expect(children.allSatisfy { $0.value is DatabasePool })
  }

  // MARK: - property 3

  @Test("Favourites and labels survive a restart; Labels lists the colours in use in Finder order")
  func curationPersists() async throws {
    let (model, _, directory, _) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.loadInitialData()
    let target = try await id(2, model)
    await model.toggleFavorite(.selection([target]))
    await model.toggleLabel(.blue, for: .selection([target]))
    await model.toggleLabel(.red, for: .selection([target]))

    let reopened = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(reopened)
    let relaunched = GalleryModel(
      catalog: ReadOnlyCatalog(database: reopened),
      editor: EditableCatalog(database: reopened),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails2", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await relaunched.loadInitialData()

    await show(.favorites, relaunched)
    #expect(relaunched.rows.map(\.id) == [target])
    #expect(relaunched.rows.first?.labels == [.red, .blue])
    #expect(relaunched.labels.map(\.label) == [.red, .blue])
    relaunched.select(.label(.blue), in: .collections)
    let labelRows = relaunched.sidebarSections.first { $0.id == "labels" }?.entries
    #expect(labelRows?.map(\.label) == ["Red", "Blue"])
    await relaunched.reload()
    #expect(relaunched.rows.map(\.id) == [target])

    // Toggling off is a real removal: the colour leaves the Labels group.
    await relaunched.toggleLabel(.red, for: .selection([target]))
    #expect(relaunched.labels.map(\.label) == [.blue])
  }

  // MARK: - property 4

  @Test("A batch or a referenced item asks once, with the count and the links sentence")
  func archiveConfirmation() async throws {
    let (model, database, directory, _) = try makeModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    await model.loadInitialData()
    let referenced = try await id(1, model)
    let plain = try await id(2, model)
    try seedLiveUsage(database, projectSlug: "blog", sha256: String(format: "%064x", 2), count: 2)
    await show(.all, model)

    await model.archive(.selection([referenced, plain]))
    let batch = try #require(model.pendingArchive)
    #expect(batch.title == "Archive 2 items?")
    #expect(batch.liveUsageCount == 1)
    #expect(batch.message.contains("1 of them are still referenced by scanned documents"))
    #expect(batch.message.contains("links won't break, because the remote files are not deleted"))
    // `Manifest.swift` exports active assets only: an archived item leaves
    // its projects' manifests, and the dialog says so.
    #expect(batch.message.contains("manifest"))
    #expect(model.totalCount == 4, "nothing archived before the answer")
    model.cancelArchive()
    await model.reload()
    #expect(model.totalCount == 4, "cancel archives nothing")

    await model.archive(.selection([referenced]))
    let single = try #require(model.pendingArchive, "live usage asks even for one")
    #expect(single.title == "Archive “asset-1.png”?")
    #expect(single.message.hasPrefix("It is still referenced by scanned documents"))
    await model.confirmArchive(single)
    #expect(model.totalCount == 3)
    #expect(!model.rows.contains { $0.id == referenced })
  }
}
