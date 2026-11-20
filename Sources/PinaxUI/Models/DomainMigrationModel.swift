import CatalogCore
import Combine
import Foundation

// MARK: - The words

/// Copy shared by the sheet, the activity bar and the Domains list.
public enum DomainCopy {
  public static let tip = "Tip: links on other sites keep working only while the old domain still serves this bucket."
  public static let formSubtitle = "Pinax checks every link on the new domain first. Nothing changes until you confirm."
  public static let toPlaceholder = "https://img2.example.com"
  public static let continueHelp = "Close the sheet. Progress stays in the activity bar."
  public static let verifiedHelpNew = "Same image on the new domain"
  public static let verifiedHelpCurrent = "Same image on the current domain"
  public static let fetchedOnlyHelpNew = "Loads on the new domain. Not in the library, so Pinax can’t compare it."
  public static let fetchedOnlyHelpCurrent = "Loads on the current domain. Not in the library, so Pinax can’t compare it."
  public static let brokenHelp = "Doesn’t load on either domain. Pinax rewrites it anyway; it doesn’t block the move."
  public static let unusedHelp = "No project links to it anymore. Remove it once the old domain stops serving."

  /// "1 link" / "268 links".
  static func links(_ n: Int, capital: Bool = false) -> String {
    PinaxFormat.count(n, singular: capital ? "Link" : "link")
  }

  /// A refused domain, in the field's words: another backend's is named.
  public static func message(_ error: Error) -> String {
    if case let CatalogConfigurationError.domainOfOtherBackend(_, backend) = error {
      return "Already belongs to the backend \(backend)."
    }
    return UserFacingErrorMessage.resolve(error)
  }

  /// The form's own check of To: http(s), a host, not the
  /// Current, no other backend's. Nil when it may be checked.
  public static func toError(_ value: String, current: String, backend: String, backends: [DomainBackend]) -> String? {
    let trimmed = DomainHost.normalized(value)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host()?.isEmpty == false
    else { return "Enter an http or https address." }
    if DomainHost.same(trimmed, current) { return "That’s the current domain." }
    if let owner = backends.first(where: { other in
      other.slug != backend && other.prefixes.contains { DomainHost.same($0, trimmed) }
    }) {
      return "Already belongs to the backend \(owner.slug)."
    }
    return nil
  }
}

extension DomainHost {
  /// Trimmed, without trailing slashes, as the core stores a prefix.
  static func normalized(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while result.last == "/" { result.removeLast() }
    return result
  }

  /// The core's `sameDomain`: scheme and host compared without case.
  static func same(_ a: String, _ b: String) -> Bool {
    func key(_ value: String) -> String {
      let value = normalized(value)
      guard var components = URLComponents(string: value) else { return value }
      components.scheme = components.scheme?.lowercased()
      components.host = components.host?.lowercased()
      return components.string ?? value
    }
    return key(a) == key(b)
  }
}

// MARK: - What the sheet and the bar show

/// The move being made: flow A (a new domain) or flow B (Old domains'
/// links to the Current).
public struct DomainMoveRequest: Equatable, Sendable {
  public let backend: String
  /// The Current prefix.
  public let from: String
  /// The new prefix; flow B's is the Current.
  public let to: String
  /// Flow B's Old domains, or flow A's (all of them unless kept).
  public let oldDomains: [String]
  /// Flow A with the switch off (`--keep-old-domains`).
  public let keepOldDomains: Bool
  /// Empty: the core's default projects.
  public let projects: [String]
  /// The links the entry counted (the checking state's "Move N Links").
  public var links = 0

  public var keepsPrefix: Bool { DomainHost.same(from, to) }
  public var toHost: String { DomainHost.host(to) }
}

/// Flow A's fill-in state.
public struct DomainMoveForm: Equatable, Sendable {
  public let backend: String
  public let current: String
  public let oldDomains: [String]
  public var to = ""
  /// "Also move links on old domains", on by default.
  public var alsoMoveOld = true
  public var projects: [DomainMoveProject] = []
  public var selected: Set<String> = []
  /// The projects are still being read.
  public var isLoading = true
  /// To's error, under the field.
  public var error: String?

  public var fromHost: String { DomainHost.host(current) }
  public var showsOldDomainsSwitch: Bool { !oldDomains.isEmpty }
  public var canCheck: Bool {
    error == nil && !DomainHost.normalized(to).isEmpty && !selected.isEmpty && !isLoading
  }
}

