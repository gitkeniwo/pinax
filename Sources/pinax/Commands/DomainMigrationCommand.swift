import ArgumentParser
import CatalogCore
import Foundation

/// `pinax backend migrate-domain`. The preview and
/// apply print as `pinax rewrite` does; `perform` is what `run()` prints,
/// so tests drive the parsed command against a temporary catalog.
struct BackendMigrateDomain: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "migrate-domain",
    abstract: "Move a backend to a new domain and rewrite every project that uses it.",
    discussion: """
      Without --apply, nothing is written and the prefix is unchanged: every new URL is fetched \
      and checked, and the preview is recorded as a run.
      With --to the current prefix and --from OLD, only links on those old domains move to it; \
      the prefix is not changed.
      --apply --from-run ID changes the prefix (the old one becomes an old domain), then writes \
      exactly that preview and rescans.
      """
  )

  @Option(help: "The backend to move.")
  var backend: String?

  @Option(help: "The new URL prefix.")
  var to: String?

  @Option(help: "Only rewrite this project. Repeatable; by default every project whose usage resolves to the backend.")
  var project: [String] = []

  @Flag(help: "Leave references under old domains as they are; only rewrite the current prefix.")
  var keepOldDomains = false

  @Option(
    name: .customLong("from"),
    help: "Only rewrite links on this old domain. Repeatable. With --to the current prefix, required: those links move to it and the prefix stays.")
  var fromDomains: [String] = []

  @Flag(help: "Print a unified diff of every change.")
  var diff = false

  @Flag(help: "Change the prefix and write the preview named by --from-run.")
  var apply = false

  @Option(help: "The preview run to write.")
  var fromRun: Int64?

  @Option(help: "PROJECT/LABEL of a source to write although it isn't clean in git. Repeatable.")
  var allowSource: [String] = []

  @Option
  var format: RewriteOutputFormat = .table

  func validate() throws {
    if apply {
      guard fromRun != nil else {
        throw ValidationError("--apply needs --from-run ID, the number of the preview to write.")
      }
      guard backend == nil, to == nil, project.isEmpty, !keepOldDomains, fromDomains.isEmpty, !diff else {
        throw ValidationError(
          "--apply takes the backend, domain and projects from the preview run; leave out --backend, --to, --from, --project, --keep-old-domains and --diff.")
      }
    } else {
      guard fromRun == nil else { throw ValidationError("--from-run only goes with --apply.") }
      guard allowSource.isEmpty else { throw ValidationError("--allow-source only goes with --apply.") }
      guard backend != nil, to != nil else { throw ValidationError("Give --backend SLUG and --to URL.") }
      guard !(diff && format == .json) else {
        throw ValidationError("--diff prints text; use it with --format table.")
      }
      guard !(keepOldDomains && !fromDomains.isEmpty) else {
        throw ValidationError("--from names the old domains to rewrite; leave out --keep-old-domains.")
      }
    }
    for source in allowSource {
      let parts = source.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
        throw ValidationError("--allow-source takes PROJECT/LABEL, not “\(source)”.")
      }
    }
  }

  mutating func run() async throws {
    let command = self
    try await RewriteExit.finish {
      try await command.perform(in: try openCatalogDatabase())
    }
  }

  func perform(
    in database: CatalogDatabasePool,
    git: GitStatusProviding = GitStatusProvider(),
    verifier: RewriteTargetVerifying = PublicTargetVerifier(),
    backupRoot: URL = RewriteApplier.defaultBackupRoot()
  ) async throws -> RewriteCommandOutput {
    if apply, let fromRun {
      let result = try DomainMigration.apply(
        fromRun: fromRun, allowedSources: Set(allowSource), database: database, git: git,
        backupRoot: backupRoot)
      return try RewriteCommand.applyOutput(
        result, events: try RunLog.events(of: result.runID, in: database), format: format)
    }
    guard let backend, let to else { throw ValidationError("Give --backend SLUG and --to URL.") }
    let result = try await DomainMigration.preview(
      backend: backend, to: to, from: fromDomains, projects: project, keepOldDomains: keepOldDomains,
      verifier: verifier, database: database, git: git)
    var output = try RewriteCommand.previewOutput(
      result, format: format, diff: diff, command: "pinax backend migrate-domain")
    if format == .table, case let .runStarted(params)? = result.events.first, let domain = params.domain {
      var lines = output.stdout.components(separatedBy: "\n")
      var move: String
      if domain.keepPrefix {
        move = "Prefix stays \(domain.from); moves links on \(domain.oldDomains.joined(separator: ", ")) to it on apply"
      } else {
        move = "Prefix \(domain.from) → \(domain.to) on apply"
        if !domain.oldDomains.isEmpty { move += "; also rewrites \(domain.oldDomains.joined(separator: ", "))" }
      }
      lines.insert(move + ".", at: 1)
      output.stdout = lines.joined(separator: "\n")
    }
    return output
  }
}
