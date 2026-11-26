import Foundation
import GRDB

public enum CatalogConfigurationError: Error, Equatable, CustomStringConvertible {
  case backendNotFound(String)
  case projectNotFound(String)
  case noProjectChanges
  case invalidSourceLabel(String)
  case duplicateSourceLabel(String)
  case relativeSourcePath(String)
  case emptySourceCommand(label: String)
  case sourceCommandTooLong(label: String)
  case relativeWorkingDirectory(String)
  case tooManySources(Int)
  case projectMetaNotObject(String)
  case sourceNotFound(project: String, label: String)
  case invalidOldDomain(String)
  case oldDomainIsCurrent(String)
  case oldDomainNotFound(backend: String, prefix: String)
  /// A domain belongs to one backend; `prefix` is
  /// already `backend`'s current or old domain.
  case domainOfOtherBackend(prefix: String, backend: String)
  /// The errors of a key template and of the key it renders, in code order.
  case invalidKeyTemplate([KeyTemplateIssue])

  public var description: String {
    switch self {
    case let .backendNotFound(slug):
      return "Backend '\(slug)' does not exist."
    case let .projectNotFound(slug):
      return "Project '\(slug)' does not exist."
    case .noProjectChanges:
      return "Specify at least one project setting to change."
    case let .invalidSourceLabel(label):
      return "Source label '\(label)' must be 1–64 letters, digits, '.', '_' or '-'."
    case let .duplicateSourceLabel(label):
      return "Source label '\(label)' is already used in this project."
    case let .relativeSourcePath(path):
      return "Source path '\(path)' must be absolute."
    case let .emptySourceCommand(label):
      return "Source '\(label)' needs a command."
    case let .sourceCommandTooLong(label):
      return
        "Source '\(label)' has a command longer than \(ProjectSource.maximumCommandLength) characters."
    case let .relativeWorkingDirectory(path):
      return "Working directory '\(path)' must be absolute."
    case let .tooManySources(count):
      return "A project has at most \(ProjectSettings.maximumSources) sources; got \(count)."
    case let .projectMetaNotObject(slug):
      return "Project '\(slug)' has settings that are not a JSON object; they were left unchanged."
    case let .sourceNotFound(project, label):
      return "Project '\(project)' has no source '\(label)'."
    case let .invalidOldDomain(prefix):
      return "Old domain '\(prefix)' must be an http:// or https:// URL with a host."
    case let .oldDomainIsCurrent(prefix):
      return "'\(prefix)' is the backend's current URL prefix."
    case let .oldDomainNotFound(backend, prefix):
      return "Backend '\(backend)' has no old domain '\(prefix)'."
    case let .domainOfOtherBackend(prefix, backend):
      return "'\(prefix)' is already a domain of backend '\(backend)'. A domain belongs to one backend."
    case let .invalidKeyTemplate(issues):
      return issues.map(\.message).joined(separator: "\n")
    }
  }
}
public struct RewriteMap: Codable, Equatable, Sendable {
  public let schema: Int
  public let current: String
  public let retired: [String]

  public init(schema: Int = 1, current: String, retired: [String]) {
    self.schema = schema
    self.current = current
    self.retired = retired
  }
}

/// What `setProject` does to a project's key template.
public enum KeyTemplateChange: Equatable, Sendable {
  case unchanged
  /// Validated first; the default template's text is stored as NULL.
  case set(String)
  /// Back to the default template (NULL).
  case reset
}

public enum CatalogConfiguration {
  public static func addBackend(
    slug: String,
    endpoint: String,
    bucket: String,
    region: String,
    urlPrefix: String,
    keychainReference: String,
    meta: String = "{}",
    to database: DatabasePool,
    now: Date = Date()
  ) throws -> Backend {
    let timestamp = timestamp(now)
    let backend = Backend(
      slug: slug,
      kind: "s3",
      endpoint: trimTrailingSlashes(endpoint),
      bucket: bucket,
      region: region,
      urlPrefix: trimTrailingSlashes(urlPrefix),
      keychainRef: keychainReference,
      meta: meta,
      createdAt: timestamp,
      updatedAt: timestamp
    )
    return try database.write { db in
      try backend.insertAndFetch(db)
    }
  }

