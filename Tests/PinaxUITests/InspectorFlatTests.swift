import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// The inspector the app hosts, fed by
/// the app's own model and preference path:
///
/// 1. With nothing selected the column is "No Selection" alone: no control,
///    no field, and exactly one screen tall — the sections stay mounted
///    underneath (the stable root) but take no room.
/// 2. The link row's format pop-up and copy button are named after the
///    default format, the copy button's action writes ⌘C's text, and a new
///    default renames them.
/// 3. One asset shows its own values — the date through `PinaxFormat`, the
///    projects it is in switched on — and two show the multiple-selection state: no link,
///    no note, the tag composer and the project switches still there. The
///    switches are drawn by `PinaxMembershipToggleStyle`, not
///    AppKit, so what each shows is read from the view's `switchIsOn`.
///
/// The fixture's values are none of the defaults: the default format is a
/// custom one, the asset is in one of two projects, the two selected assets
/// are in different ones. No test opens a menu or clicks a button;
/// the buttons' actions are the view's own methods, called as values.
@MainActor
@Suite(.serialized) struct InspectorFlatTests {
  private let blog = CopyFormat(name: "Blog", template: "{filename} → ![{name}]({url}) {width}x{height}")

  private struct Fixture {
    let app: PinaxAppModel
    let gallery: GalleryModel
    let directory: URL
  }

