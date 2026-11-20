import ArgumentParser
import CatalogCore
import Foundation

/// `pinax externals import`: claim Your Domains URLs
/// into the catalog. Public GETs only; nothing is uploaded or deleted.
struct ExternalsImportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import",
    abstract: "Claim Your Domains URLs into the catalog: GET each object, hash it, add a row.",
    discussion: """
      Objects stay where they are in the bucket; only public GETs are sent. \
      Name URLs to claim just those, or pass --all for every Your Domains URL.
      """
  )

  @Option(name: .long, help: "Only this project's Your Domains URLs (default: every project).")
  var project: String?

  @Argument(help: "Your Domains URLs to claim.")
  var urls: [String] = []

  @Flag(name: .long, help: "Claim every Your Domains URL.")
  var all = false

  @Flag(name: .long, help: "GET and hash as usual, but write nothing.")
  var dryRun = false

  @Option(name: .long)
  var format: UsageOutputFormat = .table

  func validate() throws {
    if all && !urls.isEmpty {
      throw ValidationError("Pass URLs or --all, not both.")
    }
    if !all && urls.isEmpty {
      throw ValidationError("Name the URLs to claim, or pass --all.")
    }
  }

  mutating func run() async throws {
    let database = try openCatalogDatabase()
    let result = try await ExternalsClaim.run(
      project: project,
      urls: all ? nil : urls,
      in: database,
      fetcher: URLSessionPublicObjectFetcher(),
      dryRun: dryRun,
      progress: { progress in
        FileHandle.standardError.write(
          Data(
            "progress\t\(progress.completed)/\(progress.total)\t\(progress.bytes) bytes\n".utf8))
      })
    for warning in Self.warnings(result) {
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
    ExternalsClaimSkipReason.notFound, ExternalsClaimSkipReason.forbidden,
    ExternalsClaimSkipReason.sameContent, ExternalsClaimSkipReason.otherBackend,
    ExternalsClaimSkipReason.badKey, ExternalsClaimSkipReason.fetchFailed,
  ]

  static func warnings(_ result: ExternalsClaimResult) -> [String] {
    warnings(result.cdnCheck)
  }

  /// The CDN byte check's warnings; `pinax import bucket` prints the same.
  static func warnings(_ checks: [CDNByteCheck]) -> [String] {
    checks.compactMap { check in
      switch check.status {
      case .rewritesBytes:
        return
          "\(check.backend): the CDN changed the bytes of \(check.mismatched.count) of \(check.sampled) known images (\(check.mismatched.joined(separator: ", "))); nothing was claimed."
      case .unchecked:
        return
          "\(check.backend): CDN byte check not done — no image Pinax uploaded could be compared."
      case .matched:
        return nil
      }
    }
  }

  /// Tab-separated, one fact per line, then one line per skipped URL.
  static func table(_ result: ExternalsClaimResult) -> String {
    var lines: [String] = []
    if result.dryRun { lines.append("dry_run\tnothing written") }
    lines.append("claimed\t\(result.claimed.count)")
    lines.append("already_in_catalog\t\(result.alreadyInCatalog)")
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
    lines.append("relinked_usage\t\(result.relinkedUsage)")
    for skip in result.skipped {
      lines.append(
        "SKIPPED\t\(skip.reason)\t\(skip.url)\t\(skip.detail ?? "")")
    }
    lines.append("NOTE\t\(result.notice)")
    return lines.joined(separator: "\n") + "\n"
  }
}