  public static func backends(in database: DatabasePool) throws -> [Backend] {
    try database.read { db in
      try Backend.order(Column("slug")).fetchAll(db)
    }
  }

  public static func backend(slug: String, in database: DatabasePool) throws -> Backend {
    try database.read { db in
      guard let backend = try Backend.filter(Column("slug") == slug).fetchOne(db) else {
        throw CatalogConfigurationError.backendNotFound(slug)
      }
      return backend
    }
  }

  /// Fills a backend's empty `keychain_ref` after credentials were attached
  /// post-registration (`pinax backend set-credentials`). A backend that
  /// already has a reference keeps it — the reference is the identity of the
  /// Keychain item, and changing it would orphan a stored credential.
  public static func attachKeychainReference(
    slug: String,
    reference: String,
    in database: DatabasePool,
    now: Date = Date()
  ) throws -> Backend {
    try database.write { db in
      guard var backend = try Backend.filter(Column("slug") == slug).fetchOne(db) else {
        throw CatalogConfigurationError.backendNotFound(slug)
      }
      guard backend.keychainRef.isEmpty else {
        return backend
      }
      backend.keychainRef = reference
      backend.updatedAt = timestamp(now)
      try backend.update(db)
      return backend
    }
  }

  public static func addProject(
    slug: String,
    name: String,
    keyPrefix: String,
    keyTemplate: String? = nil,
    backendSlug: String,
    to database: DatabasePool,
    now: Date = Date()
  ) throws -> Project {
    let timestamp = timestamp(now)
    let storedTemplate = try keyTemplate.flatMap {
      try validatedKeyTemplate($0, keyPrefix: keyPrefix, now: now)
    }
    return try database.write { db in
      guard let backend = try Backend.filter(Column("slug") == backendSlug).fetchOne(db),
        let backendID = backend.id
      else {
        throw CatalogConfigurationError.backendNotFound(backendSlug)
      }
      let project = Project(
        slug: slug,
        name: name,
        keyPrefix: normalizeKeyPrefix(keyPrefix),
        keyTemplate: storedTemplate,
        backendID: backendID,
        createdAt: timestamp,
        updatedAt: timestamp
      )
      return try project.insertAndFetch(db)
    }
  }

  public static func projects(in database: DatabasePool) throws -> [Project] {
    try database.read { db in
      try Project.order(Column("slug")).fetchAll(db)
    }
  }

  public static func setProject(
    slug: String,
    name: String?,
    keyPrefix: String?,
    backendSlug: String?,
    keyTemplate: KeyTemplateChange = .unchanged,
    in database: DatabasePool,
    now: Date = Date()
  ) throws -> Project {
    guard name != nil || keyPrefix != nil || backendSlug != nil || keyTemplate != .unchanged
    else {
      throw CatalogConfigurationError.noProjectChanges
    }
    let timestamp = timestamp(now)
    return try database.write { db in
      guard var project = try Project.filter(Column("slug") == slug).fetchOne(db) else {
        throw CatalogConfigurationError.projectNotFound(slug)
      }
      if let name {
        project.name = name
      }
      if let keyPrefix {
        project.keyPrefix = normalizeKeyPrefix(keyPrefix)
      }
      switch keyTemplate {
      case .unchanged:
        break
      case let .set(template):
        project.keyTemplate = try validatedKeyTemplate(
          template, keyPrefix: project.keyPrefix, now: now)
      case .reset:
        project.keyTemplate = nil
      }
      if let backendSlug {
        guard let backend = try Backend.filter(Column("slug") == backendSlug).fetchOne(db),
          let backendID = backend.id
        else {
          throw CatalogConfigurationError.backendNotFound(backendSlug)
        }
        project.backendID = backendID
      }
      project.updatedAt = timestamp
      try project.update(db)
      return project
    }
  }

