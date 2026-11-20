import AppKit
import CatalogCore
import Foundation
import GRDB

public struct BackupResult: Equatable, Sendable {
  public let assetCount: Int
  public let projectCount: Int
  public let backendCount: Int
  public let byteCount: Int
  public let destination: URL
}

public protocol BackupCreating: Sendable {
  func createBackup(at destination: URL) async throws -> BackupResult
}

public struct CatalogBackupWriter: BackupCreating {
  private let database: DatabasePool
  private let generatedAt: Date?

  public init(database: DatabasePool, generatedAt: Date? = nil) {
    self.database = database
    self.generatedAt = generatedAt
  }

  public func createBackup(at destination: URL) async throws -> BackupResult {
    let database = database
    let generatedAt = generatedAt
    return try await Task.detached {
      let backup = try CatalogBackups.create(from: database, now: generatedAt ?? Date())
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let json = String(decoding: try encoder.encode(backup), as: UTF8.self)
      let data = Data((json + "\n").utf8)
      try data.write(to: destination, options: .atomic)
      return BackupResult(
        assetCount: backup.tables.assets.count,
        projectCount: backup.tables.projects.count,
        backendCount: backup.tables.backends.count,
        byteCount: data.count,
        destination: destination)
    }.value
  }
}

/// Where a restore's sheets show: the main window for the
/// gallery's empty state and File ▸ Import Catalog Backup…, the Settings
/// window for Maintenance ▸ Backup.
public enum BackupPresenter: Equatable, Sendable {
  case gallery
  case settings
}

/// What the confirmation sheet shows: the file, when it was made, and how
/// much it holds.
public struct RestorePreview: Equatable, Sendable {
  public let fileName: String
  /// The backup's `generated_at`, as stored.
  public let generatedAt: String
  public let counts: CatalogTableCounts
  public let projectSlugs: [String]
  public let backendSlugs: [String]
  /// What the catalog holds now, when it is not empty: the restore replaces
  /// it, after the user confirms and is offered a backup of it first.
  public let replacing: CatalogTableCounts?
}

/// A decoded, version-checked backup waiting for the user's confirmation.
public struct PreparedRestore: Sendable {
  public let preview: RestorePreview
  let backup: CatalogBackup
}

/// What a finished restore wrote, and what it still needs on this Mac.
public struct RestoreOutcome: Equatable, Sendable {
  public let counts: CatalogTableCounts
  public let followUps: CatalogRestoreFollowUps
}

public protocol CatalogRestoring: Sendable {
  func isCatalogEmpty() async throws -> Bool
  /// Reads, decodes and version-checks a backup file; writes nothing.
  func prepare(_ file: URL) async throws -> PreparedRestore
  func restore(_ prepared: PreparedRestore) async throws -> RestoreOutcome
}

/// `CatalogBackups.restore`, the same call `pinax restore` makes, and its
/// follow-ups. The credential lookup is injected; the app's reads the
/// Keychain (an existence check, as Settings ▸ Backends does), tests pass
/// their own.
public struct CatalogRestorer: CatalogRestoring {
  private let database: DatabasePool
  private let credentialExists: @Sendable (String) throws -> Bool
  private let folderExists: @Sendable (String) -> Bool

  public init(
    database: DatabasePool,
    credentialExists: @escaping @Sendable (String) throws -> Bool,
    folderExists: @escaping @Sendable (String) -> Bool = { CatalogBackups.directoryExists($0) }
  ) {
    self.database = database
    self.credentialExists = credentialExists
    self.folderExists = folderExists
  }

  public func isCatalogEmpty() async throws -> Bool {
    let database = database
    return try await Task.detached { try CatalogBackups.counts(in: database).isEmpty }.value
  }

  public func prepare(_ file: URL) async throws -> PreparedRestore {
    let database = database
    return try await Task.detached {
      let backup = try CatalogBackups.decode(try Data(contentsOf: file))
      try CatalogBackups.validate(backup, for: database)
      let current = try CatalogBackups.counts(in: database)
      return PreparedRestore(
        preview: RestorePreview(
          fileName: file.lastPathComponent,
          generatedAt: backup.generatedAt,
          counts: CatalogTableCounts(backup.tables),
          projectSlugs: backup.tables.projects.map(\.slug),
          backendSlugs: backup.tables.backends.map(\.slug),
          replacing: current.isEmpty ? nil : current),
        backup: backup)
    }.value
  }

