import Foundation
import GRDB

/// The watcher and the schedule over one catalog. Both only ask for scans;
/// `UsageSyncModel` runs them.
@MainActor
final class AutoScanEngine {
  private(set) var watcher: SourceWatcher!
  private var scheduler: ScanScheduler!
  private let database: DatabasePool

  init(
    database: DatabasePool, usageSync: UsageSyncModel, clock: ScanClock,
    wakeNotifications: NotificationCenter
  ) {
    self.database = database
    watcher = SourceWatcher(
      clock: clock,
      onChange: { [weak usageSync] project in
        Task { await usageSync?.scanAutomatically(project: project, reason: .watch) }
      },
      onMissing: { [weak usageSync] project, error in
        usageSync?.reportAutomaticFailure(project: project, message: error.description)
      })
    scheduler = ScanScheduler(
      clock: clock, wakeNotifications: wakeNotifications,
      // Each check also reads what changed outside the app, and watches a
      // folder that has come back.
      projects: { [weak self] in self?.reload() ?? [] },
      onDue: { [weak usageSync] project, reason in
        Task { await usageSync?.scanAutomatically(project: project, reason: reason) }
      })
  }

  func start() {
    scheduler.start()
  }

  /// Reads the projects again and rebuilds what is watched. A catalog that
  /// cannot be read leaves the watches as they are.
  @discardableResult
  func reload() -> [AutoScanProject] {
    guard let projects = try? AutoScanProject.load(from: database) else { return [] }
    watcher.update(projects)
    return projects
  }
}
