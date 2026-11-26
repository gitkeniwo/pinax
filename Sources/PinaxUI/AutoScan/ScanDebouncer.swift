import Foundation

/// Turns a burst of changes into one firing: after a quiet period, or, while
/// changes keep coming, a longest wait after the first of them.
@MainActor
final class ScanDebouncer {
  static let quietPeriod: TimeInterval = 3
  static let longestWait: TimeInterval = 30

  private let clock: ScanClock
  private let fire: () -> Void
  private var firstChange: Date?
  private var timer: ScanClockTimer?

  init(clock: ScanClock, fire: @escaping () -> Void) {
    self.clock = clock
    self.fire = fire
  }

  var isPending: Bool { firstChange != nil }

  func noteChange() {
    let now = clock.now
    let first = firstChange ?? now
    firstChange = first
    let deadline = min(
      now.addingTimeInterval(Self.quietPeriod), first.addingTimeInterval(Self.longestWait))
    timer?.cancel()
    timer = clock.schedule(at: deadline) { [weak self] in
      guard let self else { return }
      self.cancel()
      self.fire()
    }
  }

  func cancel() {
    timer?.cancel()
    timer = nil
    firstChange = nil
  }
}