  public func restore(_ prepared: PreparedRestore) async throws -> RestoreOutcome {
    let database = database
    let credentialExists = credentialExists
    let folderExists = folderExists
    return try await Task.detached {
      let counts =
        if let confirmed = prepared.preview.replacing {
          try CatalogBackups.replace(prepared.backup, into: database, confirmed: confirmed)
        } else {
          try CatalogBackups.restore(prepared.backup, into: database)
        }
      let followUps = try CatalogBackups.followUps(
        in: database, credentialExists: credentialExists, folderExists: folderExists)
      return RestoreOutcome(counts: counts, followUps: followUps)
    }.value
  }
}

/// Where a restore that replaces a catalog stands: confirming the
/// replacement, then offered a backup of the catalog it replaces.
public enum RestoreStep: Equatable, Sendable {
  case confirm
  case offerSave
}

/// Settings ▸ Maintenance ▸ Backup, File ▸ Import / Export Catalog Backup…
/// and the empty catalog's Restore from Backup…: one
/// model, so all three entries are one action.
@MainActor
public final class BackupModel: ObservableObject {
  @Published public private(set) var isCreating = false
  @Published public private(set) var notice: String?
  /// Whether all ten catalog tables are empty; nil until first read.
  @Published public private(set) var isCatalogEmpty: Bool?
  @Published public private(set) var isRestoring = false
  /// The confirmation sheet's content, between the panel and Restore.
  @Published public private(set) var pendingRestore: RestorePreview?
  /// The Catalog Restored sheet's content.
  @Published public private(set) var restoredOutcome: RestoreOutcome?
  /// A file that would not restore, said before any confirmation.
  @Published public private(set) var restoreError: String?
  @Published public private(set) var restorePresenter: BackupPresenter = .gallery
  @Published public private(set) var restoreStep: RestoreStep = .confirm
  /// Why the backup offered before a replacement was not saved.
  @Published public private(set) var saveBeforeReplacingError: String?

  /// After a restore: the shell reloads everything that read the catalog.
  public var onRestored: (() async -> Void)?

  private let creator: BackupCreating
  private let chooseDestination: @MainActor (String) -> URL?
  private let restorer: CatalogRestoring?
  private let chooseBackupFile: @MainActor () -> URL?
  private let today: () -> Date
  private let isBusy: @MainActor () -> Bool
  private var prepared: PreparedRestore?

  public init(
    creator: BackupCreating,
    restorer: CatalogRestoring? = nil,
    chooseBackupFile: @escaping @MainActor () -> URL? = { nil },
    today: @escaping () -> Date = Date.init,
    isBusy: @escaping @MainActor () -> Bool = { false },
    chooseDestination: @escaping @MainActor (String) -> URL?
  ) {
    self.today = today
    self.isBusy = isBusy
    self.creator = creator
    self.restorer = restorer
    self.chooseBackupFile = chooseBackupFile
    self.chooseDestination = chooseDestination
  }

  /// Restore fills an empty catalog, or replaces one after asking twice.
  public var canRestore: Bool {
    restorer != nil && !isRestoring && !isCreating && pendingRestore == nil
  }

  /// File ▸ Export Catalog Backup…: off while there is nothing to export.
  public var canExport: Bool { isCatalogEmpty == false && !isCreating }

