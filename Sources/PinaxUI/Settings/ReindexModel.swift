import CatalogCore
import Foundation
import GRDB

public enum ReindexRunnerError: Error, Equatable, CustomStringConvertible {
  case credentialsNotConfigured(String)

  public var description: String {
    switch self {
    case let .credentialsNotConfigured(slug):
      return "Backend '\(slug)' does not have configured credentials."
    }
  }
}

public protocol ReindexRunning: Sendable {
  func run(backendSlug: String, dryRun: Bool) async throws -> ReindexResult
}

public struct CatalogReindexRunner: ReindexRunning {
  public typealias InventoryFactory =
    @Sendable (Backend, BackendCredentials) -> any ObjectInventory

  private let database: DatabasePool
  private let keychain: Keychain
  private let inventoryFactory: InventoryFactory

  public init(
    database: DatabasePool,
    keychain: Keychain = Keychain(),
    inventoryFactory: @escaping InventoryFactory = { backend, credentials in
      S3ObjectInventory(backend: backend, credentials: credentials)
    }
  ) {
    self.database = database
    self.keychain = keychain
    self.inventoryFactory = inventoryFactory
  }

  public func run(backendSlug: String, dryRun: Bool) async throws -> ReindexResult {
    let database = database
    let keychain = keychain
    let (backend, credentials) = try await Task.detached {
      let backend = try CatalogConfiguration.backend(slug: backendSlug, in: database)
      guard !backend.keychainRef.isEmpty,
        let credentials = try keychain.load(for: backend.keychainRef)
      else {
        throw ReindexRunnerError.credentialsNotConfigured(backendSlug)
      }
      return (backend, credentials)
    }.value
    let inventory = inventoryFactory(backend, credentials)
    return try await CatalogReindex.run(
      backend: backend, inventory: inventory, database: database, dryRun: dryRun)
  }
}
