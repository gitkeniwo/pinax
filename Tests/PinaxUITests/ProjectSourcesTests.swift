import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// The `project.meta` contract, `PathGlob`, and the
/// `pinax project source` commands. Every expected value is written out by
/// hand here, not derived from the implementation.
@Suite struct ProjectSourcesTests {
  private func meta(_ database: DatabasePool, _ slug: String = "blog") throws -> String {
    try database.read { db in
      try String.fetchOne(db, sql: "SELECT meta FROM project WHERE slug = ?", arguments: [slug])!
    }
  }

  private func setMeta(_ database: DatabasePool, _ value: String, _ slug: String = "blog") throws {
    try database.write { db in
      try db.execute(sql: "UPDATE project SET meta = ? WHERE slug = ?", arguments: [value, slug])
    }
  }

  private func object(_ json: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
  }

  // MARK: - property 1: unrelated keys survive a write

  @Test("Setting sources keeps an unrelated meta key and leaves meta a JSON object")
  func unrelatedKeysSurvive() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try setMeta(database, #"{"x":1}"#)

    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: "/Users/someone/site")], in: database)
    try CatalogConfiguration.setUsageTracking(slug: "blog", .notTracked, in: database)

    let stored = try #require(object(try meta(database)), "meta is still a JSON object")
    #expect(stored["x"] as? Int == 1)
    #expect(stored["usageTracking"] as? String == "notTracked")
    let sources = try #require(stored["sources"] as? [[String: Any]])
    #expect(sources.count == 1)
    #expect(sources.first?["label"] as? String == "site")
    #expect(sources.first?["path"] as? String == "/Users/someone/site")
    #expect(
      try CatalogConfiguration.projectSettings(slug: "blog", in: database)
        == ProjectSettings(
          sources: [ProjectSource(label: "site", path: "/Users/someone/site")],
          usageTracking: .notTracked))
    // The other project is untouched.
    #expect(try meta(database, "notes") == "{}")
  }

  // MARK: - property 2: a meta that is not a JSON object

  @Test("A meta that is not a JSON object reads as the default and refuses writes byte for byte")
  func badMetaReadsDefaultAndRefusesWrites() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for bad in [#"{"sources": [ "#, "[1, 2]", "", "hand-written notes"] {
      try setMeta(database, bad)
      #expect(
        try CatalogConfiguration.projectSettings(slug: "blog", in: database) == ProjectSettings(),
        "\(bad)")
      #expect(throws: CatalogConfigurationError.projectMetaNotObject("blog")) {
        try CatalogConfiguration.setProjectSources(
          slug: "blog", [ProjectSource(label: "site", path: "/Users/someone/site")], in: database)
      }
      #expect(throws: CatalogConfigurationError.projectMetaNotObject("blog")) {
        try CatalogConfiguration.setUsageTracking(slug: "blog", .notTracked, in: database)
      }
      #expect(try meta(database) == bad, "the stored bytes are unchanged")
    }
  }

  @Test("Missing keys and values of the wrong type read as no sources, tracked")
  func tolerantRead() {
    let none = ProjectSettings(sources: [], usageTracking: .tracked)
    #expect(ProjectSettings(meta: "{}") == none)
    #expect(ProjectSettings(meta: #"{"sources":"nope","usageTracking":3}"#) == none)
    #expect(ProjectSettings(meta: #"{"sources":[{"label":"a"}],"usageTracking":"sometimes"}"#) == none)
    #expect(ProjectSettings(meta: #"{"sources":[{"label":"a","path":"/p","include":"x"}]}"#) == none)
    #expect(
      ProjectSettings(meta: #"{"sources":[{"label":"a","path":"/p"}],"usageTracking":"notTracked"}"#)
        == ProjectSettings(
          sources: [ProjectSource(label: "a", path: "/p", include: [], exclude: [])],
          usageTracking: .notTracked))
  }

  // MARK: - property 4: validation errors

  @Test("Duplicate labels, relative paths, bad label characters and a 17th source are refused")
  func validationErrors() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try setMeta(database, #"{"x":1}"#)
    let set = { (sources: [ProjectSource]) in
      _ = try CatalogConfiguration.setProjectSources(slug: "blog", sources, in: database)
    }
    #expect(throws: CatalogConfigurationError.duplicateSourceLabel("site")) {
      try set([
        ProjectSource(label: "site", path: "/Users/someone/a"),
        ProjectSource(label: "site", path: "/Users/someone/b"),
      ])
    }
    #expect(throws: CatalogConfigurationError.relativeSourcePath("ws/site")) {
      try set([ProjectSource(label: "site", path: "ws/site")])
    }
    for label in ["my site", "", "site/2", "é", String(repeating: "a", count: 65)] {
      #expect(throws: CatalogConfigurationError.invalidSourceLabel(label)) {
        try set([ProjectSource(label: label, path: "/Users/someone/site")])
      }
    }
    let seventeen = (1...17).map { ProjectSource(label: "s\($0)", path: "/Users/someone/s\($0)") }
    #expect(throws: CatalogConfigurationError.tooManySources(17)) { try set(seventeen) }
    #expect(throws: CatalogConfigurationError.projectNotFound("nope")) {
      try CatalogConfiguration.setProjectSources(slug: "nope", [], in: database)
    }
    #expect(try meta(database) == #"{"x":1}"#, "a refused write changes nothing")

    // The edges that are allowed: 16 sources, a 64-character label of every
    // allowed character class.
    let label = "A-z_0.9" + String(repeating: "x", count: 57)
    #expect(label.count == 64)
    try set((1...15).map { ProjectSource(label: "s\($0)", path: "/Users/someone/s\($0)") }
      + [ProjectSource(label: label, path: "/Users/someone/last")])
    #expect(try CatalogConfiguration.projectSettings(slug: "blog", in: database).sources.count == 16)
  }

  @Test("Paths are stored standardized")
  func pathsStoredStandardized() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: "/Users/someone/ws/../site/./")],
      in: database)
    #expect(settings.sources.map(\.path) == ["/Users/someone/site"])
  }

  @Test("A new source's default label is its folder name, made valid and unique")
  func defaultLabels() {
    #expect(ProjectSource.defaultLabel(forPath: "/Users/someone/astro-blog", existing: []) == "astro-blog")
    #expect(
      ProjectSource.defaultLabel(forPath: "/Users/someone/astro-blog", existing: ["astro-blog"])
        == "astro-blog-2")
    #expect(
      ProjectSource.defaultLabel(
        forPath: "/Users/someone/astro-blog", existing: ["astro-blog", "astro-blog-2"])
        == "astro-blog-3")
    #expect(ProjectSource.defaultLabel(forPath: "/Users/someone/My Blog", existing: []) == "My-Blog")
  }

  // MARK: - property 3: PathGlob, by hand

  @Test(
    "PathGlob matches relative POSIX paths",
    arguments: [
      ("**/*.md", "a.md", true),
      ("**/*.md", "a/b/c.md", true),
      ("*.md", "a.md", true),
      ("*.md", "a/b.md", false),
      ("*.md", "a.MD", false),
      ("Docs/*.md", "docs/x.md", false),
      ("*.md", "", false),
      ("**/*.{md,mdx}", "x/y.mdx", true),
      ("**/*.{md,mdx}", "x/y.md", true),
      ("**/*.{md,mdx}", "x/y.markdown", false),
      ("{src,lib}/*.{js,ts}", "lib/x.ts", true),
      ("{src,lib}/*.{js,ts}", "app/x.ts", false),
      ("{a,b}/c.md", "ab/c.md", false),
      ("?.md", "a.md", true),
      ("?.md", "ab.md", false),
      ("a?b", "a/b", false),
      ("src/**/*.astro", "src/pages/about.astro", true),
      ("src/**/*.astro", "src/about.astro", true),
      ("src/**/*.astro", "lib/src/about.astro", false),
      ("src/content/drafts/**", "src/content/drafts/x/y.md", true),
      ("src/content/drafts/**", "src/content/draft.md", false),
      ("**/x", "x", true),
      ("**", "a/b/c", true),
      ("*", "a/b", false),
      ("a/*/c", "a/b/c", true),
      ("a/*/c", "a/b/d/c", false),
      ("a{b", "a{b", true),
    ])
  func pathGlob(pattern: String, path: String, expected: Bool) {
    #expect(PathGlob.matches(pattern, path) == expected, "\(pattern) vs \(path)")
  }

  // MARK: - property 5: the CLI, through its own parser

  private func parse<T: ParsableCommand>(_ arguments: [String], as: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }

  @Test("project source add, ls and rm through the real command parser on a temporary catalog")
  func cliRoundTrip() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try setMeta(database, #"{"x":1}"#)

    let add = try parse(
      ["project", "source", "add", "blog", "/Users/someone/astro-blog/",
       "--include", "src/**/*.md", "--include", "src/**/*.astro", "--exclude", "src/drafts/**"],
      as: ProjectSourceAdd.self)
    #expect(try add.output(in: database) == "astro-blog")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let second = try parse(
      ["project", "source", "add", "blog", "~/astro-blog"], as: ProjectSourceAdd.self)
    #expect(try second.output(in: database) == "astro-blog-2")
    let third = try parse(
      ["project", "source", "add", "blog", "/Users/someone/notes", "--label", "notes"],
      as: ProjectSourceAdd.self)
    #expect(try third.output(in: database) == "notes")

    let ls = try parse(["project", "source", "ls", "blog"], as: ProjectSourceList.self)
    #expect(
      try ls.output(in: database)
        == "astro-blog\t/Users/someone/astro-blog\tsrc/**/*.md src/**/*.astro\tsrc/drafts/**\tfolder\n"
        + "astro-blog-2\t\(home)/astro-blog\t**/*.{md,mdx,markdown,html,htm,astro,vue,svelte,jsx,tsx,css,scss,yml,yaml}\t-\tfolder\n"
        + "notes\t/Users/someone/notes\t**/*.{md,mdx,markdown,html,htm,astro,vue,svelte,jsx,tsx,css,scss,yml,yaml}\t-\tfolder\n")

    let rm = try parse(["project", "source", "rm", "blog", "astro-blog-2"], as: ProjectSourceRemove.self)
    #expect(try rm.output(in: database) == "astro-blog-2")
    let json = try parse(
      ["project", "source", "ls", "blog", "--format", "json"], as: ProjectSourceList.self)
    #expect(
      try json.output(in: database) == """
        [
          {
            "exclude" : [
              "src/drafts/**"
            ],
            "include" : [
              "src/**/*.md",
              "src/**/*.astro"
            ],
            "label" : "astro-blog",
            "path" : "/Users/someone/astro-blog"
          },
          {
            "exclude" : [

            ],
            "include" : [

            ],
            "label" : "notes",
            "path" : "/Users/someone/notes"
          }
        ]

        """)
    #expect(object(try meta(database))?["x"] as? Int == 1)

    #expect(throws: CatalogConfigurationError.sourceNotFound(project: "blog", label: "astro-blog-2")) {
      try rm.output(in: database)
    }
    let relative = try parse(["project", "source", "add", "blog", "ws/site"], as: ProjectSourceAdd.self)
    #expect(throws: CatalogConfigurationError.relativeSourcePath("ws/site")) {
      try relative.output(in: database)
    }
    let duplicate = try parse(
      ["project", "source", "add", "blog", "/Users/someone/x", "--label", "notes"],
      as: ProjectSourceAdd.self)
    #expect(throws: CatalogConfigurationError.duplicateSourceLabel("notes")) {
      try duplicate.output(in: database)
    }
    #expect(try CatalogConfiguration.projectSettings(slug: "blog", in: database).sources.map(\.label)
      == ["astro-blog", "notes"])
  }
}
