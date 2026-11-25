import Foundation
import GRDB

public enum DomainMigrationError: Error, Equatable, CustomStringConvertible {
  /// The new prefix is not an http(s) URL with a host.
  case invalidDomain(String)
  case sameAsCurrent(String)
  /// No usage resolves to the backend, and no `--project` was given.
  case noProjects(backend: String)
  /// The preview's checks that were not `.ok`, as `url (result)`; nothing
  /// was written and the prefix is as it was.
  case targetsNotVerified(runID: Int64, [String])
  /// The backend's prefix is no longer the one the preview moved.
  case prefixMoved(backend: String, preview: String, current: String)
  /// A `from` that is not one of the backend's old domains.
  case notAnOldDomain(String, backend: String)

  public var description: String {
    switch self {
    case let .invalidDomain(value):
      return "“\(value)” isn’t an http(s) URL with a host."
    case let .sameAsCurrent(prefix):
      return "\(prefix) is already the backend’s URL prefix. To move only links on old domains to it, name them with --from."
    case let .noProjects(backend):
      return "No project’s usage resolves to \(backend). Name projects with --project."
    case let .targetsNotVerified(id, urls):
      return RewriteRuns.failedCheckListing(
        "Preview run \(id) has new URLs that failed the check; the prefix was not changed:", urls, runID: id)
    case let .prefixMoved(backend, preview, current):
      return "\(backend)’s URL prefix is \(current) now, not \(preview) as in the preview. Preview again."
    case let .notAnOldDomain(value, backend):
      return "\(value) isn’t an old domain of \(backend)."
    }
  }
}

/// Moves a backend to a new domain — check every new URL,
/// change the prefix, rewrite every project that uses it, rescan.
public enum DomainMigration {
  /// The rules: the current prefix, and unless `oldDomains` is empty each
  /// old domain, to `to`. An old domain that is `to` itself gets no rule
  /// (it would chain).
  public static func rules(current: String, oldDomains: [String], to: String) -> [RewriteRule] {
    ([current] + oldDomains.filter { !sameDomain($0, to) }).map { .prefix(from: $0, to: to) }
  }

