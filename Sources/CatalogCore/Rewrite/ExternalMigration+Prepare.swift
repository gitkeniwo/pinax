import Foundation
import GRDB

extension ExternalMigration {
  /// Downloads each URL once, sorts the results, plans keys
  /// and the rewrite, and records a dry-run `external_migrate` run. Touches
  /// no bucket. Cancelled, it deletes its downloads and ends `cancelled`.
  ///
  /// - Parameters:
  ///   - targets: raw URLs per project, as the references have them.
  ///   - backend: a backend slug; nil takes the projects' default (the
  ///     upload rule: the project's backend, else the only one).
  ///   - now: the date keys are rendered with.
  public static func prepare(
    targets: [ExternalMigrationTarget],
    backend backendSlug: String? = nil,
    database: CatalogDatabasePool,
    fetcher: PublicObjectFetching = URLSessionPublicObjectFetcher(),
    git: GitStatusProviding = GitStatusProvider(),
    cacheRoot: URL = defaultCacheRoot(),
    now: Date = Date(),
    cancellation: ExternalMigrationCancellation = ExternalMigrationCancellation(),
    progress: (@Sendable (ExternalMigrationProgress) -> Void)? = nil
  ) async throws -> ExternalMigrationResult {
    var seenTargets = Set<String>()
    let targets = targets.compactMap { target -> ExternalMigrationTarget? in
      var seen = Set<String>()
      let urls = target.urls.filter { seen.insert($0).inserted }
      guard !urls.isEmpty, seenTargets.insert(target.project).inserted else { return nil }
      return ExternalMigrationTarget(project: target.project, urls: urls)
    }
    guard !targets.isEmpty else { throw ExternalMigrationError.noTargets }
    try gate.enter()
    defer { gate.leave() }

    let (projects, backend) = try resolve(targets.map(\.project), backend: backendSlug, in: database)
    var linkCounts: [String: [String: Int]] = [:]
    let references = try await CatalogUsage.externalReferences(in: database).references
    for reference in references {
      linkCounts[reference.projectSlug, default: [:]][reference.rawURL, default: 0] += 1
    }
    func links(_ url: String) -> Int {
      targets.reduce(0) { $0 + ($1.urls.contains(url) ? linkCounts[$1.project]?[url] ?? 0 : 0) }
    }
    var urls: [String] = []
    var seen = Set<String>()
    for target in targets {
      for url in target.urls where seen.insert(url).inserted { urls.append(url) }
    }

    let params = ExternalMigrationParams(targets: targets, backend: backend.slug)
    let runID = try RunLog.start(
      kind: .externalMigrate, backendID: backend.id, dryRun: true, params: params, in: database, now: now)
    let runCache = cacheRoot.appendingPathComponent(String(runID), isDirectory: true)
    // Step 8: only the latest preparation keeps its downloads.
    for entry in (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
    where entry != String(runID) {
      try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(entry))
    }
    var log = EventSink(runID: runID, database: database)
    do {
      try log.write(.migrationStarted(MigrationStartedEvent(
        targets: targets.map { target in
          MigrationStartedEvent.Target(
            project: target.project, urls: target.urls.count,
            links: target.urls.reduce(0) { $0 + (linkCounts[target.project]?[$1] ?? 0) },
            hosts: Set(target.urls.map(host(of:))).count)
        },
        backend: backend.slug, hosts: Set(urls.map(host(of:))).count)))

      // Steps 1–2: every URL once, at most four at a time.
      var downloaded: [String: DownloadFinishedEvent] = [:]
      var failed: [String: DownloadFailedEvent] = [:]
      let guarded = CancelGuardFetcher(base: fetcher, cancellation: cancellation)
      await withTaskGroup(of: (Int, String, Result<PublicObject, Error>).self) { group in
        var pending = urls.enumerated().makeIterator()
        func startNext() -> Bool {
          guard !cancellation.isCancelled, let (index, url) = pending.next() else { return false }
          group.addTask {
            guard let target = URL(string: url) else {
              return (index, url, .failure(PublicObjectFetchError.failed(URL(fileURLWithPath: "/"), detail: "not a URL")))
            }
            do { return (index, url, .success(try await guarded.fetchObject(target))) } catch {
              return (index, url, .failure(error))
            }
          }
          return true
        }
        for _ in 0..<maximumConcurrency where !startNext() { break }
        while let (index, url, result) = await group.next() {
          if case .failure(is CancelGuardFetcher.NotStarted) = result { continue }
          let host = host(of: url)
          do {
            switch result {
            case let .success(object):
              let directory = runCache.appendingPathComponent(String(index + 1), isDirectory: true)
              switch try store(object, url: url, host: host, in: directory) {
              case let .success(event):
                downloaded[url] = event
                try log.write(.downloadFinished(event))
              case let .failure(event):
                failed[url] = event
                try log.write(.downloadFailed(event))
              }
            case let .failure(error):
              let event = failure(url: url, host: host, error: error)
              failed[url] = event
              try log.write(.downloadFailed(event))
            }
          } catch {
            // A database or disk error: recorded below as the run's failure.
            failed[url] = DownloadFailedEvent(url: url, host: host, reason: .failed, detail: String(describing: error))
          }
          progress?(ExternalMigrationProgress(
            phase: .download, done: downloaded.count + failed.count, total: urls.count, host: host))
          _ = startNext()
        }
      }

      var summary = RewriteRunSummary()
      var migration = ExternalMigrationSummary()
      if cancellation.isCancelled {
        removeCache(runID, root: cacheRoot)
        let done = downloaded.count + failed.count
        try log.write(.migrationStopped(MigrationStoppedEvent(done: done, total: urls.count, phase: "download")))
        migration.stoppedAfter = done
        summary.migration = migration
        summary.errors = log.errors
        try log.write(.runFinished(summary))
        try RunLog.finish(runID, state: .cancelled, summary: summary, in: database)
        return ExternalMigrationResult(runID: runID, state: .cancelled, summary: summary, events: log.events)
      }

      // Step 3: keys, one per sha256, rendered for the first project that
      // names the URL; or the catalog's asset with that sha256.
      var newURLs: [String: String] = [:]
      var keyBySHA: [String: (key: String, url: String)] = [:]
      var reusedURLs = Set<String>()
      for url in urls {
        guard let download = downloaded[url] else { continue }
        let existing = try await database.read { db in
          try Asset.filter(Column("backend_id") == backend.id && Column("sha256") == download.sha256).fetchOne(db)
        }
        let event: MigrationPlannedEvent
        if let existing, let assetID = existing.id {
          let newURL = URLResolver.url(for: existing, backend: backend)
          reusedURLs.insert(url)
          event = MigrationPlannedEvent(
            url: url, sha256: download.sha256, key: existing.key, newURL: newURL, reusedAssetID: assetID,
            filename: download.filename)
        } else {
          let slug = targets.first { $0.urls.contains(url) }!.project
          let project = projects[slug]!
          let planned: (key: String, url: String)
          if let shared = keyBySHA[download.sha256] {
            planned = shared
          } else {
            let key = try renderKey(project: project, filename: download.filename, sha256: download.sha256, date: now)
            planned = (key, URLResolver.url(forKey: key, backend: backend))
            keyBySHA[download.sha256] = planned
          }
          event = MigrationPlannedEvent(
            url: url, sha256: download.sha256, key: planned.key, newURL: planned.url, project: slug,
            filename: download.filename)
        }
        newURLs[url] = event.newURL
        try log.write(.migrationPlanned(event))
      }

      // Step 4: the rewrite's preview events for the exact rules.
      let plans = try self.plans(targets, newURLs: newURLs, database: database, git: git)
      for plan in plans {
        for source in plan.sources {
          try log.write(.sourceStatus(SourceStatusEvent(project: plan.project, source: source.label, git: source.git)))
        }
        for event in RewriteRuns.plannedEvents(plan) { try log.write(event) }
      }

      // Steps 5–6.
      summary = RewriteRuns.planSummary(plans)
      var hostOrder: [String] = []
      var hostURLs: [String: [String]] = [:]
      for url in urls {
        let host = host(of: url)
        if hostURLs[host] == nil { hostOrder.append(host) }
        hostURLs[host, default: []].append(url)
      }
      migration.hosts = hostOrder.map { host in
        let hostURLs = hostURLs[host]!
        var tips: [String] = []
        if hostURLs.allSatisfy({ failed[$0] != nil }), let first = failed[hostURLs[0]] {
          tips.append("\(first.cause) · skipped")
        } else {
          if let tip = hostTip(host: host) { tips.append(tip) }
          if hostURLs.contains(where: { downloaded[$0]?.sniffed == true }) { tips.append("Type read from the image") }
        }
        return ExternalMigrationSummary.Host(
          host: host, links: hostURLs.reduce(0) { $0 + links($1) }, urls: hostURLs.count, tips: tips)
      }
      .enumerated().sorted { ($0.element.links, -$0.offset) > ($1.element.links, -$1.offset) }.map(\.element)
      for url in urls {
        if failed[url] != nil {
          migration.skipped.images += 1
          migration.skipped.links += links(url)
        } else if reusedURLs.contains(url) {
          migration.reused.images += 1
          migration.reused.links += links(url)
        } else {
          migration.migratable.images += 1
          migration.migratable.links += links(url)
        }
      }
      var counted = Set<String>()
      for url in urls {
        guard let download = downloaded[url], !reusedURLs.contains(url), counted.insert(download.sha256).inserted
        else { continue }
        migration.bytes += download.bytes
        if migration.sampleKeys.count < 3, let key = keyBySHA[download.sha256]?.key {
          migration.sampleKeys.append(key)
        }
      }
      for plan in plans {
        var bySource: [String: (files: Int, edits: Int)] = [:]
        var order: [String] = []
        for file in plan.files where file.newContent != nil {
          if bySource[file.sourceLabel] == nil { order.append(file.sourceLabel) }
          bySource[file.sourceLabel, default: (0, 0)].files += 1
          bySource[file.sourceLabel, default: (0, 0)].edits += file.edits.count
        }
        migration.files += order.map {
          ExternalMigrationSummary.Files(
            project: plan.project, source: $0, files: bySource[$0]!.files, edits: bySource[$0]!.edits)
        }
      }
      summary.migration = migration
      summary.errors = log.errors
      try log.write(.runFinished(summary))
      try RunLog.finish(runID, state: .finished, summary: summary, in: database)
      return ExternalMigrationResult(runID: runID, state: .finished, summary: summary, events: log.events)
    } catch {
      removeCache(runID, root: cacheRoot)
      RunLog.fail(runID, in: database)
      throw error
    }
  }

