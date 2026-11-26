import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// A clock that moves only when a test moves it.
@MainActor
final class ManualScanClock: ScanClock {
  private final class Pending: ScanClockTimer {
    let date: Date
    var action: (@MainActor () -> Void)?
    init(date: Date, action: @escaping @MainActor () -> Void) {
      self.date = date
      self.action = action
    }
    func cancel() { action = nil }
  }

  private(set) var now: Date
  private var pending: [Pending] = []

  init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
    self.now = now
  }

  func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> ScanClockTimer {
    let timer = Pending(date: date, action: action)
    pending.append(timer)
    return timer
  }

  /// Passes the time, running each timer at its own moment.
  func advance(by interval: TimeInterval) {
    let end = now.addingTimeInterval(interval)
    while true {
      pending.removeAll { $0.action == nil }
      guard
        let next = pending.filter({ $0.date <= end }).min(by: { $0.date < $1.date })
      else { break }
      now = max(now, next.date)
      let action = next.action
      next.action = nil
      action?()
    }
    now = end
  }

  /// The Mac asleep: time passes and no timer runs.
  func sleep(for interval: TimeInterval) {
    now = now.addingTimeInterval(interval)
  }
}

/// A command runner that runs nothing and counts what it was asked.
final class CountingCommandRunner: CommandSourceRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [CommandSourceRequest] = []
  private var _failure: CommandSourceError?

  var requests: [CommandSourceRequest] { lock.withLock { _requests } }
  var failure: CommandSourceError? {
    get { lock.withLock { _failure } }
    set { lock.withLock { _failure = newValue } }
  }

  func run(_ request: CommandSourceRequest) throws -> Data {
    lock.withLock { _requests.append(request) }
    if let failure { throw failure }
    return Data(
      #"{"schema":1,"refs":[{"raw_url":"https://img.example.com/blog/asset-0.png","source_ref":"posts/a"}]}"#
        .utf8)
  }
}

/// Records every scan; while `holds` is on, each waits to be released.
final class GatedSynchronizer: UsageSyncing, @unchecked Sendable {
  private let lock = NSLock()
  private var _scans: [String] = []
  private var _allowEmpty: [Bool] = []
  private var _released = 0
  private var _holds = true
  private var _error: (any Error)?

  var scans: [String] { lock.withLock { _scans } }
  var allowEmpty: [Bool] { lock.withLock { _allowEmpty } }
  var holds: Bool {
    get { lock.withLock { _holds } }
    set { lock.withLock { _holds = newValue } }
  }
  var error: (any Error)? {
    get { lock.withLock { _error } }
    set { lock.withLock { _error = newValue } }
  }

  /// Lets the oldest held scan finish.
  func release() { lock.withLock { _released += 1 } }

  func projects() async throws -> [String] { ["blog", "notes"] }

  func sync(documentAt source: URL, project: String, allowEmpty: Bool) async throws
    -> UsageSyncResult
  {
    UsageSyncResult(scanID: 0, foundCount: 0)
  }

  func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome {
    let turn = lock.withLock {
      _scans.append(project)
      _allowEmpty.append(allowEmpty)
      return _scans.count
    }
    while lock.withLock({ _holds && _released < turn }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    if let error { throw error }
    return UsageScanOutcome(
      sync: UsageSyncResult(scanID: Int64(turn), foundCount: 3), files: 1, skipped: 0)
  }
}

/// Defaults of the test's own; `remove` leaves nothing behind.
func makeScanDefaults() throws -> (defaults: UserDefaults, remove: () -> Void) {
  let suite = "pinaxui-auto-scan-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  return (defaults, { UserDefaults.standard.removePersistentDomain(forName: suite) })
}

/// Waits for something another task or the system will bring about.
@MainActor
func eventually(
  _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
) async {
  let deadline = Date().addingTimeInterval(15)
  while !condition(), Date() < deadline {
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  #expect(condition(), "timed out", sourceLocation: sourceLocation)
}
