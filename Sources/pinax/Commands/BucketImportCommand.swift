import ArgumentParser
import CatalogCore
import Foundation

/// `pinax import bucket`: claim the objects in a
/// backend's bucket that the catalog lacks and no page uses. One signed
/// List, then public GETs; nothing is uploaded or deleted.
struct ImportBucketCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bucket",
    abstract: "Claim bucket objects that are not in the catalog and that no page uses.",
    discussion: """
      Lists the bucket with the backend's credentials, leaves out keys already in the \
      catalog, staged for deletion, or used by a project's pages, then GETs and hashes \
      the rest. The objects stay where they are; they join no project and show up in \
      Orphans.
      """
  )

  @Option(help: "Backend whose bucket to list.")
  var backend: String

  @Flag(name: .long, help: "List, GET and hash as usual, but write nothing.")
  var dryRun = false

  @Option(name: .long)
  var format: UsageOutputFormat = .table

  mutating func run() async throws {
    let database = try openCatalogDatabase()
    let selected = try CatalogConfiguration.backend(slug: backend, in: database)
    let credentials = try reindexCredentials(for: selected)
    let result: BucketClaimResult
    do {
      result = try await BucketClaim.run(
        backend: selected,
        inventory: S3ObjectInventory(backend: selected, credentials: credentials),
        in: database,
        fetcher: URLSessionPublicObjectFetcher(),
        dryRun: dryRun,
        progress: { progress in
          FileHandle.standardError.write(
            Data(
              "progress\t\(progress.completed)/\(progress.total)\t\(progress.bytes) bytes\n".utf8))
        })
    } catch {
      guard let message = BucketClaim.listRefusalMessage(for: error, backend: selected) else {
        throw error
      }
      FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
      throw ExitCode(CLIExit.code(for: error) ?? CLIExit.failure)
    }
    for warning in ExternalsImportCommand.warnings(result.cdnCheck) {
      FileHandle.standardError.write(Data("WARN\t\(warning)\n".utf8))
    }
    switch format {
    case .json:
      print(try encodedJSON(result))
    case .table:
      print(Self.table(result), terminator: "")
    }
    if result.hasFailures {
      throw ExitCode.failure
    }
  }

  static let skipCategories = [
    ExternalsClaimSkipReason.pendingDeletion, ExternalsClaimSkipReason.badKey,
    ExternalsClaimSkipReason.notFound, ExternalsClaimSkipReason.forbidden,
    ExternalsClaimSkipReason.sameContent, ExternalsClaimSkipReason.fetchFailed,
  ]

  /// Tab-separated, one fact per line, then one line per referenced key and
  /// per skipped object — the shape of `pinax externals import`'s table.
  static func table(_ result: BucketClaimResult) -> String {
    var lines: [String] = []
    if result.dryRun { lines.append("dry_run\tnothing written") }
    lines.append("listed\t\(result.listed)")
    lines.append("already_in_catalog\t\(result.alreadyInCatalog)")
    lines.append("referenced\t\(result.referenced.count)")
    lines.append("candidates\t\(result.candidates)")
    lines.append("claimed\t\(result.claimed.count)")
    let counts = result.skippedCounts
    let categories = skipCategories + counts.keys.filter { !skipCategories.contains($0) }.sorted()
    for reason in categories {
      lines.append("skipped\t\(reason)\t\(counts[reason] ?? 0)")
    }
    for check in result.cdnCheck {
      lines.append(
        "cdn_check\t\(check.backend)\t\(check.status.rawValue)\t\(check.matched)/\(check.sampled) matched")
    }
    if result.cdnCheck.isEmpty { lines.append("cdn_check\tnone needed") }
    if result.refused { lines.append("refused\tcdn_rewrites_bytes") }
    if result.cancelled { lines.append("cancelled\t\(result.remaining) remaining") }
    for key in result.referenced {
      lines.append("REFERENCED\t\(key)\tused by a page; claim it with `pinax externals import`")
    }
    for skip in result.skipped {
      lines.append("SKIPPED\t\(skip.reason)\t\(skip.url)\t\(skip.detail ?? "")")
    }
    lines.append("NOTE\t\(result.notice)")
    return lines.joined(separator: "\n") + "\n"
  }
}
