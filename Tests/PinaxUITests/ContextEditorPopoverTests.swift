import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// Add Tag… / Edit Note… open a popover on the
/// right-clicked cell or row instead of a sheet.
/// 1. Each entry — grid cell, orphan cell, table row — opens the gallery's
///    one `contextEditor` from the menu its app view declares, and the
///    popover of that same cell or row (its `isPresented`, read through
///    `Mirror`) is the one that reads it.
/// 2. The tag list's filter, checkmarks and Return-keeps-open, through the
///    content view (hosted for focus; its `onSubmit` read off the view).
/// 3. The note's save and discard paths, and a mixed selection's draft.
/// No popover, menu or sheet is opened.
@MainActor
@Suite(.serialized) struct ContextEditorPopoverTests {
  private struct Fixture {
    let model: GalleryModel
    let reader: ReadOnlyCatalog
  }

  /// Six assets, ids 1–3 uploaded in July, 4–6 in August, shown newest
  /// first (6 … 1). Tags: 1 travel, 2 Trail, 3 travel, 4 work, 6 travel.
  /// Notes: 2, 4 and 6 "shared", 5 "different". A seventh, from June, is in
  /// blog's one completed scan, so Orphans lists the six.
  private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
    _ = NSApplication.shared  // the model reads `NSApp.currentEvent`
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tags = ["travel", "Trail", "travel", "work", nil, "travel"]
    for index in 0..<6 {
      let month = index < 3 ? "07" : "08"
      try seedAsset(
        database, index: index, uploadedAt: "2026-\(month)-0\(index + 1)T00:00:00Z",
        tag: tags[index])
    }
    try seedAsset(database, index: 6, uploadedAt: "2026-06-01T00:00:00Z")
    try seedLiveUsage(database, projectSlug: "blog", sha256: identifier(7), count: 1)
    let editor = EditableCatalog(database: database)
    for (id, note) in [(2, "shared"), (4, "shared"), (5, "different"), (6, "shared")] {
      try await editor.setNote(note, for: identifier(Int64(id)))
    }
    let reader = ReadOnlyCatalog(database: database)
    let model = GalleryModel(
      catalog: reader, editor: editor,
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    await model.loadInitialData()
    try await body(Fixture(model: model, reader: reader))
  }

  private func identifier(_ id: Int64) -> String { String(format: "%064x", id) }

  private func tags(_ fixture: Fixture, _ id: Int64) async throws -> [String] {
    try await fixture.reader.details(identifier(id)).tags.sorted()
  }

  private func note(_ fixture: Fixture, _ id: Int64) async throws -> String? {
    try await fixture.reader.details(identifier(id)).item.asset.note
  }

  // MARK: - Reading an entry as its app view declares it

  /// One cell's or row's context menu and the popover hung on it.
  private struct Entry {
    let menu: AssetContextMenuItems
    let popover: AssetContextEditorPopover
  }

  private func applied<M: ViewModifier>(_ modifier: M) -> M.Body {
    modifier.body(content: unsafeBitCast((), to: _ViewModifier_Content<M>.self))
  }

  /// A grid or orphan cell: its `AssetContextMenuModifier`, applied.
  private func gridEntries(in view: Any) -> [Int64: Entry] {
    var found: [Int64: Entry] = [:]
    func walk(_ value: Any) {
      if let rows = value as? EditorRowsForEach {
        for (id, cell) in rows.cells() {
          guard let modifier = firstView(in: cell, typePrefix: "AssetContextMenuModifier")
            as? AssetContextMenuModifier
          else { continue }
          let body = applied(modifier)
          if let menu = firstView(in: body, typePrefix: "AssetContextMenuItems")
            as? AssetContextMenuItems,
            let popover = firstView(in: body, typePrefix: "AssetContextEditorPopover")
              as? AssetContextEditorPopover
          {
            found[id] = Entry(menu: menu, popover: popover)
          }
        }
        return
      }
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .class { return }
      mirror.children.forEach { walk($0.value) }
    }
    walk(view)
    return found
  }

