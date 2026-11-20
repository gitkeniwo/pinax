import Foundation
import GRDB

public enum UploadPipelineError: Error, Equatable, CustomStringConvertible {
  case missingBackendID
  case missingProjectID
  case unsupportedFileType(String)
  case missingUploader
  /// The project's stored template (or the rendered key) is invalid; the
  /// upload never falls back to the default template.
  case invalidKeyTemplate(project: String?, issues: [KeyTemplateIssue])
  /// A new key is already used in the bucket by other content; nothing was
  /// overwritten.
  case keyTaken(String)

  public var description: String {
    switch self {
    case .missingBackendID:
      return "The selected backend has not been stored."
    case .missingProjectID:
      return "The selected project has not been stored."
    case let .unsupportedFileType(filename):
      return "Unsupported image type: \(filename)"
    case .missingUploader:
      return "An uploader is required unless dry-run is enabled."
    case let .invalidKeyTemplate(project, issues):
      let reasons = issues.map(\.message).joined(separator: " ")
      if let project {
        return "Can't build an object key for project '\(project)': \(reasons)"
      }
      return "Can't build an object key: \(reasons)"
    case let .keyTaken(key):
      return
        "The key \"\(key)\" is already taken in this bucket. "
        + "Add {hash} to the project's key template, or rename the file."
    }
  }
}

public struct UploadOutcome: Equatable, Sendable {
  public let sha256: String
  public let key: String
  public let url: String
  public let mime: String
  public let originalFilename: String
  public let byteSize: Int64
  public let width: Int?
  public let height: Int?
  public let uploadedAt: String
  public let deduplicated: Bool
  public let dryRun: Bool

  public init(
    sha256: String,
    key: String,
    url: String,
    mime: String,
    originalFilename: String,
    byteSize: Int64,
    width: Int?,
    height: Int?,
    uploadedAt: String,
    deduplicated: Bool,
    dryRun: Bool
  ) {
    self.sha256 = sha256
    self.key = key
    self.url = url
    self.mime = mime
    self.originalFilename = originalFilename
    self.byteSize = byteSize
    self.width = width
    self.height = height
    self.uploadedAt = uploadedAt
    self.deduplicated = deduplicated
    self.dryRun = dryRun
  }
}

public enum UploadOutputFormat: String, Sendable {
  case url
  case markdown
  case html
  case json
}

public enum UploadOutput {
  public static func format(_ outcomes: [UploadOutcome], as format: UploadOutputFormat) throws
    -> String
  {
    switch format {
    case .url:
      return outcomes.map(\.url).joined(separator: "\n")
    case .markdown:
      return outcomes.map { outcome in
        let alt = URL(fileURLWithPath: outcome.originalFilename)
          .deletingPathExtension().lastPathComponent
          .replacingOccurrences(of: "]", with: "\\]")
        return "![\(alt)](\(outcome.url))"
      }.joined(separator: "\n")
    case .html:
      return outcomes.map { outcome in
        let alt = htmlEscape(
          URL(fileURLWithPath: outcome.originalFilename).deletingPathExtension().lastPathComponent
        )
        let dimensions: String
        if let width = outcome.width, let height = outcome.height {
          dimensions = " width=\"\(width)\" height=\"\(height)\""
        } else {
          dimensions = ""
        }
        return "<img src=\"\(htmlEscape(outcome.url))\" alt=\"\(alt)\"\(dimensions)>"
      }.joined(separator: "\n")
    case .json:
      return try PublicAssetJSON.encode(outcomes.map(PublicAsset.init(upload:)))
    }
  }

  private static func htmlEscape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

public final class UploadPipeline: Sendable {
  private let database: DatabasePool
  private let uploader: (any Uploader)?
  private let backend: Backend
  private let project: Project?
  private let coordinator = UploadWorkCoordinator()
  /// Process-wide: every pipeline in the app shares it.
  private static let keyClaims = KeyClaims()
  private let dataReader: @Sendable (URL) throws -> Data

  public init(
    database: DatabasePool,
    uploader: (any Uploader)? = nil,
    backend: Backend,
    project: Project? = nil
  ) {
    self.database = database
    self.uploader = uploader
    self.backend = backend
    self.project = project
    self.dataReader = { try Data(contentsOf: $0) }
  }

  init(
    database: DatabasePool,
    uploader: (any Uploader)? = nil,
    backend: Backend,
    project: Project? = nil,
    dataReader: @escaping @Sendable (URL) throws -> Data
  ) {
    self.database = database
    self.uploader = uploader
    self.backend = backend
    self.project = project
    self.dataReader = dataReader
  }

