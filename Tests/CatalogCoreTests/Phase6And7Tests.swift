import CatalogCore
import Foundation
import GRDB
import Testing

@Test("Manifest export follows the checked-in v1 schema and tag changes are idempotent")
func manifestAndTags() throws {
  try withPhaseSevenCatalog { database in
    try CatalogAssets.addTag(" hero ", to: "111111", in: database)
    try CatalogAssets.addTag("hero", to: "111111", in: database)
    #expect(try CatalogAssets.details("111111", in: database).tags == ["hero"])
    try CatalogAssets.removeTag("hero", from: "111111", in: database)
    #expect(try CatalogAssets.details("111111", in: database).tags.isEmpty)

    let manifest = try CatalogManifest.export(
      project: "blog",
      from: database,
      generatedAt: Date(timeIntervalSince1970: 1_787_184_000)
    )
    let json = try manifest.json()
    let root = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    let schemaURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Schemas/pinax-manifest-v1.schema.json")
    let schema = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
    )
    #expect(validateJSON(root, against: schema).isEmpty)
    var invalidRoot = root
    invalidRoot["internal_id"] = 1
    #expect(!validateJSON(invalidRoot, against: schema).isEmpty)
    var invalidAssetRoot = root
    var invalidAssets = try #require(invalidAssetRoot["assets"] as? [[String: Any]])
    invalidAssets[0]["sha256"] = "not-a-sha256"
    invalidAssetRoot["assets"] = invalidAssets
    #expect(!validateJSON(invalidAssetRoot, against: schema).isEmpty)
    #expect(root["schema"] as? Int == 1)
    #expect(root["generated_at"] as? String == "2026-08-20T00:00:00Z")
    #expect(root["project"] as? String == "blog")
    let backend = try #require(root["backend"] as? [String: Any])
    #expect(Set(backend.keys) == ["slug", "url_prefix"])
    #expect(backend["slug"] as? String == "r2")
    let assets = try #require(root["assets"] as? [[String: Any]])
    #expect(assets.count == 3)
    #expect(assets.allSatisfy { $0["id"] == nil && $0["backend_id"] == nil })
    #expect(assets.allSatisfy { ($0["sha256"] as? String)?.count == 64 })
    let urlsByKey: [String: String] = Dictionary(
      uniqueKeysWithValues: assets.compactMap { asset in
        guard let key = asset["key"] as? String, let url = asset["url"] as? String else {
          return nil
        }
        return (key, url)
      }
    )
    #expect(urlsByKey["blog/orphan.png"] == "https://archive.example.com/blog/orphan.png")
    #expect(assets.allSatisfy { $0["key"] as? String != "blog/archived.png" })
  }
}

@Test("Usage decoding defaults optional arrays and reports contract errors")
func usageDocumentDecoding() throws {
  let minimal = Data(#"{"schema":1,"project":"blog"}"#.utf8)
  let document = try JSONDecoder().decode(UsageDocument.self, from: minimal)
  #expect(document.coverage.isEmpty)
  #expect(document.refs.isEmpty)

  #expect(throws: UsageCatalogError.unsupportedSchema(2)) {
    try JSONDecoder().decode(
      UsageDocument.self,
      from: Data(#"{"schema":2,"project":"blog"}"#.utf8)
    )
  }
  #expect(throws: UsageCatalogError.invalidDocumentField("project")) {
    try JSONDecoder().decode(
      UsageDocument.self,
      from: Data(#"{"schema":1}"#.utf8)
    )
  }
  #expect(throws: UsageCatalogError.invalidDocumentField("refs[0].raw_url")) {
    try JSONDecoder().decode(
      UsageDocument.self,
      from: Data(
        #"{"schema":1,"project":"blog","refs":[{"source_ref":"post.md","kind":"markdown"}]}"#.utf8)
    )
  }
}

@Test("An empty scan after a nonempty scan requires an explicit override")
func emptyUsageScanGuard() throws {
  try withPhaseSevenCatalog { database in
    let first = UsageDocument(
      project: "blog",
      refs: [
        UsageReference(
          rawURL: "https://img.example.com/blog/used.png",
          sourceReference: "post.md"
        )
      ]
    )
    let firstResult = try CatalogUsage.sync(
      first,
      project: "blog",
      in: database,
      now: Date(timeIntervalSince1970: 1_787_184_000)
    )
    #expect(throws: UsageCatalogError.emptyScanRejected(previousFoundCount: 1)) {
      try CatalogUsage.sync(
        UsageDocument(project: "blog", refs: []),
        project: "blog",
        in: database,
        now: Date(timeIntervalSince1970: 1_787_184_060)
      )
    }
    #expect(try database.read { try Scan.fetchCount($0) } == 1)
    #expect(
      try database.read { try Project.fetchOne($0, key: 1)?.lastScanID } == firstResult.scanID)

    let emptyResult = try CatalogUsage.sync(
      UsageDocument(project: "blog", refs: []),
      project: "blog",
      in: database,
      now: Date(timeIntervalSince1970: 1_787_184_120),
      allowEmpty: true
    )
    #expect(emptyResult.foundCount == 0)
    #expect(try CatalogUsage.report(project: "blog", in: database).items.isEmpty)
  }
}

