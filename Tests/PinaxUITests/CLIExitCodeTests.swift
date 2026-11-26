import CatalogCore
import Foundation
import Testing
@testable import pinax

/// What `pinax` exits with: one real run per status, then the table itself.
@Suite struct CLIExitCodeTests {
  private func run(
    _ arguments: [String], environment: [String: String] = [:]
  ) throws -> CLIProcess.Result {
    let (_, directory) = try makeCLITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    return try CLIProcess.run(arguments, in: directory, environment: environment)
  }

  @Test("--help prints the table")
  func help() throws {
    let help = try run(["--help"])
    #expect(help.status == 0)
    let flat = help.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    for entry in [
      "0 success", "1 other failure", "64 bad argument", "66 not found", "69 remote failure",
      "77 refused by a safeguard", "78 credentials missing",
    ] {
      #expect(flat.contains(entry), "missing \(entry)")
    }
  }

  @Test("A bad argument is 64, with usage")
  func badArgument() throws {
    let result = try run(["ls", "--limit", "0"])
    #expect(result.status == 64)
    #expect(result.stderr.hasPrefix("Error: Limit must be greater than zero.\n"))
    #expect(result.stderr.contains("Usage:"))
  }

  @Test("Another failure is 1, without usage")
  func otherFailure() throws {
    let result = try run([
      "backend", "add", "--slug", "r2", "--endpoint", "http://127.0.0.1:9", "--bucket", "b",
      "--url-prefix", "http://a.invalid", "--no-credentials",
    ])
    #expect(result.status == 1)
    #expect(result.stderr == "Error: Backend 'r2' already exists.\n")
  }

  @Test("Something that is not there is 66, without usage")
  func notFound() throws {
    // Raised by the CLI itself.
    let backend = try run(["backend", "set-credentials", "--slug", "nope"])
    #expect(backend.status == 66)
    #expect(backend.stderr == "Error: Backend 'nope' does not exist.\n")
    #expect(backend.stdout.isEmpty)
    // Raised by the catalog.
    let identifier = String(repeating: "e", count: 12)
    let asset = try run(["show", identifier])
    #expect(asset.status == 66)
    #expect(asset.stderr == "Error: No asset matches '\(identifier)'.\n")
    let file = try run(["upload", "/nonexistent/pinax.png"])
    #expect(file.status == 66)
    #expect(file.stderr == "Error: File does not exist: /nonexistent/pinax.png\n")
  }

  @Test("A store that does not answer is 69, without usage")
  func remoteFailure() throws {
    // Throwaway values for the closed local port.
    let result = try run(
      ["reindex", "--backend", "r2", "--dry-run"],
      environment: ["PINAX_ACCESS_KEY_ID": "test", "PINAX_SECRET_ACCESS_KEY": "test"])
    #expect(result.status == 69)
    #expect(result.stderr.hasPrefix("Error: "))
    #expect(!result.stderr.contains("Usage:"))
  }

  @Test("Restoring into a catalog that is not empty is 77, without usage")
  func refused() throws {
    let (_, directory) = try makeCLITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("backup.json").path
    #expect(try CLIProcess.run(["backup", "-o", file], in: directory).status == 0)
    let result = try CLIProcess.run(["restore", file], in: directory)
    #expect(result.status == 77)
    #expect(result.stderr.hasPrefix("Error: Pinax restores only into an empty catalog"))
    #expect(!result.stderr.contains("Usage:"))
  }

  @Test("A command source without --run-commands is 77, without usage")
  func commandNotAllowed() throws {
    let (database, directory) = try makeCLITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CatalogConfiguration.setProjectSources(
      slug: "blog",
      [ProjectSource(label: "cms", command: "echo ran > marker", workingDirectory: directory.path)],
      in: database)
    let result = try CLIProcess.run(["usage", "scan", "--project", "blog"], in: directory)
    #expect(result.status == 77)
    #expect(
      result.stderr
        == "Error: Source 'cms' runs a command that has not been allowed to run. "
        + "Add --run-commands to run this project's commands.\n")
    #expect(result.stdout.isEmpty)
    #expect(
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("marker").path))
  }

  @Test("Missing credentials are 78, without usage")
  func missingCredentials() throws {
    let result = try run(["reindex", "--backend", "r2", "--dry-run"])
    #expect(result.status == 78)
    #expect(
      result.stderr
        == "Error: Backend 'r2' was registered without credentials. "
        + "Run: pinax backend set-credentials --slug r2\n")
  }

  @Test("The table's classification of catalog, store and CLI errors")
  func classification() throws {
    let url = try #require(URL(string: "https://a.invalid/x.png"))
    let cases: [(Error, Int32?)] = [
      (AssetCatalogError.assetNotFound("x"), 66),
      (AssetCatalogError.projectNotFound("x"), 66),
      (AssetCatalogError.unlinkBlockedByLiveUsage(project: "x", liveCount: 1), 77),
      (AssetCatalogError.invalidTag(""), nil),
      (CatalogConfigurationError.backendNotFound("x"), 66),
      (CatalogConfigurationError.projectNotFound("x"), 66),
      (CatalogConfigurationError.sourceNotFound(project: "x", label: "y"), 66),
      (CatalogConfigurationError.oldDomainNotFound(backend: "x", prefix: "y"), 66),
      (CatalogConfigurationError.domainOfOtherBackend(prefix: "x", backend: "y"), 64),
      (CatalogConfigurationError.noProjectChanges, nil),
      (UsageCatalogError.projectNotFound("x"), 66),
      (UsageCatalogError.emptyScanRejected(previousFoundCount: 1), 77),
      (ManifestError.projectNotFound("x"), 66),
      (UsageScanError.sourceNotFound(label: "x", path: "y"), 66),
      (CatalogRestoreError.catalogNotEmpty(CatalogTableCounts()), 77),
      (DatabaseLocationError.unsafePath("x"), 77),
      (RunCommandsRequired(label: "x"), 77),
      (S3UploaderError.http(statusCode: 500, body: ""), 69),
      (S3UploaderError.invalidResponse, 69),
      (S3UploaderError.invalidEndpoint("x"), nil),
      (PublicObjectFetchError.notFound(url), 69),
      (URLError(.cannotConnectToHost), 69),
      (ExternalsMigrateError.noCredentials("x"), 78),
      (CLIError.credentials("x"), 78),
    ]
    for (error, expected) in cases {
      #expect(CLIExit.code(for: error) == expected, "\(error)")
    }
  }

  @Test("Several failures share their status, or are 1")
  func severalFailures() {
    let offline = URLError(.cannotConnectToHost)
    let rejected = S3UploaderError.http(statusCode: 403, body: "")
    let other = UploadPipelineError.unsupportedFileType("txt")
    #expect(CLIExit.code(forAll: [offline, rejected]) == 69)
    #expect(CLIExit.code(forAll: [offline, other]) == 1)
    #expect(CLIExit.code(forAll: [other]) == 1)
  }
}
