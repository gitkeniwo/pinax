import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `pinax optimize --dry-run`. The store is a fake, and the runs of the built
/// binary all stop before a request.
@Suite struct OptimizeCommandTests {
  private struct FakeStore: ObjectReading {
    var objects: [String: Data] = [:]

    func getObject(key: String) async throws -> S3StoredObject {
      guard let body = objects[key] else { throw ObjectReadError.notFound(key) }
      return S3StoredObject(
        key: key, data: body, etag: "\"e\"", contentType: "image/jpeg", cacheControl: nil,
        contentLength: Int64(body.count), lastModified: nil, metadata: [:])
    }
  }

  private func parse(_ arguments: [String]) throws -> OptimizeCommand {
    try #require(try Pinax.parseAsRoot(["optimize"] + arguments) as? OptimizeCommand)
  }

  /// Two JPEG rows whose hashes match `FakeStore`'s bytes, and one PNG.
  private func catalog() throws -> (
    database: DatabasePool, directory: URL, backend: Backend, store: FakeStore
  ) {
    let (database, directory) = try makeUITestDatabase()
    var store = FakeStore()
    try database.write { db in
      for (key, mime) in [("p/full.jpg", "image/jpeg"), ("p/sq.jpg", "image/jpeg"),
        ("p/mask.png", "image/png")]
      {
        let data = Data("bytes of \(key)".utf8)
        store.objects[key] = data
        _ = try Asset(
          sha256: Hashing.sha256(of: data), backendID: 1, key: key, byteSize: Int64(data.count),
          mime: mime, uploadedAt: "2026-08-01T00:00:00Z", createdAt: "2026-08-01T00:00:00Z",
          updatedAt: "2026-08-01T00:00:00Z"
        ).insertAndFetch(db)
      }
    }
    return (database, directory, try CatalogConfiguration.backend(slug: "r2", in: database), store)
  }

  @Test("Defaults: fifty samples, 2048 pixels, high quality, no metadata")
  func defaults() throws {
    let command = try parse(["--backend", "r2", "--dry-run"])
    #expect(command.backend == "r2" && command.prefix == "" && command.name == [])
    #expect(command.sample.count == 50 && command.seed == nil && command.format == .table)
    #expect(command.options == .default)
  }

