import Foundation

/// Finishes the work of an optimize run whose process stopped partway. Called
/// before every optimize command.
public enum OptimizeRecovery {
  /// A dry run changes nothing and records no planned replacement, so there is
  /// nothing to resume. Returns how many objects were resolved.
  @discardableResult
  public static func resumePending(in database: CatalogDatabasePool) async throws -> Int {
    0
  }
}