  /// A table row: the menu its `TableRow` stores, and the popover on the
  /// Name column's cell for that row.
  private func tableEntries(_ model: GalleryModel) -> [Int64: Entry] {
    let body = AssetTableView(model: model).body
    var columns: [EditorTableColumn] = []
    func collect(_ value: Any) {
      if let column = value as? EditorTableColumn { columns.append(column); return }
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .class { return }
      mirror.children.forEach { collect($0.value) }
    }
    collect(body)
    let rows = (firstView(in: body, typePrefix: "ForEach<") as? EditorTableRowsForEach)?
      .tableRows() ?? []
    var found: [Int64: Entry] = [:]
    for row in rows {
      let popovers = columns.compactMap { column in
        column.cell(for: row.row).flatMap {
          firstView(in: $0, typePrefix: "AssetContextEditorPopover") as? AssetContextEditorPopover
        }.map { (column.title, $0) }
      }
      #expect(popovers.map(\.0) == ["Name"], "row \(row.row.id): popover on \(popovers.map(\.0))")
      if let menu = firstView(in: row.tableRowBody, typePrefix: "AssetContextMenuItems")
        as? AssetContextMenuItems, let popover = popovers.first?.1
      {
        found[row.row.id] = Entry(menu: menu, popover: popover)
      }
    }
    return found
  }

  private func isPresented(_ entry: Entry?) -> Binding<Bool>? {
    entry.flatMap {
      Mirror(reflecting: applied($0.popover)).descendant("modifier", "provider", "_isPresented")
        as? Binding<Bool>
    }
  }

  private func press(_ title: String, in entry: Entry?) {
    let views = (entry.flatMap { firstView(in: $0.menu.body, typePrefix: "ForEach<") }
      as? EditorMenuForEach)?.views() ?? []
    let action = views.lazy.compactMap { view in
      buttonAction(in: view) { label in
        "\(Mirror(reflecting: label).descendant("storage", "anyTextStorage", "key") ?? "")"
          .contains(title)
      }
    }.first
    #expect(action != nil, "\(title) not found in the entry's menu")
    action?()
  }

  // MARK: - 1. One editor state, read by the popover that hangs from the entry

  private func checkEntries(
    _ model: GalleryModel, rows: [GalleryModel.Row], _ entries: () -> [Int64: Entry]
  ) throws {
    #expect(Set(entries().keys) == Set(rows.map(\.id)), "entries: \(entries().keys.sorted())")
    // By display position, which differs per surface (the orphan report's
    // order is its own): selected 1, 3, 4 and right-clicked 3 — neither the
    // selection's first in display order nor its last; outside, 2.
    try #require(rows.count >= 6)
    let ids = rows.map(\.id)
    let clicked = ids[3]

    model.clearSelection()
    model.select(rows[4], mode: .replace)
    model.select(rows[3], mode: .toggle)
    model.select(rows[1], mode: .toggle)
    press("Add Tag", in: entries()[clicked])
    #expect(
      model.contextEditor
        == .init(kind: .tag, anchor: clicked, target: .selection([ids[1], ids[3], ids[4]])))
    for id in ids {
      #expect(isPresented(entries()[id])?.wrappedValue == (id == clicked), "popover on \(id)")
    }
    // Clicking outside closes it, through that same popover.
    isPresented(entries()[clicked])?.wrappedValue = false
    #expect(model.contextEditor == nil)

    press("Edit Note", in: entries()[clicked])
    #expect(model.contextEditor?.kind == .note)
    #expect(model.contextEditor?.anchor == clicked)
    #expect(isPresented(entries()[clicked])?.wrappedValue == true)
    model.dismissContextEditor(saving: false)

