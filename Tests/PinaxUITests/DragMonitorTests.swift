import AppKit
import Foundation
import PinaxUI
import Testing

@MainActor
@Suite struct DragMonitorTests {
  @Test("An unchanged changeCount reads the pasteboard at most once per drag")
  func changeCountGate() async throws {
    let pasteboard = FakeDragPasteboard()
    let samples = SampleBox()
    let monitor = DragMonitor(
      pasteboard: pasteboard,
      onSample: { urls, _ in samples.append(urls) },
      onDragEnded: {}
    )
    monitor.baselinePasteboard()

    pasteboard.advance(dropping: [URL(fileURLWithPath: "/tmp/a.png")])
    for _ in 0..<10 {
      monitor.dragEventOccurred()
    }
    await waitUntil { samples.values.count >= 1 }

    #expect(pasteboard.readCount == 1)
    #expect(samples.values.first == [URL(fileURLWithPath: "/tmp/a.png")])

    // Drag events for the same session keep arriving: still one read.
    for _ in 0..<10 {
      monitor.dragEventOccurred()
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(pasteboard.readCount == 1)
  }

  @Test("A new drag session re-reads; a non-file drag samples empty")
  func newSessionsReread() async throws {
    let pasteboard = FakeDragPasteboard()
    let samples = SampleBox()
    let monitor = DragMonitor(
      pasteboard: pasteboard,
      onSample: { urls, _ in samples.append(urls) },
      onDragEnded: {}
    )
    monitor.baselinePasteboard()

    pasteboard.advance(dropping: [URL(fileURLWithPath: "/tmp/a.png")])
    monitor.dragEventOccurred()
    await waitUntil { samples.values.count >= 1 }

    pasteboard.advance(dropping: [])
    monitor.dragEventOccurred()
    await waitUntil { samples.values.count == 2 }
    #expect(samples.values.last?.isEmpty == true)
    #expect(pasteboard.readCount == 2)
  }

  @Test("A slow read never queues a second one behind it")
  func inFlightGuard() async throws {
    let pasteboard = FakeDragPasteboard()
    pasteboard.readDelay = 0.15
    let samples = SampleBox()
    let monitor = DragMonitor(
      pasteboard: pasteboard,
      onSample: { urls, _ in samples.append(urls) },
      onDragEnded: {}
    )
    monitor.baselinePasteboard()

    pasteboard.advance(dropping: [URL(fileURLWithPath: "/tmp/slow.png")])
    monitor.dragEventOccurred()
    try await Task.sleep(nanoseconds: 40_000_000)
    // 60 events/second arrive while the slow read is still in flight.
    for _ in 0..<5 {
      monitor.dragEventOccurred()
    }
    try await Task.sleep(nanoseconds: 40_000_000)
    #expect(pasteboard.readCount == 1)

    await waitUntil { samples.values.count >= 1 }
    // The queued events after completion see an unchanged count: no re-read.
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(pasteboard.readCount == 1)
  }

  @Test("A drag that predates the monitor never shows the zone")
  func baselineSwallowsStaleDrag() async throws {
    let pasteboard = FakeDragPasteboard()
    pasteboard.advance(dropping: [URL(fileURLWithPath: "/tmp/stale.png")])
    let samples = SampleBox()
    let monitor = DragMonitor(
      pasteboard: pasteboard,
      onSample: { urls, _ in samples.append(urls) },
      onDragEnded: {}
    )
    monitor.baselinePasteboard()

    for _ in 0..<5 {
      monitor.dragEventOccurred()
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(samples.values.isEmpty)
    #expect(pasteboard.readCount == 0)
  }

  @Test("Mouse up reports the drag as ended")
  func mouseUpEndsDrag() async throws {
    let ended = CounterBox()
    let monitor = DragMonitor(
      pasteboard: FakeDragPasteboard(),
      onSample: { _, _ in },
      onDragEnded: { ended.increment() }
    )
    monitor.mouseUpOccurred()
    #expect(ended.value == 1)
  }

  @Test("Within one drag session every event re-samples the flags without a new pasteboard read")
  func sameSessionFlagsResampling() async throws {
    let pasteboard = FakeDragPasteboard()
    let samples = FlaggedSampleBox()
    let monitor = DragMonitor(
      pasteboard: pasteboard,
      onSample: { samples.append(($0, $1)) },
      onDragEnded: {}
    )
    monitor.baselinePasteboard()
    pasteboard.advance(dropping: [URL(fileURLWithPath: "/tmp/a.png")])

    monitor.dragEventOccurred(flags: [])
    await waitUntil { samples.values.count >= 1 }

    // Same session, pasteboard untouched: each event samples with the flags
    // held *now* (a mid-drag modifier press must reach the model), and none of them reads the pasteboard again. Real drag events
    // arrive ~16 ms apart, which is what lets each detached gate check finish
    // before the next; the sleeps reproduce that cadence instead of firing
    // events back-to-back into the in-flight guard.
    monitor.dragEventOccurred(flags: .option)
    try await Task.sleep(nanoseconds: 40_000_000)
    monitor.dragEventOccurred(flags: .option)
    try await Task.sleep(nanoseconds: 40_000_000)
    monitor.dragEventOccurred(flags: [])
    await waitUntil { samples.values.count >= 4 }
    let flagHistory = samples.values.map { $0.1 }
    #expect(flagHistory.suffix(3) == [.option, .option, []])
    #expect(samples.values.allSatisfy { $0.0 == [URL(fileURLWithPath: "/tmp/a.png")] })
    #expect(pasteboard.readCount == 1)

    // The session ends; a later mouse drag with an untouched pasteboard must
    // not resurrect this session's sample.
    monitor.mouseUpOccurred()
    monitor.dragEventOccurred(flags: .option)
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(samples.values.count == 4)
    #expect(pasteboard.readCount == 1)
  }

  /// No pasteboard access on the main thread is a property of *threads*, not call counts: both the
  /// gate (`changeCount`) and the read (`fileURLs`) are XPC round trips, and
  /// either one on the main thread during a drag can freeze the app for
  /// 30 seconds. The only sanctioned main-thread pasteboard access is the
  /// one-time baseline at startup.
  @Test("The pasteboard gate itself runs off the main thread")
  func gateRunsOffMainThread() async throws {
    let pasteboard = FakeDragPasteboard()
    let samples = SampleBox()
    let monitor = DragMonitor(
      pasteboard: pasteboard,
      onSample: { urls, _ in samples.append(urls) },
      onDragEnded: {}
    )
    monitor.baselinePasteboard()

    pasteboard.advance(dropping: [URL(fileURLWithPath: "/tmp/a.png")])
    for _ in 0..<10 {
      monitor.dragEventOccurred()
    }
    await waitUntil { samples.values.count >= 1 }
    // Let any trailing bail-out tasks finish before tallying threads.
    try await Task.sleep(nanoseconds: 100_000_000)

    let tally = pasteboard.threadTally()
    #expect(tally.changeCountMain == 1)
    #expect(tally.changeCountBackground >= 1)
    #expect(tally.fileURLsMain == 0)
    #expect(tally.fileURLsBackground >= 1)
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<200 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

private final class FakeDragPasteboard: DragPasteboardReading, @unchecked Sendable {
  struct ThreadTally {
    let changeCountMain: Int
    let changeCountBackground: Int
    let fileURLsMain: Int
    let fileURLsBackground: Int
  }

  private let lock = NSLock()
  private var count = 0
  private var urls: [URL] = []
  private var delay: TimeInterval = 0
  private var fileURLsReads = 0
  private var changeCountMain = 0
  private var changeCountBackground = 0
  private var fileURLsMain = 0
  private var fileURLsBackground = 0

  var readCount: Int {
    lock.withLock { fileURLsReads }
  }

  var changeCount: Int {
    lock.withLock {
      if Thread.isMainThread {
        changeCountMain += 1
      } else {
        changeCountBackground += 1
      }
      return count
    }
  }

  var readDelay: TimeInterval {
    get { lock.withLock { delay } }
    set { lock.withLock { delay = newValue } }
  }

  func advance(dropping urls: [URL]) {
    lock.withLock {
      count += 1
      self.urls = urls
    }
  }

  func fileURLs() -> [URL] {
    let captured = lock.withLock { () -> ([URL], TimeInterval) in
      if Thread.isMainThread {
        fileURLsMain += 1
      } else {
        fileURLsBackground += 1
      }
      fileURLsReads += 1
      return (urls, delay)
    }
    if captured.1 > 0 {
      Thread.sleep(forTimeInterval: captured.1)
    }
    return captured.0
  }

  func threadTally() -> ThreadTally {
    lock.withLock {
      ThreadTally(
        changeCountMain: changeCountMain,
        changeCountBackground: changeCountBackground,
        fileURLsMain: fileURLsMain,
        fileURLsBackground: fileURLsBackground
      )
    }
  }
}

private final class SampleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var backing: [[URL]] = []

  var values: [[URL]] {
    lock.withLock { backing }
  }

  func append(_ value: [URL]) {
    lock.withLock { backing.append(value) }
  }
}

private final class FlaggedSampleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var backing: [([URL], NSEvent.ModifierFlags)] = []

  var values: [([URL], NSEvent.ModifierFlags)] {
    lock.withLock { backing }
  }

  func append(_ value: ([URL], NSEvent.ModifierFlags)) {
    lock.withLock { backing.append(value) }
  }
}

private final class CounterBox: @unchecked Sendable {
  private let lock = NSLock()
  private var backing = 0

  var value: Int {
    lock.withLock { backing }
  }

  func increment() {
    lock.withLock { backing += 1 }
  }
}
