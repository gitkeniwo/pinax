import CatalogCore
import Foundation

/// One block of a report's explanation: an optional heading over its lines.
public struct ReportNote: Equatable, Sendable {
  public let heading: String?
  public let lines: [String]

  public init(heading: String? = nil, lines: [String]) {
    self.heading = heading
    self.lines = lines
  }
}

/// What a report's header says: the one-line summary
/// beside the title, the explanation under it, and whether the header
/// offers Open Maintenance… beside that explanation.
public struct ReportHeaderContent: Equatable, Sendable {
  public let summary: String
  public let details: [ReportNote]
  public let offersMaintenance: Bool
}

/// The report headers' words, as pure functions of the report — so the
/// summary and every sentence moved out of the old report bodies are
/// testable without a view.
public enum ReportHeaderModel {
  /// What the Orphans surface shows under its header.
  public enum OrphanContent: Equatable, Sendable {
    case loading
    /// The candidates, in the main grid's cells.
    case candidates
    /// Every project that has assets has never completed a scan: every
    /// asset would be a candidate, so the list says nothing. The names are
    /// those projects', for the empty state's sentence.
    case usageUnknown(projectNames: [String])
  }

  /// The Orphans header and content. `candidateCount` is nil while the
  /// report loads. A project with no completed scan is "never scanned" in
  /// the summary: one by name, more by count. `untracked` counts the assets
  /// left out because their every project is not tracked, and
  /// `notTrackedProjects` how many such projects are in scope;
  /// `health` and `projects` leave not-tracked projects out.
  public static func compose(
    orphanCandidates candidateCount: Int?,
    health: [OrphanScanHealth],
    projects: [ProjectSummary],
    untracked: Int = 0,
    notTrackedProjects: Int = 0
  ) -> (header: ReportHeaderContent, content: OrphanContent) {
    let neverScanned = health.filter { $0.status == .neverScanned }
    let neverScannedSlugs = Set(neverScanned.map(\.slug))
    let withAssets = projects.filter { $0.assetCount > 0 }
    let usageUnknown =
      !withAssets.isEmpty && withAssets.allSatisfy { neverScannedSlugs.contains($0.slug) }

    var parts: [String] = []
    if let candidateCount, !usageUnknown {
      parts.append(PinaxFormat.count(candidateCount, singular: "candidate"))
    }
    switch neverScanned.count {
    case 0: break
    case 1: parts.append("\(neverScanned[0].name) never scanned")
    default: parts.append("\(neverScanned.count) projects never scanned")
    }

    let content: OrphanContent
    if usageUnknown {
      content = .usageUnknown(projectNames: withAssets.map(\.name))
    } else if candidateCount == nil {
      content = .loading
    } else {
      content = .candidates
    }
    return (
      ReportHeaderContent(
        summary: parts.joined(separator: " · "),
        details: orphanDetails(
          health, untracked: untracked, notTrackedProjects: notTrackedProjects),
        // With the list replaced by Usage Unknown, its empty state carries
        // the button; the header would only repeat it.
        offersMaintenance: !neverScanned.isEmpty && !usageUnknown),
      content
    )
  }

  /// The candidates split for the grid: those whose every project
  /// has never completed a scan go to the collapsed "Not yet scanned" group;
  /// one also in a scanned project takes that project's verdict and stays.
  /// A not-tracked project has no verdict: a candidate in a
  /// never-scanned tracked project and in a not-tracked one waits with the
  /// first. A candidate in no project stays. Report order is kept in both.
  public static func splitOrphans(
    _ report: OrphanReport,
    health: [OrphanScanHealth]
  ) -> (scanned: [CatalogAssetItem], notYetScanned: [CatalogAssetItem]) {
    let neverScanned = Set(health.filter { $0.status == .neverScanned }.map(\.slug))
    let notTracked = Set(report.notTrackedProjects).union(report.notTrackedSlugs)
    var scanned: [CatalogAssetItem] = []
    var notYetScanned: [CatalogAssetItem] = []
    for item in report.assets {
      let slugs = (item.asset.id.flatMap { report.projectSlugs[$0] } ?? [])
        .filter { !notTracked.contains($0) }
      if !slugs.isEmpty && slugs.allSatisfy(neverScanned.contains) {
        notYetScanned.append(item)
      } else {
        scanned.append(item)
      }
    }
    return (scanned, notYetScanned)
  }

  /// The old caveat block and scan-health list, word for word, as
  /// the header's explanation.
  static func orphanDetails(
    _ health: [OrphanScanHealth], untracked: Int = 0, notTrackedProjects: Int = 0
  ) -> [ReportNote] {
    var notes = [
      ReportNote(
        heading: "Orphan candidates — read-only",
        lines: [
          "Live usage is a lower bound, not proof. An asset appears here when no project's "
            + "latest completed scan references it — a project that has not been scanned "
            + "recently makes its assets look orphaned. This list is read-only and can "
            + "never justify deleting anything from the object store."
        ])
    ]
    let neverScanned = health.filter { $0.status == .neverScanned }
    let underScanned = health.filter { $0.status == .underScanned }
    let healthy = health.filter { $0.status == .scanned }
    if !neverScanned.isEmpty {
      notes.append(
        ReportNote(
          heading: "Never scanned",
          lines: neverScanned.map {
            "\($0.name): no usage scan has ever completed, so all of its assets may appear here."
          }))
    }
    if !underScanned.isEmpty {
      notes.append(
        ReportNote(
          heading: "Fewer than two completed scans",
          lines: underScanned.map { "\($0.name): last scan \(scanDate($0.lastScanAt))." }))
    }
    if !healthy.isEmpty {
      notes.append(
        ReportNote(lines: [
          "Scanned recently: "
            + healthy.map { "\($0.name) (\(scanDate($0.lastScanAt)))" }
            .joined(separator: ", ") + "."
        ]))
    }
    if untracked > 0 {
      notes.append(ReportNote(lines: [untrackedNote(untracked)]))
    }
    if health.isEmpty && notTrackedProjects == 0 {
      notes.append(ReportNote(lines: ["No projects are configured."]))
    }
    return notes
  }

  /// The not-tracked note, its verb agreeing with the count.
  static func untrackedNote(_ count: Int) -> String {
    PinaxFormat.count(count, singular: "asset")
      + " in not-tracked projects \(count == 1 ? "is" : "are") not listed."
  }

  private static func scanDate(_ raw: String?) -> String {
    raw.map { PinaxFormat.date($0, style: .dayTime) } ?? "unknown"
  }


  /// The Externals header: the count, and the old read-only paragraph word
  /// for word as its Details. `count` is nil while loading.
  public static func compose(externals count: Int?) -> ReportHeaderContent {
    ReportHeaderContent(
      summary: count.map {
        PinaxFormat.count($0, singular: "external reference")
      } ?? "",
      details: [
        ReportNote(
          heading: "External references — read-only",
          lines: [
            "URLs found in the latest completed usage scans that do not match any asset in "
              + "this catalog. This report does not change the catalog."
          ]),
        ReportNote(
          heading: "Your Domains",
          lines: [
            "On your backends' domains but not in the catalog: a typo, an object removed "
              + "outside Pinax, or one uploaded by another tool."
          ]),
      ],
      offersMaintenance: false)
  }
}
