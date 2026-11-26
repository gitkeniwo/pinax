import CatalogCore
import Foundation

/// What the Externals page needs of the core's
/// `ExternalMigration`. Tests stub it; the app's is `CatalogExternalsMigrator`.
public protocol ExternalsMigrating: Sendable {
  /// A preparation or apply is running in this process.
  var isRunning: Bool { get }

  func prepare(
    targets: [ExternalMigrationTarget], cancellation: ExternalMigrationCancellation,
    progress: @escaping @Sendable (ExternalMigrationProgress) -> Void
  ) async throws -> ExternalMigrationPreparation

  func apply(
    fromRun runID: Int64, allowedSources: Set<String>, cancellation: ExternalMigrationCancellation,
    progress: @escaping @Sendable (ExternalMigrationProgress) -> Void
  ) async throws -> ExternalMigrationResult

  /// The preparation's changes as one unified diff (Show Changes…).
  func diff(ofRun runID: Int64) async throws -> String

  /// Discard: deletes the preparation's downloads; the run stays.
  func discardPreparation(ofRun runID: Int64)
}

/// A finished preparation and the bucket it would upload to.
public struct ExternalMigrationPreparation: Sendable {
  public var result: ExternalMigrationResult
  /// "image-hosting": the backend's bucket.
  public var bucket: String?
  /// The backend's kind ("r2", "s3"), the sheet's small tag.
  public var storageKind: String?

  public init(result: ExternalMigrationResult, bucket: String?, storageKind: String? = nil) {
    self.result = result
    self.bucket = bucket
    self.storageKind = storageKind
  }
}

/// The app's migrator: the catalog, the public fetcher, the Keychain's
/// credentials and the migration core, in this process.
public struct CatalogExternalsMigrator: ExternalsMigrating {
  private let database: CatalogDatabasePool
  private let fetcher: any PublicObjectFetching
  private let credentialsLoader: @Sendable (Backend) throws -> BackendCredentials?
  /// The migration core's download cache; tests pass a temporary one.
  private let cacheRoot: URL
  /// For the rescans after an apply.
  let commands: CommandSourcePolicy
  private let runner: CommandSourceRunning

  public init(
    database: CatalogDatabasePool,
    fetcher: any PublicObjectFetching = URLSessionPublicObjectFetcher(),
    credentialsLoader: @escaping @Sendable (Backend) throws -> BackendCredentials? = {
      try Keychain().load(for: $0.keychainRef)
    },
    cacheRoot: URL = ExternalMigration.defaultCacheRoot(),
    commands: CommandSourcePolicy = .deny,
    runner: CommandSourceRunning = ShellCommandRunner()
  ) {
    self.commands = commands
    self.runner = runner
    self.cacheRoot = cacheRoot
    self.database = database
    self.fetcher = fetcher
    self.credentialsLoader = credentialsLoader
  }

  public var isRunning: Bool { ExternalMigration.isRunning }

  public func prepare(
    targets: [ExternalMigrationTarget], cancellation: ExternalMigrationCancellation,
    progress: @escaping @Sendable (ExternalMigrationProgress) -> Void
  ) async throws -> ExternalMigrationPreparation {
    let result = try await ExternalMigration.prepare(
      targets: targets, database: database, fetcher: fetcher, cacheRoot: cacheRoot,
      cancellation: cancellation, progress: progress)
    let backend = try backend(ofRun: result.runID)
    return ExternalMigrationPreparation(result: result, bucket: backend?.bucket, storageKind: backend?.kind)
  }

  public func apply(
    fromRun runID: Int64, allowedSources: Set<String>, cancellation: ExternalMigrationCancellation,
    progress: @escaping @Sendable (ExternalMigrationProgress) -> Void
  ) async throws -> ExternalMigrationResult {
    guard let backend = try backend(ofRun: runID) else { throw RewriteRunError.runNotFound(runID) }
    guard let credentials = try credentialsLoader(backend) else {
      throw UploadCatalogError.missingCredentials(backend.slug)
    }
    return try await ExternalMigration.apply(
      fromRun: runID, allowedSources: allowedSources, database: database,
      uploader: S3Uploader(backend: backend, credentials: credentials), cacheRoot: cacheRoot,
      cancellation: cancellation, progress: progress, commands: commands, runner: runner)
  }

