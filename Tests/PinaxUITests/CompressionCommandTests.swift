import ArgumentParser
import CatalogCore
import Foundation
import GRDB
import Testing
@testable import pinax

/// `pinax upload --compress/--no-compress`, `pinax project set` with the
/// compression options, and `externals migrate --compress`, through the real
/// parser on a temporary catalog.
@Suite struct CompressionCommandTests {
  private func parse<T: ParsableCommand>(_ arguments: [String], as: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }

  private func project(_ slug: String, in database: DatabasePool) throws -> Project {
    try #require(try CatalogConfiguration.projects(in: database).first { $0.slug == slug })
  }

  @Test("upload follows the project by default; the flags force it on or off")
  func uploadFlags() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CatalogConfiguration.setCompression(slug: "blog", in: database) {
      $0.isEnabled = true
      $0.options.longestEdge = 1600
    }
    let blog = try project("blog", in: database)
    let notes = try project("notes", in: database)
    let blogOptions = CompressionOptions(longestEdge: 1600)

    let plain = try parse(["upload", "a.png"], as: UploadCommand.self)
    #expect(plain.compressionOptions(for: blog) == blogOptions)
    #expect(plain.compressionOptions(for: notes) == nil)
    #expect(plain.compressionOptions(for: nil) == nil)

    let on = try parse(["upload", "--compress", "a.png"], as: UploadCommand.self)
    #expect(on.compressionOptions(for: blog) == blogOptions)
    #expect(on.compressionOptions(for: notes) == .default)
    #expect(on.compressionOptions(for: nil) == .default)

    let off = try parse(["upload", "--no-compress", "a.png"], as: UploadCommand.self)
    #expect(off.compressionOptions(for: blog) == nil)
  }

  @Test("project set stores compression on its own or with other changes")
  func projectSet() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }

    let only = try parse(
      ["project", "set", "--slug", "blog", "--compress", "--longest-edge", "none",
       "--quality", "small", "--keep-metadata"],
      as: ProjectSet.self)
    #expect(try only.perform(in: database).output == "blog")
    var settings = try CatalogConfiguration.projectSettings(slug: "blog", in: database)
    #expect(settings.compression.isEnabled)
    #expect(
      settings.compression.options
        == CompressionOptions(longestEdge: nil, quality: 60, removesMetadata: false))

    let more = try parse(
      ["project", "set", "--slug", "blog", "--name", "Weblog", "--longest-edge", "2560",
       "--remove-metadata"],
      as: ProjectSet.self)
    _ = try more.perform(in: database)
    settings = try CatalogConfiguration.projectSettings(slug: "blog", in: database)
    #expect(try project("blog", in: database).name == "Weblog")
    #expect(settings.compression.isEnabled)
    #expect(
      settings.compression.options
        == CompressionOptions(longestEdge: 2560, quality: 60, removesMetadata: true))

    let off = try parse(["project", "set", "--slug", "blog", "--no-compress"], as: ProjectSet.self)
    _ = try off.perform(in: database)
    settings = try CatalogConfiguration.projectSettings(slug: "blog", in: database)
    #expect(!settings.compression.isEnabled)
    #expect(settings.compression.options.longestEdge == 2560)

    // Nothing to change is still refused.
    let nothing = try parse(["project", "set", "--slug", "blog"], as: ProjectSet.self)
    #expect(throws: CatalogConfigurationError.self) { try nothing.perform(in: database) }
  }

  @Test("project set takes a quality from 40 to 100 or an old name, and stores the number")
  func projectSetQuality() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (argument, percent) in [("40", 40), ("100", 100), ("72", 72), ("high", 85), ("medium", 75), ("small", 60)] {
      let command = try parse(["project", "set", "--slug", "blog", "--quality", argument], as: ProjectSet.self)
      _ = try command.perform(in: database)
      let settings = try CatalogConfiguration.projectSettings(slug: "blog", in: database)
      #expect(settings.compression.options.quality.percent == percent, "\(argument)")
    }
    let help = ProjectSet.helpMessage()
    #expect(help.contains("40 to 100") && help.contains("(default 85)"), "\(help)")
  }

  @Test("project set rejects a bad longest edge or quality")
  func projectSetRejects() {
    for arguments in [
      ["--longest-edge", "0"], ["--longest-edge", "big"], ["--quality", "best"],
      ["--quality", "39"], ["--quality", "101"], ["--quality", "85.5"], ["--quality", "-1"],
    ] {
      #expect(throws: (any Error).self) {
        try Pinax.parseAsRoot(["project", "set", "--slug", "blog"] + arguments)
      }
    }
  }

  @Test("externals migrate takes --compress and --no-compress only with --apply")
  func migrateFlag() throws {
    let apply = try parse(
      ["externals", "migrate", "--apply", "--from-run", "3", "--no-compress"],
      as: ExternalsMigrateCommand.self)
    #expect(apply.compress == false)
    let following = try parse(
      ["externals", "migrate", "--apply", "--from-run", "3"], as: ExternalsMigrateCommand.self)
    #expect(following.compress == nil)
    #expect(throws: (any Error).self) {
      try Pinax.parseAsRoot(
        ["externals", "migrate", "--project", "blog", "--host", "a.invalid", "--compress"])
    }
  }
}
