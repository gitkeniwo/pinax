import ArgumentParser
import CatalogCore
import Foundation

enum ExternalsMigrateError: Error, Equatable, CustomStringConvertible {
  /// Named hosts or URLs that are not in the project's Other Domains, and
  /// the hosts that are.
  case notInOtherDomains(project: String, missing: [String], hosts: [String])
  case noCredentials(String)
  /// An apply refused before any upload; no run was recorded.
  case refused(String)

  var description: String {
    switch self {
    case let .refused(message):
      return message
    case let .notInOtherDomains(project, missing, hosts):
      var lines = ["Not in \(project)’s Other Domains: \(missing.joined(separator: ", "))."]
      lines.append(
        hosts.isEmpty
          ? "\(project) has no Other Domains links in its latest scan."
          : "Hosts there: \(hosts.joined(separator: ", ")).")
      return lines.joined(separator: "\n")
    case let .noCredentials(message):
      return message
    }
  }
}

/// `pinax externals migrate`. Without --apply it
/// prepares (downloads only, recorded as a run); --apply --from-run ID
/// uploads, checks and rewrites that preparation. `perform` is what `run()`
/// prints, so tests drive the parsed command with stubs.
struct ExternalsMigrateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "migrate",
    abstract: "Copy Other Domains images into your bucket and rewrite the links.",
    discussion: """
      Without --apply, each named image is downloaded once and the plan is recorded as a run; \
      nothing is uploaded or written.
      --apply --from-run ID uploads exactly that preparation, checks every new URL, then rewrites \
      and rescans.
      """
  )

  @Option(help: "The project whose Other Domains links to migrate.")
  var project: String?

  @Option(name: .customLong("host"), help: "Every Other Domains link on this host. Repeatable.")
  var hosts: [String] = []

  @Option(name: .customLong("url"), help: "This Other Domains URL. Repeatable.")
  var urls: [String] = []

  @Option(help: "The backend to upload to (default: the project's).")
  var backend: String?

  @Flag(help: "Upload and rewrite the preparation named by --from-run.")
  var apply = false

  @Option(help: "The preparation run to apply.")
  var fromRun: Int64?

  @Option(help: "PROJECT/LABEL of a source to write although it isn't clean in git. Repeatable.")
  var allowSource: [String] = []

  @Option
  var format: RewriteOutputFormat = .table

  static let schema = "pinax.externals.migrate.v1"

  func validate() throws {
    if apply {
      guard fromRun != nil else {
        throw ValidationError("--apply needs --from-run ID, the number of the preparation to apply.")
      }
      guard project == nil, hosts.isEmpty, urls.isEmpty, backend == nil else {
        throw ValidationError(
          "--apply takes the project, links and backend from the preparation; leave out --project, --host, --url and --backend.")
      }
    } else {
      guard fromRun == nil else { throw ValidationError("--from-run only goes with --apply.") }
      guard allowSource.isEmpty else { throw ValidationError("--allow-source only goes with --apply.") }
      guard project != nil else { throw ValidationError("Give --project SLUG.") }
      guard !hosts.isEmpty || !urls.isEmpty else {
        throw ValidationError("Name what to migrate: --host HOST or --url URL, each repeatable.")
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
    fetcher: PublicObjectFetching = URLSessionPublicObjectFetcher(),
    uploader makeUploader: (Backend) throws -> any Uploader = Self.liveUploader,
    verifier: RewriteTargetVerifying = PublicTargetVerifier(),
    git: GitStatusProviding = GitStatusProvider(),
    cacheRoot: URL = ExternalMigration.defaultCacheRoot(),
    backupRoot: URL = RewriteApplier.defaultBackupRoot(),
    now: Date = Date(),
    log: @escaping @Sendable (String) -> Void = Self.standardError
  ) async throws -> RewriteCommandOutput {
    if apply, let fromRun {
      guard let base = try RunLog.run(fromRun, in: database) else { throw RewriteRunError.runNotFound(fromRun) }
      guard base.kind == .externalMigrate else {
        throw RewriteRunError.notAPreview(fromRun, reason: "it is a \(base.kind.rawValue) run")
      }
      let params = try JSONDecoder().decode(ExternalMigrationParams.self, from: Data(base.params.utf8))
      guard let backend = try CatalogConfiguration.backends(in: database).first(where: { $0.slug == params.backend })
      else { throw CatalogConfigurationError.backendNotFound(params.backend) }
      let tail = EventTail(database: database, baseID: fromRun, log: log)
      let result: ExternalMigrationResult
      do {
        result = try await ExternalMigration.apply(
          fromRun: fromRun, allowedSources: Set(allowSource), database: database,
          uploader: try makeUploader(backend), verifier: verifier, git: git, cacheRoot: cacheRoot,
          backupRoot: backupRoot, now: now, progress: { _ in tail.flush() })
      } catch let error as RewriteRunError {
        throw Self.refusal(error, fromRun: fromRun, params: params)
      }
      tail.flush(runID: result.runID)
      return try Self.applyOutput(
        result, fromRun: fromRun, events: try RunLog.events(of: result.runID, in: database), format: format)
    }
    guard let project else { throw ValidationError("Give --project SLUG.") }
    let targets = try await Self.targets(project: project, hosts: hosts, urls: urls, in: database)
    let result = try await ExternalMigration.prepare(
      targets: [ExternalMigrationTarget(project: project, urls: targets)], backend: backend,
      database: database, fetcher: fetcher, git: git, cacheRoot: cacheRoot, now: now,
      progress: { progress in
        log("Downloading \(progress.done) of \(progress.total)" + (progress.host.map { " · \($0)" } ?? ""))
      })
    let backendID = try RunLog.run(result.runID, in: database)?.backendID
    let bucket = try CatalogConfiguration.backends(in: database).first { $0.id == backendID }
    return try Self.prepareOutput(result, bucket: bucket, format: format)
  }

  /// The rewrite's refusals in a migration's words: what was wrong, that nothing
  /// was uploaded, and what to do next, listing at most five items.
  static func refusal(_ error: RewriteRunError, fromRun: Int64, params: ExternalMigrationParams) -> Error {
    let prepare = params.targets.first.map { "pinax externals migrate --project \($0.project) --host HOST" }
      ?? "pinax externals migrate --project SLUG --host HOST"
    switch error {
    case let .planChanged(_, differences):
      return ExternalsMigrateError.refused(
        listing(
          "Files changed since preparation \(fromRun); nothing was uploaded. Prepare again (\(prepare)):",
          differences))
    case let .sourcesNotAllowed(sources):
      let flags = sources.map { "--allow-source " + ($0.components(separatedBy: " (").first ?? $0) }
      return ExternalsMigrateError.refused(
        listing(
          "Sources that are not clean must be allowed; nothing was uploaded. Run again with \(flags.joined(separator: " ")):",
          sources))
    case let .notAPreview(_, reason):
      return ExternalsMigrateError.refused(
        "Run \(fromRun) can’t be applied: \(reason); nothing was uploaded. Prepare again (\(prepare)).")
    default:
      return error
    }
  }

  static func listing(_ heading: String, _ items: [String], shown: Int = 5) -> String {
    var lines = [heading] + items.prefix(shown).map { "  \($0)" }
    if items.count > shown { lines.append("  … and \(items.count - shown) more") }
    return lines.joined(separator: "\n")
  }

  static func liveUploader(_ backend: Backend) throws -> any Uploader {
    guard let credentials = try Keychain().load(for: backend.keychainRef) else {
      throw ExternalsMigrateError.noCredentials(credentialMissingMessage(for: backend))
    }
    return S3Uploader(backend: backend, credentials: credentials)
  }

  @Sendable static func standardError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  static func host(of rawURL: String) -> String {
    (URL(string: rawURL)?.host ?? URLComponents(string: rawURL)?.host ?? "").lowercased()
  }

  /// The distinct Other Domains URLs of `project` that `hosts` or `urls`
  /// name, in the report's order. Anything named that matches none is a
  /// usage error listing the project's hosts.
  static func targets(
    project: String, hosts: [String], urls: [String], in database: CatalogDatabasePool
  ) async throws -> [String] {
    let references: [ExternalReference]
    do {
      references = try await CatalogUsage.externalReferences(project: project, in: database).references
        .filter { $0.domain == .other }
    } catch UsageCatalogError.projectNotFound(let slug) {
      throw CatalogConfigurationError.projectNotFound(slug)
    }
    let wantedHosts = Set(hosts.map { $0.lowercased() })
    let wantedURLs = Set(urls)
    var seen = Set<String>()
    var chosen: [String] = []
    var hit = Set<String>()
    for reference in references {
      let host = host(of: reference.rawURL)
      let byHost = wantedHosts.contains(host)
      let byURL = wantedURLs.contains(reference.rawURL)
      if byHost { hit.insert("host:" + host) }
      if byURL { hit.insert("url:" + reference.rawURL) }
      if (byHost || byURL) && seen.insert(reference.rawURL).inserted { chosen.append(reference.rawURL) }
    }
    var missing: [String] = []
    var named = Set<String>()
    for host in hosts where named.insert("host:" + host.lowercased()).inserted && !hit.contains("host:" + host.lowercased()) {
      missing.append(host)
    }
    for url in urls where named.insert("url:" + url).inserted && !hit.contains("url:" + url) {
      missing.append(url)
    }
    guard missing.isEmpty else {
      var known: [String] = []
      var counted = Set<String>()
      for reference in references where counted.insert(host(of: reference.rawURL)).inserted {
        known.append(host(of: reference.rawURL))
      }
      throw ExternalsMigrateError.notInOtherDomains(project: project, missing: missing, hosts: known.sorted())
    }
    return chosen
  }

  // MARK: Preparation output

  static func prepareOutput(
    _ result: ExternalMigrationResult, bucket: Backend?, format: RewriteOutputFormat
  ) throws -> RewriteCommandOutput {
    let events = result.events
    let sources = events.compactMap { if case let .sourceStatus(e) = $0 { return e } else { return nil } }
    let failures = events.compactMap { if case let .downloadFailed(e) = $0 { return e } else { return nil } }
    if format == .json {
      let document = PrepareJSON(
        runID: result.runID, state: result.state.rawValue, backend: bucket?.slug, sources: sources,
        planned: events.compactMap { if case let .migrationPlanned(e) = $0 { return e } else { return nil } },
        skipped: failures,
        files: events.compactMap { if case let .filePlanned(e) = $0 { return e } else { return nil } },
        summary: result.summary)
      return RewriteCommandOutput(stdout: try encodedJSON(document))
    }
    let migration = result.summary.migration ?? ExternalMigrationSummary()
    var lines = [
      "Prepared run \(result.runID) — pinax externals migrate --apply --from-run \(result.runID) to migrate."
    ]
    lines.append("Hosts")
    var failedByHost: [String: Int] = [:]
    for failure in failures { failedByHost[failure.host, default: 0] += 1 }
    for host in migration.hosts {
      var line = "  \(host.host) · \(plural(host.links, "link"))"
      var notes = host.tips
      if let failed = failedByHost[host.host], failed < host.urls {
        notes.append("\(failed) of \(plural(host.urls, "image")) skipped")
      }
      if !notes.isEmpty { line += " · " + notes.joined(separator: " · ") }
      lines.append(line)
    }
    lines.append("Summary")
    lines.append(
      "  Upload\t\(plural(migration.migratable.images, "image")) · \(plural(migration.migratable.links, "link")) · "
        + ByteCountFormatter.string(fromByteCount: migration.bytes, countStyle: .file))
    lines.append("  Already in library\t\(plural(migration.reused.images, "image")) · \(plural(migration.reused.links, "link"))")
    lines.append("  Skipped\t\(plural(migration.skipped.images, "image")) · \(plural(migration.skipped.links, "link"))")
    let files = migration.files.map { "\($0.project)/\($0.source) · \(plural($0.files, "file"))" }
    lines.append("  Files to change\t" + (files.isEmpty ? "none" : files.joined(separator: ", ")))
    if let bucket { lines.append("  Bucket\t\(bucket.slug) · \(bucket.bucket)") }
    if !migration.sampleKeys.isEmpty { lines.append("  New keys\t" + migration.sampleKeys.joined(separator: ", ")) }
    let unclean = sources.filter { $0.status != .clean }
    if !unclean.isEmpty {
      lines.append("Sources")
      for source in unclean {
        lines.append(
          "  " + RunEvent.sourceStatus(source).summaryLine
            + " — to write it, add --allow-source \(source.project)/\(source.source)")
      }
    }
    if !failures.isEmpty {
      lines.append("Skipped")
      lines += failures.map { "  " + RunEvent.downloadFailed($0).summaryLine }
    }
    return RewriteCommandOutput(stdout: lines.joined(separator: "\n"))
  }

  // MARK: Apply output

  /// 69 when the backend stopped the run, 1 when it was stopped or an
  /// image or file failed, else 0.
  static func exitCode(_ result: ExternalMigrationResult) -> Int32 {
    switch result.state {
    case .failed: return RewriteExit.remote
    case .cancelled: return RewriteExit.failure
    default:
      let summary = result.summary
      let failed = summary.migration?.failed?.images ?? 0
      let changed = summary.skippedFiles?[RewriteFileSkipReason.changedSincePlan.rawValue] ?? 0
      return failed > 0 || changed > 0 || (summary.failed ?? 0) > 0 ? RewriteExit.failure : 0
    }
  }

  static func applyOutput(
    _ result: ExternalMigrationResult, fromRun: Int64, events: [RunEventRecord], format: RewriteOutputFormat
  ) throws -> RewriteCommandOutput {
    let exitCode = exitCode(result)
    let all = events.map(\.event)
    if format == .json {
      let document = ApplyJSON(
        runID: result.runID, fromRunID: fromRun, state: result.state.rawValue,
        uploaded: all.compactMap { if case let .uploadFinished(e) = $0 { return e } else { return nil } },
        reused: all.compactMap { if case let .assetReused(e) = $0 { return e } else { return nil } },
        uploadFailed: all.compactMap { if case let .uploadFailed(e) = $0 { return e } else { return nil } },
        verifyFailed: all.compactMap { if case let .verifyFailed(e) = $0 { return e } else { return nil } },
        keyChanged: all.compactMap { if case let .keyChanged(e) = $0 { return e } else { return nil } },
        summary: result.summary)
      return RewriteCommandOutput(stdout: try encodedJSON(document), exitCode: exitCode)
    }
    var lines = ["Run \(result.runID) from preparation \(fromRun) · \(result.state.rawValue)"]
    if let finished = all.last(where: { if case .runFinished = $0 { return true } else { return false } }) {
      lines[0] += " — " + finished.summaryLine
    }
    for event in all {
      switch event {
      case .fileWritten, .fileSkipped, .fileFailed, .rescanFinished, .rescanFailed:
        lines.append("  " + event.summaryLine)
      default: break
      }
    }
    if let byRepo = result.summary.changedFilesByRepo, !byRepo.isEmpty {
      lines.append("Changed files")
      for repository in byRepo.keys.sorted() {
        let count = byRepo[repository]?.count ?? 0
        let name = repository == RewriteRunSummary.notInGitKey ? "not in git" : repository
        lines.append("  \(name) · \(plural(count, "file"))")
      }
    }
    return RewriteCommandOutput(stdout: lines.joined(separator: "\n"), exitCode: exitCode)
  }
}

private func plural(_ count: Int, _ noun: String) -> String {
  "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// Prints each image's events of the apply run as they land (one
/// `summaryLine` per image, on stderr). The run is the newest apply of
/// `baseID` still running.
private final class EventTail: @unchecked Sendable {
  private let lock = NSLock()
  private let database: CatalogDatabasePool
  private let baseID: Int64
  private let log: @Sendable (String) -> Void
  private var runID: Int64?
  private var lastSeq = 0

  init(database: CatalogDatabasePool, baseID: Int64, log: @escaping @Sendable (String) -> Void) {
    self.database = database
    self.baseID = baseID
    self.log = log
  }

  func flush(runID known: Int64? = nil) {
    lock.withLock {
      if let known { runID = known }
      if runID == nil {
        runID = (try? RunLog.runs(limit: 5, in: database))?
          .first { $0.fromRunID == baseID && !$0.dryRun && $0.kind == .externalMigrate }?.id
      }
      guard let runID, let records = try? RunLog.events(of: runID, in: database) else { return }
      for record in records where record.seq > lastSeq {
        lastSeq = record.seq
        switch record.event {
        case .assetReused, .uploadFinished, .uploadFailed, .verifyFailed, .keyChanged, .migrationStopped:
          log(record.event.summaryLine)
        default: break
        }
      }
    }
  }
}

private struct PrepareJSON: Encodable {
  let schema = ExternalsMigrateCommand.schema
  let runID: Int64
  let dryRun = true
  let state: String
  let backend: String?
  let sources: [SourceStatusEvent]
  let planned: [MigrationPlannedEvent]
  let skipped: [DownloadFailedEvent]
  let files: [FilePlannedEvent]
  let summary: RewriteRunSummary

  enum CodingKeys: String, CodingKey {
    case schema, state, backend, sources, planned, skipped, files, summary
    case runID = "run_id"
    case dryRun = "dry_run"
  }
}

private struct ApplyJSON: Encodable {
  let schema = ExternalsMigrateCommand.schema
  let runID: Int64
  let fromRunID: Int64
  let dryRun = false
  let state: String
  let uploaded: [UploadFinishedEvent]
  let reused: [AssetReusedEvent]
  let uploadFailed: [UploadFailedEvent]
  let verifyFailed: [VerifyFailedEvent]
  let keyChanged: [KeyChangedEvent]
  let summary: RewriteRunSummary

  enum CodingKeys: String, CodingKey {
    case schema, state, uploaded, reused, summary
    case runID = "run_id"
    case fromRunID = "from_run_id"
    case dryRun = "dry_run"
    case uploadFailed = "upload_failed"
    case verifyFailed = "verify_failed"
    case keyChanged = "key_changed"
  }
}
