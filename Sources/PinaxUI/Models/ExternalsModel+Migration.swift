import CatalogCore
import Foundation

/// Migrate to Bucket… on Other Domains — the
/// entries, the preparation in the status bar, the confirmation sheet, the
/// upload and rewrite, and what the rows say afterwards. The work itself is
/// the core's `ExternalMigration`, in this process.
extension ExternalsModel {
  /// A writable gallery has a migrator; a read-only one offers no migration.
  public var canMigrate: Bool { migrator != nil }

  /// Every entry is greyed while a preparation or apply runs,
  /// or a domain move does: the one lock says.
  public var isMigrationBusy: Bool { migrationLock.isBusy }

  public static let migrationBusyHelp = MigrationLock.busyHelp

  /// The distinct URLs `rows` would migrate: only on Other Domains, and none
  /// when a Your Domains row is among them.
  public func migrationURLs(_ rows: [ExternalReference]) -> [String] {
    guard canMigrate, !rows.isEmpty, rows.allSatisfy({ $0.domain == .other }) else { return [] }
    return ExternalsImportFacts.distinctURLs(rows)
  }

  /// The inspector's and the menu's N: the selection's distinct URLs.
  public var selectionMigrationCount: Int {
    migrationURLs(rows(selection)).count
  }

  /// "Migrate 3…" on a group header.
  public static func migrateShortTitle(_ count: Int) -> String { "Migrate \(count.formatted())…" }

  /// The multi-select inspector's primary button.
  public static func migrateInspectorTitle(_ count: Int) -> String { "Migrate \(count.formatted()) to Bucket…" }

  public func migrateSelection() async {
    await migrate(rows(selection))
  }

  /// Any entry: the rows' URLs, every row of the project referring to them
  /// rewritten. Starts the preparation at once.
  public func migrate(_ rows: [ExternalReference]) async {
    let urls = Set(migrationURLs(rows))
    guard !urls.isEmpty, !isMigrationBusy else { return }
    // One target per project, in the page's order; the scope's every row
    // for those URLs, so a URL two projects share goes in both.
    var order: [String] = []
    var byProject: [String: [String]] = [:]
    for row in items ?? [] where row.domain == .other && urls.contains(row.rawURL) {
      if byProject[row.projectSlug] == nil { order.append(row.projectSlug) }
      if !(byProject[row.projectSlug]?.contains(row.rawURL) ?? false) {
        byProject[row.projectSlug, default: []].append(row.rawURL)
      }
    }
    migrationTargets = order.map { ExternalMigrationTarget(project: $0, urls: byProject[$0] ?? []) }
    await prepareMigration(total: urls.count)
  }

  /// The status bar's ✕: preparing, it cancels (nothing is left); uploading,
  /// it stops after the image in hand; Ready, it discards.
  public func stopMigration() {
    if case .ready = migrationStatus {
      discardMigration()
      return
    }
    guard let migrationCancellation else { return }
    switch migrationStatus {
    case .preparing:
      migrationCancellation.cancel()
    case let .uploading(done, total, host, false):
      migrationCancellation.cancel()
      migrationStatus = .uploading(done: done, total: total, host: host, isStopping: true)
    default:
      break
    }
  }

  /// Review…: the sheet again, for the preparation not applied.
  public func reviewMigration() {
    guard case .ready = migrationStatus, migrationConfirmation != nil else { return }
    isMigrationSheetPresented = true
  }

  /// Discard: the slot goes back to Idle and the preparation's
  /// downloads are deleted. Its run stays in the panel's list; applying it
  /// later (`--from-run`) refuses `cacheInvalid`.
  public func discardMigration() {
    guard case let .ready(runID, _) = migrationStatus else { return }
    migrator?.discardPreparation(ofRun: runID)
    isMigrationSheetPresented = false
    migrationConfirmation = nil
    migrationSummary = nil
    migrationRefusal = nil
    migrationDiff = nil
    migrationAllowedSources = []
    migrationCompression = []
    migrationPreparedFailures = [:]
    migrationStatus = nil
    onMigrationProgress()
  }

  /// Cancel and Esc: the preparation stays, unapplied.
  public func dismissMigrationSheet() {
    isMigrationSheetPresented = false
    migrationDiff = nil
  }

  /// What apply is told: ticked compresses every image with its project's
  /// settings, unticked compresses none. Mixed (the projects disagree and
  /// the box was left alone) follows each project's own switch.
  /// With no box (nothing to upload) it follows the projects.
  public var migrationCompressionChoice: CompressionChoice {
    if migrationCompression.isEmpty { return .project }
    if migrationCompression.allSatisfy({ $0 }) { return .on }
    if migrationCompression.allSatisfy({ !$0 }) { return .off }
    return .project
  }

  public func setMigrationSource(_ id: String, allowed: Bool) {
    if allowed { migrationAllowedSources.insert(id) } else { migrationAllowedSources.remove(id) }
  }

  public var isMigrateEnabled: Bool {
    guard let migrationConfirmation, !isMigrationBusy else { return false }
    if migrationRefusal?.needsPreparing == true { return false }
    return migrationConfirmation.canMigrate(allowed: migrationAllowedSources)
  }

  /// Show Changes…: the nested sheet's unified diff.
  public func showMigrationChanges() async {
    guard let migrator, let runID = migrationConfirmation?.runID else { return }
    do {
      let text = try await migrator.diff(ofRun: runID)
      migrationDiff = text.isEmpty ? "No file changes." : text
    } catch {
      migrationDiff = UserFacingErrorMessage.resolve(error)
    }
  }

