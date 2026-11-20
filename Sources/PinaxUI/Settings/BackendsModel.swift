import CatalogCore
import Combine
import Foundation
import GRDB

public struct BackendListRow: Identifiable, Equatable, Sendable {
  public var id: String { slug }
  public let slug: String
  public let kind: String
  public let bucket: String
  public let urlPrefix: String

  public init(slug: String, kind: String, bucket: String, urlPrefix: String) {
    self.slug = slug
    self.kind = kind
    self.bucket = bucket
    self.urlPrefix = urlPrefix
  }
}

public struct BackendDetails: Equatable, Sendable {
  public let slug: String
  public let kind: String
  public let endpoint: String
  public let bucket: String
  public let region: String
  public let urlPrefix: String
  public let keychainReference: String
  public let credentialsConfigured: Bool
  /// Retired prefixes, oldest first (Old Domains).
  public let oldDomains: [String]

  public init(
    slug: String, kind: String, endpoint: String, bucket: String, region: String,
    urlPrefix: String, keychainReference: String, credentialsConfigured: Bool,
    oldDomains: [String] = []
  ) {
    self.slug = slug
    self.kind = kind
    self.endpoint = endpoint
    self.bucket = bucket
    self.region = region
    self.urlPrefix = urlPrefix
    self.keychainReference = keychainReference
    self.credentialsConfigured = credentialsConfigured
    self.oldDomains = oldDomains
  }
}

public struct NewBackendDraft: Equatable, Sendable {
  public var slug: String
  public var endpoint: String
  public var bucket: String
  public var region: String
  public var urlPrefix: String
  public var keychainReference: String

  public init(
    slug: String = "", endpoint: String = "", bucket: String = "", region: String = "auto",
    urlPrefix: String = "", keychainReference: String = "backend."
  ) {
    self.slug = slug
    self.endpoint = endpoint
    self.bucket = bucket
    self.region = region
    self.urlPrefix = urlPrefix
    self.keychainReference = keychainReference
  }
}

public struct BackendPrefixUpdate: Equatable, Sendable {
  public let details: BackendDetails
  public let retiredOldPrefix: Bool
}

public protocol BackendsReading: Sendable {
  func backends() async throws -> [BackendListRow]
  func backend(slug: String) async throws -> BackendDetails
}

public protocol BackendsWriting: Sendable {
  func addBackend(_ draft: NewBackendDraft) async throws
  func setURLPrefix(_ urlPrefix: String, slug: String) async throws -> BackendPrefixUpdate
}

/// Old Domains' + and −; each returns the backend as it now is.
public protocol BackendOldDomainsWriting: Sendable {
  func addOldDomain(_ urlPrefix: String, slug: String) async throws -> BackendDetails
  func removeOldDomain(_ urlPrefix: String, slug: String) async throws -> BackendDetails
}

/// Each domain's links (`domainLinkCounts`).
public protocol BackendDomainLinksReading: Sendable {
  func domainLinkCounts(slug: String) async throws -> DomainLinkCounts
}

/// One row of the Domains list: Current first, then the Old ones.
public struct BackendDomainRow: Identifiable, Equatable, Sendable {
  public let prefix: String
  public let isCurrent: Bool
  /// nil until the counts are read.
  public let links: Int?
  public var id: String { prefix }
  public var host: String { DomainHost.host(prefix) }
  public var isUnused: Bool { !isCurrent && links == 0 }

  /// "268 links"; Unused for an Old one with none.
  public var linksText: String? {
    guard let links else { return nil }
    if isUnused { return "Unused" }
    return PinaxFormat.count(links, singular: "link")
  }

  /// Flow B's button, on an Old row with links.
  public var moveTitle: String? {
    guard !isCurrent, let links, links > 0 else { return nil }
    return "Move \(PinaxFormat.count(links, singular: "Link")) to Current…"
  }
}

public protocol BackendCredentialsWriting: Sendable {
  func storeCredentials(_ credentials: BackendCredentials, for reference: String) throws
}

