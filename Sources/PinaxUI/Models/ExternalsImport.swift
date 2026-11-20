import CatalogCore
import Foundation
import GRDB

// Externals ▸ Your Domains ▸ Import into Catalog.
// Every sentence the import shows is produced here by pure functions, so the
// tests assert the real strings; the views only lay them out.

/// The claim core as the GUI uses it (`ExternalsClaim`), behind a seam
/// so tests drive a temporary catalog and a fake fetcher.
public protocol ExternalsClaiming: Sendable {
  /// What the sheet and the cells need before any GET: each row's
  /// canonical fetch URL, which target backends have no CDN sample, and
  /// the projects' names.
  func prepare(_ rows: [ExternalReference]) async throws -> ExternalImportPreparation

  /// One run of the claim core over `urls` (nil: every Your Domains URL in
  /// `project`'s scope). `events` reports each claim GET as it starts and
  /// ends, and the core's progress.
  func claim(
    project: String?, urls: [String]?, cancellation: ExternalsClaimCancellation,
    events: @escaping @Sendable (ExternalImportEvent) -> Void
  ) async throws -> ExternalsClaimResult
}

public struct ExternalImportPreparation: Equatable, Sendable {
  /// Raw URL → the URL the core will GET (the key under the backend's
  /// current prefix). Absent for a row the core will not fetch (another
  /// backend's domain, a key no upload makes).
  public var fetchURLs: [String: String]
  /// Target backends with no image Pinax uploaded itself: the CDN check has
  /// nothing to compare.
  public var uncheckableBackends: Set<String>
  /// Project slug → name.
  public var projectNames: [String: String]

  public init(
    fetchURLs: [String: String] = [:], uncheckableBackends: Set<String> = [],
    projectNames: [String: String] = [:]
  ) {
    self.fetchURLs = fetchURLs
    self.uncheckableBackends = uncheckableBackends
    self.projectNames = projectNames
  }
}

public enum ExternalImportEvent: Sendable, Equatable {
  /// A GET to this URL started (a CDN sample's too).
  case started(String)
  case finished(String, succeeded: Bool)
  case progress(ExternalsClaimProgress)
}

/// The app's claimer: the catalog, the public fetcher, and the core.
public struct CatalogExternalsClaimer: ExternalsClaiming {
  private let database: DatabasePool
  private let fetcher: any PublicObjectFetching
  private let maxConcurrentFetches: Int

  public init(
    database: DatabasePool,
    fetcher: any PublicObjectFetching = URLSessionPublicObjectFetcher(),
    maxConcurrentFetches: Int = 8
  ) {
    self.database = database
    self.fetcher = fetcher
    self.maxConcurrentFetches = maxConcurrentFetches
  }

  public func prepare(_ rows: [ExternalReference]) async throws -> ExternalImportPreparation {
    try await database.read { db in
      let projects = try Project.fetchAll(db)
      let bySlug = Dictionary(uniqueKeysWithValues: projects.map { ($0.slug, $0) })
      let backends = Dictionary(
        uniqueKeysWithValues: try Backend.fetchAll(db).compactMap { b in b.id.map { ($0, b) } })
      var retired: [Int64: [String]] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT backend_id, url_prefix FROM backend_prefix_history ORDER BY id")
      {
        retired[row["backend_id"], default: []].append(row["url_prefix"])
      }
      var fetchURLs: [String: String] = [:]
      var targets = Set<Int64>()
      // The core's own resolution (ExternalsClaim.Plan): the project's
      // backend only, never a transform path or a slash key.
      for row in rows where row.domain == .yours && fetchURLs[row.rawURL] == nil {
        guard let project = bySlug[row.projectSlug], let backendID = project.backendID,
          let backend = backends[backendID], row.match?.backendSlug == backend.slug,
          let key = URLResolver.key(
            from: row.rawURL, backend: backend, retiredPrefixes: retired[backendID] ?? []),
          !key.isEmpty, !key.hasPrefix("/"), !key.hasPrefix("cdn-cgi/")
        else { continue }
        fetchURLs[row.rawURL] = URLResolver.url(forKey: key, backend: backend)
        targets.insert(backendID)
      }
      var uncheckable = Set<String>()
      for backendID in targets {
        // The CDN check's sample set: assets with no `imported_from` (the core's query).
        let samples =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM asset WHERE backend_id = ? AND meta NOT LIKE '%imported_from%'",
            arguments: [backendID]) ?? 0
        if samples == 0, let slug = backends[backendID]?.slug { uncheckable.insert(slug) }
      }
      return ExternalImportPreparation(
        fetchURLs: fetchURLs, uncheckableBackends: uncheckable,
        projectNames: Dictionary(uniqueKeysWithValues: projects.map { ($0.slug, $0.name) }))
    }
  }

  public func claim(
    project: String?, urls: [String]?, cancellation: ExternalsClaimCancellation,
    events: @escaping @Sendable (ExternalImportEvent) -> Void
  ) async throws -> ExternalsClaimResult {
    try await ExternalsClaim.run(
      project: project, urls: urls, in: database,
      fetcher: ObservedFetcher(base: fetcher, events: events),
      maxConcurrentFetches: maxConcurrentFetches, cancellation: cancellation,
      progress: { events(.progress($0)) })
  }
}

