import Foundation
import GRDB

/// Registering an old domain. `set-prefix` retires the
/// current prefix as it replaces it; an old domain is a retired prefix
/// added or removed on its own, so `URLResolver` — and with it the next
/// scan, the Usage page's Old Domains and Externals' Your Domains — knows
/// it. The current prefix is never touched.
extension CatalogConfiguration {
  /// The backend's old domains: its retired prefixes, oldest first, once
  /// each, without the current one — `rewriteMap`'s `retired`.
  public static func oldDomains(backendSlug: String, in database: DatabasePool) throws
    -> [String]
  {
    try rewriteMap(backendSlug: backendSlug, in: database).retired
  }

  /// Adds one `backend_prefix_history` row and returns the prefix as
  /// stored (trailing slashes trimmed, like `set-prefix`). One already
  /// there is left as it is.
  @discardableResult
  public static func addOldDomain(
    _ urlPrefix: String,
    backendSlug: String,
    in database: DatabasePool,
    now: Date = Date()
  ) throws -> String {
    let prefix = normalizedOldDomain(urlPrefix)
    guard let url = URL(string: prefix),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host?.isEmpty == false
    else {
      throw CatalogConfigurationError.invalidOldDomain(urlPrefix)
    }
    let retiredAt = ISO8601DateFormatter().string(from: now)
    return try database.write { db in
      guard let backend = try Backend.filter(Column("slug") == backendSlug).fetchOne(db),
        let backendID = backend.id
      else {
        throw CatalogConfigurationError.backendNotFound(backendSlug)
      }
      guard backend.urlPrefix != prefix else {
        throw CatalogConfigurationError.oldDomainIsCurrent(prefix)
      }
      if let owner = try otherBackendOwning(prefix, besides: backendID, in: db) {
        throw CatalogConfigurationError.domainOfOtherBackend(prefix: prefix, backend: owner)
      }
      let existing = try BackendPrefixHistory
        .filter(Column("backend_id") == backendID && Column("url_prefix") == prefix)
        .fetchCount(db)
      if existing == 0 {
        var row = BackendPrefixHistory(backendID: backendID, urlPrefix: prefix, retiredAt: retiredAt)
        try row.insert(db)
      }
      return prefix
    }
  }

  /// Deletes the backend's `backend_prefix_history` rows for the prefix
  /// and returns it as stored.
  @discardableResult
  public static func removeOldDomain(
    _ urlPrefix: String,
    backendSlug: String,
    in database: DatabasePool
  ) throws -> String {
    let prefix = normalizedOldDomain(urlPrefix)
    return try database.write { db in
      guard let backend = try Backend.filter(Column("slug") == backendSlug).fetchOne(db),
        let backendID = backend.id
      else {
        throw CatalogConfigurationError.backendNotFound(backendSlug)
      }
      let deleted = try BackendPrefixHistory
        .filter(Column("backend_id") == backendID && Column("url_prefix") == prefix)
        .deleteAll(db)
      guard deleted > 0 else {
        throw CatalogConfigurationError.oldDomainNotFound(backend: backendSlug, prefix: prefix)
      }
      return prefix
    }
  }

  /// The slug of a backend other than `backendID` whose current prefix or
  /// any `backend_prefix_history` row is `prefix`, scheme and host compared
  /// without case: a domain belongs to one backend. Conflicts already in the
  /// catalog are left alone; only the entries that add a domain refuse.
  static func otherBackendOwning(
    _ prefix: String, besides backendID: Int64?, in db: GRDB.Database
  ) throws -> String? {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id, slug, url_prefix FROM backend
        UNION ALL
        SELECT b.id, b.slug, h.url_prefix FROM backend_prefix_history h JOIN backend b ON b.id = h.backend_id
        ORDER BY 1
        """)
    for row in rows {
      let id: Int64 = row["id"]
      if id != backendID, DomainMigration.sameDomain(row["url_prefix"], prefix) { return row["slug"] }
    }
    return nil
  }

  /// The backend's domains with the references under each: the current
  /// prefix, then every old domain oldest first. A reference is a usage row
  /// of a project's latest scan whose raw URL sits under the prefix and
  /// `/`, by `DomainLinks`' rule.
  public static func domainLinkCounts(
    backendSlug: String, in database: DatabasePool
  ) throws -> DomainLinkCounts {
    let map = try rewriteMap(backendSlug: backendSlug, in: database)
    // Scheme and host ignore case, as the rewrite does.
    let links = try DomainLinks.counts(prefixes: [map.current] + map.retired, in: database)
    return DomainLinkCounts(
      current: DomainLinkCount(prefix: map.current, links: links[map.current] ?? 0),
      old: map.retired.map { DomainLinkCount(prefix: $0, links: links[$0] ?? 0) })
  }

  private static func normalizedOldDomain(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while result.last == "/" {
      result.removeLast()
    }
    return result
  }
}

public struct DomainLinkCount: Codable, Equatable, Sendable {
  public let prefix: String
  public let links: Int

  public init(prefix: String, links: Int) {
    self.prefix = prefix
    self.links = links
  }
}

/// `domainLinkCounts`: a backend's current domain and its old domains,
/// each with its number of references.
public struct DomainLinkCounts: Equatable, Sendable {
  public let current: DomainLinkCount
  public let old: [DomainLinkCount]
}
