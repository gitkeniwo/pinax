import CatalogCore
import Foundation

/// Import into Catalog on Your Domains — the
/// menu item, Import All…, the sheet, the batch in the status bar, and what
/// the rows say afterwards. The claim itself is the core's `ExternalsClaim`.
extension ExternalsModel {
  /// A writable gallery has a claimer; a read-only one offers no import.
  public var canImport: Bool { claimer != nil }

  /// The scope's Your Domains rows, whichever half is shown.
  var yourDomainsRows: [ExternalReference] {
    items?.filter { $0.domain == .yours } ?? []
  }

  /// Import All…'s count: the scope's distinct Your Domains URLs — after a
  /// cancel, the ones still here.
  public var importAllCount: Int {
    ExternalsImportFacts.distinctURLs(yourDomainsRows).count
  }

  /// On the header in Your Domains only.
  public var showsImportAll: Bool { canImport && domain == .yours }

  /// Greyed with nothing to import, and while a batch runs.
  public var isImportAllEnabled: Bool {
    showsImportAll && importAllCount > 0 && !isImporting
  }

  public func requestImportAll() async {
    guard isImportAllEnabled else { return }
    await present(rows: yourDomainsRows, importAll: true)
  }

  /// The menu's Import into Catalog: one image goes at once; more
  /// ask first.
  public func requestImport(urls: [String]) async {
    guard canImport, !isImporting, importSheet == nil else { return }
    let wanted = Set(urls)
    let rows = yourDomainsRows.filter { wanted.contains($0.rawURL) }
    let distinct = ExternalsImportFacts.distinctURLs(rows)
    guard !distinct.isEmpty else { return }
    if distinct.count == 1 {
      guard let preparation = await prepare(rows) else { return }
      await run(
        rows: rows, preparation: preparation, urls: distinct,
        label: .image(ExternalsView.filename(rows[0])),
        host: ExternalsImportFacts.hosts(rows), requested: 1, viaSheet: false)
    } else {
      await present(rows: rows, importAll: false)
    }
  }

  /// The sheet's Import: the sheet stays, checking, until the first image's
  /// GET starts — or the CDN check refuses.
  public func confirmImport() async {
    guard case let .confirm(confirmation, checking: false)? = importSheet,
      let pending = importPending
    else { return }
    importPending = nil
    importSheet = .confirm(confirmation, checking: true)
    await run(
      rows: pending.rows, preparation: pending.preparation, urls: confirmation.urls,
      label: .host(confirmation.host), host: confirmation.host,
      requested: confirmation.imageCount, viaSheet: true)
  }

  /// The sheet's Cancel, before Import.
  public func cancelImportSheet() {
    if case .confirm(_, checking: true)? = importSheet { return }
    importSheet = nil
    importPending = nil
  }

  /// The status bar's stop button: what is committed stays.
  public func stopImport() {
    guard isImporting, let importCancellation else { return }
    importCancellation.cancel()
    if let activity = importActivity {
      importActivity = ExternalImportActivity(
        text: activity.text, completed: activity.completed, total: activity.total,
        isStopping: true)
    }
  }

  public func dismissImportSummary() {
    importSummary = nil
  }

  public func showImportedInUsage() {
    onShowInUsage()
  }

  /// A same-image row's inspector: the image already in the catalog.
  public func showInLibrary(key: String) async {
    await onShowInLibrary(key)
  }

  public func importCellState(_ row: ExternalReference) -> ExternalImportCellState? {
    row.domain == .yours ? importCellStates[row.rawURL] : nil
  }

  public func importFailure(_ row: ExternalReference) -> ExternalImportFailure? {
    row.domain == .yours ? importFailures[row.rawURL] : nil
  }

  // MARK: - The run

  private func prepare(_ rows: [ExternalReference]) async -> ExternalImportPreparation? {
    guard let claimer else { return nil }
    do {
      return try await claimer.prepare(rows)
    } catch {
      importError = UserFacingErrorMessage.resolve(error)
      return nil
    }
  }

  private func present(rows: [ExternalReference], importAll: Bool) async {
    guard !isImporting, importSheet == nil, let preparation = await prepare(rows) else { return }
    importPending = (rows, preparation)
    importSheet = .confirm(
      ExternalImportConfirmation.make(rows: rows, importAll: importAll, preparation: preparation),
      checking: false)
  }

