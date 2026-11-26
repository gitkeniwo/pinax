import AppKit
import CatalogCore
import Foundation
import GRDB

public protocol UsageSyncing: Sendable {
  func projects() async throws -> [String]
  func sync(documentAt source: URL, project: String, allowEmpty: Bool) async throws
    -> UsageSyncResult
  /// Runs the built-in scanner over the project's sources and
  /// ingests the result. `progress` gets the running count of files read.
  func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome
}

/// One Scan Now's result: the sync's, plus the files the scanner read and
/// skipped.
public struct UsageScanOutcome: Equatable, Sendable {
  public let sync: UsageSyncResult
  public let files: Int
  public let skipped: Int

  public init(sync: UsageSyncResult, files: Int, skipped: Int) {
    self.sync = sync
    self.files = files
    self.skipped = skipped
  }
}

/// What the status bar's right side says about Scan Now: the running
/// count, the finished scan's references, or the failure as it came.
public enum UsageScanActivity: Equatable, Sendable {
  case running(project: String, files: Int)
  case finished(project: String, references: Int)
  case failed(String)
  /// An automatic scan met a command that has not been allowed to run.
  case commandNeedsApproval(project: String, label: String)
  /// An automatic scan found nothing where the last one found references,
  /// and left the catalog as it was.
  case emptyScanHeld(project: String, previousFoundCount: Int)
  /// Scan All: every project was tried; the ones that
  /// failed are listed, each with its own reason.
  case summary(projects: Int, failures: [UsageScanFailure])

  public var text: String {
    switch self {
    case let .running(project, files):
      return "Scanning \(project)… \(files) \(files == 1 ? "file" : "files")"
    case let .finished(project, references):
      return "Scanned \(project): \(references) \(references == 1 ? "reference" : "references")"
    case let .failed(message):
      return message
    case let .commandNeedsApproval(project, label):
      return "\(project): command “\(label)” needs confirmation. Open Settings…"
    case let .emptyScanHeld(project, previous):
      return "\(project) found nothing where the last scan found \(previous). Scan Now to accept."
    case let .summary(projects, failures):
      let scanned = projects - failures.count
      let head =
        failures.isEmpty
        ? "Scanned \(PinaxFormat.count(projects, singular: "project"))"
        : "Scanned \(scanned) of \(PinaxFormat.count(projects, singular: "project"))"
      guard !failures.isEmpty else { return head }
      let listed = failures.map { "\($0.project): \($0.message)" }.joined(separator: "; ")
      return "\(head) · Failed: \(listed)"
    }
  }

  public var isFailure: Bool {
    switch self {
    case .failed, .commandNeedsApproval, .emptyScanHeld: return true
    case let .summary(_, failures): return !failures.isEmpty
    default: return false
    }
  }
}

/// One project Scan All could not scan, and why.
public struct UsageScanFailure: Equatable, Sendable {
  public let project: String
  public let message: String

  public init(project: String, message: String) {
    self.project = project
    self.message = message
  }
}

/// Where the empty-scan confirmation shows: the Settings window (the
/// Maintenance import and the Projects page) or the main window (a report's
/// empty state).
public enum UsageSyncPresenter: Equatable, Sendable {
  case settings
  case gallery
}

/// A command waiting for the user to allow it, as it would run.
public struct PendingCommandApproval: Equatable, Sendable {
  public let project: String
  public let label: String
  public let command: String
  public let workingDirectory: String

  public init(project: String, label: String, command: String, workingDirectory: String) {
    self.project = project
    self.label = label
    self.command = command
    self.workingDirectory = workingDirectory
  }

  var source: ProjectSource {
    ProjectSource(label: label, command: command, workingDirectory: workingDirectory)
  }
}

/// A scan stopped before anything ran, at a command not yet allowed.
public struct CommandApprovalRequired: Error, Equatable, Sendable {
  public let approval: PendingCommandApproval

  public init(_ approval: PendingCommandApproval) {
    self.approval = approval
  }
}

/// The source a scan's policy turned down.
private final class RefusedSource: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ProjectSource?

  var source: ProjectSource? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

public struct CatalogUsageSynchronizer: UsageSyncing {
  private let database: DatabasePool
  private let approvals: CommandApprovalStore?
  private let runner: CommandSourceRunning

