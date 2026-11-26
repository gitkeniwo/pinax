import Foundation
import GRDB

extension ExternalMigration {
  /// Uploads what preparation `baseID` downloaded, checks each
  /// new URL, then rewrites in one go and rescans. Refusals (the run, its
  /// downloads, changed files, unclean sources not allowed) throw before a
  /// run is recorded and before anything is uploaded; they keep the
  /// downloads. Once the run is recorded, its preparation's downloads are
  /// deleted however it ends.
  ///
  /// - Parameters:
  ///   - allowedSources: `project/label` of unclean sources that may be written.
  ///   - now: the upload date (`uploaded_at` and the key's month).
  ///   - cancellation: checked between images; never during the rewrite.
  ///   - compression: whether each image is compressed before upload; by
  ///     default as its target project says.
  public static func apply(
    fromRun baseID: Int64,
    allowedSources: Set<String>,
    database: CatalogDatabasePool,
    uploader: any Uploader,
    verifier: RewriteTargetVerifying = PublicTargetVerifier(),
    git: GitStatusProviding = GitStatusProvider(),
    cacheRoot: URL = defaultCacheRoot(),
    backupRoot: URL = RewriteApplier.defaultBackupRoot(),
    now: Date = Date(),
    compression: CompressionChoice = .project,
    cancellation: ExternalMigrationCancellation = ExternalMigrationCancellation(),
    progress: (@Sendable (ExternalMigrationProgress) -> Void)? = nil,
    processExists: (Int32) -> Bool = RunLog.processExists,
    commands: CommandSourcePolicy = .deny,
    runner: CommandSourceRunning = ShellCommandRunner()
  ) async throws -> ExternalMigrationResult {
    try gate.enter()
    defer { gate.leave() }

    // Step 1: the preparation and its downloads.
    guard let base = try RunLog.run(baseID, in: database, processExists: processExists) else {
      throw RewriteRunError.runNotFound(baseID)
    }
    guard base.kind == .externalMigrate else {
      throw RewriteRunError.notAPreview(baseID, reason: "it is a \(base.kind.rawValue) run")
    }
    guard base.dryRun else { throw RewriteRunError.notAPreview(baseID, reason: "it is not a preparation") }
    guard base.state == .finished else {
      throw RewriteRunError.notAPreview(baseID, reason: "the preparation is \(base.state.rawValue)")
    }
    let baseParams = try JSONDecoder().decode(ExternalMigrationParams.self, from: Data(base.params.utf8))
    let (projects, backend) = try resolve(
      baseParams.targets.map(\.project), backend: baseParams.backend, in: database)
    var started: MigrationStartedEvent?
    var downloads: [String: DownloadFinishedEvent] = [:]
    var planned: [String: MigrationPlannedEvent] = [:]
    var plannedOrder: [String] = []
    var skipped: [String] = []
    var expected: [String: FilePlannedEvent] = [:]
    var baseSummary: ExternalMigrationSummary?
    for record in try RunLog.events(of: baseID, in: database) {
      switch record.event {
      case let .migrationStarted(event): started = event
      case let .downloadFinished(event): downloads[event.url] = event
      case let .downloadFailed(event): skipped.append(event.url)
      case let .migrationPlanned(event):
        planned[event.url] = event
        plannedOrder.append(event.url)
      case let .filePlanned(event): expected["\(event.project)/\(event.source)/\(event.path)"] = event
      case let .runFinished(summary): baseSummary = summary.migration
      default: break
      }
    }
    var problems: [String] = []
    for url in plannedOrder {
      let plan = planned[url]!
      if let assetID = plan.reusedAssetID {
        let exists = try await database.read { db in try Asset.fetchOne(db, key: assetID) != nil }
        if !exists { problems.append("\(url) (asset \(assetID) is gone)") }
        continue
      }
      guard let download = downloads[url],
        let data = FileManager.default.contents(atPath: download.cachePath)
      else {
        problems.append("\(url) (download missing)")
        continue
      }
      if Hashing.sha256(of: data) != download.sha256 { problems.append("\(url) (download changed)") }
    }
    guard problems.isEmpty else { throw ExternalMigrationError.cacheInvalid(runID: baseID, problems) }

    // Step 2: the files and sources, before anything is uploaded.
    let plannedURLs = planned.mapValues(\.newURL)
    let gatePlans = try plans(baseParams.targets, newURLs: plannedURLs, database: database, git: git)
    let gateFiles = plannedFiles(gatePlans)
    var differences: [String] = []
    for key in Set(expected.keys).union(gateFiles.keys).sorted() {
      switch (expected[key], gateFiles[key]) {
      case (nil, _?): differences.append("\(key): new edits")
      case (_?, nil): differences.append("\(key): no edits now")
      case let (before?, now?) where before.sha256 != now.sha256: differences.append("\(key): file changed")
      case let (before?, now?) where before.editsDigest != now.digest: differences.append("\(key): edits changed")
      default: break
      }
    }
    guard differences.isEmpty else { throw RewriteRunError.planChanged(runID: baseID, differences: differences) }
    let statuses = try RewriteRuns.checkSources(gatePlans, allowedSources: allowedSources, git: git)

    var params = baseParams
    params.allowedSources = allowedSources.sorted()
    let runID = try RunLog.start(
      kind: .externalMigrate, backendID: backend.id, dryRun: false, fromRunID: baseID, params: params,
      in: database, now: now)
    defer { removeCache(baseID, root: cacheRoot) }
    var log = EventSink(runID: runID, database: database)
    do {
      if let started { try log.write(.migrationStarted(started)) }
      for status in statuses {
        try log.write(.sourceStatus(SourceStatusEvent(project: status.project, source: status.source.label, git: status.source.git)))
      }

      // Step 3: reused assets need no upload; the rest go one sha256 at a time.
      var actual: [String: String] = [:]
      var reusedURLs: [String] = []
      for url in plannedOrder {
        guard let assetID = planned[url]!.reusedAssetID else { continue }
        guard let asset = try await database.read({ db in try Asset.fetchOne(db, key: assetID) }) else { continue }
        let newURL = URLResolver.url(for: asset, backend: backend)
        try log.write(.assetReused(AssetReusedEvent(url: url, assetID: assetID, newURL: newURL)))
        actual[url] = newURL
        reusedURLs.append(url)
      }
      var groups: [(sha256: String, urls: [String])] = []
      for url in plannedOrder where planned[url]!.reusedAssetID == nil {
        let sha = planned[url]!.sha256
        if let index = groups.firstIndex(where: { $0.sha256 == sha }) {
          groups[index].urls.append(url)
        } else {
          groups.append((sha, [url]))
        }
      }
      var uploadedURLs: [String] = []
      var failedURLs: [String] = []
      var newAssetIDs: [Int64] = []
      var done = 0
      var stopped = false
      var fatal = false
      for group in groups {
        if cancellation.isCancelled {
          stopped = true
          break
        }
        let first = group.urls[0]
        let plan = planned[first]!
        let slug = plan.project ?? baseParams.targets.first { $0.urls.contains(first) }!.project
        let project = projects[slug]!
        let pipeline = UploadPipeline(
          database: database, uploader: uploader, backend: backend, project: migrationProject(project))
        let outcome: UploadOutcome
        do {
          outcome = try await pipeline.upload(
            fileURL: URL(fileURLWithPath: downloads[first]!.cachePath), date: now, sourceURL: first,
            compression: compression.options(for: project))
        } catch {
          let (isFatal, status) = uploadFailure(error)
          try log.write(.uploadFailed(UploadFailedEvent(
            url: first, error: String(describing: error), fatal: isFatal, status: status)))
          failedURLs += group.urls
          done += 1
          if isFatal {
            fatal = true
            break
          }
          continue
        }
        let assetID = try await database.read { db in
          try Int64.fetchOne(
            db, sql: "SELECT id FROM asset WHERE backend_id = ? AND sha256 = ?",
            arguments: [backend.id, outcome.sha256])
        }
        if outcome.deduplicated, let assetID {
          // Uploaded since the preparation: the catalog already has it.
          for url in group.urls {
            try log.write(.assetReused(AssetReusedEvent(url: url, assetID: assetID, newURL: outcome.url)))
            actual[url] = outcome.url
          }
          reusedURLs += group.urls
          done += 1
          continue
        }
        if let assetID {
          newAssetIDs.append(assetID)
          // Every project naming one of these URLs gets the asset.
          let others = Set(baseParams.targets.filter { target in group.urls.contains { target.urls.contains($0) } }
            .compactMap { projects[$0.project]?.id })
          try await database.write { db in
            for projectID in others {
              try db.execute(
                sql: "INSERT OR IGNORE INTO asset_project (asset_id, project_id, added_at) VALUES (?, ?, ?)",
                arguments: [assetID, projectID, ISO8601DateFormatter().string(from: now)])
            }
          }
        }
        let verification = await verifier.verify(outcome.url, expectedSHA256: outcome.sha256)
        guard case .ok = verification else {
          let reason: String
          switch verification {
          case let .unreachable(why): reason = why
          case .mismatch: reason = "serves a different file"
          case .ok: reason = "ok"
          }
          for url in group.urls {
            try log.write(.verifyFailed(VerifyFailedEvent(url: url, newURL: outcome.url, reason: reason)))
          }
          failedURLs += group.urls
          done += 1
          continue
        }
        for url in group.urls {
          try log.write(.uploadFinished(UploadFinishedEvent(
            url: url, key: outcome.key, newURL: outcome.url, assetID: assetID ?? 0, bytes: outcome.byteSize)))
          if outcome.key != planned[url]!.key {
            try log.write(.keyChanged(KeyChangedEvent(url: url, plannedKey: planned[url]!.key, key: outcome.key)))
          }
          actual[url] = outcome.url
        }
        uploadedURLs += group.urls
        done += 1
        progress?(ExternalMigrationProgress(phase: .upload, done: done, total: groups.count, host: host(of: first)))
      }

      var linkCounts: [String: Int] = [:]
      for reference in try await CatalogUsage.externalReferences(in: database).references
      where baseParams.targets.contains(where: { $0.project == reference.projectSlug && $0.urls.contains(reference.rawURL) }) {
        linkCounts[reference.rawURL, default: 0] += 1
      }
      func count(_ urls: [String]) -> ExternalMigrationSummary.Count {
        ExternalMigrationSummary.Count(images: urls.count, links: urls.reduce(0) { $0 + (linkCounts[$1] ?? 0) })
      }
      var migration = baseSummary ?? ExternalMigrationSummary()
      migration.uploaded = count(uploadedURLs)
      migration.reused = count(reusedURLs)
      migration.failed = count(failedURLs)
      migration.newAssetIDs = newAssetIDs
      var summary = RewriteRunSummary()

      if stopped || fatal {
        if stopped {
          try log.write(.migrationStopped(MigrationStoppedEvent(done: done, total: groups.count, phase: "upload")))
          migration.stoppedAfter = done
        }
        summary.migration = migration
        summary.errors = log.errors
        try log.write(.runFinished(summary))
        let state: RunState = stopped ? .cancelled : .failed
        try RunLog.finish(runID, state: state, summary: summary, in: database)
        return ExternalMigrationResult(runID: runID, state: state, summary: summary, events: log.events)
      }

      // Step 4: one rewrite, not cancellable. With every URL as planned the
      // edits must match the preparation's; otherwise only the files'
      // bytes must. A file that differs is skipped, not the whole rewrite:
      // the uploads have happened.
      let samePlan = actual == plannedURLs
      var changedSincePlan = 0
      var plans = try self.plans(baseParams.targets, newURLs: actual, database: database, git: git)
      plans = try plans.map { plan in
        var kept: [RewriteFilePlan] = []
        for file in plan.files {
          guard file.newContent != nil else {
            kept.append(file)
            continue
          }
          let before = expected["\(plan.project)/\(file.sourceLabel)/\(file.path)"]
          if let before, before.sha256 == file.originalSHA256,
            !samePlan || before.editsDigest == RewriteRuns.editsDigest(file.edits)
          {
            kept.append(file)
          } else {
            changedSincePlan += 1
            try log.write(.fileSkipped(FileSkippedEvent(
              project: plan.project, source: file.sourceLabel, path: file.path,
              reason: RewriteFileSkipReason.changedSincePlan.rawValue)))
          }
        }
        return RewritePlan(
          project: plan.project, rules: plan.rules, sources: plan.sources, files: kept, targets: plan.targets,
          protocolRelative: plan.protocolRelative, summary: plan.summary)
      }
      let written = try RewriteRuns.write(
        plans, allowedSources: allowedSources, backupRoot: backupRoot, runID: runID, git: git, log: &log)
      // Step 5.
      try RewriteRuns.rescan(
        written.rescanned, database: database, commands: commands, runner: runner, log: &log)

      // Step 6.
      summary = RewriteRuns.planSummary(plans)
      written.fill(&summary)
      if changedSincePlan > 0 {
        summary.skippedFiles?[RewriteFileSkipReason.changedSincePlan.rawValue, default: 0] += changedSincePlan
      }
      summary.migration = migration
      summary.errors = log.errors
      try log.write(.runFinished(summary))
      try RunLog.finish(runID, state: .finished, summary: summary, in: database)
      return ExternalMigrationResult(runID: runID, state: .finished, summary: summary, events: log.events)
    } catch {
      RunLog.fail(runID, in: database)
      throw error
    }
  }
}
