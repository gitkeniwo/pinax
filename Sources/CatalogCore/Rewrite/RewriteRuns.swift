import Foundation

/// The outcome of `RewriteRuns.preview`.
public struct RewritePreviewResult: Sendable {
  public let runID: Int64
  /// One per target, in target order.
  public let plans: [RewritePlan]
  /// Keyed by new URL; empty when nothing was checked.
  public let verifications: [String: TargetVerification]
  /// Every event recorded, in order.
  public let events: [RunEvent]
  public let summary: RewriteRunSummary
  /// `finished`, or `cancelled` when stopped between two checks.
  public var state: RunState = .finished
}

/// How far a preview is. `plan` counts projects
/// planned; `check` counts URLs checked, the second check of a URL that
/// may be already broken included — `total` grows by those once the first
/// pass is done, so `done` only rises and the last report has
/// `done == total`.
public struct RewritePreviewProgress: Equatable, Sendable {
  public enum Phase: String, Sendable { case plan, check }

  public let phase: Phase
  public let done: Int
  public let total: Int

  public init(phase: Phase, done: Int, total: Int) {
    self.phase = phase
    self.done = done
    self.total = total
  }
}

/// Where an apply is, for the activity bar —
/// the prefix change (a domain move's), the writes, each project's rescan.
public enum RewriteApplyPhase: Equatable, Sendable {
  case changingPrefix
  case rewriting(files: Int)
  case rescanning(project: String)
}

public struct RewriteRunFileResult: Equatable, Sendable {
  public let project: String
  public let result: RewriteFileResult
}

/// The outcome of `RewriteRuns.apply`.
public struct RewriteApplyResult: Sendable {
  public let runID: Int64
  public let fromRunID: Int64
  public let results: [RewriteRunFileResult]
  public let summary: RewriteRunSummary
}

public enum RewriteRunError: Error, Equatable, CustomStringConvertible {
  case runNotFound(Int64)
  /// The run an apply names is not a finished preview of this kind.
  case notAPreview(Int64, reason: String)
  /// The files or edits differ from the preview's; nothing was written.
  case planChanged(runID: Int64, differences: [String])
  /// `project/label` entries that are not sources of the run's projects.
  case unknownSources([String])
  /// Unclean sources with edits that were not allowed, as
  /// `project/label (status)`; nothing was written.
  case sourcesNotAllowed([String])
  /// The preview's checks that were not `.ok`, as `url (result)`; nothing
  /// was written.
  case targetsNotVerified(runID: Int64, [String])

  public var description: String {
    switch self {
    case let .runNotFound(id):
      return "No run \(id)."
    case let .notAPreview(id, reason):
      return "Run \(id) can’t be applied: \(reason)."
    case let .planChanged(id, differences):
      return (["The files changed since preview run \(id). Preview again before writing:"]
        + differences.map { "  \($0)" }).joined(separator: "\n")
    case let .unknownSources(sources):
      return "Not a source of this run’s projects: \(sources.joined(separator: ", "))."
    case let .sourcesNotAllowed(sources):
      return (["Sources that are not clean must be allowed before rewriting:"]
        + sources.map { "  \($0)" }).joined(separator: "\n")
    case let .targetsNotVerified(id, urls):
      return RewriteRuns.failedCheckListing(
        "Preview run \(id) has new URLs that failed the check; nothing was written:", urls, runID: id)
    }
  }
}

/// A preview records what a rewrite would do; an apply
/// writes exactly that, or nothing.
public enum RewriteRuns {
  /// sha256 of every edit's line, column, old and new text.
  public static func editsDigest(_ edits: [RewriteEdit]) -> String {
    Hashing.sha256(
      of: Data(edits.map { "\($0.line)\t\($0.column)\t\($0.oldText)\t\($0.newText)\n" }.joined().utf8))
  }

