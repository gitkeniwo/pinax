import ArgumentParser
import CatalogCore
import Foundation

typealias UsageOutputFormat = OutputFormat

struct UsageCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "usage",
    abstract: "Ingest and inspect source usage scans.",
    subcommands: [UsageSyncCommand.self, UsageScanCommand.self, UsageReportCommand.self]
  )
}

struct UsageSyncCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sync",
    abstract: "Atomically ingest a versioned usage document."
  )

  @Option(name: .long)
  var project: String

  @Option(name: [.short, .long], help: "Read JSON from a file instead of stdin.")
  var file: String?

  @Flag(name: .long, help: "Accept an empty scan after a nonempty scan.")
  var allowEmpty = false

  mutating func run() throws {
    let data: Data
    if let file {
      data = try Data(contentsOf: URL(fileURLWithPath: file))
    } else {
      data = FileHandle.standardInput.readDataToEndOfFile()
    }
    let document = try JSONDecoder().decode(UsageDocument.self, from: data)
    let result = try CatalogUsage.sync(
      document,
      project: project,
      in: openCatalogDatabase(),
      allowEmpty: allowEmpty
    )
    print("scan \(result.scanID): \(result.foundCount) refs")
  }
}

struct UsageScanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scan",
    abstract: "Scan a project's sources and ingest the result."
  )

  @Option(name: .long)
  var project: String

  @Flag(name: .long, help: "Print the usage document instead of ingesting it.")
  var dryRun = false

  @Flag(name: .long, help: "Run the project's command sources, with or without --dry-run.")
  var runCommands = false

  @Flag(name: .long, help: "Accept an empty scan after a nonempty scan.")
  var allowEmpty = false

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()))
  }

  /// `--dry-run`: the document as JSON, nothing written. Otherwise the
  /// `usage sync` line, then `F files, S skipped`.
  func output(in database: CatalogDatabasePool) throws -> String {
    let scan: UsageScanResult
    do {
      scan = try UsageScanner.scan(
        project: project, in: database, commands: runCommands ? .allow : .deny)
    } catch let error as CommandSourceError {
      guard case let .commandNotAllowed(label) = error else { throw error }
      throw RunCommandsRequired(label: label)
    }
    if dryRun { return try encodedJSON(scan.document) }
    let result = try CatalogUsage.sync(
      scan.document, project: project, in: database, allowEmpty: allowEmpty)
    return "scan \(result.scanID): \(result.foundCount) refs\n\(scan.files) files, \(scan.skipped) skipped"
  }
}

/// A scan reached a command source without `--run-commands`.
struct RunCommandsRequired: Error, Equatable, CustomStringConvertible {
  let label: String

  var description: String {
    "\(CommandSourceError.commandNotAllowed(label: label).description) "
      + "Add --run-commands to run this project's commands."
  }
}

struct UsageReportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "report",
    abstract: "Report live usages from a project's latest completed scan."
  )

  @Option(name: .long)
  var project: String

  @Option(name: .long)
  var format: UsageOutputFormat = .table

  @Flag(
    name: .long,
    help: "List only references still on an old domain; the table adds each one's current URL.")
  var oldDomains = false

  @Option(
    name: .long,
    help: "List only one file's references. Give its source reference, with or without #L<line>.")
  var source: String?

  mutating func run() async throws {
    let output = try await output(in: openCatalogDatabase())
    FileHandle.standardError.write(Data(output.notes.utf8))
    print(output.text, terminator: "")
  }

  /// What `run` writes: `notes` to standard error, then `text` (the table or
  /// the JSON document) to standard output.
  func output(in database: CatalogDatabasePool) async throws -> (notes: String, text: String) {
    let report = try await CatalogUsage.report(project: project, in: database)
    var notes = ""
    if !report.hasCompletedScan {
      notes = "Project '\(project)' has no completed usage scan.\n"
    }
    var items = report.items
    if let source {
      items = items.filter { Self.reference($0.sourceReference, isIn: source) }
    }
    // The plain table needs nothing about domains.
    var current: [ReportReferenceID: String] = [:]
    var old: Set<ReportReferenceID> = []
    if oldDomains || format == .json {
      let usage = try await CatalogUsage.liveUsage(project: project, in: database)
      for reference in usage.references {
        let id = ReportReferenceID(reference)
        current[id] = usage.assets[reference.assetID]?.url
        if reference.isOldDomain { old.insert(id) }
      }
    }
    if oldDomains {
      items = items.filter { old.contains(ReportReferenceID($0)) }
    }
    switch format {
    case .json:
      let document = UsageReportDocument(
        schema: report.schema, project: report.project,
        items: items.map {
          let id = ReportReferenceID($0)
          return UsageReportItemJSON(item: $0, oldDomain: old.contains(id), currentURL: current[id])
        })
      return (notes, try encodedJSON(document) + "\n")
    case .table:
      var table = "SHA256\tKEY\tKIND\tSOURCE\tURL" + (oldDomains ? "\tNEW_URL" : "") + "\n"
      for item in items {
        table +=
          "\(item.sha256.map { String($0.prefix(12)) } ?? "external")\t\(item.key ?? "")\t\(item.kind)\t\(item.sourceReference)\t\(item.rawURL)"
        if oldDomains { table += "\t\(current[ReportReferenceID(item)] ?? "")" }
        table += "\n"
      }
      return (notes, table)
    }
  }

  /// Whether `reference` is `file` itself or one of its lines, `file#L<n>`.
  static func reference(_ reference: String, isIn file: String) -> Bool {
    if reference == file { return true }
    guard reference.hasPrefix(file + "#L") else { return false }
    let line = reference.dropFirst(file.count + 2)
    return !line.isEmpty && line.allSatisfy { ("0"..."9").contains($0) }
  }
}

