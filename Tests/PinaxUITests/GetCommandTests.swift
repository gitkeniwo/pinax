import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `pinax get`. The public store is a URLProtocol stub on a host that cannot
/// resolve; exit statuses come from the built binary.
@Suite(.serialized) struct GetCommandTests {
  private final class StoreStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var objects: [String: Data] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ served: [String: Data]) {
      lock.withLock {
        objects = served
        requests = []
      }
    }

    static var captured: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
      let url = request.url!
      let data = Self.lock.withLock {
        Self.requests.append(request)
        return url.host == "img.example.invalid" ? Self.objects[url.path] : nil
      }
      let response = HTTPURLResponse(
        url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1",
        headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data ?? Data())
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  private struct Run {
    var status: Int32 = 0
    var saved: [String] = []
    var failed: [String] = []
  }

  private let keys = ["blog/asset-0.png", "blog/asset-1.png", "blog/asset-2.png"]

  /// Three assets whose catalog hashes match `bytes(index)`, all served.
  private func withFixture(
    _ body: (DatabasePool, URL, URL) async throws -> Void
  ) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<3 {
      try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
    }
    try await database.write { [self] db in
      try db.execute(sql: "UPDATE backend SET url_prefix = 'https://img.example.invalid'")
      for (index, key) in keys.enumerated() {
        try db.execute(
          sql: "UPDATE asset SET sha256 = ? WHERE key = ?",
          arguments: [Hashing.sha256(of: bytes(index)), key])
      }
    }
    StoreStub.reset(
      Dictionary(uniqueKeysWithValues: keys.enumerated().map { ("/" + $1, bytes($0)) }))
    try await body(database, directory, directory.appendingPathComponent("out/originals"))
  }

  private func bytes(_ index: Int) -> Data { Data("original \(index)".utf8) }

  private func get(
    _ identifiers: [String], to folder: URL, in database: DatabasePool
  ) async throws -> Run {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StoreStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var run = Run()
    var saved: [String] = []
    var failed: [String] = []
    run.status = try await GetCommandOperations.download(
      identifiers, to: folder, in: database,
      with: OriginalDownloader(fetcher: URLSessionPublicObjectFetcher(session: session)),
      saved: { saved.append($0.lastPathComponent) }, failed: { failed.append($0) })
    run.saved = saved
    run.failed = failed
    return run
  }

  private func files(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  @Test("Originals are saved under their filenames, in the order named, into a new folder")
  func saves() async throws {
    try await withFixture { database, _, folder in
      let run = try await get([keys[1], keys[0], keys[1]], to: folder, in: database)

      #expect(run.status == 0)
      #expect(run.saved == ["asset-1.png", "asset-0.png"])
      #expect(try Data(contentsOf: folder.appendingPathComponent("asset-0.png")) == bytes(0))
      #expect(try Data(contentsOf: folder.appendingPathComponent("asset-1.png")) == bytes(1))
      #expect(
        StoreStub.captured.map { $0.url?.absoluteString } == [
          "https://img.example.invalid/blog/asset-1.png",
          "https://img.example.invalid/blog/asset-0.png",
        ])
      #expect(
        StoreStub.captured.allSatisfy {
          $0.value(forHTTPHeaderField: "User-Agent") == URLSessionPublicObjectFetcher.userAgent
        })
    }
  }

  @Test("A taken name gets a suffix; a missing or path-like filename stays inside the folder")
  func naming() async throws {
    try await withFixture { database, _, folder in
      try await database.write { db in
        try db.execute(sql: "UPDATE asset SET orig_filename = 'shot.png' WHERE id = 1")
        try db.execute(sql: "UPDATE asset SET orig_filename = '../../shot.png' WHERE id = 2")
        try db.execute(sql: "UPDATE asset SET orig_filename = NULL WHERE id = 3")
      }
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let existing = Data("already here".utf8)
      try existing.write(to: folder.appendingPathComponent("shot.png"))

      let run = try await get(keys, to: folder, in: database)

      #expect(run.saved == ["shot 2.png", "shot 3.png", "asset-2.png"])
      #expect(files(in: folder) == ["asset-2.png", "shot 2.png", "shot 3.png", "shot.png"])
      #expect(try Data(contentsOf: folder.appendingPathComponent("shot.png")) == existing)
    }
  }

  @Test("A bad identifier fetches and writes nothing")
  func badIdentifier() async throws {
    try await withFixture { database, _, folder in
      await #expect(throws: AssetCatalogError.self) {
        _ = try await get([keys[0], "blog/none.png"], to: folder, in: database)
      }
      #expect(StoreStub.captured.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
  }

  @Test("A missing object and wrong bytes are remote failures that do not stop the rest")
  func failures() async throws {
    try await withFixture { database, _, folder in
      StoreStub.reset(["/\(keys[1])": Data("not these".utf8), "/\(keys[2])": bytes(2)])

      let run = try await get(keys, to: folder, in: database)

      #expect(run.status == 69)
      #expect(run.saved == ["asset-2.png"])
      #expect(
        run.failed == [
          "\(keys[0]): it no longer exists (HTTP 404)",
          "\(keys[1]): the downloaded bytes don't match the catalog's SHA-256",
        ])
      #expect(files(in: folder) == ["asset-2.png"])
    }
  }

  @Test("The binary exits 69 for an unreachable store, 66 for a bad identifier, 64 without -o")
  func exitStatuses() async throws {
    try await withFixture { database, directory, folder in
      try await database.write { db in
        try db.execute(sql: "UPDATE backend SET url_prefix = 'http://127.0.0.1:9'")
      }
      let unreachable = try CLIProcess.run(["get", keys[0], "-o", folder.path], in: directory)
      #expect(unreachable.status == 69, "\(unreachable.stderr)")
      #expect(unreachable.stdout.isEmpty)
      #expect(unreachable.stderr.hasPrefix("\(keys[0]): "), "\(unreachable.stderr)")

      let unknown = try CLIProcess.run(
        ["get", "deadbeef", "--output", folder.path], in: directory)
      #expect(unknown.status == 66, "\(unknown.stderr)")

      let noFolder = try CLIProcess.run(["get", keys[0]], in: directory)
      #expect(noFolder.status == 64, "\(noFolder.stderr)")
    }
  }
}
