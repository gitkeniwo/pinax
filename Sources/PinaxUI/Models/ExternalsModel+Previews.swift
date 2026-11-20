import CatalogCore
import Foundation

/// The status bar's preview batch: "Loading
/// previews 12 of 32 · host" while it runs, "Loaded N previews" after.
public struct ExternalPreviewActivity: Equatable, Sendable {
  public internal(set) var completed = 0
  public internal(set) var total = 0
  /// Of `completed`, the ones that came back as images.
  public internal(set) var loaded = 0
  /// The host of the URL started last.
  public internal(set) var host: String?
  public internal(set) var isStopping = false
  public internal(set) var isFinished = false

  public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

  public var text: String {
    if isFinished { return "Loaded \(PinaxFormat.count(loaded, singular: "preview"))" }
    let progress = "Loading previews \(completed.formatted()) of \(total.formatted())"
    return host.map { "\(progress) · \($0)" } ?? progress
  }
}

/// The Other Domains capsule: "N of M previews loaded" with Load
/// All, or "All M previews loaded" alone.
public struct ExternalPreviewCapsule: Equatable, Sendable {
  public let loaded: Int
  public let total: Int
  /// URLs a Load All would ask for: not loaded, not on their way.
  public let loadable: Int

  public var text: String {
    loaded == total
      ? "All \(PinaxFormat.count(total, singular: "preview")) loaded"
      : "\(loaded.formatted()) of \(total.formatted()) previews loaded"
  }

  public var showsLoadAll: Bool { loaded < total && loadable > 0 }
}

/// A group header's preview control, shown on hover.
public enum ExternalGroupPreview: Equatable, Sendable {
  case none
  /// Load N: the group's URLs a Load would ask for.
  case load(Int)
  /// ✓ Previews: every URL in the group is loaded.
  case loaded
}

/// Several selected rows, for the inspector and the status bar.
public struct ExternalSelectionSummary: Equatable, Sendable {
  public struct Host: Equatable, Sendable, Identifiable {
    public let host: String
    public let refs: Int
    public var id: String { host }
  }

  /// The rows, in the page's order.
  public let rows: [ExternalReference]
  /// The first row of each distinct URL.
  public let images: [ExternalReference]
  /// Each host with its rows, in order of first appearance.
  public let hosts: [Host]
  /// Distinct referencing files.
  public let files: Int

  /// "2 hosts · 3 files".
  public var facts: String {
    "\(PinaxFormat.count(hosts.count, singular: "host")) · \(PinaxFormat.count(files, singular: "file"))"
  }
}

extension ExternalsModel {
  /// At most this many previews are on their way at once.
  public static let previewConcurrency = 4

  // MARK: - Bulk previews

  /// The Other Domains rows among `rows` a Load would ask for: a URL each,
  /// one a browser can open, not loaded, not on its way, not queued; a
  /// failure may be asked again.
  func previewCandidates(_ rows: [ExternalReference]) -> [ExternalReference] {
    guard thumbnails != nil else { return [] }
    var seen = Set(previewQueue.map(\.rawURL))
    return rows.filter { row in
      guard row.domain == .other, Self.webURL(row) != nil, seen.insert(row.rawURL).inserted
      else { return false }
      switch thumbnailStates[row.rawURL] {
      case nil, .failed: return true
      case .loading, .loaded: return false
      }
    }
  }

  /// Load All, Load N, Load Previews: each distinct Other Domains URL
  /// through the one-row pipeline (`loadPreview`'s), `previewConcurrency`
  /// at a time. Only this, and the one-row button, ever ask another host.
  public func loadPreviews(_ rows: [ExternalReference]) {
    let fresh = previewCandidates(rows)
    guard !fresh.isEmpty else { return }
    if var activity = previewActivity, !activity.isFinished {
      activity.total += fresh.count
      previewActivity = activity
    } else {
      previewActivity = ExternalPreviewActivity(total: fresh.count)
    }
    previewQueue += fresh
    pumpPreviews()
  }