    // Outside the selection: that row alone, selected.
    model.selectedIDs = [ids[0], ids[1]]
    press("Add Tag", in: entries()[ids[2]])
    guard case let .row(single)? = model.contextEditor?.target else {
      Issue.record("expected a single-row target, got \(String(describing: model.contextEditor))")
      return
    }
    #expect(single.rowID == ids[2])
    #expect(model.contextEditor?.anchor == ids[2])
    #expect(model.selectedIDs == [ids[2]])
    #expect(isPresented(entries()[ids[2]])?.wrappedValue == true)
    #expect(isPresented(entries()[ids[0]])?.wrappedValue == false)
    model.dismissContextEditor(saving: false)
  }

  @Test("Grid cells: the menu opens the gallery's editor; that cell's popover reads it")
  func gridEntriesShareTheEditor() async throws {
    try await withFixture { fixture in
      fixture.model.groupsByMonth = false
      try checkEntries(fixture.model, rows: fixture.model.rows) {
        gridEntries(in: AssetGridView(model: fixture.model).body)
      }
    }
  }

  @Test("Orphan cells: the same editor and popover")
  func orphanEntriesShareTheEditor() async throws {
    try await withFixture { fixture in
      fixture.model.select(.orphans, in: SidebarModel.navigator(for: .orphans))
      await fixture.model.reload()
      let report = try #require(fixture.model.orphanReport)
      #expect(report.assets.count == 6)
      try checkEntries(fixture.model, rows: report.assets.map(GalleryModel.Row.init)) {
        gridEntries(in: OrphanView(model: fixture.model).body)
      }
    }
  }

  @Test("Table rows: the same editor; the popover hangs on the row's Name cell")
  func tableEntriesShareTheEditor() async throws {
    try await withFixture { fixture in
      fixture.model.groupsByMonth = false
      try checkEntries(fixture.model, rows: fixture.model.rows) { tableEntries(fixture.model) }
    }
  }

  // MARK: - 2. The tag list

  @Test("The tag list filters by the field, case-insensitively, and checks tags already on the target")
  func tagSuggestionsFunction() {
    let all = ["travel", "Trail", "work"]
    let names = { (s: [GalleryModel.ContextTagSuggestion]) in s.map(\.name) }
    #expect(names(GalleryModel.tagSuggestions(all, query: "", onTarget: [])) == all)
    #expect(names(GalleryModel.tagSuggestions(all, query: "  ", onTarget: [])) == all)
    #expect(names(GalleryModel.tagSuggestions(all, query: "TR", onTarget: [])) == ["travel", "Trail"])
    #expect(GalleryModel.tagSuggestions(all, query: "x", onTarget: []).isEmpty)
    #expect(
      GalleryModel.tagSuggestions(all, query: "ra", onTarget: ["travel"])
        == [.init(name: "travel", isOnTarget: true), .init(name: "Trail", isOnTarget: false)])
  }

  // Runs as `FocusSerial/ContextEditorPopover/tagPopoverContent()`.
  func tagPopoverContent() async throws {
    try await withFixture { fixture in
      let model = fixture.model
      // 1, 3 and 6 all have travel; 2 does not.
      model.beginContextTagEditing(for: .selection([6, 3, 1]), anchor: 3)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: AssetContextEditorContent(model: model))
      window.makeKeyAndOrderFront(nil)
      defer { window.orderOut(nil) }
      // Up to 5 s, and the window kept key: under the full suite another
      // suite's window can take key status, and SwiftUI focuses only in the
      // key window (1 red in 3 full runs with a 1 s wait and no re-key).
      var field: NSTextField?
      for _ in 0..<500 {
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        field = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
        if field != nil { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(field != nil, "the field has focus on open (first responder \(String(describing: window.firstResponder)))")

      let listed = { (firstView(in: ContextTagEditor(model: model).body, typePrefix: "ForEach<")
        as? EditorSuggestionsForEach)?.suggestions() ?? [] }
      #expect(listed().map(\.name).sorted() == ["Trail", "travel", "work"])
      #expect(listed().filter(\.isOnTarget).map(\.name) == ["travel"])
      model.contextTagQuery = "TR"
      #expect(listed().map(\.name).sorted() == ["Trail", "travel"])
      for _ in 0..<100 where field?.stringValue != "TR" {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(field?.stringValue == "TR", "the hosted field shows the query")

      // Return through the field's own onSubmit: ↓ to Trail, then submit.
      let submit = firstView(in: ContextTagEditor(model: model).body, typePrefix: "OnSubmitModifier")
        .flatMap { Mirror(reflecting: $0).descendant("action") }
      let onSubmit = try #require(submit as? () -> Void)
      // ↓ until Trail, the one not on every member.
      for _ in 0..<2 where model.contextTagHighlight != "Trail" {
        model.moveContextTagHighlight(by: 1)
      }
      let picked = try #require(model.contextTagHighlight)
      #expect(picked == "Trail")
      onSubmit()
      for _ in 0..<200 where try await !tags(fixture, 1).contains(picked) {
        try await Task.sleep(for: .milliseconds(10))
      }
      for id in [Int64(6), 3, 1] {
        #expect(try await tags(fixture, id).contains(picked), "\(picked) on \(id)")
      }
      #expect(model.contextEditor?.kind == .tag, "Return keeps the popover open")
      #expect(model.contextTagQuery.isEmpty, "and clears the field")
      #expect(listed().first { $0.name == picked }?.isOnTarget == true)

      // A typed new name; then a tag every member has: not added again.
      model.contextTagQuery = "night"
      onSubmit()
      for _ in 0..<200 where try await !tags(fixture, 6).contains("night") {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(try await tags(fixture, 6).contains("night"))
      let before = try await tags(fixture, 2)
      model.contextTagQuery = "travel"
      await model.submitContextTag()
      #expect(try await tags(fixture, 2) == before, "asset 2 untouched")
      #expect(model.contextEditor != nil)

      // A tag on only some members is not checked: 1 has travel, 2 has not.
      model.dismissContextEditor(saving: false)
      model.beginContextTagEditing(for: .selection([2, 1]), anchor: 1)
      #expect(listed().first { $0.name == "travel" }?.isOnTarget == false)
    }
  }

  @Test("Return on a tag only some members have adds it to the rest, once")
  func tagReturnFillsTheMissingMembers() async throws {
    try await withFixture { fixture in
      let model = fixture.model
      // travel is on 6 and 1, not on 5 (no tags) or 2 (Trail). Anchored on
      // 6, a member that already has it.
      model.beginContextTagEditing(for: .selection([6, 5, 2, 1]), anchor: 6)
      let submit = firstView(in: ContextTagEditor(model: model).body, typePrefix: "OnSubmitModifier")
        .flatMap { Mirror(reflecting: $0).descendant("action") }
      let onSubmit = try #require(submit as? () -> Void)
      #expect(model.contextTagSuggestions.first { $0.name == "travel" }?.isOnTarget == false)
      model.contextTagQuery = "travel"
      onSubmit()
      for _ in 0..<300 where try await !tags(fixture, 2).contains("travel") {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(try await tags(fixture, 5) == ["travel"], "5 lacked it")
      #expect(try await tags(fixture, 2) == ["Trail", "travel"], "2 lacked it")
      #expect(try await tags(fixture, 6) == ["travel"], "6 had it: once")
      #expect(try await tags(fixture, 1) == ["travel"], "1 had it: once")
      #expect(try await tags(fixture, 4) == ["work"], "4 is not in the target")
      #expect(model.contextTagSuggestions.first { $0.name == "travel" }?.isOnTarget == true)
      #expect(model.contextEditor?.kind == .tag, "Return keeps the popover open")
    }
  }

  // MARK: - 3. The note

  /// Presses the note popover's button as its view declares it. The walk
  /// stops at class instances: the editor's binding leads into the model.
  private func noteEditor(_ model: GalleryModel, press title: String) {
    func buttons(_ value: Any) -> [Any] {
      if String(describing: type(of: value)).hasPrefix("Button<") { return [value] }
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .class { return [] }
      return mirror.children.flatMap { buttons($0.value) }
    }
    let action = buttons(ContextNoteEditor(model: model).body).lazy.compactMap { button in
      buttonAction(in: button) { label in
        "\(Mirror(reflecting: label).descendant("storage", "anyTextStorage", "key") ?? "")"
          .contains("\"\(title)\"")
      }
    }.first
    #expect(action != nil, "no \(title) in the note popover")
    action?()
  }

  @Test("Edit Note popover: Esc discards, ⌘Return and clicking outside save; a mixed selection starts empty")
  func notePopover() async throws {
    try await withFixture { fixture in
      let model = fixture.model
      model.groupsByMonth = false
      let entries = gridEntries(in: AssetGridView(model: model).body)
      model.clearSelection()

      press("Edit Note", in: entries[2])
      #expect(model.noteDraft == "shared")
      model.noteDraft = "discarded"
      noteEditor(model, press: "Cancel")
      #expect(model.contextEditor == nil)
      #expect(model.contextEditorSave == nil)
      await model.contextEditorSave?.value
      #expect(try await note(fixture, 2) == "shared")

      press("Edit Note", in: entries[2])
      model.noteDraft = "saved"
      noteEditor(model, press: "Save")
      #expect(model.contextEditor == nil)
      await model.contextEditorSave?.value
      #expect(try await note(fixture, 2) == "saved")

      press("Edit Note", in: entries[5])
      #expect(model.noteDraft == "different")
      model.noteDraft = "outside"
      isPresented(entries[5])?.wrappedValue = false
      await model.contextEditorSave?.value
      #expect(try await note(fixture, 5) == "outside")
      #expect(try await note(fixture, 2) == "saved", "only the target is written")

      // Two members that agree bring their note; two that differ start empty.
      model.clearSelection()
      model.select(try #require(model.rows.first { $0.id == 4 }), mode: .replace)
      model.select(try #require(model.rows.first { $0.id == 6 }), mode: .toggle)
      press("Edit Note", in: gridEntries(in: AssetGridView(model: model).body)[4])
      #expect(model.noteDraft == "shared")
      model.dismissContextEditor(saving: false)
      model.select(try #require(model.rows.first { $0.id == 3 }), mode: .toggle)
      press("Edit Note", in: gridEntries(in: AssetGridView(model: model).body)[4])
      #expect(model.noteDraft == "", "6 and 4 say shared, 3 says nothing")
      // Clicking outside without typing writes nothing: the empty draft only
      // stands for "they differ", and saving it would wipe 4's and 6's notes.
      let mixed = gridEntries(in: AssetGridView(model: model).body)[4]
      isPresented(mixed)?.wrappedValue = false
      #expect(model.contextEditor == nil)
      await model.contextEditorSave?.value
      #expect(try await note(fixture, 4) == "shared", "an untouched mixed draft is not saved")
      #expect(try await note(fixture, 6) == "shared", "an untouched mixed draft is not saved")
    }
  }

  /// Selects `ids` as the grid's clicks would, then opens Edit Note from the
  /// first one's cell; returns that cell's entry.
  private func openNote(_ model: GalleryModel, on ids: [Int64]) throws -> Entry? {
    model.clearSelection()
    for (offset, id) in ids.enumerated() {
      model.select(try #require(model.rows.first { $0.id == id }), mode: offset == 0 ? .replace : .toggle)
    }
    let entry = gridEntries(in: AssetGridView(model: model).body)[ids[0]]
    press("Edit Note", in: entry)
    return entry
  }

  @Test("On a multiple selection, agreeing or mixed, Cancel writes nothing")
  func noteCancelOnASelection() async throws {
    try await withFixture { fixture in
      let model = fixture.model
      model.groupsByMonth = false

      // 4 and 6 agree ("shared"): the draft brings it; an edit, then Cancel.
      _ = try openNote(model, on: [4, 6])
      #expect(model.noteDraft == "shared")
      model.noteDraft = "edited"
      noteEditor(model, press: "Cancel")
      #expect(model.contextEditor == nil)
      #expect(model.contextEditorSave == nil, "no save started")
      await model.contextEditorSave?.value
      #expect(try await note(fixture, 4) == "shared")
      #expect(try await note(fixture, 6) == "shared")

      // 4, 5, 6 differ: the draft opens empty; typed, then Cancel.
      _ = try openNote(model, on: [4, 5, 6])
      #expect(model.noteDraft == "", "shared, different, shared")
      model.noteDraft = "typed over a mixed selection"
      noteEditor(model, press: "Cancel")
      #expect(model.contextEditorSave == nil, "no save started")
      await model.contextEditorSave?.value
      #expect(try await note(fixture, 4) == "shared")
      #expect(try await note(fixture, 5) == "different")
      #expect(try await note(fixture, 6) == "shared")
    }
  }

  /// A key-down of Esc, as AppKit would hand it: built, not posted.
  private let escape = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
    isARepeat: false, keyCode: 53)!
  private let mouseDown = NSEvent.mouseEvent(
    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!

  @Test("The popover closing itself on Esc writes nothing; on a click outside it saves")
  func notePopoverClosedByItself() async throws {
    try await withFixture { fixture in
      let model = fixture.model
      model.groupsByMonth = false
      var event: NSEvent? = nil
      model.currentEvent = { event }

      // Esc taken by the system popover, not the Cancel button: it comes
      // back through the popover's isPresented binding with Esc current.
      for ids: [Int64] in [[2], [4, 6], [4, 5, 6]] {
        let entry = try openNote(model, on: ids)
        model.noteDraft = "escaped \(ids)"
        event = escape
        isPresented(entry)?.wrappedValue = false
        #expect(model.contextEditor == nil, "\(ids)")
        #expect(model.contextEditorSave == nil, "\(ids): no save started")
        await model.contextEditorSave?.value
      }
      for (id, expected) in [(2, "shared"), (4, "shared"), (5, "different"), (6, "shared")] {
        #expect(try await note(fixture, Int64(id)) == expected, "\(id) after Esc")
      }

      // The same binding with a mouse-down current: a click outside saves.
      var entry = try openNote(model, on: [4, 6])
      model.noteDraft = "clicked away"
      event = mouseDown
      isPresented(entry)?.wrappedValue = false
      await model.contextEditorSave?.value
      #expect(try await note(fixture, 4) == "clicked away")
      #expect(try await note(fixture, 6) == "clicked away")
      #expect(try await note(fixture, 5) == "different", "only the target is written")

      // And still not an untouched draft (15ac6e5): 4, 5, 6 now differ.
      entry = try openNote(model, on: [4, 5, 6])
      #expect(model.noteDraft == "")
      isPresented(entry)?.wrappedValue = false
      await model.contextEditorSave?.value
      #expect(try await note(fixture, 4) == "clicked away")
      #expect(try await note(fixture, 5) == "different")
    }
  }
}

/// The tests above that need key status or a first responder, run
/// only in the serial `FocusSerial` invocation (see `FocusSerial`).
extension FocusSerial {
  @MainActor
  @Suite struct ContextEditorPopover {
    @Test("Add Tag popover: focused field, filtered checked list, Return adds and stays open")
    func tagPopoverContent() async throws { try await ContextEditorPopoverTests().tagPopoverContent() }
  }
}


private protocol EditorRowsForEach { func cells() -> [(Int64, Any)] }
extension ForEach: EditorRowsForEach where Data == [GalleryModel.Row] {
  fileprivate func cells() -> [(Int64, Any)] { data.map { ($0.id, content($0)) } }
}

private protocol EditorTableRowsForEach { func tableRows() -> [AssetTableRow] }
extension ForEach: EditorTableRowsForEach where Content == AssetTableRow {
  fileprivate func tableRows() -> [AssetTableRow] { data.map { content($0) } }
}

private protocol EditorMenuForEach { func views() -> [Any] }
extension ForEach: EditorMenuForEach where Data == [GalleryModel.ContextMenuItem] {
  fileprivate func views() -> [Any] { data.map { content($0) } }
}

private protocol EditorSuggestionsForEach { func suggestions() -> [GalleryModel.ContextTagSuggestion] }
extension ForEach: EditorSuggestionsForEach where Data == [GalleryModel.ContextTagSuggestion] {
  fileprivate func suggestions() -> [GalleryModel.ContextTagSuggestion] { data }
}

/// A table column's cell for a row, through the closure the column stores.
private protocol EditorTableColumn {
  var title: String { get }
  func cell(for row: GalleryModel.Row) -> Any?
}
extension TableColumn: EditorTableColumn where RowValue == GalleryModel.Row {
  fileprivate var title: String {
    "\(Mirror(reflecting: self).descendant("label", "storage", "anyTextStorage", "key", "key") ?? "")"
  }
  fileprivate func cell(for row: GalleryModel.Row) -> Any? {
    (Mirror(reflecting: self).descendant("content") as? (GalleryModel.Row) -> Content).map { $0(row) }
  }
}
