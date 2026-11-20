import CatalogCore
import Foundation
import GRDB

/// The gallery's write path. Views obtain editing through this type alone; it pairs a
/// `ReadOnlyCatalog` for reads and exposes exactly the mutations the gallery
/// offers — tags, note, project membership, and archive, favourite and
/// labels — and nothing else. It holds a database and no backend: none of
/// these edits can reach the object store.
public struct EditableCatalog: Sendable {
  private let database: DatabasePool

  public init(database: DatabasePool) {
    self.database = database
  }

  public func setNote(_ note: String?, for identifier: String) async throws {
    try await CatalogAssets.setNote(note, for: identifier, in: database)
  }

  public func addTag(_ name: String, to identifier: String) async throws {
    try await CatalogAssets.addTag(name, to: identifier, in: database)
  }

  public func removeTag(_ name: String, from identifier: String) async throws {
    try await CatalogAssets.removeTag(name, from: identifier, in: database)
  }

  public func addToProject(_ slug: String, identifier: String) async throws {
    try await CatalogAssets.addToProject(slug, identifier: identifier, in: database)
  }

  /// `confirmed` is required to unlink from a project with live usage — the
  /// view layer asks the user first (the inspector's dialog), and the core
  /// re-checks inside the write transaction.
  public func removeFromProject(
    _ slug: String, identifier: String, confirmed: Bool = false
  ) async throws {
    try await CatalogAssets.removeFromProject(
      slug, identifier: identifier, in: database, confirmed: confirmed)
  }

  /// Archive (`.archived`) or Put Back (`.active`): a state change in the
  /// catalog; the remote object stays where it is.
  public func setState(_ state: AssetState, for identifiers: [String]) async throws {
    try await CatalogAssets.setState(state, for: identifiers, in: database)
  }

  public func setFavorite(_ favorite: Bool, for identifiers: [String]) async throws {
    try await CatalogAssets.setFavorite(favorite, for: identifiers, in: database)
  }

  public func setLabel(_ label: AssetLabel, _ applied: Bool, for identifiers: [String]) async throws {
    try await CatalogAssets.setLabel(label, applied, for: identifiers, in: database)
  }
}