public struct CatalogBackendsReader: BackendsReading, BackendsWriting, BackendCredentialsWriting,
  BackendOldDomainsWriting, BackendDomainLinksReading
{
  private let database: DatabasePool
  private let keychain: Keychain

  public init(database: DatabasePool, keychain: Keychain = Keychain()) {
    self.database = database
    self.keychain = keychain
  }

  public func backends() async throws -> [BackendListRow] {
    let database = database
    return try await Task.detached {
      try CatalogConfiguration.backends(in: database).map {
        BackendListRow(slug: $0.slug, kind: $0.kind, bucket: $0.bucket, urlPrefix: $0.urlPrefix)
      }
    }.value
  }

  public func backend(slug: String) async throws -> BackendDetails {
    let database = database
    let keychain = keychain
    return try await Task.detached {
      let backend = try CatalogConfiguration.backend(slug: slug, in: database)
      let configured = !backend.keychainRef.isEmpty
        && (try? keychain.load(for: backend.keychainRef)) != nil
      return BackendDetails(
        slug: backend.slug,
        kind: backend.kind,
        endpoint: backend.endpoint,
        bucket: backend.bucket,
        region: backend.region,
        urlPrefix: backend.urlPrefix,
        keychainReference: backend.keychainRef,
        credentialsConfigured: configured,
        oldDomains: try CatalogConfiguration.oldDomains(backendSlug: slug, in: database))
    }.value
  }

  public func addBackend(_ draft: NewBackendDraft) async throws {
    let database = database
    try await Task.detached {
      _ = try CatalogConfiguration.addBackend(
        slug: draft.slug,
        endpoint: draft.endpoint,
        bucket: draft.bucket,
        region: draft.region,
        urlPrefix: draft.urlPrefix,
        keychainReference: draft.keychainReference,
        to: database)
    }.value
  }

  public func setURLPrefix(
    _ urlPrefix: String, slug: String
  ) async throws -> BackendPrefixUpdate {
    let database = database
    let keychain = keychain
    return try await Task.detached {
      let before = try CatalogConfiguration.backend(slug: slug, in: database)
      let updated = try CatalogConfiguration.setBackendURLPrefix(
        slug: slug, urlPrefix: urlPrefix, in: database)
      let configured = !updated.keychainRef.isEmpty
        && (try? keychain.load(for: updated.keychainRef)) != nil
      return BackendPrefixUpdate(
        details: BackendDetails(
          slug: updated.slug, kind: updated.kind, endpoint: updated.endpoint,
          bucket: updated.bucket, region: updated.region, urlPrefix: updated.urlPrefix,
          keychainReference: updated.keychainRef, credentialsConfigured: configured,
          oldDomains: try CatalogConfiguration.oldDomains(backendSlug: slug, in: database)),
        retiredOldPrefix: before.urlPrefix != updated.urlPrefix)
    }.value
  }

  public func domainLinkCounts(slug: String) async throws -> DomainLinkCounts {
    let database = database
    return try await Task.detached {
      try CatalogConfiguration.domainLinkCounts(backendSlug: slug, in: database)
    }.value
  }

  public func storeCredentials(
    _ credentials: BackendCredentials, for reference: String
  ) throws {
    try keychain.store(credentials, for: reference)
  }

  public func addOldDomain(_ urlPrefix: String, slug: String) async throws -> BackendDetails {
    let database = database
    try await Task.detached {
      _ = try CatalogConfiguration.addOldDomain(urlPrefix, backendSlug: slug, in: database)
    }.value
    return try await backend(slug: slug)
  }

  public func removeOldDomain(_ urlPrefix: String, slug: String) async throws -> BackendDetails {
    let database = database
    try await Task.detached {
      _ = try CatalogConfiguration.removeOldDomain(urlPrefix, backendSlug: slug, in: database)
    }.value
    return try await backend(slug: slug)
  }
}