  /// Sets a project's backend to NULL — "inherit": uploads for the project
  /// resolve the sole registered backend instead of a project-specific one.
  /// `setProject` cannot express this: its `nil` backendSlug means "leave
  /// unchanged", so the GUI's "inherit / none" picker choice needs its own
  /// write path.
  public static func clearProjectBackend(
    slug: String,
    in database: DatabasePool,
    now: Date = Date()
  ) throws -> Project {
    let timestamp = timestamp(now)
    return try database.write { db in
      guard var project = try Project.filter(Column("slug") == slug).fetchOne(db) else {
        throw CatalogConfigurationError.projectNotFound(slug)
      }
      project.backendID = nil
      project.updatedAt = timestamp
      try project.update(db)
      return project
    }
  }

  public static func setBackendURLPrefix(
    slug: String,
    urlPrefix: String,
    in database: DatabasePool,
    now: Date = Date()
  ) throws -> Backend {
    let normalizedPrefix = trimTrailingSlashes(urlPrefix)
    let timestamp = timestamp(now)
    return try database.write { db in
      guard var backend = try Backend.filter(Column("slug") == slug).fetchOne(db),
        let backendID = backend.id
      else {
        throw CatalogConfigurationError.backendNotFound(slug)
      }
      guard backend.urlPrefix != normalizedPrefix else { return backend }
      if let owner = try otherBackendOwning(normalizedPrefix, besides: backendID, in: db) {
        throw CatalogConfigurationError.domainOfOtherBackend(prefix: normalizedPrefix, backend: owner)
      }
      var retiredPrefix = BackendPrefixHistory(
        backendID: backendID,
        urlPrefix: backend.urlPrefix,
        retiredAt: timestamp
      )
      try retiredPrefix.insert(db)
      backend.urlPrefix = normalizedPrefix
      backend.updatedAt = timestamp
      try backend.update(db)
      return backend
    }
  }

  public static func rewriteMap(
    backendSlug: String,
    in database: DatabasePool
  ) throws -> RewriteMap {
    try database.read { db in
      guard let backend = try Backend.filter(Column("slug") == backendSlug).fetchOne(db),
        let backendID = backend.id
      else {
        throw CatalogConfigurationError.backendNotFound(backendSlug)
      }
      let prefixes = try String.fetchAll(
        db,
        sql: """
          SELECT url_prefix
          FROM backend_prefix_history
          WHERE backend_id = ? AND url_prefix <> ?
          ORDER BY id
          """,
        arguments: [backendID, backend.urlPrefix]
      )
      var seen = Set<String>()
      return RewriteMap(
        current: backend.urlPrefix,
        retired: prefixes.filter { seen.insert($0).inserted }
      )
    }
  }

  /// The value to store for `template` (nil for the default template), or
  /// the template's errors.
  private static func validatedKeyTemplate(
    _ template: String, keyPrefix: String, now: Date
  ) throws -> String? {
    let evaluation = KeyTemplate.evaluate(template, keyPrefix: keyPrefix, date: now)
    guard evaluation.isValid else {
      throw CatalogConfigurationError.invalidKeyTemplate(evaluation.errors)
    }
    return KeyTemplate.storedValue(for: template)
  }

  private static func normalizeKeyPrefix(_ prefix: String) -> String {
    prefix.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
  }

  private static func trimTrailingSlashes(_ value: String) -> String {
    var result = value
    while result.last == "/" {
      result.removeLast()
    }
    return result
  }

  private static func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  // MARK: - Project settings in `project.meta`

  /// A project's sources and usage tracking, read tolerantly from
  /// `project.meta`: a value that is not a JSON object reads as none.
  public static func projectSettings(slug: String, in database: DatabasePool) throws
    -> ProjectSettings
  {
    try database.read { db in
      guard let project = try Project.filter(Column("slug") == slug).fetchOne(db) else {
        throw CatalogConfigurationError.projectNotFound(slug)
      }
      return ProjectSettings(meta: project.meta)
    }
  }

