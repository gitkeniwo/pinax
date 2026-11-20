import ArgumentParser
import CatalogCore
import Foundation

enum RewriteOutputFormat: String, ExpressibleByArgument {
  case table
  case json
}

enum RunLogOutputFormat: String, ExpressibleByArgument {
  case table
  case jsonl
}

/// What a rewrite or runs command prints and exits with.
struct RewriteCommandOutput: Equatable {
  var stdout: String
  var exitCode: Int32 = 0
}

enum RewriteCommandError: Error, Equatable, CustomStringConvertible {
  case mapNotFound(String)
  case badMap(path: String, reason: String)

  var description: String {
    switch self {
    case let .mapNotFound(path): return "No map file at \(path)."
    case let .badMap(path, reason): return "\(path) isn’t a rewrite map: \(reason)"
    }
  }
}

/// Exit statuses of the rewrite commands, after sysexits(3).
enum RewriteExit {
  static let failure: Int32 = 1
  static let usage: Int32 = 64
  static let notFound: Int32 = 66
  static let remote: Int32 = 69
  static let refused: Int32 = 77

  /// The status of an error the rewrite commands classify, or nil for one
  /// ArgumentParser reports as before.
  static func code(for error: Error) -> Int32? {
    switch error {
    case let error as RewriteRunError:
      switch error {
      case .runNotFound, .unknownSources: return notFound
      case .notAPreview, .planChanged, .sourcesNotAllowed, .targetsNotVerified: return refused
      }
    case is RewriteApplyError:
      return refused
    case is RewritePlanError:
      return usage
    case let error as RewriteCommandError:
      switch error {
      case .mapNotFound: return notFound
      case .badMap: return usage
      }
    case let error as DomainMigrationError:
      switch error {
      case .invalidDomain, .sameAsCurrent, .notAnOldDomain: return usage
      case .noProjects: return notFound
      case .targetsNotVerified, .prefixMoved: return refused
      }
    case let error as CatalogConfigurationError:
      switch error {
      case .projectNotFound, .backendNotFound: return notFound
      case .domainOfOtherBackend: return usage
      default: return nil
      }
    case let error as UsageScanError:
      if case .sourceNotFound = error { return notFound }
      return nil
    case let error as ExternalMigrationError:
      switch error {
      case .noTargets: return usage
      case .noBackend, .backendsDiffer: return notFound
      case .busy, .cacheInvalid: return refused
      }
    case let error as ExternalsMigrateError:
      switch error {
      case .notInOtherDomains: return usage
      case .noCredentials: return notFound
      case .refused: return refused
      }
    default:
      return nil
    }
  }

  /// Prints `output`, exiting with its status; a classified error is
  /// printed as `Error: …` and exits with its status.
  static func finish(_ perform: () async throws -> RewriteCommandOutput) async throws {
    let output: RewriteCommandOutput
    do {
      output = try await perform()
    } catch {
      guard let code = code(for: error) else { throw error }
      FileHandle.standardError.write(Data("Error: \(String(describing: error))\n".utf8))
      throw ExitCode(code)
    }
    if !output.stdout.isEmpty { print(output.stdout) }
    if output.exitCode != 0 { throw ExitCode(output.exitCode) }
  }
}

// MARK: - pinax rewrite

