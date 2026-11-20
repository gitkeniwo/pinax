import CatalogCore
import Foundation
import GRDB

// MARK: - Service

public enum BucketImportError: Error, Equatable, CustomStringConvertible {
  case credentialsNotConfigured(String)
  /// The List came back 401/403; the text is `BucketClaim.listRefusalMessage`.
  case listRefused(String)

  public var description: String {
    switch self {
    case .credentialsNotConfigured:
      return UnreferencedObjectsSectionContent.missingCredentialsText
    case let .listRefused(message):
      return message
    }
  }
}

/// Find is the signed List alone; Import claims what it found with the
/// Externals claim core.
public protocol BucketImporting: Sendable {
  func find(backendSlug: String) async throws -> UnreferencedObjects
  func importObjects(
    _ found: UnreferencedObjects, backendSlug: String,
    cancellation: ExternalsClaimCancellation,
    progress: @escaping @Sendable (ExternalsClaimProgress) -> Void
  ) async throws -> BucketClaimResult
}

public struct CatalogBucketImporter: BucketImporting {
  public typealias CredentialsLoader = @Sendable (Backend) throws -> BackendCredentials?
  public typealias InventoryFactory =
    @Sendable (Backend, BackendCredentials) -> any ObjectInventory

  private let database: DatabasePool
  private let loadCredentials: CredentialsLoader
  private let inventoryFactory: InventoryFactory
  private let fetcher: any PublicObjectFetching

  public init(
    database: DatabasePool,
    loadCredentials: @escaping CredentialsLoader = { backend in
      backend.keychainRef.isEmpty ? nil : try Keychain().load(for: backend.keychainRef)
    },
    inventoryFactory: @escaping InventoryFactory = { backend, credentials in
      S3ObjectInventory(backend: backend, credentials: credentials)
    },
    fetcher: any PublicObjectFetching = URLSessionPublicObjectFetcher()
  ) {
    self.database = database
    self.loadCredentials = loadCredentials
    self.inventoryFactory = inventoryFactory
    self.fetcher = fetcher
  }

  public func find(backendSlug: String) async throws -> UnreferencedObjects {
    let database = database
    let loadCredentials = loadCredentials
    let (backend, credentials) = try await Task.detached {
      let backend = try CatalogConfiguration.backend(slug: backendSlug, in: database)
      guard let credentials = try loadCredentials(backend) else {
        throw BucketImportError.credentialsNotConfigured(backendSlug)
      }
      return (backend, credentials)
    }.value
    do {
      return try await BucketClaim.find(
        backend: backend, inventory: inventoryFactory(backend, credentials), in: database)
    } catch {
      guard let message = BucketClaim.listRefusalMessage(for: error, backend: backend) else {
        throw error
      }
      throw BucketImportError.listRefused(message)
    }
  }

  public func importObjects(
    _ found: UnreferencedObjects, backendSlug: String,
    cancellation: ExternalsClaimCancellation,
    progress: @escaping @Sendable (ExternalsClaimProgress) -> Void
  ) async throws -> BucketClaimResult {
    let backend = try CatalogConfiguration.backend(slug: backendSlug, in: database)
    return try await BucketClaim.run(
      found, backend: backend, in: database, fetcher: fetcher, cancellation: cancellation,
      progress: progress)
  }
}

// MARK: - State and what it shows

public enum UnreferencedObjectsState: Equatable, Sendable {
  case notChecked
  case finding
  case found(UnreferencedObjects)
  case importing(completed: Int, total: Int)
  case imported(BucketClaimResult)
  case failed(String)
}

/// Settings ▸ Backends ▸ <backend> ▸ Unreferenced Objects,
/// as data: the view draws exactly this.
public struct UnreferencedObjectsSectionContent: Equatable, Sendable {
  public static let header = "Unreferenced Objects"
  public static let missingCredentialsText =
    "Configure credentials before finding objects in this backend."
  public static let reindexNote =
    "Reindex can’t rebuild imported images from the bucket; catalog backups keep them."

