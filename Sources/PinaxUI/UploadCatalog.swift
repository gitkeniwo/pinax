import CatalogCore
import Foundation
import GRDB

public enum UploadCatalogError: Error, Equatable, CustomStringConvertible {
  case backendUnresolved
  case missingCredentials(String)
  case notPrepared

  public var description: String {
    switch self {
    case .backendUnresolved:
      return
        "No backend can be resolved: pick a project with a backend, or configure exactly one backend."
    case let .missingCredentials(slug):
      return
        "Credentials for backend '\(slug)' are unavailable. "
        + "Register them with: pinax backend set-credentials --slug \(slug)"
    case .notPrepared:
      return "This upload was not prepared here."
    }
  }
}

/// A file looked up and, when its project asks, recompressed: ready to
/// upload.
public struct PreparedDrop: Sendable {
  /// Why a file can only go up as it is.
  public enum OriginalReason: Equatable, Sendable {
    /// The copy saved too little.
    case notSmaller
    /// Transparent, animated, or a format the compressor leaves alone.
    case notCompressible
    /// The library already has these bytes; nothing is sent.
    case inLibrary
  }

  public let fileURL: URL
  public let projectSlug: String?
  /// The copy that is about to be sent; nil when none was made.
  public let compression: CardCompression?
  /// The original as it is on disk, for a card that shows it before it is
  /// sent; nil when nobody measured it.
  public let sourceByteSize: Int64?
  public let sourceWidth: Int?
  public let sourceHeight: Int?
  /// Whether the project itself would send the copy: a reviewed card's
  /// switch starts here.
  public let compressesByDefault: Bool
  /// Set only when there is no copy to choose.
  public let originalReason: OriginalReason?
  /// `UploadCatalog`'s own half-done upload; nil from any other service.
  let pending: (pipeline: UploadPipeline, upload: PreparedUpload)?

  public init(
    fileURL: URL, projectSlug: String?, compression: CardCompression? = nil,
    sourceByteSize: Int64? = nil, sourceWidth: Int? = nil, sourceHeight: Int? = nil,
    compressesByDefault: Bool? = nil, originalReason: OriginalReason? = nil
  ) {
    self.fileURL = fileURL
    self.projectSlug = projectSlug
    self.compression = compression
    self.sourceByteSize = sourceByteSize ?? compression?.sourceByteSize
    self.sourceWidth = sourceWidth ?? compression?.sourceWidth
    self.sourceHeight = sourceHeight ?? compression?.sourceHeight
    self.compressesByDefault = compressesByDefault ?? (compression != nil)
    self.originalReason = compression == nil ? (originalReason ?? .notSmaller) : nil
    self.pending = nil
  }

  init(
    pipeline: UploadPipeline, upload: PreparedUpload, projectSlug: String?,
    compressesByDefault: Bool, reusedCopy: CardCompression? = nil
  ) {
    self.fileURL = upload.fileURL
    self.projectSlug = projectSlug
    if let image = upload.compression?.compressedImage, let options = upload.compressionOptions {
      self.compression = CardCompression(image: image, options: options)
    } else {
      self.compression = reusedCopy
    }
    // Without a copy the original's own header says how big it is.
    let dimensions = compression == nil ? ImageProbe.dimensions(ofFileAt: upload.fileURL) : nil
    self.sourceByteSize =
      upload.sourceByteSize ?? compression?.sourceByteSize ?? Self.fileSize(upload.fileURL)
    self.sourceWidth = compression?.sourceWidth ?? dimensions?.width
    self.sourceHeight = compression?.sourceHeight ?? dimensions?.height
    self.compressesByDefault = compressesByDefault
    switch (compression, upload.match, upload.compression?.skipReason) {
    case (.some, _, _): self.originalReason = nil
    case (nil, .original, _): self.originalReason = .inLibrary
    case (nil, _, .notSmaller), (nil, _, nil): self.originalReason = .notSmaller
    case (nil, _, .some): self.originalReason = .notCompressible
    }
    self.pending = (pipeline, upload)
  }

  private static func fileSize(_ url: URL) -> Int64? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
  }
}

