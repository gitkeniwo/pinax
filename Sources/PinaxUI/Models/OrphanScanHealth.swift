import CatalogCore
import Foundation

/// Scan freshness behind the orphan view's caveat. Live usage is
/// a lower bound: a project whose scan history is missing or thin makes its
/// assets look orphaned even though the site may still reference them. The
/// orphan header states this per project, derived from `ProjectSummary
/// .lastScanAt` plus the orphan report's under-scanned slugs — never from a
/// guess about scan age.
public struct OrphanScanHealth: Equatable, Sendable, Identifiable {
  public enum Status: Equatable, Sendable {
    /// No completed scan exists; live usage for this project is unknown.
    case neverScanned
    /// Fewer than the required number of completed scans exist.
    case underScanned
    case scanned
  }

  public let status: Status
  public let name: String
  public let slug: String
  public let lastScanAt: String?

  public var id: String { slug }

  public init(status: Status, name: String, slug: String, lastScanAt: String?) {
    self.status = status
    self.name = name
    self.slug = slug
    self.lastScanAt = lastScanAt
  }

  /// `lastScanAt == nil` (never scanned) outranks the under-scanned list: the
  /// report lists such projects too, but nil is the stronger, self-evident fact.
  public static func assess(
    projects: [ProjectSummary],
    underScannedSlugs: [String]
  ) -> [OrphanScanHealth] {
    let underScanned = Set(underScannedSlugs)
    return projects
      .sorted { $0.slug < $1.slug }
      .map { summary in
        if let lastScanAt = summary.lastScanAt {
          return OrphanScanHealth(
            status: underScanned.contains(summary.slug) ? .underScanned : .scanned,
            name: summary.name,
            slug: summary.slug,
            lastScanAt: lastScanAt
          )
        }
        return OrphanScanHealth(
          status: .neverScanned,
          name: summary.name,
          slug: summary.slug,
          lastScanAt: nil
        )
      }
  }
}
