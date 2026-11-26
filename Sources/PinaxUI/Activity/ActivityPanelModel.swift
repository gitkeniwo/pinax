import AppKit
import CatalogCore
import Foundation

/// What the activity panel reads:
/// `ReadOnlyCatalog`, or a counting double in tests.
public protocol RunLogReading: Sendable {
  func runs(limit: Int) async throws -> [RunRecord]
  func runEvents(of runID: Int64, after seq: Int) async throws -> [RunEventRecord]
}

extension ReadOnlyCatalog: RunLogReading {}

/// The panel's log view: Events or Raw.
public enum ActivityLogView: String, CaseIterable, Sendable {
  case events, raw

  public var title: String { self == .events ? "Events" : "Raw" }
}

/// One count of the log header, in place of metric cards.
public struct ActivityTally: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case uploaded, reused, skipped, filesChanged, failed

    public var help: String {
      switch self {
      case .uploaded: return "Uploaded"
      case .reused: return "Reused from the library"
      case .skipped: return "Skipped"
      case .filesChanged: return "Files changed"
      case .failed: return "Failed"
      }
    }
  }

  public let kind: Kind
  public let count: Int
}

/// A run-list row.
public struct ActivityRunRow: Equatable, Identifiable, Sendable {
  public let id: Int64
  public let name: String
  /// The name's action word ("Migrate"), drawn primary;
  /// the rest ("astro · preview") is `subject`, drawn secondary.
  public var action: String { ActivityPanelModel.split(name).action }
  public var subject: String? { ActivityPanelModel.split(name).subject }
  public let time: String
  public let state: RunState
  /// Finished but with skips, failures or errors: the orange !.
  public let hasWarnings: Bool
}

/// A run of log rows under one heading; nil when the run
/// has none (no run selected).
public struct ActivityLogSection: Equatable, Sendable {
  public let title: String?
  public var records: [RunEventRecord]
}

public struct ActivityRunGroup: Equatable, Sendable {
  public let title: String
  public let rows: [ActivityRunRow]
}

/// The activity panel, one per window. It reads the `run`
/// table; while open it polls every two seconds for runs other processes
/// write, and never while closed.
@MainActor
public final class ActivityPanelModel: ObservableObject {
  public static let runLimit = 200

  @Published public private(set) var runs: [RunRecord] = []
  @Published public var selectedRunID: Int64? {
    didSet {
      guard oldValue != selectedRunID else { return }
      events = []
      selectedLines = []
      lineAnchor = nil
      changesDiff = nil
      Task { await loadEvents() }
    }
  }
  @Published public private(set) var events: [RunEventRecord] = []
  @Published public var logView: ActivityLogView = .events
  @Published public var warningsOnly = false
  @Published public var filter = ""
  @Published public var showsRunList = true
  @Published public var showsChangedFiles = false
  /// The selected log rows, by event `seq` (Events and Raw share it).
  @Published public private(set) var selectedLines: Set<Int> = []
  private var lineAnchor: Int?
  /// Show Changes…'s unified diff for a migration preview; non-nil
  /// presents the sheet.
  @Published public var changesDiff: String?
  /// Polling runs only while this is true.
  @Published public private(set) var isOpen = false

