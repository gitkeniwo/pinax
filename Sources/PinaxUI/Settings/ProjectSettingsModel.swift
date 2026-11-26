import AppKit
import CatalogCore
import Foundation
import GRDB

/// One project as the settings pane shows it: the identity columns plus the
/// backend slug resolved from `backend_id` (`nil` = inherit / none).
public struct ProjectSettingsRow: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let slug: String
  public let name: String
  public let keyPrefix: String
  /// The stored template; nil is the default.
  public let keyTemplate: String?
  public let backendSlug: String?
  /// The folders Scan Now reads, as `meta` stores them.
  public let sources: [ProjectSource]
  /// The latest completed scan's start, as stored, and the references it
  /// found; nil before the first scan.
  public let lastScanAt: String?
  public let referenceCount: Int
  /// `meta.usageTracking`.
  public let usageTracking: UsageTracking

  public init(
    id: Int64, slug: String, name: String, keyPrefix: String, backendSlug: String?,
    sources: [ProjectSource] = [], lastScanAt: String? = nil, referenceCount: Int = 0,
    usageTracking: UsageTracking = .tracked, keyTemplate: String? = nil
  ) {
    self.id = id
    self.slug = slug
    self.name = name
    self.keyPrefix = keyPrefix
    self.keyTemplate = keyTemplate
    self.backendSlug = backendSlug
    self.sources = sources
    self.lastScanAt = lastScanAt
    self.referenceCount = referenceCount
    self.usageTracking = usageTracking
  }
}

/// Everything the pane displays, gathered in one read: every project with its
/// resolved backend, and the registered backend slugs for the picker.
public struct ProjectSettingsSnapshot: Equatable, Sendable {
  public let rows: [ProjectSettingsRow]
  public let backendSlugs: [String]
  /// Each backend's Current prefix, by slug.
  public let backendPrefixes: [String: String]

  public init(rows: [ProjectSettingsRow], backendSlugs: [String], backendPrefixes: [String: String] = [:]) {
    self.rows = rows
    self.backendSlugs = backendSlugs
    self.backendPrefixes = backendPrefixes
  }

  /// The prefix a project's new links use: its upload backend's Current —
  /// the one backend when it inherits and there is only one; nil without.
  public func linksPrefix(for row: ProjectSettingsRow) -> String? {
    let slug = row.backendSlug ?? (backendSlugs.count == 1 ? backendSlugs.first : nil)
    return slug.flatMap { backendPrefixes[$0] }
  }

  /// What a Switch or an added Old domain on
  /// `backend` scans — the projects with sources that upload to it.
  public func scanTargets(uploadingTo backend: String) -> [String] {
    rows.filter { row in
      !row.sources.isEmpty && (row.backendSlug ?? (backendSlugs.count == 1 ? backendSlugs.first : nil)) == backend
    }.map(\.slug)
  }
}

public struct NewProjectDraft: Equatable, Sendable {
  public var slug: String
  public var name: String
  public var keyPrefix: String
  public var backendSlug: String

  public init(slug: String = "", name: String = "", keyPrefix: String = "", backendSlug: String) {
    self.slug = slug
    self.name = name
    self.keyPrefix = keyPrefix
    self.backendSlug = backendSlug
  }
}

public enum ProjectAdditionPresenter: Equatable, Sendable {
  case settings
  case sidebar
}

/// The catalog writes the pane can perform, as one injectable seam: the app
/// gets the CatalogConfiguration-backed store, tests get an in-memory double,
/// and no test ever contacts the network or the keychain.
public protocol ProjectSettingsStore: Sendable {
  func snapshot() throws -> ProjectSettingsSnapshot
  func setKeyPrefix(_ keyPrefix: String, projectSlug: String) throws
  func setKeyTemplate(_ change: KeyTemplateChange, projectSlug: String) throws
  func setBackend(slug: String?, projectSlug: String) throws
  func addProject(_ draft: NewProjectDraft) async throws -> ProjectSettingsSnapshot
  func setSources(_ sources: [ProjectSource], projectSlug: String) throws
  func setUsageTracking(_ tracking: UsageTracking, projectSlug: String) throws
}

