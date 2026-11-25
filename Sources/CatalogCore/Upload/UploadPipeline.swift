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
  /// Set when the stored bytes are a recompressed copy of the file, whether
  /// uploaded now or reused.
  public let compression: UploadCompressionFacts?

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
    dryRun: Bool,
    compression: UploadCompressionFacts? = nil
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
    self.compression = compression
  }
}

extension Optional where Wrapped == PreparedUpload.Match {
  fileprivate var isOriginal: Bool {
    if case .original = self { return true }
    return false
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

  /// Prepares and uploads one file in one go, sending the compressed copy
  /// whenever compression made one. Concurrent calls for the same content,
  /// options and flags share one upload.
  public func upload(
    fileURL: URL,
    force: Bool = false,
    dryRun: Bool = false,
    date: Date = Date(),
    sourceURL: String? = nil,
    compression: CompressionOptions? = nil
  ) async throws -> UploadOutcome {
    let backendID = try checkedBackendID()
    let sha256 = try Hashing.sha256(ofFileAt: fileURL)
    let fingerprint = compression?.fingerprint ?? "original"
    let workKey = "\(backendID):\(sha256):\(fingerprint):\(force):\(dryRun)"
    let task = await coordinator.task(for: workKey) { [self] in
      let prepared = try prepare(
        fileURL: fileURL, preflightSHA256: sha256, backendID: backendID,
        compression: compression, force: force)
      return try await upload(
        prepared, useOriginal: false, dryRun: dryRun, date: date, sourceURL: sourceURL)
    }
    return try await task.value
  }

  /// Reads and hashes the file, looks it up, and compresses it when
  /// `compression` is given. Nothing is written. The catalog is matched
  /// first by the original's hash as stored bytes, then by the original's
  /// hash as the source of a copy made with the same options; a match skips
  /// compressing (unless `force`).
  public func prepare(
    fileURL: URL,
    compression: CompressionOptions? = nil,
    force: Bool = false
  ) async throws -> PreparedUpload {
    let backendID = try checkedBackendID()
    return try prepare(
      fileURL: fileURL, preflightSHA256: try Hashing.sha256(ofFileAt: fileURL),
      backendID: backendID, compression: compression, force: force)
  }

  private func prepare(
    fileURL: URL,
    preflightSHA256: String,
    backendID: Int64,
    compression options: CompressionOptions?,
    force: Bool
  ) throws -> PreparedUpload {
    func prepared(_ sha256: String, _ match: PreparedUpload.Match?, _ data: Data?)
      -> PreparedUpload
    {
      var result: CompressionResult?
      // A match is reused as it is, so there is nothing to compress unless
      // `force` sends the bytes again; an original is never compressed then.
      if let data, let options, match == nil || (force && !match.isOriginal) {
        result = ImageCompressor.compress(data, options: options)
      }
      return PreparedUpload(
        fileURL: fileURL, sourceSHA256: sha256, compressionOptions: options, force: force,
        match: match, compression: result, sourceData: data)
    }
    var sha256 = preflightSHA256
    var match = try catalogMatch(backendID: backendID, sourceSHA256: sha256, options: options)
    if match != nil, !force {
      return prepared(sha256, match, nil)
    }
    let data = try dataReader(fileURL)
    let payloadSHA256 = Hashing.sha256(of: data)
    if payloadSHA256 != sha256 {
      sha256 = payloadSHA256
      match = try catalogMatch(backendID: backendID, sourceSHA256: sha256, options: options)
      if match != nil, !force {
        return prepared(sha256, match, data)
      }
    }
    return prepared(sha256, match, data)
  }

  /// Finishes a prepared upload. With `useOriginal`, or when compression
  /// made no copy, the original's bytes are sent as they are; otherwise the
  /// compressed copy is, recorded with the original's hash. Either way the
  /// bytes about to be sent are looked up once more, since a compressed copy
  /// may already be in the catalog.
  public func upload(
    _ prepared: PreparedUpload,
    useOriginal: Bool,
    dryRun: Bool = false,
    date: Date = Date(),
    sourceURL: String? = nil
  ) async throws -> UploadOutcome {
    let backendID = try checkedBackendID()
    let force = prepared.force
    let sourceURL = sourceURL.map(AssetProvenance.recordedURL)
    switch prepared.match {
    case let .original(asset) where !force || dryRun:
      return try deduplicate(asset, facts: nil, dryRun: dryRun, date: date)
    case let .compressedCopy(asset) where !useOriginal && (!force || dryRun):
      return try deduplicate(
        asset, facts: UploadCompressionFacts(asset: asset), dryRun: dryRun, date: date)
    default:
      break
    }

    let source: Data
    let sourceSHA256: String
    if let data = prepared.sourceData {
      source = data
      sourceSHA256 = prepared.sourceSHA256
    } else {
      source = try dataReader(prepared.fileURL)
      sourceSHA256 = Hashing.sha256(of: source)
    }
    var compressed: CompressedImage?
    var facts: UploadCompressionFacts?
    if !useOriginal, let options = prepared.compressionOptions, !prepared.match.isOriginal {
      let result = prepared.compression ?? ImageCompressor.compress(source, options: options)
      if let image = result.compressedImage {
        compressed = image
        facts = UploadCompressionFacts(options: options, sourceSHA256: sourceSHA256, image: image)
      }
    }

    let data = compressed?.data ?? source
    let sha256 = compressed.map { Hashing.sha256(of: $0.data) } ?? sourceSHA256
    let existing = try existingAsset(backendID: backendID, sha256: sha256)
    if let existing, !force || dryRun {
      return try deduplicate(
        existing, facts: facts ?? UploadCompressionFacts(asset: existing), dryRun: dryRun,
        date: date)
    }

    let filename = prepared.fileURL.lastPathComponent
    let mime: String
    let dimensions: ImageDimensions?
    let fileExtension: String
    if let compressed {
      mime = compressed.mime
      dimensions = ImageDimensions(width: compressed.width, height: compressed.height)
      fileExtension = compressed.fileExtension
    } else {
      guard
        let detected = MimeDetector.mimeType(
          of: data, fileExtension: prepared.fileURL.pathExtension)
      else {
        throw UploadPipelineError.unsupportedFileType(filename)
      }
      mime = detected
      dimensions = ImageProbe.dimensions(of: data)
      fileExtension = prepared.fileURL.pathExtension
    }
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
          fileExtension: fileExtension,
          date: date
        )
      } catch let KeyTemplateError.invalid(issues) {
        throw UploadPipelineError.invalidKeyTemplate(project: project?.slug, issues: issues)
      }
    }
    let baseMeta = sourceURL.map(AssetProvenance.migratedMeta(sourceURL:)) ?? "{}"
    let provisional = Asset(
      sha256: sha256,
      backendID: backendID,
      key: key,
      byteSize: Int64(data.count),
      width: dimensions?.width,
      height: dimensions?.height,
      mime: mime,
      originalFilename: filename,
      meta: facts?.merged(intoMeta: baseMeta) ?? baseMeta,
      uploadedAt: timestamp(date),
      createdAt: timestamp(date),
      updatedAt: timestamp(date),
      sourceSHA256: facts?.sourceSHA256
    )
    if dryRun {
      return outcome(for: provisional, deduplicated: false, dryRun: true, compression: facts)
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
    if let facts {
      metadata["source-sha256"] = facts.sourceSHA256
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
      return try await store(provisional, facts: facts, date: date)
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
    return try await store(provisional, facts: facts, date: date)
  }

  private func checkedBackendID() throws -> Int64 {
    guard let backendID = backend.id else {
      throw UploadPipelineError.missingBackendID
    }
    if project != nil, project?.id == nil {
      throw UploadPipelineError.missingProjectID
    }
    return backendID
  }

  /// Reuses `asset`: links it to the project unless this is a dry run.
  private func deduplicate(
    _ asset: Asset, facts: UploadCompressionFacts?, dryRun: Bool, date: Date
  ) throws -> UploadOutcome {
    if !dryRun, let projectID = project?.id, let assetID = asset.id {
      try link(assetID: assetID, projectID: projectID, date: date)
    }
    return outcome(for: asset, deduplicated: true, dryRun: dryRun, compression: facts)
  }

  /// The catalog's asset for an original: stored as it is, or else a copy
  /// compressed from it with the same options.
  private func catalogMatch(
    backendID: Int64, sourceSHA256: String, options: CompressionOptions?
  ) throws -> PreparedUpload.Match? {
    if let asset = try existingAsset(backendID: backendID, sha256: sourceSHA256) {
      return .original(asset)
    }
    guard let options else { return nil }
    let copies = try database.read { db in
      try Asset
        .filter(Column("backend_id") == backendID && Column("source_sha256") == sourceSHA256)
        .order(Column("id"))
        .fetchAll(db)
    }
    let fingerprint = options.fingerprint
    return copies.first { UploadCompressionFacts.fingerprint(inMeta: $0.meta) == fingerprint }
      .map(PreparedUpload.Match.compressedCopy)
  }

  /// Inserts the uploaded asset (or updates a force-re-uploaded one) and
  /// links it to the project. A failure here leaves the object in the
  /// bucket for Unreferenced Objects; nothing deletes it.
  private func store(
    _ provisional: Asset,
    facts: UploadCompressionFacts?,
    date: Date
  ) async throws -> UploadOutcome {
    let backendID = provisional.backendID
    let storedSHA256 = provisional.sha256
    let stored = try await database.write { db in
      if var existing =
        try Asset
        .filter(Column("backend_id") == backendID && Column("sha256") == storedSHA256)
        .fetchOne(db)
      {
        existing.key = provisional.key
        existing.byteSize = provisional.byteSize
        existing.width = provisional.width
        existing.height = provisional.height
        existing.mime = provisional.mime
        existing.originalFilename = provisional.originalFilename
        existing.uploadedAt = timestamp(date)
        existing.updatedAt = timestamp(date)
        if let facts {
          existing.sourceSHA256 = facts.sourceSHA256
          existing.meta = facts.merged(intoMeta: existing.meta)
        }
        try existing.update(db)
        try link(assetID: existing.id!, projectID: project?.id, date: date, in: db)
        return existing
      }
      let asset = try provisional.insertAndFetch(db)
      try link(assetID: asset.id!, projectID: project?.id, date: date, in: db)
      return asset
    }
    return outcome(for: stored, deduplicated: false, dryRun: false, compression: facts)
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

  private func outcome(
    for asset: Asset, deduplicated: Bool, dryRun: Bool, compression: UploadCompressionFacts?
  ) -> UploadOutcome {
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
      dryRun: dryRun,
      compression: compression
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