  /// Plans every target, then records a dry-run run with its events. A
  /// target that cannot be planned throws before any run is recorded.
  /// `cancellation` takes effect between two checks: no further URL is
  /// fetched, the checks already done are logged, and the run ends
  /// `cancelled` (an apply refuses it). Nothing is written either way.
  public static func preview(
    targets: [RewriteRunTarget],
    kind: RunKind = .rewrite,
    backendID: Int64? = nil,
    domain: DomainMigrationParams? = nil,
    verifier: RewriteTargetVerifying? = nil,
    database: CatalogDatabasePool,
    git: GitStatusProviding = GitStatusProvider(),
    cancellation: ExternalMigrationCancellation? = nil,
    progress: (@Sendable (RewritePreviewProgress) -> Void)? = nil
  ) async throws -> RewritePreviewResult {
    var plans: [RewritePlan] = []
    for target in targets {
      plans.append(try RewritePlanner.plan(project: target.project, rules: target.rules, database: database, git: git))
      progress?(RewritePreviewProgress(phase: .plan, done: plans.count, total: targets.count))
    }
    let params = RewriteRunParams(targets: targets, verify: verifier != nil, domain: domain)
    let runID = try RunLog.start(
      kind: kind, backendID: backendID, dryRun: true, params: params, in: database)
    var log = EventSink(runID: runID, database: database)
    do {
      try log.write(.runStarted(params))
      for plan in plans {
        for source in plan.sources {
          try log.write(.sourceStatus(SourceStatusEvent(project: plan.project, source: source.label, git: source.git)))
        }
        for event in plannedEvents(plan) { try log.write(event) }
      }
      var summary = planSummary(plans)
      var verifications: [String: TargetVerification] = [:]
      if let verifier {
        var targets: [RewriteTarget] = []
        var seen = Set<String>()
        for target in plans.flatMap(\.targets) where seen.insert(target.url).inserted {
          targets.append(target)
        }
        let counter = CheckCounter(total: targets.count, progress: progress)
        verifications = await RewriteTargetCheck.verify(
          targets, with: verifier, cancellation: cancellation, checked: counter.tick)
        // A new URL outside the catalog that fails is checked
        // again at its old URLs; when they all fail too it was already broken.
        let stopped = cancellation?.isCancelled == true
        let recheck = stopped ? [] : targets.filter {
          guard $0.expectedSHA256 == nil, case .unreachable = verifications[$0.url] else { return false }
          return !$0.oldURLs.isEmpty
        }
        let oldURLs = Array(Set(recheck.flatMap(\.oldURLs))).sorted()
        counter.grow(by: oldURLs.count)
        let oldResults = await RewriteTargetCheck.verify(
          oldURLs.map { RewriteTarget(url: $0, expectedSHA256: nil) }, with: verifier,
          cancellation: cancellation, checked: counter.tick)
        var oldReasons: [String: String] = [:]
        for target in recheck {
          let reasons = target.oldURLs.map { url -> String? in
            if case let .unreachable(reason) = oldResults[url] { return reason } else { return nil }
          }
          if let first = reasons.first, !reasons.contains(nil) { oldReasons[target.url] = first }
        }
        var counts: [String: Int] = [:]
        for target in targets.sorted(by: { $0.url < $1.url }) {
          guard let verification = verifications[target.url] else { continue }
          let event = TargetVerifiedEvent(
            url: target.url, expectedSHA256: target.expectedSHA256, verification: verification,
            oldReason: oldReasons[target.url])
          counts[event.result.rawValue, default: 0] += 1
          try log.write(.targetVerified(event))
        }
        summary.verified = counts
        summary.notInCatalog = targets.filter { $0.expectedSHA256 == nil }.count
        if cancellation?.isCancelled == true {
          let done = verifications.count + oldResults.count
          try log.write(.migrationStopped(MigrationStoppedEvent(
            done: done, total: targets.count + oldURLs.count, phase: "check")))
          summary.errors = log.errors
          try log.write(.runFinished(summary))
          try RunLog.finish(runID, state: .cancelled, summary: summary, in: database)
          return RewritePreviewResult(
            runID: runID, plans: plans, verifications: verifications, events: log.events, summary: summary,
            state: .cancelled)
        }
      }
      summary.errors = log.errors
      try log.write(.runFinished(summary))
      try RunLog.finish(runID, state: .finished, summary: summary, in: database)
      return RewritePreviewResult(
        runID: runID, plans: plans, verifications: verifications, events: log.events, summary: summary)
    } catch {
      RunLog.fail(runID, in: database)
      throw error
    }
  }