struct OrphansCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "orphans",
    abstract: "List active, unpinned assets with no live usage."
  )

  @Option(name: .long)
  var project: String?

  @Option(name: .long)
  var minScans = 2

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    let output = try output(in: openCatalogDatabase())
    FileHandle.standardError.write(Data(output.notes.utf8))
    print(output.table, terminator: "")
    FileHandle.standardError.write(Data(output.trailer.utf8))
  }

  /// What `run` writes: `notes` and `trailer` to standard error, before and
  /// after the `table` (or the JSON document) on standard output.
  func output(in database: CatalogDatabasePool) throws
    -> (notes: String, table: String, trailer: String)
  {
    guard minScans > 0 else {
      throw ValidationError("Minimum scans must be greater than zero.")
    }
    let report = try CatalogUsage.orphans(
      project: project,
      minimumScans: minScans,
      in: database
    )
    var notes =
      "WARNING: orphan results are a lower bound. Do not use this list as proof that remote objects are unused.\n"
    if let project {
      notes +=
        "Scope: only project '\(project)' is considered. Usage in other projects is ignored.\n"
    }
    if !report.unscannedProjects.isEmpty {
      notes +=
        "Fewer than \(minScans) completed scans: "
        + report.unscannedProjects.joined(separator: ", ") + "\n"
    }
    var table = "SHA256\tKEY\tURL\n"
    for item in report.assets {
      table += "\(item.asset.sha256.prefix(12))\t\(item.asset.key)\t\(item.url)\n"
    }
    if format == .json {
      table =
        try encodedJSON(OrphanDocument(report, project: project, minimumScans: minScans)) + "\n"
    }
    // The assets left out because their every project is not tracked.
    var trailer = ""
    if !report.untracked.isEmpty {
      trailer =
        "\(report.untracked.count) assets only in not-tracked projects: "
        + report.untrackedProjects.joined(separator: ", ") + "\n"
    }
    return (notes, table, trailer)
  }
}

struct ExternalsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "externals",
    abstract: "List unmatched URLs in the latest completed usage scans.",
    subcommands: [ExternalsListCommand.self, ExternalsImportCommand.self, ExternalsMigrateCommand.self],
    defaultSubcommand: ExternalsListCommand.self
  )
}

/// `pinax externals [--project SLUG]` — the listing; it is the default
/// subcommand so the bare form keeps working.
struct ExternalsListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List unmatched URLs in the latest completed usage scans."
  )

  @Option(name: .long)
  var project: String?

  @Option(name: .long)
  var format: OutputFormat = .table

  @Option(
    name: .long,
    help: "List only URLs on your domains (yours: a backend's current or old prefix) or the rest (other).")
  var domain: ExternalDomain?

  mutating func run() async throws {
    print(try await output(in: openCatalogDatabase()), terminator: "")
  }

  func output(in database: CatalogDatabasePool) async throws -> String {
    if format == .table && domain == nil {
      let items = try CatalogUsage.externals(project: project, in: database)
      return Self.table(items.map { ($0.kind, $0.sourceReference, $0.rawURL) })
    }
    var references = try await CatalogUsage.externalReferences(project: project, in: database)
      .references
    if let domain { references = references.filter { $0.domain == domain } }
    if format == .json {
      return try encodedJSON(
        ExternalListDocument(project: project, items: references.map(ExternalJSON.init))) + "\n"
    }
    return Self.table(references.map { ($0.kind, $0.sourceReference, $0.rawURL) })
  }

  private static func table(_ rows: [(kind: String, source: String, url: String)]) -> String {
    rows.reduce("KIND\tSOURCE\tURL\n") { $0 + "\($1.kind)\t\($1.source)\t\($1.url)\n" }
  }
}

extension ExternalDomain: ExpressibleByArgument {}