/// Checking's lines.
public struct DomainMoveChecking: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case planning(project: String?)
    case checking(done: Int, total: Int)
  }
  public var phase: Phase = .planning(project: nil)
  /// Only grows (the core's total grows once).
  public var fraction: Double = 0

  /// "Checking 120 of 268 links", "Planning astro…".
  public var text: String {
    switch phase {
    case let .planning(project): return project.map { "Planning \($0)…" } ?? "Planning…"
    case let .checking(done, total): return "Checking \(done.formatted()) of \(DomainCopy.links(total))"
    }
  }
}

/// One summary row of the sheet: icon, label, value, tooltip.
public struct DomainMoveLine: Equatable, Sendable {
  public enum Tone: Equatable, Sendable { case files, prefix, oldDomains, checks }
  public let label: String
  public let tone: Tone
  public let value: String
  public let help: String
}

/// A failed or broken group: the reason, how many, at most five URLs.
public struct DomainMoveGroup: Equatable, Sendable, Identifiable {
  public let reason: String
  public let urls: [String]
  public var id: String { reason }
  public static let shown = 5
  public var count: Int { urls.count }
  public var shownURLs: [String] { Array(urls.prefix(Self.shown)) }
  /// "and 2 more"; nil within five.
  public var more: String? { urls.count > Self.shown ? "and \((urls.count - Self.shown).formatted()) more" : nil }

  static func make(_ pairs: [(url: String, reason: String)]) -> [DomainMoveGroup] {
    var order: [String] = []
    var byReason: [String: [String]] = [:]
    for pair in pairs {
      if byReason[pair.reason] == nil { order.append(pair.reason) }
      byReason[pair.reason, default: []].append(pair.url)
    }
    return order.map { DomainMoveGroup(reason: $0, urls: byReason[$0] ?? []) }
  }
}

/// Everything the result sheet shows, from the core's review of the run alone,
/// so Review… reopens it after the sheet closed.
public struct DomainMoveSummary: Equatable, Sendable {
  public struct Source: Equatable, Sendable, Identifiable {
    /// `project/label`, as `apply(allowedSources:)` takes it.
    public let id: String
    public let text: String
  }

  public let review: DomainMigrationReview
  public var runID: Int64 { review.runID }
  public var keepsPrefix: Bool { review.keepPrefix }
  public var toHost: String { DomainHost.host(review.to) }
  public var fromHost: String { DomainHost.host(review.from) }
  public var links: Int { review.edits }
  public var failedCount: Int { review.failed.count }
  public var isPrefixOnly: Bool { !review.keepPrefix && review.edits == 0 && review.failed.isEmpty }

  public init(_ review: DomainMigrationReview) {
    self.review = review
  }

  public var title: String {
    if failedCount > 0 { return "\(DomainCopy.links(failedCount, capital: true)) Failed the Check" }
    if isPrefixOnly { return "Change the Prefix Only?" }
    return "Move \(DomainCopy.links(links, capital: true)) to \(toHost)?"
  }

  public var subtitle: String {
    if failedCount > 0 { return "Nothing has changed. These links don’t show the same image on \(toHost)." }
    if isPrefixOnly { return "No file links to \(fromHost). New uploads will use \(toHost)." }
    return keepsPrefix
      ? "Pinax rewrites the links in your files. The prefix stays as it is. It doesn’t commit."
      : "Pinax changes the prefix first, then rewrites the links in your files. It doesn’t commit."
  }

  /// "Move 268 Links", or "Change Prefix" with nothing to rewrite.
  public var moveTitle: String {
    isPrefixOnly ? "Change Prefix" : "Move \(DomainCopy.links(links, capital: true))"
  }

  public var filesValue: String {
    review.files == 0
      ? "None"
      : "\(PinaxFormat.count(review.files, singular: "file")) · \(PinaxFormat.count(review.projects.count { $0.files > 0 }, singular: "project"))"
  }