  public func diff(ofRun runID: Int64) async throws -> String {
    let database = database
    return try await Task.detached { try Self.diff(ofRun: runID, database: database) }.value
  }

  /// Off the main actor.
  private static func diff(ofRun runID: Int64, database: CatalogDatabasePool) throws -> String {
    guard let run = try RunLog.run(runID, in: database) else { throw RewriteRunError.runNotFound(runID) }
    let params = try JSONDecoder().decode(ExternalMigrationParams.self, from: Data(run.params.utf8))
    var newURLs: [String: String] = [:]
    for record in try RunLog.events(of: runID, in: database) {
      if case let .migrationPlanned(event) = record.event { newURLs[event.url] = event.newURL }
    }
    var parts: [String] = []
    for target in params.targets {
      let rules = target.urls.compactMap { url in newURLs[url].map { RewriteRule.exact(from: url, to: $0) } }
      guard !rules.isEmpty else { continue }
      let plan = try RewritePlanner.plan(project: target.project, rules: rules, database: database)
      for file in plan.files {
        guard let newContent = file.newContent else { continue }
        parts.append(
          RewriteDiff.unified(
            label: file.sourceLabel, path: file.path,
            old: String(decoding: file.originalContent, as: UTF8.self),
            new: String(decoding: newContent, as: UTF8.self)))
      }
    }
    return parts.joined()
  }

  public func discardPreparation(ofRun runID: Int64) {
    ExternalMigration.removeCache(runID, root: cacheRoot)
  }

  /// The run's backend, by the slug its params name.
  private func backend(ofRun runID: Int64) throws -> Backend? {
    guard let run = try RunLog.run(runID, in: database) else { return nil }
    let params = try JSONDecoder().decode(ExternalMigrationParams.self, from: Data(run.params.utf8))
    return try CatalogConfiguration.backends(in: database).first { $0.slug == params.backend }
  }
}

// MARK: - The confirmation sheet

/// Everything the sheet shows, read from the preparation's summary and
/// events alone: the sheet does not compute anything again.
public struct ExternalMigrationConfirmation: Equatable, Sendable {
  /// A summary row — its sidebar-style icon, the label, and
  /// its value as runs of figures and units; the old line under it is the
  /// row's tooltip.
  public struct Line: Equatable, Sendable {
    /// The icon's hue, as the log's tallies colour the same things.
    public enum Tone: Equatable, Sendable { case upload, reused, skipped, files, bucket, keys }

    /// A run of the value: a figure (medium), a unit (secondary), a key's
    /// faint date prefix or extension, or its hash (accent).
    public struct Segment: Equatable, Sendable {
      public enum Style: Equatable, Sendable { case figure, unit, plain, faint, hash }
      public let text: String
      public let style: Style
      /// What stands before it within its group: a space, the size's own
      /// (maybe non-breaking) space, nothing inside a key.
      public var gap = " "
    }

    public let label: String
    public let tone: Tone
    /// Groups drawn with a thin divider between them.
    public let groups: [[Segment]]
    public var detail: String?
    public var isWarning = false
    public var isMonospaced = false
    /// A small tag after the value: the storage's kind, "R2".
    public var tag: String?

    /// The value as one line, the groups joined by " · ".
    public var value: String {
      groups.map(Self.text).joined(separator: " · ")
    }

    /// A group's runs, each after its gap.
    public static func text(_ group: [Segment]) -> String {
      group.enumerated().map { ($0.offset == 0 ? "" : $0.element.gap) + $0.element.text }.joined()
    }
  }

