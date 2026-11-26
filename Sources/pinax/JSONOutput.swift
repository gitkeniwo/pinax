import ArgumentParser
import CatalogCore
import Foundation

// The `--format json` documents of the read commands, and what they share.
// Each document carries a `schema` string, `pinax.<name>.v1`; keys are
// snake_case; a missing value is `null`, never an absent key. Standard output
// holds the document only.

enum OutputFormat: String, ExpressibleByArgument {
  case table
  case json
}

func encodedJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// An optional that encodes as `null` when empty; synthesized `Encodable`
/// would leave the key out.
@propertyWrapper
struct ExplicitNull<Value: Encodable>: Encodable {
  var wrappedValue: Value?

  init(wrappedValue: Value?) {
    self.wrappedValue = wrappedValue
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    if let wrappedValue {
      try container.encode(wrappedValue)
    } else {
      try container.encodeNil()
    }
  }
}

// MARK: - pinax show

struct AssetDocument: Encodable {
  let schema = "pinax.asset.v1"
  let asset: AssetRecordJSON

  init(_ details: CatalogAssetDetails) {
    asset = AssetRecordJSON(details)
  }
}

/// The fields `show` prints as a table, apart from the source line.
struct AssetRecordJSON: Encodable {
  @ExplicitNull var id: Int64?
  let sha256: String
  let backend: String
  let key: String
  let url: String
  let bytes: Int64
  @ExplicitNull var width: Int?
  @ExplicitNull var height: Int?
  let mime: String
  @ExplicitNull var originalFilename: String?
  let state: String
  let pinned: Bool
  @ExplicitNull var note: String?
  /// The stored string, not parsed.
  let meta: String
  let uploadedAt: String
  let createdAt: String
  let updatedAt: String
  let tags: [String]
  let projects: [ProjectUsageJSON]