  public var lines: [DomainMoveLine] {
    let prefix =
      keepsPrefix ? "Unchanged · \(toHost)" : "\(fromHost) → \(toHost)"
    let old: String
    if keepsPrefix {
      old = review.oldDomains.map(DomainHost.host).joined(separator: ", ")
    } else {
      old = review.oldDomains.isEmpty ? "Kept as they are" : "Moved too · \(review.oldDomains.count.formatted())"
    }
    return [
      DomainMoveLine(label: "Files to change", tone: .files, value: filesValue, help: "Files whose links Pinax rewrites"),
      DomainMoveLine(
        label: "Prefix", tone: .prefix, value: prefix,
        help: keepsPrefix ? "The prefix stays as it is" : "New uploads and rewritten links use the new prefix"),
      DomainMoveLine(
        label: "Old domains", tone: .oldDomains, value: old.isEmpty ? "None" : old,
        help: keepsPrefix
          ? "Links on these old domains move to the current one"
          : "Links on old domains of this backend move to the new domain too"),
    ]
  }

  /// The three counts: verified (green), fetched only (blue), failed (red,
  /// only when some failed).
  public var checks: (verified: Int, fetchedOnly: Int, failed: Int) {
    (review.verified, review.fetchedOnly, review.failed.count)
  }

  public var verifiedHelp: String { keepsPrefix ? DomainCopy.verifiedHelpCurrent : DomainCopy.verifiedHelpNew }
  public var fetchedOnlyHelp: String { keepsPrefix ? DomainCopy.fetchedOnlyHelpCurrent : DomainCopy.fetchedOnlyHelpNew }

  public var failedGroups: [DomainMoveGroup] {
    DomainMoveGroup.make(review.failed.map { ($0.url, $0.reason) })
  }

  /// Grouped by `old_reason`.
  public var brokenGroups: [DomainMoveGroup] {
    DomainMoveGroup.make(review.alreadyBroken.map { ($0.url, "\($0.oldReason) on the old domain") })
  }

  public var sources: [Source] {
    review.sources.filter { !$0.isClean }.map { source in
      let text: String =
        switch source.status {
        case .dirty: "\(source.project)/\(source.label) has uncommitted changes"
        case .notGit: "\(source.project)/\(source.label) isn’t in git"
        case .unknown, .clean: "\(source.project)/\(source.label)’s git status is unknown"
        }
      return Source(id: "\(source.project)/\(source.label)", text: text)
    }
  }

  /// Greyed with a failure, an unticked unclean source, or a run that is
  /// not a finished, unapplied preview.
  public func canMove(allowed: Set<String>) -> Bool {
    review.state == .finished && !review.applied && review.failed.isEmpty
      && sources.allSatisfy { allowed.contains($0.id) }
  }
}

/// The activity bar's domain move.
public enum DomainMigrationStatus: Equatable, Sendable {
  case checking(DomainMoveChecking, host: String)
  case ready(runID: Int64, links: Int)
  case failedCheck(runID: Int64, failed: Int)
  case changingPrefix
  case rewriting(files: Int)
  case rescanning(project: String)
  case done(ActivityItem)

  public var item: ActivityItem {
    switch self {
    case let .checking(checking, host):
      if case .planning = checking.phase { return .running(checking.text, cancel: "Cancel") }
      return .running("\(checking.text) · \(host)", fraction: checking.fraction, cancel: "Cancel")
    case let .ready(runID, links):
      return ActivityItem(
        text: "Ready to move \(DomainCopy.links(links))", phase: .ready, runID: runID, link: .review)
    case let .failedCheck(runID, failed):
      return ActivityItem(
        text: "\(DomainCopy.links(failed)) failed the check", phase: .needsReview, runID: runID, link: .review)
    case .changingPrefix:
      return .running("Changing prefix…")
    case let .rewriting(files):
      return .running("Rewriting \(PinaxFormat.count(files, singular: "file"))…")
    case let .rescanning(project):
      return .running("Rescanning \(project)…")
    case let .done(item):
      return item
    }
  }

  public var isRunning: Bool { item.isRunning }

  /// Done: "Moved 268 links · 55 files", Changed Files.
  static func result(_ result: RewriteApplyResult, links: Int) -> DomainMigrationStatus {
    let written = result.summary.written ?? 0
    let warnings = result.summary.errors > 0 || (result.summary.skippedFiles?.values.reduce(0, +) ?? 0) > 0
    let text =
      written == 0 && links == 0
      ? "Prefix changed"
      : "Moved \(DomainCopy.links(links)) · \(PinaxFormat.count(written, singular: "file"))"
    return .done(
      ActivityItem(
        text: text, phase: warnings ? .warnings : .finished, runID: result.runID,
        link: written > 0 ? .changedFiles : .showLog))
  }
}

