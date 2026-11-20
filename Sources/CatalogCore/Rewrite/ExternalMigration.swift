import Foundation
import GRDB

public enum ExternalMigrationError: Error, Equatable, CustomStringConvertible {
  /// Another preparation or apply is running in this process.
  case busy
  case noTargets
  /// The project has no backend of its own and the catalog has more than
  /// one (or none).
  case noBackend(project: String)
  /// The projects default to different backends; name one.
  case backendsDiffer([String])
  /// The preparation's downloads are gone or changed; nothing was uploaded.
  case cacheInvalid(runID: Int64, [String])

  public var description: String {
    switch self {
    case .busy:
      return "Another migration is running. Wait for it to finish."
    case .noTargets:
      return "No URLs to migrate."
    case let .noBackend(project):
      return "Project \(project) has no backend to upload to."
    case let .backendsDiffer(pairs):
      return "The projects upload to different backends (\(pairs.joined(separator: ", "))). Migrate them one backend at a time."
    case let .cacheInvalid(id, problems):
      return RewriteRuns.failedCheckListing(
        "The downloads of preparation \(id) are gone or changed; nothing was uploaded. Prepare again:",
        problems, runID: id)
    }
  }
}

/// Stopped from anywhere; Task cancellation works too.
public final class ExternalMigrationCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  public init() {}

  public func cancel() {
    lock.withLock { flag = true }
  }

  public var isCancelled: Bool {
    lock.withLock { flag } || Task.isCancelled
  }
}

public struct ExternalMigrationProgress: Equatable, Sendable {
  public enum Phase: String, Sendable { case download, upload }

  public let phase: Phase
  public let done: Int
  public let total: Int
  /// The host of the URL just finished.
  public let host: String?

  public init(phase: Phase, done: Int, total: Int, host: String?) {
    self.phase = phase
    self.done = done
    self.total = total
    self.host = host
  }
}

/// What `prepare` or `apply` recorded. `state` is `finished`, `cancelled`
/// or (apply, a backend error) `failed`.
public struct ExternalMigrationResult: Sendable {
  public let runID: Int64
  public let state: RunState
  public let summary: RewriteRunSummary
  public let events: [RunEvent]
}

/// Copies images other sites host into the project's backend and rewrites
/// the references. `prepare` only downloads; `apply` uploads, checks, then
/// rewrites through the rewrite engine.
public enum ExternalMigration {
  /// `~/Library/Application Support/tech.gitkeniwo.pinax/migrate-downloads/`
  /// beside `rewrite-backups`.
  public static func defaultCacheRoot(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    homeDirectory.appendingPathComponent(
      "Library/Application Support/tech.gitkeniwo.pinax/migrate-downloads", isDirectory: true)
  }

  public static let maximumConcurrency = 4

  /// Whether a preparation or apply is running in this process.
  public static var isRunning: Bool { gate.isHeld }

  // MARK: - Pure rules

  /// A tip for a host, from the fixed table.
  public static func hostTip(host: String) -> String? {
    let host = host.lowercased()
    if host.hasSuffix(".r2.dev") { return "Your other bucket" }
    if host == "upload.wikimedia.org" || host == "wikipedia.org" || host.hasSuffix(".wikipedia.org") {
      return "Usually asks for attribution"
    }
    return nil
  }

  /// The template a migration renders keys with. A template
  /// with `{hash}` is used as is; otherwise `-{hash}` goes before the last
  /// `.{ext}`, or at the end without one. The project's template is not
  /// changed.
  public static func migrationTemplate(_ template: String) -> String {
    let hash = KeyTemplatePlaceholder.hash.token
    guard !template.contains(hash) else { return template }
    let ext = "." + KeyTemplatePlaceholder.ext.token
    if let range = template.range(of: ext, options: .backwards) {
      return template.replacingCharacters(in: range, with: "-\(hash)\(ext)")
    }
    return template + "-\(hash)"
  }

  /// The file name: the URL path's last segment without the query, decoded;
  /// with no extension, or one that names another type, the extension of
  /// the sniffed `mime`. A known image extension of another type is
  /// replaced; anything else (`.php`, `.v2`) is kept and the right one
  /// added.
  public static func filename(for rawURL: String, mime: String) -> String {
    let recorded = AssetProvenance.recordedURL(rawURL)
    let path = URL(string: recorded)?.path ?? ""
    var name = path.split(separator: "/").last.map(String.init) ?? ""
    name = name.removingPercentEncoding ?? name
    name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    while name.hasPrefix(".") { name.removeFirst() }
    if name.isEmpty { name = "image" }
    guard let wanted = fileExtension(forMIME: mime) else { return name }
    let current = (name as NSString).pathExtension
    if !current.isEmpty, MimeDetector.mimeType(forExtension: current) == mime { return name }
    if !current.isEmpty, MimeDetector.mimeType(forExtension: current) != nil {
      return (name as NSString).deletingPathExtension + "." + wanted
    }
    return name + "." + wanted
  }

