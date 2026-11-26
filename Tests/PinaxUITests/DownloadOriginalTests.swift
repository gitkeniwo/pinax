import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Download Original. Properties:
///
/// 1. The bytes on disk hash to the catalog's sha256 (fake fetcher); bytes
///    that do not are refused and nothing is written.
/// 2. A taken name gets Finder's " 2", " 3" suffix; an existing file is never
///    overwritten.
/// 3. In a batch a failed item does not stop the rest, and its sentence
///    lands on the status bar's right side.
@MainActor
@Suite(.serialized) struct DownloadOriginalTests {
  /// Serves bytes by the URL's last path component; anything else is a 404.
  struct FakeFetcher: PublicObjectFetching {
    let objects: [String: Data]

    func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
      guard let data = objects[url.lastPathComponent] else {
        throw PublicObjectFetchError.notFound(url)
      }
      return (data, "image/png", Int64(data.count))
    }
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-downloads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
  private let source = URL(string: "https://img.example.com/blog/shot.png")!

  // MARK: - property 1

  @Test("Saved bytes hash to the catalog's sha256")
  func savedBytesMatchCatalog() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sha = Hashing.sha256(of: bytes)
    let downloader = OriginalDownloader(fetcher: FakeFetcher(objects: ["shot.png": bytes]))

    let saved = try await downloader.download(
      DownloadRequest(sha256: sha, sourceURL: source, filename: "shot.png"), to: folder)

    #expect(saved.lastPathComponent == "shot.png")
    #expect(try Hashing.sha256(ofFileAt: saved) == sha)
  }

  @Test("Bytes that do not match the catalog are refused, nothing written")
  func mismatchWritesNothing() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let downloader = OriginalDownloader(fetcher: FakeFetcher(objects: ["shot.png": bytes]))

    await #expect(throws: OriginalDownloadError.checksumMismatch) {
      _ = try await downloader.download(
        DownloadRequest(
          sha256: Hashing.sha256(of: Data("other".utf8)), sourceURL: source, filename: "shot.png"),
        to: folder)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  // MARK: - property 2

  @Test("A taken name gets the next Finder suffix; existing files keep their bytes")
  func takenNameNeverOverwritten() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = Data("already here".utf8)
    let second = Data("also already here".utf8)
    try first.write(to: folder.appendingPathComponent("shot.png"))
    try second.write(to: folder.appendingPathComponent("shot 2.png"))
    let sha = Hashing.sha256(of: bytes)
    let downloader = OriginalDownloader(fetcher: FakeFetcher(objects: ["shot.png": bytes]))
    let request = DownloadRequest(sha256: sha, sourceURL: source, filename: "shot.png")

    let saved = try await downloader.download(request, to: folder)
    let again = try await downloader.download(request, to: folder)

    #expect(saved.lastPathComponent == "shot 3.png")
    #expect(again.lastPathComponent == "shot 4.png")
    #expect(try Data(contentsOf: folder.appendingPathComponent("shot.png")) == first)
    #expect(try Data(contentsOf: folder.appendingPathComponent("shot 2.png")) == second)
    #expect(try Hashing.sha256(ofFileAt: saved) == sha)
  }

  @Test("Finder suffix without an extension, and on a multi-dot name")
  func suffixShapes() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data().write(to: folder.appendingPathComponent("README"))
    try Data().write(to: folder.appendingPathComponent("Screen Shot.v2.png"))

    #expect(
      OriginalDownloader.availableURL(for: "README", in: folder).lastPathComponent == "README 2")
    #expect(
      OriginalDownloader.availableURL(for: "Screen Shot.v2.png", in: folder).lastPathComponent
        == "Screen Shot.v2 2.png")
  }

  @Test("A filename with separators saves as one path component inside the folder")
  func filenameStaysInFolder() {
    #expect(OriginalDownloader.downloadFilename("../../etc/shot.png", key: "blog/k.png") == "shot.png")
    #expect(OriginalDownloader.downloadFilename("", key: "blog/k.png") == "k.png")
  }

  // MARK: - property 3

  @Test("A failed item in the middle of a batch does not stop the rest; its error is on the status bar")
  func batchFailureIsolated() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    // Grid order is newest first: asset-2, asset-1, asset-0. asset-1 — the
    // middle one — is missing from the fake store.
    var objects: [String: Data] = [:]
    for index in 0..<3 {
      try seedAsset(
        database, index: index, uploadedAt: String(format: "2026-08-20T12:%02d:00Z", index))
      let data = Data("original \(index)".utf8)
      try await database.write { db in
        try db.execute(
          sql: "UPDATE asset SET sha256 = ? WHERE key = ?",
          arguments: [Hashing.sha256(of: data), "blog/asset-\(index).png"])
      }
      if index != 1 { objects["asset-\(index).png"] = data }
    }

    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    model.downloader = OriginalDownloader(fetcher: FakeFetcher(objects: objects))
    model.downloadFolder = folder
    var revealed: [URL] = []
    model.revealDownloads = { revealed = $0 }
    await model.loadInitialData()
    #expect(model.rows.map(\.item.asset.key) == ["blog/asset-2.png", "blog/asset-1.png", "blog/asset-0.png"])

    model.selectedIDs = Set(model.rows.map(\.id))
    await model.downloadSelection()

    #expect(revealed.map(\.lastPathComponent) == ["asset-2.png", "asset-0.png"])
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        == ["asset-0.png", "asset-2.png"])
    let expected = "Couldn't download 1 of 3 — asset-1.png: it no longer exists (HTTP 404)"
    #expect(model.downloadError == expected)
    #expect(GalleryStatusBar(model: model).activityText == expected)
    #expect(!model.isDownloading)
  }

  @Test("The download folder defaults to Downloads and a chosen one survives a restart")
  func folderPersists() throws {
    let suite = "PinaxDownloadTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let fresh = PreferencesStore(defaults: defaults)
    #expect(fresh.downloadFolder == OriginalDownloader.defaultFolder)
    var pushed: URL?
    fresh.onDownloadFolderChange = { pushed = $0 }
    fresh.downloadFolderPath = "/Users/someone/Pictures/blog"

    #expect(pushed?.path == "/Users/someone/Pictures/blog")
    #expect(PreferencesStore(defaults: defaults).downloadFolder.path == "/Users/someone/Pictures/blog")
  }
}
