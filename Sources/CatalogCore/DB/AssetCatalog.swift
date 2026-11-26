import Foundation
import GRDB

public enum AssetCatalogError: Error, Equatable, CustomStringConvertible {
  case invalidSHA256Prefix(String)
  case assetNotFound(String)
  case ambiguousIdentifier(String, candidates: [String])
  case invalidTag(String)
  case projectNotFound(String)
  case unlinkBlockedByLiveUsage(project: String, liveCount: Int)
  /// A batch's identifiers that named no single asset, one error each.
  case unresolvedIdentifiers([AssetCatalogError])
  /// The assets a batch would unlink from a project that still references them.
  case unlinkBlockedForAssets(project: String, assets: [LiveUsedAsset])

  public var description: String {
    switch self {
    case let .invalidSHA256Prefix(prefix):
      return "SHA-256 prefix '\(prefix)' must contain at least 6 hexadecimal characters."
    case let .assetNotFound(identifier):
      return "No asset matches '\(identifier)'."
    case let .ambiguousIdentifier(identifier, candidates):
      return "Asset identifier '\(identifier)' is ambiguous: \(candidates.joined(separator: ", "))"
    case let .invalidTag(tag):
      return "Tag '\(tag)' must not be empty."
    case let .projectNotFound(slug):
      return "Project '\(slug)' does not exist."
    case let .unlinkBlockedByLiveUsage(project, liveCount):
      return
        "Project '\(project)' still references this asset (\(liveCount) live references). "
        + "Unlinking it requires explicit confirmation."
    case let .unresolvedIdentifiers(errors):
      return errors.map(\.description).joined(separator: "\n")
    case let .unlinkBlockedForAssets(project, assets):
      let lines = assets.map {
        "  \($0.sha256.prefix(12))  \($0.key)  \($0.liveCount) live references"
      }
      return
        "Project '\(project)' still references these assets. "
        + "Unlinking them requires explicit confirmation.\n" + lines.joined(separator: "\n")
    }
  }
}

extension AssetCatalogError {
  /// A one-asset batch's error as the error about that asset.
  fileprivate var forOneAsset: AssetCatalogError {
    switch self {
    case let .unresolvedIdentifiers(errors):
      return errors.first ?? self
    case let .unlinkBlockedForAssets(project, assets):
      return assets.first.map {
        .unlinkBlockedByLiveUsage(project: project, liveCount: $0.liveCount)
      } ?? self
    default:
      return self
    }
  }
}

/// An asset a project's latest scan still references.
public struct LiveUsedAsset: Equatable, Sendable {
  public let sha256: String
  public let key: String
  public let liveCount: Int

  public init(sha256: String, key: String, liveCount: Int) {
    self.sha256 = sha256
    self.key = key
    self.liveCount = liveCount
  }
}

public struct CatalogAssetItem: Codable, Sendable {
  public let asset: Asset
  public let backend: Backend
  public let url: String

  public init(asset: Asset, backend: Backend) {
    self.asset = asset
    self.backend = backend
    self.url = URLResolver.url(for: asset, backend: backend)
  }
}

public struct ProjectUsageCount: Codable, Equatable, Sendable {
  public let slug: String
  public let name: String
  public let liveUsageCount: Int

  public init(slug: String, name: String, liveUsageCount: Int) {
    self.slug = slug
    self.name = name
    self.liveUsageCount = liveUsageCount
  }
}

public struct CatalogAssetDetails: Codable, Sendable {
  public let item: CatalogAssetItem
  public let tags: [String]
  public let projects: [ProjectUsageCount]
  public let favorite: Bool
  /// In Finder's order.
  public let labels: [AssetLabel]

  public init(
    item: CatalogAssetItem, tags: [String], projects: [ProjectUsageCount],
    favorite: Bool = false, labels: [AssetLabel] = []
  ) {
    self.item = item
    self.tags = tags
    self.projects = projects
    self.favorite = favorite
    self.labels = labels
  }
}

public enum CatalogAssets {
  public static func resolve(_ identifier: String, in database: DatabasePool) throws
    -> CatalogAssetItem
  {
    try database.read { db in
      try resolve(identifier, in: db)
    }
  }

  public static func resolve(_ identifier: String, in database: DatabasePool) async throws
    -> CatalogAssetItem
  {
    try await database.read { db in
      try resolve(identifier, in: db)
    }
  }

