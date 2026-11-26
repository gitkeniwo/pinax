import Foundation

/// One structured step of a run. Stored as `type` plus
/// `data` JSON; `summaryLine` is the readable rendering, the JSON the raw
/// one, both from the same value.
public enum RunEvent: Equatable, Sendable {
  case runStarted(RewriteRunParams)
  case sourceStatus(SourceStatusEvent)
  case filePlanned(FilePlannedEvent)
  case editSkipped(EditSkippedEvent)
  case protocolRelativeFound(ProtocolRelativeEvent)
  case targetVerified(TargetVerifiedEvent)
  case prefixChanged(PrefixChangedEvent)
  case fileWritten(FileWrittenEvent)
  case fileSkipped(FileSkippedEvent)
  case fileFailed(FileFailedEvent)
  case rescanFinished(RescanFinishedEvent)
  case rescanFailed(RescanFailedEvent)
  case runFinished(RewriteRunSummary)
  // External migration
  case migrationStarted(MigrationStartedEvent)
  case downloadFinished(DownloadFinishedEvent)
  case downloadFailed(DownloadFailedEvent)
  case migrationPlanned(MigrationPlannedEvent)
  case uploadFinished(UploadFinishedEvent)
  case assetReused(AssetReusedEvent)
  case uploadFailed(UploadFailedEvent)
  case verifyFailed(VerifyFailedEvent)
  case keyChanged(KeyChangedEvent)
  case migrationStopped(MigrationStoppedEvent)
  // Optimizing objects in place
  case optimizeSelected(OptimizeSelectedEvent)
  case objectMeasured(ObjectMeasuredEvent)

  public var type: String {
    switch self {
    case .runStarted: return "run_started"
    case .sourceStatus: return "source_status"
    case .filePlanned: return "file_planned"
    case .editSkipped: return "edit_skipped"
    case .protocolRelativeFound: return "protocol_relative_found"
    case .targetVerified: return "target_verified"
    case .prefixChanged: return "prefix_changed"
    case .fileWritten: return "file_written"
    case .fileSkipped: return "file_skipped"
    case .fileFailed: return "file_failed"
    case .rescanFinished: return "rescan_finished"
    case .rescanFailed: return "rescan_failed"
    case .runFinished: return "run_finished"
    case .migrationStarted: return "migration_started"
    case .downloadFinished: return "download_finished"
    case .downloadFailed: return "download_failed"
    case .migrationPlanned: return "migration_planned"
    case .uploadFinished: return "upload_finished"
    case .assetReused: return "asset_reused"
    case .uploadFailed: return "upload_failed"
    case .verifyFailed: return "verify_failed"
    case .keyChanged: return "key_changed"
    case .migrationStopped: return "migration_stopped"
    case .optimizeSelected: return "optimize_selected"
    case .objectMeasured: return "object_measured"
    }
  }

  public var level: RunLevel {
    switch self {
    case .runStarted, .filePlanned, .prefixChanged, .fileWritten, .rescanFinished,
      .migrationStarted, .downloadFinished, .migrationPlanned, .uploadFinished, .assetReused,
      .optimizeSelected:
      return .info
    case let .objectMeasured(event):
      return event.outcome.level
    case .downloadFailed, .keyChanged, .migrationStopped:
      return .warning
    case .uploadFailed, .verifyFailed:
      return .error
    case let .sourceStatus(event):
      return event.status == .clean ? .info : .warning
    case .editSkipped, .protocolRelativeFound, .fileSkipped:
      return .warning
    case let .targetVerified(event):
      switch event.result {
      case .ok: return .info
      case .alreadyBroken: return .warning
      case .mismatch, .unreachable: return .error
      }
    case .fileFailed, .rescanFailed:
      return .error
    case let .runFinished(summary):
      return summary.errors > 0 ? .error : .info
    }
  }

  /// One short English sentence, in the app's voice: `summaryParts`
  /// joined, so the CLI, Copy and the panel's rows read the same words.
  public var summaryLine: String { summaryParts.line }

