import Foundation

/// What happened to one planned file.
public struct RewriteFileResult: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case written(beforeSHA256: String, afterSHA256: String, edits: Int, backupPath: String?)
    case skipped(RewriteFileSkipReason)
    case failed(String)
  }

  public let sourceLabel: String
  public let path: String
  public let outcome: Outcome

  public init(sourceLabel: String, path: String, outcome: Outcome) {
    self.sourceLabel = sourceLabel
    self.path = path
    self.outcome = outcome
  }
}

public enum RewriteFileSkipReason: String, Equatable, Sendable {
  /// The file's bytes are no longer the ones the plan was made from, or the
  /// file is gone.
  case changedSincePlan = "changed_since_plan"
  /// The file is now a symbolic link.
  case symlink
}

public enum RewriteApplyError: Error, Equatable, CustomStringConvertible {
  /// Sources with edits that are not clean and were not allowed. Nothing
  /// was written.
  case sourcesNotAllowed([RewriteSourceState])

  public var description: String {
    switch self {
    case let .sourcesNotAllowed(sources):
      let lines = sources.map { "  \($0.label) (\($0.path)): \(describe($0.git))" }
      return (["Sources that are not clean must be allowed before rewriting:"] + lines)
        .joined(separator: "\n")
    }
  }

  private func describe(_ status: SourceGitStatus) -> String {
    switch status {
    case .clean: return "clean"
    case .notGit: return "not in git"
    case let .dirty(paths): return "uncommitted changes (\(paths.count))"
    case let .unknown(reason): return "git status unknown: \(reason)"
    }
  }
}

/// Writes a plan. The only code in Pinax that writes a
/// user's source files.
public enum RewriteApplier {
  /// `~/Library/Application Support/tech.gitkeniwo.pinax/rewrite-backups/`.
  public static func defaultBackupRoot(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    homeDirectory.appendingPathComponent(
      "Library/Application Support/tech.gitkeniwo.pinax/rewrite-backups", isDirectory: true)
  }

  /// - Parameters:
  ///   - allowedSources: labels of sources that may be written although not
  ///     clean. Their files are backed up first.
  ///   - runID: names the backup folder, `backupRoot/<runID>/<label>/<path>`.
  public static func apply(
    plan: RewritePlan,
    allowedSources: Set<String>,
    backupRoot: URL = defaultBackupRoot(),
    runID: String,
    git: GitStatusProviding = GitStatusProvider()
  ) throws -> [RewriteFileResult] {
    let planned = plan.files.filter { $0.newContent != nil }
    let touched = Set(planned.map(\.sourceLabel))
    // Status is taken again now: a source clean at plan time may not be.
    var current: [String: RewriteSourceState] = [:]
    for source in plan.sources where touched.contains(source.label) {
      current[source.label] = RewriteSourceState(
        label: source.label, path: source.path,
        git: git.status(of: URL(fileURLWithPath: source.path, isDirectory: true)))
    }
    let refused = plan.sources.compactMap { current[$0.label] }.filter {
      !$0.git.isClean && !allowedSources.contains($0.label)
    }
    guard refused.isEmpty else { throw RewriteApplyError.sourcesNotAllowed(refused) }

    return planned.map { file in
      RewriteFileResult(
        sourceLabel: file.sourceLabel, path: file.path,
        outcome: write(
          file,
          backupTo: current[file.sourceLabel]?.git.isClean == false
            ? backupRoot.appendingPathComponent(runID, isDirectory: true)
              .appendingPathComponent(file.sourceLabel, isDirectory: true)
              .appendingPathComponent(file.path)
            : nil))
    }
  }

  private static func write(_ file: RewriteFilePlan, backupTo backup: URL?) -> RewriteFileResult.Outcome {
    guard let newContent = file.newContent else { return .skipped(.changedSincePlan) }
    let fileManager = FileManager.default
    let path = file.absolutePath
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: path)
    } catch {
      return .skipped(.changedSincePlan)
    }
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return .skipped(.symlink) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      Hashing.sha256(of: data) == file.originalSHA256
    else { return .skipped(.changedSincePlan) }

    if let backup {
      do {
        try fileManager.createDirectory(
          at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: backup, options: .atomic)
      } catch {
        return .failed("Backup to \(backup.path) failed: \(error.localizedDescription)")
      }
    }

    let directory = (path as NSString).deletingLastPathComponent
    let temporary = (directory as NSString).appendingPathComponent(
      ".pinax-rewrite-\(UUID().uuidString).tmp")
    do {
      try newContent.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
      if let permissions = attributes[.posixPermissions] {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary)
      }
      guard rename(temporary, path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? fileManager.removeItem(atPath: temporary)
      return .failed("Writing \(path) failed: \(error.localizedDescription)")
    }
    return .written(
      beforeSHA256: file.originalSHA256, afterSHA256: Hashing.sha256(of: newContent),
      edits: file.edits.count, backupPath: backup?.path)
  }
}