struct RewriteCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rewrite",
    abstract: "Preview URL rewrites in a project's sources, or write a preview.",
    discussion: """
      Without --apply, nothing is written: the preview is recorded as a run.
      --apply --from-run ID writes exactly that preview, with its project and rules.
      """
  )

  @Option(help: "The project whose sources to rewrite.")
  var project: String?

  @Option(help: "A JSON file: [{\"match\": \"exact\"|\"prefix\", \"from\": URL, \"to\": URL}].")
  var map: String?

  @Option(help: "Shorthand for one prefix rule, with --to-prefix.")
  var fromPrefix: String?

  @Option(help: "Shorthand for one prefix rule, with --from-prefix.")
  var toPrefix: String?

  @Flag(help: "Fetch every new URL and compare it with the catalog.")
  var verify = false

  @Flag(help: "Print a unified diff of every change.")
  var diff = false

  @Flag(help: "Write the preview named by --from-run.")
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
      guard project == nil, map == nil, fromPrefix == nil, toPrefix == nil, !verify, !diff else {
        throw ValidationError(
          "--apply takes the project and rules from the preview run; leave out --project, --map, --from-prefix, --to-prefix, --verify and --diff.")
      }
    } else {
      guard fromRun == nil else { throw ValidationError("--from-run only goes with --apply.") }
      guard allowSource.isEmpty else { throw ValidationError("--allow-source only goes with --apply.") }
      guard project != nil else { throw ValidationError("Give --project SLUG.") }
      guard (fromPrefix == nil) == (toPrefix == nil) else {
        throw ValidationError("Give --from-prefix and --to-prefix together.")
      }
      guard map != nil || fromPrefix != nil else {
        throw ValidationError("Give --map FILE, or --from-prefix URL --to-prefix URL.")
      }
      guard !(diff && format == .json) else {
        throw ValidationError("--diff prints text; use it with --format table.")
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
      let result = try RewriteRuns.apply(
        fromRun: fromRun, allowedSources: Set(allowSource), database: database, git: git,
        backupRoot: backupRoot)
      return try Self.applyOutput(
        result, events: try RunLog.events(of: result.runID, in: database), format: format)
    }
    guard let project else { throw ValidationError("Give --project SLUG.") }
    let result = try await RewriteRuns.preview(
      targets: [RewriteRunTarget(project: project, rules: try rules())],
      verifier: verify ? verifier : nil, database: database, git: git)
    return try Self.previewOutput(result, format: format, diff: diff, command: "pinax rewrite")
  }

  /// The map file's rules, then the prefix shorthand.
  func rules() throws -> [RewriteRule] {
    var rules: [RewriteRule] = []
    if let map {
      let path = (map as NSString).expandingTildeInPath
      guard FileManager.default.fileExists(atPath: path) else { throw RewriteCommandError.mapNotFound(path) }
      do {
        rules = try JSONDecoder().decode([RewriteRule].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      } catch {
        throw RewriteCommandError.badMap(path: path, reason: Self.reason(error))
      }
    }
    if let fromPrefix, let toPrefix { rules.append(.prefix(from: fromPrefix, to: toPrefix)) }
    return rules
  }

  private static func reason(_ error: Error) -> String {
    switch error {
    case let DecodingError.dataCorrupted(context): return context.debugDescription
    case let DecodingError.keyNotFound(key, _): return "a rule has no “\(key.stringValue)”."
    case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
      return context.debugDescription
    default: return error.localizedDescription
    }
  }

  // MARK: Preview output

  /// `command` is what `--apply --from-run` follows in the first line.
  static func previewOutput(
    _ result: RewritePreviewResult, format: RewriteOutputFormat, diff: Bool, command: String
  ) throws -> RewriteCommandOutput {
    let events = result.events
    let checks = events.compactMap { if case let .targetVerified(e) = $0 { return e } else { return nil } }
    let exitCode: Int32 =
      checks.contains { $0.result == .mismatch }
      ? RewriteExit.refused
      : checks.contains { $0.result == .unreachable } ? RewriteExit.remote : 0
    if format == .json {
      let document = PreviewJSON(
        runID: result.runID,
        sources: events.compactMap { if case let .sourceStatus(e) = $0 { return e } else { return nil } },
        files: events.compactMap { if case let .filePlanned(e) = $0 { return e } else { return nil } },
        skipped: events.compactMap { if case let .editSkipped(e) = $0 { return e } else { return nil } },
        protocolRelative: events.compactMap {
          if case let .protocolRelativeFound(e) = $0 { return e } else { return nil }
        },
        verified: result.summary.verified == nil
          ? nil
          : events.compactMap { if case let .targetVerified(e) = $0 { return e } else { return nil } },
        summary: result.summary)
      return RewriteCommandOutput(stdout: try encodedJSON(document), exitCode: exitCode)
    }

    let failed = checks.filter(\.isFailure)
    let alreadyBroken = checks.filter { $0.result == .alreadyBroken }
    var lines = [
      failed.isEmpty
        ? "Preview run \(result.runID) — \(command) --apply --from-run \(result.runID) to write."
        : "Preview run \(result.runID) — \(failed.count == 1 ? "1 new URL" : "\(failed.count) new URLs") failed the check; apply is refused."
    ]
    lines.append("Sources")
    for plan in result.plans {
      for source in plan.sources {
        let id = "\(plan.project)/\(source.label)"
        let status = SourceStatusEvent(project: plan.project, source: source.label, git: source.git)
        var line = "  " + RunEvent.sourceStatus(status).summaryLine
        if !source.git.isClean { line += " — to write it, add --allow-source \(id)" }
        lines.append(line)
      }
    }
    let files = result.plans.flatMap { plan in
      plan.files.filter { $0.newContent != nil }.map { (plan, $0) }
    }
    if files.isEmpty {
      lines.append("No URLs match these rules.")
    } else {
      lines.append("Files")
      for (plan, file) in files {
        let refs = file.edits.count == 1 ? "1 ref" : "\(file.edits.count) refs"
        lines.append("  \(plan.project)/\(file.sourceLabel)/\(file.path)\t\(refs)")
      }
    }
    let notes = events.filter {
      switch $0 {
      case .editSkipped, .protocolRelativeFound: return true
      default: return false
      }
    }
    if !notes.isEmpty {
      lines.append("Notes")
      lines += notes.map { "  " + $0.summaryLine }
    }
    if !failed.isEmpty {
      lines.append("Failed checks")
      lines += Self.failedCheckLines(failed)
    }
    if !alreadyBroken.isEmpty {
      lines.append("Already broken (also fails on the old URL)")
      // Grouped by why the old URL fails.
      lines += Self.failedCheckLines(alreadyBroken, cause: { "Couldn’t fetch: \($0.oldCause)" })
    }
    lines.append(Self.summaryText(result.summary))
    if diff {
      for (_, file) in files {
        guard let newContent = file.newContent else { continue }
        let text = RewriteDiff.unified(
          label: file.sourceLabel, path: file.path,
          old: String(decoding: file.originalContent, as: UTF8.self),
          new: String(decoding: newContent, as: UTF8.self))
        lines.append(text.hasSuffix("\n") ? String(text.dropLast()) : text)
      }
    }
    return RewriteCommandOutput(stdout: lines.joined(separator: "\n"), exitCode: exitCode)
  }

  /// Failed checks grouped by cause, largest group first: a line with the
  /// cause and the count, then at most `shown` of its URLs.
  static func failedCheckLines(
    _ failed: [TargetVerifiedEvent], shown: Int = 5,
    cause causeOf: (TargetVerifiedEvent) -> String = {
      $0.result == .mismatch ? "Serves a different file" : "Couldn’t fetch: \($0.cause)"
    }
  ) -> [String] {
    var order: [String] = []
    var groups: [String: [String]] = [:]
    for event in failed {
      let cause = causeOf(event)
      if groups[cause] == nil { order.append(cause) }
      groups[cause, default: []].append(event.url)
    }
    let sorted = order.enumerated().sorted {
      (groups[$0.element]!.count, -$0.offset) > (groups[$1.element]!.count, -$1.offset)
    }
    return sorted.flatMap { _, cause -> [String] in
      let urls = groups[cause]!
      var lines = ["  \(cause) · \(urls.count == 1 ? "1 new URL" : "\(urls.count) new URLs")"]
      lines += urls.prefix(shown).map { "    \($0)" }
      if urls.count > shown { lines.append("    … and \(urls.count - shown) more") }
      return lines
    }
  }

  static func summaryText(_ summary: RewriteRunSummary) -> String {
    func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    var parts = ["\(count(summary.files, "file")), \(count(summary.edits, "ref")) to rewrite"]
    let skipped = summary.skippedEdits.values.reduce(0, +)
    if skipped > 0 { parts.append("\(count(skipped, "ref")) left as is") }
    if summary.protocolRelative > 0 {
      parts.append("\(count(summary.protocolRelative, "protocol-relative link")) to change by hand")
    }
    if let verified = summary.verified {
      let bad = (verified["mismatch"] ?? 0) + (verified["unreachable"] ?? 0)
      parts.append(bad == 0 ? "every new URL checked" : "\(count(bad, "new URL")) failed the check")
      if let broken = verified[TargetVerifiedEvent.Result.alreadyBroken.rawValue], broken > 0 {
        parts.append("\(count(broken, "new URL")) already broken")
      }
      if let missing = summary.notInCatalog, missing > 0 {
        parts.append("\(count(missing, "new URL")) not in the catalog, only fetched")
      }
    }
    return "Summary: " + parts.joined(separator: "; ") + "."
  }

  // MARK: Apply output

  static func applyOutput(
    _ result: RewriteApplyResult, events: [RunEventRecord], format: RewriteOutputFormat
  ) throws -> RewriteCommandOutput {
    let summary = result.summary
    let exitCode: Int32 =
      (summary.failed ?? 0) > 0
        || (summary.skippedFiles?[RewriteFileSkipReason.changedSincePlan.rawValue] ?? 0) > 0
      ? RewriteExit.failure : 0
    if format == .json {
      let document = ApplyJSON(
        runID: result.runID, fromRunID: result.fromRunID,
        files: result.results.map(ApplyJSON.File.init),
        summary: summary)
      return RewriteCommandOutput(stdout: try encodedJSON(document), exitCode: exitCode)
    }
    let written = summary.written ?? 0
    var lines = [
      "Run \(result.runID) wrote \(written == 1 ? "1 file" : "\(written) files") from preview \(result.fromRunID)."
    ]
    for record in events {
      switch record.event {
      case .prefixChanged, .fileWritten, .fileSkipped, .fileFailed, .rescanFinished, .rescanFailed:
        lines.append("  " + record.event.summaryLine)
      default: break
      }
    }
    if let byRepo = summary.changedFilesByRepo, !byRepo.isEmpty {
      lines.append("Changed files")
      // One line per repository; the full list is in JSON and `runs show`.
      for repository in byRepo.keys.sorted() {
        let count = byRepo[repository]?.count ?? 0
        let name = repository == RewriteRunSummary.notInGitKey ? "not in git" : repository
        lines.append("  \(name) · \(count == 1 ? "1 file" : "\(count) files")")
      }
    }
    return RewriteCommandOutput(stdout: lines.joined(separator: "\n"), exitCode: exitCode)
  }
}