  /// Stop: the queued URLs are dropped; the ones already asked finish.
  public func stopPreviews() {
    guard var activity = previewActivity, !activity.isFinished else { return }
    activity.total -= previewQueue.count
    activity.isStopping = true
    previewQueue = []
    previewActivity = activity
    finishPreviewsIfDone()
  }

  private func pumpPreviews() {
    while previewInFlight < Self.previewConcurrency, !previewQueue.isEmpty {
      let row = previewQueue.removeFirst()
      let started = load(row, allowingOther: true) { [weak self] loaded in
        self?.previewFinished(loaded: loaded)
      }
      if started {
        previewInFlight += 1
        previewActivity?.host = URL(string: row.rawURL)?.host?.lowercased()
      } else {
        // The one-row button got there first: counted, not asked twice.
        previewActivity?.completed += 1
        if case .loaded = thumbnailStates[row.rawURL] { previewActivity?.loaded += 1 }
      }
    }
    finishPreviewsIfDone()
  }

  private func previewFinished(loaded: Bool) {
    previewInFlight -= 1
    previewActivity?.completed += 1
    if loaded { previewActivity?.loaded += 1 }
    pumpPreviews()
  }

  private func finishPreviewsIfDone() {
    guard previewInFlight == 0, previewQueue.isEmpty, var activity = previewActivity,
      !activity.isFinished
    else { return }
    activity.isFinished = true
    activity.isStopping = false
    previewActivity = activity
  }

  // MARK: - Capsule and group headers

  /// The shown Other Domains half's capsule; nil on Your Domains or with
  /// no URL.
  public var previewCapsule: ExternalPreviewCapsule? {
    guard domain == .other, case let .results(rows) = presentation else { return nil }
    let urls = Set(rows.map(\.rawURL))
    guard !urls.isEmpty else { return nil }
    let loaded = urls.count { if case .loaded = thumbnailStates[$0] { true } else { false } }
    return ExternalPreviewCapsule(
      loaded: loaded, total: urls.count, loadable: previewCandidates(rows).count)
  }

  /// A host or file group's control on Other Domains.
  public func groupPreview(_ group: ExternalGroup) -> ExternalGroupPreview {
    guard domain == .other else { return .none }
    let urls = Set(group.rows.filter { $0.domain == .other }.map(\.rawURL))
    guard !urls.isEmpty else { return .none }
    if urls.allSatisfy({ if case .loaded = thumbnailStates[$0] { true } else { false } }) {
      return .loaded
    }
    let count = previewCandidates(group.rows).count
    return count > 0 ? .load(count) : .none
  }

  // MARK: - Several rows

  /// `ids`' rows summarised; nil when none is shown.
  public func selectionSummary(_ ids: Set<ExternalReference.ID>) -> ExternalSelectionSummary? {
    let rows = rows(ids)
    guard !rows.isEmpty else { return nil }
    var seenURLs = Set<String>()
    let images = rows.filter { seenURLs.insert($0.rawURL).inserted }
    var hostOrder: [String] = []
    var refs: [String: Int] = [:]
    for row in rows {
      let host = URL(string: row.rawURL)?.host?.lowercased() ?? "No Host"
      if refs[host] == nil { hostOrder.append(host) }
      refs[host, default: 0] += 1
    }
    let files = Set(rows.map { "\($0.projectSlug)\u{0}\(UsageReferenceRow.split($0.sourceReference).file)" })
    return ExternalSelectionSummary(
      rows: rows, images: images,
      hosts: hostOrder.map { .init(host: $0, refs: refs[$0] ?? 0) }, files: files.count)
  }

  /// The status bar's left side on Externals: "3 selected · 2 hosts · 3
  /// files", or nothing.
  public var selectionStatusText: String? {
    guard let summary = selectionSummary(selection) else { return nil }
    return "\(summary.rows.count.formatted()) selected · \(summary.facts)"
  }
}