  public struct Host: Equatable, Sendable, Identifiable {
    public let host: String
    public let tip: String?
    /// A broken host's tip is orange.
    public let isWarning: Bool
    public let links: Int
    /// The host's images to upload, in bytes; nil when none (a broken
    /// host's row leaves it empty).
    public var bytes: Int64?
    /// One of them is at or over the large line.
    public var hasLarge = false
    public var id: String { host }
  }

  /// One image to upload, from its `download_finished`.
  public struct Image: Equatable, Sendable, Identifiable {
    public let url: String
    public let filename: String
    public let host: String
    public let bytes: Int64
    public var id: String { url }
    public var isLarge: Bool { PinaxFormat.isLarge(bytes) }
  }

  /// A source that is not clean: written only once its box is ticked.
  public struct Source: Equatable, Sendable, Identifiable {
    /// `project/label`, as `apply(allowedSources:)` takes it.
    public let id: String
    public let text: String
  }

  public let runID: Int64
  /// Links that would change (migratable plus reused).
  public let links: Int
  public let lines: [Line]
  public let hosts: [Host]
  public let sources: [Source]
  /// The images to upload, largest first; reused ones are not uploaded.
  public var images: [Image] = []

  public static let subtitle =
    "Pinax has downloaded them. Migrating uploads each image to your bucket, adds it to the library and rewrites the links in your files. It doesn’t commit."
  public static let tip =
    "Tip: images from other sites may be under copyright. Keep any credit their owners ask for."

  public var title: String { "Migrate \(PinaxFormat.count(links, singular: "Link")) to Your Bucket?" }
  public var hostsTitle: String { "FROM \(PinaxFormat.count(hosts.count, singular: "HOST", plural: "HOSTS"))" }

  /// The list's closed line: "4 Images · 1 over 1 MB", or the count alone.
  public var imagesTitle: String { PinaxFormat.count(images.count, singular: "Image") }
  public var imagesNote: String? {
    let large = images.filter(\.isLarge).count
    guard large > 0 else { return nil }
    return "\(large.formatted()) over \(PinaxFormat.fileSize(PinaxFormat.largeImageBytes))"
  }

  /// The list's pinned total.
  public var imagesBytes: Int64 { images.reduce(0) { $0 + $1.bytes } }

  /// Greyed while a source is not allowed, or with nothing to migrate.
  public func canMigrate(allowed: Set<String>) -> Bool {
    links > 0 && sources.allSatisfy { allowed.contains($0.id) }
  }

  public var migrateTitle: String {
    links > 0 ? "Migrate \(PinaxFormat.count(links, singular: "Link"))" : "Nothing to Migrate"
  }

