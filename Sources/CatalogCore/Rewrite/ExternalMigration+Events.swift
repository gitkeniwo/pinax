import Foundation

// The events an `external_migrate` run adds. The file events
// (`file_planned`, `file_written`, `rescan_finished`, …) are the rewrite's.

/// What a migration was asked to do: the `run.params` JSON.
public struct ExternalMigrationParams: Codable, Equatable, Sendable {
  public var targets: [ExternalMigrationTarget]
  /// The backend's slug (a restored backup nulls `run.backend_id`).
  public var backend: String
  /// `project/label`; empty on a preparation.
  public var allowedSources: [String]

  public init(targets: [ExternalMigrationTarget], backend: String, allowedSources: [String] = []) {
    self.targets = targets
    self.backend = backend
    self.allowedSources = allowedSources
  }

  enum CodingKeys: String, CodingKey {
    case targets, backend
    case allowedSources = "allowed_sources"
  }
}

/// One project's raw URLs, as the references have them (query included).
public struct ExternalMigrationTarget: Codable, Equatable, Sendable {
  public var project: String
  public var urls: [String]

  public init(project: String, urls: [String]) {
    self.project = project
    self.urls = urls
  }
}

public struct MigrationStartedEvent: Codable, Equatable, Sendable {
  public struct Target: Codable, Equatable, Sendable {
    public var project: String
    public var urls: Int
    /// References to those URLs in the project's latest scan.
    public var links: Int
    public var hosts: Int

    public init(project: String, urls: Int, links: Int, hosts: Int) {
      self.project = project
      self.urls = urls
      self.links = links
      self.hosts = hosts
    }
  }

  public var targets: [Target]
  public var backend: String
  /// Distinct hosts across every project.
  public var hosts: Int

  public init(targets: [Target], backend: String, hosts: Int) {
    self.targets = targets
    self.backend = backend
    self.hosts = hosts
  }
}

public struct DownloadFinishedEvent: Codable, Equatable, Sendable {
  public var url: String
  public var host: String
  public var sha256: String
  public var bytes: Int64
  public var mime: String
  public var filename: String
  /// The response's Content-Type was not an image; the type was read from
  /// the bytes.
  public var sniffed: Bool
  public var cachePath: String

  public init(
    url: String, host: String, sha256: String, bytes: Int64, mime: String, filename: String,
    sniffed: Bool, cachePath: String
  ) {
    self.url = url
    self.host = host
    self.sha256 = sha256
    self.bytes = bytes
    self.mime = mime
    self.filename = filename
    self.sniffed = sniffed
    self.cachePath = cachePath
  }

  enum CodingKeys: String, CodingKey {
    case url, host, sha256, bytes, mime, filename, sniffed
    case cachePath = "cache_path"
  }
}

public struct DownloadFailedEvent: Codable, Equatable, Sendable {
  public enum Reason: String, Codable, Sendable {
    case httpStatus = "http_status"
    case timeout, dns
    case notImage = "not_image"
    case failed
  }

  public var url: String
  public var host: String
  public var reason: Reason
  /// The HTTP status on `http_status`.
  public var status: Int?
  /// The error as text, for the raw log.
  public var detail: String?

  public init(url: String, host: String, reason: Reason, status: Int? = nil, detail: String? = nil) {
    self.url = url
    self.host = host
    self.reason = reason
    self.status = status
    self.detail = detail
  }

  /// `404`, `timeout`, `not an image`, … — the short cause.
  public var cause: String {
    switch reason {
    case .httpStatus: return status.map(String.init) ?? "HTTP error"
    case .timeout: return "timeout"
    case .dns: return "host not found"
    case .notImage: return "not an image"
    case .failed: return "couldn’t download"
    }
  }
}

public struct MigrationPlannedEvent: Codable, Equatable, Sendable {
  public var url: String
  public var sha256: String
  public var key: String
  public var newURL: String
  public var reusedAssetID: Int64?
  /// The project whose key template rendered `key`, and that the new asset
  /// joins.
  public var project: String?
  public var filename: String?

  public init(
    url: String, sha256: String, key: String, newURL: String, reusedAssetID: Int64? = nil,
    project: String? = nil, filename: String? = nil
  ) {
    self.url = url
    self.sha256 = sha256
    self.key = key
    self.newURL = newURL
    self.reusedAssetID = reusedAssetID
    self.project = project
    self.filename = filename
  }

  enum CodingKeys: String, CodingKey {
    case url, sha256, key, project, filename
    case newURL = "new_url"
    case reusedAssetID = "reused_asset_id"
  }
}

