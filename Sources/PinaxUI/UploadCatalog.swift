import CatalogCore
import Foundation
import GRDB

public enum UploadCatalogError: Error, Equatable, CustomStringConvertible {
  case backendUnresolved
  case missingCredentials(String)

  public var description: String {
    switch self {
    case .backendUnresolved:
      return
        "No backend can be resolved: pick a project with a backend, or configure exactly one backend."
    case let .missingCredentials(slug):
      return
        "Credentials for backend '\(slug)' are unavailable. "
        + "Register them with: pinax backend set-credentials --slug \(slug)"
    }
  }
}

/// The upload operations the drop zone needs, as one injectable seam: the app
/// gets `UploadCatalog`, tests get an in-memory double, and no test ever
/// contacts the network or the keychain.
public protocol DropZoneService: Sendable {
  func projects() throws -> [Project]
  func upload(_ fileURL: URL, projectSlug: String?) async throws -> UploadOutcome
  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws
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

  public func upload(_ fileURL: URL, projectSlug: String?) async throws -> UploadOutcome {
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
    return try await pipeline.upload(fileURL: fileURL)
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