  public static func make(_ preparation: ExternalMigrationPreparation) -> ExternalMigrationConfirmation {
    let result = preparation.result
    let summary = result.summary.migration ?? ExternalMigrationSummary()
    let failures = result.events.compactMap { event -> DownloadFailedEvent? in
      if case let .downloadFailed(failure) = event { return failure }
      return nil
    }
    var lines = [
      Line(
        label: "Upload", tone: .upload,
        groups: summary.migratable.images == 0
          ? [[.init(text: "None", style: .unit)]]
          : [
            count(summary.migratable.images, "image"),
            size(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)),
          ]),
      Line(
        label: "Already in library", tone: .reused,
        groups: [
          summary.reused.images == 0
            ? [.init(text: "None", style: .unit)] : [.init(text: summary.reused.images.formatted(), style: .figure)]
        ],
        detail: "Links will point to the copy you have"),
    ]
    if summary.skipped.images > 0 {
      let broken = failures.allSatisfy { $0.reason != .notImage }
      lines.append(
        Line(
          label: "Skipped", tone: .skipped,
          groups: [count(summary.skipped.links, broken ? "broken link" : "link")],
          detail: skippedDetail(failures), isWarning: true))
    }
    let files = summary.files.reduce(0) { $0 + $1.files }
    var sourceNames: [String] = []
    for entry in summary.files where !sourceNames.contains(entry.source) { sourceNames.append(entry.source) }
    lines.append(
      Line(
        label: "Files to change", tone: .files,
        groups: files == 0
          ? [[.init(text: "None", style: .unit)]]
          : [count(files, "file")] + sourceNames.map { [.init(text: $0, style: .plain)] }))
    if let bucket = preparation.bucket {
      lines.append(
        Line(
          label: "Bucket", tone: .bucket, groups: [[.init(text: bucket, style: .plain)]],
          tag: preparation.storageKind?.uppercased()))
    }
    if let key = summary.sampleKeys.first {
      lines.append(
        Line(
          label: "New keys", tone: .keys, groups: [keySegments(key)], detail: "Your key template · dated today",
          isMonospaced: true))
    }
    let images = uploads(result.events)
    var hostBytes: [String: Int64] = [:]
    var largeHosts = Set<String>()
    for image in images {
      hostBytes[image.host, default: 0] += image.bytes
      if image.isLarge { largeHosts.insert(image.host) }
    }
    let hosts = summary.hosts.map { host in
      Host(
        host: host.host, tip: host.tips.isEmpty ? nil : host.tips.joined(separator: " · "),
        isWarning: host.tips.contains { $0.hasSuffix("skipped") }, links: host.links,
        bytes: hostBytes[host.host], hasLarge: largeHosts.contains(host.host))
    }
    var seen = Set<String>()
    let sources = result.events.compactMap { event -> Source? in
      guard case let .sourceStatus(status) = event, status.status != .clean else { return nil }
      let id = "\(status.project)/\(status.source)"
      guard seen.insert(id).inserted else { return nil }
      return Source(id: id, text: sourceText(status))
    }
    return ExternalMigrationConfirmation(
      runID: result.runID, links: summary.migratable.links + summary.reused.links, lines: lines,
      hosts: hosts, sources: sources, images: images)
  }

  /// The images the preparation would upload: each `download_finished`
  /// whose URL is planned for upload (not reused), one per content hash —
  /// the same bytes go up once. Largest first, then by name.
  static func uploads(_ events: [RunEvent]) -> [Image] {
    var toUpload = Set<String>()
    for event in events {
      if case let .migrationPlanned(plan) = event, plan.reusedAssetID == nil { toUpload.insert(plan.url) }
    }
    var seen = Set<String>()
    var images: [Image] = []
    for event in events {
      guard case let .downloadFinished(download) = event, toUpload.contains(download.url),
        seen.insert(download.sha256).inserted
      else { continue }
      images.append(
        Image(url: download.url, filename: download.filename, host: download.host, bytes: download.bytes))
    }
    return images.sorted { ($0.bytes, $1.filename) > ($1.bytes, $0.filename) }
  }

  /// "47 images": the figure, then its unit.
  static func count(_ n: Int, _ noun: String) -> [Line.Segment] {
    let text = PinaxFormat.count(n, singular: noun)
    let figure = n.formatted()
    return [.init(text: figure, style: .figure), .init(text: String(text.dropFirst(figure.count + 1)), style: .unit)]
  }

  /// "18.6 MB" as figure and unit, split at its last space (the locale's,
  /// which may be a non-breaking one).
  static func size(_ text: String) -> [Line.Segment] {
    guard let space = text.lastIndex(where: { $0.isWhitespace }) else { return [.init(text: text, style: .figure)] }
    return [
      .init(text: String(text[..<space]), style: .figure),
      .init(text: String(text[text.index(after: space)...]), style: .unit, gap: String(text[space])),
    ]
  }

  /// A sample key's runs: the date folder and extension faint, a trailing
  /// `-<hex>` hash in the accent, the name plain. Joined, they are the key.
  static func keySegments(_ key: String) -> [Line.Segment] {
    var rest = Substring(key)
    var segments: [Line.Segment] = []
    if let slash = rest.lastIndex(of: "/") {
      segments.append(.init(text: String(rest[...slash]), style: .faint))
      rest = rest[rest.index(after: slash)...]
    }
    var ext: Substring = ""
    if let dot = rest.lastIndex(of: "."), dot != rest.startIndex {
      ext = rest[dot...]
      rest = rest[..<dot]
    }
    var hash: Substring = ""
    if let dash = rest.lastIndex(of: "-") {
      let tail = rest[rest.index(after: dash)...]
      if tail.count >= 6, tail.allSatisfy(\.isHexDigit) {
        hash = rest[dash...]
        rest = rest[..<dash]
      }
    }
    if !rest.isEmpty { segments.append(.init(text: String(rest), style: .plain, gap: "")) }
    if !hash.isEmpty { segments.append(.init(text: String(hash), style: .hash, gap: "")) }
    if !ext.isEmpty { segments.append(.init(text: String(ext), style: .faint, gap: "")) }
    return segments
  }

  /// "m.media-amazon.com · 404 — left as is", a host each.
  static func skippedDetail(_ failures: [DownloadFailedEvent]) -> String {
    var parts: [String] = []
    for failure in failures {
      let part = "\(failure.host) · \(ExternalMigrationFailure.reason(failure))"
      if !parts.contains(part) { parts.append(part) }
    }
    return parts.joined(separator: ", ") + " — left as is"
  }

  static func sourceText(_ status: SourceStatusEvent) -> String {
    switch status.status {
    case .dirty: return "\(status.source) has uncommitted changes."
    case .notGit: return "\(status.source) isn’t in git."
    case .unknown, .clean: return "\(status.source)’s git status is unknown."
    }
  }
}