  init(_ details: CatalogAssetDetails) {
    let asset = details.item.asset
    id = asset.id
    sha256 = asset.sha256
    backend = details.item.backend.slug
    key = asset.key
    url = details.item.url
    bytes = asset.byteSize
    width = asset.width
    height = asset.height
    mime = asset.mime
    originalFilename = asset.originalFilename
    state = asset.state
    pinned = asset.pinned
    note = asset.note
    meta = asset.meta
    uploadedAt = asset.uploadedAt
    createdAt = asset.createdAt
    updatedAt = asset.updatedAt
    tags = details.tags
    projects = details.projects.map {
      ProjectUsageJSON(slug: $0.slug, name: $0.name, liveUsage: $0.liveUsageCount)
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, sha256, backend, key, url, bytes, width, height, mime, state, pinned, note, meta
    case tags, projects
    case originalFilename = "original_filename"
    case uploadedAt = "uploaded_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

struct ProjectUsageJSON: Encodable {
  let slug: String
  let name: String
  let liveUsage: Int

  enum CodingKeys: String, CodingKey {
    case slug, name
    case liveUsage = "live_usage"
  }
}

// MARK: - pinax object head

struct ObjectDocument: Encodable {
  let schema = "pinax.object.v1"
  let backend: String
  let key: String
  let bytes: Int64
  @ExplicitNull var contentType: String?
  /// As sent, quotes included.
  @ExplicitNull var etag: String?
  @ExplicitNull var cacheControl: String?
  @ExplicitNull var lastModified: String?
  let metadata: [String: String]

  init(_ head: S3ObjectHead, backend: String) {
    self.backend = backend
    key = head.key
    bytes = head.byteSize
    contentType = head.mime
    etag = head.etag
    cacheControl = head.cacheControl
    lastModified = head.lastModified
    metadata = head.metadata
  }

  enum CodingKeys: String, CodingKey {
    case schema, backend, key, bytes, etag, metadata
    case contentType = "content_type"
    case cacheControl = "cache_control"
    case lastModified = "last_modified"
  }
}

// MARK: - pinax note show

struct NoteDocument: Encodable {
  let schema = "pinax.note.v1"
  let sha256: String
  let key: String
  @ExplicitNull var note: String?

  init(_ asset: Asset) {
    sha256 = asset.sha256
    key = asset.key
    note = asset.note
  }
}

// MARK: - pinax project ls

struct ProjectListDocument: Encodable {
  let schema = "pinax.projects.v1"
  let projects: [ProjectJSON]
}

struct ProjectJSON: Encodable {
  let slug: String
  let name: String
  let keyPrefix: String
  /// Null for the default template.
  @ExplicitNull var keyTemplate: String?
  /// The backend's slug.
  @ExplicitNull var backend: String?

  enum CodingKeys: String, CodingKey {
    case slug, name, backend
    case keyPrefix = "key_prefix"
    case keyTemplate = "key_template"
  }
}

// MARK: - pinax backend ls, show

/// A backend without its keychain reference; nothing about credentials is
/// ever output.
struct BackendJSON: Encodable {
  let slug: String
  let kind: String
  let endpoint: String
  let bucket: String
  let region: String
  let urlPrefix: String

  init(_ backend: Backend) {
    slug = backend.slug
    kind = backend.kind
    endpoint = backend.endpoint
    bucket = backend.bucket
    region = backend.region
    urlPrefix = backend.urlPrefix
  }

  enum CodingKeys: String, CodingKey {
    case slug, kind, endpoint, bucket, region
    case urlPrefix = "url_prefix"
  }
}

struct BackendListDocument: Encodable {
  let schema = "pinax.backends.v1"
  let backends: [BackendJSON]
}

struct BackendDocument: Encodable {
  let schema = "pinax.backend.v1"
  let backend: BackendJSON
  let urlPrefixLinks: Int

  enum CodingKeys: String, CodingKey {
    case schema, backend
    case urlPrefixLinks = "url_prefix_links"
  }
}

// MARK: - pinax orphans

/// The candidates, the assets left out because their every project is not
/// tracked, and the under-scanned projects, each in its own list.
struct OrphanDocument: Encodable {
  let schema = "pinax.orphans.v1"
  @ExplicitNull var project: String?
  let minimumScans: Int
  let assets: [OrphanAssetJSON]
  let untracked: [OrphanAssetJSON]
  let untrackedProjects: [String]
  let unscannedProjects: [String]

  init(_ report: OrphanReport, project: String?, minimumScans: Int) {
    func entry(_ item: CatalogAssetItem) -> OrphanAssetJSON {
      OrphanAssetJSON(item, projects: item.asset.id.flatMap { report.projectSlugs[$0] } ?? [])
    }
    self.project = project
    self.minimumScans = minimumScans
    assets = report.assets.map(entry)
    untracked = report.untracked.map(entry)
    untrackedProjects = report.untrackedProjects
    unscannedProjects = report.unscannedProjects
  }

  enum CodingKeys: String, CodingKey {
    case schema, project, assets, untracked
    case minimumScans = "minimum_scans"
    case untrackedProjects = "untracked_projects"
    case unscannedProjects = "unscanned_projects"
  }
}

/// The keys of an asset in `ls` and `upload` JSON, and its projects.
struct OrphanAssetJSON: Encodable {
  let sha256: String
  let key: String
  let url: String
  @ExplicitNull var width: Int?
  @ExplicitNull var height: Int?
  let bytes: Int64
  let mime: String
  let filename: String
  let uploadedAt: String
  let projects: [String]

  init(_ item: CatalogAssetItem, projects: [String]) {
    let asset = PublicAsset(asset: item.asset, backend: item.backend)
    sha256 = asset.sha256
    key = asset.key
    url = asset.url
    width = asset.width
    height = asset.height
    bytes = asset.bytes
    mime = asset.mime
    filename = asset.filename
    uploadedAt = asset.uploadedAt
    self.projects = projects
  }

  enum CodingKeys: String, CodingKey {
    case sha256, key, url, width, height, bytes, mime, filename, projects
    case uploadedAt = "uploaded_at"
  }
}

// MARK: - pinax externals

/// In the table's order.
struct ExternalListDocument: Encodable {
  let schema = "pinax.externals.v1"
  @ExplicitNull var project: String?
  let items: [ExternalJSON]
}

struct ExternalJSON: Encodable {
  let project: String
  let kind: String
  let sourceReference: String
  let rawURL: String
  /// `yours` or `other`.
  let domain: String
  /// The prefix that makes it `yours`.
  @ExplicitNull var match: ExternalMatchJSON?

  init(_ reference: ExternalReference) {
    project = reference.projectSlug
    kind = reference.kind
    sourceReference = reference.sourceReference
    rawURL = reference.rawURL
    domain = reference.domain.rawValue
    match = reference.match.map {
      ExternalMatchJSON(backend: $0.backendSlug, prefix: $0.prefix, current: $0.isCurrent)
    }
  }

  enum CodingKeys: String, CodingKey {
    case project, kind, domain, match
    case sourceReference = "source_ref"
    case rawURL = "raw_url"
  }
}

struct ExternalMatchJSON: Encodable {
  let backend: String
  let prefix: String
  /// False when the prefix is one of the backend's old domains.
  let current: Bool
}

// MARK: - pinax restore

/// The rows restored per table and the two follow-ups.
struct RestoreDocument: Encodable {
  let schema = "pinax.restore.v1"
  let tables: [String: Int]
  let favorites: Int
  let backendsWithoutCredentials: [String]
  let projectsWithMissingSources: [MissingSourcesJSON]

  init(counts: CatalogTableCounts, followUps: CatalogRestoreFollowUps) {
    tables = Dictionary(uniqueKeysWithValues: counts.tables.map { ($0.name, $0.count) })
    favorites = counts.favorites
    backendsWithoutCredentials = followUps.backendsWithoutCredentials
    projectsWithMissingSources = followUps.projectsWithMissingSources.map {
      MissingSourcesJSON(project: $0.projectSlug, name: $0.projectName, paths: $0.paths)
    }
  }

  enum CodingKeys: String, CodingKey {
    case schema, tables, favorites
    case backendsWithoutCredentials = "backends_without_credentials"
    case projectsWithMissingSources = "projects_with_missing_sources"
  }
}

struct MissingSourcesJSON: Encodable {
  let project: String
  let name: String
  let paths: [String]
}