/// A refused apply: the sheet comes back with why.
public struct DomainMoveRefusal: Equatable, Sendable {
  public let message: String

  static func make(_ error: Error) -> DomainMoveRefusal? {
    let reason: String
    switch error {
    case DomainMigrationError.prefixMoved:
      reason = "The backend’s prefix changed since the check."
    case let RewriteRunError.planChanged(_, differences):
      reason = "\(PinaxFormat.count(differences.count, singular: "file")) changed since the check."
    case let RewriteRunError.sourcesNotAllowed(sources):
      reason = "Some sources aren’t clean: \(sources.joined(separator: ", "))."
    case DomainMigrationError.targetsNotVerified, RewriteRunError.targetsNotVerified:
      reason = "Some links failed the check."
    case RewriteRunError.notAPreview, RewriteRunError.runNotFound:
      reason = "This check can’t be applied any more."
    default:
      return nil
    }
    return DomainMoveRefusal(message: "\(reason) Nothing was changed. Check again.")
  }
}

// MARK: - The model

/// Flows A and B in the main window — one sheet
/// over Usage that is the form (flow A only), then the check, then the
/// result; the activity bar (source `.migration`) when it is sent to the
/// background; the apply and its result.
@MainActor
public final class DomainMigrationModel: ObservableObject {
  public enum Sheet: Equatable, Sendable { case form, checking, result }

  /// The sheet's state; nil: no sheet.
  @Published public internal(set) var sheet: Sheet?
  @Published public internal(set) var form: DomainMoveForm?
  /// The move being checked or reviewed.
  @Published public internal(set) var request: DomainMoveRequest?
  @Published public internal(set) var checking = DomainMoveChecking()
  @Published public internal(set) var summary: DomainMoveSummary?
  @Published public internal(set) var status: DomainMigrationStatus?
  @Published public internal(set) var allowedSources: Set<String> = []
  @Published public internal(set) var refusal: DomainMoveRefusal?
  /// Show Changes…'s text; non-nil shows the nested sheet.
  @Published public internal(set) var diff: String?
  /// Files to change, opened by project.
  @Published public var isFilesExpanded = false

  public let lock: MigrationLock
  let migrator: DomainMigrating
  /// The backends and their domains, read fresh for each entry.
  var backends: () async -> [DomainBackend] = { [] }
  /// The gallery's: Usage on `prefix`.
  var onShowUsage: (String) -> Void = { _ in }
  /// After an apply: every reader of the domains, the usage and the tree.
  var onFinished: () async -> Void = {}
  /// The panel's live read; Show Log on a run.
  var onProgress: () -> Void = {}
  var onShowLog: (Int64) -> Void = { _ in }

  private var cancellation: ExternalMigrationCancellation?
  private var isWorking = false

  public init(migrator: DomainMigrating, lock: MigrationLock) {
    self.migrator = migrator
    self.lock = lock
  }

  public var isBusy: Bool { lock.isBusy }

  // MARK: Entries

  /// Settings' Move to New Domain… (flow A): Usage on the Current, the
  /// form over it.
  public func beginNewDomain(backend slug: String) async {
    guard !lock.isBusy, let backend = await backends().first(where: { $0.slug == slug }) else { return }
    clearReady()
    onShowUsage(backend.current)
    form = DomainMoveForm(backend: slug, current: backend.current, oldDomains: backend.oldDomains)
    sheet = .form
    await loadFormProjects()
  }

  /// Settings' or Usage's Move N Links to Current… (flow B): Usage on that
  /// Old domain, the sheet straight at checking.
  public func beginMoveToCurrent(backend slug: String, oldDomain: String, links: Int = 0) async {
    guard !lock.isBusy, let backend = await backends().first(where: { $0.slug == slug }) else { return }
    clearReady()
    onShowUsage(oldDomain)
    let request = DomainMoveRequest(
      backend: slug, from: backend.current, to: backend.current, oldDomains: [oldDomain],
      keepOldDomains: false, projects: [], links: links)
    sheet = .checking
    await check(request)
  }

  // MARK: The form

  public func setTo(_ value: String) {
    guard var form else { return }
    form.to = value
    form.error = nil
    self.form = form
    Task { await validateTo() }
  }

  public func setAlsoMoveOld(_ on: Bool) {
    guard form != nil else { return }
    form?.alsoMoveOld = on
    Task { await loadFormProjects() }
  }