  /// The sentence as its verb, the thing it acted
  /// on (a file, path, URL or key) and a detail (a size, a count, why),
  /// with the joins that put them back into `summaryLine` word for word.
  public var summaryParts: RunEventSummaryParts {
    typealias Parts = RunEventSummaryParts
    switch self {
    case let .runStarted(params):
      let rules = params.targets.reduce(0) { $0 + $1.rules.count }
      let projects = params.targets.map(\.project).joined(separator: ", ")
      if let domain = params.domain {
        return Parts(
          verb: "Started moving", object: "\(domain.backend) to \(domain.to)",
          detail: "\(projects) · \(plural(rules, "rule"))")
      }
      return Parts(verb: "Started", object: projects, detail: plural(rules, "rule"))
    case let .sourceStatus(event):
      let name = "\(event.project)/\(event.source)"
      switch event.status {
      case .clean: return Parts(verb: "is clean", object: name, objectFirst: true)
      case .notGit: return Parts(verb: "isn’t in git", object: name, objectFirst: true)
      case .dirty:
        return Parts(
          verb: "has", object: name, detail: plural(event.dirtyPaths.count, "uncommitted change"),
          objectFirst: true, detailSeparator: " ")
      case .unknown:
        return Parts(
          verb: "git status unknown", object: name, detail: event.reason ?? "no reason given",
          objectFirst: true, objectSeparator: ": ", detailSeparator: " — ")
      }
    case let .filePlanned(event):
      return Parts(verb: "Will rewrite", object: event.path, detail: plural(event.edits, "ref"))
    case let .editSkipped(event):
      let why =
        event.reason == RewriteSkipReason.notUTF8.rawValue
        ? "the file isn’t UTF-8" : "the new URL wouldn’t read back here"
      return Parts(
        verb: "Left", object: "\(event.path):\(event.line)", detail: "as is — \(why)", detailSeparator: " ")
    case let .protocolRelativeFound(event):
      return Parts(
        verb: "has", object: event.path,
        detail: "\(plural(event.count, "protocol-relative link")) to \(event.host) — change by hand",
        objectFirst: true, detailSeparator: " ")
    case let .targetVerified(event):
      switch event.result {
      case .ok: return Parts(verb: "Checked", object: event.url)
      case .mismatch: return Parts(verb: "serves a different file", object: event.url, objectFirst: true)
      case .unreachable:
        return Parts(verb: "Couldn’t fetch", object: event.url, detail: event.cause, detailSeparator: " — ")
      case .alreadyBroken:
        return Parts(
          verb: "was already broken", object: event.url, detail: "the old URL fails too", objectFirst: true,
          detailSeparator: " — ")
      }
    case let .prefixChanged(event):
      return Parts(
        verb: "Changed", object: "\(event.backend)’s URL prefix", detail: event.to, detailSeparator: " to ")
    case let .fileWritten(event):
      return Parts(verb: "Rewrote", object: event.path, detail: plural(event.edits, "ref"))
    case let .fileSkipped(event):
      let why =
        event.reason == RewriteFileSkipReason.symlink.rawValue
        ? "it’s a symbolic link" : "changed since the preview"
      return Parts(verb: "Skipped", object: event.path, detail: why, detailSeparator: " — ")
    case let .fileFailed(event):
      return Parts(verb: "Couldn’t write", object: event.path, detail: event.error, detailSeparator: " — ")
    case let .rescanFinished(event):
      return Parts(
        verb: "Rescanned", object: event.project,
        detail: "\(plural(event.refs, "ref")) in \(plural(event.files, "file"))")
    case let .rescanFailed(event):
      return Parts(verb: "Couldn’t rescan", object: event.project, detail: event.error, detailSeparator: " — ")
    case let .migrationStarted(event):
      let links = event.targets.reduce(0) { $0 + $1.links }
      return Parts(
        verb: "Started", detail: "\(plural(links, "link")) from \(plural(event.hosts, "host"))",
        detailSeparator: " — ")
    case let .downloadFinished(event):
      return Parts(verb: "Downloaded", object: event.filename, detail: byteText(event.bytes))
    case let .downloadFailed(event):
      return Parts(
        verb: "Skipped", object: shortURL(event.url), detail: "\(event.cause), left as is", detailSeparator: " — ")
    case let .migrationPlanned(event):
      let name = event.filename ?? displayName(event.url)
      if event.reusedAssetID != nil {
        return Parts(verb: "Will reuse", object: name, detail: "already in the library", detailSeparator: " — ")
      }
      return Parts(verb: "Will upload", object: "\(name) → \(event.key)")
    case let .uploadFinished(event):
      return Parts(verb: "Uploaded", object: "\(displayName(event.url)) → \(event.key)")
    case let .assetReused(event):
      return Parts(
        verb: "Reused", object: displayName(event.url), detail: "already in the library", detailSeparator: " — ")
    case let .uploadFailed(event):
      let why: String
      switch event.status {
      case 401?, 403?: why = "the bucket refused it (\(event.status!))"
      case let status?: why = "the storage answered \(status)"
      case nil: why = event.error
      }
      return Parts(verb: "Couldn’t upload", object: displayName(event.url), detail: why, detailSeparator: " — ")
    case let .verifyFailed(event):
      return Parts(
        verb: "New link for", object: displayName(event.url), detail: "doesn’t load — not rewritten",
        detailSeparator: " ")
    case let .keyChanged(event):
      return Parts(
        verb: "Key for", object: displayName(event.url), detail: "changed to \(event.key)", detailSeparator: " ")
    case let .migrationStopped(event):
      // A preview stopped while checking new URLs.
      let noun = event.phase == "check" ? "URL" : "image"
      let tail = event.phase == "check" ? " checked" : ""
      return Parts(
        verb: "Stopped", detail: "after \(event.done) of \(plural(event.total, noun))\(tail)", detailSeparator: " ")
    case let .optimizeSelected(event):
      return Parts(
        verb: "Selected", detail: "\(plural(event.images.count, "JPEG")), measuring \(event.sample)",
        detailSeparator: " ")
    case let .objectMeasured(event):
      if event.outcome == .smaller, let after = event.bytesAfter {
        return Parts(
          verb: "Measured", object: event.key,
          detail: "\(byteText(event.bytesBefore)) → \(byteText(after))")
      }
      let why = event.detail.map { "\(event.outcome.label) (\($0))" } ?? event.outcome.label
      return Parts(verb: "Would leave", object: event.key, detail: why, detailSeparator: " — ")
    case let .runFinished(summary):
      var parts: Parts
      if let report = summary.optimize {
        parts = Parts(
          verb: "Finished",
          detail: "measured \(report.savings.measured) of \(plural(report.selection.images, "JPEG"))")
      } else if let migration = summary.migration {
        if let stopped = migration.stoppedAfter {
          parts = Parts(verb: "Stopped", detail: "after \(plural(stopped, "image"))", detailSeparator: " ")
        } else if let uploaded = migration.uploaded {
          var detail = "uploaded \(uploaded.images), reused \(migration.reused.images)"
          if let failed = migration.failed, failed.images > 0 { detail += ", \(failed.images) failed" }
          if migration.skipped.images > 0 { detail += ", \(migration.skipped.images) skipped" }
          detail += " · wrote \(plural(summary.written ?? 0, "file"))"
          parts = Parts(verb: "Finished", detail: detail)
        } else {
          parts = Parts(
            verb: "Ready",
            detail:
              "\(plural(migration.migratable.images, "image")) to upload, \(migration.reused.images) reused, \(migration.skipped.images) skipped"
          )
        }
      } else if let written = summary.written {
        parts = Parts(verb: "Finished", detail: "wrote \(plural(written, "file"))")
      } else {
        parts = Parts(
          verb: "Finished",
          detail: "\(plural(summary.files, "file")), \(plural(summary.edits, "ref")) to rewrite")
      }
      if summary.errors > 0 { parts.detail = (parts.detail ?? "") + " · \(plural(summary.errors, "error"))" }
      return parts
    }
  }