  /// The assets the identifiers name, in order, each once. When one of
  /// several does not resolve, the error lists every one that did not; for
  /// a single identifier it is the error `resolve` throws.
  public static func resolveAll(_ identifiers: [String], in database: DatabasePool) throws
    -> [CatalogAssetItem]
  {
    do {
      return try database.read { db in
        try catalogItems(for: resolveAll(identifiers, db: db), in: db)
      }
    } catch let error as AssetCatalogError where identifiers.count == 1 {
      throw error.forOneAsset
    }
  }

  /// The slugs of the projects each asset is a member of; an asset in none
  /// has no entry.
  public static func projectMemberships(assetIDs: [Int64], in database: DatabasePool) throws
    -> [Int64: Set<String>]
  {
    try database.read { db in
      try projectMemberships(assetIDs: assetIDs, in: db)
    }
  }

  public static func projectMemberships(assetIDs: [Int64], in database: DatabasePool)
    async throws -> [Int64: Set<String>]
  {
    try await database.read { db in
      try projectMemberships(assetIDs: assetIDs, in: db)
    }
  }

  /// The same for the one asset a backend stores under `sha256`; empty when
  /// there is none.
  public static func projectSlugs(
    sha256: String, backendID: Int64?, in database: DatabasePool
  ) throws -> Set<String> {
    try database.read { db in
      guard
        let id = try Asset
          .filter(Column("backend_id") == backendID && Column("sha256") == sha256)
          .fetchOne(db)?.id
      else { return [] }
      return try projectMemberships(assetIDs: [id], in: db)[id] ?? []
    }
  }