private struct PreviewJSON: Encodable {
  let schema = "pinax.rewrite.v1"
  let runID: Int64
  let dryRun = true
  let sources: [SourceStatusEvent]
  let files: [FilePlannedEvent]
  let skipped: [EditSkippedEvent]
  let protocolRelative: [ProtocolRelativeEvent]
  let verified: [TargetVerifiedEvent]?
  let summary: RewriteRunSummary

  enum CodingKeys: String, CodingKey {
    case schema, sources, files, skipped, verified, summary
    case runID = "run_id"
    case dryRun = "dry_run"
    case protocolRelative = "protocol_relative"
  }
}

private struct ApplyJSON: Encodable {
  struct File: Encodable {
    let project: String
    let source: String
    let path: String
    let outcome: String
    let reason: String?
    let edits: Int?
    let backupPath: String?

    init(_ item: RewriteRunFileResult) {
      project = item.project
      source = item.result.sourceLabel
      path = item.result.path
      switch item.result.outcome {
      case let .written(_, _, edits, backup):
        (outcome, reason, self.edits, backupPath) = ("written", nil, edits, backup)
      case let .skipped(why):
        (outcome, reason, edits, backupPath) = ("skipped", why.rawValue, nil, nil)
      case let .failed(message):
        (outcome, reason, edits, backupPath) = ("failed", message, nil, nil)
      }
    }