  // MARK: - type + data

  public func dataJSON() throws -> String {
    try RunLog.json(Payload(event: self))
  }

  public init(type: String, data: String) throws {
    let decoder = JSONDecoder()
    let bytes = Data(data.utf8)
    func decode<T: Decodable>(_: T.Type) throws -> T { try decoder.decode(T.self, from: bytes) }
    switch type {
    case "run_started": self = .runStarted(try decode(RewriteRunParams.self))
    case "source_status": self = .sourceStatus(try decode(SourceStatusEvent.self))
    case "file_planned": self = .filePlanned(try decode(FilePlannedEvent.self))
    case "edit_skipped": self = .editSkipped(try decode(EditSkippedEvent.self))
    case "protocol_relative_found": self = .protocolRelativeFound(try decode(ProtocolRelativeEvent.self))
    case "target_verified": self = .targetVerified(try decode(TargetVerifiedEvent.self))
    case "prefix_changed": self = .prefixChanged(try decode(PrefixChangedEvent.self))
    case "file_written": self = .fileWritten(try decode(FileWrittenEvent.self))
    case "file_skipped": self = .fileSkipped(try decode(FileSkippedEvent.self))
    case "file_failed": self = .fileFailed(try decode(FileFailedEvent.self))
    case "rescan_finished": self = .rescanFinished(try decode(RescanFinishedEvent.self))
    case "rescan_failed": self = .rescanFailed(try decode(RescanFailedEvent.self))
    case "run_finished": self = .runFinished(try decode(RewriteRunSummary.self))
    case "migration_started": self = .migrationStarted(try decode(MigrationStartedEvent.self))
    case "download_finished": self = .downloadFinished(try decode(DownloadFinishedEvent.self))
    case "download_failed": self = .downloadFailed(try decode(DownloadFailedEvent.self))
    case "migration_planned": self = .migrationPlanned(try decode(MigrationPlannedEvent.self))
    case "upload_finished": self = .uploadFinished(try decode(UploadFinishedEvent.self))
    case "asset_reused": self = .assetReused(try decode(AssetReusedEvent.self))
    case "upload_failed": self = .uploadFailed(try decode(UploadFailedEvent.self))
    case "verify_failed": self = .verifyFailed(try decode(VerifyFailedEvent.self))
    case "key_changed": self = .keyChanged(try decode(KeyChangedEvent.self))
    case "migration_stopped": self = .migrationStopped(try decode(MigrationStoppedEvent.self))
    case "optimize_selected": self = .optimizeSelected(try decode(OptimizeSelectedEvent.self))
    case "object_measured": self = .objectMeasured(try decode(ObjectMeasuredEvent.self))
    default: throw RunLogError.unknownEventType(type)
    }
  }