/// Production store. Every write goes through `CatalogConfiguration` — the
/// same functions the CLI uses; the pane adds no SQL of its own. `setBackend`
/// with `nil` is the picker's "inherit / none" choice and takes the explicit
/// clear path, because `setProject`'s `nil` backendSlug means "unchanged".
public struct CatalogProjectSettingsStore: ProjectSettingsStore {
  private let database: DatabasePool

  public init(database: DatabasePool) {
    self.database = database
  }

  public func snapshot() throws -> ProjectSettingsSnapshot {
    let projects = try CatalogConfiguration.projects(in: database)
    let backends = try CatalogConfiguration.backends(in: database)
    let slugByID = Dictionary(
      uniqueKeysWithValues: backends.compactMap { backend in
        backend.id.map { ($0, backend.slug) }
      })
    let summaries = Dictionary(
      uniqueKeysWithValues: try CatalogConfiguration.projectSummaries(in: database).map { ($0.slug, $0) })
    let rows = projects.compactMap { project -> ProjectSettingsRow? in
      guard let id = project.id else { return nil }
      let summary = summaries[project.slug]
      let settings = ProjectSettings(meta: project.meta)
      return ProjectSettingsRow(
        id: id,
        slug: project.slug,
        name: project.name,
        keyPrefix: project.keyPrefix,
        backendSlug: project.backendID.flatMap { slugByID[$0] },
        sources: settings.sources,
        lastScanAt: summary?.lastScanAt,
        referenceCount: summary?.liveUsageCount ?? 0,
        usageTracking: settings.usageTracking,
        keyTemplate: project.keyTemplate
      )
    }
    return ProjectSettingsSnapshot(
      rows: rows, backendSlugs: backends.map(\.slug),
      backendPrefixes: Dictionary(backends.map { ($0.slug, $0.urlPrefix) }, uniquingKeysWith: { first, _ in first }))
  }

  public func setKeyPrefix(_ keyPrefix: String, projectSlug: String) throws {
    _ = try CatalogConfiguration.setProject(
      slug: projectSlug, name: nil, keyPrefix: keyPrefix, backendSlug: nil, in: database
    )
  }

  public func setKeyTemplate(_ change: KeyTemplateChange, projectSlug: String) throws {
    _ = try CatalogConfiguration.setProject(
      slug: projectSlug, name: nil, keyPrefix: nil, backendSlug: nil, keyTemplate: change,
      in: database)
  }

  public func setBackend(slug: String?, projectSlug: String) throws {
    if let slug {
      _ = try CatalogConfiguration.setProject(
        slug: projectSlug, name: nil, keyPrefix: nil, backendSlug: slug, in: database
      )
    } else {
      _ = try CatalogConfiguration.clearProjectBackend(slug: projectSlug, in: database)
    }
  }

  public func setSources(_ sources: [ProjectSource], projectSlug: String) throws {
    try CatalogConfiguration.setProjectSources(slug: projectSlug, sources, in: database)
  }

  public func setUsageTracking(_ tracking: UsageTracking, projectSlug: String) throws {
    try CatalogConfiguration.setUsageTracking(slug: projectSlug, tracking, in: database)
  }

  public func addProject(_ draft: NewProjectDraft) async throws -> ProjectSettingsSnapshot {
    let database = database
    return try await Task.detached {
      _ = try CatalogConfiguration.addProject(
        slug: draft.slug,
        name: draft.name,
        keyPrefix: draft.keyPrefix,
        backendSlug: draft.backendSlug,
        to: database)
      return try CatalogProjectSettingsStore(database: database).snapshot()
    }.value
  }
}

/// The model behind the Projects settings pane. Display is strictly
/// read-only: `load` only reads, and a write happens solely
/// when the user commits one — the prefix's Set action or a picker choice.
/// After every committed write the snapshot is re-read so the pane shows the
/// row as stored, normalization included.
@MainActor
public final class ProjectSettingsModel: ObservableObject {
  public static let backendRequiredMessage =
    "Add a backend in Settings > Backends before creating a project."

  @Published public private(set) var snapshot: ProjectSettingsSnapshot?
  @Published public private(set) var saveError: String?
  @Published public private(set) var additionDraft: NewProjectDraft?
  @Published public private(set) var additionPresenter: ProjectAdditionPresenter?
  @Published public private(set) var isAddingProject = false

  public var onAdditionCommitted:
    ((ProjectAdditionPresenter, ProjectSettingsRow) async -> Void)?

