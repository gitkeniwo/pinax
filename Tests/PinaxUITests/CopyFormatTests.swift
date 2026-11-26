import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Copy As formats. Properties:
///
/// 1. Template rendering is a pure function, one test per placeholder.
/// 2. Unknown placeholders are left as written, and reported for the list.
/// 3. Every Copy As entry writes exactly its own format to the pasteboard.
/// 4. A multi-selection copies one line per item in grid order, whatever
///    order the items were clicked in.
/// 5. The format list and the default survive a restart (a new store over
///    the same defaults).
@MainActor
@Suite(.serialized) struct CopyFormatTests {
  private let fields = CopyFields(
    url: "https://img.example.com/blog/a.png", filename: "Screen Shot.v2.png",
    width: 800, height: 600, key: "blog/a.png", projects: ["blog", "notes"])

  // MARK: - property 1 (the placeholders themselves: `CopyTemplateTests`)

  @Test("Factory templates render the spec's lines")
  func factoryTemplates() {
    #expect(CopyTemplate.render(CopyFormat.url.template, fields: fields) == fields.url)
    #expect(
      CopyTemplate.render(CopyFormat.markdown.template, fields: fields)
        == "![Screen Shot.v2](https://img.example.com/blog/a.png)")
    #expect(
      CopyTemplate.render(CopyFormat.html.template, fields: fields)
        == #"<img src="https://img.example.com/blog/a.png" alt="Screen Shot.v2" width="800" height="600">"#)
  }

  // MARK: - property 2

  @Test("The factory templates name only known placeholders")
  func factoryPlaceholders() {
    for format in CopyFormat.factory {
      #expect(CopyTemplate.unknownPlaceholders(in: format.template).isEmpty, "\(format.name)")
    }
  }

  // MARK: - property 3

  @Test("Every Copy As entry writes exactly its format")
  func copyAsWritesEachFormat() async throws {
    let custom = CopyFormat(name: "Key", template: "{key} ({width}×{height}) {project}")
    try await withModel(count: 2) { model, _ in
      model.copyFormats = CopyFormat.factory + [custom]
      let row = model.rows[1]
      #expect(row.item.asset.key == "blog/asset-0.png")
      let item = try #require(copyAsItem(model.contextMenuItems(for: row)))
      guard case let .copyAs(target, formats) = item else { return }
      #expect(formats == model.copyFormats)

      let expected = [
        row.item.url,
        "![asset-0](\(row.item.url))",
        #"<img src="\#(row.item.url)" alt="asset-0" width="800" height="600">"#,
        "blog/asset-0.png (800×600) blog",
      ]
      for (format, line) in zip(formats, expected) {
        let pasteboard = scratchPasteboard()
        model.copy(format, for: target, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == line, "\(format.name)")
      }
    }
  }

  @Test("Edit ▸ Copy As copies the current selection in each format")
  func editMenuCopiesSelection() async throws {
    try await withModel(count: 2) { model, _ in
      #expect(!model.canCopySelection)
      model.select(model.rows[0], mode: .replace)
      #expect(model.canCopySelection)
      let pasteboard = scratchPasteboard()
      model.copySelection(as: .markdown, to: pasteboard)
      #expect(pasteboard.string(forType: .string) == "![asset-1](\(model.rows[0].item.url))")
    }
  }

  // MARK: - property 4

  @Test("A multi-selection copies one line per item in grid order")
  func multiSelectionFollowsGridOrder() async throws {
    try await withModel(count: 4) { model, _ in
      let rows = model.rows
      // Clicked back to front: the copy must still read front to back.
      model.select(rows[3], mode: .replace)
      model.select(rows[0], mode: .toggle)
      model.select(rows[2], mode: .toggle)
      let lines = [rows[0], rows[2], rows[3]].map(\.item.asset.key).joined(separator: "\n")
      let keyFormat = CopyFormat(name: "Key", template: "{key}")

      let item = try #require(copyAsItem(model.contextMenuItems(for: rows[2])))
      guard case let .copyAs(target, _) = item else { return }
      let menuBoard = scratchPasteboard()
      model.copy(keyFormat, for: target, to: menuBoard)
      #expect(menuBoard.string(forType: .string) == lines)

      let editBoard = scratchPasteboard()
      model.copySelection(as: keyFormat, to: editBoard)
      #expect(editBoard.string(forType: .string) == lines)
    }
  }

  // MARK: - property 5

  @Test("Formats and the default survive a restart")
  func formatsPersist() throws {
    let suite = "PinaxCopyFormatTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let fresh = PreferencesStore(defaults: defaults)
    #expect(fresh.copyFormats == CopyFormat.factory)
    #expect(fresh.defaultCopyFormatID == CopyFormat.url.id)

    let custom = CopyFormat(name: "Blog", template: "{project}: {url}")
    fresh.copyFormats = [CopyFormat.markdown, custom]
    fresh.defaultCopyFormatID = custom.id

    let restarted = PreferencesStore(defaults: defaults)
    #expect(restarted.copyFormats == [CopyFormat.markdown, custom])
    #expect(restarted.defaultCopyFormatID == custom.id)
    #expect(restarted.defaultCopyFormat == custom)
  }

  @Test("A default that left the list falls back to the list's first entry")
  func defaultFallsBack() throws {
    let suite = "PinaxCopyFormatTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not json".utf8), forKey: "pinax.copy.formats")

    let store = PreferencesStore(defaults: defaults)
    #expect(store.copyFormats == CopyFormat.factory)
    store.copyFormats = [CopyFormat.html]
    #expect(store.defaultCopyFormat == CopyFormat.html)
  }

  // MARK: - helpers

  private func copyAsItem(_ items: [GalleryModel.ContextMenuItem]) -> GalleryModel.ContextMenuItem? {
    items.first { $0.id == "copyAs" }
  }

  private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("PinaxCopyFormatTests-\(UUID().uuidString)"))
  }

  private func withModel(
    count: Int, _ body: (GalleryModel, DatabasePool) async throws -> Void
  ) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<count {
      try seedAsset(
        database, index: index,
        // Later index = newer = earlier in the grid, so grid order is the
        // reverse of row-id order and an id-sorted copy cannot pass.
        uploadedAt: String(format: "2026-08-20T12:%02d:00Z", index))
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
    await model.loadInitialData()
    try await body(model, database)
  }
}