  func encodeTypeAndData<Key: CodingKey>(
    into container: inout KeyedEncodingContainer<Key>, type typeKey: Key, data dataKey: Key
  ) throws {
    try container.encode(type, forKey: typeKey)
    try container.encode(Payload(event: self), forKey: dataKey)
  }

  /// Encodes just the case's data.
  private struct Payload: Encodable {
    let event: RunEvent

    func encode(to encoder: Encoder) throws {
      switch event {
      case let .runStarted(value): try value.encode(to: encoder)
      case let .sourceStatus(value): try value.encode(to: encoder)
      case let .filePlanned(value): try value.encode(to: encoder)
      case let .editSkipped(value): try value.encode(to: encoder)
      case let .protocolRelativeFound(value): try value.encode(to: encoder)
      case let .targetVerified(value): try value.encode(to: encoder)
      case let .prefixChanged(value): try value.encode(to: encoder)
      case let .fileWritten(value): try value.encode(to: encoder)
      case let .fileSkipped(value): try value.encode(to: encoder)
      case let .fileFailed(value): try value.encode(to: encoder)
      case let .rescanFinished(value): try value.encode(to: encoder)
      case let .rescanFailed(value): try value.encode(to: encoder)
      case let .runFinished(value): try value.encode(to: encoder)
      case let .migrationStarted(value): try value.encode(to: encoder)
      case let .downloadFinished(value): try value.encode(to: encoder)
      case let .downloadFailed(value): try value.encode(to: encoder)
      case let .migrationPlanned(value): try value.encode(to: encoder)
      case let .uploadFinished(value): try value.encode(to: encoder)
      case let .assetReused(value): try value.encode(to: encoder)
      case let .uploadFailed(value): try value.encode(to: encoder)
      case let .verifyFailed(value): try value.encode(to: encoder)
      case let .keyChanged(value): try value.encode(to: encoder)
      case let .migrationStopped(value): try value.encode(to: encoder)
      case let .optimizeSelected(value): try value.encode(to: encoder)
      case let .objectMeasured(value): try value.encode(to: encoder)
      }
    }
  }
}