  /// Writes what preview run `baseID` showed. `allowedSources` are
  /// `project/label`. Refusals (no finished preview `baseID`, files changed
  /// since the preview, unclean sources not allowed) throw before a run is
  /// recorded and before anything is written.
  /// `beforeWriting` runs once every check has passed, after the run is
  /// recorded and before the first file is written; its events are logged
  /// and an error it throws fails the run with nothing written.
  /// The preview's `target_verified` events that failed (not `.ok` or
  /// `already_broken`), as `url (result)`.
  public static func failedChecks(of runID: Int64, in database: CatalogDatabasePool) throws -> [String] {
    try RunLog.events(of: runID, in: database).compactMap {
      guard case let .targetVerified(event) = $0.event, event.isFailure else { return nil }
      return "\(event.url) (\(event.result.rawValue))"
    }
  }

  public static func apply(
    fromRun baseID: Int64,
    allowedSources: Set<String>,
    kind: RunKind = .rewrite,
    database: CatalogDatabasePool,
    git: GitStatusProviding = GitStatusProvider(),
    backupRoot: URL = RewriteApplier.defaultBackupRoot(),
    processExists: (Int32) -> Bool = RunLog.processExists,
    beforeWriting: (() throws -> [RunEvent])? = nil,
    phase: (@Sendable (RewriteApplyPhase) -> Void)? = nil
  ) throws -> RewriteApplyResult {
    guard let base = try RunLog.run(baseID, in: database, processExists: processExists) else {
      throw RewriteRunError.runNotFound(baseID)
    }
    guard base.kind == kind else {
      throw RewriteRunError.notAPreview(baseID, reason: "it is a \(base.kind.rawValue) run")
    }
    guard base.dryRun else { throw RewriteRunError.notAPreview(baseID, reason: "it is not a preview") }
    guard base.state == .finished else {
      throw RewriteRunError.notAPreview(baseID, reason: "the preview is \(base.state.rawValue)")
    }
    let baseParams = try JSONDecoder().decode(RewriteRunParams.self, from: Data(base.params.utf8))
    let failed = try failedChecks(of: baseID, in: database)
    guard failed.isEmpty else { throw RewriteRunError.targetsNotVerified(runID: baseID, failed) }

    // Step 2: the same files with the same bytes and the same edits.
    var expected: [String: FilePlannedEvent] = [:]
    for record in try RunLog.events(of: baseID, in: database) {
      if case let .filePlanned(event) = record.event {
        expected["\(event.project)/\(event.source)/\(event.path)"] = event
      }
    }
    let plans = try baseParams.targets.map {
      try RewritePlanner.plan(project: $0.project, rules: $0.rules, database: database, git: git)
    }
    var actual: [String: (sha256: String, digest: String)] = [:]
    for plan in plans {
      for file in plan.files where file.newContent != nil {
        actual["\(plan.project)/\(file.sourceLabel)/\(file.path)"] =
          (file.originalSHA256, editsDigest(file.edits))
      }
    }
    var differences: [String] = []
    for key in Set(expected.keys).union(actual.keys).sorted() {
      switch (expected[key], actual[key]) {
      case (nil, _?): differences.append("\(key): new edits")
      case (_?, nil): differences.append("\(key): no edits now")
      case let (before?, now?) where before.sha256 != now.sha256:
        differences.append("\(key): file changed")
      case let (before?, now?) where before.editsDigest != now.digest:
        differences.append("\(key): edits changed")
      default: break
      }
    }
    guard differences.isEmpty else {
      throw RewriteRunError.planChanged(runID: baseID, differences: differences)
    }

    let statuses = try checkSources(plans, allowedSources: allowedSources, git: git)

    let params = RewriteRunParams(
      targets: baseParams.targets, allowedSources: allowedSources.sorted(), domain: baseParams.domain)
    let runID = try RunLog.start(
      kind: kind, backendID: base.backendID, dryRun: false, fromRunID: baseID, params: params,
      in: database)
    var log = EventSink(runID: runID, database: database)
    do {
      try log.write(.runStarted(params))
      for status in statuses {
        try log.write(.sourceStatus(SourceStatusEvent(project: status.project, source: status.source.label, git: status.source.git)))
      }
      if let beforeWriting {
        for event in try beforeWriting() { try log.write(event) }
      }
      phase?(.rewriting(files: plans.reduce(0) { $0 + $1.files.count { $0.newContent != nil } }))
      let written = try write(
        plans, allowedSources: allowedSources, backupRoot: backupRoot, runID: runID, git: git, log: &log)
      try rescan(written.rescanned, database: database, log: &log, phase: phase)
      var summary = planSummary(plans)
      written.fill(&summary)
      summary.errors = log.errors
      try log.write(.runFinished(summary))
      try RunLog.finish(runID, state: .finished, summary: summary, in: database)
      return RewriteApplyResult(runID: runID, fromRunID: baseID, results: written.results, summary: summary)
    } catch {
      RunLog.fail(runID, in: database)
      throw error
    }
  }

