import CatalogCore
import Combine
import Foundation
import GRDB

/// A backend's Current domain and its Old ones,
/// as the Catalog roots, the Usage domain menu and the Domains list read
/// them.
public struct DomainBackend: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let slug: String
  /// The Current prefix, as stored.
  public let current: String
  /// The Old domains, oldest first.
  public let oldDomains: [String]
  /// The backend's active assets: its Catalog root's count.
  public let assetCount: Int
  /// The bucket, shown after the Storage root's
  /// slug and in its tooltip.
  public let bucket: String

  public init(
    id: Int64, slug: String, current: String, oldDomains: [String] = [], assetCount: Int = 0,
    bucket: String = ""
  ) {
    self.id = id
    self.slug = slug
    self.current = current
    self.oldDomains = oldDomains
    self.assetCount = assetCount
    self.bucket = bucket
  }

  /// Current first, then the Old ones.
  public var prefixes: [String] { [current] + oldDomains }
}

/// A prefix may carry a path; rows show its host and keep the
/// whole value for the tooltip.
public enum DomainHost {
  public static func host(_ prefix: String) -> String {
    URL(string: prefix)?.host() ?? prefix
  }

  /// A raw URL under `prefix` + `/`, by the counts' and the rewrite's
  /// one rule: scheme and host ignore case.
  public static func isUnder(_ rawURL: String, prefix: String) -> Bool {
    DomainLinks.isUnder(rawURL, prefix: prefix)
  }
}

// MARK: - The one lock

/// Externals' migration and the domain move both write source files, so
/// only one runs in the process at a time. Every entry of either asks
/// `isBusy` here, and nowhere else.
@MainActor
public final class MigrationLock: ObservableObject {
  public enum Owner: Equatable, Sendable { case externals, domain }

  @Published public private(set) var owner: Owner?
  /// The Externals migration's own process-wide flag (`ExternalMigration.isRunning`), which can
  /// be set by work this lock did not start.
  var externalWork: () -> Bool = { false }

  public init() {}

  public static let busyHelp = "A migration is already running"

  public var isBusy: Bool { owner != nil || externalWork() }

  /// Takes the lock for `owner`; false when anything else holds it.
  @discardableResult
  public func take(_ owner: Owner) -> Bool {
    if self.owner == owner { return true }
    guard !isBusy else { return false }
    self.owner = owner
    return true
  }

  public func release(_ owner: Owner) {
    if self.owner == owner { self.owner = nil }
  }
}

// MARK: - What the GUI needs of the domain-move core

/// One project the form offers, with its links on the moved domains.
public struct DomainMoveProject: Identifiable, Equatable, Sendable {
  public let slug: String
  public let links: Int
  public var id: String { slug }

  public init(slug: String, links: Int) {
    self.slug = slug
    self.links = links
  }
}

/// The core's `DomainMigration`, `DomainMigrationReview` and
/// `RewriteRuns.diff`, in this process. Tests stub it.
public protocol DomainMigrating: Sendable {
  /// `referencingProjects` with each project's links under `prefixes`.
  func projects(backend: String, prefixes: [String], includeResolved: Bool) async throws -> [DomainMoveProject]

  func preview(
    backend: String, to: String, from: [String], projects: [String], keepOldDomains: Bool,
    cancellation: ExternalMigrationCancellation,
    progress: @escaping @Sendable (RewritePreviewProgress) -> Void
  ) async throws -> RewritePreviewResult

  func review(runID: Int64) async throws -> DomainMigrationReview

  func apply(
    fromRun runID: Int64, allowedSources: Set<String>,
    phase: @escaping @Sendable (RewriteApplyPhase) -> Void
  ) async throws -> RewriteApplyResult

  /// A `rewrite` or `domain_migrate` preview's unified diff.
  func diff(ofRun runID: Int64) async throws -> String
}

public struct CatalogDomainMigrator: DomainMigrating {
  private let database: DatabasePool
  private let verifier: any RewriteTargetVerifying
  private let git: any GitStatusProviding
  /// For the rescans after an apply.
  let commands: CommandSourcePolicy
  private let runner: any CommandSourceRunning

  public init(
    database: DatabasePool, verifier: any RewriteTargetVerifying = PublicTargetVerifier(),
    git: any GitStatusProviding = GitStatusProvider(),
    commands: CommandSourcePolicy = .deny,
    runner: any CommandSourceRunning = ShellCommandRunner()
  ) {
    self.commands = commands
    self.runner = runner
    self.database = database
    self.verifier = verifier
    self.git = git
  }

  public func projects(
    backend: String, prefixes: [String], includeResolved: Bool
  ) async throws -> [DomainMoveProject] {
    let database = database
    // Every link under the prefixes, in the catalog
    // or not — `domainLinkCounts`' count, which the preview rewrites.
    let (slugs, links) = try await Task.detached {
      (
        try DomainMigration.referencingProjects(
          backendSlug: backend, prefixes: prefixes, includeResolved: includeResolved, in: database),
        try DomainLinks.countsByProject(prefixes: prefixes, in: database)
      )
    }.value
    return slugs.map { DomainMoveProject(slug: $0, links: links[$0] ?? 0) }
  }

  public func preview(
    backend: String, to: String, from: [String], projects: [String], keepOldDomains: Bool,
    cancellation: ExternalMigrationCancellation,
    progress: @escaping @Sendable (RewritePreviewProgress) -> Void
  ) async throws -> RewritePreviewResult {
    try await DomainMigration.preview(
      backend: backend, to: to, from: from, projects: projects, keepOldDomains: keepOldDomains,
      verifier: verifier, database: database, git: git, cancellation: cancellation, progress: progress)
  }

  public func review(runID: Int64) async throws -> DomainMigrationReview {
    let database = database
    return try await Task.detached { try DomainMigrationReview.load(runID: runID, in: database) }.value
  }

  public func apply(
    fromRun runID: Int64, allowedSources: Set<String>,
    phase: @escaping @Sendable (RewriteApplyPhase) -> Void
  ) async throws -> RewriteApplyResult {
    let database = database
    let git = git
    let commands = commands
    let runner = runner
    return try await Task.detached {
      try DomainMigration.apply(
        fromRun: runID, allowedSources: allowedSources, database: database, git: git,
        commands: commands, runner: runner, phase: phase)
    }.value
  }

  public func diff(ofRun runID: Int64) async throws -> String {
    let database = database
    let git = git
    return try await Task.detached { try RewriteRuns.diff(ofRun: runID, in: database, git: git) }.value
  }
}
