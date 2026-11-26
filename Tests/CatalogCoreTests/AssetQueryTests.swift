import CatalogCore
import Foundation
import GRDB
import Testing

private func makeQueryDatabase() throws -> (database: DatabasePool, directory: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  try database.write { db in
    try db.execute(
      sql: """
        INSERT INTO backend
          (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
           created_at, updated_at)
        VALUES
          (1, 'r2', 's3', 'https://storage.example.com', 'images', 'auto',
           'https://img.example.com', 'backend.r2', '{}',
           '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        INSERT INTO project
          (id, slug, name, key_prefix, backend_id, created_at, updated_at)
        VALUES
          (1, 'blog', 'Blog', 'blog', 1, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
          (2, 'never-scanned', 'Never Scanned', 'ns', 1,
           '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        """
    )
  }
  return (database, directory)
}

private func withQueryDatabase(_ body: (DatabasePool) throws -> Void) throws {
  let (database, directory) = try makeQueryDatabase()
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(database)
}

private func withQueryDatabase(_ body: (DatabasePool) async throws -> Void) async throws {
  let (database, directory) = try makeQueryDatabase()
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(database)
}

private func insertAsset(
  _ db: GRDB.Database,
  index: Int,
  uploadedAt: String,
  origFilename: String? = nil,
  note: String? = nil,
  state: String = "active",
  projectID: Int64? = 1
) throws {
  let sha = String(format: "%064x", index + 1)
  var asset = Asset(
    sha256: sha,
    backendID: 1,
    key: "blog/asset-\(index).png",
    byteSize: Int64(100 + index),
    width: index,
    height: index * 2,
    mime: "image/png",
    originalFilename: origFilename ?? "asset-\(index).png",
    state: state,
    note: note,
    uploadedAt: uploadedAt,
    createdAt: uploadedAt,
    updatedAt: uploadedAt
  )
  try asset.insert(db)
  if let projectID {
    try db.execute(
      sql: """
        INSERT INTO asset_project (asset_id, project_id, added_at)
        SELECT id, ?, ? FROM asset WHERE sha256 = ?
        """,
      arguments: [projectID, uploadedAt, sha]
    )
  }
}

private func pageThrough(_ database: DatabasePool, query: AssetQuery) throws -> [AssetPage] {
  var pages: [AssetPage] = []
  var cursor = query.after
  var guardCounter = 0
  repeat {
    var step = query
    step.after = cursor
    let page = try CatalogAssets.page(step, in: database)
    pages.append(page)
    cursor = page.next
    guardCounter += 1
    if guardCounter > 100 { break }
  } while cursor != nil
  return pages
}

private func syncPage(_ query: AssetQuery, in database: DatabasePool) throws -> AssetPage {
  try CatalogAssets.page(query, in: database)
}

private func syncDetails(_ identifier: String, in database: DatabasePool) throws
  -> CatalogAssetDetails
{
  try CatalogAssets.details(identifier, in: database)
}

@Suite struct AssetQueryTests {
  @Test("Pagination over 250 assets with limit 100 matches an unpaginated fetch")
  func paginationConcatenation() throws {
    try withQueryDatabase { database in
      try database.write { db in
        for index in 0..<250 {
          let day = String(format: "%02d", 1 + index % 5)
          try insertAsset(db, index: index, uploadedAt: "2026-08-\(day)T12:00:00Z")
        }
      }
      var query = AssetQuery()
      query.limit = 100
      let pages = try pageThrough(database, query: query)

      #expect(pages.count == 3)
      #expect(pages[0].items.count == 100)
      #expect(pages[1].items.count == 100)
      #expect(pages[2].items.count == 50)
      #expect(pages[2].next == nil)

      let pagedKeys = pages.flatMap(\.items).map(\.asset.key)
      #expect(Set(pagedKeys).count == 250)
      var unpaginated = AssetQuery()
      unpaginated.limit = 250
      let allKeys = try syncPage(unpaginated, in: database).items.map(\.asset.key)
      #expect(pagedKeys == allKeys)
    }
  }