/// The upload operations the drop zone needs, as one injectable seam: the app
/// gets `UploadCatalog`, tests get an in-memory double, and no test ever
/// contacts the network or the keychain.
public protocol DropZoneService: Sendable {
  func projects() throws -> [Project]
  /// Everything before sending: resolves the destination, looks the file up
  /// and recompresses it when the project asks.
  func prepare(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop
  /// The same for a file the user reviews before it is sent: a copy is
  /// made even when the project would not send one, so switching
  /// compression on needs no second pass.
  func prepareForReview(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop
  /// Sends a prepared file: its compressed copy when it has one, unless
  /// `useOriginal`.
  func upload(_ prepared: PreparedDrop, useOriginal: Bool) async throws -> UploadOutcome
  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws
}

extension DropZoneService {
  /// A service with nothing to add prepares a reviewed file as any other.
  public func prepareForReview(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    try await prepare(fileURL, projectSlug: projectSlug)
  }
}

/// The upload write path. The drop zone reaches uploading through this type alone;
/// it mirrors the CLI's resolution rules (the project's backend, else the single
/// configured backend) and keeps the pipeline's pieces out of the view layer.
public struct UploadCatalog: DropZoneService {
  private let database: DatabasePool
  private let credentialsLoader: @Sendable (Backend) throws -> BackendCredentials?
  private let uploaderFactory: @Sendable (Backend, BackendCredentials) -> any Uploader

  public init(
    database: DatabasePool,
    credentialsLoader: @escaping @Sendable (Backend) throws -> BackendCredentials? = {
      try Keychain().load(for: $0.keychainRef)
    },
    uploaderFactory: @escaping @Sendable (Backend, BackendCredentials) -> any Uploader = {
      S3Uploader(backend: $0, credentials: $1)
    }
  ) {
    self.database = database
    self.credentialsLoader = credentialsLoader
    self.uploaderFactory = uploaderFactory
  }

  public func projects() throws -> [Project] {
    try CatalogConfiguration.projects(in: database)
  }

  /// Both steps in one go.
  public func upload(_ fileURL: URL, projectSlug: String?) async throws -> UploadOutcome {
    try await upload(prepare(fileURL, projectSlug: projectSlug), useOriginal: false)
  }

  /// Compression follows the project's switch; No Project is never
  /// compressed.
  public func prepare(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    let (pipeline, project) = try makePipeline(projectSlug: projectSlug)
    let options = CompressionChoice.project.options(for: project)
    let prepared = try await pipeline.prepare(fileURL: fileURL, compression: options)
    return PreparedDrop(
      pipeline: pipeline, upload: prepared, projectSlug: projectSlug,
      compressesByDefault: options != nil)
  }

  /// A project that does not compress (or No Project) is offered a copy
  /// made with the default options.
  public func prepareForReview(_ fileURL: URL, projectSlug: String?) async throws -> PreparedDrop {
    let (pipeline, project) = try makePipeline(projectSlug: projectSlug)
    let projectOptions = CompressionChoice.project.options(for: project)
    let prepared = try await pipeline.prepare(
      fileURL: fileURL, compression: projectOptions ?? .default)
    // A copy the library already holds was not made again; a dry run of its
    // reuse reads its sizes back without linking anything.
    var reused: CardCompression?
    if case .compressedCopy = prepared.match {
      let outcome = try await pipeline.upload(prepared, useOriginal: false, dryRun: true)
      reused = CardCompression(outcome: outcome)
    }
    return PreparedDrop(
      pipeline: pipeline, upload: prepared, projectSlug: projectSlug,
      compressesByDefault: projectOptions != nil, reusedCopy: reused)
  }

  private func makePipeline(projectSlug: String?) throws -> (UploadPipeline, Project?) {
    let projects = try CatalogConfiguration.projects(in: database)
    var project: Project?
    if let projectSlug {
      guard let match = projects.first(where: { $0.slug == projectSlug }) else {
        throw CatalogConfigurationError.projectNotFound(projectSlug)
      }
      project = match
    }
    let backends = try CatalogConfiguration.backends(in: database)
    let backend = try resolveBackend(backends: backends, project: project)
    guard let credentials = try credentialsLoader(backend) else {
      throw UploadCatalogError.missingCredentials(backend.slug)
    }
    let pipeline = UploadPipeline(
      database: database,
      uploader: uploaderFactory(backend, credentials),
      backend: backend,
      project: project
    )
    return (pipeline, project)
  }

  public func upload(_ prepared: PreparedDrop, useOriginal: Bool) async throws -> UploadOutcome {
    guard let pending = prepared.pending else { throw UploadCatalogError.notPrepared }
    return try await pending.pipeline.upload(pending.upload, useOriginal: useOriginal)
  }

  /// Moves an asset's project membership atomically. `nil` sides mean "no
  /// project", so link, unlink, and move are all expressible. The outgoing
  /// side carries the live-usage guard: an unconfirmed move away from a
  /// project that still references the asset is refused, whole.
  public func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool = false
  ) async throws {
    try await CatalogAssets.moveAsset(
      sha256,
      fromProject: fromProject,
      toProject: toProject,
      in: database,
      confirmed: confirmed
    )
  }

  private func resolveBackend(backends: [Backend], project: Project?) throws -> Backend {
    if let backendID = project?.backendID,
      let match = backends.first(where: { $0.id == backendID })
    {
      return match
    }
    if backends.count == 1, let only = backends.first {
      return only
    }
    throw UploadCatalogError.backendUnresolved
  }
}
