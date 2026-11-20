import ArgumentParser
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing
@testable import pinax

/// Registering an old domain: `CatalogConfiguration`'s
/// add / remove / list, `pinax backend old-domain`, and Settings ▸ Backends'
/// Old Domains. Every expected value is written out by hand.
@MainActor @Suite struct OldDomainsTests {
  /// `r2` serves from https://img.example.com and has no retired prefix;
  /// `blog/asset-0.png` is in the catalog. `blog`'s one source has a.md:
  ///   img.example.com/blog/asset-0.png  current prefix, in the catalog
  ///   img.example.com/blog/gone.png     current prefix, not in the catalog
  ///   pub-old.r2.dev/blog/asset-0.png   the unregistered old domain, in the catalog
  ///   pub-old.r2.dev/blog/missing.png   the unregistered old domain, not in the catalog
  ///   elsewhere.example.org/x.png       a third party
  private func withFixture(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try """
    ![a](https://img.example.com/blog/asset-0.png)
    ![b](https://img.example.com/blog/gone.png)
    ![c](https://pub-old.r2.dev/blog/asset-0.png)
    ![d](https://pub-old.r2.dev/blog/missing.png)
    ![e](https://elsewhere.example.org/x.png)

    """.write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try CatalogConfiguration.setProjectSources(
      slug: "blog", [ProjectSource(label: "site", path: source.path)], in: database)
    try seedAsset(database, index: 0, uploadedAt: "2026-08-02T00:00:00Z")
    try await body(database)
  }

  /// Scan Now's two steps: scan the sources, sync the document.
  private func scan(_ database: DatabasePool) throws {
    let scan = try UsageScanner.scan(project: "blog", in: database)
    _ = try CatalogUsage.sync(scan.document, project: "blog", in: database)
  }