/// A refused apply (thrown before any run is recorded, so the activity
/// panel has nothing): the sheet says why and what to do next.
public struct ExternalMigrationRefusal: Equatable, Sendable {
  public let message: String
  /// The preparation is stale: the sheet offers Prepare Again.
  public let needsPreparing: Bool

  public static func make(_ error: Error) -> ExternalMigrationRefusal? {
    switch error {
    case let RewriteRunError.planChanged(_, differences):
      return ExternalMigrationRefusal(
        message: "\(PinaxFormat.count(differences.count, singular: "file")) changed since Pinax prepared this migration. Nothing was uploaded. Prepare again to see the new changes.",
        needsPreparing: true)
    case let RewriteRunError.sourcesNotAllowed(sources):
      return ExternalMigrationRefusal(
        message: "Some sources aren’t clean: \(sources.joined(separator: ", ")). Nothing was uploaded. Tick Write anyway for each, or commit first.",
        needsPreparing: false)
    case RewriteRunError.notAPreview, RewriteRunError.runNotFound:
      return ExternalMigrationRefusal(
        message: "This preparation can’t be migrated any more. Nothing was uploaded. Prepare again.",
        needsPreparing: true)
    case ExternalMigrationError.cacheInvalid:
      return ExternalMigrationRefusal(
        message: "The downloaded images are gone or changed. Nothing was uploaded. Prepare again to download them anew.",
        needsPreparing: true)
    default:
      return nil
    }
  }
}

// MARK: - The status bar

/// The migration's state as the activity slot shows it.
public enum ExternalMigrationStatus: Equatable, Sendable {
  case preparing(done: Int, total: Int, host: String?)
  /// Prepared and not applied: Review… reopens the sheet.
  case ready(runID: Int64, links: Int)
  case uploading(done: Int, total: Int, host: String?, isStopping: Bool)
  case rewriting(files: Int)
  /// The last result, until the next migration.
  case done(ActivityItem)

