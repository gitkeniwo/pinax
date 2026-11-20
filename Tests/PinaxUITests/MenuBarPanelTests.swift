import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import Testing

/// The menu bar panel's home page, as values. Nothing
/// opens a panel or pops a menu; the pasteboard is a private named one.
@MainActor
@Suite(.serialized) struct MenuBarPanelTests {
  private func makeApp(
    seed: Int = 0, withBackend: Bool = true
  ) async throws -> (app: PinaxAppModel, directory: URL) {
    let (database, directory) = try makeUITestDatabase()
    if !withBackend {
      try await database.write { db in
        try db.execute(sql: "DELETE FROM project; DELETE FROM backend")
      }
    }
    for index in 0..<seed {
      try seedAsset(
        database, index: index, uploadedAt: String(format: "2026-08-%02dT00:00:00Z", index + 1))
    }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-t47-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    await app.backends?.load()
    return (app, directory)
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func namedPasteboard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("pinaxui-t47-\(UUID().uuidString)"))
    board.clearContents()
    return board
  }

  private func pngData(width: Int, height: Int) throws -> Data {
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(rep.representation(using: .png, properties: [:]))
  }

  // MARK: - The clipboard card

  @Test("No image on the clipboard: no card; an image: a card worded from the image")
  func clipboardCard() async throws {
    let board = namedPasteboard()
    defer { board.releaseGlobally() }
    #expect(ClipboardImageProbe.probe(board) == nil)
    board.setString("just text", forType: .string)
    #expect(ClipboardImageProbe.probe(board) == nil)

    let data = try pngData(width: 120, height: 80)
    board.setData(data, forType: .png)
    let found = try #require(ClipboardImageProbe.probe(board))
    #expect(found.info.kind == "PNG")
    #expect(found.info.width == 120 && found.info.height == 80)
    #expect(found.info.byteSize == Int64(data.count))
    #expect(found.info.detailLine.hasPrefix("PNG · 120 × 80 · "))
    #expect(found.thumbnail != nil)

    // The panel model carries the probe; the summary shows the card only then.
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let panel = MenuBarPanelModel(pasteboard: board)
    await panel.refreshClipboard()
    #expect(MenuBarSummary(app: app, clipboard: panel.clipboard?.info).clipboard == found.info)
    board.clearContents()
    await panel.refreshClipboard()
    #expect(panel.clipboard == nil)
    #expect(MenuBarSummary(app: app, clipboard: panel.clipboard?.info).clipboard == nil)
  }

  // MARK: - RECENT

  @Test("The panel lists the eight newest uploads, newest first")
  func recentEight() async throws {
    let (app, directory) = try await makeApp(seed: 10)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(RecentUpload.limit == 8)
    let summary = MenuBarSummary(app: app, clipboard: nil)
    #expect(summary.recent.count == 8)
    #expect(summary.recent.first?.filename == "asset-9.png")
    #expect(summary.recent.last?.filename == "asset-2.png")
  }

  @Test("The copy feedback names the clicked file, and clears after 1.5 s")
  func copyFeedback() async throws {
    var copied: [String] = []
    var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    let panel = MenuBarPanelModel(
      pasteboard: namedPasteboard(), copier: { copied.append($0) },
      schedule: { scheduled.append(($0, $1)) })
    let first = RecentUpload(id: 1, filename: "one.png", url: "https://img.example.com/one.png")
    let second = RecentUpload(id: 2, filename: "two.png", url: "https://img.example.com/two.png")

    panel.copyLink(second)
    #expect(copied == ["https://img.example.com/two.png"])
    #expect(panel.copied == .init(uploadID: 2, filename: "two.png", message: "✓ Link copied"))
    #expect(scheduled.last?.0 == 1.5)

    // A second click inside the window: the first timer must not clear it.
    panel.copyLink(first)
    #expect(panel.copied?.filename == "one.png")
    scheduled[0].1()
    #expect(panel.copied?.filename == "one.png")
    scheduled[1].1()
    #expect(panel.copied == nil)

    panel.copyMarkdown(second)
    #expect(copied.last == "![two](https://img.example.com/two.png)")
    #expect(panel.copied?.filename == "two.png")
  }

  // MARK: - First run, uploading

  @Test("No backend: first-run state, nothing but Quit below it")
  func firstRun() async throws {
    let (app, directory) = try await makeApp(withBackend: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipboard = ClipboardImageInfo(kind: "PNG", width: 1, height: 1, byteSize: 10)
    let summary = MenuBarSummary(app: app, clipboard: clipboard)
    #expect(summary.isFirstRun)
    #expect(summary.footer == [.quit])
    #expect(summary.clipboard == nil)
    #expect(summary.recent.isEmpty)

    let (configured, other) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: other) }
    #expect(!MenuBarSummary(app: configured, clipboard: nil).isFirstRun)
  }

  @Test("Uploading with the drop zone panel hidden shows the line; with it showing, not")
  func uploadingLine() async throws {
    let (app, directory) = try await makeApp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let zone = try #require(app.dropZone?.model)
    #expect(MenuBarSummary(app: app, clipboard: nil).uploadingLine == nil)
    // Unreadable files fail fast: pending first, no network.
    zone.drop(fileURLs: (0..<2).map { URL(fileURLWithPath: "/nonexistent/t47-\($0).png") })
    #expect(zone.uploadCounts == .init(completed: 0, total: 2))
    // A drop presents the zone, which already shows the uploads: no line.
    #expect(zone.isWindowVisible)
    #expect(MenuBarSummary(app: app, clipboard: nil).uploadingLine == nil)
    zone.dismiss()
    #expect(!zone.isWindowVisible)
    #expect(MenuBarSummary(app: app, clipboard: nil).uploadingLine == "Uploading 1 of 2")
    await waitUntil { zone.cards.allSatisfy { !$0.phase.isPending } }
    #expect(MenuBarSummary(app: app, clipboard: nil).uploadingLine == nil)

    let counts = UploadCounts(completed: 1, total: 5)
    func line(visible: Bool) -> String? {
      MenuBarSummary(
        hasBackend: true, clipboard: nil, recent: [], uploadCounts: counts,
        dropZonePanelVisible: visible
      ).uploadingLine
    }
    #expect(line(visible: false) == "Uploading 2 of 5")
    #expect(line(visible: true) == nil)
  }
}