  /// Without `approvals` no command runs.
  public init(
    database: DatabasePool, approvals: CommandApprovalStore? = nil,
    runner: CommandSourceRunning = ShellCommandRunner()
  ) {
    self.database = database
    self.approvals = approvals
    self.runner = runner
  }

  public func projects() async throws -> [String] {
    let database = database
    return try await Task.detached {
      try CatalogConfiguration.projects(in: database).map(\.slug)
    }.value
  }

  public func sync(
    documentAt source: URL, project: String, allowEmpty: Bool
  ) async throws -> UsageSyncResult {
    let database = database
    return try await Task.detached {
      let document = try JSONDecoder().decode(UsageDocument.self, from: Data(contentsOf: source))
      return try CatalogUsage.sync(
        document, project: project, in: database, allowEmpty: allowEmpty)
    }.value
  }

  public func scan(
    project: String, allowEmpty: Bool, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> UsageScanOutcome {
    let database = database
    let approvals = approvals
    let runner = runner
    return try await Task.detached {
      // The refused source is kept as the scanner saw it, so what gets
      // confirmed is exactly what was turned down.
      let refused = RefusedSource()
      let policy = CommandSourcePolicy(allowsInProject: { slug, source in
        let allowed = approvals?.isApproved(project: slug, source: source) == true
        if !allowed { refused.source = source }
        return allowed
      })
      let scan: UsageScanResult
      do {
        scan = try UsageScanner.scan(
          project: project, in: database, commands: policy, runner: runner, progress: progress)
      } catch CommandSourceError.commandNotAllowed(let label) {
        guard let source = refused.source else {
          throw CommandSourceError.commandNotAllowed(label: label)
        }
        throw CommandApprovalRequired(
          PendingCommandApproval(
            project: project, label: source.label, command: source.command,
            workingDirectory: source.workingDirectory))
      }
      let sync = try CatalogUsage.sync(
        scan.document, project: project, in: database, allowEmpty: allowEmpty)
      return UsageScanOutcome(sync: sync, files: scan.files, skipped: scan.skipped)
    }.value
  }
}

/// A waiting scan that another request for the same one joins.
private enum QueuedScan: Hashable {
  case automatic(String)
  case manual([String], UsageSyncPresenter)
}

/// The empty scan waiting for confirmation: a chosen document, or one
/// project's Scan Now.
private enum PendingEmptyUsageSync: Sendable {
  case document(source: URL, project: String)
  case scan(project: String)
}

@MainActor
public final class UsageSyncModel: ObservableObject {
  @Published public private(set) var projects: [String]?
  @Published public var selectedProject: String?
  @Published public private(set) var result: UsageSyncResult?
  /// True while any scan or import is running or waiting its turn.
  @Published public private(set) var isSyncing = false
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var requiresEmptyScanConfirmation = false
  @Published public private(set) var emptyScanPresenter: UsageSyncPresenter = .settings
  /// The command a Scan Now stopped at. Only a scan the user asked for sets it.
  @Published public private(set) var pendingCommandApproval: PendingCommandApproval?
  @Published public private(set) var commandApprovalPresenter: UsageSyncPresenter = .settings
  @Published public private(set) var scanActivity: UsageScanActivity? {
    didSet { onScanActivityChange?(scanActivity) }
  }

  /// The app installs these: the status bar's sentence, and the reports'
  /// reload once a scan has been ingested.
  public var onScanActivityChange: ((UsageScanActivity?) -> Void)?
  public var onScanCompleted: (() async -> Void)?

  private let synchronizer: UsageSyncing
  private let chooseSource: @MainActor () -> URL?
  private var pendingEmptySync: PendingEmptyUsageSync?
  private let approvals: CommandApprovalStore?
  /// Everything that writes usage runs one at a time, in the order asked.
  private var lastInLine: Task<Void, Never>?
  private var waiting: [QueuedScan: Task<Void, Never>] = [:]
  private var inLine = 0

  /// Scans and imports running or waiting.
  var lengthOfLine: Int { inLine }

  public init(
    synchronizer: UsageSyncing,
    approvals: CommandApprovalStore? = nil,
    chooseSource: @escaping @MainActor () -> URL?
  ) {
    self.synchronizer = synchronizer
    self.approvals = approvals
    self.chooseSource = chooseSource
  }

