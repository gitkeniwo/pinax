import ArgumentParser
import CatalogCore
import Foundation

// `delete`: the gallery's Delete Permanently…. Every write and every request
// is `CatalogDeletion`'s; this file chooses what to ask of it and prints.

struct DeleteCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete",
    abstract: "Delete archived assets for good, from the catalog and the bucket.",
    discussion: """
      Without --confirm the plan is printed and nothing happens (exit 77); \
      --dry-run prints it and exits 0. An imported asset's object stays in \
      the bucket; only its catalog row goes. A delete the bucket did not \
      finish stays owed: --pending lists those, --resume carries them on.
      """
  )

  @Argument(help: "Exact asset keys or unambiguous SHA-256 prefixes.")
  var identifiers: [String] = []

  @Flag(name: .long, help: "Delete what the plan lists. This cannot be undone.")
  var confirm = false

  @Flag(name: .long, help: "Print the plan; write nothing and send nothing.")
  var dryRun = false

  @Flag(name: .long, help: "Also delete assets that scanned sources still reference.")
  var includeUsed = false

  @Flag(name: .long, help: "Carry on every owed delete.")
  var resume = false

  @Option(name: .long, help: "With --resume: only this backend's owed deletes.")
  var backend: String?

  @Flag(name: .long, help: "List the owed deletes.")
  var pending = false

  @Option(name: .long)
  var format: OutputFormat = .table

  func validate() throws {
    if resume || pending {
      let mode = resume ? "--resume" : "--pending"
      if resume && pending {
        throw ValidationError("--resume and --pending cannot be used together.")
      }
      if !identifiers.isEmpty || confirm || dryRun || includeUsed {
        throw ValidationError(
          "\(mode) takes no identifiers, --confirm, --dry-run or --include-used.")
      }
    } else if identifiers.isEmpty {
      throw ValidationError("Name at least one asset, or use --resume or --pending.")
    }
    if backend != nil && !resume {
      throw ValidationError("--backend goes with --resume.")
    }
  }

  mutating func run() async throws {
    let database = try openCatalogDatabase()
    if pending {
      print(try DeleteCommandOperations.pending(format: format, in: database))
      return
    }
    let remote: DeletionRemote = { try CatalogDeletion.keychainRemote($0) }
    let report: DeleteReport
    do {
      if resume {
        report = try await DeleteCommandOperations.resume(
          backend: backend, format: format, in: database, remote: remote)
      } else {
        report = try await DeleteCommandOperations.delete(
          identifiers, mode: dryRun ? .dryRun : confirm ? .confirmed : .unconfirmed,
          includeUsed: includeUsed, format: format, in: database, remote: remote)
      }
    } catch let error as CatalogDeletionError {
      if let hint = DeleteCommandOperations.hint(for: error) {
        FileHandle.standardError.write(Data((hint + "\n").utf8))
      }
      throw error
    }
    print(report.output)
    for note in report.notes {
      FileHandle.standardError.write(Data((note + "\n").utf8))
    }
    if let failure = report.failure { throw failure }
  }
}

enum DeleteMode {
  case unconfirmed
  case dryRun
  case confirmed
}

/// What a `delete` run prints, and the error it then exits with.
struct DeleteReport {
  /// Standard output.
  let output: String
  /// Lines for standard error.
  var notes: [String] = []
  var failure: CLIError?
}

enum DeleteCommandOperations {
  /// The plan of the named assets; when confirmed, then the gallery's order:
  /// stage, then purge what was staged. A refusal throws before any write.
  static func delete(
    _ identifiers: [String], mode: DeleteMode, includeUsed: Bool = false,
    format: OutputFormat = .table, in database: CatalogDatabasePool,
    remote: @escaping DeletionRemote
  ) async throws -> DeleteReport {
    let batch = try plan(identifiers, includeUsed: includeUsed, in: database)
    switch mode {
    case .dryRun:
      return DeleteReport(
        output: try planOutput(batch.entries, format: format),
        notes: ["Dry run: nothing was written."])
    case .unconfirmed:
      return DeleteReport(
        output: try planOutput(batch.entries, format: format),
        failure: .refused(
          "Nothing was deleted. Pass --confirm to delete the \(batch.entries.count) "
            + "listed; this cannot be undone."))
    case .confirmed:
      break
    }

    // Every backend's remote is built before the first write, so missing
    // credentials refuse the batch instead of leaving it owed. Building one
    // sends nothing.
    let remotes = try await makeRemotes(for: batch.remoteBackendSlugs, in: database, remote: remote)
    let owed = try CatalogDeletion.stage(
      deleting: batch.deleting, keeping: batch.keeping, in: database, includeUsed: includeUsed)
    let purged =
      owed.isEmpty
      ? []
      : try await CatalogDeletion.purge(owed, in: database, remote: { backend in
        guard let built = remotes[backend.slug] else { return try remote(backend) }
        return built
      })
    let kept = batch.entries.filter { !$0.deletesRemote }.map {
      DeleteResultJSON(key: $0.key, outcome: "removed_from_catalog", error: nil)
    }
    return try report(
      purged, kept: kept, plan: batch.entries, credentialFailures: [:], format: format, in: database)
  }