  public func setProject(_ slug: String, selected: Bool) {
    if selected { form?.selected.insert(slug) } else { form?.selected.remove(slug) }
  }

  func validateTo() async {
    guard let form else { return }
    let error = DomainCopy.toError(form.to, current: form.current, backend: form.backend, backends: await backends())
    guard self.form?.to == form.to else { return }
    self.form?.error = error
  }

  /// `referencingProjects`, all ticked.
  private func loadFormProjects() async {
    guard let form else { return }
    let prefixes = [form.current] + (form.alsoMoveOld ? form.oldDomains : [])
    let projects = (try? await migrator.projects(backend: form.backend, prefixes: prefixes, includeResolved: true)) ?? []
    guard self.form?.backend == form.backend, self.form?.alsoMoveOld == form.alsoMoveOld else { return }
    self.form?.projects = projects
    self.form?.selected = Set(projects.map(\.slug))
    self.form?.isLoading = false
  }

  /// Check Links.
  public func checkLinks() async {
    await validateTo()
    guard let form, form.canCheck, !lock.isBusy else { return }
    let to = DomainHost.normalized(form.to)
    let request = DomainMoveRequest(
      backend: form.backend, from: form.current, to: to,
      oldDomains: form.alsoMoveOld ? form.oldDomains : [], keepOldDomains: !form.alsoMoveOld,
      projects: form.projects.map(\.slug).filter(form.selected.contains),
      links: form.projects.filter { form.selected.contains($0.slug) }.reduce(0) { $0 + $1.links })
    sheet = .checking
    await check(request)
  }

  // MARK: Checking

  /// The preview with its progress, in the sheet and the bar.
  private func check(_ request: DomainMoveRequest) async {
    guard lock.take(.domain) else { return }
    isWorking = true
    self.request = request
    summary = nil
    refusal = nil
    diff = nil
    allowedSources = []
    isFilesExpanded = false
    checking = DomainMoveChecking()
    status = .checking(checking, host: request.toHost)
    onProgress()
    let cancellation = ExternalMigrationCancellation()
    self.cancellation = cancellation
    let projects = request.projects
    let (stream, continuation) = AsyncStream<RewritePreviewProgress>.makeStream()
    let consumer = Task { @MainActor [weak self] in
      for await progress in stream { self?.advance(progress, projects: projects) }
    }
    let outcome: Result<RewritePreviewResult, Error>
    do {
      outcome = .success(
        try await migrator.preview(
          backend: request.backend, to: request.to,
          // Flow B names its Old domains; flow A takes the core's default
          // (every Old one, or none with the switch off).
          from: request.keepsPrefix ? request.oldDomains : [],
          projects: request.projects, keepOldDomains: request.keepOldDomains, cancellation: cancellation,
          progress: { continuation.yield($0) }))
    } catch {
      outcome = .failure(error)
    }
    continuation.finish()
    await consumer.value
    self.cancellation = nil
    isWorking = false
    lock.release(.domain)
    switch outcome {
    case let .success(result) where result.state == .cancelled:
      // Cancel: back to Idle; the run stays `cancelled`.
      status = nil
      if sheet == .checking { sheet = nil }
    case let .success(result):
      await show(runID: result.runID)
    case let .failure(error):
      status = .done(ActivityItem(text: DomainCopy.message(error), phase: .failed))
      if sheet == .checking { sheet = nil }
    }
    onProgress()
  }

  private func advance(_ progress: RewritePreviewProgress, projects: [String]) {
    switch progress.phase {
    case .plan:
      let index = min(progress.done, max(projects.count - 1, 0))
      checking.phase = .planning(project: projects.isEmpty ? nil : projects[index])
    case .check:
      checking.phase = .checking(done: progress.done, total: progress.total)
      if progress.total > 0 {
        checking.fraction = max(checking.fraction, Double(progress.done) / Double(progress.total))
      }
    }
    if case .checking? = status, let request { status = .checking(checking, host: request.toHost) }
    onProgress()
  }