@Test("Usage report returns an empty contract before the first scan")
func usageReportBeforeFirstScan() throws {
  try withPhaseSevenCatalog { database in
    let report = try CatalogUsage.report(project: "blog", in: database)
    #expect(!report.hasCompletedScan)
    #expect(report.items.isEmpty)
    let root = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
    )
    #expect(Set(root.keys) == ["schema", "project", "items"])
    #expect(root["schema"] as? Int == 1)
    #expect(root["project"] as? String == "blog")
    #expect((root["items"] as? [Any])?.isEmpty == true)
  }
}

@Test("Identical usage sync is idempotent and advances last_seen")
func usageSyncIsIdempotent() throws {
  try withPhaseSevenCatalog { database in
    let first = Date(timeIntervalSince1970: 1_787_184_000)
    let second = first.addingTimeInterval(60)
    let document = UsageDocument(
      project: "blog",
      sourceRevision: "abc",
      coverage: ["content/**/*.md"],
      refs: [
        UsageReference(
          rawURL: "https://img.example.com/blog/used.png",
          sourceReference: "post.md#L1"
        ),
        UsageReference(
          rawURL: "https://external.example/legacy.png",
          sourceReference: "post.md#L2"
        ),
      ]
    )
    _ = try CatalogUsage.sync(document, project: "blog", in: database, now: first)
    let initial = try usageSnapshot(database)
    _ = try CatalogUsage.sync(document, project: "blog", in: database, now: second)
    let updated = try usageSnapshot(database)

    #expect(initial.count == 2)
    #expect(updated.count == 2)
    #expect(updated.map(\.firstSeen) == initial.map(\.firstSeen))
    #expect(updated.allSatisfy { $0.lastSeen == "2026-08-20T00:01:00Z" })
    #expect(try CatalogUsage.report(project: "blog", in: database).items.count == 2)
    let externals = try CatalogUsage.externals(project: "blog", in: database)
    #expect(externals.map(\.rawURL) == ["https://external.example/legacy.png"])
  }
}

@Test("Dropped references become non-live but remain stored")
func droppedUsageBecomesNonLive() throws {
  try withPhaseSevenCatalog { database in
    let first = UsageDocument(
      project: "blog",
      refs: [
        UsageReference(
          rawURL: "https://img.example.com/blog/used.png",
          sourceReference: "post.md#L1"
        ),
        UsageReference(
          rawURL: "https://external.example/legacy.png",
          sourceReference: "post.md#L2"
        ),
      ]
    )
    _ = try CatalogUsage.sync(
      first,
      project: "blog",
      in: database,
      now: Date(timeIntervalSince1970: 1_787_184_000)
    )
    _ = try CatalogUsage.sync(
      UsageDocument(project: "blog", refs: Array(first.refs.prefix(1))),
      project: "blog",
      in: database,
      now: Date(timeIntervalSince1970: 1_787_184_060)
    )
    #expect(try database.read { try Usage.fetchCount($0) } == 2)
    #expect(try CatalogUsage.report(project: "blog", in: database).items.count == 1)
    #expect(try CatalogUsage.externals(project: "blog", in: database).isEmpty)
  }
}

