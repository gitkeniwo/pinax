import ArgumentParser
import CatalogCore
import CryptoKit
import Foundation

/// `pinax object head|get`: one object by backend and key, read from the bucket
/// with a signed request rather than from its public URL. Nothing is written to
/// the bucket or added to the catalog. Each command's `output` is what `run()`
/// prints, so tests drive the parsed command with a stub store.
struct ObjectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "object",
    abstract: "Read one object from a backend's bucket.",
    subcommands: [ObjectHeadCommand.self, ObjectGetCommand.self]
  )
}

struct ObjectLocation: ParsableArguments {
  @Option(help: "Backend whose bucket to read.")
  var backend: String

  @Argument(help: "The object's exact key.")
  var key: String

  func validate() throws {
    // An empty key would address the bucket itself.
    guard !key.isEmpty else { throw ValidationError("Key must not be empty.") }
  }

  func inventory() throws -> S3ObjectInventory {
    let selected = try CatalogConfiguration.backend(slug: backend, in: openCatalogDatabase())
    return S3ObjectInventory(backend: selected, credentials: try reindexCredentials(for: selected))
  }
}

struct ObjectHeadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "head",
    abstract: "Show an object's headers."
  )

  @OptionGroup var location: ObjectLocation

  @Option(help: "table or json.")
  var format: OutputFormat = .table

  mutating func run() async throws {
    print(try await output(from: location.inventory()), terminator: "")
  }

  /// `Content-Type` is the media type, without parameters.
  func output(from inventory: any ObjectInventory) async throws -> String {
    let head: S3ObjectHead
    do {
      head = try await inventory.headObject(key: location.key)
    } catch S3UploaderError.http(statusCode: 404, _) {
      throw ObjectReadError.notFound(location.key)
    }
    if format == .json {
      return try encodedJSON(ObjectDocument(head, backend: location.backend)) + "\n"
    }
    var lines = [
      "content-type: \(head.mime ?? "")",
      "content-length: \(head.byteSize)",
      "etag: \(head.etag ?? "")",
      "cache-control: \(head.cacheControl ?? "")",
    ]
    if head.metadata.isEmpty {
      lines.append("metadata: none")
    } else {
      lines.append("metadata:")
      lines += head.metadata.sorted { $0.key < $1.key }.map { "  \($0.key)\t\($0.value)" }
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

struct ObjectGetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get",
    abstract: "Save an object's bytes to a new file and print their SHA-256."
  )

  @OptionGroup var location: ObjectLocation

  @Option(name: [.short, .long], help: "File to create. An existing file is never replaced.")
  var output: String

  mutating func run() async throws {
    // Before credentials are read or anything is requested.
    try refuseExistingOutput()
    print(try await save(from: location.inventory()))
  }

  /// Writes the object to `output` and returns the SHA-256 of what was
  /// written.
  func save(from reader: any ObjectReading) async throws -> String {
    try refuseExistingOutput()
    let object = try await reader.getObject(key: location.key)
    do {
      try object.data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    } catch CocoaError.fileWriteFileExists {
      throw outputExists
    }
    return SHA256.hash(data: object.data).map { String(format: "%02x", $0) }.joined()
  }

  private func refuseExistingOutput() throws {
    // Unlike `fileExists`, this also sees a symbolic link that leads nowhere.
    if (try? FileManager.default.attributesOfItem(atPath: output)) != nil {
      throw outputExists
    }
  }

  private var outputExists: CLIError {
    .refused("Refusing to replace an existing file: \(output)")
  }
}