  /// The unified diff of a `rewrite` or
  /// `domain_migrate` preview, planned again from the run's
  /// `params.targets` as `pinax rewrite --diff` prints it at preview time
  /// (each file's diff, joined). A file changed since the preview shows as
  /// it is now; the apply refuses that, not this.
  public static func diff(
    ofRun runID: Int64, in database: CatalogDatabasePool, git: GitStatusProviding = GitStatusProvider()
  ) throws -> String {
    guard let run = try RunLog.run(runID, in: database) else { throw RewriteRunError.runNotFound(runID) }
    guard run.kind == .rewrite || run.kind == .domainMigrate else {
      throw RewriteRunError.notAPreview(runID, reason: "it is a \(run.kind.rawValue) run")
    }
    guard run.dryRun else { throw RewriteRunError.notAPreview(runID, reason: "it is not a preview") }
    let params = try JSONDecoder().decode(RewriteRunParams.self, from: Data(run.params.utf8))
    var parts: [String] = []
    for target in params.targets {
      let plan = try RewritePlanner.plan(project: target.project, rules: target.rules, database: database, git: git)
      for file in plan.files {
        guard let newContent = file.newContent else { continue }
        parts.append(
          RewriteDiff.unified(
            label: file.sourceLabel, path: file.path,
            old: String(decoding: file.originalContent, as: UTF8.self),
            new: String(decoding: newContent, as: UTF8.self)))
      }
    }
    return parts.joined()
  }

  // MARK: - Helpers

  /// What `write` did, for the run's summary.
  struct WrittenFiles {
    var results: [RewriteRunFileResult] = []
    var skippedFiles: [String: Int] = [:]
    var failed = 0
    var changed: [String: [String]] = [:]
    /// Projects with at least one file written, in plan order.
    var rescanned: [String] = []

    func fill(_ summary: inout RewriteRunSummary) {
      summary.written = changed.values.reduce(0) { $0 + $1.count }
      summary.skippedFiles = skippedFiles
      summary.failed = failed
      summary.changedFilesByRepo = changed.mapValues { $0.sorted() }
    }
  }

