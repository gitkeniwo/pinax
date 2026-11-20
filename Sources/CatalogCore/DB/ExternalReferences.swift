import Foundation
import GRDB

/// Which half of the Externals report an unmatched URL belongs to.
public enum ExternalDomain: String, CaseIterable, Sendable {
  /// On one of your backends' current or retired prefixes, but not in the
  /// catalog.
  case yours
  /// Anywhere else.
  case other
}

/// One unmatched reference of a project's latest completed scan, with its
/// half of the report.
public struct ExternalReference: Identifiable, Equatable, Sendable {
  public let projectSlug: String
  public let sourceReference: String
  public let rawURL: String
  public let kind: String
  public let domain: ExternalDomain
  /// The prefix that put it in Your Domains; nil in Other Domains.
  public let match: ExternalDomainMatch?

  public init(
    projectSlug: String, sourceReference: String, rawURL: String, kind: String,
    domain: ExternalDomain, match: ExternalDomainMatch? = nil
  ) {
    self.projectSlug = projectSlug
    self.sourceReference = sourceReference
    self.rawURL = rawURL
    self.kind = kind
    self.domain = domain
    self.match = match
  }

  /// `usage`'s unique key: project, source, URL, kind.
  public var id: String {
    [projectSlug, sourceReference, rawURL, kind].joined(separator: "\u{0}")
  }
}

/// Which backend prefix resolves a Your Domains URL: the
/// backend's current one, or one of its retired ones.
public struct ExternalDomainMatch: Hashable, Sendable {
  public let backendSlug: String
  public let prefix: String
  public let isCurrent: Bool

  public init(backendSlug: String, prefix: String, isCurrent: Bool) {
    self.backendSlug = backendSlug
    self.prefix = prefix
    self.isCurrent = isCurrent
  }
}

/// The unmatched references in a scope and each project's configured
/// sources (for the Open File rule).
public struct ExternalReferenceSet: Equatable, Sendable {
  /// Ordered by project slug, source reference, URL, kind — `externals`'
  /// order.
  public let references: [ExternalReference]
  public let projectSources: [String: [ProjectSource]]

  public init(references: [ExternalReference], projectSources: [String: [ProjectSource]]) {
    self.references = references
    self.projectSources = projectSources
  }
}

extension CatalogUsage {
  /// A URL is on your domains when any backend's current prefix or
  /// one of its retired ones resolves it — the resolver's own test, so a
  /// prefix registered as an old domain moves its URLs here.
  public static func externalDomain(
    _ rawURL: String, backends: [Backend], retiredPrefixes: [Int64: [String]]
  ) -> ExternalDomain {
    let resolves = backends.contains { backend in
      let retired = backend.id.flatMap { retiredPrefixes[$0] } ?? []
      return URLResolver.key(from: rawURL, backend: backend, retiredPrefixes: retired) != nil
    }
    return resolves ? .yours : .other
  }

  /// The prefix behind `externalDomain`'s `.yours` — a current
  /// prefix ahead of any retired one, backends in the order given; nil
  /// exactly when `externalDomain` is `.other`.
  public static func externalDomainMatch(
    _ rawURL: String, backends: [Backend], retiredPrefixes: [Int64: [String]]
  ) -> ExternalDomainMatch? {
    for backend in backends where URLResolver.key(from: rawURL, backend: backend) != nil {
      return ExternalDomainMatch(backendSlug: backend.slug, prefix: backend.urlPrefix, isCurrent: true)
    }
    for backend in backends {
      for prefix in backend.id.flatMap({ retiredPrefixes[$0] }) ?? []
      where URLResolver.key(from: rawURL, backend: backend, retiredPrefixes: [prefix]) != nil {
        return ExternalDomainMatch(backendSlug: backend.slug, prefix: prefix, isCurrent: false)
      }
    }
    return nil
  }

  /// Read-only: `externals`' rows — every project, or the one
  /// named — each with its project and its half of the report.
  public static func externalReferences(
    project slug: String? = nil,
    in database: CatalogDatabasePool
  ) async throws -> ExternalReferenceSet {
    try await database.read { db in
      var projectsRequest = Project.order(Column("slug"))
      if let slug {
        projectsRequest = projectsRequest.filter(Column("slug") == slug)
        guard try projectsRequest.fetchCount(db) == 1 else {
          throw UsageCatalogError.projectNotFound(slug)
        }
      }
      let projects = try projectsRequest.fetchAll(db)
      var conditions = ["u.asset_id IS NULL", "u.last_scan_id = p.last_scan_id"]
      var arguments: [DatabaseValueConvertible?] = []
      if let slug {
        conditions.append("p.slug = ?")
        arguments.append(slug)
      }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT p.slug, u.raw_url, u.source_ref, u.kind
          FROM usage u
          JOIN project p ON p.id = u.project_id
          WHERE \(conditions.joined(separator: " AND "))
          ORDER BY p.slug, u.source_ref, u.raw_url, u.kind
          """,
        arguments: StatementArguments(arguments))
      let backends = try Backend.order(Column("id")).fetchAll(db)
      var retired: [Int64: [String]] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT backend_id, url_prefix FROM backend_prefix_history ORDER BY id")
      {
        retired[row["backend_id"], default: []].append(row["url_prefix"])
      }
      return ExternalReferenceSet(
        references: rows.map { row in
          let rawURL: String = row["raw_url"]
          return ExternalReference(
            projectSlug: row["slug"], sourceReference: row["source_ref"], rawURL: rawURL,
            kind: row["kind"],
            domain: externalDomain(rawURL, backends: backends, retiredPrefixes: retired),
            match: externalDomainMatch(rawURL, backends: backends, retiredPrefixes: retired))
        },
        projectSources: Dictionary(
          uniqueKeysWithValues: projects.map { ($0.slug, ProjectSettings(meta: $0.meta).sources) }))
    }
  }
}