  public func upload(
    fileURL: URL,
    force: Bool = false,
    dryRun: Bool = false,
    date: Date = Date(),
    sourceURL: String? = nil
  ) async throws -> UploadOutcome {
    guard let backendID = backend.id else {
      throw UploadPipelineError.missingBackendID
    }
    if project != nil, project?.id == nil {
      throw UploadPipelineError.missingProjectID
    }
    let sha256 = try Hashing.sha256(ofFileAt: fileURL)
    let workKey = "\(backendID):\(sha256):\(force):\(dryRun)"
    let task = await coordinator.task(for: workKey) { [self] in
      try await performUpload(
        fileURL: fileURL,
        preflightSHA256: sha256,
        backendID: backendID,
        force: force,
        dryRun: dryRun,
        date: date,
        sourceURL: sourceURL.map(AssetProvenance.recordedURL)
      )
    }
    return try await task.value
  }

  private func performUpload(
    fileURL: URL,
    preflightSHA256: String,
    backendID: Int64,
    force: Bool,
    dryRun: Bool,
    date: Date,
    sourceURL: String?
  ) async throws -> UploadOutcome {
    var sha256 = preflightSHA256
    var existing = try existingAsset(backendID: backendID, sha256: sha256)
    if let existing, !force || dryRun {
      if !dryRun, let projectID = project?.id, let assetID = existing.id {
        try link(assetID: assetID, projectID: projectID, date: date)
      }
      return outcome(for: existing, deduplicated: true, dryRun: dryRun)
    }

    let data = try dataReader(fileURL)
    let payloadSHA256 = Hashing.sha256(of: data)
    if payloadSHA256 != sha256 {
      sha256 = payloadSHA256
      existing = try existingAsset(backendID: backendID, sha256: sha256)
      if let existing, !force || dryRun {
        if !dryRun, let projectID = project?.id, let assetID = existing.id {
          try link(assetID: assetID, projectID: projectID, date: date)
        }
        return outcome(for: existing, deduplicated: true, dryRun: dryRun)
      }
    }

    let filename = fileURL.lastPathComponent
    guard let mime = MimeDetector.mimeType(of: data, fileExtension: fileURL.pathExtension) else {
      throw UploadPipelineError.unsupportedFileType(filename)
    }
    let dimensions = ImageProbe.dimensions(of: data)
    let key: String
    if let existing {
      key = existing.key
    } else {
      do {
        key = try KeyTemplate.render(
          template: project?.keyTemplate ?? KeyTemplate.defaultTemplate,
          keyPrefix: project?.keyPrefix ?? "",
          originalFilename: filename,
          sha256: sha256,
          fileExtension: fileURL.pathExtension,
          date: date
        )
      } catch let KeyTemplateError.invalid(issues) {
        throw UploadPipelineError.invalidKeyTemplate(project: project?.slug, issues: issues)
      }
    }
    let provisional = Asset(
      sha256: sha256,
      backendID: backendID,
      key: key,
      byteSize: Int64(data.count),
      width: dimensions?.width,
      height: dimensions?.height,
      mime: mime,
      originalFilename: filename,
      meta: sourceURL.map(AssetProvenance.migratedMeta(sourceURL:)) ?? "{}",
      uploadedAt: timestamp(date),
      createdAt: timestamp(date),
      updatedAt: timestamp(date)
    )
    if dryRun {
      return outcome(for: provisional, deduplicated: false, dryRun: true)
    }

    var metadata = [
      "sha256": sha256,
      "orig-filename": filename,
    ]
    if let width = dimensions?.width {
      metadata["width"] = String(width)
    }
    if let height = dimensions?.height {
      metadata["height"] = String(height)
    }
    if let sourceURL {
      metadata["source-url"] = AssetProvenance.percentEncodedNonASCII(sourceURL)
    }
    guard let uploader else {
      throw UploadPipelineError.missingUploader
    }
    let request = UploadRequest(
      data: data,
      sha256: sha256,
      key: key,
      mime: mime,
      metadata: metadata,
      createOnly: existing == nil
    )
    guard existing == nil else {
      // A forced re-upload rewrites its own object at its own key.
      _ = try await uploader.upload(request)
      return try await store(provisional, data: data, dimensions: dimensions, date: date)
    }

    // A new key: claim it in this process, check the catalog, then
    // create the object only if the bucket has none there.
    let claim = "\(database.path)\u{0}\(backendID)\u{0}\(key)"
    guard Self.keyClaims.claim(claim) else {
      throw UploadPipelineError.keyTaken(key)
    }
    defer { Self.keyClaims.release(claim) }
    // A key still in pending_deletion is taken too: its object may still be
    // cached as immutable, so reusing the key would keep serving the old image.
    let keyInCatalog = try await database.read { db in
      try Asset.filter(Column("backend_id") == backendID && Column("key") == key).fetchCount(db) > 0
        || Bool.fetchOne(
          db,
          sql: "SELECT EXISTS (SELECT 1 FROM pending_deletion WHERE backend_id = ? AND key = ?)",
          arguments: [backendID, key]) == true
    }
    if keyInCatalog {
      throw UploadPipelineError.keyTaken(key)
    }
    do {
      _ = try await uploader.upload(request)
    } catch UploaderError.objectAlreadyExists {
      // Most likely an earlier attempt wrote it and its response was lost.
      guard case let .present(remoteSHA256) = try await uploader.head(key: key),
        remoteSHA256 == sha256
      else {
        throw UploadPipelineError.keyTaken(key)
      }
    }
    return try await store(provisional, data: data, dimensions: dimensions, date: date)
  }