  @Test("Every option parses, and --name repeats")
  func options() throws {
    let command = try parse([
      "--backend", "r2", "--prefix", "p/", "--name", "full.jpg", "--name", "sq.jpg", "--dry-run",
      "--sample", "all", "--longest-edge", "none", "--quality", "small", "--keep-metadata",
      "--seed", "42", "--format", "json",
    ])
    #expect(command.prefix == "p/" && command.name == ["full.jpg", "sq.jpg"])
    #expect(command.sample.count == nil && command.seed == 42 && command.format == .json)
    #expect(
      command.options
        == CompressionOptions(longestEdge: nil, quality: .small, removesMetadata: false))
    let sized = try parse(["--backend", "r2", "--dry-run", "--sample", "7", "--longest-edge", "900"])
    #expect(sized.sample.count == 7 && sized.options.longestEdge == 900)
  }

  @Test("Without --dry-run, and with a bad value, the command line is rejected")
  func badArguments() {
    for arguments in [
      ["--backend", "r2"], ["--backend", "r2", "--apply"], ["--dry-run"],
      ["--backend", "r2", "--dry-run", "--sample", "0"],
      ["--backend", "r2", "--dry-run", "--sample", "some"],
      ["--backend", "r2", "--dry-run", "--longest-edge", "0"],
      ["--backend", "r2", "--dry-run", "--quality", "best"],
      ["--backend", "r2", "--dry-run", "--seed", "-1"],
      ["--backend", "r2", "--dry-run", "--name", "a/full.jpg"],
      ["--backend", "r2", "--dry-run", "--name", ""],
    ] {
      do {
        _ = try Pinax.parseAsRoot(["optimize"] + arguments)
        Issue.record("parsed \(arguments)")
      } catch {
        #expect(Pinax.exitCode(for: error) == .validationFailure, "\(arguments)")
      }
    }
  }

  @Test("JSON has every key, with null for a missing value")
  func json() async throws {
    let (database, directory, backend, store) = try catalog()
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = try parse([
      "--backend", "r2", "--dry-run", "--sample", "all", "--longest-edge", "none", "--format",
      "json",
    ])
    let output = try await command.perform(backend: backend, reader: store, database: database)
    #expect(output.warnings.isEmpty)
    let document = try #require(
      try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
    #expect(
      Set(document.keys) == [
        "schema", "mode", "run_id", "backend", "prefix", "names", "options", "seed", "selection",
        "sample", "skipped", "hash_mismatch", "read_failures", "estimate", "untouched", "by_name",
      ])
    #expect(document["schema"] as? String == "pinax.optimize.v1")
    #expect(document["mode"] as? String == "dry_run")
    let options = try #require(document["options"] as? [String: Any])
    #expect(options["longest_edge"] is NSNull)
    #expect(options["fingerprint"] as? String == "enone-qhigh-m1")
    let sample = try #require(document["sample"] as? [String: Any])
    #expect(
      Set(sample.keys) == [
        "requested", "images", "measured", "bytes_before", "bytes_after", "saved_ratio",
      ])
    #expect(sample["requested"] is NSNull)
    #expect(sample["images"] as? Int == 2)
    #expect(
      Set(try #require(document["skipped"] as? [String: Int]).keys) == [
        "not_smaller", "transparent", "animated", "unsupported_format", "unreadable",
        "format_would_change", "duplicate_hash", "unsupported_headers",
      ])
    #expect(document["read_failures"] as? [String: Int] == ["not_found": 0, "read_failed": 0])
    let estimate = try #require(document["estimate"] as? [String: Any])
    #expect(estimate["estimate"] as? Bool == true)
    #expect(Set(estimate.keys) == ["estimate", "bytes_after", "saved_bytes"])
    let untouched = try #require(document["untouched"] as? [String: [String: Int]])
    #expect(untouched["png"]?["images"] == 1 && untouched["other"]?["images"] == 0)
    let names = try #require(document["by_name"] as? [[String: Any]])
    #expect(Set(names.compactMap { $0["name"] as? String }) == ["full.jpg", "sq.jpg"])
    for row in names {
      #expect(
        Set(row.keys) == [
          "name", "merged_names", "images", "bytes", "sampled", "measured", "sample_bytes_before",
          "sample_bytes_after", "saved_ratio",
        ])
      #expect(row["merged_names"] is NSNull)
    }
  }

  @Test("The table says it is a dry run and lists each name; unread and changed objects warn")
  func table() async throws {
    let (database, directory, backend, full) = try catalog()
    defer { try? FileManager.default.removeItem(at: directory) }
    var store = full
    store.objects["p/full.jpg"] = Data("something else".utf8)
    store.objects["p/sq.jpg"] = nil
    let command = try parse(["--backend", "r2", "--dry-run", "--name", "full.jpg", "--name", "sq.jpg"])
    let output = try await command.perform(backend: backend, reader: store, database: database)
    #expect(output.stdout.hasPrefix("Run 1 · dry run · nothing was changed\n"))
    #expect(output.stdout.contains("prefix: (every key)\n"))
    #expect(output.stdout.contains("names: full.jpg, sq.jpg\n"))
    #expect(output.stdout.contains("hash mismatches: 1\n"))
    #expect(output.stdout.contains("NAME\tSELECTED\tSIZE\tSAMPLE\tBEFORE\tAFTER\tSAVED\n"))
    #expect(output.stdout.contains("\nsq.jpg\t1\t17 B\t1\t-\t-\t-\n"))
    #expect(output.warnings.count == 2)
    #expect(output.warnings.first?.contains("1 of 2 sampled objects differ") == true)
    #expect(output.warnings.last?.contains("pinax runs show 1") == true)
  }

  @Test("Sizes use decimal units")
  func sizes() {
    #expect(OptimizeTable.size(999) == "999 B")
    #expect(OptimizeTable.size(41_200_000) == "41.2 MB")
    #expect(OptimizeTable.size(999_999) == "1.0 MB")
    #expect(OptimizeTable.size(1_920_000_000) == "1.9 GB")
  }

  @Test("An empty selection is not found and an unreadable sample is a remote failure")
  func exitCodes() {
    #expect(
      CLIExit.code(for: OptimizeError.noImages(backend: "r2", prefix: "", names: [])) == 66)
    #expect(
      CLIExit.code(for: OptimizeError.nothingRead(runID: 1, sampled: 2, firstFailure: "x")) == 69)
  }

  @Test("The binary: 64 without --dry-run, 66 for an unknown backend or no rows, 78 without credentials")
  func binary() throws {
    let (_, directory) = try makeCLITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try CLIProcess.run(["optimize", "--backend", "r2"], in: directory).status == 64)
    #expect(
      try CLIProcess.run(["optimize", "--backend", "nope", "--dry-run"], in: directory).status == 66)
    #expect(
      try CLIProcess.run(["optimize", "--backend", "r2", "--dry-run"], in: directory).status == 78)
    // The shared catalog holds only PNG rows.
    let empty = try CLIProcess.run(
      ["optimize", "--backend", "r2", "--dry-run"], in: directory,
      environment: ["PINAX_ACCESS_KEY_ID": "test", "PINAX_SECRET_ACCESS_KEY": "test"])
    #expect(empty.status == 66)
    #expect(empty.stderr == "Error: No active JPEG assets on backend r2.\n")
    #expect(empty.stdout.isEmpty)
  }
}