  /// The run's review: the sheet turns into the result when it is open,
  /// the bar says Ready either way.
  private func show(runID: Int64) async {
    do {
      let summary = DomainMoveSummary(try await migrator.review(runID: runID))
      self.summary = summary
      status =
        summary.failedCount > 0
        ? .failedCheck(runID: runID, failed: summary.failedCount)
        : .ready(runID: runID, links: summary.links)
      if sheet == .checking { sheet = .result }
    } catch {
      status = .done(ActivityItem(text: DomainCopy.message(error), phase: .failed, runID: runID))
      if sheet == .checking { sheet = nil }
    }
  }

  /// Continue in Background: the sheet goes, the bar keeps the progress.
  public func continueInBackground() {
    guard sheet == .checking else { return }
    sheet = nil
  }

  /// Checking's Cancel, and the bar's ✕ while checking.
  public func cancelCheck() {
    cancellation?.cancel()
  }

  /// Check Again: the same request, previewed anew.
  public func checkAgain() async {
    guard let request, !lock.isBusy else { return }
    sheet = .checking
    await check(request)
  }

  // MARK: The result

  /// Review…: the result sheet again.
  public func reviewAgain() {
    guard summary != nil else { return }
    switch status {
    case .ready?, .failedCheck?: sheet = .result
    default: break
    }
  }

  /// The bar's ✕: Cancel while checking, Discard while ready (the run
  /// stays).
  public func stopOrDiscard() {
    switch status {
    case .checking?: cancelCheck()
    case .ready?, .failedCheck?: discard()
    default: break
    }
  }

  public func discard() {
    sheet = nil
    summary = nil
    request = nil
    refusal = nil
    diff = nil
    allowedSources = []
    status = nil
    onProgress()
  }

  /// Cancel and Esc: the form goes; the result stays reviewable.
  public func dismissSheet() {
    switch sheet {
    case .form?:
      form = nil
      sheet = nil
    case .checking?:
      cancelCheck()
    case .result?:
      sheet = nil
      diff = nil
    case nil:
      break
    }
  }

  public func setSource(_ id: String, allowed: Bool) {
    if allowed { allowedSources.insert(id) } else { allowedSources.remove(id) }
  }

  public var isMoveEnabled: Bool {
    guard let summary, !lock.isBusy, refusal == nil else { return false }
    return summary.canMove(allowed: allowedSources)
  }

  public func showChanges() async {
    guard let runID = summary?.runID else { return }
    do {
      let text = try await migrator.diff(ofRun: runID)
      diff = text.isEmpty ? "No file changes." : text
    } catch {
      diff = UserFacingErrorMessage.resolve(error)
    }
  }

  public func closeChanges() { diff = nil }

  public func showLog() {
    guard let runID = summary?.runID else { return }
    onShowLog(runID)
  }

  // MARK: Apply

  public func confirm() async {
    guard isMoveEnabled, let summary, lock.take(.domain) else { return }
    isWorking = true
    sheet = nil
    diff = nil
    status = summary.keepsPrefix ? .rewriting(files: summary.review.files) : .changingPrefix
    onProgress()
    let (stream, continuation) = AsyncStream<RewriteApplyPhase>.makeStream()
    let consumer = Task { @MainActor [weak self] in
      for await phase in stream {
        switch phase {
        case .changingPrefix: self?.status = .changingPrefix
        case let .rewriting(files): self?.status = .rewriting(files: files)
        case let .rescanning(project): self?.status = .rescanning(project: project)
        }
        self?.onProgress()
      }
    }
    let outcome: Result<RewriteApplyResult, Error>
    do {
      outcome = .success(
        try await migrator.apply(
          fromRun: summary.runID, allowedSources: allowedSources, phase: { continuation.yield($0) }))
    } catch {
      outcome = .failure(error)
    }
    continuation.finish()
    await consumer.value
    isWorking = false
    lock.release(.domain)
    switch outcome {
    case let .success(result):
      status = DomainMigrationStatus.result(result, links: summary.links)
      self.summary = nil
      request = nil
      allowedSources = []
      onProgress()
      await onFinished()
    case let .failure(error):
      if let refusal = DomainMoveRefusal.make(error) {
        // The sheet comes back with the reason.
        self.refusal = refusal
        status = .ready(runID: summary.runID, links: summary.links)
        sheet = .result
      } else {
        status = .done(ActivityItem(text: DomainCopy.message(error), phase: .failed))
      }
      onProgress()
    }
  }

  /// A new move clears the last one's Ready.
  private func clearReady() {
    switch status {
    case .ready?, .failedCheck?, .done?: discard()
    default: break
    }
    form = nil
  }
}