/// Reports each GET's start and end; the bytes pass through untouched.
struct ObservedFetcher: PublicObjectFetching {
  let base: any PublicObjectFetching
  let events: @Sendable (ExternalImportEvent) -> Void

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    let object = try await fetchObject(url)
    return (object.data, object.mime, object.contentLength)
  }

  func fetchObject(_ url: URL) async throws -> PublicObject {
    events(.started(url.absoluteString))
    do {
      let object = try await base.fetchObject(url)
      events(.finished(url.absoluteString, succeeded: true))
      return object
    } catch {
      events(.finished(url.absoluteString, succeeded: false))
      throw error
    }
  }
}

// MARK: - The sheet

public struct ExternalImportConfirmation: Equatable, Sendable {
  public struct Line: Equatable, Sendable {
    public let label: String
    public let value: String
  }

  public let title: String
  public let subtitle: String
  public let lines: [Line]
  /// No image to check the CDN against.
  public let cdnWarning: String?
  public let finePrint: String
  /// While the CDN check runs.
  public let checkingText: String
  /// The URLs to claim; nil = Import All (the scope's every URL).
  public let urls: [String]?
  /// Distinct URLs.
  public let imageCount: Int
  public let host: String

  public static let finePrintText = "Objects stay where they are; nothing is uploaded or deleted."
  static let explanation =
    "Pinax downloads each image once to fingerprint it, then adds it to the catalog at the address it already has."
  static let cdnWarningText =
    "Pinax can’t check whether the CDN changes bytes on this domain: none of your catalog’s images were uploaded by Pinax yet."

  /// - Parameters:
  ///   - rows: the rows to import (any number per URL).
  ///   - importAll: Import All… — claim by scope, not by URL list.
  public static func make(
    rows: [ExternalReference], importAll: Bool, preparation: ExternalImportPreparation
  ) -> ExternalImportConfirmation {
    let urls = ExternalsImportFacts.distinctURLs(rows)
    let count = urls.count
    let host = ExternalsImportFacts.hosts(rows)
    let slugs = ExternalsImportFacts.distinct(rows.map(\.projectSlug))
    let project =
      slugs.count == 1
      ? preparation.projectNames[slugs[0]] ?? slugs[0] : "the projects that use them"
    let targets = Set(
      rows.filter { preparation.fetchURLs[$0.rawURL] != nil }.compactMap(\.match?.backendSlug))
    let uncheckable = !targets.isDisjoint(with: preparation.uncheckableBackends)
    return ExternalImportConfirmation(
      title: "Import \(count.formatted()) \(count == 1 ? "Image" : "Images") into the Catalog?",
      subtitle: "From \(host). \(explanation)",
      lines: [
        Line(label: "Images", value: count.formatted()),
        Line(
          label: "Downloads",
          value: "about \(count.formatted()) \(count == 1 ? "download" : "downloads")"),
        Line(label: "Project", value: project),
      ],
      cdnWarning: uncheckable ? cdnWarningText : nil,
      finePrint: finePrintText,
      checkingText: "Checking that \(host) serves the original bytes…",
      urls: importAll ? nil : urls, imageCount: count, host: host)
  }
}

/// The CDN check refused the batch: nothing was written.
public struct ExternalImportRefusal: Equatable, Sendable {
  public let title: String
  public let subtitle: String
  public let lines: [ExternalImportConfirmation.Line]
  public let advice: String

  public static let titleText = "Nothing Was Imported"
  static let adviceText =
    "This usually means image optimization (such as Cloudflare Polish) is on for this domain. Turn it off, then import again."

  public static func make(_ checks: [CDNByteCheck], host: String) -> ExternalImportRefusal {
    let refused = checks.filter { $0.status == .rewritesBytes }
    let checked = refused.reduce(0) { $0 + $1.matched + $1.mismatched.count }
    let changed = refused.reduce(0) { $0 + $1.mismatched.count }
    return ExternalImportRefusal(
      title: titleText,
      subtitle:
        "The CDN for \(host) changed the bytes of images Pinax uploaded, so it can’t fingerprint the images on this domain. Nothing was imported.",
      lines: [
        .init(label: "Images checked", value: checked.formatted()),
        .init(label: "Changed by the CDN", value: changed.formatted()),
      ],
      advice: adviceText)
  }
}

