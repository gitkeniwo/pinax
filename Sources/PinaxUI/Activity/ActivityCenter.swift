import Combine
import Foundation

/// Where an activity comes from. The status bar's slot keeps one entry per
/// source; the Externals migration reports as `.migration`.
public enum ActivitySource: String, CaseIterable, Sendable {
  case download, upload, deletion, scan, quickLook, externalsImport, previews, migration

  /// What the `+N` badge's tooltip calls it.
  public var name: String {
    switch self {
    case .download: return "Download"
    case .upload: return "Upload"
    case .deletion: return "Deletion"
    case .scan: return "Scan"
    case .quickLook: return "Quick Look"
    case .externalsImport: return "Import"
    case .previews: return "Previews"
    case .migration: return "Migration"
    }
  }
}

/// The text buttons a finished activity can carry.
public enum ActivityLink: Equatable, Sendable {
  case review, changedFiles, showLog

  public var title: String {
    switch self {
    case .review: return "Review…"
    case .changedFiles: return "Changed Files"
    case .showLog: return "Show Log"
    }
  }
}

/// One activity as the slot draws it: every state the slot can show.
public struct ActivityItem: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    /// A spinner, the sentence, a 110 pt bar when the fraction is known,
    /// and the grey ✕ when `cancel` names it.
    case running(fraction: Double?, cancel: String?)
    /// Green ✓ (Idle: the last result).
    case finished
    /// Blue ✓ and Review….
    case ready
    /// Red ! with Review… and Discard: a domain move whose check failed
    case needsReview
    /// Orange !.
    case warnings
    /// Red ✕ (stopped or failed).
    case failed
  }

  public var text: String
  public var phase: Phase
  /// The run this activity wrote, if any — Show Log and Changed Files open
  /// the panel on it.
  public var runID: Int64?
  /// Overrides the phase's default link (`ready` → Review…, `warnings` →
  /// Changed Files, `failed` → Show Log, each only with a run).
  public var link: ActivityLink?

  public init(text: String, phase: Phase, runID: Int64? = nil, link: ActivityLink? = nil) {
    self.text = text
    self.phase = phase
    self.runID = runID
    self.link = link
  }

  public static func running(_ text: String, fraction: Double? = nil, cancel: String? = nil) -> ActivityItem {
    ActivityItem(text: text, phase: .running(fraction: fraction, cancel: cancel))
  }

  public var isRunning: Bool {
    if case .running = phase { return true }
    return false
  }

  /// The grey ✕'s tooltip: a running activity's Cancel, or Ready's
  /// Discard; nil draws no ✕.
  public var cancelHelp: String? {
    switch phase {
    case let .running(_, cancel): return cancel
    case .ready, .needsReview: return "Discard"
    case .finished, .warnings, .failed: return nil
    }
  }

  /// The text button beside the sentence.
  public var shownLink: ActivityLink? {
    if let link { return link }
    switch phase {
    case .ready, .needsReview: return .review
    case .warnings: return runID == nil ? nil : .changedFiles
    case .failed: return runID == nil ? nil : .showLog
    case .running, .finished: return nil
    }
  }
}

/// The status bar's activity slot. Each source reports its
/// current item (or nil); the slot shows the newest-started one, counts the
/// other running ones as `+N`, and keeps a result until the next activity
/// starts.
@MainActor
public final class ActivityCenter: ObservableObject {
  struct Entry: Equatable {
    var item: ActivityItem
    /// When the activity started (a running item appearing, or a result
    /// appearing on its own), in report order.
    var stamp: Int
    /// When the result arrived; Idle's "· 2 min ago".
    var finishedAt: Date?
    /// A newer activity started after this result.
    var isDismissed = false
  }

  @Published private(set) var entries: [ActivitySource: Entry] = [:]
  private var nextStamp = 0
  private let now: () -> Date

  /// Cancel and Review…, per source.
  var handlers: [ActivitySource: (ActivityLink?) -> Void] = [:]
  /// Show Log / Changed Files: the window opens its panel on this run.
  var onPanelRequest: ((ActivityPanelRequest) -> Void)?

  public init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  /// A source's current item. A new running item (or a result with no
  /// running item before it) is a new activity: it takes the next stamp,
  /// and a running one dismisses every older result.
  public func report(_ item: ActivityItem?, from source: ActivitySource) {
    guard let item else {
      if entries[source] != nil { entries[source] = nil }
      return
    }
    let previous = entries[source]
    if let previous, previous.item == item { return }
    var entry: Entry
    switch (previous, item.isRunning) {
    case let (previous?, true) where previous.item.isRunning:
      entry = previous
      entry.item = item
    case let (previous?, false) where previous.item.isRunning:
      entry = previous
      entry.item = item
      entry.finishedAt = now()
    case (_, true):
      nextStamp += 1
      entry = Entry(item: item, stamp: nextStamp)
      for (key, other) in entries where key != source && !other.item.isRunning {
        entries[key]?.isDismissed = true
      }
    case (_, false):
      nextStamp += 1
      entry = Entry(item: item, stamp: nextStamp, finishedAt: now())
    }
    entries[source] = entry
  }

  /// Registers what Cancel (link nil) and Review… do for `source`.
  public func setHandler(for source: ActivitySource, _ handler: @escaping (ActivityLink?) -> Void) {
    handlers[source] = handler
  }

  private var visible: [(source: ActivitySource, entry: Entry)] {
    entries.filter { !$0.value.isDismissed }
      .map { (source: $0.key, entry: $0.value) }
      .sorted { $0.entry.stamp > $1.entry.stamp }
  }

  /// The newest-started visible activity.
  public var current: ActivityItem? { visible.first?.entry.item }
  public var currentSource: ActivitySource? { visible.first?.source }
  var currentFinishedAt: Date? { visible.first?.entry.finishedAt }

  /// The other activities still running: the `+N` badge and its tooltip.
  public var others: [ActivitySource] {
    visible.dropFirst().filter { $0.entry.item.isRunning }.map(\.source)
  }

  /// "+2" with "Download, Scan" on hover; nil with nothing else running.
  public var badge: (text: String, help: String)? {
    let others = others
    guard !others.isEmpty else { return nil }
    return ("+\(others.count)", others.map(\.name).joined(separator: ", "))
  }

  /// The grey ✕: Cancel, or Ready's Discard.
  public func cancelCurrent() {
    guard let source = currentSource else { return }
    handlers[source]?(nil)
  }

  /// The text button: Review… goes to the source; Show Log and Changed
  /// Files open the panel on the run.
  public func perform(_ link: ActivityLink) {
    guard let source = currentSource, let item = current else { return }
    switch link {
    case .review:
      handlers[source]?(.review)
    case .showLog, .changedFiles:
      guard let runID = item.runID else { return }
      onPanelRequest?(ActivityPanelRequest(runID: runID, showsChangedFiles: link == .changedFiles))
    }
  }

  /// Idle's age, refreshed every minute: "just now", "2 min ago",
  /// "3 hr ago", "2 days ago".
  public static func age(since date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) hr ago" }
    let days = hours / 24
    return days == 1 ? "1 day ago" : "\(days) days ago"
  }

  /// The sentence with Idle's age: a finished result says how long ago.
  public func displayText(now date: Date) -> String? {
    guard let item = current else { return nil }
    guard case .finished = item.phase, let finishedAt = currentFinishedAt else { return item.text }
    return "\(item.text) · \(Self.age(since: finishedAt, now: date))"
  }
}

/// Show Log / Changed Files: open the panel with this run selected.
public struct ActivityPanelRequest: Equatable, Sendable {
  public var runID: Int64
  public var showsChangedFiles: Bool
}