  public func loadProjects() async {
    do {
      let projects = try await synchronizer.projects()
      self.projects = projects
      if selectedProject == nil || !projects.contains(selectedProject ?? "") {
        selectedProject = projects.first
      }
      errorMessage = nil
    } catch {
      projects = nil
      errorMessage = message(for: error)
    }
  }

  public func chooseAndSync() async {
    guard !isSyncing, let project = selectedProject, let source = chooseSource() else { return }
    await enqueue { model in
      model.emptyScanPresenter = .settings
      await model.sync(source: source, project: project, allowEmpty: false)
    }.value
  }

  /// The one Scan Now. Every entry point — the Projects page,
  /// the reports' empty states, the Project menu — calls this. Scans run
  /// one project at a time off the main thread. One project: an empty scan
  /// over a nonempty one stops at the same confirmation the document import
  /// uses. Several (Scan All): every project is tried, and the
  /// status line then lists each one that failed — an empty scan among
  /// them is a failure there, to be confirmed by scanning that project alone.
  /// While another scan runs this one waits its turn; asking again for the
  /// same waiting scan joins it. Returns once the scan has run.
  public func scanNow(projects: [String], presenter: UsageSyncPresenter) async {
    guard !projects.isEmpty else { return }
    await enqueue(.manual(projects, presenter)) { model in
      if projects.count == 1 {
        await model.scan(projects[0], allowEmpty: false, presenter: presenter)
      } else {
        await model.scanAll(projects)
      }
    }.value
  }

  /// A scan nobody asked for just now: a watched folder changed, or the
  /// schedule came due. It waits in the same line as Scan Now, one per
  /// project at most. It never asks anything: an empty scan, a command not
  /// yet allowed and every failure only reach `scanActivity`, and the
  /// catalog stays as it was.
  public func scanAutomatically(project: String, reason: UsageAutoScanReason) async {
    await enqueue(.automatic(project)) { model in
      await model.automaticScan(project)
    }.value
  }

  /// Something that kept an automatic scan from being possible at all.
  func reportAutomaticFailure(project: String, message: String) {
    enqueue { model in model.scanActivity = .failed("\(project): \(message)") }
  }

  public func isCommandApprovalPresented(by presenter: UsageSyncPresenter) -> Bool {
    pendingCommandApproval != nil && commandApprovalPresenter == presenter
  }

  public func cancelCommand() {
    pendingCommandApproval = nil
  }

  /// Allows the pending command on this Mac and scans its project again,
  /// which stops at the project's next command not yet allowed, if any.
  public func confirmCommand() async {
    guard let pending = pendingCommandApproval, let approvals else { return }
    pendingCommandApproval = nil
    approvals.approve(project: pending.project, source: pending.source)
    await scanNow(projects: [pending.project], presenter: commandApprovalPresenter)
  }

  public func isEmptyScanConfirmationPresented(by presenter: UsageSyncPresenter) -> Bool {
    requiresEmptyScanConfirmation && emptyScanPresenter == presenter
  }

  public func cancelEmptyScan() {
    pendingEmptySync = nil
    requiresEmptyScanConfirmation = false
  }

  public func confirmEmptyScan() async {
    guard let pendingEmptySync else { return }
    self.pendingEmptySync = nil
    requiresEmptyScanConfirmation = false
    let presenter = emptyScanPresenter
    await enqueue { model in
      switch pendingEmptySync {
      case let .document(source, project):
        await model.sync(source: source, project: project, allowEmpty: true)
      case let .scan(project):
        await model.scan(project, allowEmpty: true, presenter: presenter)
      }
    }.value
  }

  /// Puts `work` at the end of the line. With a `key`, work already waiting
  /// under it stands for this request too.
  @discardableResult
  private func enqueue(
    _ key: QueuedScan? = nil, _ work: @escaping @MainActor (UsageSyncModel) async -> Void
  ) -> Task<Void, Never> {
    if let key, let task = waiting[key] { return task }
    inLine += 1
    isSyncing = true
    let previous = lastInLine
    let task = Task { @MainActor in
      await previous?.value
      if let key { self.waiting[key] = nil }
      await work(self)
      self.inLine -= 1
      if self.inLine == 0 {
        self.isSyncing = false
        self.lastInLine = nil
      }
    }
    lastInLine = task
    if let key { waiting[key] = task }
    return task
  }