  /// The latest scan's references that resolved to an asset.
  private func resolved(_ database: DatabasePool) throws -> [String] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT u.raw_url FROM usage u JOIN project p ON p.id = u.project_id
          WHERE p.slug = 'blog' AND u.last_scan_id = p.last_scan_id AND u.asset_id IS NOT NULL
          ORDER BY u.raw_url
          """)
    }
  }

  private func halves(_ database: DatabasePool) async throws -> (yours: [String], other: [String]) {
    let set = try await CatalogUsage.externalReferences(project: "blog", in: database)
    return (
      set.references.filter { $0.domain == .yours }.map(\.rawURL),
      set.references.filter { $0.domain == .other }.map(\.rawURL)
    )
  }

  private func command<T: ParsableCommand>(_ arguments: [String], as _: T.Type) throws -> T {
    try #require(try Pinax.parseAsRoot(arguments) as? T)
  }

  /// The configuration error `body` throws, nil when it returns.
  private func failure(_ body: () throws -> String) -> CatalogConfigurationError? {
    do {
      _ = try body()
      return nil
    } catch {
      return error as? CatalogConfigurationError
    }
  }

  private func prefix(_ database: DatabasePool) throws -> String {
    try CatalogConfiguration.backend(slug: "r2", in: database).urlPrefix
  }

  // MARK: - The property: scan, register, scan, remove, scan

  @Test("Registering an old domain resolves its catalogued reference and moves the rest to Your Domains; removing it restores both")
  func registerAndRemove() async throws {
    try await withFixture { database async throws in
      try scan(database)
      #expect(try resolved(database) == ["https://img.example.com/blog/asset-0.png"])
      var split = try await halves(database)
      #expect(split.yours == ["https://img.example.com/blog/gone.png"])
      // In line order: a.md#L3, #L4, #L5.
      #expect(split.other == [
        "https://pub-old.r2.dev/blog/asset-0.png",
        "https://pub-old.r2.dev/blog/missing.png",
        "https://elsewhere.example.org/x.png",
      ])

      let add = try command(
        ["backend", "old-domain", "add", "r2", "https://pub-old.r2.dev/"], as: BackendOldDomainAdd.self)
      #expect(try add.output(in: database) == "https://pub-old.r2.dev")
      #expect(try prefix(database) == "https://img.example.com")
      try scan(database)
      #expect(try resolved(database) == [
        "https://img.example.com/blog/asset-0.png",
        "https://pub-old.r2.dev/blog/asset-0.png",
      ])
      split = try await halves(database)
      #expect(split.yours == [
        "https://img.example.com/blog/gone.png",
        "https://pub-old.r2.dev/blog/missing.png",
      ])
      #expect(split.other == ["https://elsewhere.example.org/x.png"])

      let remove = try command(
        ["backend", "old-domain", "rm", "r2", "https://pub-old.r2.dev"], as: BackendOldDomainRemove.self)
      #expect(try remove.output(in: database) == "https://pub-old.r2.dev")
      #expect(try prefix(database) == "https://img.example.com")
      try scan(database)
      #expect(try resolved(database) == ["https://img.example.com/blog/asset-0.png"])
      split = try await halves(database)
      #expect(split.yours == ["https://img.example.com/blog/gone.png"])
      #expect(split.other == [
        "https://pub-old.r2.dev/blog/asset-0.png",
        "https://pub-old.r2.dev/blog/missing.png",
        "https://elsewhere.example.org/x.png",
      ])
    }
  }

  // MARK: - The CLI's values

  @Test("pinax backend old-domain: ls lists oldest first, once each; add refuses the current prefix and non-URLs; rm refuses one not there")
  func commandLine() async throws {
    try await withFixture { database async throws in
      let list = try command(["backend", "old-domain", "ls", "r2"], as: BackendOldDomainList.self)
      #expect(try list.output(in: database) == "")
      for prefix in ["https://b.example.com", "https://a.example.com", "https://b.example.com/"] {
        let add = try command(["backend", "old-domain", "add", "r2", prefix], as: BackendOldDomainAdd.self)
        _ = try add.output(in: database)
      }
      #expect(try list.output(in: database) == "https://b.example.com\t0\nhttps://a.example.com\t0\n")
      let rows = try await database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backend_prefix_history")!
      }
      #expect(rows == 2)

      let current = try command(
        ["backend", "old-domain", "add", "r2", "https://img.example.com/"], as: BackendOldDomainAdd.self)
      #expect(failure { try current.output(in: database) } == CatalogConfigurationError.oldDomainIsCurrent("https://img.example.com"))
      let notURL = try command(
        ["backend", "old-domain", "add", "r2", "pub-old.r2.dev"], as: BackendOldDomainAdd.self)
      #expect(failure { try notURL.output(in: database) } == CatalogConfigurationError.invalidOldDomain("pub-old.r2.dev"))
      let missing = try command(
        ["backend", "old-domain", "rm", "r2", "https://c.example.com"], as: BackendOldDomainRemove.self)
      #expect(failure { try missing.output(in: database) } == CatalogConfigurationError.oldDomainNotFound(backend: "r2", prefix: "https://c.example.com"))
      let noBackend = try command(["backend", "old-domain", "ls", "s3"], as: BackendOldDomainList.self)
      #expect(failure { try noBackend.output(in: database) } == CatalogConfigurationError.backendNotFound("s3"))
      // A prefix `set-prefix` retired is an old domain too, and rm takes it.
      _ = try CatalogConfiguration.setBackendURLPrefix(
        slug: "r2", urlPrefix: "https://new.example.com", in: database)
      #expect(
        try list.output(in: database)
          == "https://b.example.com\t0\nhttps://a.example.com\t0\nhttps://img.example.com\t0\n")
      let retired = try command(
        ["backend", "old-domain", "rm", "r2", "https://img.example.com"], as: BackendOldDomainRemove.self)
      _ = try retired.output(in: database)
      #expect(try list.output(in: database) == "https://b.example.com\t0\nhttps://a.example.com\t0\n")
      #expect(try prefix(database) == "https://new.example.com")
    }
  }

  // MARK: - Settings ▸ Backends

  @Test("Settings ▸ Backends: the form holds Old Domains; + and − change the list, never the URL prefix; a refusal is shown")
  func settingsForm() async throws {
    try await withFixture { database async throws in
      let keychain = Keychain(service: "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)")
      let model = BackendsModel(reader: CatalogBackendsReader(database: database, keychain: keychain))
      await model.load()
      #expect(model.details?.oldDomains == [])
      #expect(model.canEditOldDomains)

      let editors = collectViews(BackendsSettingsContent(model: model).body, as: BackendDomainsSection.self)
      // Met once per settings card container the page sits in (stored and in its body).
      #expect(Set(editors.map(\.details.slug)) == ["r2"])

      await model.addOldDomain("https://pub-old.r2.dev/")
      #expect(model.details?.oldDomains == ["https://pub-old.r2.dev"])
      #expect(model.details?.urlPrefix == "https://img.example.com")
      #expect(model.oldDomainError == nil)
      let shown = collectViews(BackendsSettingsContent(model: model).body, as: BackendDomainsSection.self)
      #expect(Set(shown.map(\.details.oldDomains)) == [["https://pub-old.r2.dev"]])

      await model.addOldDomain("https://img.example.com")
      #expect(model.oldDomainError == "'https://img.example.com' is the backend's current URL prefix.")
      #expect(model.details?.oldDomains == ["https://pub-old.r2.dev"])

      await model.removeOldDomain("https://pub-old.r2.dev")
      #expect(model.details?.oldDomains == [])
      #expect(model.oldDomainError == nil)
      #expect(try prefix(database) == "https://img.example.com")
    }
  }
}
