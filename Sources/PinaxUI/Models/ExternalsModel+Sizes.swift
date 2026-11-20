import CatalogCore
import Foundation

/// A selection's sizes, from the images a Load
/// already fetched — nothing is asked of a host for them.
public struct ExternalSelectionSizes: Equatable, Sendable {
  /// The loaded images' bytes added up; nil when none has a size.
  public let loadedBytes: Int64?
  /// One of the loaded images is at or over the large line.
  public let hasLarge: Bool
  /// Images (distinct URLs) not loaded.
  public let notLoaded: Int
  /// Each host's loaded bytes; a host with none loaded is absent.
  public let hostBytes: [String: Int64]
  /// Hosts holding a large image.
  public let largeHosts: Set<String>

  /// "1 not loaded".
  public var notLoadedText: String { "\(notLoaded.formatted()) not loaded" }
}

extension ExternalsModel {
  /// The original's facts for a loaded row; nil until loaded, or
  /// for an image cached before they were recorded.
  public func imageInfo(_ row: ExternalReference) -> RemoteImageInfo? {
    if case let .loaded(_, info)? = preview(row) { return info }
    return nil
  }

  /// The strip's two pills and the Hosts subtotals, over the
  /// selection's distinct images.
  public func selectionSizes(_ summary: ExternalSelectionSummary) -> ExternalSelectionSizes {
    var total: Int64?
    var hasLarge = false
    var notLoaded = 0
    var hostBytes: [String: Int64] = [:]
    var largeHosts = Set<String>()
    for row in summary.images {
      guard case .loaded? = preview(row) else {
        notLoaded += 1
        continue
      }
      guard let info = imageInfo(row) else { continue }
      total = (total ?? 0) + info.bytes
      let host = URL(string: row.rawURL)?.host?.lowercased() ?? "No Host"
      hostBytes[host, default: 0] += info.bytes
      if info.isLarge {
        hasLarge = true
        largeHosts.insert(host)
      }
    }
    return ExternalSelectionSizes(
      loadedBytes: total, hasLarge: hasLarge, notLoaded: notLoaded, hostBytes: hostBytes,
      largeHosts: largeHosts)
  }
}
