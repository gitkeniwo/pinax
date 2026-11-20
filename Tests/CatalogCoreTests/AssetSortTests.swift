import CatalogCore
import Foundation
import GRDB
import Testing

/// Sorting happens in the query, and the keyset cursor
/// pages every sort without duplicates or gaps. The fixture is built so no
/// sort key follows id order (a sort that silently falls back to id, or a
/// cursor that only compares ids, cannot pass by coincidence), and every key
/// has ties, so page boundaries land inside runs of equal keys.
private let rowCount = 150
/// The single largest asset, deliberately in the middle of the id range.
private let largestIndex = 60

private func sizeOf(_ i: Int) -> Int64 {
  i == largestIndex ? 9_000_000 : Int64(((i * 37) % 50) * 1_000 + 500)
}

/// Each name occurs twice (53 is coprime with 75), once per case, so NOCASE
/// ties differ in bytes. Every 13th row has no filename and sorts by key.
private func filenameOf(_ i: Int) -> String? {
  guard i % 13 != 0 else { return nil }
  let stem = (i * 53) % 75
  return i % 2 == 0 ? "IMG-\(stem).png" : "img-\(stem).png"
}

private func keyOf(_ i: Int) -> String { "blog/k-\(i).png" }

private func uploadedAtOf(_ i: Int) -> String {
  String(format: "2026-08-%02dT10:00:00Z", 1 + (i * 7) % 30)
}

private let mimes = ["image/webp", "image/png", "image/gif", "image/jpeg"]
private func mimeOf(_ i: Int) -> String { mimes[(i * 3) % 4] }

