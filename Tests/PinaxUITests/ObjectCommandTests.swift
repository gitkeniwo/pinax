import ArgumentParser
import CatalogCore
import Foundation
import Testing
@testable import pinax

/// `pinax object head|get`. The stores are fakes, and the runs of the built
/// binary all stop before a request.
@Suite struct ObjectCommandTests {
  private struct FakeStore: ObjectInventory, ObjectReading {
    var head: S3ObjectHead?
    var body = Data("abc".utf8)

    func listObjects() async throws -> [S3ObjectSummary] { [] }

    func headObject(key: String) async throws -> S3ObjectHead {
      guard let head else { throw S3UploaderError.http(statusCode: 404, body: "") }
      return head
    }

    func getObject(key: String) async throws -> S3StoredObject {
      S3StoredObject(
        key: key, data: body, etag: "\"e\"", contentType: nil, cacheControl: nil,
        contentLength: Int64(body.count), lastModified: nil, metadata: [:])
    }
  }

  private static let abcHash =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-object-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func parseHead(_ arguments: [String]) throws -> ObjectHeadCommand {
    try #require(
      try Pinax.parseAsRoot(["object", "head"] + arguments) as? ObjectHeadCommand)
  }

  private func parseGet(_ arguments: [String]) throws -> ObjectGetCommand {
    try #require(try Pinax.parseAsRoot(["object", "get"] + arguments) as? ObjectGetCommand)
  }

  @Test("head and get parse a backend, a key and their options")
  func parsing() throws {
    let head = try parseHead(["--backend", "r2", "a b/c.png"])
    #expect(head.location.backend == "r2")
    #expect(head.location.key == "a b/c.png")
    #expect(head.format == .table)
    #expect(try parseHead(["--backend", "r2", "k", "--format", "json"]).format == .json)
    let get = try parseGet(["--backend", "r2", "k", "-o", "out.bin"])
    #expect(get.output == "out.bin")
    #expect(try parseGet(["--backend", "r2", "k", "--output", "o"]).output == "o")
  }

  @Test("A missing backend, key or output, and an empty key, are bad arguments")
  func badArguments() {
    for arguments in [
      ["head", "k"], ["head", "--backend", "r2"], ["head", "--backend", "r2", ""],
      ["get", "--backend", "r2", "k"], ["get", "--backend", "r2", "", "-o", "f"],
    ] {
      do {
        _ = try Pinax.parseAsRoot(["object"] + arguments)
        Issue.record("parsed \(arguments)")
      } catch {
        #expect(Pinax.exitCode(for: error) == .validationFailure, "\(arguments)")
      }
    }
  }

  @Test("head prints the headers as a table")
  func headTable() async throws {
    let store = FakeStore(
      head: S3ObjectHead(
        key: "k", byteSize: 12, mime: "text/plain", lastModified: nil,
        metadata: ["width": "4", "sha256": "feed"], cacheControl: "no-store", etag: "\"e1\""))
    let output = try await parseHead(["--backend", "r2", "k"]).output(from: store)
    #expect(
      output == """
        content-type: text/plain
        content-length: 12
        etag: "e1"
        cache-control: no-store
        metadata:
          sha256\tfeed
          width\t4

        """)
  }

  @Test("head JSON has every key, with null for a missing value")
  func headJSON() async throws {
    let store = FakeStore(
      head: S3ObjectHead(key: "k", byteSize: 12, mime: nil, lastModified: nil, metadata: [:]))
    let output = try await parseHead(["--backend", "r2", "k", "--format", "json"])
      .output(from: store)
    let document = try #require(
      try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect(
      Set(document.keys) == [
        "schema", "backend", "key", "bytes", "content_type", "etag", "cache_control",
        "last_modified", "metadata",
      ])
    #expect(document["schema"] as? String == "pinax.object.v1")
    #expect(document["bytes"] as? Int == 12)
    for key in ["content_type", "etag", "cache_control", "last_modified"] {
      #expect(document[key] is NSNull, "\(key)")
    }
  }

  @Test("A HEAD answered 404 is not found")
  func headNotFound() async throws {
    let command = try parseHead(["--backend", "r2", "gone"])
    await #expect(throws: ObjectReadError.notFound("gone")) {
      _ = try await command.output(from: FakeStore(head: nil))
    }
  }

  @Test("get writes the bytes to a new file and returns their SHA-256")
  func save() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("out.bin")
    let command = try parseGet(["--backend", "r2", "k", "-o", file.path])
    #expect(try await command.save(from: FakeStore()) == Self.abcHash)
    #expect(try Data(contentsOf: file) == Data("abc".utf8))
    // The file is now there, so the same command refuses.
    await #expect(throws: CLIError.self) {
      _ = try await command.save(from: FakeStore(body: Data("other".utf8)))
    }
    #expect(try Data(contentsOf: file) == Data("abc".utf8))
  }

  @Test("get refuses an existing file or a dangling link with 77, before the catalog is read")
  func existingOutput() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("mine.txt")
    try Data("mine".utf8).write(to: file)
    let link = directory.appendingPathComponent("link")
    let target = directory.appendingPathComponent("absent")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    for path in [file.path, link.path] {
      // No catalog and no backend exist here: reaching either would not be 77.
      let result = try CLIProcess.run(
        ["object", "get", "--backend", "nope", "k", "-o", path], in: directory)
      #expect(result.status == 77)
      #expect(result.stderr == "Error: Refusing to replace an existing file: \(path)\n")
      #expect(result.stdout.isEmpty)
    }
    #expect(try Data(contentsOf: file) == Data("mine".utf8))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("catalog.sqlite").path))
  }

  @Test("An unknown backend is 66 and missing credentials are 78")
  func backendAndCredentials() throws {
    let (_, directory) = try makeCLITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let unknown = try CLIProcess.run(["object", "head", "--backend", "nope", "k"], in: directory)
    #expect(unknown.status == 66)
    let output = directory.appendingPathComponent("o").path
    for arguments in [["head"], ["get", "-o", output]] {
      let result = try CLIProcess.run(
        ["object"] + arguments + ["--backend", "r2", "k"], in: directory)
      #expect(result.status == 78, "\(arguments)")
    }
    #expect(!FileManager.default.fileExists(atPath: output))
  }

  @Test("Read errors map to not found and remote failure")
  func exitCodes() {
    #expect(CLIExit.code(for: ObjectReadError.notFound("k")) == 66)
    #expect(CLIExit.code(for: ObjectReadError.missingETag("k")) == 69)
    #expect(
      CLIExit.code(
        for: ObjectReadError.lengthMismatch(
          key: "k", expected: 2, received: 1, contentEncoding: nil)) == 69)
  }
}