  /// The projects by slug and the backend the migration uploads to.
  static func resolve(
    _ slugs: [String], backend slug: String?, in database: CatalogDatabasePool
  ) throws -> (projects: [String: Project], backend: Backend) {
    try database.read { db in
      var projects: [String: Project] = [:]
      for slug in slugs {
        guard let project = try Project.filter(Column("slug") == slug).fetchOne(db) else {
          throw CatalogConfigurationError.projectNotFound(slug)
        }
        projects[slug] = project
      }
      let backends = try Backend.order(Column("id")).fetchAll(db)
      if let slug {
        guard let backend = backends.first(where: { $0.slug == slug }) else {
          throw CatalogConfigurationError.backendNotFound(slug)
        }
        return (projects, backend)
      }
      var chosen: [(project: String, backend: Backend)] = []
      for slug in slugs {
        if let id = projects[slug]!.backendID, let backend = backends.first(where: { $0.id == id }) {
          chosen.append((slug, backend))
        } else if backends.count == 1 {
          chosen.append((slug, backends[0]))
        } else {
          throw ExternalMigrationError.noBackend(project: slug)
        }
      }
      guard Set(chosen.map(\.backend.id)).count == 1 else {
        throw ExternalMigrationError.backendsDiffer(chosen.map { "\($0.project) → \($0.backend.slug)" })
      }
      return (projects, chosen[0].backend)
    }
  }