  static func fileExtension(forMIME mime: String) -> String? {
    switch mime {
    case "image/png": return "png"
    case "image/jpeg": return "jpg"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/heic": return "heic"
    case "image/tiff": return "tiff"
    case "image/svg+xml": return "svg"
    default: return nil
    }
  }

  /// A download error as a `download_failed` reason.
  static func failure(url: String, host: String, error: Error) -> DownloadFailedEvent {
    let detail = String(describing: error)
    func event(_ reason: DownloadFailedEvent.Reason, _ status: Int? = nil) -> DownloadFailedEvent {
      DownloadFailedEvent(url: url, host: host, reason: reason, status: status, detail: detail)
    }
    switch error {
    case PublicObjectFetchError.notFound: return event(.httpStatus, 404)
    case PublicObjectFetchError.forbidden: return event(.httpStatus, 403)
    case let PublicObjectFetchError.failed(_, text):
      if text.hasPrefix("HTTP "), let status = Int(text.dropFirst(5)) { return event(.httpStatus, status) }
      let lowered = text.lowercased()
      if lowered.contains("timed out") { return event(.timeout) }
      if lowered.contains("hostname could not be found") || lowered.contains("dns") { return event(.dns) }
      return event(.failed)
    case let error as URLError:
      switch error.code {
      case .timedOut: return event(.timeout)
      case .cannotFindHost, .dnsLookupFailed: return event(.dns)
      default: return event(.failed)
      }
    default:
      return event(.failed)
    }
  }

  /// A backend-level error stops the run; anything else
  /// fails one image. The status is the storage's HTTP answer, if any.
  static func uploadFailure(_ error: Error) -> (fatal: Bool, status: Int?) {
    switch error {
    case let S3UploaderError.http(status, _):
      return ([401, 403, 404].contains(status), status)
    case S3UploaderError.invalidEndpoint:
      return (true, nil)
    case let error as URLError:
      let unreachable: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
        .timedOut, .secureConnectionFailed, .networkConnectionLost,
      ]
      return (unreachable.contains(error.code), nil)
    default:
      return (false, nil)
    }
  }

  // MARK: - Shared

  /// The rewrite plans for `newURLs` (raw URL → new URL): one exact rule
  /// per URL a target names and `newURLs` has; projects with none are left
  /// out.
  static func plans(
    _ targets: [ExternalMigrationTarget], newURLs: [String: String], database: CatalogDatabasePool,
    git: GitStatusProviding
  ) throws -> [RewritePlan] {
    try targets.compactMap { target in
      let rules = target.urls.compactMap { url in newURLs[url].map { RewriteRule.exact(from: url, to: $0) } }
      guard !rules.isEmpty else { return nil }
      return try RewritePlanner.plan(project: target.project, rules: rules, database: database, git: git)
    }
  }

  /// `project/source/path` → (sha256, edits digest) of every file with edits.
  static func plannedFiles(_ plans: [RewritePlan]) -> [String: (sha256: String, digest: String)] {
    var files: [String: (String, String)] = [:]
    for plan in plans {
      for file in plan.files where file.newContent != nil {
        files["\(plan.project)/\(file.sourceLabel)/\(file.path)"] =
          (file.originalSHA256, RewriteRuns.editsDigest(file.edits))
      }
    }
    return files
  }

  /// The project as the upload pipeline should see it: its template with
  /// `{hash}` ensured.
  static func migrationProject(_ project: Project) -> Project {
    var copy = project
    copy.keyTemplate = migrationTemplate(project.keyTemplate ?? KeyTemplate.defaultTemplate)
    return copy
  }

  static func host(of url: String) -> String {
    URL(string: AssetProvenance.recordedURL(url))?.host?.lowercased() ?? ""
  }

  /// Deletes a preparation's downloads (public for the GUI's Discard); an
  /// apply from that run then refuses `cacheInvalid`.
  public static func removeCache(_ runID: Int64, root: URL = defaultCacheRoot()) {
    try? FileManager.default.removeItem(at: root.appendingPathComponent(String(runID), isDirectory: true))
  }

  /// One migration at a time in the process.
  static let gate = MigrationGate()

  final class MigrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false

    var isHeld: Bool { lock.withLock { held } }

    func enter() throws {
      try lock.withLock {
        guard !held else { throw ExternalMigrationError.busy }
        held = true
      }
    }

    func leave() {
      lock.withLock { held = false }
    }
  }
}
