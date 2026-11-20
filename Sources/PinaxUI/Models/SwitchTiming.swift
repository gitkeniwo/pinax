import Foundation

#if DEBUG || PINAX_SWITCH_TIMING
import os
#endif

/// How long a sidebar switch takes, phase by phase —
/// from the selection changing to the first screen of thumbnails in place.
///
/// Compiled only into DEBUG builds or a build passing
/// `-DPINAX_SWITCH_TIMING`; everywhere else every call is an empty inline
/// function and `timed` is the body itself. Even where compiled it records
/// nothing unless the process was launched with `PINAX_SWITCH_TIMING=1`.
/// One line per switch goes to the unified log, subsystem `app.pinax`,
/// category `switch-timing`.
enum SwitchTiming {
  #if DEBUG || PINAX_SWITCH_TIMING
  static let isEnabled = ProcessInfo.processInfo.environment["PINAX_SWITCH_TIMING"] == "1"
  private static let log = Logger(subsystem: "app.pinax", category: "switch-timing")
  private static let lock = NSLock()
  nonisolated(unsafe) private static var clickedAt: UInt64?
  nonisolated(unsafe) private static var record: Record?
  nonisolated(unsafe) private static var nextID = 0

  private final class Record {
    let id: Int
    let label: String
    let start: UInt64
    let clickLag: Double?
    var marks: [(String, Double)] = []
    var durations: [(String, Double)] = []
    var committedAt: UInt64?
    var started = 0
    var finished = 0
    var logged = false

    init(id: Int, label: String, start: UInt64, clickLag: Double?) {
      self.id = id
      self.label = label
      self.start = start
      self.clickLag = clickLag
    }
  }

  private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  private static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to &- from) / 1e6 }
  #endif

  /// The selection moved (the sidebar's List, the jump bar, a menu).
  @inline(__always) static func selectionChanged() {
    #if DEBUG || PINAX_SWITCH_TIMING
    guard isEnabled else { return }
    lock.withLock { clickedAt = now() }
    #endif
  }

  /// An asset reload starts; a record still open is logged as superseded.
  @inline(__always) static func begin(_ label: @autoclosure () -> String) {
    #if DEBUG || PINAX_SWITCH_TIMING
    guard isEnabled else { return }
    let text = label()
    lock.withLock {
      if let open = record { flush(open, reason: "superseded") }
      let start = now()
      let lag = clickedAt.map { ms($0, start) }
      clickedAt = nil
      nextID += 1
      record = Record(id: nextID, label: text, start: start, clickLag: lag)
    }
    #endif
  }

  /// A point in the current reload, in ms since `begin`.
  @inline(__always) static func mark(_ phase: StaticString) {
    #if DEBUG || PINAX_SWITCH_TIMING
    guard isEnabled else { return }
    lock.withLock {
      guard let open = record else { return }
      open.marks.append(("\(phase)", ms(open.start, now())))
    }
    #endif
  }

  /// The rows reached the published state: from here the cells that start
  /// loading a thumbnail are the first screen.
  @inline(__always) static func committed() {
    #if DEBUG || PINAX_SWITCH_TIMING
    guard isEnabled else { return }
    lock.withLock {
      guard let open = record else { return }
      let at = now()
      open.committedAt = at
      open.marks.append(("commit", ms(open.start, at)))
    }
    #endif
  }

  /// One query's own duration, wherever it ran.
  @inline(__always) static func timed<T>(
    _ phase: StaticString, _ body: () async throws -> T
  ) async rethrows -> T {
    #if DEBUG || PINAX_SWITCH_TIMING
    guard isEnabled else { return try await body() }
    let began = now()
    defer {
      let took = ms(began, now())
      lock.withLock { record?.durations.append(("\(phase)", took)) }
    }
    #endif
    return try await body()
  }

  /// A cell's thumbnail task started; returns the record it counts toward.
  @inline(__always) static func thumbnailStarted() -> Int? {
    #if DEBUG || PINAX_SWITCH_TIMING
    guard isEnabled else { return nil }
    return lock.withLock {
      guard let open = record, open.committedAt != nil, !open.logged else { return nil }
      open.started += 1
      return open.id
    }
    #else
    return nil
    #endif
  }

  /// That task ended (cached, loaded, failed or cancelled). When the last
  /// first-screen cell is done, the switch's line is logged.
  @inline(__always) static func thumbnailFinished(_ token: Int?) {
    #if DEBUG || PINAX_SWITCH_TIMING
    guard isEnabled, let token else { return }
    lock.withLock {
      guard let open = record, open.id == token, !open.logged else { return }
      open.finished += 1
      if open.finished == open.started {
        open.marks.append(("thumbs", ms(open.start, now())))
        flush(open, reason: nil)
      }
    }
    #endif
  }

  /// A reload that publishes no cells (an empty view, an error) ends here.
  @inline(__always) static func endWithoutCells() {
    #if DEBUG || PINAX_SWITCH_TIMING
    guard isEnabled else { return }
    lock.withLock {
      guard let open = record, open.started == 0 else { return }
      flush(open, reason: "no cells")
    }
    #endif
  }

  #if DEBUG || PINAX_SWITCH_TIMING
  private static func flush(_ open: Record, reason: String?) {
    guard !open.logged else { return }
    open.logged = true
    if record === open { record = nil }
    func list(_ items: [(String, Double)]) -> String {
      items.map { "\($0.0)=\(String(format: "%.1f", $0.1))" }.joined(separator: " ")
    }
    let lag = open.clickLag.map { String(format: "%.1f", $0) } ?? "-"
    let line =
      "#\(open.id) \(open.label) clickLag=\(lag) | at: \(list(open.marks)) | took: \(list(open.durations)) | cells=\(open.started)"
      + (reason.map { " [\($0)]" } ?? "")
    log.notice("\(line, privacy: .public)")
  }
  #endif
}
