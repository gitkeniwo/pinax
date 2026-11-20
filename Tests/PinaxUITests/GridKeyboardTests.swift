import AppKit
import CatalogCore
import Combine
import Foundation
import GRDB
@testable import PinaxUI
@preconcurrency import QuickLookUI
import SwiftUI
import Testing

/// Grid keyboard navigation. Properties:
///
/// 1. The arrows walk the rows the grid draws: one cell, one row at the
///    rung's column count, month sections wrapping on their own, a short
///    row taken at its last cell; Home / End; ⇧ extends from the unmoved
///    anchor. Model-level, at 4 and 8 columns, grouped and not.
/// 2. Selection is not a query, on the arrow path: key presses on the focused, hosted grid
///    move the selection and fire no query (the positive control — a
///    search keystroke — does).
/// 3. Edit ▸ Select All / Copy go to whichever holds focus: the grid selects
///    all loaded rows / copies the selection in the default format; the
///    search field selects / copies its own text and the grid's selection
///    is untouched.
/// 4. The curation keys `.`, space and ⌘⌫ still type in the search and note fields once
///    the grid can hold focus, and still act on the focused grid.
/// 5. The app's own wiring behind 3: `PinaxCommands`
///    leaves the system's Edit ▸ Cut / Copy / Paste / Select All group in
///    place, and ⌘C's default is the one `PinaxAppModel` hands over from the
///    settings — at launch and when changed while running.
///
/// Hosted in a real window: focus reaches the grid by Tab (synthesised
/// clicks do not drive SwiftUI's tap gestures in the test process —
/// measured), keys go to the window as `NSApp.sendEvent` would send them
/// (`press`), and the model's
/// `currentEvent` seam holds the key being handled. The Edit menu is a
/// stand-in carrying `PinaxCommands`' three curation items; AppKit matches its ⌘
/// key equivalent before the responder chain and its plain `.` and space
/// only after the whole chain declined the key (both measured here).
@MainActor
@Suite(.serialized) struct GridKeyboardTests {
  /// Records the keys that travel the whole responder chain unhandled.
  final class RecordingWindow: NSWindow {
    var unhandledKeys: [String] = []
    override func keyDown(with event: NSEvent) {
      unhandledKeys.append(event.charactersIgnoringModifiers ?? "")
      super.keyDown(with: event)
    }
  }

  /// The three curation items as `PinaxCommands` declares them (same keys, same
  /// model calls, same `Task` wrapping).
  final class CommandTarget: NSObject {
    let model: GalleryModel
    init(model: GalleryModel) { self.model = model }
    @MainActor @objc func favorite(_ sender: Any?) {
      Task { await model.toggleFavoriteFromCommand() }
    }
    @MainActor @objc func quickLook(_ sender: Any?) {
      model.toggleQuickLookFromCommand()
    }
    @MainActor @objc func archive(_ sender: Any?) {
      Task { await model.archiveOrPutBackFromCommand() }
    }
  }

  private final class ReloadProbe {
    private(set) var count = 0
    private var cancellable: AnyCancellable?
    private var wasLoading = false

    @MainActor
    func track(_ model: GalleryModel) {
      cancellable = model.$isLoadingPage.sink { loading in
        if loading && !self.wasLoading { self.count += 1 }
        self.wasLoading = loading
      }
    }
  }

  private struct Fixture {
    let model: GalleryModel
    let database: DatabasePool
    let directory: URL
    let window: RecordingWindow
  }

  // MARK: - Fixtures and drivers

