import GRDB

public struct Backend: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "backend"

  public var id: Int64?
  public var slug: String
  public var kind: String
  public var endpoint: String
  public var bucket: String
  public var region: String
  public var urlPrefix: String
  public var keychainRef: String
  public var meta: String
  public var createdAt: String
  public var updatedAt: String

  enum CodingKeys: String, CodingKey {
    case id, slug, kind, endpoint, bucket, region, meta
    case urlPrefix = "url_prefix"
    case keychainRef = "keychain_ref"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  public init(
    id: Int64? = nil, slug: String, kind: String, endpoint: String, bucket: String,
    region: String = "auto", urlPrefix: String, keychainRef: String, meta: String = "{}",
    createdAt: String, updatedAt: String
  ) {
    self.id = id
    self.slug = slug
    self.kind = kind
    self.endpoint = endpoint
    self.bucket = bucket
    self.region = region
    self.urlPrefix = urlPrefix
    self.keychainRef = keychainRef
    self.meta = meta
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct BackendPrefixHistory: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "backend_prefix_history"

  public var id: Int64?
  public var backendID: Int64
  public var urlPrefix: String
  public var retiredAt: String

  enum CodingKeys: String, CodingKey {
    case id
    case backendID = "backend_id"
    case urlPrefix = "url_prefix"
    case retiredAt = "retired_at"
  }

  public init(id: Int64? = nil, backendID: Int64, urlPrefix: String, retiredAt: String) {
    self.id = id
    self.backendID = backendID
    self.urlPrefix = urlPrefix
    self.retiredAt = retiredAt
  }
}

public struct Asset: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "asset"

  public var id: Int64?
  public var sha256: String
  public var backendID: Int64
  public var key: String
  public var byteSize: Int64
  public var width: Int?
  public var height: Int?
  public var mime: String
  public var originalFilename: String?
  public var state: String
  public var pinned: Bool
  public var note: String?
  public var meta: String
  public var uploadedAt: String
  public var createdAt: String
  public var updatedAt: String
  /// The hash of the original file when the stored bytes are a recompressed
  /// copy of it; nil for an uploaded original. `sha256` is always the hash
  /// of the stored bytes. Backups made before the column existed decode as nil.
  public var sourceSHA256: String?

  enum CodingKeys: String, CodingKey {
    case id, sha256, key, width, height, mime, state, pinned, note, meta
    case backendID = "backend_id"
    case byteSize = "byte_size"
    case originalFilename = "orig_filename"
    case sourceSHA256 = "source_sha256"
    case uploadedAt = "uploaded_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  public init(
    id: Int64? = nil, sha256: String, backendID: Int64, key: String, byteSize: Int64,
    width: Int? = nil, height: Int? = nil, mime: String, originalFilename: String? = nil,
    state: String = "active", pinned: Bool = false, note: String? = nil, meta: String = "{}",
    uploadedAt: String, createdAt: String, updatedAt: String, sourceSHA256: String? = nil
  ) {
    self.id = id
    self.sha256 = sha256
    self.backendID = backendID
    self.key = key
    self.byteSize = byteSize
    self.width = width
    self.height = height
    self.mime = mime
    self.originalFilename = originalFilename
    self.state = state
    self.pinned = pinned
    self.note = note
    self.meta = meta
    self.uploadedAt = uploadedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.sourceSHA256 = sourceSHA256
  }
}