  private func run(
    rows: [ExternalReference], preparation: ExternalImportPreparation, urls: [String]?,
    label: ExternalImportLabel, host: String, requested: Int, viaSheet: Bool
  ) async {
    guard let claimer else { return }
    importRun += 1
    let run = importRun
    isImporting = true
    importError = nil
    importSummary = nil
    let batch = ExternalsImportFacts.distinctURLs(rows)
    // The URL each GET asks for → the rows it imports.
    var cells: [String: [String]] = [:]
    for url in batch {
      if let fetch = preparation.fetchURLs[url] { cells[fetch, default: []].append(url) }
    }
    if !viaSheet {
      importActivity = .make(label: label, completed: 0, total: requested)
    }
    let cancellation = ExternalsClaimCancellation()
    importCancellation = cancellation
    // One ordered stream, drained before the result is read: a GET's start
    // never lands after its end, and none lands after the batch.
    let (events, continuation) = AsyncStream<ExternalImportEvent>.makeStream()
    let consumer = Task { @MainActor [weak self, cells] in
      for await event in events {
        self?.handle(event, run: run, cells: cells, label: label, requested: requested)
      }
    }
    let outcome: Result<ExternalsClaimResult, Error>
    do {
      outcome = .success(
        try await claimer.claim(
          project: selectedProjectSlug, urls: urls, cancellation: cancellation,
          events: { continuation.yield($0) }))
    } catch {
      outcome = .failure(error)
    }
    continuation.finish()
    await consumer.value
    importCancellation = nil

    switch outcome {
    case let .failure(error):
      importError = UserFacingErrorMessage.resolve(error)
      importSheet = nil
      await endBatch()
    case let .success(result) where result.refused:
      // The batch was refused before any claim; nothing was written.
      importSheet = .refused(ExternalImportRefusal.make(result.cdnCheck, host: host))
      await endBatch()
    case let .success(result):
      var failures = importFailures
      var batchFailures: [ExternalImportFailure] = []
      for url in batch {
        failures[url] = nil
        let fetch = preparation.fetchURLs[url]
        guard let row = rows.first(where: { $0.rawURL == url }),
          let skip = result.skipped.first(where: { $0.url == url || $0.url == fetch })
        else { continue }
        let failure = ExternalImportFailure.make(skip, row: row)
        failures[url] = failure
        batchFailures.append(failure)
      }
      importFailures = failures
      importSummary = ExternalImportSummary.make(
        imported: result.claimed.count, requested: requested, failures: batchFailures,
        cancelled: result.cancelled)
      if case .confirm? = importSheet { importSheet = nil }
      await endBatch()
    }
  }

  /// The batch's rows leave in one step — the reload and the marks'
  /// clearing land together — then the gallery reads the catalog again.
  private func endBatch() async {
    importActivity = nil
    isImporting = false
    reloadAfterImport = false
    importRun += 1
    await load()
    importCellStates = [:]
    await onImportFinished()
  }

  private func handle(
    _ event: ExternalImportEvent, run: Int, cells: [String: [String]],
    label: ExternalImportLabel, requested: Int
  ) {
    guard run == importRun, isImporting else { return }
    switch event {
    case let .started(url):
      // A CDN sample's GET marks nothing.
      guard let rows = cells[url] else { return }
      beginRunning(label: label, requested: requested)
      for row in rows where importCellStates[row] == nil {
        importCellStates[row] = .importing
      }
    case let .finished(url, succeeded):
      guard let rows = cells[url] else { return }
      for row in rows {
        importCellStates[row] = succeeded ? .imported : nil
      }
    case let .progress(progress):
      beginRunning(label: label, requested: requested)
      importActivity = .make(
        label: label, completed: progress.completed, total: progress.total,
        isStopping: importActivity?.isStopping ?? false)
    }
  }

  /// The CDN check passed: the sheet goes, the status bar takes over.
  private func beginRunning(label: ExternalImportLabel, requested: Int) {
    if case .confirm(_, checking: true)? = importSheet { importSheet = nil }
    if importActivity == nil {
      importActivity = .make(label: label, completed: 0, total: requested)
    }
  }
}
