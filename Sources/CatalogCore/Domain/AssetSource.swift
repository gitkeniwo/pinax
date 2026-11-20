import Foundation

/// Where an asset came from, read from `asset.meta`.
/// Only two keys decide it:
/// - `imported_from` non-empty: an import — `picgo`, `externals`/`bucket`,
///   anything else `otherImport`;
/// - `imported_from` empty and `source_url` non-empty: `migrated`
///   (an Other Domains image copied into the bucket);
/// - neither, no meta, or meta that is not a JSON object: `pinax`.
public enum AssetSource: String, Sendable, Hashable, CaseIterable, Codable {
  case pinax
  case picgo
  case bucket
  case otherImport = "other_import"
  case migrated

  /// The one classifier: the GUI, the CLI and `AssetQuery.sources` (through
  /// the `pinax_asset_source` SQL function) all call this.
  public static func of(meta: String?) -> AssetSource {
    let provenance = AssetProvenance(meta: meta)
    switch provenance.importedFrom {
    case "picgo": return .picgo
    case "externals", "bucket": return .bucket
    case .some: return .otherImport
    case nil: return provenance.sourceURL == nil ? .pinax : .migrated
    }
  }
}

/// The two provenance keys of `asset.meta`, parsed once.
public struct AssetProvenance: Sendable, Equatable {
  public let importedFrom: String?
  public let sourceURL: String?

  /// Meta that is missing, not JSON, or not an object has neither key; so
  /// does a key whose value is not a non-empty string.
  public init(meta: String?) {
    let object = meta.flatMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    func text(_ key: String) -> String? {
      guard let value = object?[key] as? String, !value.isEmpty else { return nil }
      return value
    }
    importedFrom = text("imported_from")
    sourceURL = text("source_url")
  }

  /// The meta a claim writes. `importedFrom` is required: a row with
  /// `source_url` but no `imported_from` reads as `migrated`, and the delete
  /// path (DeletingCatalog) would then delete the bucket object too.
  static func meta(importedFrom: String, sourceURL: String?) -> String {
    struct Keys: Encodable {
      let imported_from: String
      let source_url: String?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Encoding two strings cannot fail.
    let data = try! encoder.encode(Keys(imported_from: importedFrom, source_url: sourceURL))
    return String(decoding: data, as: UTF8.self)
  }

  /// The meta a migrated upload writes: only
  /// `source_url`, never `imported_from`, so the asset reads as `migrated`
  /// and deleting it deletes its bucket object too.
  static func migratedMeta(sourceURL: String) -> String {
    struct Keys: Encodable { let source_url: String }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Encoding one string cannot fail.
    let data = try! encoder.encode(Keys(source_url: sourceURL))
    return String(decoding: data, as: UTF8.self)
  }

  /// `value` with every byte outside printable ASCII percent-encoded, for
  /// an object metadata header.
  static func percentEncodedNonASCII(_ value: String) -> String {
    var result = ""
    for byte in value.utf8 {
      if byte > 0x20, byte < 0x7f {
        result.unicodeScalars.append(Unicode.Scalar(byte))
      } else {
        result += String(format: "%%%02X", byte)
      }
    }
    return result
  }

  /// A referenced URL as recorded: query and fragment cut, the rest byte
  /// for byte as the reference had it.
  static func recordedURL(_ rawURL: String) -> String {
    String(rawURL.prefix { $0 != "?" && $0 != "#" })
  }
}

/// What the Inspector's Source row says: the kind, a domain and the
/// date the asset entered the catalog (`created_at`, not `uploaded_at`).
public struct AssetSourceDescription: Sendable, Equatable {
  public let source: AssetSource
  public let title: String
  /// `source_url`'s host, else the backend's current prefix host.
  public let domain: String?
  /// `asset.created_at`, unformatted; the caller formats it.
  public let addedAt: String
  /// A migrated asset's `source_url`, which the Source row opens.
  public let originalURL: URL?

  public init(asset: Asset, backend: Backend) {
    let provenance = AssetProvenance(meta: asset.meta)
    source = AssetSource.of(meta: asset.meta)
    switch source {
    case .picgo: title = "Imported from PicGo"
    case .bucket: title = "Imported from your bucket"
    case .otherImport: title = "Imported from \(provenance.importedFrom ?? "")"
    // The host the image was copied from.
    case .migrated:
      title = "Migrated from \(provenance.sourceURL.flatMap { URL(string: $0)?.host } ?? "another site")"
    case .pinax: title = "Uploaded by Pinax"
    }
    originalURL = source == .migrated ? provenance.sourceURL.flatMap(URL.init(string:)) : nil
    domain =
      provenance.sourceURL.flatMap { URL(string: $0)?.host }
      ?? URL(string: backend.urlPrefix)?.host
    addedAt = asset.createdAt
  }

  /// The row's text with `date` (already formatted) at the end. Only the
  /// bucket line names its domain.
  public func text(date: String) -> String {
    if source == .bucket, let domain {
      return "\(title) · \(domain) · \(date)"
    }
    return "\(title) · \(date)"
  }
}
