import Foundation
import GRDB

public enum ManifestError: Error, Equatable, CustomStringConvertible {
  case projectNotFound(String)
  case projectHasNoBackend(String)
  case assetBackendMissing(String)

  public var description: String {
    switch self {
    case let .projectNotFound(slug):
      return "Project '\(slug)' does not exist."
    case let .projectHasNoBackend(slug):
      return "Project '\(slug)' has no backend."
    case let .assetBackendMissing(key):
      return "The backend for asset '\(key)' does not exist."
    }
  }
}

public struct ManifestBackend: Codable, Equatable, Sendable {
  public let slug: String
  public let urlPrefix: String

  enum CodingKeys: String, CodingKey {
    case slug
    case urlPrefix = "url_prefix"
  }
}

public struct AssetManifest: Codable, Equatable, Sendable {
  public let schema: Int
  public let generatedAt: String
  public let project: String
  public let backend: ManifestBackend
  public let assets: [PublicAsset]

  public init(
    schema: Int = 1,
    generatedAt: String,
    project: String,
    backend: ManifestBackend,
    assets: [PublicAsset]
  ) {
    self.schema = schema
    self.generatedAt = generatedAt
    self.project = project
    self.backend = backend
    self.assets = assets
  }

  enum CodingKeys: String, CodingKey {
    case schema, project, backend, assets
    case generatedAt = "generated_at"
  }

  public func json() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}

public enum CatalogManifest {
  public static func export(
    project slug: String,
    from database: CatalogDatabasePool,
    generatedAt: Date = Date()
  ) throws -> AssetManifest {
    try database.read { db in
      guard let project = try Project.filter(Column("slug") == slug).fetchOne(db) else {
        throw ManifestError.projectNotFound(slug)
      }
      guard let projectBackendID = project.backendID,
        let projectBackend = try Backend.fetchOne(db, key: projectBackendID)
      else {
        throw ManifestError.projectHasNoBackend(slug)
      }
      let assets = try Asset.fetchAll(
        db,
        sql: """
          SELECT a.*
          FROM asset a
          JOIN asset_project ap ON ap.asset_id = a.id
          WHERE ap.project_id = ? AND a.state = 'active'
          ORDER BY a.uploaded_at, a.id
          """,
        arguments: [project.id]
      )
      let backendIDs = Set(assets.map(\.backendID))
      let assetBackends = try Backend.filter(backendIDs.contains(Column("id"))).fetchAll(db)
      let backendByID = Dictionary(
        uniqueKeysWithValues: assetBackends.compactMap { backend in
          backend.id.map { ($0, backend) }
        }
      )
      let publicAssets = try assets.map { asset in
        guard let backend = backendByID[asset.backendID] else {
          throw ManifestError.assetBackendMissing(asset.key)
        }
        return PublicAsset(asset: asset, backend: backend)
      }
      return AssetManifest(
        generatedAt: timestamp(generatedAt),
        project: slug,
        backend: ManifestBackend(slug: projectBackend.slug, urlPrefix: projectBackend.urlPrefix),
        assets: publicAssets
      )
    }
  }

  private static func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