  private static func projectMemberships(assetIDs: [Int64], in db: GRDB.Database) throws
    -> [Int64: Set<String>]
  {
    guard !assetIDs.isEmpty else { return [:] }
    let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT ap.asset_id, p.slug
        FROM asset_project ap
        JOIN project p ON p.id = ap.project_id
        WHERE ap.asset_id IN (\(placeholders))
        """,
      arguments: StatementArguments(assetIDs)
    )
    var result: [Int64: Set<String>] = [:]
    for row in rows {
      let assetID: Int64 = row["asset_id"]
      let slug: String = row["slug"]
      result[assetID, default: []].insert(slug)
    }
    return result
  }

  static func resolve(_ identifier: String, in db: GRDB.Database) throws -> CatalogAssetItem {
    guard let asset = try resolveInWrite(identifier, db: db),
      let backend = try Backend.fetchOne(db, key: asset.backendID)
    else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    return CatalogAssetItem(asset: asset, backend: backend)
  }

  public static func details(_ identifier: String, in database: DatabasePool) throws
    -> CatalogAssetDetails
  {
    try database.read { db in
      let item = try resolve(identifier, in: db)
      return try assetDetails(item, in: db)
    }
  }

  public static func details(_ identifier: String, in database: DatabasePool) async throws
    -> CatalogAssetDetails
  {
    try await database.read { db in
      let item = try resolve(identifier, in: db)
      return try assetDetails(item, in: db)
    }
  }

  static func assetDetails(_ item: CatalogAssetItem, in db: GRDB.Database) throws
    -> CatalogAssetDetails
  {
    guard let assetID = item.asset.id else {
      throw AssetCatalogError.assetNotFound(item.asset.key)
    }
    let tags = try String.fetchAll(
        db,
        sql: """
          SELECT t.name
          FROM tag t
          JOIN asset_tag at ON at.tag_id = t.id
          WHERE at.asset_id = ?
          ORDER BY t.name
          """,
        arguments: [assetID]
      )
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT DISTINCT p.slug, p.name, COALESCE(l.n, 0) AS live_usage_count
          FROM project p
          LEFT JOIN asset_project ap ON ap.project_id = p.id AND ap.asset_id = ?
          LEFT JOIN asset_live_usage l ON l.project_id = p.id AND l.asset_id = ?
          WHERE ap.asset_id IS NOT NULL OR l.asset_id IS NOT NULL
          ORDER BY p.slug
          """,
        arguments: [assetID, assetID]
      )
      let projects = rows.map { row in
        ProjectUsageCount(
          slug: row["slug"],
          name: row["name"],
          liveUsageCount: row["live_usage_count"]
        )
      }
      return CatalogAssetDetails(
        item: item, tags: tags, projects: projects,
        favorite: try favoriteIDs(among: [item.asset], in: db).contains(assetID),
        labels: try labelsByAssetID(for: [item.asset], in: db)[assetID] ?? [])
  }

  public static func addTag(
    _ name: String,
    to identifier: String,
    in database: DatabasePool
  ) throws {
    try database.write { db in
      try addTagInTransaction(name, identifier: identifier, db: db)
    }
  }

  public static func addTag(
    _ name: String,
    to identifier: String,
    in database: DatabasePool
  ) async throws {
    try await database.write { db in
      try addTagInTransaction(name, identifier: identifier, db: db)
    }
  }

  public static func removeTag(
    _ name: String,
    from identifier: String,
    in database: DatabasePool
  ) throws {
    try database.write { db in
      try removeTagInTransaction(name, identifier: identifier, db: db)
    }
  }

  public static func removeTag(
    _ name: String,
    from identifier: String,
    in database: DatabasePool
  ) async throws {
    try await database.write { db in
      try removeTagInTransaction(name, identifier: identifier, db: db)
    }
  }

  /// Sets or clears an asset's note. `nil` clears it. Touches `updated_at`.
  /// Resolution and update happen inside one write transaction so concurrent
  /// writers cannot be reverted by a whole-row rewrite.
  public static func setNote(
    _ note: String?,
    for identifier: String,
    in database: DatabasePool,
    now: Date = Date()
  ) throws {
    try database.write { db in
      try setNoteInTransaction(note, for: identifier, now: now, db: db)
    }
  }

  public static func setNote(
    _ note: String?,
    for identifier: String,
    in database: DatabasePool,
    now: Date = Date()
  ) async throws {
    try await database.write { db in
      // The synchronous body re-resolves inside the writer; reuse it directly.
      try setNoteInTransaction(note, for: identifier, now: now, db: db)
    }
  }

  /// Adds the asset to a project. Re-adding is a no-op.
  public static func addToProject(
    _ slug: String,
    identifier: String,
    in database: DatabasePool,
    now: Date = Date()
  ) throws {
    try forOneAsset {
      _ = try addToProject(slug, identifiers: [identifier], in: database, now: now)
    }
  }

  public static func addToProject(
    _ slug: String,
    identifier: String,
    in database: DatabasePool,
    now: Date = Date()
  ) async throws {
    try await forOneAsset {
      _ = try await addToProject(slug, identifiers: [identifier], in: database, now: now)
    }
  }

  @discardableResult
  public static func addToProject(
    _ slug: String,
    identifiers: [String],
    in database: DatabasePool,
    dryRun: Bool = false,
    now: Date = Date()
  ) throws -> [CurationChange] {
    let date = timestamp(now)
    return try curate(identifiers, in: database, dryRun: dryRun) { db, assets in
      try link(assets, to: slug, date: date, in: db)
    }
  }

  @discardableResult
  public static func addToProject(
    _ slug: String,
    identifiers: [String],
    in database: DatabasePool,
    dryRun: Bool = false,
    now: Date = Date()
  ) async throws -> [CurationChange] {
    let date = timestamp(now)
    return try await curate(identifiers, in: database, dryRun: dryRun) { db, assets in
      try link(assets, to: slug, date: date, in: db)
    }
  }

  /// Removes the asset from a project. Removing a non-membership is a no-op.
  ///
  /// Live usage is a lower bound that never authorizes destructive action, so
  /// an unlink from a project that still references the asset is refused
  /// unless the caller passes `confirmed: true` — the caller's job is to have
  /// asked the user, not to assume. The check runs inside the write
  /// transaction, so it cannot be outrun by a concurrent scan.
  public static func removeFromProject(
    _ slug: String,
    identifier: String,
    in database: DatabasePool,
    confirmed: Bool = false
  ) throws {
    try forOneAsset {
      _ = try removeFromProject(
        slug, identifiers: [identifier], in: database, confirmed: confirmed)
    }
  }

  public static func removeFromProject(
    _ slug: String,
    identifier: String,
    in database: DatabasePool,
    confirmed: Bool = false
  ) async throws {
    try await forOneAsset {
      _ = try await removeFromProject(
        slug, identifiers: [identifier], in: database, confirmed: confirmed)
    }
  }

  /// One referenced asset refuses the whole batch, and the error names each.
  @discardableResult
  public static func removeFromProject(
    _ slug: String,
    identifiers: [String],
    in database: DatabasePool,
    confirmed: Bool = false,
    dryRun: Bool = false
  ) throws -> [CurationChange] {
    try curate(identifiers, in: database, dryRun: dryRun) { db, assets in
      try unlink(assets, from: slug, projectID: projectID(slug, in: db), confirmed: confirmed, in: db)
    }
  }

  @discardableResult
  public static func removeFromProject(
    _ slug: String,
    identifiers: [String],
    in database: DatabasePool,
    confirmed: Bool = false,
    dryRun: Bool = false
  ) async throws -> [CurationChange] {
    try await curate(identifiers, in: database, dryRun: dryRun) { db, assets in
      try unlink(assets, from: slug, projectID: projectID(slug, in: db), confirmed: confirmed, in: db)
    }
  }

  /// Moves an asset between projects atomically: either both halves land or
  /// neither does. Every decision — asset resolution, both project lookups,
  /// and the live-usage guard on the outgoing side — happens inside the one
  /// transaction, so a bad target slug or a refused unlink leaves the old
  /// membership untouched instead of destroying it.
  public static func moveAsset(
    _ identifier: String,
    fromProject fromSlug: String?,
    toProject toSlug: String?,
    in database: DatabasePool,
    confirmed: Bool = false,
    now: Date = Date()
  ) async throws {
    try await forOneAsset {
      _ = try await moveAssets(
        [identifier], fromProject: fromSlug, toProject: toSlug, in: database,
        confirmed: confirmed, now: now)
    }
  }

  /// `moveAsset` for any number of assets, all or none.
  @discardableResult
  public static func moveAssets(
    _ identifiers: [String],
    fromProject fromSlug: String?,
    toProject toSlug: String?,
    in database: DatabasePool,
    confirmed: Bool = false,
    dryRun: Bool = false,
    now: Date = Date()
  ) async throws -> [CurationChange] {
    let date = timestamp(now)
    return try await curate(identifiers, in: database, dryRun: dryRun) { db, assets in
      // Both projects are looked up before either half is written.
      let from = try fromSlug.map { (slug: $0, id: try projectID($0, in: db)) }
      let to = try toSlug.map { (slug: $0, id: try projectID($0, in: db)) }
      if let from {
        try unlink(assets, from: from.slug, projectID: from.id, confirmed: confirmed, in: db)
      }
      if let to {
        try link(assets, to: to.slug, date: date, in: db)
      }
    }
  }

  /// The one-asset forms report a failure as the error about that asset, not
  /// as a batch of one.
  private static func forOneAsset(_ body: () throws -> Void) throws {
    do { try body() } catch let error as AssetCatalogError { throw error.forOneAsset }
  }

  private static func forOneAsset(_ body: () async throws -> Void) async throws {
    do { try await body() } catch let error as AssetCatalogError { throw error.forOneAsset }
  }

  private static func projectID(_ slug: String, in db: GRDB.Database) throws -> Int64 {
    guard let id = try Project.filter(Column("slug") == slug).fetchOne(db)?.id else {
      throw AssetCatalogError.projectNotFound(slug)
    }
    return id
  }

  private static func link(
    _ assets: [Asset], to slug: String, date: String, in db: GRDB.Database
  ) throws {
    let projectID = try projectID(slug, in: db)
    for asset in assets {
      try db.execute(
        sql: "INSERT OR IGNORE INTO asset_project (asset_id, project_id, added_at) VALUES (?, ?, ?)",
        arguments: [asset.id, projectID, date]
      )
    }
  }

  private static func unlink(
    _ assets: [Asset], from slug: String, projectID: Int64, confirmed: Bool,
    in db: GRDB.Database
  ) throws {
    if !confirmed {
      try requireNoLiveUsage(assets, projectID: projectID, slug: slug, in: db)
    }
    for asset in assets {
      try db.execute(
        sql: "DELETE FROM asset_project WHERE asset_id = ? AND project_id = ?",
        arguments: [asset.id, projectID]
      )
    }
  }

  private static func requireNoLiveUsage(
    _ assets: [Asset], projectID: Int64, slug: String, in db: GRDB.Database
  ) throws {
    let blocked = try assets.compactMap { asset -> LiveUsedAsset? in
      let live = try Int.fetchOne(
        db,
        sql: "SELECT n FROM asset_live_usage WHERE asset_id = ? AND project_id = ?",
        arguments: [asset.id, projectID]
      ) ?? 0
      return live > 0 ? LiveUsedAsset(sha256: asset.sha256, key: asset.key, liveCount: live) : nil
    }
    if !blocked.isEmpty {
      throw AssetCatalogError.unlinkBlockedForAssets(project: slug, assets: blocked)
    }
  }

  static func timestamp(_ date: Date) -> String {
    Self.iso8601.string(from: date)
  }

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    return formatter
  }()

  private static func addTagInTransaction(
    _ name: String,
    identifier: String,
    db: GRDB.Database
  ) throws {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw AssetCatalogError.invalidTag(name) }
    guard let asset = try resolveInWrite(identifier, db: db), let assetID = asset.id else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    try db.execute(
      sql: "INSERT INTO tag (name) VALUES (?) ON CONFLICT(name) DO NOTHING",
      arguments: [normalized]
    )
    try db.execute(
      sql: """
        INSERT INTO asset_tag (asset_id, tag_id)
        SELECT ?, id FROM tag WHERE name = ?
        ON CONFLICT(asset_id, tag_id) DO NOTHING
        """,
      arguments: [assetID, normalized]
    )
  }

  private static func removeTagInTransaction(
    _ name: String,
    identifier: String,
    db: GRDB.Database
  ) throws {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw AssetCatalogError.invalidTag(name) }
    guard let asset = try resolveInWrite(identifier, db: db), let assetID = asset.id else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    try db.execute(
      sql: """
        DELETE FROM asset_tag
        WHERE asset_id = ? AND tag_id = (SELECT id FROM tag WHERE name = ?)
        """,
      arguments: [assetID, normalized]
    )
    try db.execute(
      sql:
        "DELETE FROM tag WHERE name = ? AND NOT EXISTS (SELECT 1 FROM asset_tag WHERE tag_id = tag.id)",
      arguments: [normalized]
    )
  }

  /// An exact key, else an unambiguous sha256 prefix. A key is unique per
  /// backend only: when two backends hold it, the identifier is ambiguous —
  /// never whichever row SQLite returns first.
  static func resolveInWrite(_ identifier: String, db: GRDB.Database) throws -> Asset? {
    let exact = try Asset.filter(Column("key") == identifier).order(Column("id")).fetchAll(db)
    if exact.count > 1 {
      let slugs = try Dictionary(
        uniqueKeysWithValues: Backend.fetchAll(db).map { ($0.id ?? -1, $0.slug) })
      let candidates = exact.map {
        "\($0.sha256.prefix(12)) \($0.key) (\(slugs[$0.backendID] ?? "?"))"
      }
      throw AssetCatalogError.ambiguousIdentifier(identifier, candidates: candidates)
    }
    if let exact = exact.first {
      return exact
    }
    guard identifier.count >= 6,
      identifier.unicodeScalars.allSatisfy({ scalar in
        (48...57).contains(scalar.value) || (65...70).contains(scalar.value)
          || (97...102).contains(scalar.value)
      })
    else {
      throw AssetCatalogError.invalidSHA256Prefix(identifier)
    }
    let matches = try Asset
      .filter(Column("sha256").like("\(identifier.lowercased())%"))
      .order(Column("sha256"), Column("key"))
      .fetchAll(db)
    guard !matches.isEmpty else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    guard matches.count == 1 else {
      let candidates = matches.map { "\($0.sha256.prefix(12)) \($0.key)" }
      throw AssetCatalogError.ambiguousIdentifier(identifier, candidates: candidates)
    }
    return matches[0]
  }

  private static func setNoteInTransaction(
    _ note: String?,
    for identifier: String,
    now: Date,
    db: GRDB.Database
  ) throws {
    let normalized = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleared = (normalized?.isEmpty ?? true) ? nil : normalized
    guard var asset = try resolveInWrite(identifier, db: db) else {
      throw AssetCatalogError.assetNotFound(identifier)
    }
    asset.note = cleared
    asset.updatedAt = Self.timestamp(now)
    try asset.update(db)
  }
}