extension RunEvent: Codable {
  enum CodingKeys: String, CodingKey { case type, data }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try encodeTypeAndData(into: &container, type: .type, data: .data)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    let data = try container.decode(JSONValue.self, forKey: .data)
    try self.init(type: type, data: try RunLog.json(data))
  }
}

/// Any JSON, kept so `RunEvent`'s decoder can hand `data` on as text.
private enum JSONValue: Codable {
  case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case let .bool(value): try container.encode(value)
    case let .number(value):
      if value == value.rounded(), abs(value) < 1e15 {
        try container.encode(Int64(value))
      } else {
        try container.encode(value)
      }
    case let .string(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    }
  }
}

/// A `summaryLine` in its three layers. `line`
/// joins them: the verb, then the object (or the object first, for "X is
/// clean"), then the detail, each with its own join.
public struct RunEventSummaryParts: Equatable, Sendable {
  public var verb: String
  /// A file, path, URL or key; the part a narrow row truncates first.
  public var object: String?
  /// A size, a count, or why; never truncated.
  public var detail: String?
  /// "X is clean": the object stands before the verb.
  public var objectFirst = false
  public var objectSeparator = " "
  public var detailSeparator = " · "

  public init(
    verb: String, object: String? = nil, detail: String? = nil, objectFirst: Bool = false,
    objectSeparator: String = " ", detailSeparator: String = " · "
  ) {
    self.verb = verb
    self.object = object
    self.detail = detail
    self.objectFirst = objectFirst
    self.objectSeparator = objectSeparator
    self.detailSeparator = detailSeparator
  }

  public var line: String {
    var line = verb
    if let object { line = objectFirst ? object + objectSeparator + verb : verb + objectSeparator + object }
    if let detail { line += detailSeparator + detail }
    return line
  }
}

