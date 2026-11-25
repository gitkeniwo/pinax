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
    abstract: "Scan a project's source folders and ingest the result."
  )

  @Option(name: .long)
  var project: String

  @Flag(name: .long, help: "Print the usage document instead of ingesting it.")
  var dryRun = false

  @Flag(name: .long, help: "Accept an empty scan after a nonempty scan.")
  var allowEmpty = false

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()))
  }

  /// `--dry-run`: the document as JSON, nothing written. Otherwise the
  /// `usage sync` line, then `F files, S skipped`.
  func output(in database: CatalogDatabasePool) throws -> String {
    let scan = try UsageScanner.scan(project: project, in: database)
    if dryRun { return try encodedJSON(scan.document) }
    let result = try CatalogUsage.sync(
      scan.document, project: project, in: database, allowEmpty: allowEmpty)
    return "scan \(result.scanID): \(result.foundCount) refs\n\(scan.files) files, \(scan.skipped) skipped"
  }
}

struct UsageReportCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "report",
    abstract: "Report live usages from a project's latest completed scan."
  )

  @Option(name: .long)
  var project: String

  @Option(name: .long)
  var format: UsageOutputFormat = .table

  mutating func run() throws {
    let report = try CatalogUsage.report(project: project, in: openCatalogDatabase())
    if !report.hasCompletedScan {
      let hint = "Project '\(project)' has no completed usage scan.\n"
      FileHandle.standardError.write(Data(hint.utf8))
    }
    switch format {
    case .json:
      print(try encodedJSON(report))
    case .table:
      print("SHA256\tKEY\tKIND\tSOURCE\tURL")
      for item in report.items {
        print(
          "\(item.sha256.map { String($0.prefix(12)) } ?? "external")\t\(item.key ?? "")\t\(item.kind)\t\(item.sourceReference)\t\(item.rawURL)"
        )
      }
    }
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

  mutating func run() async throws {
    let database = try openCatalogDatabase()
    if format == .json {
      let set = try await CatalogUsage.externalReferences(project: project, in: database)
      print(
        try encodedJSON(
          ExternalListDocument(project: project, items: set.references.map(ExternalJSON.init))))
      return
    }
    let items = try CatalogUsage.externals(project: project, in: database)
    print("KIND\tSOURCE\tURL")
    for item in items {
      print("\(item.kind)\t\(item.sourceReference)\t\(item.rawURL)")
    }
  }
}
