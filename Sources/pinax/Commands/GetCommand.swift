import ArgumentParser
import CatalogCore
import Foundation

struct GetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get",
    abstract: "Download originals into a folder.",
    discussion: """
      Each file is fetched from its public URL, checked against the catalog's SHA-256, and \
      saved under its original filename. An existing file is never overwritten: a taken name \
      gets the suffix " 2", " 3", and so on. The path of each saved file is printed.
      """
  )

  @Argument(help: "Exact asset keys or unambiguous SHA-256 prefixes.")
  var identifiers: [String]

  @Option(name: [.short, .long], help: "The folder to save into; created if missing.")
  var output: String

  mutating func run() async throws {
    let result = try await GetCommandOperations.download(
      identifiers,
      to: URL(
        fileURLWithPath: (output as NSString).expandingTildeInPath, isDirectory: true
      ).standardizedFileURL,
      in: openCatalogDatabase(), with: OriginalDownloader(),
      saved: { print($0.path) },
      failed: { FileHandle.standardError.write(Data("\($0)\n".utf8)) })
    if result != 0 {
      throw ExitCode(result)
    }
  }
}

enum GetCommandOperations {
  /// Saves each asset's original into `folder`, one at a time, and returns
  /// the exit status. Nothing is fetched unless every identifier resolves;
  /// after that one asset's failure does not stop the rest.
  static func download(
    _ identifiers: [String], to folder: URL, in database: CatalogDatabasePool,
    with downloader: OriginalDownloader, saved: (URL) -> Void, failed: (String) -> Void
  ) async throws -> Int32 {
    let items = try CatalogAssets.resolveAll(identifiers, in: database)
    var failures: [Error] = []
    for item in items {
      do {
        guard let source = URL(string: item.url) else {
          throw OriginalDownloadError.invalidURL
        }
        let name = OriginalDownloader.downloadFilename(
          CopyFields(item: item, projects: []).filename, key: item.asset.key)
        saved(
          try await downloader.download(
            DownloadRequest(sha256: item.asset.sha256, sourceURL: source, filename: name),
            to: folder))
      } catch {
        failures.append(error)
        failed("\(item.asset.key): \(error.localizedDescription)")
      }
    }
    return failures.isEmpty ? 0 : CLIExit.code(forAll: failures)
  }
}