private func plural(_ count: Int, _ noun: String) -> String {
  "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// `412 KB`, `1.3 MB` (decimal units, like Finder).
private func byteText(_ bytes: Int64) -> String {
  if bytes < 1000 { return "\(bytes) bytes" }
  if bytes < 1_000_000 { return "\(Int((Double(bytes) / 1000).rounded())) KB" }
  return String(format: "%.1f MB", Double(bytes) / 1_000_000)
}

/// A URL's file name, decoded; its host when the path has none.
private func displayName(_ url: String) -> String {
  let recorded = AssetProvenance.recordedURL(url)
  let parsed = URL(string: recorded)
  let last = parsed?.path.split(separator: "/").last.map(String.init) ?? ""
  return last.isEmpty ? (parsed?.host ?? recorded) : last
}

/// `host/…/name`, or `host/name` when the name is the whole path.
private func shortURL(_ url: String) -> String {
  let recorded = AssetProvenance.recordedURL(url)
  guard let parsed = URL(string: recorded), let host = parsed.host else { return recorded }
  let parts = parsed.path.split(separator: "/")
  switch parts.count {
  case 0: return host
  case 1: return "\(host)/\(parts[0])"
  default: return "\(host)/…/\(parts.last!)"
  }
}

// MARK: - Payloads

/// What a rewrite run was asked to do: the `run.params` JSON and the
/// `run_started` data. Allowed sources are `project/label`.
public struct RewriteRunParams: Codable, Equatable, Sendable {
  public var targets: [RewriteRunTarget]
  public var allowedSources: [String]
  public var verify: Bool
  /// Set on a domain migration; nil on a plain rewrite.
  public var domain: DomainMigrationParams?

  public init(
    targets: [RewriteRunTarget], allowedSources: [String] = [], verify: Bool = false,
    domain: DomainMigrationParams? = nil
  ) {
    self.targets = targets
    self.allowedSources = allowedSources
    self.verify = verify
    self.domain = domain
  }

  enum CodingKeys: String, CodingKey {
    case targets, verify, domain
    case allowedSources = "allowed_sources"
  }
}

/// A domain migration's backend, by slug (restoring a backup nulls
/// `run.backend_id`), and the prefixes it moves.
public struct DomainMigrationParams: Codable, Equatable, Sendable {
  public var backend: String
  /// The backend's current prefix when the preview ran.
  public var from: String
  public var to: String
  /// Old domains rewritten along with `from`; empty with `--keep-old-domains`.
  /// When `keepPrefix`, the only ones rewritten.
  public var oldDomains: [String]
  public var keepOldDomains: Bool
  /// `to` is the current prefix; only `oldDomains` move to it and the
  /// prefix is not changed. Absent in runs recorded by older versions,
  /// read as false.
  public var keepPrefix: Bool

  public init(
    backend: String, from: String, to: String, oldDomains: [String], keepOldDomains: Bool,
    keepPrefix: Bool = false
  ) {
    self.backend = backend
    self.from = from
    self.to = to
    self.oldDomains = oldDomains
    self.keepOldDomains = keepOldDomains
    self.keepPrefix = keepPrefix
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    backend = try container.decode(String.self, forKey: .backend)
    from = try container.decode(String.self, forKey: .from)
    to = try container.decode(String.self, forKey: .to)
    oldDomains = try container.decode([String].self, forKey: .oldDomains)
    keepOldDomains = try container.decode(Bool.self, forKey: .keepOldDomains)
    keepPrefix = try container.decodeIfPresent(Bool.self, forKey: .keepPrefix) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(backend, forKey: .backend)
    try container.encode(from, forKey: .from)
    try container.encode(to, forKey: .to)
    try container.encode(oldDomains, forKey: .oldDomains)
    try container.encode(keepOldDomains, forKey: .keepOldDomains)
    // Only a run that keeps the prefix writes the key, so a prefix move's
    // params stay unchanged.
    if keepPrefix { try container.encode(true, forKey: .keepPrefix) }
  }

  enum CodingKeys: String, CodingKey {
    case backend, from, to
    case oldDomains = "old_domains"
    case keepOldDomains = "keep_old_domains"
    case keepPrefix = "keep_prefix"
  }
}

public struct RewriteRunTarget: Codable, Equatable, Sendable {
  public var project: String
  public var rules: [RewriteRule]

  public init(project: String, rules: [RewriteRule]) {
    self.project = project
    self.rules = rules
  }
}

/// `{"match": "exact"|"prefix", "from": …, "to": …}`, the map file's shape.
extension RewriteRule: Codable {
  enum CodingKeys: String, CodingKey { case match, from, to }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let from = try container.decode(String.self, forKey: .from)
    let to = try container.decode(String.self, forKey: .to)
    switch try container.decode(String.self, forKey: .match) {
    case "exact": self = .exact(from: from, to: to)
    case "prefix": self = .prefix(from: from, to: to)
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .match, in: container, debugDescription: "match must be exact or prefix, not \(other)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(isPrefix ? "prefix" : "exact", forKey: .match)
    try container.encode(from, forKey: .from)
    try container.encode(to, forKey: .to)
  }
}

public struct SourceStatusEvent: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case clean
    case notGit = "not_git"
    case dirty, unknown
  }

  public var project: String
  public var source: String
  public var status: Status
  public var dirtyPaths: [String]
  public var reason: String?

  public init(project: String, source: String, git: SourceGitStatus) {
    self.project = project
    self.source = source
    switch git {
    case .clean: (status, dirtyPaths, reason) = (.clean, [], nil)
    case .notGit: (status, dirtyPaths, reason) = (.notGit, [], nil)
    case let .dirty(paths): (status, dirtyPaths, reason) = (.dirty, paths, nil)
    case let .unknown(why): (status, dirtyPaths, reason) = (.unknown, [], why)
    }
  }

  enum CodingKeys: String, CodingKey {
    case project, source, status, reason
    case dirtyPaths = "dirty_paths"
  }
}

public struct FilePlannedEvent: Codable, Equatable, Sendable {
  public var project: String
  public var source: String
  public var path: String
  public var sha256: String
  public var edits: Int
  public var editsDigest: String

