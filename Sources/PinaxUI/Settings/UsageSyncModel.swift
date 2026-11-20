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
    case .failed: return true
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

public struct CatalogUsageSynchronizer: UsageSyncing {
  private let database: DatabasePool

  public init(database: DatabasePool) {
    self.database = database
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
    return try await Task.detached {
      let scan = try UsageScanner.scan(project: project, in: database, progress: progress)
      let sync = try CatalogUsage.sync(
        scan.document, project: project, in: database, allowEmpty: allowEmpty)
      return UsageScanOutcome(sync: sync, files: scan.files, skipped: scan.skipped)
    }.value
  }
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
  @Published public private(set) var isSyncing = false
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var requiresEmptyScanConfirmation = false
  @Published public private(set) var emptyScanPresenter: UsageSyncPresenter = .settings
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

  public init(
    synchronizer: UsageSyncing,
    chooseSource: @escaping @MainActor () -> URL?
  ) {
    self.synchronizer = synchronizer
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
    emptyScanPresenter = .settings
    await sync(source: source, project: project, allowEmpty: false)
  }

  /// The one Scan Now. Every entry point — the Projects page,
  /// the reports' empty states, the Project menu — calls this. Scans run
  /// one project at a time off the main thread. One project: an empty scan
  /// over a nonempty one stops at the same confirmation the document import
  /// uses. Several (Scan All): every project is tried, and the
  /// status line then lists each one that failed — an empty scan among
  /// them is a failure there, to be confirmed by scanning that project alone.
  public func scanNow(projects: [String], presenter: UsageSyncPresenter) async {
    guard !isSyncing, !projects.isEmpty else { return }
    emptyScanPresenter = presenter
    if projects.count == 1 {
      await scan(projects[0], allowEmpty: false)
    } else {
      await scanAll(projects)
    }
  }

  public func isEmptyScanConfirmationPresented(by presenter: UsageSyncPresenter) -> Bool {
    requiresEmptyScanConfirmation && emptyScanPresenter == presenter
  }

  public func cancelEmptyScan() {
    pendingEmptySync = nil
    requiresEmptyScanConfirmation = false
  }

  public func confirmEmptyScan() async {
    guard !isSyncing, let pendingEmptySync else { return }
    self.pendingEmptySync = nil
    requiresEmptyScanConfirmation = false
    switch pendingEmptySync {
    case let .document(source, project):
      await sync(source: source, project: project, allowEmpty: true)
    case let .scan(project):
      await scan(project, allowEmpty: true)
    }
  }

  private func scan(_ project: String, allowEmpty: Bool) async {
    isSyncing = true
    defer { isSyncing = false }
    do {
      let outcome = try await runScan(project, allowEmpty: allowEmpty)
      scanActivity = .finished(project: project, references: outcome.sync.foundCount)
      await onScanCompleted?()
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
    isSyncing = true
    defer { isSyncing = false }
    var failures: [UsageScanFailure] = []
    for project in projects {
      do {
        _ = try await runScan(project, allowEmpty: false)
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
    let outcome = try await synchronizer.scan(
      project: project, allowEmpty: allowEmpty,
      progress: { files in
        Task { @MainActor [weak self] in
          guard case .running(project, let shown)? = self?.scanActivity, shown < files
          else { return }
          self?.scanActivity = .running(project: project, files: files)
        }
      })
    result = outcome.sync
    errorMessage = nil
    return outcome
  }

  private func sync(source: URL, project: String, allowEmpty: Bool) async {
    isSyncing = true
    defer { isSyncing = false }
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