  /// `CatalogDeletion.resume`, or `purge` of one backend's tombstones.
  static func resume(
    backend slug: String? = nil, format: OutputFormat = .table,
    in database: CatalogDatabasePool, remote: @escaping DeletionRemote
  ) async throws -> DeleteReport {
    // `purge` keeps only an error's words, so the remote factory's are noted
    // here to tell missing credentials from a failed request.
    let failures = RemoteFailures()
    let noting: DeletionRemote = { backend in
      do {
        return try remote(backend)
      } catch {
        failures.note(error, backend: backend.slug)
        throw error
      }
    }
    let purged: [PurgeResult]
    if let slug {
      guard try await database.read({ try Backend.fetchAll($0) }).contains(where: { $0.slug == slug })
      else { throw CatalogConfigurationError.backendNotFound(slug) }
      let ids = try CatalogDeletion.pending(in: database)
        .filter { $0.backendSlug == slug }.map(\.id)
      purged = try await CatalogDeletion.purge(ids, in: database, remote: noting)
    } else {
      purged = try await CatalogDeletion.resume(in: database, remote: noting)
    }
    return try report(
      purged, kept: [], plan: [], credentialFailures: failures.codes, format: format,
      in: database)
  }

  /// The tombstones still owed a delete: what `--resume` would take. Rows
  /// removed from the catalog only owe nothing and are not listed.
  static func pending(format: OutputFormat = .table, in database: CatalogDatabasePool) throws
    -> String
  {
    let owed = try CatalogDeletion.pending(in: database).filter { !$0.keepRemote }
    switch format {
    case .json:
      return try encodedJSON(PendingDeletionsDocument(pending: owed.map(PendingDeletionJSON.init)))
    case .table:
      let rows = owed.map {
        "\($0.backendSlug)\t\($0.key)\t\($0.sha256.prefix(12))\t\($0.byteSize)\t"
          + "\($0.phase.rawValue)\t\($0.attempts)\t\(cell($0.lastError))"
      }
      return (["BACKEND\tKEY\tSHA256\tBYTES\tPHASE\tATTEMPTS\tLAST_ERROR"] + rows)
        .joined(separator: "\n")
    }
  }

  /// What to run next after a refusal the command line can answer.
  static func hint(for error: CatalogDeletionError) -> String? {
    switch error {
    case .notArchived: return "Run `pinax archive` on them first."
    case .stillUsed: return "Pass --include-used to delete them anyway."
    default: return nil
    }
  }

  // MARK: - Planning

  private struct Batch {
    var entries: [DeletePlanJSON] = []
    /// Identifiers whose objects are deleted, and those whose rows only go.
    var deleting: [String] = []
    var keeping: [String] = []
    var remoteBackendSlugs: [String] = []
  }

  /// `CatalogDeletion.plan`, twice: every guard on the whole batch, then the
  /// key guards on the assets whose objects would be deleted.
  private static func plan(
    _ identifiers: [String], includeUsed: Bool, in database: CatalogDatabasePool
  ) throws -> Batch {
    // As the other batch writes: every bad identifier is reported at once.
    let named = try CatalogAssets.resolveNamed(identifiers, in: database)
    // The whole batch: the limit, archived, live usage.
    let candidates = try CatalogDeletion.plan(
      identifiers, in: database, includeUsed: includeUsed, keepRemote: true)
    var batch = Batch()
    for (identifier, asset) in named {
      guard let candidate = candidates.first(where: { $0.assetID == asset.id }) else {
        throw AssetCatalogError.assetNotFound(identifier)
      }
      let deletesRemote = CatalogDeletion.importedFrom(meta: asset.meta) == nil
      if deletesRemote {
        batch.deleting.append(identifier)
        if !batch.remoteBackendSlugs.contains(candidate.backendSlug) {
          batch.remoteBackendSlugs.append(candidate.backendSlug)
        }
      } else {
        batch.keeping.append(identifier)
      }
      batch.entries.append(DeletePlanJSON(candidate, deletesRemote: deletesRemote))
    }
    if !batch.deleting.isEmpty {
      _ = try CatalogDeletion.plan(batch.deleting, in: database, includeUsed: true)
    }
    return batch
  }