  public init(project: String, source: String, path: String, sha256: String, edits: Int, editsDigest: String) {
    self.project = project
    self.source = source
    self.path = path
    self.sha256 = sha256
    self.edits = edits
    self.editsDigest = editsDigest
  }

  enum CodingKeys: String, CodingKey {
    case project, source, path, sha256, edits
    case editsDigest = "edits_digest"
  }
}

public struct EditSkippedEvent: Codable, Equatable, Sendable {
  public var project: String
  public var source: String
  public var path: String
  public var line: Int
  public var reason: String

  public init(project: String, source: String, path: String, line: Int, reason: String) {
    self.project = project
    self.source = source
    self.path = path
    self.line = line
    self.reason = reason
  }
}

public struct ProtocolRelativeEvent: Codable, Equatable, Sendable {
  public var project: String
  public var source: String
  public var path: String
  public var host: String
  public var count: Int

  public init(project: String, source: String, path: String, host: String, count: Int) {
    self.project = project
    self.source = source
    self.path = path
    self.host = host
    self.count = count
  }
}

public struct TargetVerifiedEvent: Codable, Equatable, Sendable {
  /// `alreadyBroken`: a new URL not in the catalog that
  /// can't be fetched, whose old URL can't be fetched either. A warning,
  /// not a failed check.
  public enum Result: String, Codable, Sendable {
    case ok, mismatch, unreachable
    case alreadyBroken = "already_broken"
  }

  public var url: String
  public var result: Result
  public var expectedSHA256: String?
  public var actualSHA256: String?
  public var reason: String?
  /// Why the old URL failed too; only on `alreadyBroken`.
  public var oldReason: String?

  /// With `oldReason`, an `.unreachable` verification is `alreadyBroken`.
  public init(
    url: String, expectedSHA256: String?, verification: TargetVerification, oldReason: String? = nil
  ) {
    self.url = url
    self.expectedSHA256 = expectedSHA256
    switch verification {
    case let .ok(sha): (result, actualSHA256, reason) = (.ok, sha, nil)
    case let .mismatch(_, actual): (result, actualSHA256, reason) = (.mismatch, actual, nil)
    case let .unreachable(why):
      (result, actualSHA256, reason) = (oldReason == nil ? .unreachable : .alreadyBroken, nil, why)
      self.oldReason = oldReason
    }
  }

  /// A failed check blocks apply; `ok` and `alreadyBroken` don't.
  public var isFailure: Bool { result == .mismatch || result == .unreachable }

  /// Why the check failed, without the URL: `reason` with it taken out
  /// (fetch errors name it), or the mismatch. Not part of the JSON.
  public var cause: String {
    switch result {
    case .ok: return "ok"
    case .mismatch: return "serves a different file"
    case .unreachable, .alreadyBroken:
      guard var text = reason, !text.isEmpty else { return "no reason given" }
      for form in [" for \(url)", ": \(url)", url] {
        text = text.replacingOccurrences(of: form, with: "")
      }
      text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":—-")))
      return text.isEmpty ? "no reason given" : text
    }
  }

  /// Why the old URL failed too, with any URL
  /// taken out so the same failure groups together; `cause` when there is
  /// no `oldReason` (runs recorded before it). Not part of the JSON.
  public var oldCause: String {
    guard var text = oldReason, !text.isEmpty else { return cause }
    text = text.replacingOccurrences(of: #"\s*(for )?https?://\S+?(?=:?(\s|$))"#, with: "", options: .regularExpression)
    text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":—-")))
    return text.isEmpty ? "no reason given" : text
  }

  enum CodingKeys: String, CodingKey {
    case url, result, reason
    case oldReason = "old_reason"
    case expectedSHA256 = "expected_sha256"
    case actualSHA256 = "actual_sha256"
  }
}

/// A domain migration writes this when it changes a backend's prefix.
public struct PrefixChangedEvent: Codable, Equatable, Sendable {
  public var backend: String
  public var from: String
  public var to: String

  public init(backend: String, from: String, to: String) {
    self.backend = backend
    self.from = from
    self.to = to
  }
}

