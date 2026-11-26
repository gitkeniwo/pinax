import AppKit
import CatalogCore
import Foundation

/// Asks for scheduled scans while the app runs: once at the start, every few
/// minutes, and when the Mac wakes. A project is due a whole interval after
/// the later of its last completed scan and the last time the schedule tried
/// it, so a missed stretch is made up once and a failure waits a full
/// interval before the next try. It never wakes the Mac.
@MainActor
final class ScanScheduler {
  static let checkInterval: TimeInterval = 5 * 60

  private let clock: ScanClock
  private let wakeNotifications: NotificationCenter
  private let projects: () -> [AutoScanProject]
  private let onDue: (String, UsageAutoScanReason) -> Void
  /// In memory only: a relaunch may try again at once.
  private var lastAttempts: [String: Date] = [:]
  private var timer: ScanClockTimer?
  private var wakeObserver: NSObjectProtocol?

  init(
    clock: ScanClock, wakeNotifications: NotificationCenter,
    projects: @escaping () -> [AutoScanProject],
    onDue: @escaping (String, UsageAutoScanReason) -> Void
  ) {
    self.clock = clock
    self.wakeNotifications = wakeNotifications
    self.projects = projects
    self.onDue = onDue
  }

  func start() {
    guard wakeObserver == nil else { return }
    wakeObserver = wakeNotifications.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.check(reason: .wake) }
    }
    check(reason: .schedule)
    arm()
  }

  func stop() {
    timer?.cancel()
    timer = nil
    if let wakeObserver { wakeNotifications.removeObserver(wakeObserver) }
    wakeObserver = nil
  }

  func check(reason: UsageAutoScanReason) {
    let now = clock.now
    for project in projects() where !project.sources.isEmpty {
      guard let interval = Self.interval(project.autoScan.schedule) else { continue }
      let latest = [project.lastScanAt, lastAttempts[project.slug]].compactMap { $0 }.max()
      if let latest, now.timeIntervalSince(latest) < interval { continue }
      lastAttempts[project.slug] = now
      onDue(project.slug, reason)
    }
  }

  static func interval(_ schedule: ProjectAutoScan.Schedule) -> TimeInterval? {
    switch schedule {
    case .off: return nil
    case .hourly: return 60 * 60
    case .daily: return 24 * 60 * 60
    }
  }

  private func arm() {
    timer = clock.schedule(at: clock.now.addingTimeInterval(Self.checkInterval)) { [weak self] in
      guard let self else { return }
      self.check(reason: .schedule)
      self.arm()
    }
  }
}
