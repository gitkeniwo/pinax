import ArgumentParser
import CatalogCore
import Foundation

// Reports over what CatalogCore already reads for the app; this file only
// lays them out.

/// What identifies a reference within one project's scan.
struct ReportReferenceID: Hashable {
  let sourceReference: String
  let rawURL: String
  let kind: String

  init(_ reference: LiveUsageReference) {
    sourceReference = reference.sourceReference
    rawURL = reference.rawURL
    kind = reference.kind
  }

  init(_ item: UsageReportItem) {
    sourceReference = item.sourceReference
    rawURL = item.rawURL
    kind = item.kind
  }
}

// MARK: - pinax usage report

/// The document `usage report --format json` has always printed (`schema` 1),
/// each item with two more keys.
struct UsageReportDocument: Encodable {
  let schema: Int
  let project: String
  let items: [UsageReportItemJSON]
}

/// `UsageReportItem` as it encodes itself, so its keys stay as they were
/// (`sha256` and `key` are absent for an external URL), then `old_domain` and
/// `current_url`, which is `null` for an external URL.
struct UsageReportItemJSON: Encodable {
  let item: UsageReportItem
  let oldDomain: Bool
  /// The asset's URL on its backend's current prefix.
  let currentURL: String?

  private struct Added: Encodable {
    let oldDomain: Bool
    @ExplicitNull var currentURL: String?

    enum CodingKeys: String, CodingKey {
      case oldDomain = "old_domain"
      case currentURL = "current_url"
    }
  }

  func encode(to encoder: Encoder) throws {
    try item.encode(to: encoder)
    try Added(oldDomain: oldDomain, currentURL: currentURL).encode(to: encoder)
  }
}

// MARK: - pinax used-in

struct UsedInCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "used-in",
    abstract: "List the references to an asset in the latest completed usage scans."
  )

  @Argument(help: "An exact key or an unambiguous SHA-256 prefix.")
  var identifier: String

  @Option(name: .long, help: "Only this project's references.")
  var project: String?

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() async throws {
    let output = try await output(in: openCatalogDatabase())
    FileHandle.standardError.write(Data(output.notes.utf8))
    print(output.text, terminator: "")
  }

  func output(in database: CatalogDatabasePool) async throws -> (notes: String, text: String) {
    let asset = try await CatalogAssets.resolve(identifier, in: database)
    guard let assetID = asset.asset.id else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    // The read behind the inspector's Used In group.
    let usage = try await CatalogUsage.liveUsage(project: project, assetID: assetID, in: database)
    // Without a scan, an empty list says nothing about the asset.
    var notes = ""
    if usage.scannedProjects.isEmpty {
      notes =
        project.map { "Project '\($0)' has no completed usage scan.\n" }
        ?? "No project has a completed usage scan.\n"
    }
    if format == .json {
      let document = UsedInDocument(asset: asset, project: project, usage: usage)
      return (notes, try encodedJSON(document) + "\n")
    }
    var table = "PROJECT\tSOURCE\tKIND\tURL\tOLD_DOMAIN\n"
    for reference in usage.references {
      table +=
        "\(reference.projectSlug)\t\(reference.sourceReference)\t\(reference.kind)\t\(reference.rawURL)\t\(reference.isOldDomain)\n"
    }
    return (notes, table)
  }
}

struct UsedInDocument: Encodable {
  let schema = "pinax.used-in.v1"
  let sha256: String
  let key: String
  /// The asset's URL on its backend's current prefix.
  let url: String
  @ExplicitNull var project: String?
  /// The projects in scope with a completed scan.
  let scannedProjects: [String]
  let references: [UsedInReferenceJSON]

  init(asset: CatalogAssetItem, project: String?, usage: LiveUsageSet) {
    sha256 = asset.asset.sha256
    key = asset.asset.key
    url = asset.url
    self.project = project
    scannedProjects = usage.scannedProjects.sorted()
    references = usage.references.map {
      UsedInReferenceJSON(
        project: $0.projectSlug, sourceReference: $0.sourceReference, rawURL: $0.rawURL,
        kind: $0.kind, oldDomain: $0.isOldDomain)
    }
  }

  enum CodingKeys: String, CodingKey {
    case schema, sha256, key, url, project, references
    case scannedProjects = "scanned_projects"
  }
}

struct UsedInReferenceJSON: Encodable {
  let project: String
  let sourceReference: String
  let rawURL: String
  let kind: String
  let oldDomain: Bool

  enum CodingKeys: String, CodingKey {
    case project, kind
    case sourceReference = "source_ref"
    case rawURL = "raw_url"
    case oldDomain = "old_domain"
  }
}

// MARK: - pinax stats