public struct UploadFinishedEvent: Codable, Equatable, Sendable {
  public var url: String
  public var key: String
  public var newURL: String
  public var assetID: Int64
  public var bytes: Int64

  public init(url: String, key: String, newURL: String, assetID: Int64, bytes: Int64) {
    self.url = url
    self.key = key
    self.newURL = newURL
    self.assetID = assetID
    self.bytes = bytes
  }

  enum CodingKeys: String, CodingKey {
    case url, key, bytes
    case newURL = "new_url"
    case assetID = "asset_id"
  }
}

public struct AssetReusedEvent: Codable, Equatable, Sendable {
  public var url: String
  public var assetID: Int64
  public var newURL: String

  public init(url: String, assetID: Int64, newURL: String) {
    self.url = url
    self.assetID = assetID
    self.newURL = newURL
  }

  enum CodingKeys: String, CodingKey {
    case url
    case assetID = "asset_id"
    case newURL = "new_url"
  }
}

public struct UploadFailedEvent: Codable, Equatable, Sendable {
  public var url: String
  public var error: String
  /// A backend error that stopped the run.
  public var fatal: Bool
  /// The storage's HTTP status, when it answered with one.
  public var status: Int?

  public init(url: String, error: String, fatal: Bool, status: Int? = nil) {
    self.url = url
    self.error = error
    self.fatal = fatal
    self.status = status
  }
}

public struct VerifyFailedEvent: Codable, Equatable, Sendable {
  public var url: String
  public var newURL: String
  public var reason: String

  public init(url: String, newURL: String, reason: String) {
    self.url = url
    self.newURL = newURL
    self.reason = reason
  }

  enum CodingKeys: String, CodingKey {
    case url, reason
    case newURL = "new_url"
  }
}

public struct KeyChangedEvent: Codable, Equatable, Sendable {
  public var url: String
  public var plannedKey: String
  public var key: String

  public init(url: String, plannedKey: String, key: String) {
    self.url = url
    self.plannedKey = plannedKey
    self.key = key
  }

  enum CodingKeys: String, CodingKey {
    case url, key
    case plannedKey = "planned_key"
  }
}

public struct MigrationStoppedEvent: Codable, Equatable, Sendable {
  public var done: Int
  public var total: Int
  /// `download` while preparing, `upload` while applying; `check` when a
  /// rewrite or domain preview stops between two checks.
  public var phase: String?

  public init(done: Int, total: Int, phase: String? = nil) {
    self.done = done
    self.total = total
    self.phase = phase
  }
}

/// `run_finished`'s migration part (`RewriteRunSummary.migration`).
/// Counts are images (distinct URLs) and links (references); the confirm
/// sheet reads this and the events, and computes nothing again.
public struct ExternalMigrationSummary: Codable, Equatable, Sendable {
  public struct Host: Codable, Equatable, Sendable {
    public var host: String
    public var links: Int
    public var urls: Int
    public var tips: [String]

    public init(host: String, links: Int, urls: Int, tips: [String]) {
      self.host = host
      self.links = links
      self.urls = urls
      self.tips = tips
    }
  }

  public struct Count: Codable, Equatable, Sendable {
    public var images: Int
    public var links: Int

    public init(images: Int = 0, links: Int = 0) {
      self.images = images
      self.links = links
    }
  }

  public struct Files: Codable, Equatable, Sendable {
    public var project: String
    public var source: String
    public var files: Int
    public var edits: Int

    public init(project: String, source: String, files: Int, edits: Int) {
      self.project = project
      self.source = source
      self.files = files
      self.edits = edits
    }
  }

  /// Most links first.
  public var hosts: [Host] = []
  /// Preparation: downloaded and new to the backend.
  public var migratable = Count()
  /// Already in the catalog with the same sha256.
  public var reused = Count()
  /// Broken links and non-images.
  public var skipped = Count()
  /// Bytes to upload (migratable images).
  public var bytes: Int64 = 0
  /// Files the rewrite will change, by project and source.
  public var files: [Files] = []
  /// Up to three planned keys.
  public var sampleKeys: [String] = []
  /// Apply only.
  public var uploaded: Count?
  public var failed: Count?
  public var newAssetIDs: [Int64]?
  /// Images done when the run stopped.
  public var stoppedAfter: Int?

  public init() {}

  enum CodingKeys: String, CodingKey {
    case hosts, migratable, reused, skipped, bytes, files, uploaded, failed
    case sampleKeys = "sample_keys"
    case newAssetIDs = "new_asset_ids"
    case stoppedAfter = "stopped_after"
  }
}
