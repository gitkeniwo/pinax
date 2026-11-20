import ArgumentParser
import CatalogCore
import Foundation

/// `pinax backend old-domain add|rm|ls`. Each command's
/// `output(in:)` is what `run()` prints, so tests drive the parsed command
/// against a temporary catalog.
struct BackendOldDomainCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "old-domain",
    abstract: "Register URL prefixes a backend used to serve from, without changing its current one.",
    subcommands: [BackendOldDomainList.self, BackendOldDomainAdd.self, BackendOldDomainRemove.self]
  )
}

struct BackendOldDomainList: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ls")

  @Argument var backend: String

  @Option(help: "table or json.")
  var format: RewriteOutputFormat = .table

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()), terminator: "")
  }

  /// One old domain per line, oldest first, with its number of links after
  /// a tab. JSON adds the current domain.
  func output(in database: CatalogDatabasePool) throws -> String {
    let counts = try CatalogConfiguration.domainLinkCounts(backendSlug: backend, in: database)
    if format == .json {
      return try encodedJSON(OldDomainsJSON(backend: backend, current: counts.current, oldDomains: counts.old)) + "\n"
    }
    return counts.old.map { "\($0.prefix)\t\($0.links)\n" }.joined()
  }
}

/// `pinax backend old-domain ls --format json`.
struct OldDomainsJSON: Encodable {
  let schema = "pinax.old-domains.v1"
  let backend: String
  let current: DomainLinkCount
  let oldDomains: [DomainLinkCount]

  enum CodingKeys: String, CodingKey {
    case schema, backend, current
    case oldDomains = "old_domains"
  }
}

struct BackendOldDomainAdd: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add")

  @Argument var backend: String
  @Argument var prefix: String

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()))
  }

  /// Registers the prefix and returns it as stored.
  func output(in database: CatalogDatabasePool) throws -> String {
    try CatalogConfiguration.addOldDomain(prefix, backendSlug: backend, in: database)
  }
}

struct BackendOldDomainRemove: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "rm")

  @Argument var backend: String
  @Argument var prefix: String

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()))
  }

  /// Removes the registration and returns the prefix as stored.
  func output(in database: CatalogDatabasePool) throws -> String {
    try CatalogConfiguration.removeOldDomain(prefix, backendSlug: backend, in: database)
  }
}
