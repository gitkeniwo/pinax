import Foundation

/// The time as automatic scans see it: what the watcher's quiet period and
/// the schedule are measured on. Tests drive their own.
@MainActor
public protocol ScanClock: AnyObject {
  var now: Date { get }
  /// Runs `action` once, at `date` or as soon after as the Mac is awake.
  func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> ScanClockTimer
}

@MainActor
public protocol ScanClockTimer: AnyObject {
  func cancel()
}

public final class SystemScanClock: ScanClock {
  nonisolated public init() {}

  public var now: Date { Date() }

  public func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> ScanClockTimer {
    let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
      MainActor.assumeIsolated { action() }
    }
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
    return Token(timer)
  }

  private final class Token: ScanClockTimer {
    private let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
  }
}
