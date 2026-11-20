import Foundation
import GRDB
import Testing

@testable import CatalogCore

/// Key templates: parsing, checks, warnings, the evaluation the settings
/// field shows, project storage and backups. Temporary catalogs only.
@Suite struct KeyTemplateTests {
  private let sha = "431ced6916a2" + String(repeating: "b", count: 52)
  private let august = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!

  private func errors(_ template: String, prefix: String = "blog") -> [KeyTemplateIssue] {
    KeyTemplate.evaluate(template, keyPrefix: prefix, date: august).errors
  }

  private func warnings(_ template: String, prefix: String = "blog") -> [KeyTemplateIssue] {
    KeyTemplate.evaluate(template, keyPrefix: prefix, date: august).warnings
  }

  /// The rule `render` had before templates, frozen here verbatim so the
  /// default template is compared with it rather than with itself.
  private func legacyRender(prefix: String, filename: String, ext: String, date: Date) -> String {
    let normalizedExtension = ext.trimmingCharacters(in: .whitespacesAndNewlines)
      .drop(while: { $0 == "." }).lowercased()
    let normalizedPrefix = prefix.split(separator: "/", omittingEmptySubsequences: true)
      .joined(separator: "/")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month], from: date)
    let month = String(format: "%04d%02d", parts.year!, parts.month!)
    let basename = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    let latin = basename.applyingTransform(.toLatin, reverse: false) ?? basename
    let stripped = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    var slug = ""
    var previousWasHyphen = false
    for scalar in stripped.lowercased().unicodeScalars {
      if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
        slug.unicodeScalars.append(scalar)
        previousWasHyphen = false
      } else if !previousWasHyphen && !slug.isEmpty {
        slug.append("-")
        previousWasHyphen = true
      }
    }
    slug = String(slug.prefix(40))
    while slug.last == "-" { slug.removeLast() }
    if slug.isEmpty { slug = "image" }
    return [normalizedPrefix, month, "\(slug)-\(sha.prefix(12)).\(normalizedExtension)"]
      .filter { !$0.isEmpty }.joined(separator: "/")
  }

  // MARK: - Default template ≡ the old rule

  @Test("The default template renders every existing case exactly as the old rule did")
  func defaultMatchesLegacy() throws {
    #expect(KeyTemplate.defaultTemplate == "{prefix}/{year}{month}/{name}-{hash}.{ext}")
    let prefixes = ["", "blog", "//blog///", "blog//drafts", "a/b/c", "blog_x", "blog%", "a\\b"]
    let files: [(String, String)] = [
      ("Dashboard Final!!.PNG", ".PNG"), ("!!!.jpg", "jpg"),
      ("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890-extra-long-name.png", "png"),
      ("截图 你好.png", "png"), ("../../ev il 😀 .PNG", "png"), ("a___b--c.gif", "gif"),
      ("pixel.png", "png"), ("{hash}.png", "png"), ("Ünïcödé.webp", "WEBP"),
    ]
    let dates = [august, Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_787_184_000)]
    for prefix in prefixes {
      for (filename, ext) in files {
        for date in dates {
          let expected = legacyRender(prefix: prefix, filename: filename, ext: ext, date: date)
          #expect(
            try KeyTemplate.render(
              keyPrefix: prefix, originalFilename: filename, sha256: sha,
              fileExtension: ext, date: date) == expected)
          #expect(
            try KeyTemplate.render(
              template: KeyTemplate.defaultTemplate, keyPrefix: prefix,
              originalFilename: filename, sha256: sha, fileExtension: ext, date: date)
              == expected)
        }
      }
    }
  }

  @Test("Placeholders are public in their fixed order")
  func placeholderOrder() {
    #expect(
      KeyTemplate.placeholders.map(\.token)
        == ["{prefix}", "{year}", "{month}", "{day}", "{name}", "{hash}", "{ext}"])
  }

  // MARK: - Template errors, verbatim

  @Test("Each template error, with its exact text")
  func templateErrors() {
    #expect(errors("") == [.init(code: .empty, message: "Template is empty.")])
    #expect(errors("  \n") == [.init(code: .empty, message: "Template is empty.")])
    #expect(
      errors("{prefix}/{foo}.{ext}")
        == [.init(code: .unknownPlaceholder, message: "Unknown placeholder {foo}.")])
    #expect(
      errors("{prefix}/{name.{ext}")
        == [.init(code: .unmatchedBrace, message: "Unmatched brace at position 10.")])
    #expect(
      errors("{prefix}/name}.{ext}")
        == [.init(code: .unmatchedBrace, message: "Unmatched brace at position 14.")])
    #expect(
      errors("{prefix}/#{name}.{ext}")
        == [.init(code: .disallowedCharacter, message: "\"#\" is not allowed in a key template.")])
    #expect(
      errors("{prefix}/{name}.png")
        == [.init(code: .missingExtension, message: "Template must end with .{ext}.")])
    let slash = KeyTemplateIssue(
      code: .slashEdges, message: "Template can't start or end with \"/\", or contain \"//\".")
    #expect(errors("/{name}.{ext}") == [slash])
    #expect(errors("{prefix}//{name}.{ext}") == [slash])
    let dot = KeyTemplateIssue(
      code: .dotSegment, message: "\".\" and \"..\" can't be a path segment.")
    #expect(errors("{prefix}/../{name}.{ext}") == [dot])
    #expect(errors("./{name}.{ext}") == [dot])
  }

  @Test("Several errors are listed in code order; the UI shows the first")
  func errorsInCodeOrder() {
    let found = errors("/a b/{foo}.png")
    #expect(found.map(\.code) == [.unknownPlaceholder, .disallowedCharacter, .missingExtension, .slashEdges])
    #expect(found[1].message == "\" \" is not allowed in a key template.")
  }

  @Test("E4 is only about template text: a prefix with other characters stays valid")
  func prefixValueIsNotE4() throws {
    #expect(errors(KeyTemplate.defaultTemplate, prefix: "blog#2 ü") == [])
    #expect(
      try KeyTemplate.render(
        keyPrefix: "blog#2 ü", originalFilename: "a.png", sha256: sha, fileExtension: "png",
        date: august) == "blog#2 ü/202608/a-431ced6916a2.png")
  }

  // MARK: - Rendered-key checks

  @Test("Each rendered-key check refuses rather than rewrites")
  func renderedChecks() {
    #expect(
      errors(KeyTemplate.defaultTemplate, prefix: "cdn-cgi/image")
        == [.init(code: .renderedReservedPrefix, message: "The key can't start with \"cdn-cgi/\".")])
    #expect(
      errors(KeyTemplate.defaultTemplate, prefix: "a/./b").map(\.code) == [.renderedBadSegment])
    #expect(
      errors(KeyTemplate.defaultTemplate, prefix: "a/..").first?.message
        == "The key can't have an empty, \".\" or \"..\" path segment.")
    let long = String(repeating: "p", count: 1000)
    let tooLong = errors(KeyTemplate.defaultTemplate, prefix: long)
    #expect(tooLong.map(\.code) == [.renderedTooLong])
    #expect(tooLong.first?.message == "The key is 1030 bytes; the limit is 1024.")
    // R1 cannot come from a valid template and a normalized prefix; the
    // check itself still holds.
    #expect(
      KeyTemplate.renderedKeyErrors("a/b/")
        == [.init(code: .renderedSlashEdges, message: "The key can't start or end with \"/\".")])
    #expect(throws: KeyTemplateError.self) {
      try KeyTemplate.render(
        keyPrefix: "cdn-cgi", originalFilename: "a.png", sha256: sha, fileExtension: "png",
        date: august)
    }
  }

  // MARK: - Warnings, verbatim

  @Test("W1 and W2 with their exact text; warnings do not block")
  func warningsVerbatim() {
    let noHash = KeyTemplate.evaluate("{prefix}/{name}.{ext}", keyPrefix: "blog", date: august)
    #expect(noHash.isValid)
    #expect(
      noHash.warnings == [
        .init(
          code: .noHash,
          message:
            "Without {hash}, two images can get the same key. Pinax refuses the second upload."
        )
      ])
    #expect(
      warnings("{year}/{name}-{hash}.{ext}", prefix: "/blog/")
        == [
          .init(
            code: .prefixIgnored,
            message: "The key prefix “blog” isn’t used by this template.")
        ])
    #expect(warnings("{year}/{name}-{hash}.{ext}", prefix: "") == [])
    #expect(warnings(KeyTemplate.defaultTemplate) == [])
  }

  // MARK: - One pass

  @Test("A file named {hash}.png is not substituted twice")
  func valuesAreNotReinterpreted() throws {
    // The slug drops braces; a literal-looking value still cannot re-expand.
    #expect(
      try KeyTemplate.render(
        template: "{name}-{hash}.{ext}", keyPrefix: "{hash}", originalFilename: "{hash}.png",
        sha256: sha, fileExtension: "png", date: august) == "hash-431ced6916a2.png")
    #expect(
      try KeyTemplate.render(
        template: "{prefix}/{name}.{ext}", keyPrefix: "{name}", originalFilename: "{hash}.png",
        sha256: sha, fileExtension: "png", date: august) == "{name}/hash.png")
  }

  @Test("{day} is the UTC day, not the local one")
  func utcDay() throws {
    // 00:30 on 1 Sep in UTC+8 is 16:30 on 31 Aug in UTC.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let local = calendar.date(
      from: DateComponents(year: 2026, month: 9, day: 1, hour: 0, minute: 30))!
    #expect(
      try KeyTemplate.render(
        template: "{year}/{month}/{day}/{name}.{ext}", keyPrefix: "", originalFilename: "a.png",
        sha256: sha, fileExtension: "png", date: local) == "2026/08/31/a.png")
  }

  // MARK: - Example segments

  @Test("Example segments join to the real render, with kinds; empty {prefix} adds no /")
  func exampleSegments() throws {
    let templates = [
      KeyTemplate.defaultTemplate, "{prefix}/{year}/{month}/{day}/{name}.{ext}",
      "{year}{month}/{prefix}/{hash}.{ext}", "x-{prefix}-{name}.{ext}", "{name}/{prefix}.{ext}",
      "{prefix}/{prefix}/{hash}.{ext}",
    ]
    for template in templates {
      for prefix in ["", "blog", "a/b"] {
        let evaluation = KeyTemplate.evaluate(template, keyPrefix: prefix, date: august)
        let example = try #require(evaluation.example, "\(template) / \(prefix)")
        let real = try KeyTemplate.render(
          template: template, keyPrefix: prefix, originalFilename: KeyTemplate.sampleFilename,
          sha256: KeyTemplate.sampleSHA256, fileExtension: "png", date: august)
        #expect(evaluation.exampleKey == real)
        #expect(!real.hasPrefix("/") && !real.hasSuffix("/") && !real.contains("//"), "\(real)")
        #expect(example.allSatisfy { !$0.text.isEmpty })
      }
    }
    let empty = KeyTemplate.evaluate(KeyTemplate.defaultTemplate, keyPrefix: "", date: august)
    #expect(empty.exampleKey == "202608/photo-3fa9c2e1b07d.png")
    let blog = KeyTemplate.evaluate(KeyTemplate.defaultTemplate, keyPrefix: "blog", date: august)
    #expect(
      blog.example == [
        .init(kind: .prefix, text: "blog"), .init(kind: .literal, text: "/"),
        .init(kind: .year, text: "2026"), .init(kind: .month, text: "08"),
        .init(kind: .literal, text: "/"), .init(kind: .name, text: "photo"),
        .init(kind: .literal, text: "-"), .init(kind: .hash, text: "3fa9c2e1b07d"),
        .init(kind: .literal, text: "."), .init(kind: .ext, text: "png"),
      ])
    #expect(
      KeyTemplate.evaluate("x-{prefix}-{name}.{ext}", keyPrefix: "", date: august).exampleKey
        == "x--photo.png")
  }

  @Test("No example while there are errors")
  func noExampleWithErrors() {
    for (template, prefix) in [("{foo}.{ext}", "blog"), (KeyTemplate.defaultTemplate, "cdn-cgi")] {
      let evaluation = KeyTemplate.evaluate(template, keyPrefix: prefix, date: august)
      #expect(!evaluation.errors.isEmpty)
      #expect(evaluation.example == nil)
    }
  }

  // MARK: - Storage, configuration, upload

  private func makeCatalog() throws -> (database: DatabasePool, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-keytemplate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://storage.example.com", bucket: "images", region: "auto",
      urlPrefix: "https://img.example.com", keychainReference: "backend.r2", to: database,
      now: august)
    return (database, directory)
  }

  private func storedTemplate(_ slug: String, in database: DatabasePool) throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT key_template FROM project WHERE slug = ?", arguments: [slug])
    }
  }

  @Test("Configuration validates, stores NULL for the default, and tells unchanged from reset")
  func configuration() throws {
    let (database, directory) = try makeCatalog()
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try CatalogConfiguration.addProject(
      slug: "plain", name: "Plain", keyPrefix: "p", backendSlug: "r2", to: database)
    #expect(try storedTemplate("plain", in: database) == nil)
    _ = try CatalogConfiguration.addProject(
      slug: "def", name: "Def", keyPrefix: "d", keyTemplate: KeyTemplate.defaultTemplate,
      backendSlug: "r2", to: database)
    #expect(try storedTemplate("def", in: database) == nil)
    #expect(throws: CatalogConfigurationError.invalidKeyTemplate([
      .init(code: .unknownPlaceholder, message: "Unknown placeholder {foo}.")
    ])) {
      try CatalogConfiguration.addProject(
        slug: "bad", name: "Bad", keyPrefix: "", keyTemplate: "{foo}.{ext}",
        backendSlug: "r2", to: database)
    }
    #expect(try CatalogConfiguration.projects(in: database).map(\.slug) == ["def", "plain"])

    let flat = "{prefix}/{name}.{ext}"
    var project = try CatalogConfiguration.setProject(
      slug: "plain", name: nil, keyPrefix: nil, backendSlug: nil, keyTemplate: .set(flat),
      in: database)
    #expect(project.keyTemplate == flat)
    project = try CatalogConfiguration.setProject(
      slug: "plain", name: "Renamed", keyPrefix: nil, backendSlug: nil, in: database)
    #expect(project.keyTemplate == flat)
    #expect(try storedTemplate("plain", in: database) == flat)
    #expect(
      CatalogConfigurationError.invalidKeyTemplate([
        .init(code: .missingExtension, message: "Template must end with .{ext}.")
      ]).description == "Template must end with .{ext}.")
    #expect(throws: CatalogConfigurationError.self) {
      try CatalogConfiguration.setProject(
        slug: "plain", name: nil, keyPrefix: nil, backendSlug: nil,
        keyTemplate: .set("{name}.png"), in: database)
    }
    #expect(try storedTemplate("plain", in: database) == flat)
    project = try CatalogConfiguration.setProject(
      slug: "plain", name: nil, keyPrefix: nil, backendSlug: nil, keyTemplate: .reset,
      in: database)
    #expect(project.keyTemplate == nil)
    #expect(try storedTemplate("plain", in: database) == nil)
    _ = try CatalogConfiguration.setProject(
      slug: "plain", name: nil, keyPrefix: nil, backendSlug: nil,
      keyTemplate: .set(KeyTemplate.defaultTemplate), in: database)
    #expect(try storedTemplate("plain", in: database) == nil)
    #expect(throws: CatalogConfigurationError.noProjectChanges) {
      try CatalogConfiguration.setProject(
        slug: "plain", name: nil, keyPrefix: nil, backendSlug: nil, in: database)
    }
  }

  @Test("Uploads render with the project's template; an invalid stored one fails, no fallback")
  func pipelineUsesProjectTemplate() async throws {
    let (database, directory) = try makeCatalog()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = try CatalogConfiguration.backend(slug: "r2", in: database)
    let project = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "blog",
      keyTemplate: "{prefix}/{year}/{day}/{name}.{ext}", backendSlug: "r2", to: database)
    let image = directory.appendingPathComponent("Pixel Art.png")
    try Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!.write(to: image)

    let planned = try await UploadPipeline(database: database, backend: backend, project: project)
      .upload(fileURL: image, dryRun: true, date: august)
    #expect(planned.key == "blog/2026/20/pixel-art.png")
    let unscoped = try await UploadPipeline(database: database, backend: backend)
      .upload(fileURL: image, dryRun: true, date: august)
    #expect(unscoped.key == "202608/pixel-art-431ced6916a2.png")

    try await database.write { db in
      try db.execute(sql: "UPDATE project SET key_template = '{prefix}/{nope}.{ext}'")
    }
    let broken = try CatalogConfiguration.projects(in: database)[0]
    await #expect(
      throws: UploadPipelineError.invalidKeyTemplate(
        project: "blog",
        issues: [.init(code: .unknownPlaceholder, message: "Unknown placeholder {nope}.")])
    ) {
      try await UploadPipeline(database: database, backend: backend, project: broken)
        .upload(fileURL: image, dryRun: true, date: august)
    }
    #expect(
      UploadPipelineError.invalidKeyTemplate(
        project: "blog",
        issues: [.init(code: .unknownPlaceholder, message: "Unknown placeholder {nope}.")]
      ).description
        == "Can't build an object key for project 'blog': Unknown placeholder {nope}.")
  }

  // MARK: - Backups

  @Test("A backup without key_template restores as NULL; a new backup round-trips it")
  func backups() throws {
    let (source, sourceDirectory) = try makeCatalog()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    _ = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "blog", keyTemplate: "{prefix}/{name}.{ext}",
      backendSlug: "r2", to: source)
    _ = try CatalogConfiguration.addProject(
      slug: "notes", name: "Notes", keyPrefix: "", backendSlug: "r2", to: source)
    let backup = try CatalogBackups.create(from: source)
    #expect(backup.migrations.contains("v4_project_key_template"))

    let (fresh, freshDirectory) = try makeEmptyCatalog()
    defer { try? FileManager.default.removeItem(at: freshDirectory) }
    _ = try CatalogBackups.restore(
      try CatalogBackups.decode(try JSONEncoder().encode(backup)), into: fresh)
    #expect(try storedTemplate("blog", in: fresh) == "{prefix}/{name}.{ext}")
    #expect(try storedTemplate("notes", in: fresh) == nil)

    // As written before v4: no key_template key on any project row.
    var object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
    var tables = try #require(object["tables"] as? [String: Any])
    let projects = try #require(tables["projects"] as? [[String: Any]])
    #expect(projects.contains { $0["key_template"] as? String == "{prefix}/{name}.{ext}" })
    tables["projects"] = projects.map { row in
      var row = row
      row["key_template"] = nil
      return row
    }
    object["tables"] = tables
    object["migrations"] = ["v1_initial", "v2_favorite_label", "v3_pending_deletion"]
    let old = try CatalogBackups.decode(try JSONSerialization.data(withJSONObject: object))
    #expect(old.tables.projects.allSatisfy { $0.keyTemplate == nil })
    let (target, targetDirectory) = try makeEmptyCatalog()
    defer { try? FileManager.default.removeItem(at: targetDirectory) }
    _ = try CatalogBackups.restore(old, into: target)
    #expect(try storedTemplate("blog", in: target) == nil)
    #expect(try storedTemplate("notes", in: target) == nil)
  }

  private func makeEmptyCatalog() throws -> (database: DatabasePool, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-keytemplate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    return (database, directory)
  }
}
