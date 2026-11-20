import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// The library inspector:
///
/// 1. The label band's click is the old dots' call: it sets and clears the
///    label over the selection, the same end state `toggleLabel` gives.
/// 2. The link row's Download button saves what File ▸ Download Original
///    saves; Open in Browser opens the asset's public URL.
/// 3. The header's title and subtitle come from the file name, the upload
///    date through `PinaxFormat` and the kind; the link splits into name
///    and "host › path".
/// 4. The configured numbers are the ones laid out.
/// 5. The title sits in the inspector's toolbar section: one asset only,
///    no room while the inspector is hidden; project switches and fields
///    take the inspector's fonts.
@MainActor
@Suite(.serialized) struct InspectorLayoutTests {
  struct FakeFetcher: PublicObjectFetching {
    let objects: [String: Data]

    func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
      guard let data = objects[url.lastPathComponent] else {
        throw PublicObjectFetchError.notFound(url)
      }
      return (data, "image/png", Int64(data.count))
    }
  }

  private func makeModel(_ database: DatabasePool, directory: URL) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - 1. The label band

  @Test("A band click sets and clears the label, the same end state the dots' toggleLabel gave")
  func labelBandTogglesLikeTheDots() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z")
    let model = makeModel(database, directory: directory)
    await model.loadInitialData()
    let band = model.rows[0]
    let dots = model.rows[1]

    // The band, on one asset: the closure the inspector installs.
    model.select(band, mode: .replace)
    let bandTarget = try #require(model.selectionTargetIfAny)
    let view = AssetInspectorView(model: model)
    #expect(view.labelBand(for: bandTarget).states[.orange] == .some(false))
    view.labelBand(for: bandTarget).onToggle(.orange)
    await waitUntil { model.labelState(.orange, of: bandTarget) == true }
    #expect(model.labelState(.orange, of: bandTarget) == true)
    #expect(model.labelState(.red, of: bandTarget) == false)
    #expect(view.labelBand(for: bandTarget).states[.orange] == .some(true))

    // The dots' call, on the other.
    model.select(dots, mode: .replace)
    let dotsTarget = try #require(model.selectionTargetIfAny)
    await model.toggleLabel(.orange, for: dotsTarget)
    #expect(
      AssetLabel.allCases.map { model.labelState($0, of: dotsTarget) }
        == AssetLabel.allCases.map { model.labelState($0, of: bandTarget) })

    // A second band click clears it.
    model.select(band, mode: .replace)
    AssetInspectorView(model: model).labelBand(for: bandTarget).onToggle(.orange)
    await waitUntil { model.labelState(.orange, of: bandTarget) == false }
    #expect(model.labelState(.orange, of: bandTarget) == false)

    // Over both: orange is on one only, so mixed; the band shows it full
    // with a dash and dims the labels neither has.
    model.selectedIDs = Set([band.id, dots.id])
    let both = try #require(model.selectionTargetIfAny)
    let states = AssetInspectorView(model: model).labelBand(for: both).states
    #expect(states[.orange] == .some(nil))
    #expect(LabelBand.mark(of: nil) == "minus" && LabelBand.mark(of: true) == "checkmark")
    #expect(LabelBand.mark(of: false) == nil)
    #expect(LabelBand.anyOn(states))
    #expect(LabelBand.opacity(of: false, anyOn: true) == 0.35)
    #expect(LabelBand.opacity(of: nil, anyOn: true) == 1)
    #expect(LabelBand.opacity(of: false, anyOn: false) == 1)
  }

  // MARK: - 2. Link buttons

  @Test("Download saves what Download Original saves; Open hands over the public URL")
  func linkButtonsAreTheOldEntries() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
    let data = Data("original 0".utf8)
    try await database.write { db in
      try db.execute(
        sql: "UPDATE asset SET sha256 = ? WHERE key = ?",
        arguments: [Hashing.sha256(of: data), "blog/asset-0.png"])
    }
    let folder = directory.appendingPathComponent("downloads", isDirectory: true)
    let model = makeModel(database, directory: directory)
    model.downloader = OriginalDownloader(fetcher: FakeFetcher(objects: ["asset-0.png": data]))
    model.downloadFolder = folder
    var revealed: [URL] = []
    model.revealDownloads = { revealed = $0 }
    await model.loadInitialData()
    model.select(model.rows[0], mode: .replace)
    await waitUntil { model.selectedDetails != nil }

    var opened: [URL] = []
    var view = AssetInspectorView(model: model)
    view.openURL = { opened.append($0) }
    #expect(AssetInspectorView.LinkAction.allCases.allSatisfy { view.isEnabled($0) })

    await view.perform(.download)
    #expect(revealed.map(\.lastPathComponent) == ["asset-0.png"])
    #expect(try Data(contentsOf: folder.appendingPathComponent("asset-0.png")) == data)
    // File ▸ Download Original, the same selection: the next free name.
    await model.downloadSelection()
    #expect(revealed.map(\.lastPathComponent) == ["asset-0 2.png"])
    #expect(model.downloadError == nil)

    await view.perform(.openInBrowser)
    #expect(opened.map(\.absoluteString) == [model.rows[0].item.url])
    #expect(opened.first?.scheme == "https")
  }

  // MARK: - 3. Header and link fields

  @Test("The header reads the file name over the upload date and kind")
  func headerTitleFields() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(
      database, index: 0, uploadedAt: "2026-03-14T09:26:00Z", origFilename: "IMG_4103.jpeg")
    let model = makeModel(database, directory: directory)
    await model.loadInitialData()
    model.select(model.rows[0], mode: .replace)
    await waitUntil { model.selectedDetails != nil }
    let details = try #require(model.selectedDetails)
    let header = AssetInspectorView.headerTitle(details)
    #expect(header.title == "IMG_4103.jpeg")
    let date = PinaxFormat.date("2026-03-14T09:26:00Z", style: .dayTime)
    #expect(header.subtitle == "\(date) · \(PinaxFormat.kind(mime: "image/png"))")
    #expect(!header.subtitle.contains("2026-03-14"))
  }

  @Test("A link splits into its file name and host › directories")
  func linkParts() {
    let deep = AssetInspectorView.linkParts("https://img.example.com/202512/sub/5676812.jpeg")
    #expect(deep.name == "5676812.jpeg")
    #expect(deep.location == "img.example.com › 202512 › sub")
    let root = AssetInspectorView.linkParts("https://cdn.example.org/a%20b.png")
    #expect(root.name == "a b.png" && root.location == "cdn.example.org")
    let odd = AssetInspectorView.linkParts("not a url")
    #expect(odd.name == "not a url" && odd.location == "")
  }

  // MARK: - 4. Configuration values

  @Test("The inspector's configured numbers")
  func configurationValues() {
    #expect(DesignMetrics.inspectorFields.keyWidth == 48)
    #expect(InspectorFieldRow<EmptyView>.keyText("Source") == "Source:")
    #expect(DesignMetrics.labelBand.height == 18 && DesignMetrics.labelBand.radius == 6)
    #expect(DesignMetrics.labelBand.dimmedOpacity == 0.35)
    #expect(DesignMetrics.colorSquare.header == 28)
    #expect(DesignMetrics.inspector.previewMinHeight == 160)
    // A landscape asset's box grows to 160 (it was 150.75); a portrait one
    // keeps the 220 cap; no dimensions take the cap.
    #expect(AssetInspectorView.previewHeight(width: 1920, height: 1080) == 160)
    #expect(AssetInspectorView.previewHeight(width: 1000, height: 2000) == 220)
    #expect(AssetInspectorView.previewHeight(width: nil, height: nil) == 220)
    let widths = AssetInspectorView.statPillWidths
    #expect(abs(widths.dimensions / widths.size - 1.35) < 0.0001)
    #expect(
      abs(widths.size + widths.dimensions + DesignMetrics.inspectorStats.spacing
        - AssetInspectorView.columnWidth) < 0.0001)
    // Bands: distinct keys, Identity closed by default.
    let keys = AssetInspectorView.Band.allCases.map(\.storageKey)
    #expect(Set(keys).count == keys.count)
    #expect(AssetInspectorView.Band.allCases.filter { !$0.expandedByDefault } == [.identity])
    #expect(
      AssetInspectorView.Band.allCases.map(\.title)
        == ["Source & Link", "Note", "Tags & Labels", "Projects", "Used In", "Identity"])
    #expect(AssetInspectorView.projectLetter("astro") == "A")
    #expect(AssetInspectorView.sourceToken(.picgo) == .orange)
    #expect(PinaxPalette.live(dark: false).description == "#79740e")
    #expect(PinaxPalette.live(dark: true).description == "#b8bb26")
  }

  @Test("The inspector's Source square and the grid's source square take one hue per source")
  func sourceSquareMatchesTheGrid() {
    func rgba(_ color: Color, dark: Bool) -> [CGFloat] {
      var result: [CGFloat] = []
      NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        let resolved = NSColor(color).usingColorSpace(.sRGB)!
        result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
      }
      return result
    }
    for source in AssetSource.allCases {
      let inspector = PinaxPalette.color(AssetInspectorView.sourceToken(source))
      // The grid draws `SourceTint.color`; an unmarked source (Pinax's own
      // uploads) has no grid square and is gray in the inspector.
      let grid = SourceCaption.tint(of: source)?.color ?? PinaxPalette.gray
      for dark in [false, true] {
        #expect(rgba(inspector, dark: dark) == rgba(grid, dark: dark), "\(source) dark: \(dark)")
      }
    }
    #expect(AssetInspectorView.sourceToken(.pinax) == .gray)
  }

  @Test("Every new inspector symbol exists")
  func symbolsExist() {
    let names =
      AssetInspectorView.LinkAction.allCases.map(\.systemImage) + [
        "sidebar.right", "arrow.up.and.down", "arrow.up.left.and.arrow.down.right",
        "checkmark", "minus", "chevron.down", "heart", "heart.fill",
      ]
    for name in names {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  // MARK: - 5. Toolbar title, switches, fields

  @Test("The column title shows one asset")
  func toolbarTitleItem() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z")
    let model = makeModel(database, directory: directory)
    await model.loadInitialData()
    model.showsInspector = true
    model.select(model.rows[0], mode: .replace)
    await waitUntil { model.selectedDetails != nil }
    #expect(InspectorTitleBar.details(model)?.item.asset.key == model.rows[0].item.asset.key)
    model.selectedIDs = Set([model.rows[0].id, model.rows[1].id])
    #expect(InspectorTitleBar.details(model) == nil)
    model.select(model.rows[0], mode: .replace)
    model.showsInspector = false
    #expect(InspectorTitleBar.details(model)?.item.asset.key == model.rows[0].item.asset.key)
  }

  @Test("A project switch is a green rounded box with a check when on, gray and empty when off")
  func membershipSwitchFace() {
    #expect(PinaxMembershipToggleStyle.face(isOn: true).fill == .green)
    #expect(PinaxMembershipToggleStyle.face(isOn: true).mark == "checkmark")
    #expect(PinaxMembershipToggleStyle.face(isOn: false).fill == .gray)
    #expect(PinaxMembershipToggleStyle.face(isOn: false).mark == nil)
    typealias Box = DesignMetrics.membershipSwitch
    #expect(Box.width == 34 && Box.height == 18 && Box.radius == 5)
  }

  @Test("Note and tag fields: a filled rounded box, outlined in the accent while focused")
  func fieldChromeValues() {
    typealias field = DesignMetrics.inspectorField
    #expect(field.radius == 6)
    #expect(field.lineWidth == 0.5 && field.focusedLineWidth == 1)
    #expect(field.noteHeight == 26 && field.tagHeight == 22)
  }
}