  /// Replaces a project's sources. Labels must match
  /// `ProjectSettings`' label rule and be unique
  /// within the project, paths and working directories must be absolute
  /// (they are stored standardized), a command is stored trimmed, not empty
  /// and at most `ProjectSource.maximumCommandLength` characters, and a
  /// project has at most 16 sources. Every other key in
  /// `meta` is kept; a `meta` that is not a JSON object is left untouched
  /// and the write is refused.
  @discardableResult
  public static func setProjectSources(
    slug: String,
    _ sources: [ProjectSource],
    in database: DatabasePool,
    now: Date = Date()
  ) throws -> ProjectSettings {
    guard sources.count <= ProjectSettings.maximumSources else {
      throw CatalogConfigurationError.tooManySources(sources.count)
    }
    var seen = Set<String>()
    var normalized: [ProjectSource] = []
    for var source in sources {
      guard ProjectSource.isValidLabel(source.label) else {
        throw CatalogConfigurationError.invalidSourceLabel(source.label)
      }
      guard seen.insert(source.label).inserted else {
        throw CatalogConfigurationError.duplicateSourceLabel(source.label)
      }
      switch source.kind {
      case .folder:
        guard source.path.hasPrefix("/") else {
          throw CatalogConfigurationError.relativeSourcePath(source.path)
        }
        source.path = URL(fileURLWithPath: source.path).standardizedFileURL.path
        normalized.append(
          ProjectSource(
            label: source.label, path: source.path, include: source.include,
            exclude: source.exclude))
      case .command:
        let command = source.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
          throw CatalogConfigurationError.emptySourceCommand(label: source.label)
        }
        guard command.count <= ProjectSource.maximumCommandLength else {
          throw CatalogConfigurationError.sourceCommandTooLong(label: source.label)
        }
        guard source.workingDirectory.hasPrefix("/") else {
          throw CatalogConfigurationError.relativeWorkingDirectory(source.workingDirectory)
        }
        normalized.append(
          ProjectSource(
            label: source.label, command: command,
            workingDirectory: URL(fileURLWithPath: source.workingDirectory)
              .standardizedFileURL.path))
      }
    }
    return try updateProjectMeta(slug: slug, in: database, now: now) { object in
      object["sources"] = normalized.map(\.json)
    }
  }

  @discardableResult
  public static func setUsageTracking(
    slug: String,
    _ tracking: UsageTracking,
    in database: DatabasePool,
    now: Date = Date()
  ) throws -> ProjectSettings {
    try updateProjectMeta(slug: slug, in: database, now: now) { object in
      object["usageTracking"] = tracking.rawValue
    }
  }

  /// Changes a project's upload compression, starting from what is stored
  /// (or the default when nothing is), in one write transaction.
  @discardableResult
  public static func setCompression(
    slug: String,
    in database: DatabasePool,
    now: Date = Date(),
    _ change: (inout ProjectCompression) -> Void
  ) throws -> ProjectSettings {
    try updateProjectMeta(slug: slug, in: database, now: now) { object in
      var compression = object["compression"].map(ProjectCompression.init(json:)) ?? ProjectCompression()
      change(&compression)
      object["compression"] = compression.json
    }
  }

  @discardableResult
  public static func setAutoScan(
    slug: String,
    _ autoScan: ProjectAutoScan,
    in database: DatabasePool,
    now: Date = Date()
  ) throws -> ProjectSettings {
    try updateProjectMeta(slug: slug, in: database, now: now) { object in
      object["autoScan"] = autoScan.json
    }
  }

  /// Read → change one key → write back, in one write transaction.
  private static func updateProjectMeta(
    slug: String,
    in database: DatabasePool,
    now: Date,
    _ change: (inout [String: Any]) -> Void
  ) throws -> ProjectSettings {
    let timestamp = timestamp(now)
    return try database.write { db in
      guard var project = try Project.filter(Column("slug") == slug).fetchOne(db) else {
        throw CatalogConfigurationError.projectNotFound(slug)
      }
      guard var object = ProjectSettings.object(project.meta) else {
        throw CatalogConfigurationError.projectMetaNotObject(slug)
      }
      change(&object)
      let data = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      project.meta = String(decoding: data, as: UTF8.self)
      project.updatedAt = timestamp
      try project.update(db)
      return ProjectSettings(meta: project.meta)
    }
  }
}