  /// Allowed sources, across every project before any project is written:
  /// every `project/label` must be a source, and every source with edits
  /// that is not clean (status taken now) must be allowed. Returns the
  /// statuses of the sources with edits.
  static func checkSources(
    _ plans: [RewritePlan], allowedSources: Set<String>, git: GitStatusProviding
  ) throws -> [(project: String, source: RewriteSourceState)] {
    let known = Set(plans.flatMap { plan in plan.sources.map { "\(plan.project)/\($0.label)" } })
    let unknown = allowedSources.subtracting(known).sorted()
    guard unknown.isEmpty else { throw RewriteRunError.unknownSources(unknown) }
    var statuses: [(project: String, source: RewriteSourceState)] = []
    for plan in plans {
      let touched = Set(plan.files.filter { $0.newContent != nil }.map(\.sourceLabel))
      for source in plan.sources where touched.contains(source.label) {
        statuses.append(
          (plan.project,
           RewriteSourceState(
            label: source.label, path: source.path,
            git: git.status(of: URL(fileURLWithPath: source.path, isDirectory: true)))))
      }
    }
    let refused = statuses.filter {
      !$0.source.git.isClean && !allowedSources.contains("\($0.project)/\($0.source.label)")
    }
    guard refused.isEmpty else {
      throw RewriteRunError.sourcesNotAllowed(
        refused.map { "\($0.project)/\($0.source.label) (\(describe($0.source.git)))" })
    }
    return statuses
  }