    enum CodingKeys: String, CodingKey {
      case project, source, path, outcome, reason, edits
      case backupPath = "backup_path"
    }
  }

  let schema = "pinax.rewrite.v1"
  let runID: Int64
  let fromRunID: Int64
  let dryRun = false
  let files: [File]
  let summary: RewriteRunSummary

  enum CodingKeys: String, CodingKey {
    case schema, files, summary
    case runID = "run_id"
    case fromRunID = "from_run_id"
    case dryRun = "dry_run"
  }
}

// MARK: - pinax runs

struct RunsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "runs",
    abstract: "List rewrite runs and show their logs.",
    subcommands: [RunsListCommand.self, RunsShowCommand.self],
    defaultSubcommand: RunsListCommand.self
  )
}

struct RunsListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ls", abstract: "List runs, newest first.")

  @Option(help: "How many runs to list.")
  var limit = 20

  @Option
  var format: RewriteOutputFormat = .table

  func validate() throws {
    guard limit > 0 else { throw ValidationError("--limit must be greater than zero.") }
  }

  mutating func run() async throws {
    let command = self
    try await RewriteExit.finish { try command.perform(in: try openCatalogDatabase()) }
  }

  func perform(
    in database: CatalogDatabasePool, processExists: (Int32) -> Bool = RunLog.processExists
  ) throws -> RewriteCommandOutput {
    let runs = try RunLog.runs(limit: limit, in: database, processExists: processExists)
    if format == .json {
      return RewriteCommandOutput(stdout: try encodedJSON(RunsJSON(runs: runs.map(RunJSON.init))))
    }
    var lines = ["ID\tKIND\tMODE\tSTATE\tSTARTED\tFROM"]
    for run in runs {
      lines.append(
        "\(run.id)\t\(run.kind.rawValue)\t\(run.dryRun ? "preview" : "apply")\t\(run.state.rawValue)\t\(run.startedAt)\t\(run.fromRunID.map(String.init) ?? "")")
    }
    return RewriteCommandOutput(stdout: lines.joined(separator: "\n"))
  }
}