  /// Inserts the uploaded asset (or updates a force-re-uploaded one) and
  /// links it to the project. A failure here leaves the object in the
  /// bucket for Unreferenced Objects; nothing deletes it.
  private func store(
    _ provisional: Asset,
    data: Data,
    dimensions: ImageDimensions?,
    date: Date
  ) async throws -> UploadOutcome {
    let backendID = provisional.backendID
    let key = provisional.key
    let mime = provisional.mime
    let filename = provisional.originalFilename
    let storedSHA256 = provisional.sha256
    let stored = try await database.write { db in
      if var existing =
        try Asset
        .filter(Column("backend_id") == backendID && Column("sha256") == storedSHA256)
        .fetchOne(db)
      {
        existing.key = key
        existing.byteSize = Int64(data.count)
        existing.width = dimensions?.width
        existing.height = dimensions?.height
        existing.mime = mime
        existing.originalFilename = filename
        existing.uploadedAt = timestamp(date)
        existing.updatedAt = timestamp(date)
        try existing.update(db)
        try link(assetID: existing.id!, projectID: project?.id, date: date, in: db)
        return existing
      }
      let asset = try provisional.insertAndFetch(db)
      try link(assetID: asset.id!, projectID: project?.id, date: date, in: db)
      return asset
    }
    return outcome(for: stored, deduplicated: false, dryRun: false)
  }

  private func existingAsset(backendID: Int64, sha256: String) throws -> Asset? {
    try database.read { db in
      try Asset
        .filter(Column("backend_id") == backendID && Column("sha256") == sha256)
        .fetchOne(db)
    }
  }

  private func link(assetID: Int64, projectID: Int64, date: Date) throws {
    try database.write { db in
      try link(assetID: assetID, projectID: projectID, date: date, in: db)
    }
  }

  private func link(assetID: Int64, projectID: Int64?, date: Date, in db: GRDB.Database) throws {
    guard let projectID else { return }
    try db.execute(
      sql: "INSERT OR IGNORE INTO asset_project (asset_id, project_id, added_at) VALUES (?, ?, ?)",
      arguments: [assetID, projectID, timestamp(date)]
    )
  }

  private func outcome(for asset: Asset, deduplicated: Bool, dryRun: Bool) -> UploadOutcome {
    UploadOutcome(
      sha256: asset.sha256,
      key: asset.key,
      url: URLResolver.url(for: asset, backend: backend),
      mime: asset.mime,
      originalFilename: asset.originalFilename ?? asset.key,
      byteSize: asset.byteSize,
      width: asset.width,
      height: asset.height,
      uploadedAt: asset.uploadedAt,
      deduplicated: deduplicated,
      dryRun: dryRun
    )
  }

  private func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

/// Keys a running upload is about to create, per catalog and backend.
private final class KeyClaims: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = Set<String>()

  func claim(_ claim: String) -> Bool {
    lock.withLock { claimed.insert(claim).inserted }
  }

  func release(_ claim: String) {
    _ = lock.withLock { claimed.remove(claim) }
  }
}

private actor UploadWorkCoordinator {
  private struct Entry {
    let token: UUID
    let task: Task<UploadOutcome, Error>
  }

  private var entries: [String: Entry] = [:]

  func task(
    for key: String,
    operation: @escaping @Sendable () async throws -> UploadOutcome
  ) -> Task<UploadOutcome, Error> {
    if let existing = entries[key] {
      return existing.task
    }
    let token = UUID()
    let task = Task { try await operation() }
    entries[key] = Entry(token: token, task: task)
    Task { [weak self] in
      _ = await task.result
      await self?.remove(key: key, token: token)
    }
    return task
  }

  private func remove(key: String, token: UUID) {
    guard entries[key]?.token == token else { return }
    entries[key] = nil
  }
}