  public func closeMigrationChanges() {
    migrationDiff = nil
  }

  /// A stale preparation's Prepare Again: the same URLs, downloaded anew.
  public func prepareMigrationAgain() async {
    guard !migrationTargets.isEmpty, !isMigrationBusy else { return }
    let total = Set(migrationTargets.flatMap(\.urls)).count
    await prepareMigration(total: total)
  }

  /// Migrate N Links: the sheet goes and the status bar takes over; a
  /// refusal (thrown before anything is uploaded) brings the sheet back
  /// with the reason.
  public func confirmMigration() async {
    guard isMigrateEnabled, let migrator, let confirmation = migrationConfirmation else { return }
    let summary = migrationSummary
    let total = summary?.migratable.images ?? 0
    let files = summary?.files.reduce(0) { $0 + $1.files } ?? 0
    isMigrationSheetPresented = false
    migrationDiff = nil
    migrationRefusal = nil
    isMigrating = true
    migrationStatus = total > 0
      ? .uploading(done: 0, total: total, host: nil, isStopping: false) : .rewriting(files: files)
    let compression = migrationCompressionChoice
    let cancellation = ExternalMigrationCancellation()
    migrationCancellation = cancellation
    let outcome = await run { progress in
      try await migrator.apply(
        fromRun: confirmation.runID, allowedSources: self.migrationAllowedSources,
        compression: compression, cancellation: cancellation, progress: progress)
    } onProgress: { [weak self] progress in
      guard let self, case let .uploading(_, _, _, isStopping)? = self.migrationStatus else { return }
      if progress.done >= progress.total, !isStopping {
        self.migrationStatus = .rewriting(files: files)
      } else {
        self.migrationStatus = .uploading(
          done: progress.done, total: progress.total, host: progress.host, isStopping: isStopping)
      }
    }
    migrationCancellation = nil
    isMigrating = false
    switch outcome {
    case let .success(result):
      migrationConfirmation = nil
      migrationAllowedSources = []
      migrationCompression = []
      migrationStatus = .result(result)
      var failures = migrationFailures
      for url in migrationTargets.flatMap(\.urls) { failures[url] = nil }
      failures.merge(migrationPreparedFailures) { _, new in new }
      failures.merge(ExternalMigrationFailure.make(result.events)) { _, new in new }
      migrationFailures = failures
      migrationPreparedFailures = [:]
      onMigrationProgress()
      // The migrated rows leave with the rescan; the library gained assets.
      await load()
      await onMigrationFinished()
    case let .failure(error):
      if let refusal = ExternalMigrationRefusal.make(error) {
        migrationRefusal = refusal
        migrationStatus = .ready(runID: confirmation.runID, links: confirmation.links)
        isMigrationSheetPresented = true
      } else {
        migrationStatus = .done(ActivityItem(text: UserFacingErrorMessage.resolve(error), phase: .failed))
      }
    }
  }

  // MARK: - The run

  private func prepareMigration(total: Int) async {
    guard let migrator else { return }
    let targets = migrationTargets
    isMigrating = true
    isMigrationSheetPresented = false
    migrationConfirmation = nil
    migrationSummary = nil
    migrationRefusal = nil
    migrationDiff = nil
    migrationAllowedSources = []
    migrationCompression = []
    migrationStatus = .preparing(done: 0, total: total, host: nil)
    let cancellation = ExternalMigrationCancellation()
    migrationCancellation = cancellation
    let outcome = await run { progress in
      try await migrator.prepare(targets: targets, cancellation: cancellation, progress: progress)
    } onProgress: { [weak self] progress in
      guard let self, case .preparing? = self.migrationStatus else { return }
      self.migrationStatus = .preparing(done: progress.done, total: progress.total, host: progress.host)
    }
    migrationCancellation = nil
    isMigrating = false
    switch outcome {
    case let .success(preparation) where preparation.result.state == .cancelled:
      // Cancelled: the core deleted the downloads; back to Idle.
      migrationStatus = nil
      onMigrationProgress()
    case let .success(preparation):
      let confirmation = ExternalMigrationConfirmation.make(preparation)
      migrationConfirmation = confirmation
      migrationCompression = confirmation.compressionDefaults
      migrationSummary = preparation.result.summary.migration
      migrationPreparedFailures = ExternalMigrationFailure.make(preparation.result.events)
      migrationStatus = .ready(runID: confirmation.runID, links: confirmation.links)
      isMigrationSheetPresented = true
      onMigrationProgress()
    case let .failure(error):
      migrationStatus = .done(ActivityItem(text: UserFacingErrorMessage.resolve(error), phase: .failed))
    }
  }

  /// Runs `work`, handing its progress to `onProgress` on the main actor in
  /// order, and drains them all before returning.
  private func run<T: Sendable>(
    _ work: (@escaping @Sendable (ExternalMigrationProgress) -> Void) async throws -> T,
    onProgress: @escaping @MainActor (ExternalMigrationProgress) -> Void
  ) async -> Result<T, Error> {
    let (stream, continuation) = AsyncStream<ExternalMigrationProgress>.makeStream()
    let consumer = Task { @MainActor [weak self] in
      for await progress in stream {
        onProgress(progress)
        self?.onMigrationProgress()
      }
    }
    let outcome: Result<T, Error>
    do {
      outcome = .success(try await work { continuation.yield($0) })
    } catch {
      outcome = .failure(error)
    }
    continuation.finish()
    await consumer.value
    return outcome
  }

  public func migrationFailure(_ row: ExternalReference) -> ExternalMigrationFailure? {
    row.domain == .other ? migrationFailures[row.rawURL] : nil
  }
}
