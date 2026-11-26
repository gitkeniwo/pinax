import Foundation
import GRDB

public enum DeletionRemoteError: Error, Equatable, CustomStringConvertible {
  case missingCredentials(String)

  public var description: String {
    switch self {
    case let .missingCredentials(slug):
      return "No credentials for backend '\(slug)' in Keychain."
    }
  }
}

/// What the app and the CLI share around `CatalogDeletion`.
extension CatalogDeletion {
  /// The real remote: the backend's Keychain credentials, one
  /// `S3ObjectDeleter` per backend.
  public static func keychainRemote(_ backend: Backend) throws -> any ObjectDeleting {
    guard let credentials = try Keychain().load(for: backend.keychainRef) else {
      throw DeletionRemoteError.missingCredentials(backend.slug)
    }
    return S3ObjectDeleter(backend: backend, credentials: credentials)
  }

  /// A row's `meta.imported_from` (PicGo, a claimed external), or nil.
  /// When present, Pinax cannot prove it wrote those bytes, so a deletion
  /// leaves the object and removes only the row.
  public static func importedFrom(meta: String?) -> String? {
    let object = meta.flatMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    return object?["imported_from"] as? String
  }

  /// A confirmed batch in the order both callers run it: stages the
  /// deletable assets, then removes the rest from the catalog only. Returns
  /// the ids of the tombstones owed a delete, for `purge`.
  public static func stage(
    deleting: [String], keeping: [String], in database: DatabasePool, includeUsed: Bool,
    now: Date = Date()
  ) throws -> [Int64] {
    var staged: [DeletionCandidate] = []
    if !deleting.isEmpty {
      staged = try stage(deleting, in: database, includeUsed: includeUsed, now: now)
    }
    if !keeping.isEmpty {
      try removeFromCatalogOnly(keeping, in: database, includeUsed: includeUsed, now: now)
    }
    let wanted = Set(staged.map { "\($0.backendSlug)\u{0}\($0.key)" })
    return try pending(in: database)
      .filter { !$0.keepRemote && wanted.contains("\($0.backendSlug)\u{0}\($0.key)") }
      .map(\.id)
  }
}