  private static func makeRemotes(
    for slugs: [String], in database: CatalogDatabasePool, remote: DeletionRemote
  ) async throws -> [String: any ObjectDeleting] {
    let backends = try await database.read { try Backend.fetchAll($0) }
    var remotes: [String: any ObjectDeleting] = [:]
    for backend in backends where slugs.contains(backend.slug) {
      remotes[backend.slug] = try remote(backend)
    }
    return remotes
  }

  // MARK: - Output

  private static func planOutput(_ entries: [DeletePlanJSON], format: OutputFormat) throws
    -> String
  {
    switch format {
    case .json:
      return try encodedJSON(DeleteDocument(plan: entries, results: []))
    case .table:
      let rows = entries.map {
        "\($0.sha256.prefix(12))\t\($0.key)\t\($0.backend)\t\($0.bytes)\t"
          + "\($0.deletesRemote ? "delete" : "keep")\t\($0.liveUsage)"
      }
      return (["SHA256\tKEY\tBACKEND\tBYTES\tOBJECT\tLIVE_USAGE"] + rows).joined(separator: "\n")
    }
  }

  /// The results, and the exit status: the one all unfinished deletes share,
  /// else 1.
  private static func report(
    _ purged: [PurgeResult], kept: [DeleteResultJSON], plan: [DeletePlanJSON],
    credentialFailures: [String: Int32], format: OutputFormat, in database: CatalogDatabasePool
  ) throws -> DeleteReport {
    // A refusal's words are on its tombstone, not on its outcome.
    let tombstones = try CatalogDeletion.pending(in: database)
    var results: [DeleteResultJSON] = []
    var notes: [String] = []
    var codes: [Int32] = []
    for result in purged {
      let outcome: String
      var error: String?
      switch result.outcome {
      case let .deleted(versioned):
        outcome = "deleted"
        if versioned {
          notes.append(
            "\(result.key): the bucket keeps versions; older ones stay until it removes them.")
        }
      case .alreadyGone:
        outcome = "already_gone"
      case .superseded:
        outcome = "superseded"
      case .refusedMismatch:
        outcome = "refused_mismatch"
        error = tombstones.first { $0.id == result.id }?.lastError
        codes.append(CLIExit.refused)
      case let .failed(message):
        outcome = "failed"
        error = message
        codes.append(credentialFailures[result.backendSlug] ?? CLIExit.remote)
      }
      if let error { notes.append("\(result.key): \(error)") }
      results.append(DeleteResultJSON(key: result.key, outcome: outcome, error: error))
    }
    results += kept

    let output: String
    switch format {
    case .json:
      output = try encodedJSON(DeleteDocument(plan: plan, results: results))
    case .table:
      let rows = results.map { "\($0.key)\t\($0.outcome)\t\(cell($0.error))" }
      output = (["KEY\tOUTCOME\tERROR"] + rows).joined(separator: "\n")
    }
    var report = DeleteReport(output: output, notes: notes)
    if !codes.isEmpty {
      let shared = Set(codes)
      report.failure = CLIError(
        exitCode: shared.count == 1 ? codes[0] : CLIExit.failure,
        description: "\(codes.count) of \(purged.count) deletes did not finish and stay owed. "
          + "`pinax delete --resume` carries them on.")
    }
    return report
  }

  /// One table cell: no tabs or line breaks, `-` when empty.
  private static func cell(_ text: String?) -> String {
    guard let text, !text.isEmpty else { return "-" }
    return text.split(whereSeparator: { $0 == "\t" || $0.isNewline }).joined(separator: " ")
  }
}

/// The status each backend's remote factory failed with.
private final class RemoteFailures: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String: Int32] = [:]

  var codes: [String: Int32] { lock.withLock { stored } }

  func note(_ error: Error, backend: String) {
    lock.withLock { stored[backend] = CLIExit.code(for: error) ?? CLIExit.failure }
  }
}
