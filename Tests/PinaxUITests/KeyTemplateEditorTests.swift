import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// The key template editor, model layer: the draft against the
/// stored template, what the block shows under the field, Insert, and the
/// field's atomic tokens — through the editor and text view the pane uses.
/// No menu is opened and no window is shown.
@MainActor
@Suite struct KeyTemplateEditorTests {
  private let october = ISO8601DateFormatter().date(from: "2026-10-27T23:30:00Z")!

  private func editor(stored: String? = nil, prefix: String = "blog") -> KeyTemplateEditor {
    KeyTemplateEditor(stored: stored, keyPrefix: prefix, date: october)
  }

  private func storedTemplate(_ slug: String, in database: DatabasePool) throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT key_template FROM project WHERE slug = ?", arguments: [slug])
    }
  }

  // MARK: - Draft, stored value, Set

  @Test("Set is off when the draft is the stored value or has an error, on with only a warning")
  func setAvailability() {
    var state = editor()
    #expect(state.draft == KeyTemplate.defaultTemplate)
    #expect(!state.canSet)

    state.draft = "{prefix}/{year}/{month}/{name}-{hash}.{ext}"
    #expect(state.canSet)

    state.draft = "{prefix}/{name}-{hash}"
    #expect(!state.canSet)

    state.draft = "{prefix}/{name}.{ext}"
    #expect(state.callout?.kind == .warning)
    #expect(state.canSet)

    // A stored custom template: typing it back is no change.
    var custom = editor(stored: "{name}-{hash}.{ext}", prefix: "")
    #expect(custom.draft == "{name}-{hash}.{ext}")
    #expect(!custom.canSet)
    custom.draft = KeyTemplate.defaultTemplate
    #expect(custom.canSet)
  }

  @Test("Set and Reset to Default write through the model; Reset stores NULL and hides itself")
  func setAndReset() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
    model.load()

    var state = editor()
    #expect(!state.showsReset)
    state.draft = "{prefix}/{year}/{name}-{hash}.{ext}"
    #expect(state.showsReset)
    state.submit(to: model, project: "blog")
    #expect(model.saveError == nil)
    #expect(try storedTemplate("blog", in: database) == "{prefix}/{year}/{name}-{hash}.{ext}")
    let row = try #require(model.snapshot?.rows.first { $0.slug == "blog" })
    #expect(row.keyTemplate == "{prefix}/{year}/{name}-{hash}.{ext}")

    // An error never reaches the catalog.
    var broken = KeyTemplateEditor(stored: row.keyTemplate, keyPrefix: "blog", date: october)
    broken.draft = "{prefix}/{name}"
    broken.submit(to: model, project: "blog")
    #expect(try storedTemplate("blog", in: database) == "{prefix}/{year}/{name}-{hash}.{ext}")

    broken.reset(to: model, project: "blog")
    #expect(try storedTemplate("blog", in: database) == nil)
    #expect(broken.draft == KeyTemplate.defaultTemplate)
    #expect(!broken.showsReset)
    #expect(model.snapshot?.rows.first { $0.slug == "blog" }?.keyTemplate == nil)

    // Reset with the default already stored still puts the default back in the field.
    var drafted = editor()
    drafted.draft = "{name}.{ext}"
    drafted.reset(to: model, project: "blog")
    #expect(drafted.draft == KeyTemplate.defaultTemplate)
    #expect(try storedTemplate("blog", in: database) == nil)
  }

  @Test("Return in the field submits")
  func returnSubmits() {
    let field = KeyTemplateTextView.make()
    var submitted = 0
    field.onSubmit = { submitted += 1 }
    field.template = KeyTemplate.defaultTemplate
    field.insertNewline(nil)
    #expect(submitted == 1)
    #expect(field.template == KeyTemplate.defaultTemplate)
  }

  // MARK: - What shows under the field

  @Test("An error shows only the first error and no example")
  func errorCallout() {
    var state = editor()
    state.draft = "{prefix}/{nme}-{hash}"
    #expect(state.callout?.kind == .error)
    #expect(state.callout?.issue.code == .unknownPlaceholder)
    #expect(state.callout?.issue.message == "Unknown placeholder {nme}.")
    #expect(state.example == nil)
  }

  @Test("A warning shows the example and the first warning together")
  func warningCallout() {
    var state = editor()
    state.draft = "{name}.{ext}"
    #expect(state.callout?.kind == .warning)
    #expect(state.callout?.issue.code == .noHash)
    #expect(state.callout?.issue.message == "Without {hash}, two images can get the same key. Pinax refuses the second upload.")
    #expect(state.example?.map(\.text).joined() == "photo.png")

    state.draft = "{year}{month}/{name}-{hash}.{ext}"
    #expect(state.callout?.issue.message == "The key prefix “blog” isn’t used by this template.")
    #expect(state.example?.map(\.text).joined() == "202610/photo-3fa9c2e1b07d.png")

    state.draft = KeyTemplate.defaultTemplate
    #expect(state.callout == nil)
    #expect(state.example?.map(\.text).joined() == "blog/202610/photo-3fa9c2e1b07d.png")
  }

  @Test("The example follows the key prefix field as typed")
  func exampleFollowsPrefix() {
    var state = editor()
    state.keyPrefix = "notes/"
    #expect(state.example?.map(\.text).joined() == "notes/202610/photo-3fa9c2e1b07d.png")
  }

  @Test("UTC shows only with a date placeholder")
  func utcMark() {
    var state = editor()
    #expect(state.showsUTC)
    state.draft = "{prefix}/{name}-{hash}.{ext}"
    #expect(!state.showsUTC)
    state.draft = "{day}/{name}-{hash}.{ext}"
    #expect(state.showsUTC)
    // No example, no mark.
    state.draft = "{day}/{name}"
    #expect(!state.showsUTC)
  }

  // MARK: - Insert

  @Test("Insert puts the token at the cursor, or at the end without one")
  func insertAtCursor() {
    var state = editor()
    state.draft = "{prefix}/{name}-{hash}.{ext}"
    state.insert(.year)
    #expect(state.draft == "{prefix}/{name}-{hash}.{ext}{year}")
    #expect(state.cursor == ("{prefix}/{name}-{hash}.{ext}{year}" as NSString).length)

    state.draft = "{prefix}/{name}-{hash}.{ext}"
    state.cursor = ("{prefix}/" as NSString).length
    state.insert(.year)
    #expect(state.draft == "{prefix}/{year}{name}-{hash}.{ext}")
    #expect(state.cursor == ("{prefix}/{year}" as NSString).length)
  }

  @Test("The Insert menu lists the placeholders in order with sample values; no prefix value when the prefix is empty")
  func insertMenu() {
    let items = KeyTemplateEditor.insertMenu(keyPrefix: "blog", date: october)
    #expect(items.map(\.placeholder) == KeyTemplate.placeholders)
    #expect(items.map(\.sample) == ["blog", "2026", "10", "27", "photo", "3fa9c2e1b07d", "png"])
    let empty = KeyTemplateEditor.insertMenu(keyPrefix: "", date: october)
    #expect(empty.first?.sample == nil)
    #expect(empty.dropFirst().allSatisfy { $0.sample != nil })
  }

  @Test("The example splits into folders and the file; the file is all of a key without a slash")
  func examplePath() throws {
    let state = editor(prefix: "verylong something")
    let path = try #require(state.examplePath)
    #expect(path.folders == ["verylong something", "202610"])
    #expect(path.file == "photo-3fa9c2e1b07d.png")
    #expect(path.text == "verylong something/202610/photo-3fa9c2e1b07d.png")

    var flat = editor(prefix: "")
    flat.draft = "{name}-{hash}.{ext}"
    #expect(flat.examplePath == KeyTemplateEditor.ExamplePath(folders: [], file: "photo-3fa9c2e1b07d.png"))

    var broken = editor()
    broken.draft = "{prefix}/{name}"
    #expect(broken.examplePath == nil)
  }

  @Test("The UTC note and the popover's sample line say the date in words")
  func utcWording() {
    var state = editor()
    #expect(KeyTemplateEditor.utcStamp(october) == "27 Oct 2026, 23:30")
    #expect(state.utcNote == "Dates use UTC: 27 Oct 2026, 23:30.")
    #expect(state.sampleNote == "For a photo.png uploaded now. Dates use UTC (27 Oct 2026, 23:30).")

    state.draft = "{prefix}/{name}-{hash}.{ext}"
    #expect(state.utcNote == nil)
    #expect(state.sampleNote == "For a photo.png uploaded now.")
  }

  // MARK: - The field's tokens

  @Test("One backspace after a token removes the whole {…}")
  func atomicDelete() {
    let field = KeyTemplateTextView.make()
    field.template = "{prefix}/{name}-{hash}.{ext}"
    // prefix, /, name: the cursor sits after the name token.
    field.setSelectedRange(NSRange(location: 3, length: 0))
    field.deleteBackward(nil)
    #expect(field.template == "{prefix}/-{hash}.{ext}")
    #expect(field.templateCursor == ("{prefix}/" as NSString).length)

    // Forward delete before a token takes it whole too.
    field.setSelectedRange(NSRange(location: 0, length: 0))
    field.deleteForward(nil)
    #expect(field.template == "/-{hash}.{ext}")
  }

  @Test("Typing the closing brace turns the text into a token; copying gives the {…} text")
  func tokensAndCopy() {
    let field = KeyTemplateTextView.make()
    field.template = "{prefix}/{nam"
    #expect(field.tokenCount == 1)
    field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
    field.insertText("e}", replacementRange: field.selectedRange())
    #expect(field.template == "{prefix}/{name}")
    #expect(field.tokenCount == 2)
    #expect(field.templateCursor == ("{prefix}/{name}" as NSString).length)

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinax-k4-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    field.selectAll(nil)
    #expect(field.writeSelection(to: pasteboard, types: [.string]))
    #expect(pasteboard.string(forType: .string) == "{prefix}/{name}")
  }

  @Test("Misspelt and unclosed {…} stay text and are marked invalid")
  func invalidStaysText() {
    let field = KeyTemplateTextView.make()
    field.template = "{nme}/{name}.{ext"
    #expect(field.tokenCount == 1)
    #expect(field.string == "{nme}/\u{FFFC}.{ext")
    #expect(field.invalidDisplayRanges == [NSRange(location: 0, length: 5), NSRange(location: 8, length: 4)])
  }

  @Test("A click anywhere in the field lands in the text, not the scroll view round it")
  func clickReachesText() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database))
    model.load()
    let row = try #require(model.snapshot?.rows.first { $0.slug == "blog" })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil) }
    window.contentView = NSHostingView(
      rootView: ProjectEditorView(row: row, backendSlugs: ["r2"], model: model))
    window.contentView?.layoutSubtreeIfNeeded()

    var stack: [NSView] = [window.contentView!]
    var found: KeyTemplateTextView?
    while let view = stack.popLast() {
      stack.append(contentsOf: view.subviews)
      if let text = view as? KeyTemplateTextView { found = text }
    }
    let text = try #require(found)
    let scroll = try #require(text.enclosingScrollView)
    let root = try #require(window.contentView?.superview)
    // The middle, and near the trailing end past the text.
    for x in [scroll.bounds.midX, scroll.bounds.maxX - 4] {
      let point = root.convert(scroll.convert(NSPoint(x: x, y: scroll.bounds.midY), to: nil), from: nil)
      #expect(root.hitTest(point) === text)
    }
  }
}