@MainActor
public final class BackendsModel: ObservableObject {
  @Published public private(set) var rows: [BackendListRow]?
  @Published public private(set) var details: BackendDetails?
  @Published public private(set) var selectedSlug: String?
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: String?
  @Published public private(set) var additionDraft: NewBackendDraft?
  @Published public private(set) var isAddingBackend = false
  @Published public private(set) var pendingPrefix: String?
  @Published public private(set) var operationMessage: String?
  @Published public private(set) var reindexDryRunResult: ReindexResult?
  @Published public private(set) var reindexAppliedResult: ReindexResult?
  @Published public private(set) var isReindexing = false
  @Published public private(set) var reindexError: String?
  @Published public private(set) var picGoSourceURL: URL
  @Published public private(set) var picGoDryRunResult: PicGoImportResult?
  @Published public private(set) var picGoAppliedResult: PicGoImportResult?
  @Published public private(set) var isImportingPicGo = false
  @Published public private(set) var picGoImportError: String?
  @Published public private(set) var isCredentialsFormPresented = false
  @Published public private(set) var credentialAccessKeyID = ""
  @Published public private(set) var credentialSecretAccessKey = ""
  @Published public private(set) var isSavingCredentials = false
  @Published public private(set) var credentialsSaveError: String?
  /// Old Domains' last + or − failure; cleared by the next success.
  @Published public private(set) var oldDomainError: String?
  /// The selected backend's links per domain.
  @Published public private(set) var domainLinks: DomainLinkCounts?
  /// Add Old Domain: the footer's inline field, while it is open.
  @Published public private(set) var oldDomainDraft: String?
  /// Switch Without Rewriting: the sheet's field, while it is open.
  @Published public private(set) var switchDraft: String?
  @Published public private(set) var switchError: String?
  /// Shared with the main window's migrations; nil: none run here.
  public var migrationLock: MigrationLock? {
    didSet {
      lockWiring = migrationLock?.$owner.sink { [weak self] _ in self?.objectWillChange.send() }
    }
  }
  private var lockWiring: AnyCancellable?
  /// Flow A's and B's entries: the main window takes over (the app sets
  /// them; nil while the library is not open).
  public var onMoveToNewDomain: ((String) -> Void)?
  public var onMoveToCurrent: ((String, String) -> Void)?
  /// A Switch or an Old domain added or removed: the main window's roots
  /// and menu read again.
  public var onDomainsChanged: (() async -> Void)?
  /// After a Switch or an added Old domain, Scan Now
  /// over the projects that upload to the backend (the app sets it).
  public var onScanBackend: ((String) -> Void)?
  /// Unreferenced Objects under Reindex.
  public let unreferenced: UnreferencedObjectsModel

  private let reader: BackendsReading
  private let writer: BackendsWriting?
  private let reindexer: ReindexRunning?
  private let picGoImporter: PicGoGalleryImporting?
  private let credentialsWriter: BackendCredentialsWriting?
  private let oldDomainsWriter: BackendOldDomainsWriting?
  private let domainLinksReader: BackendDomainLinksReading?
  private let choosePicGoSource: @MainActor (URL) -> URL?
  private var generation = 0

  public init(
    reader: BackendsReading, writer: BackendsWriting? = nil,
    reindexer: ReindexRunning? = nil,
    picGoImporter: PicGoGalleryImporting? = nil,
    credentialsWriter: BackendCredentialsWriting? = nil,
    oldDomainsWriter: BackendOldDomainsWriting? = nil,
    bucketImporter: BucketImporting? = nil,
    picGoSourceURL: URL = PicGoGalleryOpenPanel.defaultSource,
    choosePicGoSource: @escaping @MainActor (URL) -> URL? = PicGoGalleryOpenPanel.choose
  ) {
    self.reader = reader
    self.writer = writer ?? reader as? BackendsWriting
    self.reindexer = reindexer
    self.picGoImporter = picGoImporter
    self.credentialsWriter = credentialsWriter ?? reader as? BackendCredentialsWriting
    self.oldDomainsWriter = oldDomainsWriter ?? reader as? BackendOldDomainsWriting
    self.domainLinksReader = reader as? BackendDomainLinksReading
    self.picGoSourceURL = picGoSourceURL
    self.choosePicGoSource = choosePicGoSource
    unreferenced = UnreferencedObjectsModel(importer: bucketImporter)
  }

  public var canRunReindex: Bool {
    reindexer != nil && details?.credentialsConfigured == true && !isReindexing
  }

  public var canApplyReindex: Bool {
    canRunReindex && reindexDryRunResult != nil
  }

  public var canRunPicGoImport: Bool {
    picGoImporter != nil && selectedSlug != nil && !isImportingPicGo
  }

  public var canApplyPicGoImport: Bool {
    canRunPicGoImport && picGoDryRunResult != nil
  }

  public var canSubmitCredentials: Bool {
    credentialsWriter != nil && details?.keychainReference.isEmpty == false
      && !credentialAccessKeyID.isEmpty && !credentialSecretAccessKey.isEmpty
      && !isSavingCredentials
  }

  public var canSubmitAddition: Bool {
    guard let draft = additionDraft else { return false }
    return !draft.slug.isEmpty && !draft.endpoint.isEmpty && !draft.bucket.isEmpty
      && !draft.region.isEmpty && !draft.urlPrefix.isEmpty && !draft.keychainReference.isEmpty
      && writer != nil
  }

  public func beginAddition() {
    guard writer != nil else { return }
    additionDraft = NewBackendDraft()
    operationMessage = nil
    loadError = nil
  }