/// What the import sheet shows.
public enum ExternalImportSheet: Equatable, Sendable {
  /// `checking`: Import was pressed and the CDN check is running.
  case confirm(ExternalImportConfirmation, checking: Bool)
  case refused(ExternalImportRefusal)
}

// MARK: - Failures

/// Why a row stayed in Your Domains after an import: the four categories
/// the grid's badge distinguishes, with the cause behind "skipped".
public enum ExternalImportFailure: Equatable, Sendable {
  public enum Category: String, CaseIterable, Sendable {
    case notFound, sameImage, otherBackend, skipped
  }

  public enum Cause: Equatable, Sendable {
    case cloudflarePath
    case badKey
    case pendingDeletion
    case forbidden
    case downloadFailed(String?)
    case incomplete
    case notInYourDomains
  }

  case notFound
  case sameImage(existingKey: String)
  /// The backend whose domain the link is on.
  case otherBackend(String?)
  case skipped(Cause)

  /// The core's skip, read for `row` (same image under another key, another
  /// backend, a `/cdn-cgi/image/` URL, and the fetch failures).
  public static func make(_ skip: ExternalsClaimSkip, row: ExternalReference) -> ExternalImportFailure {
    switch skip.reason {
    case ExternalsClaimSkipReason.notFound: return .notFound
    case ExternalsClaimSkipReason.sameContent:
      return .sameImage(existingKey: skip.existingKey ?? "")
    case ExternalsClaimSkipReason.otherBackend: return .otherBackend(row.match?.backendSlug)
    case ExternalsClaimSkipReason.badKey:
      return .skipped((skip.key ?? "").hasPrefix("cdn-cgi/") ? .cloudflarePath : .badKey)
    case ExternalsClaimSkipReason.pendingDeletion: return .skipped(.pendingDeletion)
    case ExternalsClaimSkipReason.forbidden: return .skipped(.forbidden)
    case ExternalsClaimSkipReason.lengthMismatch: return .skipped(.incomplete)
    case ExternalsClaimSkipReason.notInYourDomains: return .skipped(.notInYourDomains)
    default: return .skipped(.downloadFailed(skip.detail))
    }
  }

  public var category: Category {
    switch self {
    case .notFound: .notFound
    case .sameImage: .sameImage
    case .otherBackend: .otherBackend
    case .skipped: .skipped
    }
  }

  /// The badge's symbol: a shape per category, so colour is never alone.
  public static func symbol(_ category: Category) -> String {
    switch category {
    case .notFound: "rectangle.slash"
    case .sameImage: "square.on.square"
    case .otherBackend: "externaldrive"
    case .skipped: "xmark"
    }
  }

  public var symbol: String { Self.symbol(category) }

  /// The list's words before Kind, and the grid's caption line.
  public var label: String {
    switch self {
    case .notFound: "Not found"
    case let .sameImage(key): "Same image as \(key)"
    case let .otherBackend(slug): slug.map { "On another backend (\($0))" } ?? "On another backend"
    case let .skipped(cause): "Skipped: \(Self.causeLabel(cause))"
    }
  }

  /// The grid cell's caption line.
  public var caption: String {
    self == .notFound ? "Not found in the bucket" : label
  }

  /// The inspector's line under the name.
  public var inspectorSubtitle: String {
    switch self {
    case .notFound: "On your domain, not in the bucket"
    case .sameImage: "Same image is already in the catalog"
    case .otherBackend: "On another backend’s domain"
    case .skipped: "On your domain, not in the catalog"
    }
  }

  /// The inspector's Import group: the word, then the whole explanation.
  public var inspectorStatus: String {
    self == .notFound ? "Not found" : "Skipped"
  }

  public var explanation: String {
    switch self {
    case .notFound:
      "The bucket has no object at this key. If the file name has a space, write the link as ![](<…>) so the whole name is kept."
    case let .sameImage(key):
      "Same image as \(key), which is already in the catalog. Pinax keeps one record per image."
    case let .otherBackend(slug):
      "The link is on \(slug ?? "another backend")’s domain, but its project uses another backend. Pinax imports an image only into a project on the backend that serves it."
    case let .skipped(cause):
      switch cause {
      case .cloudflarePath:
        "The link is a Cloudflare image transform, not an object’s address. Link the original image to import it."
      case .badKey:
        "The link’s path starts with a slash or is empty, so it names no object Pinax could import."
      case .pendingDeletion:
        "An image at this key is being deleted permanently. Finish or undo that in Archived first."
      case .forbidden:
        "The host refused the download (403). Make the object public, then import again."
      case let .downloadFailed(detail):
        "The download failed\(detail.map { ": \($0)" } ?? ""). Import again to retry."
      case .incomplete:
        "The download was shorter than the host said. Import again to retry."
      case .notInYourDomains:
        "The link is no longer in Your Domains."
      }
    }
  }

