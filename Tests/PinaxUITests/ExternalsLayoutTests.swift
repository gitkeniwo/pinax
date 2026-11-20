import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// The Externals scope bar's counts, the table's
/// row geometry, the line-number split, the domain colour, and the inspector
/// preview that asks for exactly one Other Domains image.
@MainActor
@Suite struct ExternalsLayoutTests {
  static let prefix = "https://img.pinax.invalid"

  static func row(
    _ source: String, _ name: String, domain: ExternalDomain = .yours,
    rawURL: String? = nil
  ) -> ExternalReference {
    ExternalReference(
      projectSlug: "blog", sourceReference: source,
      rawURL: rawURL ?? "\(prefix)/blog/\(name)", kind: "markdown", domain: domain,
      match: domain == .yours
        ? ExternalDomainMatch(backendSlug: "r2", prefix: prefix, isCurrent: true) : nil)
  }

  static let rows: [ExternalReference] = [
    row("posts/a.md#L18", "Transatlanticism.jpg"),
    row("posts/b.md#L2", "Alpha.png"),
    row("posts/c.md", "gamma.gif"),
    row("posts/d.md#L31", "remote.png", domain: .other,
        rawURL: "https://upload.wikimedia.org/wikipedia/en/e/e9/remote.png"),
    row("posts/e.md#L7", "elsewhere.png", domain: .other,
        rawURL: "https://elsewhere.example.org/x/elsewhere.png"),
  ]

  private struct StaticExternals: ExternalUsageReading {
    let rows: [ExternalReference]
    func externalReferences(project: String?) async throws -> ExternalReferenceSet {
      ExternalReferenceSet(
        references: rows.filter { project == nil || $0.projectSlug == project },
        projectSources: [:])
    }
  }

  private func until(seconds: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  // MARK: - Scope bar

  @Test("The scope bar names both halves and the model's counts are its capsules")
  func scopeCounts() async {
    let model = ExternalsModel(reader: StaticExternals(rows: Self.rows))
    await model.selectProject("blog")
    #expect(ExternalScopeBar.title(.yours) == "Your domains")
    #expect(ExternalScopeBar.title(.other) == "Other domains")
    #expect(model.count(.yours) == 3)
    #expect(model.count(.other) == 2)
    #expect(model.domain == .yours)
    model.domain = .other
    #expect(model.presentation == .results(Self.rows.filter { $0.domain == .other }))
  }

  // MARK: - Refs order

  @Test("Refs orders the domain groups by their count; its first click is largest first")
  func refsOrder() async {
    let rows = [
      Self.row("posts/a.md#L1", "one.png", domain: .other,
               rawURL: "https://a.example/1.png"),
      Self.row("posts/b.md#L1", "two.png", domain: .other,
               rawURL: "https://a.example/2.png"),
      Self.row("posts/c.md#L1", "three.png", domain: .other,
               rawURL: "https://b.example/1.png"),
    ]
    let model = ExternalsModel(reader: StaticExternals(rows: rows))
    await model.selectProject("blog")
    model.domain = .other
    model.sort = model.sort.clicking(.refs)
    #expect(model.sort == ExternalSort(field: .refs, direction: .descending))
    #expect(model.groups.map(\.host) == ["a.example", "b.example"])
    #expect(model.groups.map(\.rows.count) == [2, 1])
    model.sort = model.sort.clicking(.refs)
    #expect(model.groups.map(\.rows.count) == [1, 2])
  }

  // MARK: - Line split

  @Test("A place's line splits off for its capsule; a reference without one has no capsule")
  func lineSplit() {
    #expect(ExternalsView.line(Self.rows[0]) == 18)
    #expect(ExternalsView.sourceFile(Self.rows[0]) == "a.md")
    #expect(ExternalsView.line(Self.rows[2]) == nil)
    #expect(ExternalsView.sourceFile(Self.rows[2]) == "c.md")
    // The split requires a positive number, as Usage's own does.
    #expect(ExternalsView.line(Self.row("posts/a.md#L0", "zero.png")) == nil)
    #expect(ExternalsView.line(Self.row("posts/a.md#L100", "hundred.png")) == 100)
    #expect(ExternalsView.place(Self.rows[0], inFileGroup: true) == "L18")
    #expect(ExternalsView.place(Self.rows[2], inFileGroup: true) == "c")
  }

  // MARK: - Row geometry and the inspector's face

  @Test("The configured row numbers are the ones laid out")
  func rowGeometry() {
    let table = DesignMetrics.externalsTable.self
    #expect(table.hostSquareSide == 20 && table.hostSquareRadius == 5)
    #expect(table.hostStackOffset == 3)
    #expect(table.hostStackRing == 1.5)
    #expect(table.hostStackOpacityLight == 0.58 && table.hostStackOpacityDark == 0.62)
    #expect(table.countWidth == 34)
    #expect(table.hostRowHeight == 34)
    #expect(table.childRowHeight == 38)
    #expect(table.childLeading == 36)
    #expect(table.thumbnail == 28 && table.thumbnailRadius == 6)
    #expect(table.placeholderStroke == 1.5)
    #expect(table.treeX == 17 && table.treeGap == 3 && table.treeRadius == 7)
    #expect(table.treeLineWidth == 1.5)
    #expect(table.lineCapsuleWidth == 30)
    #expect(table.usedInWidth == 176 && table.kindWidth == 34 && table.refsWidth == 34)
    #expect(table.selectionRadius == 7)
    #expect(DesignMetrics.externalsInspector.previewHeight == 130)
    #expect(DesignMetrics.assetTable.formatBlock == 13)
    #expect(DesignMetrics.assetTable.selectedSecondaryOpacity == 0.75)
    #expect(ExternalHostRow.stackOpacity(dark: false) == 0.58)
    #expect(ExternalHostRow.stackOpacity(dark: true) == 0.62)
  }

  @Test("The table Kind mark and the inspector's syntax, domain and title line use the same words")
  func inspectorWords() {
    let other = Self.rows[3]
    #expect(ExternalsView.kindMark("markdown") == "MD")
    #expect(ExternalsView.kindMark("html") == "HTML")
    #expect(ExternalsView.kindMark("astro") == "ASTR")
    #expect(ExternalInspector.syntax(other) == "Markdown image")
    #expect(ExternalInspector.domain(other) == "Other · not yours")
    #expect(ExternalInspector.domain(Self.rows[0]) == "r2 · current domain")
    #expect(
      ExternalsView.headerSubtitle(other, failure: nil)
        == "On another host · wikimedia.org")
    #expect(ExternalInspector.previewNote(other, state: nil) == "Not loaded from host")
    #expect(ExternalInspector.previewNote(other, state: .failed("404 · not found")) == "404 · not found")
    #expect(ExternalInspector.canLoadPreview(nil))
    #expect(ExternalInspector.canLoadPreview(.failed("404 · not found")))
    #expect(!ExternalInspector.canLoadPreview(.loading))
  }