  @Test("All assets sharing one uploaded_at paginate through the tie without loss or duplication")
  func paginationFullTie() throws {
    try withQueryDatabase { database in
      try database.write { db in
        for index in 0..<250 {
          try insertAsset(db, index: index, uploadedAt: "2026-08-20T12:00:00Z")
        }
      }
      var query = AssetQuery()
      query.limit = 100
      let pages = try pageThrough(database, query: query)
      #expect(pages.count == 3)
      let keys = pages.flatMap(\.items).map(\.asset.key)
      #expect(Set(keys).count == 250)
      #expect(keys.count == 250)
      #expect(pages.last?.next == nil)
    }
  }

  @Test("An asset inserted mid-pagination never reappears in later pages")
  func insertionDuringIteration() throws {
    try withQueryDatabase { database in
      try database.write { db in
        for index in 0..<30 {
          try insertAsset(db, index: index, uploadedAt: "2026-08-\(String(format: "%02d", 1 + index % 3))T12:00:00Z")
        }
      }
      var query = AssetQuery()
      query.limit = 10
      let firstPage = try CatalogAssets.page(query, in: database)
      #expect(firstPage.items.count == 10)
      let seen = Set(firstPage.items.map(\.asset.id))

      try database.write { db in
        try insertAsset(db, index: 999, uploadedAt: "2026-09-01T12:00:00Z")
      }

      var cursor = firstPage.next
      var rest: [CatalogCore.Asset] = []
      while let next = cursor {
        query.after = next
        let page = try CatalogAssets.page(query, in: database)
        rest.append(contentsOf: page.items.map(\.asset))
        cursor = page.next
      }
      let restIDs = rest.compactMap(\.id)
      #expect(restIDs.count == 20)
      #expect(restIDs.allSatisfy { !seen.contains($0) })
      #expect(!rest.contains { $0.key == "blog/asset-999.png" })
    }
  }

  @Test("Search matches CJK filenames and does not treat % or _ as wildcards")
  func searchEscaping() throws {
    try withQueryDatabase { database in
      try database.write { db in
        try insertAsset(db, index: 0, uploadedAt: "2026-08-20T12:00:00Z", origFilename: "截图 2026年8月.png")
        try insertAsset(db, index: 1, uploadedAt: "2026-08-21T12:00:00Z", origFilename: "100%_test.png")
        try insertAsset(db, index: 2, uploadedAt: "2026-08-22T12:00:00Z", origFilename: "plain.png", note: "has 50% discount")
        try insertAsset(db, index: 3, uploadedAt: "2026-08-23T12:00:00Z", origFilename: "under_score.png")
      }

      var cjk = AssetQuery()
      cjk.search = "截图"
      let cjkResults = try CatalogAssets.page(cjk, in: database).items
      #expect(cjkResults.count == 1)
      #expect(cjkResults.first?.asset.originalFilename == "截图 2026年8月.png")

      var percent = AssetQuery()
      percent.search = "%"
      let percentResults = try CatalogAssets.page(percent, in: database).items
      #expect(percentResults.map(\.asset.key).sorted() == ["blog/asset-1.png", "blog/asset-2.png"])

      var underscore = AssetQuery()
      underscore.search = "_test"
      let underscoreResults = try CatalogAssets.page(underscore, in: database).items
      #expect(underscoreResults.count == 1)
      #expect(underscoreResults.first?.asset.key == "blog/asset-1.png")

      var byKey = AssetQuery()
      byKey.search = "ASSET-0"
      let keyResults = try CatalogAssets.page(byKey, in: database).items
      #expect(keyResults.count == 1)
      #expect(keyResults.first?.asset.key == "blog/asset-0.png")
    }
  }

