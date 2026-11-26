import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing

@testable import pinax

/// `pinax project set`'s usage tracking and backend options, `project show`,
/// the `project ls` / `show` JSON and `project source set`, through the real
/// parser on a temporary catalog.
@Suite struct ProjectSettingsCommandTests {
  private func parse<T: ParsableCommand>(_ arguments: [String], as: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }

  private func withDatabase(_ body: (DatabasePool) throws -> Void) throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(database)
  }

  private func settings(_ database: DatabasePool) throws -> ProjectSettings {
    try CatalogConfiguration.projectSettings(slug: "blog", in: database)
  }

  private func project(_ database: DatabasePool) throws -> Project {
    try #require(try CatalogConfiguration.projects(in: database).first { $0.slug == "blog" })
  }

  private func set(_ arguments: [String], in database: DatabasePool) throws {
    _ = try parse(["project", "set", "--slug", "blog"] + arguments, as: ProjectSet.self)
      .perform(in: database)
  }

  private func sourceSet(_ arguments: [String], in database: DatabasePool) throws -> String {
    try parse(["project", "source", "set", "blog"] + arguments, as: ProjectSourceSet.self)
      .output(in: database)
  }

  private let sources = [
    ProjectSource(label: "first", path: "/srv/first"),
    ProjectSource(label: "site", path: "/srv/site", include: ["**/*.md"], exclude: ["drafts/**"]),
    ProjectSource(label: "cms", command: "node export.mjs", workingDirectory: "/srv/cms"),
  ]

  // MARK: - project set

  @Test("--usage-tracking alone is a change, and goes both ways")
  func usageTracking() throws {
    try withDatabase { database in
      try set(["--usage-tracking", "not-tracked"], in: database)
      #expect(try settings(database).usageTracking == .notTracked)
      try set(["--usage-tracking", "tracked"], in: database)
      #expect(try settings(database).usageTracking == .tracked)
    }
  }

  @Test("--no-backend alone clears the backend, and works beside another change")
  func noBackend() throws {
    try withDatabase { database in
      #expect(try project(database).backendID != nil)
      try set(["--no-backend"], in: database)
      #expect(try project(database).backendID == nil)
      try set(["--backend", "r2"], in: database)
      try set(["--no-backend", "--name", "Journal"], in: database)
      #expect(try project(database).backendID == nil)
      #expect(try project(database).name == "Journal")
    }
  }

  @Test("--backend with --no-backend is refused by the parser")
  func bothBackendOptions() {
    #expect {
      try Pinax.parseAsRoot(
        ["project", "set", "--slug", "blog", "--backend", "r2", "--no-backend"])
    } throws: { error in
      Pinax.message(for: error) == "Give --backend or --no-backend, not both."
    }
  }

  // MARK: - project source set

  @Test("--path alone keeps the label, the patterns and the order")
  func pathOnly() throws {
    try withDatabase { database in
      try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
      #expect(try sourceSet(["site", "--path", "~/moved/"], in: database) == "site")
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      #expect(
        try settings(database).sources == [
          sources[0],
          ProjectSource(
            label: "site", path: home + "/moved", include: ["**/*.md"], exclude: ["drafts/**"]),
          sources[2],
        ])
    }
  }

  @Test("--include and --exclude replace the patterns; the default include is stored empty")
  func patterns() throws {
    try withDatabase { database in
      try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
      _ = try sourceSet(
        ["site", "--include", " *.html ", "--include", "*.css", "--exclude", "dist/**"],
        in: database)
      #expect(
        try settings(database).sources[1]
          == ProjectSource(
            label: "site", path: "/srv/site", include: ["*.html", "*.css"], exclude: ["dist/**"]))

      _ = try sourceSet(
        ["site", "--include", ProjectSource.defaultInclude[0]], in: database)
      #expect(try settings(database).sources[1].include == [])
      #expect(try settings(database).sources[1].exclude == ["dist/**"])
    }
  }

  @Test("--clear-include and --clear-exclude empty one list each")
  func clearPatterns() throws {
    try withDatabase { database in
      try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
      _ = try sourceSet(["site", "--clear-include"], in: database)
      #expect(try settings(database).sources[1].include == [])
      #expect(try settings(database).sources[1].exclude == ["drafts/**"])
      _ = try sourceSet(["site", "--clear-exclude"], in: database)
      #expect(try settings(database).sources[1].exclude == [])
    }
  }

  @Test("A command source takes --command and --in, each alone")
  func commandSource() throws {
    try withDatabase { database in
      try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
      _ = try sourceSet(["cms", "--command", "make refs"], in: database)
      #expect(
        try settings(database).sources[2]
          == ProjectSource(label: "cms", command: "make refs", workingDirectory: "/srv/cms"))
      _ = try sourceSet(["cms", "--in", "~/cms/../tools/"], in: database)
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      #expect(
        try settings(database).sources == [
          sources[0], sources[1],
          ProjectSource(label: "cms", command: "make refs", workingDirectory: home + "/tools"),
        ])
    }
  }

  @Test(
    "An option for the other kind of source is refused, naming the kind, and writes nothing",
    arguments: [
      ["site", "--command", "x"], ["site", "--in", "/a"], ["site", "--path", "/a", "--in", "/a"],
      ["cms", "--path", "/a"], ["cms", "--include", "*.md"], ["cms", "--exclude", "a"],
      ["cms", "--clear-include"], ["cms", "--clear-exclude"],
    ])
  func wrongKind(arguments: [String]) throws {
    try withDatabase { database in
      try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
      let kind = arguments[0] == "site" ? "is a folder source" : "is a command source"
      #expect {
        try sourceSet(arguments, in: database)
      } throws: { error in
        error is ValidationError && Pinax.message(for: error).contains(kind)
      }
      #expect(try settings(database).sources == sources)
    }
  }

  @Test(
    "Nothing to change, or a pattern both given and cleared, is refused by the parser",
    arguments: [
      ["site"], ["site", "--include", "a", "--clear-include"],
      ["site", "--exclude", "a", "--clear-exclude"],
    ])
  func parserRefusals(arguments: [String]) {
    #expect(throws: (any Error).self) {
      try Pinax.parseAsRoot(["project", "source", "set", "blog"] + arguments)
    }
  }

  @Test("Exit status: a wrong-kind option 64, a missing source or project 66")
  func exitStatus() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
    func status(_ arguments: [String]) throws -> Int32 {
      try CLIProcess.run(["project"] + arguments, in: directory).status
    }
    #expect(try status(["source", "set", "blog", "cms", "--path", "/a"]) == 64)
    #expect(try status(["set", "--slug", "blog", "--backend", "r2", "--no-backend"]) == 64)
    #expect(try status(["source", "set", "blog", "gone", "--path", "/a"]) == 66)
    #expect(try status(["source", "set", "gone", "site", "--path", "/a"]) == 66)
    #expect(try status(["show", "gone"]) == 66)
    #expect(try settings(database).sources == sources)
  }

  // MARK: - project ls, show

  /// `blog` with the three sources, automatic scanning on, two assets and one
  /// completed scan holding one live reference.
  private func withDescribedProject(_ body: (DatabasePool, String) throws -> Void) throws {
    try withDatabase { database in
      try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
      try CatalogConfiguration.setAutoScan(
        slug: "blog", ProjectAutoScan(watch: true, schedule: .daily), in: database)
      for index in 0..<2 {
        try seedAsset(database, index: index, uploadedAt: "2026-08-0\(index + 1)T00:00:00Z")
      }
      _ = try CatalogUsage.sync(
        UsageDocument(
          project: "blog",
          refs: [
            UsageReference(
              rawURL: "https://img.example.com/blog/asset-0.png", sourceReference: "a.md")
          ]),
        project: "blog", in: database)
      let lastScanAt = try #require(
        try CatalogConfiguration.projectSummaries(in: database)
          .first { $0.slug == "blog" }?.lastScanAt)
      try body(database, lastScanAt)
    }
  }

  private func expectedRecord(lastScanAt: String, sourceList: String) throws -> NSDictionary {
    [
      "slug": "blog", "name": "Blog", "key_prefix": "blog", "key_template": NSNull(),
      "backend": "r2", "usage_tracking": "tracked",
      "auto_scan": ["watch": true, "schedule": "daily"] as [String: Any],
      "sources": try JSONSerialization.jsonObject(with: Data(sourceList.utf8)),
      "last_scan_at": lastScanAt, "live_references": 1, "assets": 2,
    ]
  }

  @Test("show and ls JSON carry the settings and counts; sources are as source ls prints them")
  func json() throws {
    try withDescribedProject { database, lastScanAt in
      let sourceList = try parse(
        ["project", "source", "ls", "blog", "--format", "json"], as: ProjectSourceList.self
      ).output(in: database)
      let record = try expectedRecord(lastScanAt: lastScanAt, sourceList: sourceList)

      let show = try parse(["project", "show", "blog", "--format", "json"], as: ProjectShow.self)
        .output(in: database)
      let shown = try #require(
        JSONSerialization.jsonObject(with: Data(show.utf8)) as? NSDictionary)
      #expect(shown == ["schema": "pinax.project.v1", "project": record] as NSDictionary)

      let ls = try parse(["project", "ls", "--format", "json"], as: ProjectList.self)
        .output(in: database)
      let listed = try #require(
        JSONSerialization.jsonObject(with: Data(ls.utf8)) as? NSDictionary)
      let projects = try #require(listed["projects"] as? [NSDictionary])
      #expect(projects.first { $0["slug"] as? String == "blog" } == record)
      let notes = try #require(projects.first { $0["slug"] as? String == "notes" })
      #expect(notes["last_scan_at"] is NSNull)
      #expect(notes["assets"] as? Int == 0)
      #expect(notes["sources"] as? [NSDictionary] == [])
    }
  }

  @Test("show's table lists the settings, the counts and one line per source")
  func table() throws {
    try withDescribedProject { database, lastScanAt in
      let output = try parse(["project", "show", "blog"], as: ProjectShow.self)
        .output(in: database)
      let include = ProjectSource.defaultInclude[0]
      #expect(
        output == """
          slug: blog
          name: Blog
          key-prefix: blog
          key-template: default
          backend: r2
          usage-tracking: tracked
          watch: on
          schedule: daily
          assets: 2
          live-references: 1
          last-scan-at: \(lastScanAt)
          source: first\t/srv/first\t\(include)\t-\tfolder
          source: site\t/srv/site\t**/*.md\tdrafts/**\tfolder
          source: cms\t/srv/cms\t-\t-\tcommand

          """)
    }
  }
}