  /// Save Backup…'s suggested name: `pinax-backup-YYYY-MM-DD.json`,
  /// the local date.
  public nonisolated static func defaultFilename(
    for date: Date, timeZone: TimeZone = .current
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let day = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "pinax-backup-%04d-%02d-%02d.json", day.year ?? 0, day.month ?? 0, day.day ?? 0)
  }

  /// The backup offered before a replacement: `…-before-restore.json`, so
  /// the save panel never suggests the name of the file being restored.
  public nonisolated static func beforeRestoreFilename(
    for date: Date, timeZone: TimeZone = .current
  ) -> String {
    defaultFilename(for: date, timeZone: timeZone)
      .replacingOccurrences(of: ".json", with: "-before-restore.json")
  }

  public func create() async {
    guard !isCreating,
      let destination = chooseDestination(Self.defaultFilename(for: today()))
    else { return }
    isCreating = true
    defer { isCreating = false }
    do {
      let result = try await creator.createBackup(at: destination)
      notice = "Backed up \(result.assetCount) assets, \(result.projectCount) projects, and \(result.backendCount) backends (\(result.byteCount) bytes)."
    } catch {
      notice = UserFacingErrorMessage.resolve(error)
    }
  }

  public func refreshCatalogState() async {
    guard let restorer else { return }
    if let empty = try? await restorer.isCatalogEmpty() { isCatalogEmpty = empty }
  }

  /// The one action behind all three Restore entries: choose a file, check
  /// it, and ask. A file that will not restore is said here, with no
  /// confirmation sheet.
  public func beginRestore(presenter: BackupPresenter) async {
    await refreshCatalogState()
    guard canRestore, let restorer else { return }
    restorePresenter = presenter
    restoreError = nil
    restoreStep = .confirm
    saveBeforeReplacingError = nil
    guard !isBusy() else {
      restoreError = "Wait for uploads and usage scans to finish, then restore."
      return
    }
    guard let file = chooseBackupFile() else { return }
    do {
      let prepared = try await restorer.prepare(file)
      self.prepared = prepared
      pendingRestore = prepared.preview
    } catch {
      restoreError = Self.message(for: error)
    }
  }

  /// The confirmation's Restore / Replace…. Replacing a catalog asks once
  /// more, offering a backup of it, before anything is written.
  public func confirmRestore() async {
    guard let pendingRestore else { return }
    if pendingRestore.replacing != nil && restoreStep == .confirm {
      restoreStep = .offerSave
      return
    }
    await performRestore()
  }

  /// Save and Replace…: the save panel, a backup of the catalog about to be
  /// replaced, then the replacement. A cancelled panel or a failed backup
  /// replaces nothing.
  public func saveThenReplace() async {
    guard restoreStep == .offerSave, pendingRestore != nil, !isCreating,
      let destination = chooseDestination(Self.beforeRestoreFilename(for: today()))
    else { return }
    isCreating = true
    saveBeforeReplacingError = nil
    do {
      let result = try await creator.createBackup(at: destination)
      isCreating = false
      notice = "Backed up \(result.assetCount) assets, \(result.projectCount) projects, and \(result.backendCount) backends to \(destination.lastPathComponent)."
    } catch {
      isCreating = false
      saveBeforeReplacingError = UserFacingErrorMessage.resolve(error)
      return
    }
    await performRestore()
  }

  /// Replace Without Saving.
  public func replaceWithoutSaving() async {
    guard restoreStep == .offerSave else { return }
    await performRestore()
  }

  private func performRestore() async {
    guard let prepared, let restorer, !isRestoring else { return }
    isRestoring = true
    pendingRestore = nil
    self.prepared = nil
    defer { isRestoring = false }
    do {
      let outcome = try await restorer.restore(prepared)
      restoreStep = .confirm
      isCatalogEmpty = outcome.counts.isEmpty
      restoredOutcome = outcome
      await onRestored?()
    } catch {
      restoreStep = .confirm
      restoreError = Self.message(for: error)
      await refreshCatalogState()
    }
  }

  public func cancelRestore() {
    pendingRestore = nil
    prepared = nil
    restoreStep = .confirm
    saveBeforeReplacingError = nil
  }

  public func dismissRestoreError() { restoreError = nil }
  public func dismissRestored() { restoredOutcome = nil }

  public func isConfirmationPresented(by presenter: BackupPresenter) -> Bool {
    pendingRestore != nil && restorePresenter == presenter
  }

  public func isOutcomePresented(by presenter: BackupPresenter) -> Bool {
    restoredOutcome != nil && restorePresenter == presenter
  }

  public func isErrorPresented(by presenter: BackupPresenter) -> Bool {
    restoreError != nil && restorePresenter == presenter
  }

  private static func message(for error: Error) -> String {
    if error is DecodingError {
      return "This file is not a Pinax catalog backup, or it is damaged."
    }
    return UserFacingErrorMessage.resolve(error)
  }
}

@MainActor
public enum BackupSavePanel {
  public static func choose(defaultFilename: String) -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultFilename
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.message = "Save catalog backup"
    return panel.runModal() == .OK ? panel.url : nil
  }
}

/// The backup chooser behind all three Restore entries.
@MainActor
public enum BackupOpenPanel {
  public static func choose() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose a catalog backup"
    return panel.runModal() == .OK ? panel.url : nil
  }
}