  /// asset-1 (blog, newest) and asset-0 (notes) — rows[0] and rows[1].
  private func makeFixture() async throws -> Fixture {
    let (database, directory) = try makeUITestDatabase()
    try seedAsset(
      database, index: 0, uploadedAt: "2026-08-01T09:30:00Z", projectSlug: "notes",
      width: 1920, height: 1080)
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z", projectSlug: "blog")
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-inspector-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    app.preferences.copyFormats.append(blog)
    app.preferences.defaultCopyFormatID = blog.id
    await gallery.loadInitialData()
    #expect(gallery.defaultCopyFormat == blog)
    #expect(gallery.rows.map(\.item.asset.originalFilename) == ["asset-1.png", "asset-0.png"])
    #expect(gallery.projects.map(\.slug).sorted() == ["blog", "notes"])
    return Fixture(app: app, gallery: gallery, directory: directory)
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  private func spin(_ seconds: TimeInterval = 0.5) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// Waits for the model, then lets the hosted view catch up.
  private func settle(until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
    await spin(0.3)
  }

  private func host(
    _ gallery: GalleryModel, pasteboard: NSPasteboard = .general, height: CGFloat = 900
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: GalleryWidthBudget.inspectorWidth, height: height),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: AssetInspectorView(model: gallery, pasteboard: pasteboard))
    window.orderFront(nil)
    return window
  }

  /// What the hosted inspector draws that AppKit can name.
  private struct Drawn {
    var buttons: [NSButton] = []
    var fields: [NSTextField] = []
    var copyButtons: [NSSegmentedControl] = []
    var scrollView: NSScrollView?

    var placeholders: [String] { fields.compactMap(\.placeholderString) }
    var values: [String] { fields.map(\.stringValue) }
  }

  private func drawn(in window: NSWindow) -> Drawn {
    var result = Drawn()
    var stack: [NSView] = [window.contentView!]
    while let view = stack.popLast() {
      stack.append(contentsOf: view.subviews)
      guard !view.isHiddenOrHasHiddenAncestor else { continue }
      if let control = view as? NSSegmentedControl {
        result.copyButtons.append(control)
      } else if let button = view as? NSButton {
        result.buttons.append(button)
      } else if let field = view as? NSTextField, field.superview is NSSegmentedControl == false {
        result.fields.append(field)
      }
      if result.scrollView == nil, let scroll = view as? NSScrollView { result.scrollView = scroll }
    }
    return result
  }

  private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("pinax-inspector-tests-\(UUID().uuidString)"))
  }

  // MARK: - 1. No Selection

  @Test("With nothing selected the column is No Selection alone, one screen tall")
  func noSelectionIsTheWholeColumn() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    // Shorter than the sections, so hidden-but-sized sections would scroll.
    let window = host(gallery, height: 300)
    defer { window.orderOut(nil) }

    func expectEmpty(_ note: Comment) throws {
      let now = drawn(in: window)
      #expect(
        now.buttons.isEmpty && now.fields.isEmpty && now.copyButtons.isEmpty, note)
      let scroll = try #require(now.scrollView)
      let document = try #require(scroll.documentView)
      #expect(document.frame.height == scroll.contentView.bounds.height, note)
    }

    await spin()
    #expect(gallery.selectedDetails == nil)
    try expectEmpty("launch")

    gallery.select(gallery.rows[1], mode: .replace)
    await settle(until: { gallery.selectedDetails != nil })
    let selected = drawn(in: window)
    #expect(selected.placeholders.contains("Add tag…"))
    #expect(selected.placeholders.contains("Add a note…"))
    let scroll = try #require(selected.scrollView)
    #expect(try #require(scroll.documentView).frame.height > scroll.contentView.bounds.height)

    gallery.clearSelection()
    await settle(until: { gallery.selectedDetails == nil })
    try expectEmpty("after a selection")
  }

  // MARK: - 2. The copy button

  @Test("The link row's pop-up and copy button are named after the default format and copy ⌘C's text")
  func copyButtonIsTheDefaultFormat() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    let board = privatePasteboard()
    defer { board.releaseGlobally() }
    let window = host(gallery, pasteboard: board)
    defer { window.orderOut(nil) }

    gallery.select(gallery.rows[1], mode: .replace)
    await settle(until: { gallery.selectedDetails != nil })
    // The old split button is gone: no segmented control is drawn.
    #expect(drawn(in: window).copyButtons.isEmpty)

    let commandC = privatePasteboard()
    defer { commandC.releaseGlobally() }
    gallery.copySelectionInDefaultFormat(to: commandC)
    let expected = try #require(commandC.string(forType: .string))
    #expect(expected == "asset-0.png → ![asset-0](\(gallery.rows[1].item.url)) 1920x1080")
    #expect(expected != gallery.rows[1].item.url)

    // The copy icon button's click is ⌘C's call; the pop-up's items are
    // the view's own method.
    let view = AssetInspectorView(model: gallery, pasteboard: board)
    #expect(view.copyButtonFormat == blog)
    #expect(view.isEnabled(.copy))
    await view.perform(.copy)
    #expect(board.string(forType: .string) == expected)
    view.copy(as: CopyFormat.markdown)
    #expect(board.string(forType: .string) == "![asset-0](\(gallery.rows[1].item.url))")

    // A new default, set where the user sets it, renames the pop-up.
    fixture.app.preferences.defaultCopyFormatID = CopyFormat.markdown.id
    await spin()
    #expect(AssetInspectorView(model: gallery).copyButtonFormat == CopyFormat.markdown)
  }

  // MARK: - 3. One asset, two assets

  @Test("One asset shows its own values; two show the multiple-selection state")
  func singleAndMultipleSelection() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let gallery = fixture.gallery
    let window = host(gallery)
    defer { window.orderOut(nil) }
    let names = gallery.projects.map(\.slug)

    // asset-0, in notes and not blog.
    let row = gallery.rows[1]
    gallery.select(row, mode: .replace)
    await settle(until: { gallery.selectedDetails?.item.asset.sha256 == row.item.asset.sha256 })
    let one = drawn(in: window)
    let asset = row.item.asset
    // The name and date are in the header, which is not selectable text
    // (a selectable Text drops its truncation); the view's own header
    // values are read.
    let details = try #require(gallery.selectedDetails)
    let header = AssetInspectorView.headerTitle(details)
    #expect(header.title == "asset-0.png")
    // The URL is drawn but not as a selectable field: a selected field drops
    // its middle truncation and paints the whole URL over the copy button
    // It is copied with the button or ⌘C.
    #expect(!one.values.contains(row.item.url), "the URL is a selectable field again")
    #expect(AssetInspectorView(model: gallery).browserURL?.absoluteString == row.item.url)
    let date = PinaxFormat.date(asset.uploadedAt, style: .dayTime)
    #expect(date != asset.uploadedAt)
    #expect(header.subtitle == "\(date) · \(PinaxFormat.kind(mime: asset.mime))")
    #expect(!header.subtitle.contains(asset.uploadedAt))
    #expect(one.placeholders.contains("Add a note…") && one.placeholders.contains("Add tag…"))
    #expect(
      names.map(AssetInspectorView(model: gallery).switchIsOn) == names.map { $0 == "notes" },
      "\(names)")

    // Both: blog and notes are each only partly checked, so neither is.
    gallery.select(gallery.rows[0], mode: .toggle)
    await settle(until: { gallery.selectedDetails == nil })
    #expect(gallery.selectedIDs.count == 2 && gallery.selectedDetails == nil)
    let two = drawn(in: window)
    #expect(AssetInspectorView(model: gallery).browserURL == nil, "Link reads —")
    #expect(!two.placeholders.contains("Add a note…"), "Note reads —")
    #expect(two.placeholders.contains("Add tag…"), "tags stay editable")
    #expect(!two.values.contains(row.item.url) && !two.values.contains(date))
    #expect(names.count == 2 && !gallery.isSavingEdit)
    #expect(names.allSatisfy { !AssetInspectorView(model: gallery).switchIsOn($0) })
  }
}
