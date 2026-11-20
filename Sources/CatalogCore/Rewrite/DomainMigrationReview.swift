import Foundation
import GRDB

/// Everything the confirmation sheet shows about a
/// `domain_migrate` preview, read only from the run's params and events —
/// so `Review…` reopens it after the sheet was closed or the app restarted.
public struct DomainMigrationReview: Equatable, Sendable {
  public struct ProjectCount: Equatable, Sendable {
    public let project: String
    /// Files with edits.
    public let files: Int
    /// References rewritten.
    public let edits: Int

    public init(project: String, files: Int, edits: Int) {
      (self.project, self.files, self.edits) = (project, files, edits)
    }
  }

  public struct FailedCheck: Equatable, Sendable {
    public let url: String
    public let result: TargetVerifiedEvent.Result
    /// `TargetVerifiedEvent.cause`: why, without the URL.
    public let reason: String

    public init(url: String, result: TargetVerifiedEvent.Result, reason: String) {
      (self.url, self.result, self.reason) = (url, result, reason)
    }
  }

  public struct BrokenLink: Equatable, Sendable {
    public let url: String
    /// `TargetVerifiedEvent.oldCause`: why the old URL fails too; the new
    /// URL's reason for runs recorded without `old_reason`.
    public let oldReason: String

    public init(url: String, oldReason: String) {
      (self.url, self.oldReason) = (url, oldReason)
    }
  }

  public struct Source: Equatable, Sendable {
    public let project: String
    public let label: String
    public let status: SourceStatusEvent.Status
    public var isClean: Bool { status == .clean }
    /// The dirty paths' count, or git's error; nil when clean or not in git.
    public let reason: String?

    public init(project: String, label: String, status: SourceStatusEvent.Status, reason: String?) {
      (self.project, self.label, self.status, self.reason) = (project, label, status, reason)
    }
  }

  public let runID: Int64
  public let state: RunState
  public let backend: String
  public let from: String
  public let to: String
  /// Old domains rewritten along with `from` (or, when `keepPrefix`, the
  /// only ones); empty when they are left as they are.
  public let oldDomains: [String]
  /// Flow B: only old links move to the current prefix, which stays.
  public let keepPrefix: Bool
  /// Every project of the run, in run order, with 0 when it has no edits.
  public let projects: [ProjectCount]
  /// `ok` checks with an expected sha256 that matched.
  public let verified: Int
  /// `ok` checks of URLs not in the catalog: only fetched.
  public let fetchedOnly: Int
  public let failed: [FailedCheck]
  public let alreadyBroken: [BrokenLink]
  public let sources: [Source]
  /// The latest apply run made from this preview, if any.
  public let appliedRunID: Int64?

  public var applied: Bool { appliedRunID != nil }
  public var files: Int { projects.reduce(0) { $0 + $1.files } }
  public var edits: Int { projects.reduce(0) { $0 + $1.edits } }

  public enum LoadError: Error, Equatable, CustomStringConvertible {
    case notADomainPreview(Int64)

    public var description: String {
      switch self {
      case let .notADomainPreview(id): return "Run \(id) isn’t a domain migration preview."
      }
    }
  }

  /// The review of preview run `runID`.
  public static func load(
    runID: Int64, in database: CatalogDatabasePool,
    processExists: (Int32) -> Bool = RunLog.processExists
  ) throws -> DomainMigrationReview {
    guard let run = try RunLog.run(runID, in: database, processExists: processExists) else {
      throw RewriteRunError.runNotFound(runID)
    }
    let params = try JSONDecoder().decode(RewriteRunParams.self, from: Data(run.params.utf8))
    guard run.kind == .domainMigrate, run.dryRun, let domain = params.domain else {
      throw LoadError.notADomainPreview(runID)
    }
    var files: [String: Int] = [:]
    var edits: [String: Int] = [:]
    var verified = 0
    var fetchedOnly = 0
    var failed: [FailedCheck] = []
    var broken: [BrokenLink] = []
    var sources: [Source] = []
    for record in try RunLog.events(of: runID, in: database) {
      switch record.event {
      case let .filePlanned(event):
        files[event.project, default: 0] += 1
        edits[event.project, default: 0] += event.edits
      case let .sourceStatus(event):
        let reason: String? =
          switch event.status {
          case .clean, .notGit: nil
          case .dirty: "uncommitted changes (\(event.dirtyPaths.count))"
          case .unknown: event.reason
          }
        sources.append(Source(project: event.project, label: event.source, status: event.status, reason: reason))
      case let .targetVerified(event):
        switch event.result {
        case .ok:
          if event.expectedSHA256?.isEmpty == false { verified += 1 } else { fetchedOnly += 1 }
        case .alreadyBroken:
          broken.append(BrokenLink(url: event.url, oldReason: event.oldCause))
        case .mismatch, .unreachable:
          failed.append(FailedCheck(url: event.url, result: event.result, reason: event.cause))
        }
      default:
        break
      }
    }
    var seen = Set<String>()
    let projects = params.targets.map(\.project).filter { seen.insert($0).inserted }.map {
      ProjectCount(project: $0, files: files[$0] ?? 0, edits: edits[$0] ?? 0)
    }
    let applied = try database.read { db in
      try Int64.fetchOne(
        db, sql: "SELECT MAX(id) FROM run WHERE from_run_id = ? AND dry_run = 0", arguments: [runID])
    }
    return DomainMigrationReview(
      runID: runID, state: run.state, backend: domain.backend, from: domain.from, to: domain.to,
      oldDomains: domain.oldDomains, keepPrefix: domain.keepPrefix, projects: projects,
      verified: verified, fetchedOnly: fetchedOnly, failed: failed, alreadyBroken: broken,
      sources: sources, appliedRunID: applied)
  }
}