  /// Projects with usage that resolves to the backend's assets, or whose
  /// raw URL sits under one of `prefixes`, by slug. Without
  /// `includeResolved`, only the ones under `prefixes` (moving old domains
  /// onto the current prefix).
  public static func referencingProjects(
    backendSlug: String, prefixes: [String], includeResolved: Bool = true, in database: DatabasePool
  ) throws -> [String] {
    try database.read { db in
      guard let backendID = try Backend.filter(Column("slug") == backendSlug).fetchOne(db)?.id else {
        throw CatalogConfigurationError.backendNotFound(backendSlug)
      }
      // `DomainLinks`' rule, as the counts use.
      let matches = prefixes.map { DomainLinks.condition("u.raw_url", prefix: $0) }
      let underPrefix = matches.map { " OR \($0.sql)" }.joined()
      var arguments: StatementArguments = [includeResolved ? backendID : -1]
      for match in matches { arguments += match.arguments }
      return try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT p.slug
          FROM usage u
          JOIN project p ON p.id = u.project_id
          LEFT JOIN asset a ON a.id = u.asset_id
          WHERE a.backend_id = ?\(underPrefix)
          ORDER BY p.slug
          """,
        arguments: arguments)
    }
  }

  /// Plans the move of `backendSlug` to `newPrefix` and records it as a
  /// `domain_migrate` preview. Every new URL is checked.
  ///
  /// `from` names old domains of the backend: with a new prefix they are
  /// the only old domains moved along with the current one; with
  /// `newPrefix` the current prefix (old domains onto the current one) they are
  /// required, are the only ones rewritten, and the prefix is not changed.
  /// `cancellation` and `progress` are `RewriteRuns.preview`'s.
  public static func preview(
    backend backendSlug: String,
    to newPrefix: String,
    from: [String] = [],
    projects: [String] = [],
    keepOldDomains: Bool = false,
    verifier: RewriteTargetVerifying,
    database: DatabasePool,
    git: GitStatusProviding = GitStatusProvider(),
    cancellation: ExternalMigrationCancellation? = nil,
    progress: (@Sendable (RewritePreviewProgress) -> Void)? = nil
  ) async throws -> RewritePreviewResult {
    let to = normalized(newPrefix)
    guard let url = URL(string: to), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host?.isEmpty == false
    else {
      throw DomainMigrationError.invalidDomain(newPrefix)
    }
    let map = try CatalogConfiguration.rewriteMap(backendSlug: backendSlug, in: database)
    let keepPrefix = sameDomain(map.current, to)
    guard !keepPrefix || !from.isEmpty else { throw DomainMigrationError.sameAsCurrent(map.current) }
    let backendID = try await database.read { try Backend.filter(Column("slug") == backendSlug).fetchOne($0)?.id }
    if !keepPrefix, let owner = try await database.read({
      try CatalogConfiguration.otherBackendOwning(to, besides: backendID, in: $0)
    }) {
      throw CatalogConfigurationError.domainOfOtherBackend(prefix: to, backend: owner)
    }
    var named: [String] = []
    for value in from {
      guard let old = map.retired.first(where: { sameDomain($0, value) }) else {
        throw DomainMigrationError.notAnOldDomain(normalized(value), backend: backendSlug)
      }
      if !named.contains(old) { named.append(old) }
    }
    let oldDomains =
      from.isEmpty
      ? (keepOldDomains ? [] : map.retired.filter { !sameDomain($0, to) })
      : map.retired.filter { named.contains($0) && !sameDomain($0, to) }
    let rules =
      keepPrefix
      ? oldDomains.map { RewriteRule.prefix(from: $0, to: map.current) }
      : rules(current: map.current, oldDomains: oldDomains, to: to)
    let slugs =
      projects.isEmpty
      ? try referencingProjects(
        backendSlug: backendSlug, prefixes: keepPrefix ? oldDomains : [map.current] + oldDomains,
        includeResolved: !keepPrefix, in: database)
      : projects
    guard !slugs.isEmpty else { throw DomainMigrationError.noProjects(backend: backendSlug) }
    return try await RewriteRuns.preview(
      targets: slugs.map { RewriteRunTarget(project: $0, rules: rules) },
      kind: .domainMigrate, backendID: backendID,
      domain: DomainMigrationParams(
        backend: backendSlug, from: map.current, to: keepPrefix ? map.current : to, oldDomains: oldDomains,
        keepOldDomains: keepOldDomains, keepPrefix: keepPrefix),
      verifier: verifier, database: database, git: git, cancellation: cancellation, progress: progress)
  }

  /// Writes preview run `baseID`: refuses when any of its checks was not
  /// `.ok`, then `RewriteRuns.apply`'s checks across every project; only
  /// when all pass does it change the prefix, then rewrite and rescan. The
  /// checks are not run again.
  public static func apply(
    fromRun baseID: Int64,
    allowedSources: Set<String>,
    database: DatabasePool,
    git: GitStatusProviding = GitStatusProvider(),
    backupRoot: URL = RewriteApplier.defaultBackupRoot(),
    processExists: (Int32) -> Bool = RunLog.processExists,
    commands: CommandSourcePolicy = .deny,
    runner: CommandSourceRunning = ShellCommandRunner(),
    phase: (@Sendable (RewriteApplyPhase) -> Void)? = nil
  ) throws -> RewriteApplyResult {
    guard let base = try RunLog.run(baseID, in: database, processExists: processExists) else {
      throw RewriteRunError.runNotFound(baseID)
    }
    guard base.kind == .domainMigrate else {
      throw RewriteRunError.notAPreview(baseID, reason: "it is a \(base.kind.rawValue) run")
    }
    guard base.dryRun else { throw RewriteRunError.notAPreview(baseID, reason: "it is not a preview") }
    guard base.state == .finished else {
      throw RewriteRunError.notAPreview(baseID, reason: "the preview is \(base.state.rawValue)")
    }
    let params = try JSONDecoder().decode(RewriteRunParams.self, from: Data(base.params.utf8))
    guard let domain = params.domain, params.verify else {
      throw RewriteRunError.notAPreview(baseID, reason: "it has no checked domain move")
    }
    let failed = try RewriteRuns.failedChecks(of: baseID, in: database)
    guard failed.isEmpty else { throw DomainMigrationError.targetsNotVerified(runID: baseID, failed) }
    let current = try CatalogConfiguration.rewriteMap(backendSlug: domain.backend, in: database).current
    guard current == domain.from else {
      throw DomainMigrationError.prefixMoved(backend: domain.backend, preview: domain.from, current: current)
    }
    // Moving old domains onto the current prefix only rewrites: no prefix change,
    // no `prefix_changed`.
    let changePrefix: (() throws -> [RunEvent])? =
      domain.keepPrefix
      ? nil
      : {
        // The old prefix becomes an old domain, so `URLResolver` knows both
        // URLs while the files are rewritten.
        phase?(.changingPrefix)
        _ = try CatalogConfiguration.setBackendURLPrefix(slug: domain.backend, urlPrefix: domain.to, in: database)
        return [.prefixChanged(PrefixChangedEvent(backend: domain.backend, from: domain.from, to: domain.to))]
      }
    return try RewriteRuns.apply(
      fromRun: baseID, allowedSources: allowedSources, kind: .domainMigrate, database: database,
      git: git, backupRoot: backupRoot, processExists: processExists, commands: commands,
      runner: runner, beforeWriting: changePrefix, phase: phase)
  }

  /// Trimmed, without trailing slashes — as `addOldDomain` stores it.
  static func normalized(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while result.last == "/" { result.removeLast() }
    return result
  }

  /// Equal with scheme and host compared without case, as rules match.
  static func sameDomain(_ a: String, _ b: String) -> Bool {
    func key(_ value: String) -> String {
      guard var components = URLComponents(string: normalized(value)) else { return normalized(value) }
      components.scheme = components.scheme?.lowercased()
      components.host = components.host?.lowercased()
      return components.string ?? normalized(value)
    }
    return key(a) == key(b)
  }
}