  private func makeModel(
    months: [(String, Int)] = [("2026-08", 9)],
    panel: FakeQuickLookPanel? = nil, originals: OriginalFetchProbe? = nil
  ) async throws -> (GalleryModel, DatabasePool, URL) {
    let (database, directory) = try makeUITestDatabase()
    var index = 0
    for (month, count) in months {
      for day in 1...count {
        try seedAsset(
          database, index: index, uploadedAt: String(format: "\(month)-%02dT00:00:00Z", day))
        index += 1
      }
    }
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let quickLook = panel.map { panel in
      QuickLookController(
        thumbnails: thumbnails,
        originals: (originals ?? OriginalFetchProbe()).cache(
          in: directory.appendingPathComponent("originals", isDirectory: true)),
        panel: { panel })
    }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: thumbnails, quickLook: quickLook)
    await model.loadInitialData()
    return (model, database, directory)
  }

  private func makeHostedFixture(
    panel: FakeQuickLookPanel? = nil, originals: OriginalFetchProbe? = nil
  ) async throws -> Fixture {
    let (model, database, directory) = try await makeModel(panel: panel, originals: originals)
    let window = RecordingWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    await spin(1.0)
    return Fixture(model: model, database: database, directory: directory, window: window)
  }

  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<60 where !condition() {
      await spin(0.05)
    }
  }

  private func keyEvent(
    _ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
    in window: NSWindow
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: keyCode)!
  }

  /// The key being handled, as `NSApp.currentEvent` holds it in the app.
  /// `NSApp.nextEvent` would set the real one, but the test process exits
  /// on the next run-loop turn after dequeuing (measured), so the model's
  /// seam carries it instead.
  final class CurrentEvent {
    var event: NSEvent?
  }

  private func track(_ current: CurrentEvent, _ model: GalleryModel) {
    model.currentEvent = { [current] in current.event }
  }

  /// A key press, delivered the way `NSApp.sendEvent` does — the main
  /// menu's ⌘ key equivalents first, then the window — but addressed to this
  /// window only: through `NSApp.sendEvent` it measurably reached other
  /// suites' hosted windows in the parallel run and moved their selections.
  private func press(
    _ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
    in window: NSWindow, current: CurrentEvent? = nil
  ) async {
    let event = keyEvent(characters, keyCode, flags, in: window)
    current?.event = event
    if flags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
      await spin(0.15)
      return
    }
    window.sendEvent(event)
    await spin(0.15)
  }

  private func arrow(_ key: Int, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) async {
    await press(String(UnicodeScalar(UInt16(key))!), code, flags, in: window)
  }

  private func right(_ w: NSWindow, _ flags: NSEvent.ModifierFlags = []) async {
    await arrow(NSRightArrowFunctionKey, 124, flags, in: w)
  }
  private func left(_ w: NSWindow) async { await arrow(NSLeftArrowFunctionKey, 123, in: w) }
  private func down(_ w: NSWindow) async { await arrow(NSDownArrowFunctionKey, 125, in: w) }
  private func up(_ w: NSWindow) async { await arrow(NSUpArrowFunctionKey, 126, in: w) }

  /// Tabs until the grid holds focus, detected by an arrow that moves the
  /// selection; leaves the selection on row 0. False when the grid never
  /// takes focus.
  private func focusGrid(_ fixture: Fixture) async -> Bool {
    let (model, window) = (fixture.model, fixture.window)
    window.makeFirstResponder(nil)
    for _ in 0..<12 {
      model.select(model.rows[0])
      await press("\t", 48, in: window)
      await right(window)
      if model.selectedIDs == [model.rows[1].id] {
        model.select(model.rows[0])
        return true
      }
    }
    return false
  }

  /// Edit ▸ Select All / Copy are nil-targeted menu items: AppKit sends the
  /// action to the first object in the key window's responder chain that
  /// implements it and validates it. The test window cannot become key, so
  /// the walk is done here over the same chain.
  @discardableResult
  private func sendEditAction(_ action: Selector, in window: NSWindow) -> Bool {
    var responder = window.firstResponder
    while let current = responder {
      if current.responds(to: action) {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let validator = current as? NSUserInterfaceValidations,
          !validator.validateUserInterfaceItem(item)
        {
          return false
        }
        return NSApp.sendAction(action, to: current, from: item)
      }
      responder = current.nextResponder
    }
    return false
  }

  private func index(_ model: GalleryModel) -> [Int] {
    model.rows.indices.filter { model.selectedIDs.contains(model.rows[$0].id) }
  }

  private func textField(placeholder: String?, in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField, field.isEditable,
      placeholder == nil || field.placeholderString == placeholder
        || field.placeholderAttributedString?.string == placeholder
    {
      return field
    }
    for subview in view.subviews {
      if let found = textField(placeholder: placeholder, in: subview) { return found }
    }
    return nil
  }

  private func favoriteCount(_ database: DatabasePool) throws -> Int {
    try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset WHERE favorite = 1") ?? 0 }
  }

  private func archivedCount(_ database: DatabasePool) throws -> Int {
    try database.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset WHERE state = 'archived'") ?? 0
    }
  }

  private func installEditMenu(_ target: CommandTarget) -> NSMenu? {
    let saved = NSApp.mainMenu
    let edit = NSMenu(title: "Edit")
    for (title, action, key, flags) in [
      ("Favorite", #selector(CommandTarget.favorite(_:)), ".", NSEvent.ModifierFlags()),
      ("Quick Look", #selector(CommandTarget.quickLook(_:)), " ", []),
      ("Archive", #selector(CommandTarget.archive(_:)), "\u{7F}", [.command]),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = flags
      item.target = target
      edit.addItem(item)
    }
    let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    top.submenu = edit
    let main = NSMenu()
    main.addItem(top)
    NSApp.mainMenu = main
    return saved
  }

  // MARK: - 1. The walk (model)

  @Test("Arrows walk the drawn rows, month sections and short rows included; Home, End, ⇧")
  func arrowsWalkTheDrawnRows() async throws {
    // Grid order: August's five (rows 0–4), then July's three (rows 5–7).
    let (model, _, directory) = try await makeModel(months: [("2026-07", 3), ("2026-08", 5)])
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.rows.count == 8)
    #expect(model.groupsRowsByMonth, "Library ▸ All groups by month by default")
    func at(_ i: Int) { model.select(model.rows[i]) }
    func go(_ move: GalleryModel.GridMove, _ shift: Bool = false) -> [Int] {
      model.moveSelection(move, extending: shift)
      return index(model)
    }

    model.setGridColumns(4)  // August draws 4 + 1, July 3.
    #expect(go(.right) == [0], "nothing selected: the first key starts at the first row")
    #expect(go(.down) == [4], "one row down, same column")
    #expect(go(.down) == [5], "past August's last row into July's first")
    #expect(go(.up) == [4])
    #expect(go(.up) == [0])
    at(3)
    #expect(go(.down) == [4], "a short row is taken at its last cell")
    #expect(go(.right) == [5], "← → walk the display order across sections")
    #expect(go(.left) == [4])
    at(0)
    #expect(go(.left) == [0], "no row before the first")
    #expect(go(.end) == [7])
    #expect(go(.down) == [7], "no row after the last")
    #expect(go(.home) == [0])

    model.setGridColumns(8)  // Each month is one drawn row.
    at(2)
    #expect(go(.down) == [7], "column 2 of July's 3 cells")
    #expect(go(.up) == [2])
    at(4)
    #expect(go(.down) == [7], "column 4 onto July's 3 cells: its last")

    model.groupsByMonth = false  // One section: rows of 4 across both months.
    model.setGridColumns(4)
    at(3)
    #expect(go(.down) == [7])
    at(4)
    #expect(go(.down) == [4], "row 4 is on the last drawn row")

    // ⇧: the anchor stays, the cursor moves, the range grows from the anchor.
    at(1)
    #expect(go(.right, true) == [1, 2])
    #expect(go(.down, true) == [1, 2, 3, 4, 5, 6])
    #expect(model.selectionAnchor == model.rows[1].id)
    #expect(go(.home, true) == [0, 1, 2, 3, 4, 5, 6])
  }

  // MARK: - 2. Selection is not a query, on the key path (hosted)

  // Runs as `FocusSerial/GridKeyboard/keysMoveSelectionWithoutQueries()`.
  func keysMoveSelectionWithoutQueries() async throws {
    let fixture = try await makeHostedFixture()
    let (model, window) = (fixture.model, fixture.window)
    defer {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    #expect(model.gridColumns == 4)
    let focused = await focusGrid(fixture)
    try #require(focused, "the grid never took keyboard focus")

    let probe = ReloadProbe()
    probe.track(model)
    let baseline = probe.count

    await right(window)
    #expect(index(model) == [1])
    await down(window)
    #expect(index(model) == [5])
    await left(window)
    #expect(index(model) == [4])
    await up(window)
    #expect(index(model) == [0])
    await right(window, .shift)
    await right(window, .shift)
    #expect(index(model) == [0, 1, 2], "⇧ extends from the anchor")
    await press(String(UnicodeScalar(UInt16(NSEndFunctionKey))!), 119, in: window)
    #expect(index(model) == [8])
    await press(String(UnicodeScalar(UInt16(NSHomeFunctionKey))!), 115, in: window)
    #expect(index(model) == [0])
    await spin(0.3)
    #expect(probe.count == baseline, "a key press re-ran the query")

    // Positive control: the instrument counts a reload when one is due.
    model.searchText = "asset-1"
    await waitUntil { probe.count > baseline }
    #expect(probe.count > baseline)
  }

  // MARK: - 3. ⌘A / ⌘C follow focus (hosted)

  // Runs as `FocusSerial/GridKeyboard/selectAllAndCopyFollowFocus()`.
  func selectAllAndCopyFollowFocus() async throws {
    let fixture = try await makeHostedFixture()
    let (model, window) = (fixture.model, fixture.window)
    let pasteboard = NSPasteboard.general
    let savedClipboard = pasteboard.string(forType: .string)
    defer {
      pasteboard.clearContents()
      if let savedClipboard { pasteboard.setString(savedClipboard, forType: .string) }
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    // Markdown, not the list's first entry: ⌘C must follow the default.
    model.defaultCopyFormat = CopyFormat.factory[1]

    // Grid focus.
    let focused = await focusGrid(fixture)
    #expect(focused, "the grid never took keyboard focus")
    #expect(sendEditAction(#selector(NSResponder.selectAll(_:)), in: window))
    await spin(0.2)
    #expect(model.selectedIDs.count == 9, "Select All on the grid selects every loaded row")
    pasteboard.clearContents()
    #expect(sendEditAction(#selector(NSText.copy(_:)), in: window))
    await spin(0.2)
    let expected = (0..<9).reversed()
      .map { "![asset-\($0)](https://img.example.com/blog/asset-\($0).png)" }
      .joined(separator: "\n")
    #expect(pasteboard.string(forType: .string) == expected, "⌘C on the grid: default format, grid order")

    // Search-field focus.
    model.select(model.rows[0])
    model.isSearchPresented = true
    await spin(0.4)
    let field = try #require(textField(placeholder: nil, in: window.contentView))
    #expect(window.makeFirstResponder(field))
    model.searchText = "asset"
    await spin(0.5)
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.setSelectedRange(NSRange(location: 1, length: 0))
    let selectionBefore = model.selectedIDs
    #expect(sendEditAction(#selector(NSResponder.selectAll(_:)), in: window))
    await spin(0.2)
    #expect(editor.selectedRange() == NSRange(location: 0, length: 5), "the field's text is selected")
    #expect(model.selectedIDs == selectionBefore, "the grid's selection is untouched")
    pasteboard.clearContents()
    #expect(sendEditAction(#selector(NSText.copy(_:)), in: window))
    await spin(0.2)
    #expect(pasteboard.string(forType: .string) == "asset", "⌘C in the field copies its text")
  }

  // MARK: - 4. Curation keys (hosted)

  // Runs as `FocusSerial/GridKeyboard/curationKeysTypeInTextFields()`.
  func curationKeysTypeInTextFields() async throws {
    let fixture = try await makeHostedFixture()
    let (model, window, database) = (fixture.model, fixture.window, fixture.database)
    let target = CommandTarget(model: model)
    let savedMenu = installEditMenu(target)
    let current = CurrentEvent()
    track(current, model)
    defer {
      NSApp.mainMenu = savedMenu
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    let focused = await focusGrid(fixture)
    #expect(focused, "the grid never took keyboard focus")
    model.select(model.rows[0])
    model.showsInspector = true
    model.isSearchPresented = true
    await spin(0.8)
    let probe = ReloadProbe()
    probe.track(model)

    for (name, placeholder) in [("search", nil), ("note", "Add a note…")] as [(String, String?)] {
      await waitUntil { textField(placeholder: placeholder, in: window.contentView) != nil }
      let field = try #require(textField(placeholder: placeholder, in: window.contentView), "\(name)")
      #expect(window.makeFirstResponder(field), "\(name)")
      await spin(0.2)
      let editor = try #require(window.firstResponder as? NSTextView, "\(name)")
      editor.string = "ab"
      editor.setSelectedRange(NSRange(location: 2, length: 0))
      let reloadsBefore = probe.count

      // The key path: the field takes the keys.
      await press(".", 47, in: window, current: current)
      await press(" ", 49, in: window, current: current)
      #expect(editor.string == "ab. ", "\(name): typed, not taken by the menu")

      // ⌘⌫ is a ⌘ key equivalent, so the menu does take it first.
      await press("\u{7F}", 51, .command, in: window, current: current)
      await spin(0.3)
      #expect(editor.string == "", "\(name): ⌘⌫ deletes to the start of the line")

      #expect(try favoriteCount(database) == 0, "\(name): nothing favourited")
      #expect(try archivedCount(database) == 0, "\(name): nothing archived")
      #expect(!model.quickLook.isVisible, "\(name): no Quick Look")

      // The search keys re-ran the query ("ab." matches nothing, then ""),
      // and the note field exists only while details are loaded: a query
      // still in flight can land under the focused note field and rebuild
      // it (measured in a full run: the note pass found the window, not the
      // field editor, first responder). Wait for the last query and the
      // details it brings back. A superseded query leaves `isLoadingPage`
      // set, so false means the newest one finished.
      if placeholder == nil {
        await waitUntil {
          probe.count > reloadsBefore && !model.isLoadingPage && model.selectedDetails != nil
        }
      }
    }
  }

  // Runs as `FocusSerial/GridKeyboard/curationKeysActOnTheGrid()`.
  func curationKeysActOnTheGrid() async throws {
    let fixture = try await makeHostedFixture()
    let (model, window, database) = (fixture.model, fixture.window, fixture.database)
    let target = CommandTarget(model: model)
    let savedMenu = installEditMenu(target)
    let current = CurrentEvent()
    track(current, model)
    defer {
      NSApp.mainMenu = savedMenu
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    let focused = await focusGrid(fixture)
    try #require(focused, "the grid never took keyboard focus")
    let first = model.rows[0].id

    // The grid lets `.` and space through untouched: they travel the whole
    // responder chain, and at its end AppKit's menu answers plain-key
    // shortcuts — the same path they took before the grid could hold focus.
    window.unhandledKeys = []
    await press(".", 47, in: window, current: current)
    await waitUntil { (try? favoriteCount(database)) == 1 }
    #expect(try favoriteCount(database) == 1, "`.` favourites the grid's selection")
    await press(" ", 49, in: window, current: current)
    await waitUntil { model.quickLook.isVisible }
    #expect(model.quickLook.isVisible, "space opens Quick Look")
    // The real panel, wired by the app's own `attach`: without its
    // delegate the panel never hands over ↑ ↓, never asks where to zoom from
    // and never tells the controller it closed.
    let shared = try #require(QLPreviewPanel.shared())
    #expect(shared.dataSource === model.quickLook, "the real panel's data source")
    #expect(shared.delegate === model.quickLook, "the real panel's delegate")
    #expect(window.unhandledKeys == [".", " "])
    #expect(model.selectedIDs == [first])
    await press(" ", 49, in: window, current: current)
    await waitUntil { !model.quickLook.isVisible }

    await press("\u{7F}", 51, .command, in: window, current: current)
    await waitUntil { (try? archivedCount(database)) == 1 }
    #expect(try archivedCount(database) == 1, "⌘⌫ archives the grid's selection")
  }

  // MARK: - 6. Keys with the Quick Look panel open

  /// Arrows and Space reach the grid, "one press, one step", with the panel
  /// open. The panel is a stand-in that treats keys as the real one was
  /// measured to (`FakeQuickLookPanel`); everything between it and the grid
  /// — the controller's `handle` and index observation, the model's
  /// navigator hook, the grid's installed arrow entry — is the app's own.
  // Runs as `FocusSerial/GridKeyboard/quickLookKeysMoveOnce()`.
  func quickLookKeysMoveOnce() async throws {
    let panel = FakeQuickLookPanel()
    let originals = OriginalFetchProbe()
    let fixture = try await makeHostedFixture(panel: panel, originals: originals)
    let (model, window) = (fixture.model, fixture.window)
    defer {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    let focused = await focusGrid(fixture)
    try #require(focused, "the grid never took keyboard focus")
    let url = { (i: Int) in URL(string: model.rows[i].item.url)! }

    model.toggleQuickLookFromCommand()
    #expect(panel.isVisible)
    #expect(panel.count == model.rows.count, "the panel pages through the loaded rows")
    #expect(panel.currentPreviewItemIndex == 0)
    await waitUntil { originals.started == [url(0)] }

    // Grid → panel: the grid has focus in the main window.
    await right(window)
    #expect(index(model) == [1], "one arrow on the grid moves one cell")
    #expect(panel.currentPreviewItemIndex == 1)
    await waitUntil { originals.cancelled.contains(url(0)) }
    #expect(originals.cancelled.contains(url(0)), "moving on cancels the previous original")

    // Keys in the panel: ↓ is handed over, ← → the panel takes itself.
    panel.press(quickLookKey(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125))
    await spin(0.15)
    #expect(index(model) == [5], "↓ in the panel moves one row")
    #expect(panel.currentPreviewItemIndex == 5)
    panel.press(quickLookKey(String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!), 123))
    await spin(0.15)
    #expect(index(model) == [4], "← in the panel moves one cell")
    #expect(panel.currentPreviewItemIndex == 4)

    // Panel ◀ ▶ → grid.
    panel.clickNext()
    await spin(0.15)
    #expect(index(model) == [5])
    panel.clickPrevious()
    panel.clickPrevious()
    await spin(0.15)
    #expect(index(model) == [3])
    #expect(panel.currentPreviewItemIndex == 3)

    await waitUntil { originals.started.last == url(3) }
    let fetched = Set(originals.started)
    #expect(fetched.isSubset(of: Set([0, 1, 5, 4, 3].map(url))), "only current entries fetch")
    #expect(!fetched.contains(url(8)))

    // Space handed over closes through View ▸ Quick Look's own path.
    #expect(model.quickLook.previewPanel(nil, handle: quickLookKey(" ", 49)))
    await waitUntil { !panel.isVisible }
    #expect(!panel.isVisible)

    // Closed: the grid alone.
    await right(window)
    #expect(index(model) == [4])
    #expect(!panel.isVisible)
  }

  /// Closing hands the
  /// panel the selected cell's own frame on screen — the anchor the cell
  /// registered — and, the grid filling its cells, the part of the
  /// thumbnail the cell shows; the controller lets go of the panel only at
  /// `windowWillClose`. The panel behaves as measured (`FakeQuickLookPanel`).
  @Test("Closing Quick Look zooms back into the selected cell's frame and visible crop")
  func quickLookClosesIntoCell() async throws {
    let panel = FakeQuickLookPanel()
    let fixture = try await makeHostedFixture(panel: panel)
    let (model, window) = (fixture.model, fixture.window)
    defer {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    // A thumbnail file whose shape (1:2) is not the cell's.
    let row = model.rows[2]
    _ = await model.thumbnails.store(
      data: pngData(width: 300, height: 600),
      for: ThumbnailRequest(sha256: row.item.asset.sha256, sourceURL: URL(string: row.item.url)!))
    #expect(model.gridThumbnailSizing == .fillGrid)
    model.select(row)
    await spin(0.2)

    model.toggleQuickLookFromCommand()
    #expect(panel.isVisible)
    model.toggleQuickLookFromCommand()

    let anchor = try #require(anchorView(for: row, in: window))
    let cellOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    #expect(panel.closingSourceFrames == [cellOnScreen], "asked once, answered with the cell")
    #expect(cellOnScreen.width > 0)
    let image = try #require(panel.closingImages.first ?? nil)
    #expect(
      panel.closingContentRects
        == [AspectFill.visibleRect(image: image.size, in: anchor.bounds.size)])
    #expect(panel.closingContentRects.first != NSRect(origin: .zero, size: image.size))
    #expect(panel.controller != nil, "the delegate stays for the zoom back")
    await waitUntil { panel.controller == nil }
    #expect(panel.controller == nil, "and goes at windowWillClose")
    #expect(!panel.isVisible)

    model.toggleQuickLookFromCommand()
    #expect(panel.isVisible, "the next open attaches again")
    #expect(panel.controller != nil)
  }

  private func anchorView(for row: GalleryModel.Row, in window: NSWindow) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier(
      "PinaxAssetGridCellThumbnail-\(row.item.asset.sha256)")
    var stack = window.contentView.map { [$0] } ?? []
    while let view = stack.popLast() {
      if view.identifier == identifier, view.window === window, view.bounds.width > 0 {
        return view
      }
      stack.append(contentsOf: view.subviews)
    }
    return nil
  }

  // MARK: - 5. The app's own wiring

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-grid-keyboard-tests-\(UUID().uuidString)"))
  }

  /// A group placement's identity. SwiftUI keeps it per process, the same
  /// value however often `.pasteboard` is read (measured).
  private func placementID(_ placement: CommandGroupPlacement) -> String {
    "\(Mirror(reflecting: placement).descendant("id") ?? "")"
  }

  /// The command groups a `Commands` body declares, as placement and
  /// mutation (`replace`, `append`, `prepend` — measured). A group's items
  /// sit inside a SwiftUI resolver closure, out of reflection's reach; the
  /// placement and mutation are what show a system group taken away.
  private func commandGroups(in commands: Any) -> [(placement: String, mutation: String)] {
    let mirror = Mirror(reflecting: commands)
    if String(describing: type(of: commands)).hasPrefix("CommandGroup<") {
      let placement = mirror.descendant("change", "placement", "id").map { "\($0)" } ?? ""
      let mutation = mirror.descendant("change", "mutation").map { "\($0)" } ?? ""
      return [(placement, mutation)]
    }
    return mirror.children.flatMap { commandGroups(in: $0.value) }
  }

  @Test("The app's commands keep the system Edit group whose ⌘A and ⌘C send selectAll: and copy:")
  func appCommandsKeepTheSystemPasteboardGroup() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: try makeDefaults(), databaseOpener: { database })
    let pasteboard = placementID(.pasteboard)
    func replacesPasteboard(_ groups: [(placement: String, mutation: String)]) -> Bool {
      groups.contains { $0.placement == pasteboard && $0.mutation == "replace" }
    }

    // The body the app installs (`.commands { PinaxCommands(app:) }`).
    let groups = commandGroups(in: PinaxCommands(app: app).body)
    #expect(
      groups.contains { $0.placement == pasteboard && $0.mutation == "append" },
      "the walk reaches the real body: Copy URL … Archive join the Edit group")
    #expect(
      !replacesPasteboard(groups),
      "Edit ▸ Copy / Select All are the system's `copy:` / `selectAll:` items, which the focused grid answers")

    // Positive control: the walk sees the group taken away.
    #expect(replacesPasteboard(commandGroups(in: CommandGroup(replacing: .pasteboard) {})))
  }

  @Test("⌘C's default format is the one the settings name, handed over at launch and on change")
  func defaultCopyFormatComesFromTheSettings() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    let defaults = try makeDefaults()
    // Set in Settings before this launch; not the list's first entry.
    PreferencesStore(defaults: defaults).defaultCopyFormatID = CopyFormat.markdown.id
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    await gallery.loadInitialData()
    gallery.select(try #require(gallery.rows.first))
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinax-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    // What the focused grid's `copy:` runs (hosted above).
    gallery.copySelectionInDefaultFormat(to: pasteboard)
    #expect(
      pasteboard.string(forType: .string) == "![asset-0](https://img.example.com/blog/asset-0.png)",
      "at launch: the saved default")

    // Changed in Settings while the window is open — to HTML, not URL:
    // URL is the list's first entry, so a push that sent `formats.first`
    // instead of the chosen default would pass.
    app.preferences.defaultCopyFormatID = CopyFormat.html.id
    gallery.copySelectionInDefaultFormat(to: pasteboard)
    #expect(
      pasteboard.string(forType: .string)?.hasPrefix(
        #"<img src="https://img.example.com/blog/asset-0.png""#) == true,
      "after the change: the new default")
  }
}

/// The tests above that need key status or a first responder, run
/// only in the serial `FocusSerial` invocation (see `FocusSerial`).
extension FocusSerial {
  @MainActor
  @Suite struct GridKeyboard {
    @Test("Keys on the focused grid move the selection and fire no query")
    func keysMoveSelectionWithoutQueries() async throws { try await GridKeyboardTests().keysMoveSelectionWithoutQueries() }

    @Test("Select All and Copy act on the focused grid, and on the text in a focused field")
    func selectAllAndCopyFollowFocus() async throws { try await GridKeyboardTests().selectAllAndCopyFollowFocus() }

    @Test("`.`, space and ⌘⌫ type in the search and note fields once the grid can hold focus")
    func curationKeysTypeInTextFields() async throws { try await GridKeyboardTests().curationKeysTypeInTextFields() }

    @Test("`.`, space and ⌘⌫ still act on the focused grid")
    func curationKeysActOnTheGrid() async throws { try await GridKeyboardTests().curationKeysActOnTheGrid() }

    @Test("With Quick Look open, each key moves the grid and the panel one step together")
    func quickLookKeysMoveOnce() async throws { try await GridKeyboardTests().quickLookKeysMoveOnce() }
  }
}

