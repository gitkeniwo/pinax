import CatalogCore
import Foundation
import GRDB
import Testing

/// `CatalogStats`, the Overview's one read. Every
/// number below is worked out by hand from `OverviewFixture`'s table.
@Suite("Overview stats")
struct OverviewStatsTests {
  typealias Total = CatalogStats.Total
  typealias Share = CatalogStats.Share

  static let utc = OverviewFixture.calendar(firstWeekday: 2)

  static func day(_ iso: String, in calendar: Calendar = utc) -> Date {
    calendar.startOfDay(for: OverviewFixture.date(iso + "T12:00:00Z"))
  }

  @Test("All Projects — totals, tags, kinds, backends and the report numbers")
  func allProjects() async throws {
    try await OverviewFixture.withDatabase { database in
      let stats = try await CatalogStats.load(calendar: Self.utc, in: database)
      #expect(stats.project == nil)
      // 25 seeded, 8 archived: 24 active; 1000 × 25 + (0 + … + 24) − 1008.
      #expect(stats.assets == Total(count: 24, bytes: 24_292))
      #expect(stats.favorites == 1)
      #expect(stats.archived == 1)
      #expect(
        stats.tags == [
          Share(name: "travel", total: Total(count: 3)), Share(name: "cover", total: Total(count: 2)),
        ])
      // 7 has both tags: 4 tagged assets, not 3 + 2.
      #expect(stats.tagged == 4)
      #expect(stats.untagged == 20)
      #expect(
        stats.kinds == [
          Share(name: "image/png", total: Total(count: 22, bytes: 22_277)),
          Share(name: "image/jpeg", total: Total(count: 2, bytes: 2_015)),
        ])
      #expect(
        stats.backends == [
          Share(name: "r2", total: Total(count: 23, bytes: 23_286)),
          Share(name: "b2", total: Total(count: 1, bytes: 1_006)),
        ])
      // Archived 8's cover tag is not counted.
      // Used: 3 and 4. Candidates: the other 22 active assets. Notes' 4 is
      // a candidate with notes current though blog uses it.
      #expect(stats.usedImages == 2)
      #expect(stats.orphanCandidates == Total(count: 22, bytes: 22_285))
      #expect(stats.yourDomains == 2)
      #expect(stats.oldDomains == 1)
      #expect(
        stats.projects == [
          CatalogStats.ProjectUsage(
            slug: "blog", name: "Blog", used: 2, orphanCandidates: 4, yourDomains: 2,
            otherDomains: 1, lastScanAt: "2026-10-06T10:01:00Z", usageTracking: .tracked),
          CatalogStats.ProjectUsage(
            slug: "notes", name: "Notes", used: 0, orphanCandidates: 4, yourDomains: 0,
            otherDomains: 0, lastScanAt: nil, usageTracking: .tracked),
        ])
      // Blog 0 1 3 4 5 7, notes 2 4 7 9: 4 and 7 count in both; the 16
      // active assets in neither are "" (24,292 − 8,031 bytes).
      #expect(
        stats.projectShares == [
          Share(name: "", total: Total(count: 16, bytes: 16_261)),
          Share(name: "Blog", total: Total(count: 6, bytes: 6_020)),
          Share(name: "Notes", total: Total(count: 4, bytes: 4_022)),
        ])
    }
  }

  @Test("One project's scope — only its assets, and its own report numbers")
  func oneProject() async throws {
    try await OverviewFixture.withDatabase { database in
      let stats = try await CatalogStats.load(project: "blog", calendar: Self.utc, in: database)
      #expect(stats.project == "blog")
      // Active in blog: 0 1 3 4 5 7.
      #expect(stats.assets == Total(count: 6, bytes: 6_020))
      #expect(stats.favorites == 1)
      #expect(stats.archived == 1)
      #expect(
        stats.tags == [
          Share(name: "cover", total: Total(count: 2)), Share(name: "travel", total: Total(count: 2)),
        ])
      #expect(stats.tagged == 3)
      #expect(stats.untagged == 3)
      #expect(stats.kinds == [Share(name: "image/png", total: Total(count: 6, bytes: 6_020))])
      #expect(stats.backends == [Share(name: "r2", total: Total(count: 6, bytes: 6_020))])
      #expect(stats.usedImages == 2)
      #expect(stats.orphanCandidates == Total(count: 4, bytes: 4_013))
      #expect(stats.yourDomains == 2)
      #expect(stats.oldDomains == 1)
      #expect(stats.projects.map(\.slug) == ["blog"])
      #expect(stats.projects.first?.orphanCandidates == 4)
      // Only the current project, though 4 and 7 are in notes too.
      #expect(stats.projectShares == [Share(name: "Blog", total: Total(count: 6, bytes: 6_020))])

      let notes = try await CatalogStats.load(project: "notes", calendar: Self.utc, in: database)
      // Notes: 2 4 7 9. Blog uses 4, notes does not: a candidate here.
      #expect(notes.assets == Total(count: 4, bytes: 4_022))
      #expect(notes.archived == 0)
      #expect(notes.usedImages == 0)
      #expect(notes.orphanCandidates == Total(count: 4, bytes: 4_022))
      #expect(notes.projectShares == [Share(name: "Notes", total: Total(count: 4, bytes: 4_022))])
    }
  }

  @Test("Uploads by day — active only, bucketed in the calendar's time zone")
  func uploadsByDay() async throws {
    try await OverviewFixture.withDatabase { database in
      let stats = try await CatalogStats.load(calendar: Self.utc, in: database)
      #expect(
        stats.uploadsByDay == [
          Self.day("2025-03-10"): Total(count: 1, bytes: 1_009),
          Self.day("2025-10-05"): Total(count: 1, bytes: 1_000),
          Self.day("2025-10-06"): Total(count: 1, bytes: 1_001),
          Self.day("2026-07-01"): Total(count: 8, bytes: 8_164),
          Self.day("2026-08-20"): Total(count: 5, bytes: 5_070),
          Self.day("2026-09-15"): Total(count: 3, bytes: 3_023),
          Self.day("2026-09-28"): Total(count: 1, bytes: 1_003),
          Self.day("2026-10-04"): Total(count: 1, bytes: 1_004),
          Self.day("2026-10-05"): Total(count: 2, bytes: 2_011),
          Self.day("2026-10-06"): Total(count: 1, bytes: 1_007),
        ])

      // An hour west of UTC, Monday 00:00 UTC (5) is still Sunday, and
      // 2025-10-06 00:00 UTC (1) is 2025-10-05.
      let west = OverviewFixture.calendar(
        firstWeekday: 2, timeZone: TimeZone(secondsFromGMT: -3600)!)
      let shifted = try await CatalogStats.load(calendar: west, in: database)
      #expect(shifted.uploadsByDay[Self.day("2026-10-04", in: west)] == Total(count: 2, bytes: 2_009))
      #expect(shifted.uploadsByDay[Self.day("2026-10-05", in: west)] == Total(count: 1, bytes: 1_006))
      #expect(shifted.uploadsByDay[Self.day("2025-10-05", in: west)] == Total(count: 2, bytes: 2_001))
      #expect(shifted.uploadsByDay[Self.day("2025-10-06", in: west)] == nil)
    }
  }

  /// The counted report numbers against the reports themselves, for the
  /// scope and for every project — so a number on the Overview is the one
  /// its click opens.
  static func expectMatchesReports(_ database: DatabasePool) async throws {
    let slugs = try await database.read { try String.fetchAll($0, sql: "SELECT slug FROM project") }
    for scope in [nil] + slugs.map(Optional.some) {
      let stats = try await CatalogStats.load(project: scope, calendar: utc, in: database)
      let usage = try await CatalogUsage.liveUsage(project: scope, in: database)
      let externals = try await CatalogUsage.externalReferences(project: scope, in: database)
      let orphans = try await CatalogUsage.orphans(project: scope, in: database)
      #expect(stats.usedImages == usage.assets.count, "scope \(scope ?? "All")")
      #expect(stats.oldDomains == usage.references.filter(\.isOldDomain).count)
      #expect(stats.yourDomains == externals.references.filter { $0.domain == .yours }.count)
      #expect(
        stats.orphanCandidates
          == Total(
            count: orphans.assets.count, bytes: orphans.assets.reduce(0) { $0 + $1.asset.byteSize }),
        "scope \(scope ?? "All")")
      for row in stats.projects {
        let projectUsage = try await CatalogUsage.liveUsage(project: row.slug, in: database)
        let projectExternals = try await CatalogUsage.externalReferences(project: row.slug, in: database)
        #expect(row.used == projectUsage.assets.count, "\(row.slug)")
        #expect(
          row.orphanCandidates
            == (try await CatalogUsage.orphans(project: row.slug, in: database)).assets.count,
          "\(row.slug)")
        #expect(row.yourDomains == projectExternals.references.filter { $0.domain == .yours }.count)
        #expect(row.otherDomains == projectExternals.references.filter { $0.domain == .other }.count)
      }
    }
  }

  @Test("Every report number equals its report's own read — this fixture and the not-tracked one")
  @MainActor
  func matchesReports() async throws {
    try await OverviewFixture.withDatabase { try await Self.expectMatchesReports($0) }
    try await UsageNotTrackedTests.withFixture { try await Self.expectMatchesReports($0) }
  }
}
