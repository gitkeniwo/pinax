import CryptoKit
import Foundation
import GRDB
@testable import CatalogCore
import Testing

/// A shipped migration is never edited, only followed by a new one. Every
/// catalog in the wild ran `v1_initial` as it first shipped; the statements it executes are pinned here by
/// digest, so adding a table or changing a column in it fails the suite.
@Suite struct MigrationBytesTests {
  @Test("v1_initial executes exactly the statements it shipped with")
  func v1IsFrozen() throws {
    let statements = StatementLog()
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      db.trace { event in
        if case .statement(let statement) = event { statements.append(statement.sql) }
      }
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try CatalogCore.Database.migrator.migrate(queue, upTo: "v1_initial")

    // The migrator's own bookkeeping (transactions, `grdb_migrations`,
    // foreign key checks) belongs to GRDB, not to the migration.
    let schema = statements.all.filter { sql in
      let upper = sql.uppercased()
      return !upper.contains("GRDB_MIGRATIONS") && !upper.hasPrefix("PRAGMA")
        && !upper.hasPrefix("BEGIN") && !upper.hasPrefix("COMMIT")
        && !upper.hasPrefix("SAVEPOINT") && !upper.hasPrefix("RELEASE")
        && !upper.hasPrefix("SELECT")
    }
    let digest = SHA256.hash(data: Data(schema.joined(separator: "\n").utf8))
      .map { String(format: "%02x", $0) }.joined()
    #expect(schema.count == 18)
    #expect(digest == "d377741c47efc20fadd2158c502556506cb107359356d56be1d30a4a54ce205a")
  }
}

private final class StatementLog: @unchecked Sendable {
  private let lock = NSLock()
  private var statements: [String] = []
  func append(_ sql: String) { lock.withLock { statements.append(sql) } }
  var all: [String] { lock.withLock { statements } }
}