public struct FileWrittenEvent: Codable, Equatable, Sendable {
  public var project: String
  public var source: String
  public var path: String
  public var beforeSHA256: String
  public var afterSHA256: String
  public var edits: Int
  public var backupPath: String?

  public init(
    project: String, source: String, path: String, beforeSHA256: String, afterSHA256: String,
    edits: Int, backupPath: String?
  ) {
    self.project = project
    self.source = source
    self.path = path
    self.beforeSHA256 = beforeSHA256
    self.afterSHA256 = afterSHA256
    self.edits = edits
    self.backupPath = backupPath
  }

  enum CodingKeys: String, CodingKey {
    case project, source, path, edits
    case beforeSHA256 = "before_sha256"
    case afterSHA256 = "after_sha256"
    case backupPath = "backup_path"
  }
}

public struct FileSkippedEvent: Codable, Equatable, Sendable {
  public var project: String
  public var source: String
  public var path: String
  public var reason: String

  public init(project: String, source: String, path: String, reason: String) {
    self.project = project
    self.source = source
    self.path = path
    self.reason = reason
  }
}

public struct FileFailedEvent: Codable, Equatable, Sendable {
  public var project: String
  public var source: String
  public var path: String
  public var error: String

  public init(project: String, source: String, path: String, error: String) {
    self.project = project
    self.source = source
    self.path = path
    self.error = error
  }
}

public struct RescanFinishedEvent: Codable, Equatable, Sendable {
  public var project: String
  public var refs: Int
  public var files: Int

  public init(project: String, refs: Int, files: Int) {
    self.project = project
    self.refs = refs
    self.files = files
  }
}

public struct RescanFailedEvent: Codable, Equatable, Sendable {
  public var project: String
  public var error: String

  public init(project: String, error: String) {
    self.project = project
    self.error = error
  }
}

/// The `run.summary` JSON and the `run_finished` data. The apply-only
/// fields are nil on a preview; `verified` is nil when nothing was checked.
public struct RewriteRunSummary: Codable, Equatable, Sendable {
  /// Files with at least one planned edit, and those edits.
  public var files: Int
  public var edits: Int
  /// Sites left as they are, by `RewriteSkipReason`.
  public var skippedEdits: [String: Int]
  public var protocolRelative: Int
  /// Target checks by result (`ok`, `mismatch`, `unreachable`).
  public var verified: [String: Int]?
  /// New URLs checked that resolve to no catalog asset, so only fetched.
  public var notInCatalog: Int?
  public var written: Int?
  /// Files not written, by `RewriteFileSkipReason`.
  public var skippedFiles: [String: Int]?
  public var failed: Int?
  /// Events at level error.
  public var errors: Int
  /// `{repository root: [paths relative to it]}`; files outside git are
  /// under the key `"null"` (JSON keys are strings).
  public var changedFilesByRepo: [String: [String]]?
  /// Set on an `external_migrate` run.
  public var migration: ExternalMigrationSummary?
  /// Set on an `optimize` run.
  public var optimize: OptimizeReport?

  public init(
    files: Int = 0, edits: Int = 0, skippedEdits: [String: Int] = [:], protocolRelative: Int = 0,
    verified: [String: Int]? = nil, notInCatalog: Int? = nil, written: Int? = nil, skippedFiles: [String: Int]? = nil,
    failed: Int? = nil, errors: Int = 0, changedFilesByRepo: [String: [String]]? = nil
  ) {
    self.files = files
    self.edits = edits
    self.skippedEdits = skippedEdits
    self.protocolRelative = protocolRelative
    self.verified = verified
    self.notInCatalog = notInCatalog
    self.written = written
    self.skippedFiles = skippedFiles
    self.failed = failed
    self.errors = errors
    self.changedFilesByRepo = changedFilesByRepo
  }

  /// The key `changedFilesByRepo` uses for files outside git.
  public static let notInGitKey = "null"

  enum CodingKeys: String, CodingKey {
    case files, edits, verified, written, failed, errors, migration, optimize
    case skippedEdits = "skipped_edits"
    case protocolRelative = "protocol_relative"
    case skippedFiles = "skipped_files"
    case notInCatalog = "not_in_catalog"
    case changedFilesByRepo = "changed_files_by_repo"
  }
}