  public var item: ActivityItem {
    switch self {
    case let .preparing(done, total, host):
      let text = "Preparing · downloaded \(done.formatted()) of \(total.formatted())"
      return .running(
        host.map { "\(text) · \($0)" } ?? text, fraction: total > 0 ? Double(done) / Double(total) : nil,
        cancel: "Cancel")
    case let .ready(runID, links):
      return ActivityItem(
        text: "Ready to migrate \(PinaxFormat.count(links, singular: "link"))", phase: .ready, runID: runID,
        link: .review)
    case let .uploading(done, total, host, isStopping):
      let text = "Uploading \(done.formatted()) of \(total.formatted())"
      return .running(
        host.map { "\(text) · \($0)" } ?? text, fraction: total > 0 ? Double(done) / Double(total) : nil,
        cancel: isStopping ? nil : "Stop after this image")
    case let .rewriting(files):
      return .running("Rewriting \(PinaxFormat.count(files, singular: "file"))…")
    case let .done(item):
      return item
    }
  }

  /// Done, Done with warnings, Stopped or Failed, from apply's
  /// result.
  public static func result(_ result: ExternalMigrationResult) -> ExternalMigrationStatus {
    let summary = result.summary.migration ?? ExternalMigrationSummary()
    let uploaded = summary.uploaded?.images ?? 0
    let failed = summary.failed?.images ?? 0
    switch result.state {
    case .cancelled:
      let done = summary.stoppedAfter ?? uploaded
      let total = summary.migratable.images
      return .done(
        ActivityItem(
          text: "Stopped after \(done.formatted()) of \(PinaxFormat.count(total, singular: "image")) · nothing rewritten",
          phase: .failed, runID: result.runID, link: .showLog))
    case .failed:
      return .done(
        ActivityItem(
          text: "Migration failed · nothing rewritten", phase: .failed, runID: result.runID, link: .showLog))
    default:
      var parts = ["Migrated \(uploaded.formatted())"]
      if summary.reused.images > 0 { parts.append("\(summary.reused.images.formatted()) reused") }
      if summary.skipped.images > 0 { parts.append("\(summary.skipped.images.formatted()) skipped") }
      if failed > 0 { parts.append("\(failed.formatted()) failed") }
      let warnings = failed > 0 || summary.skipped.images > 0 || result.summary.errors > 0
        || (result.summary.skippedFiles?.values.reduce(0, +) ?? 0) > 0
      return .done(
        ActivityItem(
          text: parts.joined(separator: " · "), phase: warnings ? .warnings : .finished,
          runID: result.runID, link: (result.summary.written ?? 0) > 0 ? .changedFiles : .showLog))
    }
  }
}

// MARK: - Why a row stayed

/// A row the migration left: shown in the inspector's Migration band the
/// way import failures are.
public struct ExternalMigrationFailure: Equatable, Sendable {
  /// "404 · skipped", "Upload failed", "New link doesn’t load".
  public let status: String
  /// The run's own sentence for it (`RunEvent.summaryLine`).
  public let explanation: String

  /// A broken link's reason: "404", "timed out", "not an image".
  static func reason(_ failure: DownloadFailedEvent) -> String {
    switch failure.reason {
    case .httpStatus: return failure.status.map(String.init) ?? "HTTP error"
    case .timeout: return "timed out"
    case .dns: return "host not found"
    case .notImage: return "not an image"
    case .failed: return "couldn’t download"
    }
  }

  /// Each URL the run's events leave behind, by raw URL.
  public static func make(_ events: [RunEvent]) -> [String: ExternalMigrationFailure] {
    var failures: [String: ExternalMigrationFailure] = [:]
    for event in events {
      switch event {
      case let .downloadFailed(failure):
        failures[failure.url] = ExternalMigrationFailure(
          status: "\(reason(failure)) · skipped", explanation: event.summaryLine)
      case let .uploadFailed(failure):
        failures[failure.url] = ExternalMigrationFailure(status: "Upload failed", explanation: event.summaryLine)
      case let .verifyFailed(failure):
        failures[failure.url] = ExternalMigrationFailure(
          status: "New link doesn’t load", explanation: event.summaryLine)
      default:
        break
      }
    }
    return failures
  }
}