/// All five sources, in a pattern that follows no other key. The sort
/// key is the source's raw value.
private let sourceMetas: [(meta: String, key: String)] = [
  (#"{"imported_from":"picgo"}"#, "picgo"),
  (#"{"imported_from":"externals"}"#, "bucket"),
  ("{}", "pinax"),
  (#"{"imported_from":"hexo"}"#, "other_import"),
  (#"{"source_url":"https://old.pinax.invalid/a.png"}"#, "migrated"),
]
private func sourceOf(_ i: Int) -> (meta: String, key: String) { sourceMetas[(i * 3) % 5] }

private func withSortDatabase(_ body: (DatabasePool) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
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
        """
    )
    for i in 1...rowCount {
      var asset = Asset(
        sha256: String(format: "%064x", i), backendID: 1, key: keyOf(i),
        byteSize: sizeOf(i), width: 10, height: 10, mime: mimeOf(i),
        originalFilename: filenameOf(i), state: "active", note: nil, meta: sourceOf(i).meta,
        uploadedAt: uploadedAtOf(i), createdAt: uploadedAtOf(i), updatedAt: uploadedAtOf(i))
      try asset.insert(db)
    }
  }
  try body(database)
}

/// Rows are inserted in index order, so id == index.
private func expectedOrder(_ sort: AssetSort) -> [Int64] {
  func key(_ i: Int) -> String {
    switch sort.field {
    case .uploadedAt: uploadedAtOf(i)
    case .name: (filenameOf(i) ?? keyOf(i)).lowercased()
    case .byteSize: String(format: "%012lld", sizeOf(i))
    case .kind: mimeOf(i)
    case .source: sourceOf(i).key
    // One backend: every row ties, so it pages by id (DomainLinksD4aTests
    // orders two backends).
    case .domain: "img.example.com"
    }
  }
  let ascending = (1...rowCount).sorted { a, b in
    key(a) == key(b) ? a < b : key(a) < key(b)
  }
  return (sort.direction == .ascending ? ascending : ascending.reversed()).map(Int64.init)
}

private func pageAll(_ database: DatabasePool, sort: AssetSort, limit: Int) throws -> [[Int64]] {
  var query = AssetQuery()
  query.sort = sort
  query.limit = limit
  var pages: [[Int64]] = []
  repeat {
    let page = try CatalogAssets.page(query, in: database)
    pages.append(page.items.compactMap(\.asset.id))
    query.after = page.next
  } while query.after != nil && pages.count <= rowCount
  return pages
}

@Suite("AssetSort in the query")
struct AssetSortTests {
  @Test("No sort key of the fixture follows id order, and every key has ties")
  func fixtureHasNoCoincidences() {
    let ids = (1...rowCount).map(Int64.init)
    for field in AssetSort.Field.menuCases {
      let order = expectedOrder(AssetSort(field: field, direction: .ascending))
      #expect(order != ids, "\(field) ascending equals id order")
      #expect(order != ids.reversed(), "\(field) ascending equals reversed id order")
    }
    #expect(Set((1...rowCount).map(sizeOf)).count < rowCount - 1)
    #expect(Set((1...rowCount).map { (filenameOf($0) ?? keyOf($0)).lowercased() }).count < rowCount)
    #expect(Set((1...rowCount).map(uploadedAtOf)).count < rowCount)
    #expect(Set((1...rowCount).map(mimeOf)).count < rowCount)
  }

  @Test("Size descending on a 150-row catalog starts with the catalog's largest asset")
  func sizeDescendingStartsWithGlobalMaximum() throws {
    try withSortDatabase { database in
      // Anti-coincidence: the largest asset is not on the default first page,
      // so sorting only the loaded page cannot find it.
      let defaultFirst = try CatalogAssets.page(AssetQuery(), in: database)
      #expect(defaultFirst.items.count == 100)
      #expect(!defaultFirst.items.contains { $0.asset.id == Int64(largestIndex) })

      var query = AssetQuery()
      query.sort = AssetSort(field: .byteSize, direction: .descending)
      let page = try CatalogAssets.page(query, in: database)
      #expect(page.items.first?.asset.id == Int64(largestIndex))
      #expect(page.items.first?.asset.byteSize == 9_000_000)
    }
  }

  @Test("Name ascending, two pages of 100, the id sets union to the whole catalog")
  func nameAscendingTwoPagesCoverEverything() throws {
    try withSortDatabase { database in
      let pages = try pageAll(database, sort: AssetSort(field: .name, direction: .ascending), limit: 100)
      #expect(pages.map(\.count) == [100, 50])
      let all = pages.flatMap { $0 }
      #expect(all.count == rowCount)
      #expect(Set(all) == Set((1...rowCount).map(Int64.init)))
      #expect(all == expectedOrder(AssetSort(field: .name, direction: .ascending)))
    }
  }

  @Test(
    "Every field and direction pages without duplicates or gaps, boundaries inside tie runs",
    arguments: AssetSort.Field.allCases, AssetSort.Direction.allCases)
  func everySortPagesExactly(field: AssetSort.Field, direction: AssetSort.Direction) throws {
    let sort = AssetSort(field: field, direction: direction)
    let limit = 7
    let expected = expectedOrder(sort)
    try withSortDatabase { database in
      let pages = try pageAll(database, sort: sort, limit: limit)
      let all = pages.flatMap { $0 }
      #expect(all.count == rowCount)
      #expect(Set(all).count == rowCount)
      #expect(all == expected)
    }
    // Anti-coincidence: at least one page boundary splits a run of equal keys.
    func keyOfID(_ id: Int64) -> String {
      let i = Int(id)
      switch field {
      case .uploadedAt: return uploadedAtOf(i)
      case .name: return (filenameOf(i) ?? keyOf(i)).lowercased()
      case .byteSize: return String(sizeOf(i))
      case .kind: return mimeOf(i)
      case .source: return sourceOf(i).key
      case .domain: return "img.example.com"
      }
    }
    let splits = stride(from: limit, to: rowCount, by: limit).filter {
      keyOfID(expected[$0 - 1]) == keyOfID(expected[$0])
    }
    #expect(!splits.isEmpty)
  }

  @Test("The default sort is upload date, newest first")
  func defaultSort() {
    #expect(AssetQuery().sort == AssetSort(field: .uploadedAt, direction: .descending))
  }
}