struct RunsShowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one run's log.")

  @Argument(help: "The run number.")
  var id: Int64

  @Option
  var format: RunLogOutputFormat = .table

  mutating func run() async throws {
    let command = self
    try await RewriteExit.finish { try command.perform(in: try openCatalogDatabase()) }
  }

  func perform(
    in database: CatalogDatabasePool, processExists: (Int32) -> Bool = RunLog.processExists
  ) throws -> RewriteCommandOutput {
    guard let run = try RunLog.run(id, in: database, processExists: processExists) else {
      throw RewriteRunError.runNotFound(id)
    }
    let events = try RunLog.events(of: id, in: database)
    if format == .jsonl {
      return RewriteCommandOutput(stdout: events.map(\.jsonLine).joined(separator: "\n"))
    }
    var header = "Run \(run.id) · \(run.kind.rawValue) · \(run.dryRun ? "preview" : "apply") · \(run.state.rawValue)"
    if let from = run.fromRunID { header += " · from run \(from)" }
    var lines = [header, "Started \(run.startedAt)" + (run.finishedAt.map { " · finished \($0)" } ?? "")]
    lines += events.map { "\($0.seq)\t\($0.level.rawValue)\t\($0.event.summaryLine)" }
    return RewriteCommandOutput(stdout: lines.joined(separator: "\n"))
  }
}

private struct RunsJSON: Encodable {
  let schema = "pinax.runs.v1"
  let runs: [RunJSON]
}

private struct RunJSON: Encodable {
  let id: Int64
  let kind: String
  let state: String
  let dryRun: Bool
  let fromRunID: Int64?
  let backendID: Int64?
  let startedAt: String
  let finishedAt: String?
  let summary: RewriteRunSummary?

  init(_ run: RunRecord) {
    id = run.id
    kind = run.kind.rawValue
    state = run.state.rawValue
    dryRun = run.dryRun
    fromRunID = run.fromRunID
    backendID = run.backendID
    startedAt = run.startedAt
    finishedAt = run.finishedAt
    summary = run.summary.flatMap {
      try? JSONDecoder().decode(RewriteRunSummary.self, from: Data($0.utf8))
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, state, summary
    case dryRun = "dry_run"
    case fromRunID = "from_run_id"
    case backendID = "backend_id"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
  }
}