public struct Project: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "project"

  public var id: Int64?
  public var slug: String
  public var name: String
  public var keyPrefix: String
  /// `v4_project_key_template`: nil is the default template
  /// (`KeyTemplate.defaultTemplate`). Backups made before v4 lack the key
  /// and decode as nil.
  public var keyTemplate: String?
  public var backendID: Int64?
  public var lastScanID: Int64?
  public var note: String?
  public var meta: String
  public var createdAt: String
  public var updatedAt: String

  enum CodingKeys: String, CodingKey {
    case id, slug, name, note, meta
    case keyPrefix = "key_prefix"
    case keyTemplate = "key_template"
    case backendID = "backend_id"
    case lastScanID = "last_scan_id"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  public init(
    id: Int64? = nil, slug: String, name: String, keyPrefix: String = "",
    keyTemplate: String? = nil, backendID: Int64? = nil,
    lastScanID: Int64? = nil, note: String? = nil, meta: String = "{}", createdAt: String,
    updatedAt: String
  ) {
    self.id = id
    self.slug = slug
    self.name = name
    self.keyPrefix = keyPrefix
    self.keyTemplate = keyTemplate
    self.backendID = backendID
    self.lastScanID = lastScanID
    self.note = note
    self.meta = meta
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct AssetProject: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "asset_project"

  public var assetID: Int64
  public var projectID: Int64
  public var addedAt: String

  enum CodingKeys: String, CodingKey {
    case assetID = "asset_id"
    case projectID = "project_id"
    case addedAt = "added_at"
  }

  public init(assetID: Int64, projectID: Int64, addedAt: String) {
    self.assetID = assetID
    self.projectID = projectID
    self.addedAt = addedAt
  }
}

public struct Tag: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "tag"

  public var id: Int64?
  public var name: String

  public init(id: Int64? = nil, name: String) {
    self.id = id
    self.name = name
  }
}

public struct AssetTag: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "asset_tag"

  public var assetID: Int64
  public var tagID: Int64

  enum CodingKeys: String, CodingKey {
    case assetID = "asset_id"
    case tagID = "tag_id"
  }

  public init(assetID: Int64, tagID: Int64) {
    self.assetID = assetID
    self.tagID = tagID
  }
}

public struct Scan: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "scan"

  public var id: Int64?
  public var projectID: Int64
  public var startedAt: String
  public var finishedAt: String?
  public var sourceRevision: String?
  public var coverage: String
  public var foundCount: Int?

  enum CodingKeys: String, CodingKey {
    case id, coverage
    case projectID = "project_id"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case sourceRevision = "source_rev"
    case foundCount = "found_count"
  }

  public init(
    id: Int64? = nil, projectID: Int64, startedAt: String, finishedAt: String? = nil,
    sourceRevision: String? = nil, coverage: String = "[]", foundCount: Int? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.sourceRevision = sourceRevision
    self.coverage = coverage
    self.foundCount = foundCount
  }
}

public struct Usage: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  public static let databaseTableName = "usage"

  public var id: Int64?
  public var projectID: Int64
  public var assetID: Int64?
  public var rawURL: String
  public var sourceReference: String
  public var kind: String
  public var firstSeen: String
  public var lastSeen: String
  public var lastScanID: Int64?

  enum CodingKeys: String, CodingKey {
    case id, kind
    case projectID = "project_id"
    case assetID = "asset_id"
    case rawURL = "raw_url"
    case sourceReference = "source_ref"
    case firstSeen = "first_seen"
    case lastSeen = "last_seen"
    case lastScanID = "last_scan_id"
  }

  public init(
    id: Int64? = nil, projectID: Int64, assetID: Int64? = nil, rawURL: String,
    sourceReference: String, kind: String = "markdown", firstSeen: String, lastSeen: String,
    lastScanID: Int64? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.assetID = assetID
    self.rawURL = rawURL
    self.sourceReference = sourceReference
    self.kind = kind
    self.firstSeen = firstSeen
    self.lastSeen = lastSeen
    self.lastScanID = lastScanID
  }
}

public struct AssetLiveUsage: Codable, FetchableRecord, Sendable {
  public var assetID: Int64
  public var projectID: Int64
  public var count: Int

  enum CodingKeys: String, CodingKey {
    case assetID = "asset_id"
    case projectID = "project_id"
    case count = "n"
  }

  public init(assetID: Int64, projectID: Int64, count: Int) {
    self.assetID = assetID
    self.projectID = projectID
    self.count = count
  }
}