  public var status: String
  /// Lines under the status, in order.
  public var details: [String] = []
  public var isError = false
  public var showsSpinner = false
  /// 0…1 while importing.
  public var progress: Double?
  public var findTitle: String?
  public var findEnabled = false
  public var importTitle: String?
  public var showsCancel = false
  public var showsOrphansLink = false
  public var footer: String

  public static func make(
    state: UnreferencedObjectsState, bucket: String, credentialsConfigured: Bool,
    canImport: Bool
  ) -> Self {
    let footer =
      "Objects in \(bucket) that aren’t in the catalog and that no project’s pages use. Imported images show up in Orphans. Objects stay in the bucket."
    var content = Self(status: "Not checked yet", footer: footer)
    let canFind = canImport && credentialsConfigured
    switch state {
    case .notChecked:
      content.findTitle = "Find Objects"
      content.findEnabled = canFind
      if !credentialsConfigured { content.details = [missingCredentialsText] }
    case .finding:
      content.status = "Listing objects in \(bucket)…"
      content.showsSpinner = true
    case let .found(found):
      content.status = notInCatalog(found.candidates.count)
      content.findTitle = "Find Again"
      content.findEnabled = canFind
      if !found.candidates.isEmpty {
        content.importTitle = importTitle(found.candidates.count)
      }
    case let .importing(completed, total):
      content.status = "Importing \(completed) of \(total)…"
      content.showsSpinner = true
      content.progress = total > 0 ? Double(completed) / Double(total) : 0
      content.showsCancel = true
    case let .imported(result):
      content.findTitle = "Find Again"
      content.findEnabled = canFind
      if result.refused {
        content.status = "Nothing imported"
        content.details = [
          "The CDN changed the bytes of images Pinax uploaded, so nothing was imported."
        ]
        content.isError = true
        return content
      }
      content.status =
        result.cancelled
        ? "Imported \(result.claimed.count) of \(result.candidates) objects"
        : "Imported \(count(result.claimed.count, "object", "objects"))"
      let problems = problemSummary(result)
      if !problems.isEmpty { content.details.append(problems) }
      if !result.claimed.isEmpty {
        content.details.append(reindexNote)
        content.showsOrphansLink = true
      }
      if result.cancelled, result.remaining > 0 {
        content.importTitle = importTitle(result.remaining)
      }
    case let .failed(message):
      content.findTitle = "Find Objects"
      content.findEnabled = canFind
      content.details = [message]
      content.isError = true
    }
    return content
  }

  static func notInCatalog(_ n: Int) -> String {
    switch n {
    case 0: return "Every object is in the catalog"
    case 1: return "1 object isn’t in the catalog"
    default: return "\(n) objects aren’t in the catalog"
    }
  }

  static func importTitle(_ n: Int) -> String {
    "Import \(count(n, "Object", "Objects"))…"
  }

  /// "1 not found · 2 couldn’t be downloaded", in a fixed order.
  static func problemSummary(_ result: BucketClaimResult) -> String {
    let counts = result.skippedCounts
    let labels: [(String, String)] = [
      (ExternalsClaimSkipReason.notFound, "not found"),
      (ExternalsClaimSkipReason.forbidden, "refused by the server"),
      (ExternalsClaimSkipReason.fetchFailed, "couldn’t be downloaded"),
      (ExternalsClaimSkipReason.lengthMismatch, "downloaded incompletely"),
      (ExternalsClaimSkipReason.sameContent, "already in the catalog under another name"),
      (ExternalsClaimSkipReason.pendingDeletion, "being deleted"),
      (ExternalsClaimSkipReason.badKey, "not images"),
    ]
    return labels.compactMap { reason, label in
      counts[reason].map { "\($0) \(label)" }
    }.joined(separator: " · ")
  }

  static func count(_ n: Int, _ one: String, _ many: String) -> String {
    "\(n) \(n == 1 ? one : many)"
  }
}

/// The sheet behind Import N Objects….
public struct ImportObjectsSheetContent: Equatable, Sendable {
  public struct Row: Equatable, Sendable {
    public let label: String
    public let value: String
  }

  public static let cdnUncheckedText =
    "Pinax can’t check whether the CDN changes bytes on this domain."
  public static let note = "Objects stay where they are; nothing is uploaded or deleted."