  /// Applies each plan, logging every file's outcome.
  /// `allowedSources` are `project/label`.
  static func write(
    _ plans: [RewritePlan], allowedSources: Set<String>, backupRoot: URL, runID: Int64,
    git: GitStatusProviding, log: inout EventSink
  ) throws -> WrittenFiles {
    var written = WrittenFiles()
    for plan in plans {
      let prefix = plan.project + "/"
      let labels = Set(allowedSources.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
      let fileResults = try RewriteApplier.apply(
        plan: plan, allowedSources: labels, backupRoot: backupRoot, runID: String(runID), git: git)
      let sourcePaths = Dictionary(plan.sources.map { ($0.label, $0.path) }, uniquingKeysWith: { a, _ in a })
      for result in fileResults {
        written.results.append(RewriteRunFileResult(project: plan.project, result: result))
        switch result.outcome {
        case let .written(before, after, edits, backup):
          try log.write(.fileWritten(FileWrittenEvent(
            project: plan.project, source: result.sourceLabel, path: result.path,
            beforeSHA256: before, afterSHA256: after, edits: edits, backupPath: backup)))
          let (repository, path) = repositoryPath(
            root: sourcePaths[result.sourceLabel] ?? "", relativePath: result.path)
          written.changed[repository ?? RewriteRunSummary.notInGitKey, default: []].append(path)
        case let .skipped(reason):
          written.skippedFiles[reason.rawValue, default: 0] += 1
          try log.write(.fileSkipped(FileSkippedEvent(
            project: plan.project, source: result.sourceLabel, path: result.path, reason: reason.rawValue)))
        case let .failed(message):
          written.failed += 1
          try log.write(.fileFailed(FileFailedEvent(
            project: plan.project, source: result.sourceLabel, path: result.path, error: message)))
        }
      }
      if fileResults.contains(where: { if case .written = $0.outcome { return true } else { return false } }) {
        written.rescanned.append(plan.project)
      }
    }
    return written
  }

  /// Rescans the projects by the same path as `pinax usage scan`.
  static func rescan(
    _ projects: [String], database: CatalogDatabasePool, log: inout EventSink,
    phase: (@Sendable (RewriteApplyPhase) -> Void)? = nil
  ) throws {
    for project in projects {
      phase?(.rescanning(project: project))
      do {
        let scan = try UsageScanner.scan(project: project, in: database)
        let sync = try CatalogUsage.sync(scan.document, project: project, in: database)
        try log.write(.rescanFinished(RescanFinishedEvent(project: project, refs: sync.foundCount, files: scan.files)))
      } catch {
        try log.write(.rescanFailed(RescanFailedEvent(project: project, error: String(describing: error))))
      }
    }
  }

  /// A refusal's heading and at most `shown` failed checks, then
  /// `… and N more` and where to see them all.
  static func failedCheckListing(_ heading: String, _ urls: [String], runID: Int64, shown: Int = 5) -> String {
    var lines = [heading] + urls.prefix(shown).map { "  \($0)" }
    if urls.count > shown {
      lines.append("  … and \(urls.count - shown) more — pinax runs show \(runID) lists them all.")
    }
    return lines.joined(separator: "\n")
  }

  /// `file_planned`, `edit_skipped` and `protocol_relative_found` for one
  /// plan, in file order.
  static func plannedEvents(_ plan: RewritePlan) -> [RunEvent] {
    var events: [RunEvent] = []
    var protocolRelative: [(source: String, path: String, host: String, count: Int)] = []
    for hit in plan.protocolRelative {
      if let last = protocolRelative.last, last.source == hit.sourceLabel, last.path == hit.path,
        last.host == hit.host
      {
        protocolRelative[protocolRelative.count - 1].count += 1
      } else {
        protocolRelative.append((hit.sourceLabel, hit.path, hit.host, 1))
      }
    }
    for file in plan.files {
      if !file.edits.isEmpty, file.newContent != nil {
        events.append(.filePlanned(FilePlannedEvent(
          project: plan.project, source: file.sourceLabel, path: file.path, sha256: file.originalSHA256,
          edits: file.edits.count, editsDigest: editsDigest(file.edits))))
      }
      for skip in file.skips {
        events.append(.editSkipped(EditSkippedEvent(
          project: plan.project, source: file.sourceLabel, path: file.path, line: skip.line,
          reason: skip.reason.rawValue)))
      }
    }
    for hit in protocolRelative {
      events.append(.protocolRelativeFound(ProtocolRelativeEvent(
        project: plan.project, source: hit.source, path: hit.path, host: hit.host, count: hit.count)))
    }
    return events
  }

  static func planSummary(_ plans: [RewritePlan]) -> RewriteRunSummary {
    var summary = RewriteRunSummary()
    for plan in plans {
      summary.files += plan.summary.files
      summary.edits += plan.summary.edits
      summary.protocolRelative += plan.summary.protocolRelative
      for (reason, count) in plan.summary.skippedByReason {
        summary.skippedEdits[reason.rawValue, default: 0] += count
      }
    }
    return summary
  }

  /// The repository holding a source file and the file's path relative to
  /// it; outside git, nil and the path relative to the source.
  static func repositoryPath(root: String, relativePath: String) -> (String?, String) {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    guard let repository = GitStatusProvider.containingRepository(rootURL) else { return (nil, relativePath) }
    let file = rootURL.appendingPathComponent(relativePath).standardizedFileURL.path
    let base = repository.standardizedFileURL.path
    let prefix = base.hasSuffix("/") ? base : base + "/"
    return (base, file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : relativePath)
  }

  static func describe(_ status: SourceGitStatus) -> String {
    switch status {
    case .clean: return "clean"
    case .notGit: return "not in git"
    case let .dirty(paths): return "uncommitted changes (\(paths.count))"
    case let .unknown(reason): return "git status unknown: \(reason)"
    }
  }
}

/// The check phase's running count, across the first pass and the second
/// check of URLs that may be already broken.
private final class CheckCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var done = 0
  private var total: Int
  private let progress: (@Sendable (RewritePreviewProgress) -> Void)?

  init(total: Int, progress: (@Sendable (RewritePreviewProgress) -> Void)?) {
    self.total = total
    self.progress = progress
  }

  func grow(by count: Int) {
    lock.withLock { total += count }
  }

  @Sendable func tick() {
    let report = lock.withLock { () -> RewritePreviewProgress in
      done += 1
      return RewritePreviewProgress(phase: .check, done: done, total: total)
    }
    progress?(report)
  }
}

/// Appends events to one run and counts the errors among them.
struct EventSink {
  let runID: Int64
  let database: CatalogDatabasePool
  var errors = 0
  var events: [RunEvent] = []

  mutating func write(_ event: RunEvent) throws {
    if event.level == .error { errors += 1 }
    try RunLog.append(event, to: runID, in: database)
    events.append(event)
  }
}