  private func automaticScan(_ project: String) async {
    do {
      let outcome = try await runScan(project, allowEmpty: false)
      scanActivity = .finished(project: project, references: outcome.sync.foundCount)
      await onScanCompleted?()
    } catch let UsageCatalogError.emptyScanRejected(previousFoundCount) {
      scanActivity = .emptyScanHeld(project: project, previousFoundCount: previousFoundCount)
    } catch let error as CommandApprovalRequired {
      scanActivity = .commandNeedsApproval(project: project, label: error.approval.label)
    } catch {
      scanActivity = .failed("\(project): \(message(for: error))")
    }
  }

  private func scan(_ project: String, allowEmpty: Bool, presenter: UsageSyncPresenter) async {
    emptyScanPresenter = presenter
    do {
      let outcome = try await runScan(project, allowEmpty: allowEmpty)
      record(outcome)
      scanActivity = .finished(project: project, references: outcome.sync.foundCount)
      await onScanCompleted?()
    } catch let error as CommandApprovalRequired {
      commandApprovalPresenter = presenter
      pendingCommandApproval = error.approval
      scanActivity = nil
    } catch let error as UsageCatalogError {
      if case .emptyScanRejected = error, !allowEmpty {
        pendingEmptySync = .scan(project: project)
        requiresEmptyScanConfirmation = true
        scanActivity = nil
      } else {
        scanActivity = .failed(error.description)
      }
    } catch {
      scanActivity = .failed(message(for: error))
    }
  }

  private func scanAll(_ projects: [String]) async {
    var failures: [UsageScanFailure] = []
    for project in projects {
      do {
        record(try await runScan(project, allowEmpty: false))
      } catch let UsageCatalogError.emptyScanRejected(previousFoundCount) {
        failures.append(UsageScanFailure(
          project: project,
          message: "found nothing where the last scan found \(previousFoundCount); scan it alone to accept"))
      } catch {
        failures.append(UsageScanFailure(project: project, message: message(for: error)))
      }
    }
    scanActivity = .summary(projects: projects.count, failures: failures)
    if failures.count < projects.count { await onScanCompleted?() }
  }

  /// One project's scan and ingest, with the running count on the status bar.
  private func runScan(_ project: String, allowEmpty: Bool) async throws -> UsageScanOutcome {
    scanActivity = .running(project: project, files: 0)
    return try await synchronizer.scan(
      project: project, allowEmpty: allowEmpty,
      progress: { files in
        Task { @MainActor [weak self] in
          guard case .running(project, let shown)? = self?.scanActivity, shown < files
          else { return }
          self?.scanActivity = .running(project: project, files: files)
        }
      })
  }

  /// A scan the user asked for also fills in the Maintenance page's result.
  private func record(_ outcome: UsageScanOutcome) {
    result = outcome.sync
    errorMessage = nil
  }

  private func sync(source: URL, project: String, allowEmpty: Bool) async {
    do {
      result = try await synchronizer.sync(
        documentAt: source, project: project, allowEmpty: allowEmpty)
      errorMessage = nil
    } catch let error as UsageCatalogError {
      if case .emptyScanRejected = error, !allowEmpty {
        pendingEmptySync = .document(source: source, project: project)
        requiresEmptyScanConfirmation = true
        errorMessage = nil
      } else {
        errorMessage = error.description
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func message(for error: Error) -> String {
    if let error = error as? UsageCatalogError {
      return error.description
    }
    if let error = error as? UsageScanError {
      return error.description
    }
    if let error = error as? CommandSourceError {
      return error.description
    }
    if let error = error as? CommandApprovalRequired {
      return CommandSourceError.commandNotAllowed(label: error.approval.label).description
    }
    if let error = error as? LocalizedError, let description = error.errorDescription {
      return description
    }
    return UserFacingErrorMessage.resolve(error)
  }
}

@MainActor
enum UsageDocumentOpenPanel {
  static func choose() -> URL? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.json]
    panel.message = "Choose a usage document"
    return panel.runModal() == .OK ? panel.url : nil
  }
}