  public let title: String
  public let message: String
  public let rows: [Row]
  public let cdnWarning: String?
  public let note: String
  public let cancelTitle = "Cancel"
  public let confirmTitle = "Import"

  public static func make(count n: Int, bucket: String, cdnSamples: Int) -> Self {
    Self(
      title:
        "Import \(UnreferencedObjectsSectionContent.count(n, "Object", "Objects")) into the Catalog?",
      message:
        "From \(bucket). Pinax downloads each object once to fingerprint it, then adds it to the catalog at the address it already has.",
      rows: [
        Row(label: "Objects", value: "\(n)"),
        Row(
          label: "Downloads",
          value: "about \(UnreferencedObjectsSectionContent.count(n, "download", "downloads"))"),
        Row(
          label: "Project",
          value: n == 1 ? "none — it’ll appear in Orphans" : "none — they’ll appear in Orphans"),
      ],
      cdnWarning: cdnSamples == 0 ? cdnUncheckedText : nil,
      note: note)
  }
}

// MARK: - Model

@MainActor
public final class UnreferencedObjectsModel: ObservableObject {
  @Published public private(set) var state: UnreferencedObjectsState = .notChecked
  /// Non-nil while the confirmation sheet is up.
  @Published public private(set) var confirmation: ImportObjectsSheetContent?
  /// The section's "Show in Orphans"; PinaxAppModel points it at the gallery.
  public var onShowOrphans: (() -> Void)?

  private let importer: BucketImporting?
  private var found: UnreferencedObjects?
  private var cancellation: ExternalsClaimCancellation?
  private var generation = 0

  public init(importer: BucketImporting?) {
    self.importer = importer
  }

  public var canImport: Bool { importer != nil }

  public var isBusy: Bool {
    switch state {
    case .finding, .importing: return true
    default: return false
    }
  }

  /// How many an Import now would attempt: what Find found, or what a
  /// cancelled import left.
  private var importCount: Int {
    switch state {
    case let .found(found): return found.candidates.count
    case let .imported(result) where result.cancelled: return result.remaining
    default: return 0
    }
  }

  public func find(backendSlug: String) async {
    guard let importer, !isBusy else { return }
    generation += 1
    let current = generation
    state = .finding
    do {
      let result = try await importer.find(backendSlug: backendSlug)
      guard current == generation else { return }
      found = result
      state = .found(result)
    } catch {
      guard current == generation else { return }
      found = nil
      state = .failed(Self.message(for: error))
    }
  }

  public func requestImport(bucket: String) {
    guard let found, importCount > 0, !isBusy else { return }
    confirmation = ImportObjectsSheetContent.make(
      count: importCount, bucket: bucket, cdnSamples: found.cdnSamples)
  }

  public func dismissConfirmation() {
    confirmation = nil
  }

  public func confirmImport(backendSlug: String) async {
    guard let importer, let found, confirmation != nil else { return }
    let total = importCount
    confirmation = nil
    generation += 1
    let current = generation
    let cancellation = ExternalsClaimCancellation()
    self.cancellation = cancellation
    state = .importing(completed: 0, total: total)
    do {
      let result = try await importer.importObjects(
        found, backendSlug: backendSlug, cancellation: cancellation,
        progress: { [weak self] progress in
          Task { @MainActor in self?.apply(progress, generation: current) }
        })
      guard current == generation else { return }
      state = .imported(result)
    } catch {
      guard current == generation else { return }
      state = .failed(Self.message(for: error))
    }
    self.cancellation = nil
  }

  public func cancelImport() {
    cancellation?.cancel()
  }

  public func showOrphans() {
    onShowOrphans?()
  }

  /// Another backend was selected: forget this one's List.
  public func reset() {
    cancellation?.cancel()
    cancellation = nil
    generation += 1
    found = nil
    confirmation = nil
    state = .notChecked
  }

  private func apply(_ progress: ExternalsClaimProgress, generation current: Int) {
    guard current == generation, case .importing = state else { return }
    state = .importing(completed: progress.completed, total: progress.total)
  }

  static func message(for error: Error) -> String {
    if let error = error as? BucketImportError { return error.description }
    return UserFacingErrorMessage.resolve(error)
  }
}