  private let reader: RunLogReading?
  private let pollInterval: Duration
  private var pollTask: Task<Void, Never>?
  private let now: () -> Date
  /// Copy Log, opening a changed file, Reveal in Finder; replaced in tests.
  public var copy: (String) -> Void = { text in
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  public var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
  public var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
  /// A migration preview's diff (the app's migrator); nil offers no Show
  /// Changes….
  public var diff: ((Int64) async throws -> String)?
  /// A `rewrite` or `domain_migrate` preview's
  /// diff (the core's `RewriteRuns.diff`); nil offers no Show Changes… for them.
  public var rewriteDiff: ((Int64) async throws -> String)?

  public init(reader: RunLogReading?, pollInterval: Duration = .seconds(2), now: @escaping () -> Date = Date.init) {
    self.reader = reader
    self.pollInterval = pollInterval
    self.now = now
  }

  // MARK: Open, close, poll

  /// The panel opened or closed: polling starts with it and stops with it.
  public func setOpen(_ open: Bool) {
    guard open != isOpen else { return }
    isOpen = open
    pollTask?.cancel()
    pollTask = nil
    guard open, reader != nil else { return }
    let interval = pollInterval
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// Opens on `request`'s run (Show Log, Changed Files).
  public func show(_ request: ActivityPanelRequest) {
    selectedRunID = request.runID
    showsChangedFiles = request.showsChangedFiles
  }

  /// Rereads the runs and the selected run's new events. In-process
  /// runs call this from their progress callbacks; the poll calls it
  /// every two seconds while the panel is open.
  public func refresh() async {
    guard let reader else { return }
    if let fresh = try? await reader.runs(limit: Self.runLimit), fresh != runs {
      runs = fresh
    }
    if selectedRunID == nil || !runs.contains(where: { $0.id == selectedRunID }) {
      selectedRunID = runs.first?.id
    }
    await loadEvents()
  }

  private func loadEvents() async {
    guard let reader, let runID = selectedRunID else { return }
    let after = events.last?.seq ?? 0
    guard let fresh = try? await reader.runEvents(of: runID, after: after), !fresh.isEmpty,
      runID == selectedRunID, (events.last?.seq ?? 0) == after
    else { return }
    events += fresh
  }

  // MARK: Run list

  public var selectedRun: RunRecord? { runs.first { $0.id == selectedRunID } }

  /// Today, Yesterday, then "27 Oct".
  public var groups: [ActivityRunGroup] {
    Self.groups(runs, now: now())
  }

  static func groups(_ runs: [RunRecord], now: Date, calendar: Calendar = .current) -> [ActivityRunGroup] {
    var groups: [ActivityRunGroup] = []
    var title: String?
    var rows: [ActivityRunRow] = []
    for run in runs {
      let started = Self.date(run.startedAt)
      let heading = started.map { dayTitle($0, now: now, calendar: calendar) } ?? "Earlier"
      if heading != title {
        if let title { groups.append(ActivityRunGroup(title: title, rows: rows)) }
        title = heading
        rows = []
      }
      rows.append(
        ActivityRunRow(
          id: run.id, name: name(of: run), time: started.map { format($0, "HH:mm") } ?? "",
          state: run.state, hasWarnings: hasWarnings(run)))
    }
    if let title { groups.append(ActivityRunGroup(title: title, rows: rows)) }
    return groups
  }

  static func dayTitle(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "Yesterday"
    }
    return format(date, "d MMM")
  }

  /// "Migrate · astro", "Rewrite · astro", "Domain move · r2"; a preview
  /// adds " · preview", a cancelled run " · cancelled" instead (no
  /// dash).
  public static func name(of run: RunRecord) -> String {
    let base = baseName(of: run)
    if run.state == .cancelled { return base + " · cancelled" }
    return run.dryRun ? base + " · preview" : base
  }

  /// "Migrate · astro · preview" → ("Migrate", "astro · preview").
  nonisolated static func split(_ name: String) -> (action: String, subject: String?) {
    guard let range = name.range(of: " · ") else { return (name, nil) }
    return (String(name[..<range.lowerBound]), String(name[range.upperBound...]))
  }

  static func baseName(of run: RunRecord) -> String {
    let decoder = JSONDecoder()
    let data = Data(run.params.utf8)
    let label: String
    let subject: [String]
    switch run.kind {
    case .externalMigrate:
      label = "Migrate"
      subject = (try? decoder.decode(ExternalMigrationParams.self, from: data))?.targets.map(\.project) ?? []
    case .rewrite:
      label = "Rewrite"
      subject = (try? decoder.decode(RewriteRunParams.self, from: data))?.targets.map(\.project) ?? []
    case .domainMigrate:
      label = "Domain move"
      subject = [(try? decoder.decode(RewriteRunParams.self, from: data))?.domain?.backend].compactMap { $0 }
    case .optimize:
      label = "Optimize"
      subject = [(try? decoder.decode(OptimizeRunParams.self, from: data))?.backend].compactMap { $0 }
    }
    var seen = Set<String>()
    let unique = subject.filter { seen.insert($0).inserted }
    return unique.isEmpty ? label : "\(label) · \(unique.joined(separator: ", "))"
  }

  /// The header's title: the run's name, and a migration's bucket.
  public var title: String? {
    guard let run = selectedRun else { return nil }
    guard run.kind == .externalMigrate,
      let params = try? JSONDecoder().decode(ExternalMigrationParams.self, from: Data(run.params.utf8))
    else { return Self.name(of: run) }
    return "\(Self.name(of: run)) → \(params.backend)"
  }

  static func summary(of run: RunRecord) -> RewriteRunSummary? {
    run.summary.flatMap { try? JSONDecoder().decode(RewriteRunSummary.self, from: Data($0.utf8)) }
  }

  static func hasWarnings(_ run: RunRecord) -> Bool {
    guard run.state == .finished, let summary = summary(of: run) else { return false }
    return tallies(kind: run.kind, summary: summary)
      .contains { ($0.kind == .skipped || $0.kind == .failed) && $0.count > 0 } || summary.errors > 0
  }

  // MARK: Header

  /// The header's counts, from the run's summary.
  public var tallies: [ActivityTally] {
    guard let run = selectedRun, let summary = Self.summary(of: run) else { return [] }
    return Self.tallies(kind: run.kind, summary: summary)
  }

  static func tallies(kind: RunKind, summary: RewriteRunSummary) -> [ActivityTally] {
    let filesChanged = summary.written ?? summary.files
    switch kind {
    case .externalMigrate:
      let migration = summary.migration
      return [
        ActivityTally(kind: .uploaded, count: migration?.uploaded?.images ?? 0),
        ActivityTally(kind: .reused, count: migration?.reused.images ?? 0),
        ActivityTally(kind: .skipped, count: migration?.skipped.images ?? 0),
        ActivityTally(kind: .filesChanged, count: filesChanged),
      ]
    case .rewrite, .domainMigrate:
      let skipped = summary.skippedFiles.map { $0.values.reduce(0, +) }
        ?? summary.skippedEdits.values.reduce(0, +)
      return [
        ActivityTally(kind: .filesChanged, count: filesChanged),
        ActivityTally(kind: .skipped, count: skipped),
        ActivityTally(kind: .failed, count: summary.failed ?? 0),
      ]
    case .optimize:
      // A measurement changes nothing, so it has nothing to count.
      return []
    }
  }

  // MARK: Log

  private var levelFiltered: [RunEventRecord] { levelFiltered(events) }

  private func levelFiltered(_ events: [RunEventRecord]) -> [RunEventRecord] {
    warningsOnly ? events.filter { $0.level >= .warning } : events
  }

  private var trimmedFilter: String { filter.trimmingCharacters(in: .whitespaces) }

  /// Events view: one row per event, filtered on its summary line.
  public var visibleEvents: [RunEventRecord] { visibleEvents(events) }

  private func visibleEvents(_ events: [RunEventRecord]) -> [RunEventRecord] {
    let filter = trimmedFilter
    guard !filter.isEmpty else { return levelFiltered(events) }
    return levelFiltered(events).filter { $0.event.summaryLine.localizedCaseInsensitiveContains(filter) }
  }

  /// The visible events under headings that say what was
  /// done, a new heading where the kind of step changes. An event with no
  /// heading of its own (the start, the finish, a stop) stays under the
  /// one before it; leading ones join the first heading that follows.
  public var eventSections: [ActivityLogSection] {
    guard let run = selectedRun else { return [ActivityLogSection(title: nil, records: visibleEvents)] }
    return Self.sections(visibleEvents, kind: run.kind, dryRun: run.dryRun)
  }

  static func sections(_ records: [RunEventRecord], kind: RunKind, dryRun: Bool) -> [ActivityLogSection] {
    let titles = records.map { section(of: $0.event, kind: kind, dryRun: dryRun) }
    var sections: [ActivityLogSection] = []
    var current = titles.first { $0 != nil } ?? nil
    for (record, title) in zip(records, titles) {
      if let title, title != current || sections.isEmpty {
        current = title
        sections.append(ActivityLogSection(title: title, records: [record]))
      } else if sections.isEmpty {
        sections.append(ActivityLogSection(title: current, records: [record]))
      } else {
        sections[sections.count - 1].records.append(record)
      }
    }
    return sections
  }

  /// The heading an event belongs under. A migration's preparation:
  /// what it downloaded and checked, then what happens when you migrate;
  /// its apply: what was uploaded, then what was rewritten. A rewrite or a
  /// domain move by the same rule: what it checked, then — previewed —
  /// what happens when you apply, or — applied — what was rewritten.
  static func section(of event: RunEvent, kind: RunKind, dryRun: Bool) -> String? {
    switch event {
    case .runStarted, .migrationStarted, .runFinished, .migrationStopped, .optimizeSelected:
      return nil
    case .objectMeasured:
      return "Measured"
    case .downloadFinished, .downloadFailed:
      return "Downloaded and checked"
    case .sourceStatus, .targetVerified:
      switch kind {
      case .externalMigrate: return dryRun ? "Downloaded and checked" : "Uploaded"
      case .rewrite, .domainMigrate, .optimize: return "Checked"
      }
    case .uploadFinished, .assetReused, .uploadFailed, .verifyFailed, .keyChanged:
      return "Uploaded"
    case .migrationPlanned, .filePlanned:
      return kind == .externalMigrate ? "When you migrate" : "When you apply"
    case .editSkipped, .protocolRelativeFound:
      if dryRun { return kind == .externalMigrate ? "When you migrate" : "When you apply" }
      return "Rewritten"
    case .prefixChanged, .fileWritten, .fileSkipped, .fileFailed, .rescanFinished, .rescanFailed:
      return "Rewritten"
    }
  }

  /// A planned step ("Will upload", "Will rewrite") is drawn a
  /// level down.
  public static func isPlanned(_ event: RunEvent) -> Bool {
    switch event {
    case .migrationPlanned, .filePlanned: return true
    default: return false
    }
  }

  /// The run's closing line: its verb is the only bold one.
  public static func isSummary(_ event: RunEvent) -> Bool {
    if case .runFinished = event { return true }
    return false
  }

  /// A downloaded image's size at or over the large line: orange.
  public static func hasLargeDetail(_ event: RunEvent) -> Bool {
    if case let .downloadFinished(download) = event { return PinaxFormat.isLarge(download.bytes) }
    return false
  }

  /// Raw view: `pinax runs show --format jsonl`'s lines, filtered per line.
  public var rawLines: [String] { rawRows.map(\.line) }

  /// Raw's lines with their event's `seq`, for selecting rows.
  public var rawRows: [(seq: Int, line: String)] { rawRows(events) }

  private func rawRows(_ events: [RunEventRecord]) -> [(seq: Int, line: String)] {
    let rows = levelFiltered(events).map { (seq: $0.seq, line: $0.jsonLine) }
    let filter = trimmedFilter
    guard !filter.isEmpty else { return rows }
    return rows.filter { $0.line.localizedCaseInsensitiveContains(filter) }
  }

  // MARK: Selecting and copying rows

  /// The rows the current view shows, in order: what ⇧ ranges over and
  /// what a copy keeps the order of.
  private var visibleSeqs: [Int] {
    switch logView {
    case .events: return visibleEvents.map(\.seq)
    case .raw: return rawRows.map(\.seq)
    }
  }

  /// A click on a row: alone it selects just that row; ⌘ adds or removes
  /// it; ⇧ selects from the last clicked row to it (⌘⇧ adds that range).
  public func clickLine(_ seq: Int, extending: Bool = false, toggling: Bool = false) {
    let seqs = visibleSeqs
    if extending, let anchor = lineAnchor, let from = seqs.firstIndex(of: anchor),
      let to = seqs.firstIndex(of: seq)
    {
      let range = Set(seqs[min(from, to)...max(from, to)])
      selectedLines = toggling ? selectedLines.union(range) : range
      return
    }
    if toggling {
      if selectedLines.contains(seq) { selectedLines.remove(seq) } else { selectedLines.insert(seq) }
    } else {
      selectedLines = [seq]
    }
    lineAnchor = seq
  }

  /// ⌘A selects every row the current view shows.
  public func selectAllLines() {
    let seqs = visibleSeqs
    selectedLines = Set(seqs)
    lineAnchor = seqs.first
  }

  public func clearLineSelection() {
    selectedLines = []
    lineAnchor = nil
  }

  /// The text a copy puts on the pasteboard for `seqs`, in view order:
  /// Events `HH:mm:ss  summary line`, Raw the JSONL lines.
  public func lineText(_ seqs: Set<Int>) -> String {
    switch logView {
    case .events:
      return visibleEvents.filter { seqs.contains($0.seq) }
        .map { "\(Self.eventTime($0.at))  \($0.event.summaryLine)" }
        .joined(separator: "\n")
    case .raw:
      return rawRows.filter { seqs.contains($0.seq) }.map(\.line).joined(separator: "\n")
    }
  }

  /// The selected rows shown in the current view.
  public var selectedLineText: String { lineText(selectedLines) }

  /// ⌘C: the selected rows; nothing selected copies nothing.
  public func copySelectedLines() {
    let text = selectedLineText
    guard !text.isEmpty else { return }
    copy(text)
  }

  /// A row's context menu Copy: the selection when the row is in it,
  /// otherwise just that row.
  public func copyLines(from seq: Int) {
    copy(lineText(selectedLines.contains(seq) ? selectedLines : [seq]))
  }

  /// Copy Log: the summary lines, or the JSONL, as shown.
  public var logText: String { logText(of: events) }

  /// Copy Log's text for any run's events: the current view and filters.
  public func logText(of events: [RunEventRecord]) -> String {
    switch logView {
    case .events: return visibleEvents(events).map(\.event.summaryLine).joined(separator: "\n")
    case .raw: return rawRows(events).map(\.line).joined(separator: "\n")
    }
  }

  public func copyLog() { copy(logText) }

  /// A run row's Copy Log — that run's whole log as
  /// the bar's Copy Log would copy it, without selecting the row.
  public func copyLog(ofRun runID: Int64) async {
    if runID == selectedRunID {
      await loadEvents()
      copy(logText)
      return
    }
    guard let reader, let fresh = try? await reader.runEvents(of: runID, after: 0) else { return }
    copy(logText(of: fresh))
  }

  /// "14:00:02" in local time.
  public static func eventTime(_ at: String) -> String {
    date(at).map { format($0, "HH:mm:ss") } ?? ""
  }

  // MARK: Changed files

  public struct ChangedRepository: Equatable, Sendable {
    /// Nil: files outside git, listed relative to their source folder —
    /// and a preview's planned files.
    public let root: String?
    public let paths: [String]
    /// A preview's group, "astro · blog" (project · source); its paths are
    /// relative to the source folder, so they do not open.
    public var planned: String?

    public func url(_ path: String) -> URL? {
      root.map { URL(fileURLWithPath: $0).appendingPathComponent(path) }
    }

    public var title: String {
      planned ?? root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not in git"
    }
  }

  /// A preview lists the files it would change (its `file_planned`
  /// events); an apply its `changed_files_by_repo`.
  public var isPreviewSelected: Bool { selectedRun?.dryRun ?? false }

  /// Changed Files: a preview's planned files by project · source, in
  /// event order; an apply's `changed_files_by_repo`, repositories in
  /// order, files outside git last.
  public var changedFiles: [ChangedRepository] {
    guard let run = selectedRun else { return [] }
    if run.dryRun { return plannedFiles }
    guard let map = Self.summary(of: run)?.changedFilesByRepo else { return [] }
    return map.keys.sorted { lhs, rhs in
      if lhs == RewriteRunSummary.notInGitKey { return false }
      if rhs == RewriteRunSummary.notInGitKey { return true }
      return lhs < rhs
    }.map { key in
      ChangedRepository(
        root: key == RewriteRunSummary.notInGitKey ? nil : key, paths: (map[key] ?? []).sorted())
    }
  }

  private var plannedFiles: [ChangedRepository] {
    var order: [String] = []
    var paths: [String: [String]] = [:]
    for record in events {
      guard case let .filePlanned(event) = record.event else { continue }
      let key = "\(event.project) · \(event.source)"
      if paths[key] == nil { order.append(key) }
      if !(paths[key]?.contains(event.path) ?? false) { paths[key, default: []].append(event.path) }
    }
    return order.map { ChangedRepository(root: nil, paths: paths[$0] ?? [], planned: $0) }
  }

  /// The changed files Finder can find (the ones in a repository); none
  /// for a preview.
  public var changedFileURLs: [URL] {
    changedFiles.flatMap { repository in repository.paths.compactMap(repository.url) }
  }

  /// Show Changes… in the popover: a migration preview that planned files.
  public var canShowChanges: Bool {
    guard let run = selectedRun, run.dryRun, diffReader(for: run.kind) != nil else { return false }
    return !changedFiles.isEmpty
  }

  /// Externals' preview through its migrator; rewrite and domain moves
  /// through the core's diff by run.
  private func diffReader(for kind: RunKind) -> ((Int64) async throws -> String)? {
    switch kind {
    case .externalMigrate: return diff
    case .rewrite, .domainMigrate: return rewriteDiff
    case .optimize: return nil
    }
  }

  public func showChanges() async {
    guard canShowChanges, let run = selectedRun, let diff = diffReader(for: run.kind),
      let runID = selectedRunID
    else { return }
    showsChangedFiles = false
    do {
      let text = try await diff(runID)
      changesDiff = text.isEmpty ? "No file changes." : text
    } catch {
      changesDiff = UserFacingErrorMessage.resolve(error)
    }
  }

  // MARK: Layout

  /// The panel's height, dragged at its top edge: at least 160 pt, at
  /// most 60 % of the window, 340 by default.
  public static let defaultHeight: CGFloat = 340
  public static let minimumHeight: CGFloat = 160
  public static let maximumHeightFraction: CGFloat = 0.6

  public static func clampedHeight(_ height: CGFloat, windowHeight: CGFloat) -> CGFloat {
    let maximum = max(minimumHeight, (windowHeight * maximumHeightFraction).rounded(.down))
    return min(max(height, minimumHeight), maximum)
  }

  /// The run list's width, dragged at its divider: at least 180 pt, and
  /// the log keeps at least 280. A panel narrower than both shares
  /// its width in that 180 : 280 ratio, so neither column overflows.
  public static let defaultRunListWidth: CGFloat = 240
  public static let minimumRunListWidth: CGFloat = 180
  public static let minimumLogWidth: CGFloat = 280

  public static func clampedRunListWidth(_ width: CGFloat, panelWidth: CGFloat) -> CGFloat {
    let floor = minimumRunListWidth + minimumLogWidth
    if panelWidth > 0, panelWidth < floor {
      return (panelWidth * minimumRunListWidth / floor).rounded(.down)
    }
    let maximum = max(minimumRunListWidth, panelWidth - minimumLogWidth)
    return min(max(width, minimumRunListWidth), maximum)
  }

  public func revealChangedFiles() {
    let urls = changedFileURLs
    guard !urls.isEmpty else { return }
    reveal(urls)
  }

  // MARK: Dates

  static func date(_ stamp: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: stamp) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: stamp)
  }

  static func format(_ date: Date, _ template: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_GB")
    formatter.dateFormat = template
    return formatter.string(from: date)
  }
}