struct StatsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stats",
    abstract: "Show the catalog's totals and uploads by day.",
    discussion: "Days are in the local time zone; set TZ to use another."
  )

  @Option(name: .long)
  var project: String?

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() async throws {
    print(try await output(in: openCatalogDatabase(), timeZone: .current), terminator: "")
  }

  /// The table is the single numbers, a blank line, then one row per day with
  /// uploads. The breakdowns are in the JSON only.
  func output(in database: CatalogDatabasePool, timeZone: TimeZone) async throws -> String {
    // Gregorian whatever the user's calendar is: the dates are `YYYY-MM-DD`.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let stats = try await CatalogStats.load(project: project, calendar: calendar, in: database)
    let document = StatsDocument(stats, calendar: calendar)
    if format == .json {
      return try encodedJSON(document) + "\n"
    }
    let lines: [(String, String)] = [
      ("project", stats.project ?? "all"),
      ("assets", "\(stats.assets.count)"),
      ("bytes", "\(stats.assets.bytes)"),
      ("favorites", "\(stats.favorites)"),
      ("archived", "\(stats.archived)"),
      ("tagged", "\(stats.tagged)"),
      ("untagged", "\(stats.untagged)"),
      ("used_images", "\(stats.usedImages)"),
      ("orphan_candidates", "\(stats.orphanCandidates.count)"),
      ("orphan_candidate_bytes", "\(stats.orphanCandidates.bytes)"),
      ("externals_on_your_domains", "\(stats.yourDomains)"),
      ("old_domain_references", "\(stats.oldDomains)"),
      ("time_zone", document.timeZone),
    ]
    var table = lines.map { "\($0.0): \($0.1)\n" }.joined()
    table += "\nDATE\tCOUNT\tBYTES\n"
    for day in document.uploadsByDay {
      table += "\(day.date)\t\(day.count)\t\(day.bytes)\n"
    }
    return table
  }
}

struct StatsDocument: Encodable {
  let schema = "pinax.stats.v1"
  @ExplicitNull var project: String?
  let timeZone: String
  let assets: StatsTotalJSON
  let favorites: Int
  let archived: Int
  let tagged: Int
  let untagged: Int
  let usedImages: Int
  let orphanCandidates: StatsTotalJSON
  let externalsOnYourDomains: Int
  let oldDomainReferences: Int
  /// Oldest first; a day without uploads has no entry.
  let uploadsByDay: [StatsDayJSON]
  let tags: [StatsTagJSON]
  let kinds: [StatsShareJSON]
  let backends: [StatsShareJSON]
  let projects: [StatsProjectJSON]
  let projectShares: [StatsProjectShareJSON]

  init(_ stats: CatalogStats, calendar: Calendar) {
    project = stats.project
    timeZone = calendar.timeZone.identifier
    assets = StatsTotalJSON(stats.assets)
    favorites = stats.favorites
    archived = stats.archived
    tagged = stats.tagged
    untagged = stats.untagged
    usedImages = stats.usedImages
    orphanCandidates = StatsTotalJSON(stats.orphanCandidates)
    externalsOnYourDomains = stats.yourDomains
    oldDomainReferences = stats.oldDomains
    uploadsByDay = stats.uploadsByDay.sorted { $0.key < $1.key }.map { start, total in
      let day = calendar.dateComponents([.year, .month, .day], from: start)
      return StatsDayJSON(
        date: String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0),
        count: total.count, bytes: total.bytes)
    }
    tags = stats.tags.map { StatsTagJSON(name: $0.name, count: $0.total.count) }
    kinds = stats.kinds.map(StatsShareJSON.init)
    backends = stats.backends.map(StatsShareJSON.init)
    projects = stats.projects.map(StatsProjectJSON.init)
    projectShares = stats.projectShares.map {
      StatsProjectShareJSON(
        name: $0.name.isEmpty ? nil : $0.name, count: $0.total.count, bytes: $0.total.bytes)
    }
  }

  enum CodingKeys: String, CodingKey {
    case schema, project, assets, favorites, archived, tagged, untagged, tags, kinds, backends
    case projects
    case timeZone = "time_zone"
    case usedImages = "used_images"
    case orphanCandidates = "orphan_candidates"
    case externalsOnYourDomains = "externals_on_your_domains"
    case oldDomainReferences = "old_domain_references"
    case uploadsByDay = "uploads_by_day"
    case projectShares = "project_shares"
  }
}

struct StatsTotalJSON: Encodable {
  let count: Int
  let bytes: Int64

  init(_ total: CatalogStats.Total) {
    count = total.count
    bytes = total.bytes
  }
}

struct StatsDayJSON: Encodable {
  let date: String
  let count: Int
  let bytes: Int64
}

/// A tag has no byte total.
struct StatsTagJSON: Encodable {
  let name: String
  let count: Int
}

struct StatsShareJSON: Encodable {
  let name: String
  let count: Int
  let bytes: Int64

  init(_ share: CatalogStats.Share) {
    name = share.name
    count = share.total.count
    bytes = share.total.bytes
  }
}

/// Assets by project name; `name` is `null` for those in no project.
struct StatsProjectShareJSON: Encodable {
  @ExplicitNull var name: String?
  let count: Int
  let bytes: Int64
}

struct StatsProjectJSON: Encodable {
  let slug: String
  let name: String
  let usedImages: Int
  let orphanCandidates: Int
  let externalsOnYourDomains: Int
  let externalsOnOtherDomains: Int
  @ExplicitNull var lastScanAt: String?
  /// `tracked` or `not-tracked`.
  let usageTracking: String

  init(_ usage: CatalogStats.ProjectUsage) {
    slug = usage.slug
    name = usage.name
    usedImages = usage.used
    orphanCandidates = usage.orphanCandidates
    externalsOnYourDomains = usage.yourDomains
    externalsOnOtherDomains = usage.otherDomains
    lastScanAt = usage.lastScanAt
    switch usage.usageTracking {
    case .tracked: usageTracking = "tracked"
    case .notTracked: usageTracking = "not-tracked"
    }
  }

  enum CodingKeys: String, CodingKey {
    case slug, name
    case usedImages = "used_images"
    case orphanCandidates = "orphan_candidates"
    case externalsOnYourDomains = "externals_on_your_domains"
    case externalsOnOtherDomains = "externals_on_other_domains"
    case lastScanAt = "last_scan_at"
    case usageTracking = "usage_tracking"
  }
}