  static func causeLabel(_ cause: Cause) -> String {
    switch cause {
    case .cloudflarePath: "Cloudflare path"
    case .badKey: "not an object key"
    case .pendingDeletion: "being deleted"
    case .forbidden: "access denied"
    case .downloadFailed: "download failed"
    case .incomplete: "download incomplete"
    case .notInYourDomains: "not in Your Domains"
    }
  }

  /// "4 not found", "2 same image", "2 other backend", "1 skipped".
  static func countPhrase(_ category: Category, _ count: Int) -> String {
    let noun =
      switch category {
      case .notFound: "not found"
      case .sameImage: "same image"
      case .otherBackend: "other backend"
      case .skipped: "skipped"
      }
    return "\(count.formatted()) \(noun)"
  }
}

// MARK: - The result bar

public struct ExternalImportSummary: Equatable, Sendable {
  public let title: String
  public let detail: String?
  /// Show in Usage: only when something was imported and the run finished.
  public let offersUsage: Bool

  static let doneDetail =
    "Find them in Usage. Reindex can’t rebuild imported images from the bucket; catalog backups keep them."

  /// - Parameters:
  ///   - imported: images claimed.
  ///   - requested: distinct URLs the run was asked for (the sheet's count).
  ///   - failures: this run's rows that stayed, one per URL.
  public static func make(
    imported: Int, requested: Int, failures: [ExternalImportFailure], cancelled: Bool
  ) -> ExternalImportSummary {
    var parts = [
      cancelled
        ? "Imported \(imported.formatted()) of \(requested.formatted())"
        : "Imported \(imported.formatted())"
    ]
    for category in ExternalImportFailure.Category.allCases {
      let count = failures.count { $0.category == category }
      if count > 0 { parts.append(ExternalImportFailure.countPhrase(category, count)) }
    }
    if cancelled {
      parts.append("Cancelled")
      let rest = max(requested - imported, 0)
      return ExternalImportSummary(
        title: parts.joined(separator: " · "),
        detail: "The other \(rest.formatted()) are still here. Import All picks up where it stopped.",
        offersUsage: false)
    }
    return ExternalImportSummary(
      title: parts.joined(separator: " · "), detail: imported > 0 ? doneDetail : nil,
      offersUsage: imported > 0)
  }
}

// MARK: - The batch in flight

/// A cell's mark while a batch runs: a spinner, then ✓ and dimmed.
public enum ExternalImportCellState: Equatable, Sendable {
  case importing
  case imported
}

/// The status bar's import: the sentence, the bar, the stop button.
public struct ExternalImportActivity: Equatable, Sendable {
  public let text: String
  public let completed: Int
  public let total: Int
  public let isStopping: Bool

  public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

  /// "Importing from img.example.invalid… 57 of 189"; one image: "Importing
  /// a.png…".
  public static func make(
    label: ExternalImportLabel, completed: Int, total: Int, isStopping: Bool = false
  ) -> ExternalImportActivity {
    let text =
      switch label {
      case let .host(host): "Importing from \(host)… \(completed.formatted()) of \(total.formatted())"
      case let .image(name): "Importing \(name)…"
      }
    return ExternalImportActivity(
      text: text, completed: completed, total: total, isStopping: isStopping)
  }
}

public enum ExternalImportLabel: Equatable, Sendable {
  case host(String)
  case image(String)
}

/// Shared facts about rows.
enum ExternalsImportFacts {
  static func distinct(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  /// A selection's URLs, each once, in row order.
  static func distinctURLs(_ rows: [ExternalReference]) -> [String] {
    distinct(rows.map(\.rawURL))
  }

  /// The domains the rows are on — the prefix matched, as the group header
  /// shows it — joined: "a.invalid", "a.invalid and b.invalid".
  static func hosts(_ rows: [ExternalReference]) -> String {
    let hosts = distinct(
      rows.map { row in
        let prefix = row.match?.prefix ?? row.rawURL
        return URL(string: prefix)?.host?.lowercased() ?? prefix
      })
    switch hosts.count {
    case 0: return ""
    case 1: return hosts[0]
    case 2: return "\(hosts[0]) and \(hosts[1])"
    default: return hosts.dropLast().joined(separator: ", ") + ", and \(hosts.last!)"
    }
  }
}