  /// The key the upload pipeline will render for this file.
  static func renderKey(project: Project, filename: String, sha256: String, date: Date) throws -> String {
    let project = migrationProject(project)
    do {
      return try KeyTemplate.render(
        template: project.keyTemplate!, keyPrefix: project.keyPrefix, originalFilename: filename,
        sha256: sha256, fileExtension: (filename as NSString).pathExtension, date: date)
    } catch let KeyTemplateError.invalid(issues) {
      throw UploadPipelineError.invalidKeyTemplate(project: project.slug, issues: issues)
    }
  }

  private enum Stored {
    case success(DownloadFinishedEvent)
    case failure(DownloadFailedEvent)
  }

  /// Sniffs, names and caches one download; a non-image is a failure.
  private static func store(
    _ object: PublicObject, url: String, host: String, in directory: URL
  ) throws -> Stored {
    guard let mime = MimeDetector.mimeType(of: object.data, fileExtension: ""), mime.hasPrefix("image/") else {
      return .failure(DownloadFailedEvent(
        url: url, host: host, reason: .notImage, detail: object.mime.map { "Content-Type \($0)" }))
    }
    let filename = filename(for: url, mime: mime)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(filename)
    try object.data.write(to: file, options: .atomic)
    return .success(DownloadFinishedEvent(
      url: url, host: host, sha256: Hashing.sha256(of: object.data), bytes: Int64(object.data.count),
      mime: mime, filename: filename, sniffed: !(object.mime?.lowercased().hasPrefix("image/") ?? false),
      cachePath: file.path))
  }

  /// Checks for a stop inside the fetch slot, so a GET queued behind the
  /// concurrency bound is never sent once stopped.
  private struct CancelGuardFetcher: PublicObjectFetching {
    struct NotStarted: Error {}

    let base: any PublicObjectFetching
    let cancellation: ExternalMigrationCancellation

    func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
      let object = try await fetchObject(url)
      return (object.data, object.mime, object.contentLength)
    }

    func fetchObject(_ url: URL) async throws -> PublicObject {
      if cancellation.isCancelled { throw NotStarted() }
      return try await base.fetchObject(url)
    }
  }
}