  /// The project the pane should select next time it shows — Add Source…
  /// and Open Project Settings… on the reports set it.
  @Published public var requestedSlug: String?

  /// Scan Now, as the app installs it: `UsageSyncModel.scanNow` for one
  /// project, presented in the Settings window.
  public var scanNow: ((String) -> Void)?
  /// Scan Now's activity, pushed by the app: the Sources group shows the
  /// running count and holds Scan Now while one runs.
  @Published public var scanActivity: UsageScanActivity?
  /// After a committed Sources write: the reports' empty states pick their
  /// action by whether a project has sources.
  public var onSourcesChange: (() -> Void)?
  /// After a project's Usage choice is written: Orphans
  /// counts not-tracked projects differently, so the reports re-read.
  public var onUsageTrackingChange: (() -> Void)?

  private let store: ProjectSettingsStore
  /// The directory-only chooser: + and Locate…. The app's is
  /// an `NSOpenPanel`; tests inject one that never opens a window.
  private let chooseFolder: @MainActor (_ startingAt: String?) -> URL?

  public init(
    store: ProjectSettingsStore,
    chooseFolder: @escaping @MainActor (_ startingAt: String?) -> URL? = SourceFolderOpenPanel.choose
  ) {
    self.store = store
    self.chooseFolder = chooseFolder
  }

  // MARK: - Sources

  /// + : a chosen folder becomes a new source with the default label and
  /// include. Nothing is written when the chooser is cancelled.
  public func addSource(toProject slug: String) {
    guard let row = row(slug), let url = chooseFolder(nil) else { return }
    let path = url.standardizedFileURL.path
    let label = ProjectSource.defaultLabel(forPath: path, existing: row.sources.map(\.label))
    writeSources(row.sources + [ProjectSource(label: label, path: path)], slug)
  }

  /// − : removes the source with this label.
  public func removeSource(label: String, fromProject slug: String) {
    guard let row = row(slug) else { return }
    writeSources(row.sources.filter { $0.label != label }, slug)
  }

  /// The selected row's fields, committed together. Include and Exclude are
  /// comma-separated; an Include equal to the default stores as empty.
  public func updateSource(
    label: String, inProject slug: String, newLabel: String, include: String, exclude: String
  ) {
    guard let row = row(slug) else { return }
    let includePatterns = Self.patterns(include)
    writeSources(
      row.sources.map { source in
        guard source.label == label else { return source }
        var updated = source
        updated.label = newLabel.trimmingCharacters(in: .whitespaces)
        updated.include = includePatterns == ProjectSource.defaultInclude ? [] : includePatterns
        updated.exclude = Self.patterns(exclude)
        return updated
      }, slug)
  }

  /// Locate… : points a source whose folder is gone at a new one, keeping
  /// its label and patterns.
  public func locateSource(label: String, inProject slug: String) {
    guard let row = row(slug),
      let source = row.sources.first(where: { $0.label == label }),
      let url = chooseFolder(source.path)
    else { return }
    writeSources(
      row.sources.map { candidate in
        guard candidate.label == label else { return candidate }
        var updated = candidate
        updated.path = url.standardizedFileURL.path
        return updated
      }, slug)
  }