  @Test("projectSummaries reports a never-scanned project with nil lastScanAt")
  func projectSummariesNeverScanned() throws {
    try withQueryDatabase { database in
      try database.write { db in
        try insertAsset(db, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
        try db.execute(
          sql: """
            INSERT INTO scan (id, project_id, started_at, finished_at, found_count)
            VALUES (7, 1, '2026-08-25T10:00:00Z', '2026-08-25T10:01:00Z', 1);
            UPDATE project SET last_scan_id = 7 WHERE id = 1;
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            VALUES
              (1, 1, 'https://img.example.com/a0.png', 'post.md', 'markdown',
               '2026-08-25T10:00:00Z', '2026-08-25T10:01:00Z', 7);
            """
        )
      }
      let summaries = try CatalogConfiguration.projectSummaries(in: database)
      #expect(summaries.count == 2)

      let scanned = summaries.first { $0.slug == "blog" }
      #expect(scanned?.assetCount == 1)
      #expect(scanned?.liveUsageCount == 1)
      #expect(scanned?.lastScanAt == "2026-08-25T10:00:00Z")

      let neverScanned = summaries.first { $0.slug == "never-scanned" }
      #expect(neverScanned?.assetCount == 0)
      #expect(neverScanned?.liveUsageCount == 0)
      #expect(neverScanned?.lastScanAt == nil)
    }
  }

  @Test("tagSummaries and availableMonths report counts and months newest first")
  func tagAndMonthSummaries() throws {
    try withQueryDatabase { database in
      try database.write { db in
        try insertAsset(db, index: 0, uploadedAt: "2026-07-05T12:00:00Z")
        try insertAsset(db, index: 1, uploadedAt: "2026-08-15T12:00:00Z")
        try insertAsset(db, index: 2, uploadedAt: "2026-08-16T12:00:00Z")
        try db.execute(sql: "INSERT INTO tag (name) VALUES ('hero')")
        try db.execute(sql: "INSERT INTO tag (name) VALUES ('wide')")
        try db.execute(
          sql: """
            INSERT INTO asset_tag (asset_id, tag_id)
            SELECT 1, id FROM tag WHERE name = 'hero';
            INSERT INTO asset_tag (asset_id, tag_id)
            SELECT 2, id FROM tag WHERE name = 'wide';
            INSERT INTO asset_tag (asset_id, tag_id)
            SELECT 3, id FROM tag WHERE name = 'wide';
            """
        )
      }
      let tags = try CatalogAssets.tagSummaries(in: database)
      #expect(tags == [
        TagSummary(name: "hero", assetCount: 1),
        TagSummary(name: "wide", assetCount: 2),
      ])

      let months = try CatalogAssets.availableMonths(in: database)
      #expect(months.count == 2)
      #expect(months[0].month == "2026-08" && months[0].count == 2)
      #expect(months[1].month == "2026-07" && months[1].count == 1)
    }
  }

  @Test("Async overloads return the same results as their synchronous siblings")
  func asyncOverloads() async throws {
    func seed(_ database: DatabasePool) throws {
      try database.write { db in
        for index in 0..<25 {
          try insertAsset(db, index: index, uploadedAt: "2026-08-\(String(format: "%02d", 1 + index % 5))T12:00:00Z")
        }
      }
    }
    try await withQueryDatabase { database in
      try seed(database)
      var query = AssetQuery()
      query.limit = 10
      let expectedPage = try syncPage(query, in: database)
      let asyncPage = try await CatalogAssets.page(query, in: database)
      #expect(expectedPage.next == asyncPage.next)
      #expect(expectedPage.items.map(\.asset.key) == asyncPage.items.map(\.asset.key))

      let identifier = asyncPage.items[0].asset.sha256
      let expectedDetails = try syncDetails(identifier, in: database)
      let asyncDetails = try await CatalogAssets.details(identifier, in: database)
      #expect(expectedDetails.item.asset.key == asyncDetails.item.asset.key)

      let asyncTags = try await CatalogAssets.tagSummaries(in: database)
      #expect(asyncTags.isEmpty)
      let asyncSummaries = try await CatalogConfiguration.projectSummaries(in: database)
      #expect(asyncSummaries.count == 2)
    }
  }

  @Test("Filters compose: state, since/until, project, and cursor work together")
  func filterComposition() throws {
    try withQueryDatabase { database in
      try database.write { db in
        for index in 0..<40 {
          let day = String(format: "%02d", 1 + index % 4)
          try insertAsset(
            db, index: index,
            uploadedAt: "2026-08-\(day)T12:00:00Z",
            state: index % 2 == 0 ? "active" : "archived"
          )
        }
      }
      var query = AssetQuery()
      query.state = .archived
      query.since = "2026-08-02T00:00:00Z"
      query.until = "2026-08-03T00:00:00Z"
      query.limit = 5

      let pages = try pageThrough(database, query: query)
      let items = pages.flatMap(\.items)
      #expect(items.count == 10)
      #expect(items.allSatisfy { $0.asset.state == "archived" })
      #expect(items.allSatisfy {
        $0.asset.uploadedAt.prefix(10) == "2026-08-02"
      })

      var projected = AssetQuery()
      projected.project = "nonexistent"
      let empty = try CatalogAssets.page(projected, in: database)
      #expect(empty.items.isEmpty && empty.next == nil)
    }
  }

  @Test("Total exactly divisible by limit ends on a full page without an empty trailing page")
  func paginationExactMultiple() throws {
    try withQueryDatabase { database in
      try database.write { db in
        for index in 0..<200 {
          let day = String(format: "%02d", 1 + index % 5)
          try insertAsset(db, index: index, uploadedAt: "2026-08-\(day)T12:00:00Z")
        }
      }
      var query = AssetQuery()
      query.limit = 100
      let pages = try pageThrough(database, query: query)
      #expect(pages.count == 2)
      #expect(pages[0].items.count == 100)
      #expect(pages[0].next != nil)
      #expect(pages[1].items.count == 100)
      #expect(pages[1].next == nil)
    }
  }

  @Test("since is inclusive and until is exclusive at exact timestamp boundaries")
  func sinceUntilBoundaries() throws {
    try withQueryDatabase { database in
      try database.write { db in
        try insertAsset(db, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
        try insertAsset(db, index: 1, uploadedAt: "2026-09-01T00:00:00Z")
        try insertAsset(db, index: 2, uploadedAt: "2026-08-15T00:00:00Z")
      }
      var query = AssetQuery()
      query.since = "2026-08-01T00:00:00Z"
      query.until = "2026-09-01T00:00:00Z"
      let keys = try CatalogAssets.page(query, in: database).items.map(\.asset.key)
      #expect(keys == ["blog/asset-2.png", "blog/asset-0.png"])
    }
  }

  @Test("availableMonths scopes counts to the given query")
  func availableMonthsScoped() throws {
    try withQueryDatabase { database in
      try database.write { db in
        try insertAsset(db, index: 0, uploadedAt: "2026-07-05T12:00:00Z")
        try insertAsset(db, index: 1, uploadedAt: "2026-08-15T12:00:00Z")
        try db.execute(
          sql: """
            INSERT INTO project (id, slug, name, key_prefix, backend_id, created_at, updated_at)
            VALUES (3, 'notes', 'Notes', 'notes', 1,
                    '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
            INSERT INTO asset
              (id, sha256, backend_id, key, byte_size, mime, orig_filename, state, meta,
               uploaded_at, created_at, updated_at)
            VALUES
              (99, '\(String(repeating: "f", count: 64))', 1, 'notes/only.png', 10,
               'image/png', 'only.png', 'active', '{}',
               '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z');
            INSERT INTO asset_project (asset_id, project_id, added_at) VALUES (99, 3, '2026-07-01T00:00:00Z');
            INSERT INTO tag (id, name) VALUES (1, 'hero');
            INSERT INTO asset_tag (asset_id, tag_id) VALUES (1, 1);
            """
        )
      }
      let allMonths = try CatalogAssets.availableMonths(in: database)
      #expect(allMonths.map(\.month) == ["2026-08", "2026-07"])
      #expect(allMonths.map(\.count) == [1, 2])

      var notesOnly = AssetQuery()
      notesOnly.project = "notes"
      let noteMonths = try CatalogAssets.availableMonths(in: database, matching: notesOnly)
      #expect(noteMonths.map(\.month) == ["2026-07"])
      #expect(noteMonths.map(\.count) == [1])

      var tagged = AssetQuery()
      tagged.tag = "hero"
      let tagMonths = try CatalogAssets.availableMonths(in: database, matching: tagged)
      #expect(tagMonths.map(\.month) == ["2026-07"])
      #expect(tagMonths.map(\.count) == [1])

      var searchNothing = AssetQuery()
      searchNothing.search = "zzz-no-match"
      #expect(try CatalogAssets.availableMonths(in: database, matching: searchNothing).isEmpty)
    }
  }

  @Test("Search scopes narrow matching to their one column; .any keeps the CLI behaviour")
  func searchScopesMatchOneColumn() throws {
    try withQueryDatabase { database in
      try database.write { db in
        // Each asset matches "poster" in exactly one column: filename, key, note.
        try insertAsset(
          db, index: 0, uploadedAt: "2026-08-01T00:00:00Z",
          origFilename: "poster.png")
        try insertAsset(
          db, index: 1, uploadedAt: "2026-08-02T00:00:00Z",
          origFilename: "unrelated.png")
        try db.execute(
          sql: """
            UPDATE asset SET key = 'blog/poster.png'
            WHERE sha256 = '\(String(format: "%064x", 2))'
            """
        )
        try insertAsset(
          db, index: 2, uploadedAt: "2026-08-03T00:00:00Z",
          origFilename: "unrelated.png", note: "poster draft")
      }

      func keys(_ field: SearchField) throws -> [String] {
        var query = AssetQuery()
        query.search = "poster"
        query.searchField = field
        return try CatalogAssets.page(query, in: database).items.map(\.asset.key)
      }

      // `.any` is the pre-scope behaviour: one pattern, all three columns.
      #expect(try keys(.any).count == 3)
      #expect(try keys(.filename) == ["blog/asset-0.png"])
      #expect(try keys(.key) == ["blog/poster.png"])
      #expect(try keys(.note) == ["blog/asset-2.png"])
    }
  }

  /// The find strip's match-mode and case controls map onto
  /// real query semantics. The fixture must give the modes DIFFERENT row
  /// sets — a mode test where every mode returns the same rows proves
  /// nothing. Rows: "Screen-Shot.png" (mixed case), "screenshot.png"
  /// (lower), "notes.txt".
  @Test("Match modes and case sensitivity select different row sets")
  func matchModesAndCaseSelectDifferentRows() throws {
    try withQueryDatabase { database in
      try database.write { db in
        try insertAsset(
          db, index: 0, uploadedAt: "2026-08-01T00:00:00Z",
          origFilename: "Screen-Shot.png")
        try insertAsset(
          db, index: 1, uploadedAt: "2026-08-02T00:00:00Z",
          origFilename: "screenshot.png")
        try insertAsset(
          db, index: 2, uploadedAt: "2026-08-03T00:00:00Z",
          origFilename: "notes.txt")
      }

      func keys(_ term: String, match: SearchMatch, caseSensitive: Bool) throws -> [String] {
        var query = AssetQuery()
        query.search = term
        query.searchField = .filename
        query.searchMatch = match
        query.searchCaseSensitive = caseSensitive
        return try CatalogAssets.page(query, in: database).items.map(\.asset.key)
      }

      // Case folding: "Shot" vs "shot" — contains.
      #expect(try keys("shot", match: .contains, caseSensitive: false).count == 2)
      #expect(
        try keys("shot", match: .contains, caseSensitive: true)
          == ["blog/asset-1.png"],
        "only the lowercase filename contains a lowercase 'shot'")

      // Prefix: capital-S term matches only the mixed-case row when
      // case-sensitive; both when folded.
      #expect(try keys("screen", match: .begins, caseSensitive: false).count == 2)
      #expect(
        try keys("Screen", match: .begins, caseSensitive: true)
          == ["blog/asset-0.png"])
      #expect(
        try keys("screen", match: .begins, caseSensitive: true)
          == ["blog/asset-1.png"])

      // Suffix: both PNG rows end in ".png" case-sensitively.
      #expect(
        try keys(".png", match: .ends, caseSensitive: true).count == 2)
      #expect(try keys(".PNG", match: .ends, caseSensitive: true).isEmpty)

      // Whole-value match: byte-exact only.
      #expect(
        try keys("Screen-Shot.png", match: .matches, caseSensitive: true)
          == ["blog/asset-0.png"])
      #expect(
        try keys("screen-shot.png", match: .matches, caseSensitive: true).isEmpty)
      #expect(
        try keys("SCREEN-SHOT.PNG", match: .matches, caseSensitive: false)
          == ["blog/asset-0.png"],
        "folded matching still applies to the whole-value mode")

      // The modes genuinely differ on one term, one case setting.
      #expect(
        try keys("shot", match: .begins, caseSensitive: true).isEmpty)
      #expect(
        try keys("shot", match: .ends, caseSensitive: true).isEmpty,
        "'screenshot.png' contains 'shot' but does not end with it")

      // Like-wildcard characters must not act as wildcards in any mode.
      try database.write { db in
        try insertAsset(
          db, index: 3, uploadedAt: "2026-08-04T00:00:00Z",
          origFilename: "100%_sure.png")
      }
      #expect(
        try keys("100%_sure", match: .contains, caseSensitive: false)
          == ["blog/asset-3.png"],
        "% and _ must be escaped in the folded path")
      #expect(
        try keys("100%_sure", match: .contains, caseSensitive: true)
          == ["blog/asset-3.png"],
        "and are literal bytes in the case-sensitive path")
    }
  }

  /// The status bar's count must equal what an unlimited
  /// listing of the same query returns, over a filter that actually
  /// excludes rows — a count test on a filter that excludes nothing proves
  /// nothing. The second project membership is there so the equivalence
  /// holds with join rows present, not just on a flat table.
  @Test("Count matches an unlimited listing over an excluding filter, joins included")
  func countMatchesUnlimitedListing() throws {
    try withQueryDatabase { database in
      try database.write { db in
        try insertAsset(
          db, index: 0, uploadedAt: "2026-08-01T00:00:00Z", origFilename: "poster-a.png")
        try insertAsset(
          db, index: 1, uploadedAt: "2026-08-02T00:00:00Z", origFilename: "unrelated.png")
        try insertAsset(
          db, index: 2, uploadedAt: "2026-08-03T00:00:00Z", origFilename: "poster-b.png",
          projectID: nil)
        // Asset 2 joins a second project too: one asset, two membership
        // rows — COUNT(DISTINCT a.id) must still say one.
        try db.execute(
          sql: """
            INSERT INTO asset_project (asset_id, project_id, added_at)
            SELECT a.id, 2, '2026-08-03T00:00:00Z' FROM asset a
            WHERE a.orig_filename = 'poster-b.png'
            """
        )
      }

      var search = AssetQuery()
      search.search = "poster"
      search.searchField = .filename
      var unlimited = search
      unlimited.limit = 1_000
      let listed = try CatalogAssets.page(unlimited, in: database).items
      #expect(listed.count == 2, "the filter must exclude something for this test to mean anything")
      #expect(try CatalogAssets.count(search, in: database) == 2)
      #expect(try CatalogAssets.count(search, in: database) == listed.count)

      var projectScoped = AssetQuery()
      projectScoped.project = "never-scanned"
      #expect(try CatalogAssets.count(projectScoped, in: database) == 1)
      // A paged query with a cursor must NOT count only the remainder: the
      // count ignores `after` by construction.
      var paged = search
      paged.limit = 1
      let first = try CatalogAssets.page(paged, in: database)
      #expect(first.next != nil)
      paged.after = first.next
      #expect(try CatalogAssets.count(paged, in: database) == 2)
    }
  }
}
