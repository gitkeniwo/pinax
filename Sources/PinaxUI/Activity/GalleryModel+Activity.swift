import Combine
import Foundation

/// Every background activity the status bar used to
/// show side by side reports into the one slot. The sentences are the
/// sources' own, unchanged; only the arrangement moved.
///
/// `@Published` publishers emit the new value before the property is set,
/// so each source combines its own publishers instead of reading the
/// model back.
extension GalleryModel {
  func wireActivity() {
    let center = activity
    func feed<P: Publisher>(_ source: ActivitySource, _ publisher: P)
    where P.Output == ActivityItem?, P.Failure == Never {
      publisher.sink { [weak center] item in
        MainActor.assumeIsolated { center?.report(item, from: source) }
      }
      .store(in: &activityWiring)
    }

    feed(.download, $downloadProgress.combineLatest($downloadError).map(Self.downloadItem))
    feed(.upload, $uploadProgress.map { $0.map { ActivityItem.running($0) } })
    feed(
      .deletion,
      $deletionProgress.combineLatest($deletionNotice, $deletionError).map(Self.deletionItem))
    feed(.scan, $usageScanActivity.map { $0.map(Self.scanItem) })
    feed(.quickLook, $quickLookErrorMessage.map { $0.map { ActivityItem(text: $0, phase: .failed) } })
    feed(
      .externalsImport,
      externals.$importActivity.combineLatest(externals.$importError).map(Self.importItem))
    feed(.previews, externals.$previewActivity.map { $0.map(Self.previewItem) })
    // Externals' migration and the domain move
    // share the slot (and the lock); the newer of the two shows.
    if let domain = domainMigration {
      let merged = Publishers.Merge(
        externals.$migrationStatus.map { MigrationSlot.Change.externals($0?.item) },
        domain.$status.map { MigrationSlot.Change.domain($0?.item) }
      )
      .scan(MigrationSlot()) { slot, change in slot.applying(change) }
      merged.sink { [weak self] slot in
        MainActor.assumeIsolated { self?.migrationSlot = slot }
      }
      .store(in: &activityWiring)
      feed(.migration, merged.map(\.item))
    } else {
      feed(.migration, externals.$migrationStatus.map { $0?.item })
    }

    center.setHandler(for: .externalsImport) { [weak self] link in
      if link == nil { self?.externals.stopImport() }
    }
    center.setHandler(for: .previews) { [weak self] link in
      if link == nil { self?.externals.stopPreviews() }
    }
    // ✕ cancels the preparation or stops the upload; Review… reopens
    // the sheet.
    center.setHandler(for: .migration) { [weak self] link in
      guard let self else { return }
      if self.migrationSlot.showsDomain, let domain = self.domainMigration {
        switch link {
        case nil: domain.stopOrDiscard()
        case .review?: domain.reviewAgain()
        default: break
        }
        return
      }
      switch link {
      case nil: self.externals.stopMigration()
      case .review?: self.externals.reviewMigration()
      default: break
      }
    }
    center.onPanelRequest = { [weak self] request in
      self?.activityPanel.show(request)
      self?.isActivityPanelOpen = true
    }
  }

  /// The domain move's hooks into the gallery: Usage on the chosen domain, the
  /// backends read fresh, and every
  /// reader after an apply.
  func wireDomainMigration() {
    guard let domain = domainMigration else { return }
    domain.backends = { [weak self] in
      guard let self else { return [] }
      await self.refreshDomainBackends()
      return self.domainBackends
    }
    domain.onShowUsage = { [weak self] prefix in
      guard let self else { return }
      self.usageDomain = prefix
      self.select(.usage, in: .reports)
    }
    domain.onProgress = { [weak self] in
      guard let panel = self?.activityPanel else { return }
      Task { await panel.refresh() }
    }
    domain.onShowLog = { [weak self] runID in
      self?.activityPanel.show(ActivityPanelRequest(runID: runID, showsChangedFiles: false))
      self?.isActivityPanelOpen = true
    }
    domain.onFinished = { [weak self] in
      guard let self else { return }
      await self.refreshDomainBackends()
      await self.reloadAfterUsageScan()
      await self.onDomainsChanged?()
    }
  }

  public func toggleActivityPanel() {
    isActivityPanelOpen.toggle()
  }

  nonisolated static func downloadItem(progress: String?, error: String?) -> ActivityItem? {
    if let progress { return .running(progress) }
    return error.map { ActivityItem(text: $0, phase: .failed) }
  }

  nonisolated static func deletionItem(progress: String?, notice: String?, error: String?) -> ActivityItem? {
    if let progress { return .running(progress) }
    if let notice { return ActivityItem(text: notice, phase: .finished) }
    return error.map { ActivityItem(text: $0, phase: .failed) }
  }

  nonisolated static func scanItem(_ activity: UsageScanActivity) -> ActivityItem {
    switch activity {
    case .running: return .running(activity.text)
    case .finished: return ActivityItem(text: activity.text, phase: .finished)
    case .failed: return ActivityItem(text: activity.text, phase: .failed)
    case .commandNeedsApproval, .emptyScanHeld:
      return ActivityItem(text: activity.text, phase: .warnings)
    case let .summary(_, failures):
      return ActivityItem(text: activity.text, phase: failures.isEmpty ? .finished : .warnings)
    }
  }

  nonisolated static func importItem(activity: ExternalImportActivity?, error: String?) -> ActivityItem? {
    if let activity {
      return .running(
        activity.text, fraction: activity.fraction, cancel: activity.isStopping ? nil : "Stop Importing")
    }
    return error.map { ActivityItem(text: $0, phase: .failed) }
  }

  nonisolated static func previewItem(_ activity: ExternalPreviewActivity) -> ActivityItem {
    if activity.isFinished { return ActivityItem(text: activity.text, phase: .finished) }
    return .running(activity.text, fraction: activity.fraction, cancel: activity.isStopping ? nil : "Stop loading")
  }
}

/// The `.migration` slot's two sources: whichever reported last shows,
/// falling back to the other while the last one has nothing.
struct MigrationSlot: Equatable {
  enum Change {
    case externals(ActivityItem?)
    case domain(ActivityItem?)
  }

  var externals: ActivityItem?
  var domain: ActivityItem?
  var domainIsNewer = false

  func applying(_ change: Change) -> MigrationSlot {
    var slot = self
    switch change {
    case let .externals(item):
      if item != nil, item != externals { slot.domainIsNewer = false }
      slot.externals = item
    case let .domain(item):
      if item != nil, item != domain { slot.domainIsNewer = true }
      slot.domain = item
    }
    return slot
  }

  var showsDomain: Bool { domain != nil && (domainIsNewer || externals == nil) }
  var item: ActivityItem? { showsDomain ? domain : externals }
}