  /// Whether a source's folder is there — the row's Locate… state.
  public nonisolated static func folderExists(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// The Sources group's last line: "Never scanned", or "Last scan 2
  /// days ago · 312 references".
  public nonisolated static func scanStatus(
    for row: ProjectSettingsRow, now: Date = Date(), locale: Locale = .current
  ) -> String {
    guard let lastScanAt = row.lastScanAt else { return "Never scanned" }
    let count = row.referenceCount
    return "Last scan \(PinaxFormat.relativeDate(lastScanAt, now: now, locale: locale))"
      + " · \(count) \(count == 1 ? "reference" : "references")"
  }

  /// "a, b ,c" → ["a", "b", "c"]. A comma inside a pattern's braces is part
  /// of the pattern: "*.{md,mdx}, docs/**" → ["*.{md,mdx}", "docs/**"].
  /// Braces pair as `PathGlob` reads them.
  public nonisolated static func patterns(_ text: String) -> [String] {
    var pieces: [Substring] = []
    var start = text.startIndex
    var index = start
    while index < text.endIndex {
      if text[index] == "{", let close = text[index...].firstIndex(of: "}") {
        index = close
      } else if text[index] == "," {
        pieces.append(text[start..<index])
        start = text.index(after: index)
      }
      index = text.index(after: index)
    }
    pieces.append(text[start...])
    return pieces
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func row(_ slug: String) -> ProjectSettingsRow? {
    snapshot?.rows.first { $0.slug == slug }
  }

  private func writeSources(_ sources: [ProjectSource], _ slug: String) {
    commit { try store.setSources(sources, projectSlug: slug) }
    if saveError == nil { onSourcesChange?() }
  }

  public func load() {
    do {
      snapshot = try store.snapshot()
      saveError = nil
    } catch {
      saveError = UserFacingErrorMessage.resolve(error)
    }
  }

  public func setKeyPrefix(_ keyPrefix: String, forProject slug: String) {
    commit { try store.setKeyPrefix(keyPrefix, projectSlug: slug) }
  }

  /// Set (or Return) on the key template.
  /// `CatalogConfiguration` validates it again and stores the default as NULL.
  public func setKeyTemplate(_ template: String, forProject slug: String) {
    commit { try store.setKeyTemplate(.set(template), projectSlug: slug) }
  }

  /// Reset to Default writes NULL.
  public func resetKeyTemplate(forProject slug: String) {
    commit { try store.setKeyTemplate(.reset, projectSlug: slug) }
  }

  public func setBackend(slug: String?, forProject projectSlug: String) {
    commit { try store.setBackend(slug: slug, projectSlug: projectSlug) }
  }

  /// The Usage picker's write; the reports re-read after it.
  public func setUsageTracking(_ tracking: UsageTracking, forProject slug: String) {
    commit { try store.setUsageTracking(tracking, projectSlug: slug) }
    if saveError == nil { onUsageTrackingChange?() }
  }

  public var canBeginAddition: Bool {
    snapshot?.backendSlugs.isEmpty == false
  }

  public var canSubmitAddition: Bool {
    guard let draft = additionDraft else { return false }
    return !draft.slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !draft.backendSlug.isEmpty
  }

  public func beginAddition(presenter: ProjectAdditionPresenter = .settings) {
    guard let backendSlug = snapshot?.backendSlugs.first else { return }
    additionDraft = NewProjectDraft(backendSlug: backendSlug)
    additionPresenter = presenter
    saveError = nil
  }

  public func isAdditionPresented(by presenter: ProjectAdditionPresenter) -> Bool {
    additionDraft != nil && additionPresenter == presenter
  }

  public func updateAdditionDraft(_ update: (inout NewProjectDraft) -> Void) {
    guard var draft = additionDraft else { return }
    update(&draft)
    additionDraft = draft
  }

  public func cancelAddition(presenter: ProjectAdditionPresenter = .settings) {
    guard additionPresenter == presenter else { return }
    additionDraft = nil
    additionPresenter = nil
    saveError = nil
  }

  public func submitAddition(presenter: ProjectAdditionPresenter = .settings) async {
    guard additionPresenter == presenter, let draft = additionDraft, canSubmitAddition else {
      return
    }
    isAddingProject = true
    defer { isAddingProject = false }
    do {
      let existingIDs = Set(snapshot?.rows.map(\.id) ?? [])
      let updatedSnapshot = try await store.addProject(draft)
      snapshot = updatedSnapshot
      additionDraft = nil
      additionPresenter = nil
      saveError = nil
      if let created = updatedSnapshot.rows.first(where: { !existingIDs.contains($0.id) }) {
        await onAdditionCommitted?(presenter, created)
      }
    } catch {
      saveError = UserFacingErrorMessage.resolve(error)
    }
  }

  private func commit(_ write: () throws -> Void) {
    do {
      try write()
      snapshot = try store.snapshot()
      saveError = nil
    } catch {
      saveError = UserFacingErrorMessage.resolve(error)
    }
  }
}

/// The directory-only chooser behind the Sources table's + and Locate….
@MainActor
public enum SourceFolderOpenPanel {
  public static func choose(startingAt path: String?) -> URL? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.message = "Choose a source folder"
    if let path {
      panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    }
    return panel.runModal() == .OK ? panel.url : nil
  }
}