@Test("A failed usage ingest rolls back its scan and project pointer")
func failedUsageSyncRollsBack() throws {
  try withPhaseSevenCatalog { database in
    let initial = UsageDocument(
      project: "blog",
      refs: [UsageReference(rawURL: "https://img.example.com/blog/used.png", sourceReference: "ok")]
    )
    let first = try CatalogUsage.sync(
      initial,
      project: "blog",
      in: database,
      now: Date(timeIntervalSince1970: 1_787_184_000)
    )
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER reject_test_usage BEFORE INSERT ON usage
          WHEN NEW.source_ref = 'throw'
          BEGIN SELECT RAISE(ABORT, 'test failure'); END
          """
      )
    }
    let failing = UsageDocument(
      project: "blog",
      refs: [
        UsageReference(rawURL: "https://img.example.com/blog/used.png", sourceReference: "new"),
        UsageReference(rawURL: "https://img.example.com/blog/orphan.png", sourceReference: "throw"),
      ]
    )
    #expect(throws: (any Error).self) {
      _ = try CatalogUsage.sync(
        failing,
        project: "blog",
        in: database,
        now: Date(timeIntervalSince1970: 1_787_184_060)
      )
    }
    let state = try database.read { db in
      (
        try Project.fetchOne(db, key: 1)?.lastScanID,
        try Scan.fetchCount(db),
        try Usage.fetchCount(db)
      )
    }
    #expect(state.0 == first.scanID)
    #expect(state.1 == 1)
    #expect(state.2 == 1)
  }
}

@Test("Orphans exclude pinned and live assets after the minimum scan count")
func orphanReportIsConservative() throws {
  try withPhaseSevenCatalog { database in
    let document = UsageDocument(
      project: "blog",
      refs: [
        UsageReference(rawURL: "https://img.example.com/blog/used.png", sourceReference: "post.md")
      ]
    )
    _ = try CatalogUsage.sync(
      document,
      project: "blog",
      in: database,
      now: Date(timeIntervalSince1970: 1_787_184_000)
    )
    var report = try CatalogUsage.orphans(project: "blog", minimumScans: 2, in: database)
    #expect(report.unscannedProjects == ["blog"])
    #expect(report.assets.map(\.asset.key) == ["blog/orphan.png"])
    _ = try CatalogUsage.sync(
      document,
      project: "blog",
      in: database,
      now: Date(timeIntervalSince1970: 1_787_184_060)
    )
    report = try CatalogUsage.orphans(project: "blog", minimumScans: 2, in: database)
    #expect(report.unscannedProjects.isEmpty)
    #expect(report.assets.map(\.asset.key) == ["blog/orphan.png"])
  }
}

private struct UsageSnapshot {
  let firstSeen: String
  let lastSeen: String
}

private func usageSnapshot(_ database: CatalogDatabasePool) throws -> [UsageSnapshot] {
  try database.read { db in
    try Row.fetchAll(
      db,
      sql: "SELECT first_seen, last_seen FROM usage ORDER BY source_ref"
    ).map { UsageSnapshot(firstSeen: $0["first_seen"], lastSeen: $0["last_seen"]) }
  }
}

private func validateJSON(
  _ value: Any,
  against schema: [String: Any],
  path: String = "$"
) -> [String] {
  var errors: [String] = []
  if let expected = schema["const"] as? NSNumber {
    guard let actual = value as? NSNumber, actual == expected else {
      return ["\(path) does not match const"]
    }
  }
  if let type = schema["type"] as? String {
    let matches: Bool
    switch type {
    case "object": matches = value is [String: Any]
    case "array": matches = value is [Any]
    case "string": matches = value is String
    case "integer":
      matches = (value as? NSNumber).map { $0.doubleValue.rounded() == $0.doubleValue } ?? false
    default: matches = true
    }
    if !matches { return ["\(path) is not \(type)"] }
  }

  if let object = value as? [String: Any] {
    let properties = schema["properties"] as? [String: Any] ?? [:]
    let required = Set(schema["required"] as? [String] ?? [])
    for key in required where object[key] == nil {
      errors.append("\(path).\(key) is required")
    }
    if schema["additionalProperties"] as? Bool == false {
      for key in object.keys where properties[key] == nil {
        errors.append("\(path).\(key) is not allowed")
      }
    }
    for (key, child) in object {
      guard let childSchema = properties[key] as? [String: Any] else { continue }
      errors += validateJSON(child, against: childSchema, path: "\(path).\(key)")
    }
  }

  if let array = value as? [Any], let itemSchema = schema["items"] as? [String: Any] {
    for (index, child) in array.enumerated() {
      errors += validateJSON(child, against: itemSchema, path: "\(path)[\(index)]")
    }
  }

  if let string = value as? String {
    if let minimum = schema["minLength"] as? Int, string.count < minimum {
      errors.append("\(path) is shorter than \(minimum)")
    }
    if let pattern = schema["pattern"] as? String,
      string.range(of: pattern, options: .regularExpression) == nil
    {
      errors.append("\(path) does not match \(pattern)")
    }
    if let format = schema["format"] as? String {
      switch format {
      case "date-time":
        if ISO8601DateFormatter().date(from: string) == nil {
          errors.append("\(path) is not a date-time")
        }
      case "uri":
        let components = URLComponents(string: string)
        if components?.scheme == nil || components?.host == nil {
          errors.append("\(path) is not a URI")
        }
      default:
        break
      }
    }
  }

  if let number = value as? NSNumber, let minimum = schema["minimum"] as? NSNumber,
    number.compare(minimum) == .orderedAscending
  {
    errors.append("\(path) is less than \(minimum)")
  }
  return errors
}

private func withPhaseSevenCatalog(
  _ body: (CatalogDatabasePool) throws -> Void
) throws {
  let (database, directory) = try makePhaseSevenCatalog()
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(database)
}

private func withPhaseSevenCatalogAsync(
  _ body: (CatalogDatabasePool) async throws -> Void
) async throws {
  let (database, directory) = try makePhaseSevenCatalog()
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(database)
}

private func makePhaseSevenCatalog() throws -> (
  database: CatalogDatabasePool, directory: URL
) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  try database.write { db in
    try db.execute(
      sql: """
        INSERT INTO backend
          (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, created_at, updated_at)
        VALUES
          (1, 'r2', 's3', 'https://storage.example.com', 'images', 'auto',
           'https://img.example.com', 'backend.r2', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
          (2, 'archive', 's3', 'https://archive-storage.example.com', 'archive', 'auto',
           'https://archive.example.com', 'backend.archive', '2026-08-01T00:00:00Z',
           '2026-08-01T00:00:00Z');
        INSERT INTO project
          (id, slug, name, key_prefix, backend_id, created_at, updated_at)
        VALUES
          (1, 'blog', 'Blog', 'blog', 1, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        INSERT INTO asset
          (id, sha256, backend_id, key, byte_size, width, height, mime, orig_filename,
           state, pinned, uploaded_at, created_at, updated_at)
        VALUES
          (1, '1111111111111111111111111111111111111111111111111111111111111111', 1,
           'blog/used.png', 10, 1, 1, 'image/png', 'used.png', 'active', 0,
           '2026-08-10T00:00:00Z', '2026-08-10T00:00:00Z', '2026-08-10T00:00:00Z'),
          (2, '2222222222222222222222222222222222222222222222222222222222222222', 2,
           'blog/orphan.png', 20, 2, 2, 'image/png', 'orphan.png', 'active', 0,
           '2026-08-11T00:00:00Z', '2026-08-11T00:00:00Z', '2026-08-11T00:00:00Z'),
          (3, '3333333333333333333333333333333333333333333333333333333333333333', 1,
           'blog/pinned.png', 30, 3, 3, 'image/png', 'pinned.png', 'active', 1,
           '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z'),
          (4, '4444444444444444444444444444444444444444444444444444444444444444', 1,
           'blog/archived.png', 40, 4, 4, 'image/png', 'archived.png', 'archived', 0,
           '2026-08-13T00:00:00Z', '2026-08-13T00:00:00Z', '2026-08-13T00:00:00Z');
        INSERT INTO asset_project (asset_id, project_id, added_at)
        VALUES
          (1, 1, '2026-08-10T00:00:00Z'),
          (2, 1, '2026-08-11T00:00:00Z'),
          (3, 1, '2026-08-12T00:00:00Z'),
          (4, 1, '2026-08-13T00:00:00Z');
        """
    )
  }
  return (database, directory)
}

@Test("Async usage reads match their synchronous siblings")
func asyncUsageReadsMatchSync() async throws {
  try await withPhaseSevenCatalogAsync { database in
    let document = UsageDocument(
      project: "blog",
      refs: [
        UsageReference(rawURL: "https://img.example.com/blog/used.png", sourceReference: "post.md"),
        UsageReference(rawURL: "https://cdn.other.example.com/cover.png", sourceReference: "post.md"),
      ]
    )
    _ = try CatalogUsage.sync(
      document,
      project: "blog",
      in: database,
      now: Date(timeIntervalSince1970: 1_787_184_000)
    )

    // The immediately-invoked closures pin the synchronous overloads; in an
    // async context Swift would otherwise silently prefer the async siblings.
    let syncReport = try { try CatalogUsage.report(project: "blog", in: database) }()
    let asyncReport = try await CatalogUsage.report(project: "blog", in: database)
    #expect(asyncReport == syncReport)
    #expect(asyncReport.items.count == 2)
    #expect(asyncReport.items.filter { $0.sha256 == nil }.count == 1)

    let syncOrphans = try {
      try CatalogUsage.orphans(project: "blog", minimumScans: 2, in: database)
    }()
    let asyncOrphans = try await CatalogUsage.orphans(
      project: "blog", minimumScans: 2, in: database
    )
    #expect(asyncOrphans.assets.map(\.asset.key) == syncOrphans.assets.map(\.asset.key))
    #expect(asyncOrphans.unscannedProjects == syncOrphans.unscannedProjects)
    #expect(asyncOrphans.assets.map(\.asset.key) == ["blog/orphan.png"])
  }
}
