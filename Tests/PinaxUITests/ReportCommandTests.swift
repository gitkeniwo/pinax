import CatalogCore
import Foundation
import GRDB
import Testing

@testable import pinax

/// The report commands, run as the built binary on `makeCLITestDatabase()`.
@Suite struct ReportCommandTests {
  private let first = String(format: "%064x", 1)
  private let second = String(format: "%064x", 2)

  private func withFixture(_ body: (DatabasePool, URL) throws -> Void) throws {
    let (database, directory) = try makeCLITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(database, directory)
  }

  /// Adds line 5, asset-1 under the old domain, and scans again.
  private func addOldDomainUse(_ database: DatabasePool, _ directory: URL) throws {
    let file = directory.appendingPathComponent("site/a.md")
    let text = try String(contentsOf: file, encoding: .utf8)
    try (text + "\n![e](https://old.example.com/blog/asset-1.png)\n")
      .write(to: file, atomically: true, encoding: .utf8)
    let scan = try UsageScanner.scan(project: "blog", in: database)
    _ = try CatalogUsage.sync(scan.document, project: "blog", in: database)
  }

  private func succeed(
    _ arguments: [String], in directory: URL, environment: [String: String] = [:]
  ) throws -> CLIProcess.Result {
    let result = try CLIProcess.run(arguments, in: directory, environment: environment)
    #expect(result.status == 0, "\(result.stderr)")
    return result
  }

  private func json(
    _ arguments: [String], in directory: URL, environment: [String: String] = [:]
  ) throws -> [String: Any] {
    let result = try succeed(
      arguments + ["--format", "json"], in: directory, environment: environment)
    return try #require(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
  }

  /// The rows under the header, split at tabs.
  private func rows(_ table: String) -> [[String]] {
    table.split(separator: "\n").dropFirst().map {
      $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }
  }

  private func sources(_ document: [String: Any], _ list: String = "items") throws -> [String] {
    try #require(document[list] as? [[String: Any]]).map { $0["source_ref"] as? String ?? "" }
  }

  // MARK: usage report