  public func updateAdditionDraft(_ update: (inout NewBackendDraft) -> Void) {
    guard var draft = additionDraft else { return }
    let oldSlug = draft.slug
    let followedDefault = draft.keychainReference == "backend.\(oldSlug)"
    update(&draft)
    if followedDefault && draft.slug != oldSlug {
      draft.keychainReference = "backend.\(draft.slug)"
    }
    additionDraft = draft
  }

  public func cancelAddition() {
    guard !isAddingBackend else { return }
    additionDraft = nil
  }

  public func submitAddition() async {
    guard let draft = additionDraft, canSubmitAddition, let writer else { return }
    isAddingBackend = true
    defer { isAddingBackend = false }
    do {
      try await writer.addBackend(draft)
      selectedSlug = draft.slug
      additionDraft = nil
      operationMessage = "Backend added. Credentials are not configured."
      await load()
    } catch {
      loadError = UserFacingErrorMessage.resolve(error)
    }
  }

  public func requestURLPrefixChange(_ urlPrefix: String) {
    guard writer != nil else { return }
    pendingPrefix = urlPrefix
    operationMessage = nil
  }

  public func cancelURLPrefixChange() {
    pendingPrefix = nil
  }

  public func confirmURLPrefixChange() async {
    guard let slug = selectedSlug, let urlPrefix = pendingPrefix, let writer else { return }
    pendingPrefix = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let result = try await writer.setURLPrefix(urlPrefix, slug: slug)
      details = result.details
      rows = try await reader.backends()
      loadError = nil
      operationMessage = result.retiredOldPrefix
        ? "URL prefix updated; the old prefix was retired."
        : "URL prefix is unchanged; no prefix was retired."
      await loadDomainLinks()
      await onDomainsChanged?()
    } catch {
      loadError = UserFacingErrorMessage.resolve(error)
    }
  }

  // MARK: - Domains

  /// Current first, then each Old domain, with their links.
  public var domainRows: [BackendDomainRow] {
    guard let details else { return [] }
    let counts = domainLinks.flatMap { $0.current.prefix == details.urlPrefix ? $0 : nil }
    var rows = [BackendDomainRow(prefix: details.urlPrefix, isCurrent: true, links: counts?.current.links)]
    for prefix in details.oldDomains {
      rows.append(
        BackendDomainRow(
          prefix: prefix, isCurrent: false, links: counts?.old.first { $0.prefix == prefix }?.links))
    }
    return rows
  }

  public var isMigrationBusy: Bool { migrationLock?.isBusy ?? false }

  /// A, B (and D, Remove): greyed while a migration runs; A and B also
  /// while the main window's library is not open.
  public var canMove: Bool { !isMigrationBusy && onMoveToNewDomain != nil }

  /// The tooltip of a greyed A or B.
  public var moveHelp: String? {
    if isMigrationBusy { return MigrationLock.busyHelp }
    if onMoveToNewDomain == nil { return "The library is not open yet." }
    return nil
  }

  public func moveToNewDomain() {
    guard canMove, let slug = selectedSlug else { return }
    onMoveToNewDomain?(slug)
  }

  public func moveToCurrent(_ oldDomain: String) {
    guard canMove, let slug = selectedSlug else { return }
    onMoveToCurrent?(slug, oldDomain)
  }

  /// The counts, read again (Settings opening, after a move or a scan).
  public func loadDomainLinks() async {
    guard let slug = selectedSlug, let reader = domainLinksReader else {
      domainLinks = nil
      return
    }
    let counts = try? await reader.domainLinkCounts(slug: slug)
    guard selectedSlug == slug else { return }
    domainLinks = counts
  }

  /// Add Old Domain: the footer becomes a field.
  public func beginOldDomainAddition() {
    guard canEditOldDomains else { return }
    oldDomainDraft = ""
    oldDomainError = nil
  }

  public func updateOldDomainDraft(_ value: String) {
    guard oldDomainDraft != nil else { return }
    oldDomainDraft = value
    oldDomainError = nil
  }

  public func cancelOldDomainAddition() {
    oldDomainDraft = nil
    oldDomainError = nil
  }

  public var canSubmitOldDomain: Bool {
    guard let draft = oldDomainDraft else { return false }
    return canEditOldDomains && !draft.trimmingCharacters(in: .whitespaces).isEmpty && oldDomainError == nil
  }

  public func submitOldDomain() async {
    guard canSubmitOldDomain, let draft = oldDomainDraft else { return }
    await addOldDomain(draft)
    if oldDomainError == nil { oldDomainDraft = nil }
  }

  /// Switch Without Rewriting…: the sheet.
  public func beginSwitch() {
    guard writer != nil, !isMigrationBusy else { return }
    switchDraft = ""
    switchError = nil
  }

  public func updateSwitchDraft(_ value: String) {
    guard switchDraft != nil else { return }
    switchDraft = value
    switchError = nil
  }

  public func cancelSwitch() {
    switchDraft = nil
    switchError = nil
  }

  public var canSubmitSwitch: Bool {
    guard let draft = switchDraft, let details else { return false }
    let value = draft.trimmingCharacters(in: .whitespaces)
    return !value.isEmpty && switchError == nil && !DomainHost.same(value, details.urlPrefix)
      && !isMigrationBusy
  }

  /// Switch: the prefix changes, the old one joins Old domains, no file
  /// changes. A refusal stays in the sheet, under the field.
  public func submitSwitch() async {
    guard canSubmitSwitch, let slug = selectedSlug, let draft = switchDraft, let writer else { return }
    do {
      let result = try await writer.setURLPrefix(draft, slug: slug)
      guard selectedSlug == slug else { return }
      details = result.details
      rows = try await reader.backends()
      switchDraft = nil
      switchError = nil
      await loadDomainLinks()
      await onDomainsChanged?()
      onScanBackend?(slug)
    } catch {
      switchError = DomainCopy.message(error)
    }
  }

  // MARK: - Old Domains

  public var canEditOldDomains: Bool { oldDomainsWriter != nil && details != nil }

  /// +: registers the prefix on the selected backend. Only
  /// `backend_prefix_history` changes; the current prefix stays.
  public func addOldDomain(_ urlPrefix: String) async {
    // The references under it read as old only after a scan; a Remove
    // changes no reference, so it does not scan.
    await editOldDomains(scans: true) { writer, slug in try await writer.addOldDomain(urlPrefix, slug: slug) }
  }

  /// −: removes the registration.
  public func removeOldDomain(_ urlPrefix: String) async {
    await editOldDomains { writer, slug in try await writer.removeOldDomain(urlPrefix, slug: slug) }
  }

  private func editOldDomains(
    scans: Bool = false, _ edit: (BackendOldDomainsWriting, String) async throws -> BackendDetails
  ) async {
    guard let slug = selectedSlug, let writer = oldDomainsWriter else { return }
    do {
      let updated = try await edit(writer, slug)
      guard selectedSlug == slug else { return }
      details = updated
      oldDomainError = nil
      await loadDomainLinks()
      await onDomainsChanged?()
      if scans { onScanBackend?(slug) }
    } catch {
      oldDomainError = DomainCopy.message(error)
    }
  }

  public func beginCredentialsEntry() {
    guard credentialsWriter != nil, details?.keychainReference.isEmpty == false else { return }
    clearCredentialFields()
    credentialsSaveError = nil
    isCredentialsFormPresented = true
  }

  public func updateCredentialAccessKeyID(_ value: String) {
    credentialAccessKeyID = value
  }

  public func updateCredentialSecretAccessKey(_ value: String) {
    credentialSecretAccessKey = value
  }

  public func cancelCredentialsEntry() {
    guard !isSavingCredentials else { return }
    resetCredentialsEntry()
  }

  public func submitCredentials() async {
    guard canSubmitCredentials, let credentialsWriter, let details else { return }
    let credentials = BackendCredentials(
      accessKeyID: credentialAccessKeyID,
      secretAccessKey: credentialSecretAccessKey)
    let reference = details.keychainReference
    clearCredentialFields()
    isSavingCredentials = true
    defer { isSavingCredentials = false }
    do {
      try credentialsWriter.storeCredentials(credentials, for: reference)
      let refreshedDetails = try await reader.backend(slug: details.slug)
      if selectedSlug == details.slug {
        self.details = refreshedDetails
      }
      credentialsSaveError = nil
      isCredentialsFormPresented = false
      operationMessage = "Credentials saved."
    } catch {
      // Credential-path errors are deliberately opaque: even a localized or
      // printable error may carry the submitted secret as an associated value.
      credentialsSaveError = "Credentials could not be saved."
    }
  }

  public func runReindexDryRun() async {
    guard canRunReindex, let slug = selectedSlug, let reindexer else { return }
    isReindexing = true
    defer { isReindexing = false }
    do {
      reindexDryRunResult = try await reindexer.run(backendSlug: slug, dryRun: true)
      reindexAppliedResult = nil
      reindexError = nil
    } catch {
      reindexError = reindexMessage(for: error)
    }
  }

  public func applyReindex() async {
    guard canApplyReindex, let slug = selectedSlug, let reindexer else { return }
    isReindexing = true
    defer { isReindexing = false }
    do {
      reindexAppliedResult = try await reindexer.run(backendSlug: slug, dryRun: false)
      reindexDryRunResult = nil
      reindexError = nil
    } catch {
      reindexError = reindexMessage(for: error)
    }
  }

  public func choosePicGoGallery() {
    guard !isImportingPicGo, let source = choosePicGoSource(picGoSourceURL) else { return }
    guard source != picGoSourceURL else { return }
    picGoSourceURL = source
    resetPicGoImportResults()
  }

  public func runPicGoDryRun() async {
    guard canRunPicGoImport, let slug = selectedSlug, let picGoImporter else { return }
    isImportingPicGo = true
    defer { isImportingPicGo = false }
    do {
      picGoDryRunResult = try await picGoImporter.run(
        source: picGoSourceURL, backendSlug: slug, dryRun: true)
      picGoAppliedResult = nil
      picGoImportError = nil
    } catch {
      picGoImportError = picGoMessage(for: error)
    }
  }

  public func applyPicGoImport() async {
    guard canApplyPicGoImport, let slug = selectedSlug, let picGoImporter else { return }
    isImportingPicGo = true
    defer { isImportingPicGo = false }
    do {
      picGoAppliedResult = try await picGoImporter.run(
        source: picGoSourceURL, backendSlug: slug, dryRun: false)
      picGoDryRunResult = nil
      picGoImportError = nil
    } catch {
      picGoImportError = picGoMessage(for: error)
    }
  }

  public func load() async {
    generation += 1
    let currentGeneration = generation
    isLoading = true
    defer { if generation == currentGeneration { isLoading = false } }
    do {
      let rows = try await reader.backends()
      guard generation == currentGeneration else { return }
      self.rows = rows
      loadError = nil
      let slug = selectedSlug.flatMap { selected in
        rows.contains(where: { $0.slug == selected }) ? selected : nil
      } ?? rows.first?.slug
      selectedSlug = slug
      if let slug {
        let loadedDetails = try await reader.backend(slug: slug)
        if details?.slug != loadedDetails.slug {
          resetReindexResults()
          resetPicGoImportResults()
          unreferenced.reset()
        }
        details = loadedDetails
        await loadDomainLinks()
      } else {
        details = nil
      }
    } catch {
      guard generation == currentGeneration else { return }
      details = nil
      loadError = UserFacingErrorMessage.resolve(error)
    }
  }

  public func select(_ slug: String) async {
    generation += 1
    let currentGeneration = generation
    selectedSlug = slug
    resetCredentialsEntry()
    resetReindexResults()
    resetPicGoImportResults()
    unreferenced.reset()
    oldDomainError = nil
    oldDomainDraft = nil
    switchDraft = nil
    domainLinks = nil
    isLoading = true
    defer { if generation == currentGeneration { isLoading = false } }
    do {
      details = try await reader.backend(slug: slug)
      guard generation == currentGeneration else { return }
      loadError = nil
      await loadDomainLinks()
    } catch {
      guard generation == currentGeneration else { return }
      details = nil
      loadError = UserFacingErrorMessage.resolve(error)
    }
  }

  private func resetReindexResults() {
    reindexDryRunResult = nil
    reindexAppliedResult = nil
    reindexError = nil
  }

  private func resetPicGoImportResults() {
    picGoDryRunResult = nil
    picGoAppliedResult = nil
    picGoImportError = nil
  }

  private func clearCredentialFields() {
    credentialAccessKeyID = ""
    credentialSecretAccessKey = ""
  }

  private func resetCredentialsEntry() {
    clearCredentialFields()
    credentialsSaveError = nil
    isCredentialsFormPresented = false
  }

  private func reindexMessage(for error: Error) -> String {
    if let error = error as? ReindexRunnerError {
      return error.description
    }
    if let error = error as? ReindexError {
      return error.description
    }
    return UserFacingErrorMessage.resolve(error)
  }

  private func picGoMessage(for error: Error) -> String {
    if let error = error as? PicGoGalleryError {
      return error.description
    }
    return UserFacingErrorMessage.resolve(error)
  }
}
