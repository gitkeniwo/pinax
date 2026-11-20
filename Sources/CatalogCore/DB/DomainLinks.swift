import Foundation
import GRDB

/// The one rule for "a link on a domain", shared
/// by every count (Settings' Domains, Projects' Links use, Usage's domain
/// menu, the move sheet's projects) and by the rewrite engine's prefix
/// rules: a raw URL of a project's latest scan that starts with the prefix
/// and `/`, scheme and host ignoring case, the path as stored. In the
/// catalog or not, it counts.
public enum DomainLinks {
  /// `url` sits under `prefix` + `/` — `RewriteRule.prefix`'s own test.
  public static func isUnder(_ url: String, prefix: String) -> Bool {
    RewriteRules.isUnder(url, prefix: RewriteRules.trimmingTrailingSlashes(prefix))
  }

  /// The SQL form of `isUnder` on `column`. SQLite's `lower` and the
  /// rule's own lowercasing both touch ASCII only; `substr` counts
  /// characters, so the lengths are in Unicode scalars.
  static func condition(_ column: String, prefix: String) -> (sql: String, arguments: StatementArguments) {
    let base = RewriteRules.trimmingTrailingSlashes(prefix)
    let split = base.utf8.index(base.startIndex, offsetBy: RewriteRules.originLength(base))
    let origin = String(base[..<split]).asciiLowercased
    let rest = String(base[split...]) + "/"
    let originLength = origin.unicodeScalars.count
    return (
      "(lower(substr(\(column), 1, ?)) = ? AND substr(\(column), ?, ?) = ?)",
      [originLength, origin, originLength + 1, rest.unicodeScalars.count, rest]
    )
  }

  /// Links under each prefix, in every project or in `project` only.
  public static func counts(
    prefixes: [String], project: String? = nil, in database: DatabasePool
  ) throws -> [String: Int] {
    try database.read { db in try counts(prefixes: prefixes, project: project, db: db) }
  }

  static func counts(prefixes: [String], project: String?, db: GRDB.Database) throws -> [String: Int] {
    var result: [String: Int] = [:]
    for prefix in prefixes where result[prefix] == nil {
      let match = condition("u.raw_url", prefix: prefix)
      var sql = """
        SELECT COUNT(*) FROM usage u JOIN project p ON p.id = u.project_id
        WHERE u.last_scan_id = p.last_scan_id AND \(match.sql)
        """
      var arguments = match.arguments
      if let project {
        sql += " AND p.slug = ?"
        arguments += [project]
      }
      result[prefix] = try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }
    return result
  }

  /// Links under any of `prefixes`, by project slug; projects with none
  /// are left out.
  public static func countsByProject(prefixes: [String], in database: DatabasePool) throws -> [String: Int] {
    guard !prefixes.isEmpty else { return [:] }
    let matches = prefixes.map { condition("u.raw_url", prefix: $0) }
    var arguments: StatementArguments = []
    for match in matches { arguments += match.arguments }
    return try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT p.slug AS slug, COUNT(*) AS links FROM usage u JOIN project p ON p.id = u.project_id
          WHERE u.last_scan_id = p.last_scan_id AND (\(matches.map(\.sql).joined(separator: " OR ")))
          GROUP BY p.slug
          """,
        arguments: arguments)
      return Dictionary(uniqueKeysWithValues: rows.map { ($0["slug"] as String, $0["links"] as Int) })
    }
  }
}

extension String {
  /// A–Z to a–z, nothing else: what SQLite's `lower` does.
  var asciiLowercased: String {
    String(String.UnicodeScalarView(unicodeScalars.map { (65...90).contains($0.value) ? Unicode.Scalar($0.value + 32)! : $0 }))
  }
}
