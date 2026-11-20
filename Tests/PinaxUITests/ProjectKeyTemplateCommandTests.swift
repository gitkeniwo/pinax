import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `pinax project add/set --key-template`,
/// `--reset-key-template` and `project ls`, through the real parser on a
/// temporary catalog.
@Suite struct ProjectKeyTemplateCommandTests {
  private func parse<T: ParsableCommand>(_ arguments: [String], as: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }

  private func storedTemplate(_ slug: String, in database: DatabasePool) throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT key_template FROM project WHERE slug = ?", arguments: [slug])
    }
  }

  private let w1 =
    "Without {hash}, two images can get the same key. Pinax refuses the second upload."

  @Test("add and set store a template, warn on stderr's list, reset goes back to default")
  func addSetReset() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = try #require(try CatalogConfiguration.backends(in: database).first).slug

    let add = try parse(
      ["project", "add", "--slug", "kt-notes", "--name", "KT Notes", "--key-prefix", "n",
       "--key-template", "{prefix}/{name}.{ext}", "--backend", backend],
      as: ProjectAdd.self)
    let added = try add.perform(in: database)
    #expect(added.output == "kt-notes")
    #expect(added.warnings == [w1])
    #expect(try storedTemplate("kt-notes", in: database) == "{prefix}/{name}.{ext}")

    let plain = try parse(
      ["project", "add", "--slug", "kt-plain", "--name", "KT Plain", "--key-prefix", "",
       "--backend", backend],
      as: ProjectAdd.self)
    #expect(try plain.perform(in: database).warnings == [])
    #expect(try storedTemplate("kt-plain", in: database) == nil)

    let set = try parse(
      ["project", "set", "--slug", "kt-notes", "--key-template", "{year}/{name}-{hash}.{ext}"],
      as: ProjectSet.self)
    #expect(
      try set.perform(in: database).warnings
        == ["The key prefix “n” isn’t used by this template."])
    #expect(try storedTemplate("kt-notes", in: database) == "{year}/{name}-{hash}.{ext}")

    // The template counts as the one change `project set` needs.
    let reset = try parse(
      ["project", "set", "--slug", "kt-notes", "--reset-key-template"], as: ProjectSet.self)
    let resetResult = try reset.perform(in: database)
    #expect(resetResult.output == "kt-notes")
    #expect(resetResult.warnings.isEmpty)
    #expect(try storedTemplate("kt-notes", in: database) == nil)

    let nothing = try parse(["project", "set", "--slug", "kt-notes"], as: ProjectSet.self)
    #expect(throws: CatalogConfigurationError.noProjectChanges) {
      try nothing.perform(in: database)
    }
  }

  @Test("Both template options at once are refused by the parser")
  func bothOptions() {
    #expect {
      try Pinax.parseAsRoot(
        ["project", "set", "--slug", "kt-notes", "--key-template", "{name}.{ext}",
         "--reset-key-template"])
    } throws: { error in
      Pinax.message(for: error) == "Give --key-template or --reset-key-template, not both."
    }
  }

  @Test("An invalid template is refused with the validation text and nothing is written")
  func invalidTemplate() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let project = try #require(try CatalogConfiguration.projects(in: database).first)
    let set = try parse(
      ["project", "set", "--slug", project.slug, "--key-template", "/{foo}.png"],
      as: ProjectSet.self)
    do {
      _ = try set.perform(in: database)
      Issue.record("expected the template to be refused")
    } catch let error as CatalogConfigurationError {
      #expect(
        error.description == """
          Unknown placeholder {foo}.
          Template must end with .{ext}.
          Template can't start or end with "/", or contain "//".
          """)
    }
    #expect(try storedTemplate(project.slug, in: database) == nil)
  }

  @Test("project ls appends the template as the last column; the default reads `default`")
  func listColumn() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let project = try #require(try CatalogConfiguration.projects(in: database).first)
    let ls = try parse(["project", "ls"], as: ProjectList.self)
    let before = try ls.output(in: database).split(separator: "\n").map(String.init)
    #expect(before.allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 5 })
    #expect(before.allSatisfy { $0.hasSuffix("\tdefault") })
    _ = try CatalogConfiguration.setProject(
      slug: project.slug, name: nil, keyPrefix: nil, backendSlug: nil,
      keyTemplate: .set("{prefix}/{day}/{name}-{hash}.{ext}"), in: database)
    let after = try ls.output(in: database).split(separator: "\n").map(String.init)
    #expect(after == before.map { line in
      line.hasPrefix("\(project.slug)\t")
        ? line.replacingOccurrences(of: "\tdefault", with: "\t{prefix}/{day}/{name}-{hash}.{ext}")
        : line
    })
  }
}