  // MARK: - Load preview

  @Test("Load preview asks for exactly that one Other Domains URL, once; the lists still ask for none")
  func loadPreviewOnlyOne() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-t04-preview-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let asked = ExternalsFetchLog()
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory,
      fetcher: { url in
        asked.add(url)
        return pngData(width: 8, height: 8)
      })
    let model = ExternalsModel(reader: StaticExternals(rows: Self.rows), thumbnails: thumbnails)
    await model.selectProject("blog")
    model.domain = .other
    let first = try #require(model.groups.flatMap(\.rows).first)
    let second = try #require(model.groups.flatMap(\.rows).dropFirst().first)

    // The page's own appearance path asks for nothing on Other Domains.
    model.loadThumbnail(first)
    #expect(model.thumbnail(first) == nil)
    #expect(asked.urls.isEmpty)
    #expect(model.preview(first) == nil)

    // The inspector's one button.
    model.loadPreview(first)
    model.loadPreview(first)
    await until { model.preview(first) != .loading }
    #expect(asked.urls == [URL(string: first.rawURL)!])
    #expect(model.preview(second) == nil)
    guard case .loaded? = model.preview(first) else {
      Issue.record("preview did not load: \(String(describing: model.preview(first)))")
      return
    }

    // A loaded preview is not asked for again.
    model.loadPreview(first)
    await spin(0.2)
    #expect(asked.urls.count == 1)

    // A second row's button asks for that row alone.
    model.loadPreview(second)
    await until { model.preview(second) != .loading }
    #expect(Set(asked.urls.map(\.absoluteString)) == [
      first.rawURL, second.rawURL,
    ])
  }

  private func spin(_ seconds: TimeInterval) async {
    await until(seconds: seconds) { false }
  }
}
