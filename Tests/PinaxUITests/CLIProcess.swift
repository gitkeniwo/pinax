import CatalogCore
import Foundation
import GRDB

/// Runs the built `pinax` on a temporary catalog, and the catalog the CLI
/// exit-status and JSON suites share.
enum CLIProcess {
  struct Result {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  private final class BundleToken {}

  /// `PINAX_DB` and `HOME` point into `directory`, and nothing else of this
  /// process's environment is passed on.
  static func run(
    _ arguments: [String], in directory: URL, environment extra: [String: String] = [:]
  ) throws -> Result {
    let process = Process()
    // SwiftPM builds `pinax` next to the test bundle.
    process.executableURL = Bundle(for: BundleToken.self).bundleURL
      .deletingLastPathComponent().appendingPathComponent("pinax")
    process.arguments = arguments
    process.environment = [
      "PATH": "/usr/bin:/bin",
      "HOME": directory.path,
      "PINAX_DB": directory.appendingPathComponent("catalog.sqlite").path,
    ].merging(extra) { $1 }
    process.standardInput = FileHandle.nullDevice
    // Files, not pipes: neither stream can fill up and block the other.
    let stdout = directory.appendingPathComponent("stdout-\(UUID().uuidString)")
    let stderr = directory.appendingPathComponent("stderr-\(UUID().uuidString)")
    for url in [stdout, stderr] {
      _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    process.standardOutput = try FileHandle(forWritingTo: stdout)
    process.standardError = try FileHandle(forWritingTo: stderr)
    try process.run()
    process.waitUntilExit()
    return Result(
      status: process.terminationStatus,
      stdout: try String(contentsOf: stdout, encoding: .utf8),
      stderr: try String(contentsOf: stderr, encoding: .utf8))
  }
}

/// `makeUITestDatabase()` with every backend registered without credentials,
/// so no command consults the Keychain, and with its endpoint on a closed
/// local port. Plus:
///   asset-0  blog, tag `cats`, note "hello"; used by blog's a.md
///   asset-1  blog, never used, no dimensions or original filename
///   asset-2  notes only; `notes` is not tracked
/// blog's a.md also links a missing image on the current prefix, one on the
/// old domain https://old.example.com, and a third party's. Two blog scans.
func makeCLITestDatabase() throws -> (database: DatabasePool, directory: URL) {
  let (database, directory) = try makeUITestDatabase()
  let source = directory.appendingPathComponent("site", isDirectory: true)
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  try """
  ![a](https://img.example.com/blog/asset-0.png)
  ![b](https://img.example.com/blog/gone.png)
  ![c](https://old.example.com/blog/missing.png)
  ![d](https://elsewhere.example.org/x.png)
  """.write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
  try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z", tag: "cats")
  try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z")
  try seedAsset(database, index: 2, uploadedAt: "2026-08-03T00:00:00Z", projectSlug: "notes")
  try database.write { db in
    try db.execute(
      sql: """
        UPDATE backend SET keychain_ref = '', endpoint = 'http://127.0.0.1:9';
        UPDATE asset SET note = 'hello' WHERE id = 1;
        UPDATE asset SET width = NULL, height = NULL, orig_filename = NULL WHERE id = 2;
        UPDATE project SET meta = '{"usageTracking":"notTracked"}' WHERE slug = 'notes';
        """)
  }
  try CatalogConfiguration.setProjectSources(
    slug: "blog", [ProjectSource(label: "site", path: source.path)], in: database)
  _ = try CatalogConfiguration.addOldDomain(
    "https://old.example.com", backendSlug: "r2", in: database)
  for _ in 0..<2 {
    let scan = try UsageScanner.scan(project: "blog", in: database)
    _ = try CatalogUsage.sync(scan.document, project: "blog", in: database)
  }
  return (database, directory)
}