  @Test("usage report keeps its table, and --old-domains adds the current URL")
  func oldDomains() throws {
    try withFixture { database, directory in
      try addOldDomainUse(database, directory)
      let plain = try succeed(["usage", "report", "--project", "blog"], in: directory).stdout
      #expect(plain.hasPrefix("SHA256\tKEY\tKIND\tSOURCE\tURL\n"))
      #expect(rows(plain).count == 5)
      #expect(rows(plain).allSatisfy { $0.count == 5 })

      let old = try succeed(
        ["usage", "report", "--project", "blog", "--old-domains"], in: directory
      ).stdout
      #expect(
        old == "SHA256\tKEY\tKIND\tSOURCE\tURL\tNEW_URL\n"
          + "\(second.prefix(12))\tblog/asset-1.png\tmarkdown\tsite/a.md#L5\t"
          + "https://old.example.com/blog/asset-1.png\t"
          + "https://img.example.com/blog/asset-1.png\n")
    }
  }

  @Test("usage report JSON adds old_domain and current_url to each item")
  func reportJSON() throws {
    try withFixture { database, directory in
      try addOldDomainUse(database, directory)
      let document = try json(["usage", "report", "--project", "blog"], in: directory)
      #expect(document["schema"] as? Int == 1)
      let items = try #require(document["items"] as? [[String: Any]])
      #expect(items.map { $0["old_domain"] as? Bool } == [false, false, false, false, true])
      #expect(items[0]["current_url"] as? String == "https://img.example.com/blog/asset-0.png")
      #expect(items[4]["current_url"] as? String == "https://img.example.com/blog/asset-1.png")
      // An external URL, old domain or not, has no asset: its own keys stay
      // absent and the new one is null.
      #expect(items[2]["current_url"] is NSNull)
      #expect(items[2]["sha256"] == nil)

      let filtered = try json(
        ["usage", "report", "--project", "blog", "--old-domains"], in: directory)
      #expect(try sources(filtered) == ["site/a.md#L5"])
    }
  }

  @Test("--source takes a file or one of its lines")
  func sourceFilter() throws {
    try withFixture { database, directory in
      try addOldDomainUse(database, directory)
      let command = ["usage", "report", "--project", "blog", "--source"]
      let file = try succeed(command + ["site/a.md"], in: directory).stdout
      #expect(rows(file).count == 5)
      let line = try succeed(command + ["site/a.md#L2"], in: directory).stdout
      #expect(rows(line).map { $0[3] } == ["site/a.md#L2"])
      let none = try succeed(command + ["site/a"], in: directory).stdout
      #expect(rows(none).isEmpty)
      let both = try json(command + ["site/a.md#L1", "--old-domains"], in: directory)
      #expect(try sources(both).isEmpty)
    }
    #expect(UsageReportCommand.reference("a.md#L10", isIn: "a.md"))
    #expect(!UsageReportCommand.reference("a.md#L10", isIn: "a.md#L1"))
    #expect(!UsageReportCommand.reference("a.mdx#L1", isIn: "a.md"))
    #expect(!UsageReportCommand.reference("a.md#Late", isIn: "a.md"))
  }

  // MARK: externals

  @Test("externals --domain keeps one half, in the table and the JSON")
  func externalsDomain() throws {
    try withFixture { _, directory in
      for command in [["externals"], ["externals", "list", "--project", "blog"]] {
        let yours = try succeed(command + ["--domain", "yours"], in: directory).stdout
        #expect(
          yours == "KIND\tSOURCE\tURL\n"
            + "markdown\tsite/a.md#L2\thttps://img.example.com/blog/gone.png\n"
            + "markdown\tsite/a.md#L3\thttps://old.example.com/blog/missing.png\n")
        let other = try succeed(command + ["--domain", "other"], in: directory).stdout
        #expect(
          other == "KIND\tSOURCE\tURL\n"
            + "markdown\tsite/a.md#L4\thttps://elsewhere.example.org/x.png\n")
      }
      let document = try json(["externals", "--domain", "other"], in: directory)
      #expect(try sources(document) == ["site/a.md#L4"])
      #expect(try CLIProcess.run(["externals", "--domain", "mine"], in: directory).status == 64)
    }
  }

  // MARK: used-in

  @Test("used-in lists an asset's references")
  func usedIn() throws {
    try withFixture { database, directory in
      try addOldDomainUse(database, directory)
      let table = try succeed(["used-in", "blog/asset-1.png"], in: directory)
      #expect(table.stderr.isEmpty)
      #expect(
        table.stdout == "PROJECT\tSOURCE\tKIND\tURL\tOLD_DOMAIN\n"
          + "blog\tsite/a.md#L5\tmarkdown\thttps://old.example.com/blog/asset-1.png\ttrue\n")

      let document = try json(["used-in", String(second)], in: directory)
      #expect(
        document as NSDictionary == [
          "schema": "pinax.used-in.v1", "sha256": second, "key": "blog/asset-1.png",
          "url": "https://img.example.com/blog/asset-1.png", "project": NSNull(),
          "scanned_projects": ["blog"],
          "references": [
            [
              "project": "blog", "source_ref": "site/a.md#L5", "kind": "markdown",
              "raw_url": "https://old.example.com/blog/asset-1.png", "old_domain": true,
            ] as [String: Any]
          ],
        ] as NSDictionary)
    }
  }

  @Test("used-in tells a project without a scan from an unused asset")
  func usedInScope() throws {
    try withFixture { _, directory in
      let unused = try succeed(["used-in", "blog/asset-1.png"], in: directory)
      #expect(unused.stderr.isEmpty)
      #expect(rows(unused.stdout).isEmpty)

      let unscanned = try succeed(
        ["used-in", "blog/asset-0.png", "--project", "notes"], in: directory)
      #expect(unscanned.stderr == "Project 'notes' has no completed usage scan.\n")
      #expect(rows(unscanned.stdout).isEmpty)

      let scoped = try succeed(["used-in", "blog/asset-0.png", "--project", "blog"], in: directory)
      #expect(rows(scoped.stdout).map { $0[1] } == ["site/a.md#L1"])

      for arguments in [["used-in", "ffffff"], ["used-in", first, "--project", "nope"]] {
        #expect(try CLIProcess.run(arguments, in: directory).status == 66)
      }
    }
  }

  // MARK: stats

  @Test("stats prints its numbers, then the days")
  func statsTable() throws {
    try withFixture { _, directory in
      let table = try succeed(["stats"], in: directory, environment: ["TZ": "Asia/Tokyo"])
      #expect(
        table.stdout == """
          project: all
          assets: 3
          bytes: 3003
          favorites: 0
          archived: 0
          tagged: 1
          untagged: 2
          used_images: 1
          orphan_candidates: 1
          orphan_candidate_bytes: 1001
          externals_on_your_domains: 2
          old_domain_references: 0
          time_zone: Asia/Tokyo

          DATE\tCOUNT\tBYTES
          2026-08-01\t1\t1000
          2026-08-02\t1\t1001
          2026-08-03\t1\t1002

          """)
    }
  }

  @Test("stats days follow TZ")
  func statsTimeZone() throws {
    try withFixture { _, directory in
      // Every upload is at midnight UTC: the previous day west of it.
      func days(_ zone: String) throws -> [String] {
        let document = try json(["stats"], in: directory, environment: ["TZ": zone])
        #expect(document["time_zone"] as? String == zone)
        return try #require(document["uploads_by_day"] as? [[String: Any]])
          .compactMap { $0["date"] as? String }
      }
      let east = try days("Asia/Tokyo")
      let west = try days("America/Los_Angeles")
      #expect(east == ["2026-08-01", "2026-08-02", "2026-08-03"])
      #expect(west == ["2026-07-31", "2026-08-01", "2026-08-02"])
    }
  }

  @Test("stats JSON, for one project")
  func statsJSON() throws {
    try withFixture { _, directory in
      let document = try json(["stats", "--project", "notes"], in: directory)
      #expect(document["schema"] as? String == "pinax.stats.v1")
      #expect(document["project"] as? String == "notes")
      #expect(document["assets"] as? [String: Int] == ["count": 1, "bytes": 1002])
      #expect(document["orphan_candidates"] as? [String: Int] == ["count": 0, "bytes": 0])
      #expect(
        document["projects"] as? NSArray == [
          [
            "slug": "notes", "name": "Notes", "used_images": 0, "orphan_candidates": 0,
            "externals_on_your_domains": 0, "externals_on_other_domains": 0,
            "last_scan_at": NSNull(), "usage_tracking": "not-tracked",
          ] as [String: Any]
        ] as NSArray)
      #expect(
        document["project_shares"] as? NSArray
          == [["name": "Notes", "count": 1, "bytes": 1002] as [String: Any]] as NSArray)
      #expect(try CLIProcess.run(["stats", "--project", "nope"], in: directory).status == 66)
    }
  }
}
