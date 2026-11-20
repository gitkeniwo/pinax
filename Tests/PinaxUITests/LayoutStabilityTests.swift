import AppKit
import CatalogCore
import Combine
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// Layout stability, stated as properties rather than outcomes:
///
/// 1. Search text, scope, and presentation survive a selection change — the
///    search field's state lives on the model, outside the branch container.
/// 2. `selectedDetails` holds the previous asset while the next load is in
///    flight, so the inspector never collapses between two selections.
/// 3. A view inside the inspector's stable root appears exactly once per
///    hosting, no matter how the selection (or its absence) changes — hosted
///    against the real `AssetInspectorView`, not a structural copy.
/// 4. The appearance counter is proven able to fail: a falsifier twin with
///    the old branch-swap shape re-fires it on the same transitions (an
///    instrument that cannot go red proves nothing).
/// 5. The inspector toggle's window-coordinate frame is identical with
///    the inspector shown and hidden, while its toolbar neighbours slide.
/// 6. Keystrokes in the filter bar re-run no scan on report surfaces,
///    and do reload on the grid (the positive control).
/// 7. Escape reaches the filter bar and clears + dismisses it.
///
/// Serialized: these tests host real windows and focus, and Swift Testing's
/// default parallel execution interleaves them at suspension points —
/// another test's `makeKeyAndOrderFront` during our spin measurably broke
/// event routing (the Escape went to a leftover window).
@MainActor
@Suite(.serialized) struct LayoutStabilityTests {
  private final class AppearanceCounter {
    var count = 0
    func bump() { count += 1 }
  }

  private final class PresentationIdentityRecorder {
    var values: [UUID] = []
    func record(_ value: UUID) { values.append(value) }
  }

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-stability-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  private func makeEditableModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-stability-edit-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }
      )
    )
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  /// `RunLoop.run(until:)` is flagged unavailable from async contexts by a
  /// static check; the pump itself is ordinary main-thread synchronous work.
  nonisolated private func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  /// Pumps the main run loop so SwiftUI hosted in an offscreen window gets
  /// layout passes and appearance callbacks — the test runner does not run a
  /// window server event loop for us. Each runloop segment is followed by a
  /// suspension: this test function is itself on the main actor, and without
  /// yielding it the model's async loads can never run (measured: a purely
  /// synchronous pump left `selectedDetails` frozen).
  private func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// Pumps like `spin` until `condition` holds, then one more segment so
  /// the update the condition reflects is laid out — or until `timeout`,
  /// when the caller's assertions fail on what was read. A condition, not
  /// a delay: the parallel full run starves the main thread, and a fixed
  /// 0.4 s measurably read layouts and loads that had not landed yet.
  private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.05))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    pumpRunLoop(until: Date().addingTimeInterval(0.05))
  }

  private func host<Content: View>(
    _ content: Content, size: CGSize = CGSize(width: 320, height: 640)
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: content)
    window.orderFront(nil)
    return window
  }

  private func makeSeededModel() async throws -> (GalleryModel, URL) {
    let (database, directory) = try makeUITestDatabase()
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-08-02T00:00:00Z")
    let model = makeModel(database)
    await model.loadInitialData()
    return (model, directory)
  }

  // MARK: - Search state survives a selection change

  @Test("Search text, scope, and presentation survive a selection change")
  func searchStateSurvivesSelectionChange() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    model.searchText = "poster"
    model.searchScope = .key
    model.isSearchPresented = true
    for selection in [
      SidebarSelection.all, .recent, .orphans, .usage,
      .project("blog"), .tag("hero"),
    ] {
      model.sidebarSelection = selection
    }
    #expect(model.searchText == "poster")
    #expect(model.searchScope == .key)
    #expect(model.isSearchPresented)

    // The surviving state still composes into the next query.
    let query = model.makeQuery()
    #expect(query.search == "poster")
    #expect(query.searchField == .key)
  }

  // MARK: - The model holds previous details during a load

  @Test("selectedDetails holds the previous asset while the next load is in flight")
  func detailsHeldDuringLoad() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.rows.count == 2)

    let first = model.rows[0], second = model.rows[1]
    model.selectedIDs = [first.id]
    await waitUntil { model.selectedDetails?.item.asset.sha256 == first.item.asset.sha256 }

    // The load task for the new selection is queued, not run: until it lands,
    // the inspector keeps showing the previous asset instead of collapsing.
    model.selectedIDs = [second.id]
    #expect(model.selectedDetails?.item.asset.sha256 == first.item.asset.sha256)
    await waitUntil { model.selectedDetails?.item.asset.sha256 == second.item.asset.sha256 }
  }

  // MARK: - Identity inside the inspector survives (hosted)

  @Test("Inspector editors receive at least 80 percent of the content width")
  func inspectorEditorsReceiveFullWidth() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    let model = makeEditableModel(database)
    await model.loadInitialData()
    guard let row = model.rows.first else {
      Issue.record("no row available for the inspector layout test")
      return
    }
    model.select(row)
    await waitUntil { model.selectedDetails != nil }

    let hostWidth: CGFloat = 320
    let window = host(
      AssetInspectorView(model: model),
      size: CGSize(width: hostWidth, height: 640)
    )
    defer { window.orderOut(nil) }
    await spin(0.5)

    // The inspector caps its rendered content at its 300 pt column even
    // when a wider host proposes more. The block content excludes the root's
    // 10 pt inset on each side.
    let contentWidth = min(hostWidth, GalleryWidthBudget.inspectorWidth) - 20
    // Tags sits in a band's value column, right of the 48 pt key
    // column and its 8 pt gap (and the band's 2 pt insets); Note still
    // spans the band.
    let fields = DesignMetrics.inspectorFields.self
    let valueColumn =
      contentWidth - fields.keyWidth - fields.columnSpacing - 2 * fields.horizontalPadding
    for (placeholder, available) in [("Add a note…", contentWidth), ("Add tag…", valueColumn)] {
      let minimumEditorWidth = available * 0.8
      guard let field = textField(withPlaceholder: placeholder, in: window.contentView) else {
        Issue.record("\(placeholder) field was not found in the hosted inspector")
        continue
      }
      let renderedWidth = field.convert(field.bounds, to: window.contentView).width
      #expect(
        renderedWidth >= minimumEditorWidth,
        "\(placeholder) rendered at \(renderedWidth), below 80% of \(available)"
      )
    }
  }

  @Test("Inspector content never fits wider than its fixed column")
  func inspectorContentFitsInsideFixedColumn() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(database)
    let controller = NSHostingController(rootView: AssetInspectorView(model: model))

    // The real inspector animates from zero to 300 pt. Ask with a proposal
    // well inside that transition and assert the content cannot negotiate a
    // width beyond the fixed destination column.
    let fitted = controller.sizeThatFits(
      in: CGSize(width: 80, height: 640)
    )
    #expect(fitted.width <= GalleryWidthBudget.inspectorWidth)
  }

  @Test(
    "The sidebar stays at x zero and keeps its width across inspector visibility",
    arguments: [CGFloat(900), 1000, 1100, 1300]
  )
  func sidebarWidthIsInspectorInvariant(windowWidth: CGFloat) async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    // These tests measure the docked inspector, so they open it: the
    // launch default is closed, and the fixture says so rather than
    // leaning on a default it does not test.
    model.showsInspector = true

    let window = host(
      GalleryView(model: model), size: CGSize(width: windowWidth, height: 720)
    )
    defer { window.orderOut(nil) }
    await spin(0.8)

    #expect(
      dockedInspectorWidth(in: window) == GalleryWidthBudget.inspectorWidth,
      "Expected the inspector docked at \(windowWidth) pt"
    )

    guard let shownFrame = sidebarRenderedFrame(in: window) else {
      Issue.record("the hosted gallery's sidebar outline view was not found")
      return
    }

    model.showsInspector = false
    await spin(0.8)
    guard let hiddenFrame = sidebarRenderedFrame(in: window) else {
      Issue.record("the hosted gallery's sidebar outline view disappeared")
      return
    }

    #expect(shownFrame.width == hiddenFrame.width)
    #expect(shownFrame.minX == 0)
    #expect(hiddenFrame.minX == 0)
    #expect(shownFrame.width >= GalleryWidthBudget.sidebarMin)
    #expect(shownFrame.width <= GalleryWidthBudget.sidebarMax)
  }

  /// The inspector is a docked split column at every width — 900 (the
  /// minimum), either side of 1115 / 1120 (where the sidebar once jumped)
  /// and 1400. There is no overlay to cover the grid; the column sits
  /// beside it.
  @Test(
    "The inspector is docked at every window width",
    arguments: [CGFloat(900), 1115, 1120, 1400]
  )
  func inspectorIsDockedAtEveryWidth(windowWidth: CGFloat) async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    model.showsInspector = true

    let window = host(
      GalleryView(model: model), size: CGSize(width: windowWidth, height: 720)
    )
    defer { window.orderOut(nil) }
    await spin(0.8)

    #expect(model.showsInspector)
    #expect(dockedInspectorWidth(in: window) == GalleryWidthBudget.inspectorWidth)
    let frame = try #require(dockedInspectorFrame(in: window))
    #expect(frame.minX >= 0)
    #expect(frame.maxX <= windowWidth)
  }

  /// State identity survives 1300 to 900 to 1300: resizing across those
  /// widths keeps the inspector docked,
  /// its root `@State` and selection, and exactly one tracking separator.
  @Test("Resizing 1300 to 900 to 1300 keeps the inspector docked and its state")
  func inspectorStaysDockedAcrossResize() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    model.showsInspector = true
    let recorder = PresentationIdentityRecorder()
    let selected = model.rows[0]
    model.selectedIDs = [selected.id]
    await waitUntil { model.selectedDetails?.item.asset.sha256 == selected.item.asset.sha256 }

    let window = host(
      GalleryView(
        model: model,
        inspectorPresentationIdentityProbe: recorder.record
      ),
      size: CGSize(width: 1300, height: 420)
    )
    defer { window.orderOut(nil) }
    await spin(0.8)

    guard let initialIdentity = recorder.values.last else {
      Issue.record("the docked inspector identity state was not observed")
      return
    }
    // SwiftUI's own inspector separator (the mount adds none, since a
    // second on the same divider throws).
    func separators() -> Int {
      window.toolbar?.items.filter { isInspectorSeparator($0.itemIdentifier) }.count ?? -1
    }
    #expect(separators() == 1)

    for width: CGFloat in [900, 1300] {
      window.setContentSize(NSSize(width: width, height: 420))
      await spin(0.8)
      #expect(model.showsInspector)
      #expect(dockedInspectorWidth(in: window) == GalleryWidthBudget.inspectorWidth, "at \(width)")
      #expect(separators() == 1, "at \(width)")
      #expect(
        window.toolbar?.items.filter { $0.itemIdentifier == .toggleInspector }.count == 1)
      #expect(model.selectedDetails?.item.asset.sha256 == selected.item.asset.sha256)
    }
    #expect(Set(recorder.values) == [initialIdentity])
  }

  @Test("A view inside the inspector's stable root appears exactly once per hosting")
  func inspectorIdentitySurvives() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = model.rows[0], second = model.rows[1]
    model.selectedIDs = [first.id]
    await waitUntil { model.selectedDetails != nil }

    let counter = AppearanceCounter()
    let window = host(
      AssetInspectorView(model: model, identityProbe: { counter.bump() }))
    await spin(until: { counter.count >= 1 })
    #expect(counter.count == 1)

    // A → B: content swap inside the stable sections. Each step waits for
    // the load it starts to land (measured red in parallel full runs after
    // the fixed 0.4 s: `selectedDetails` still A, or still nil).
    model.selectedIDs = [second.id]
    await spin(until: { model.selectedDetails?.item.asset.sha256 == second.item.asset.sha256 })
    #expect(model.selectedDetails?.item.asset.sha256 == second.item.asset.sha256)
    #expect(counter.count == 1)

    // The nil pass that destroyed the old subtree: selection dropped (the
    // grid → orphans transition clears `rows` before the report lands), then
    // a new selection arrives. The sections must survive both halves.
    model.clearSelection()
    await spin(until: { model.selectedDetails == nil })
    #expect(model.selectedDetails == nil)
    model.selectedIDs = [first.id]
    await spin(until: { model.selectedDetails != nil })
    #expect(model.selectedDetails != nil)
    #expect(counter.count == 1)

    window.orderOut(nil)
  }

  @Test("The appearance counter detects the old branch-swap shape")
  func counterDetectsBranchSwap() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = model.rows[0]
    model.selectedIDs = [first.id]
    await waitUntil { model.selectedDetails != nil }

    let counter = AppearanceCounter()
    let window = host(BranchSwapInspector(model: model) { counter.bump() })
    await spin(until: { counter.count >= 1 })
    #expect(counter.count == 1)

    // Same nil pass as the stability test above — on the branch-swap shape
    // the subtree is destroyed and rebuilt, so the probe must fire again. If it
    // does not, the instrument in the test above cannot prove anything.
    model.clearSelection()
    await spin(until: { model.selectedDetails == nil })
    model.selectedIDs = [first.id]
    await spin(until: { model.selectedDetails != nil && counter.count >= 2 })
    #expect(counter.count >= 2)

    window.orderOut(nil)
  }

  // MARK: - Hosted gallery search state and focus across a branch switch

  /// The search field's contents and focus survive a selection change. Both halves are asserted here against a real hosted
  /// `GalleryView` going through real branch switches. The filter bar's
  /// field is a standard SwiftUI TextField with a real AppKit control behind
  /// it, so focus is asserted as responder identity: if the selection change
  /// destroyed the field's owning view, the window's field editor would
  /// resign and `firstResponder` would stop being the same object.
  // Runs as `FocusSerial/LayoutStability/hostedGalleryKeepsSearchState()`.
  func hostedGalleryKeepsSearchState() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    await spin(0.6)

    // ⌘F's path: presenting the bar focuses its field.
    model.isSearchPresented = true
    await spin(0.4)
    #expect(model.isSearchPresented)
    if window.firstResponder == nil || window.firstResponder === window {
      // The FocusState auto-focus did not land in this hosted context; focus
      // the field the way a click would rather than skip the focus half.
      guard let field = firstTextField(in: window.contentView) else {
        Issue.record("the filter bar's text field was not found in the hosted tree")
        return
      }
      #expect(window.makeFirstResponder(field))
    }
    await spin(0.3)
    let before = window.firstResponder
    #expect(before is NSTextView)

    model.searchText = "asset"
    await spin(0.4)
    #expect(model.searchText == "asset")

    // Through the orphan report view and back — the widest branch distance
    // the center column has; both switches run real reloads first.
    model.sidebarSelection = .orphans
    await spin(0.8)
    model.sidebarSelection = .all
    await spin(0.8)

    #expect(model.searchText == "asset")
    #expect(model.isSearchPresented)
    let after = window.firstResponder
    #expect(after === before)

    window.orderOut(nil)
  }

  // MARK: - A navigator switch leaves only the new tree's rows

  /// The regression: after Time → Library the sidebar drew the new labels
  /// over rows the old tree left behind. The instrument is the outline's
  /// own row views, not their text: SwiftUI draws a row's text through
  /// `CGDrawingView`, and in this host the rows expose no accessibility
  /// text, so a label cannot be read back (measured). What the defect is,
  /// measured before the fix: a `NSTableRowView` that belongs to no row
  /// (`row(for:) == -1`) stays visible on top of row 1 after Time →
  /// Library, one more per round trip; flat-to-flat switches (library,
  /// collections, reports in any order) left none. So the property is: after
  /// every switch, the outline has exactly the new tree's row count, every
  /// visible row view belongs to one of those rows, and each sits in its
  /// row's own rect.
  @Test("Switching navigators leaves only the new tree's rows in the outline")
  func navigatorSwitchLeavesOnlyTheNewTreesRows() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (index, day) in ["2026-08-01", "2026-07-02", "2026-03-02", "2025-12-02"].enumerated() {
      try seedAsset(database, index: index, uploadedAt: "\(day)T00:00:00Z")
    }
    let model = makeModel(database)
    await model.loadInitialData()
    let window = host(
      GalleryView(model: model), size: CGSize(width: 1300, height: 800))
    defer { window.orderOut(nil) }
    await spin(0.8)

    // Two rounds of the switch the user made, then every navigator once.
    let path: [SidebarNavigator] =
      [.time, .library, .time, .library, .collections, .time, .reports, .library]
    // Headers plus top-level rows, and the months of the one year the Time
    // tab opens by default. An empty Tags group draws its header alone (no
    // "No Tags" row).
    func expected() -> Int {
      let sections = model.sidebarSections
      let openYear =
        model.navigator == .time
        ? sections.flatMap(\.entries).first { $0.id == model.timeDefaultOpenRowID }?
          .children.count ?? 0
        : 0
      // The Library tab's shortcut sections start closed: header only.
      let drawn = sections.filter { $0.shortcut == nil }.map(\.entries.count).reduce(0, +)
      // Storage's roots start open on their loaded folders.
      let openRoots = sections.first { $0.id == "catalog" }?.entries
        .map(\.children.count).reduce(0, +) ?? 0
      return sections.count + drawn + openYear + openRoots
    }
    for (step, navigator) in path.enumerated() {
      model.navigator = navigator
      // Wait for the switch to reach the outline (measured red at a3c8dfa in
      // a parallel full run after the fixed 0.4 s: 0 rows of 3).
      await spin(until: {
        let outlines = allOutlines(in: window.contentView)
        guard outlines.count == 1, let outline = outlines.first else { return false }
        let visible = outline.subviews.compactMap { $0 as? NSTableRowView }.filter { !$0.isHidden }
        return outline.numberOfRows == expected() && visible.count == outline.numberOfRows
      })
      let expectedRows = expected()
      let context = "step \(step) → \(navigator.rawValue)"
      // Found afresh each step, and exactly one: a switch may replace the
      // outline, and then a retired one left in the window would be the
      // same defect one level up.
      let outlines = allOutlines(in: window.contentView)
      #expect(outlines.count == 1, "\(context): \(outlines.count) outline views")
      guard let outline = outlines.first else { continue }
      #expect(outline.numberOfRows == expectedRows, "\(context)")
      let visible = outline.subviews.compactMap { $0 as? NSTableRowView }.filter { !$0.isHidden }
      let strays = visible.filter { outline.row(for: $0) < 0 }
      #expect(strays.isEmpty, "\(context): \(strays.count) row view(s) belong to no row")
      #expect(visible.count == outline.numberOfRows, "\(context)")
      for rowView in visible where outline.row(for: rowView) >= 0 {
        let row = outline.row(for: rowView)
        #expect(rowView.frame == outline.rect(ofRow: row), "\(context): row \(row) is out of place")
      }
    }
  }

  // MARK: - Native sidebar selection stays bound in both directions

  @Test("Selecting a native sidebar row updates the model")
  func nativeSidebarSelectionUpdatesModel() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = host(
      GalleryView(model: model), size: CGSize(width: 1300, height: 800))
    defer { window.orderOut(nil) }
    await spin(0.8)

    guard let outline = sidebarOutline(in: window) else {
      Issue.record("the hosted gallery's sidebar outline view was not found")
      return
    }
    outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    await spin(0.2)

    #expect(outline.selectedRow == 2)
    #expect(model.sidebarSelection == .recent)
  }

  @Test("Changing the model selects the matching native sidebar row")
  func modelSelectionUpdatesNativeSidebar() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = host(
      GalleryView(model: model), size: CGSize(width: 1300, height: 800))
    defer { window.orderOut(nil) }
    await spin(0.8)

    guard let outline = sidebarOutline(in: window) else {
      Issue.record("the hosted gallery's sidebar outline view was not found")
      return
    }
    model.sidebarSelection = .recent
    await spin(0.2)

    #expect(outline.selectedRow == 2)
  }

  @Test("The initial model selection is selected in the native sidebar")
  func initialModelSelectionIsSelectedInNativeSidebar() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = host(
      GalleryView(model: model), size: CGSize(width: 1300, height: 800))
    defer { window.orderOut(nil) }
    await spin(0.8)

    guard let outline = sidebarOutline(in: window) else {
      Issue.record("the hosted gallery's sidebar outline view was not found")
      return
    }
    #expect(model.sidebarSelection == .all)
    #expect(outline.selectedRow == 1)
  }

  /// The first editable text control in the hosted tree, depth-first — the
  /// filter bar's field (the only one in this hosting: the inspector's
  /// editors are absent with no `editor` on the model).
  private func firstTextField(in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField, field.isEditable {
      return field
    }
    for subview in view.subviews {
      if let found = firstTextField(in: subview) { return found }
    }
    return nil
  }

  private func textField(withPlaceholder placeholder: String, in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField,
      field.placeholderString == placeholder
    {
      return field
    }
    for subview in view.subviews {
      if let found = textField(withPlaceholder: placeholder, in: subview) { return found }
    }
    return nil
  }

  /// SwiftUI's sidebar-style `List` is the only outline view in this hosted
  /// gallery. Its enclosing scroll view is the rendered sidebar column, so
  /// this reads the product geometry without adding a test-only marker.
  private func sidebarRenderedFrame(in window: NSWindow) -> CGRect? {
    guard let root = window.contentView,
      let outline = sidebarOutline(in: window),
      let scrollView = outline.enclosingScrollView
    else { return nil }
    return scrollView.convert(scrollView.bounds, to: root)
  }

  private func allOutlines(in view: NSView?) -> [NSOutlineView] {
    guard let view else { return [] }
    return (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap { allOutlines(in: $0) }
  }

  private func sidebarOutline(in window: NSWindow) -> NSOutlineView? {
    guard let root = window.contentView else { return nil }
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
      if let outline = view as? NSOutlineView { return outline }
      stack.append(contentsOf: view.subviews)
    }
    return nil
  }

  /// The inspector's split item — `NSSplitViewItem.behavior == .inspector`
  /// under the split view controller SwiftUI builds for `.inspector` — when
  /// it is presented (not collapsed).
  private func dockedInspectorItem(in window: NSWindow) -> NSSplitViewItem? {
    guard let root = window.contentView else { return nil }
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
      if let split = view as? NSSplitView,
        let controller = split.delegate as? NSSplitViewController,
        let item = controller.splitViewItems.first(where: { $0.behavior == .inspector })
      {
        return item.isCollapsed ? nil : item
      }
      stack.append(contentsOf: view.subviews)
    }
    return nil
  }

  private func dockedInspectorFrame(in window: NSWindow) -> CGRect? {
    guard let view = dockedInspectorItem(in: window)?.viewController.view else { return nil }
    return view.convert(view.bounds, to: nil)
  }

  private func dockedInspectorWidth(in window: NSWindow) -> CGFloat? {
    dockedInspectorFrame(in: window)?.width
  }

  /// Hosts through an `NSHostingController` contentViewController so SwiftUI
  /// installs a real window toolbar — required for the geometry
  /// comparison of the inserted inspector-toggle item and its neighbours.
  private func hostWithToolbar<Content: View>(
    _ content: Content, size: CGSize = CGSize(width: 1100, height: 720)
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: content)
    window.makeKeyAndOrderFront(nil)
    return window
  }

  // MARK: - The toggle's window frame is inspector-invariant

  /// The toggle view's frame in window coordinates is equal when
  /// `showsInspector` is true and false. The toggle is the toolbar's last
  /// item, so this locates the
  /// rightmost `NSToolbarItemViewer` rather than a titlebar accessory.
  ///
  /// The vacuity guard matters as much as the equality: the hosted window
  /// does not reproduce the real app's toolbar-section sliding, so the
  /// "layout actually changed" signal is the content reflow — at least one
  /// clip view in the window must change its window-rect between the two
  /// states. The section sliding itself was measured in the running app;
  /// no right-edge assertion is made here because the
  /// hosted offscreen window lays its toolbar out narrower than the window
  /// (measured: maxX 443 in a 1100 pt window) — that would test the
  /// fixture, not the property.
  @Test("The inspector toggle's window frame is identical with the inspector shown and hidden")
  func toggleFrameIsInvariantAcrossInspectorVisibility() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    // These tests measure the docked inspector, so they open it: the
    // launch default is closed, and the fixture says so rather than
    // leaning on a default it does not test.
    model.showsInspector = true

    let window = hostWithToolbar(GalleryView(model: model))
    await spin(0.8)

    guard let toolbar = window.toolbar,
      toolbar.items.contains(where: { $0.itemIdentifier == .toggleInspector })
    else {
      Issue.record("the standard toggleInspector toolbar item was not inserted")
      return
    }
    guard let toggle = toolbarItemViewers(in: window).last else {
      Issue.record("no NSToolbarItemViewer found in the hosted window")
      return
    }

    func toggleFrame() -> CGRect {
      toggle.convert(toggle.bounds, to: nil)
    }

    func clipViewRects() -> [CGRect] {
      guard let root = window.contentView?.superview else { return [] }
      var rects: [CGRect] = []
      var stack: [NSView] = [root]
      while let view = stack.popLast() {
        if let clip = view as? NSClipView {
          rects.append(clip.convert(clip.bounds, to: nil))
        }
        stack.append(contentsOf: view.subviews)
      }
      return rects
    }

    let shownToggle = toggleFrame()
    let shownClips = clipViewRects()

    model.showsInspector = false
    await spin(0.8)
    let hiddenToggle = toggleFrame()
    let hiddenClips = clipViewRects()

    // The inspector's presence must actually have changed the window's
    // content layout, or the toggle equality below would be vacuous.
    #expect(shownClips != hiddenClips)

    #expect(shownToggle == hiddenToggle)
    #expect(shownToggle.width > 0)

    window.orderOut(nil)
  }

  /// The standard item's nil-target `-toggleInspector:`
  /// must be answered from the window's responder chain (the mount splices
  /// its coordinator between window and NSApp) and must flip the same
  /// `showsInspector` the ⌃⌘I menu command flips.
  // Runs as `FocusSerial/LayoutStability/toolbarToggleItemDrivesTheSameStateAsTheCommand()`.
  func toolbarToggleItemDrivesTheSameStateAsTheCommand() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    let window = hostWithToolbar(GalleryView(model: model))
    await spin(0.8)
    defer { window.orderOut(nil) }

    guard
      let item = window.toolbar?.items.first(where: {
        $0.itemIdentifier == .toggleInspector
      }),
      let action = item.action,
      item.target == nil
    else {
      Issue.record("toggleInspector item missing or no longer nil-targeted")
      return
    }

    // The exact dispatch a click performs: nil target → the window's
    // responder chain.
    let before = model.showsInspector
    #expect(window.firstResponder?.tryToPerform(action, with: nil) == true)
    #expect(model.showsInspector != before)

    model.toggleInspector()
    #expect(model.showsInspector == before)
  }

  // Runs as `FocusSerial/LayoutStability/inspectorToggleClosesAfterSidebarSelection()`.
  func inspectorToggleClosesAfterSidebarSelection() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    let window = hostWithToolbar(
      GalleryView(model: model), size: CGSize(width: 1300, height: 800))
    await spin(0.8)
    defer { window.orderOut(nil) }

    guard
      sidebarOutline(in: window) != nil,
      let item = window.toolbar?.items.first(where: {
        $0.itemIdentifier == .toggleInspector
      }),
      let action = item.action,
      item.target == nil
    else {
      Issue.record("sidebar outline or nil-target inspector toggle was not found")
      return
    }

    model.showsInspector = true
    // One grid surface and one report surface. Orphans is a Reports row,
    // so its case switches navigator first; the outline is looked up again
    // because each navigator has its own. Usage sits above it, Overview
    // above both.
    for (navigator, row, selection) in [
      (SidebarNavigator.library, 2, SidebarSelection.recent), (.reports, 3, .orphans),
    ] {
      model.navigator = navigator
      await spin(0.3)
      guard let outline = sidebarOutline(in: window) else {
        Issue.record("no sidebar outline in \(navigator)")
        return
      }
      #expect(window.makeFirstResponder(outline))
      outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      await spin(0.3)
      #expect(model.sidebarSelection == selection)

      #expect(outline.tryToPerform(action, with: nil))
      await spin(0.4)
      #expect(
        !model.showsInspector,
        "Inspector stayed open after selecting \(selection)")

      model.showsInspector = true
      await spin(0.4)
    }
  }



  // MARK: - The zoom slider is continuous and snaps on release

  /// Photos' zoom slider: no tick marks, a fill from the − end in the
  /// accent colour, and a drag released between two rungs
  /// lands on the nearer one — the knob and the grid agree. The drag is a
  /// real AppKit tracking loop: down, drag and up are queued before
  /// `mouseDown(with:)`, whose loop consumes them, so SwiftUI sees the
  /// same editing-began / editing-ended pair a pointer produces. The
  /// release must not fire a query.
  @Test("The zoom slider has no ticks, the accent fill, and a released drag snaps to the nearest rung")
  func zoomSliderSnapsOnRelease() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The gallery is hosted so its reload wiring is live; the controls get
    // a plain window of their own because the hosted toolbar does not give
    // its item views real window geometry to click at.
    let gallery = hostWithToolbar(GalleryView(model: model))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GridToolbarControls(model: model))
    window.makeKeyAndOrderFront(nil)
    await spin(0.8)
    // The gallery's first load is not the drag's: the parallel full run
    // starves the main thread, and it measurably ran past the 0.8 s (ended
    // at 0.99–1.23 s), so tracking started inside it and counted it.
    await spin(until: { !model.rows.isEmpty && !model.isLoadingPage })
    let slider = try #require(window.contentView.flatMap(slider(in:)))

    #expect(slider.numberOfTickMarks == 0)
    #expect(!slider.allowsTickMarkValuesOnly)
    // The fill is the accent colour, not a gray.
    var fill: NSColor?
    var accent: NSColor?
    slider.effectiveAppearance.performAsCurrentDrawingAppearance {
      fill = slider.trackFillColor?.usingColorSpace(.sRGB)
      accent = PinaxPalette.nsColor(.accent).usingColorSpace(.sRGB)
    }
    #expect(fill != nil, "no fill colour: AppKit draws the system accent")
    if let fill, let accent {
      #expect(
        abs(fill.redComponent - accent.redComponent) < 0.01
          && abs(fill.greenComponent - accent.greenComponent) < 0.01
          && abs(fill.blueComponent - accent.blueComponent) < 0.01,
        "fill is not the accent: \(fill)")
    }

    // The SwiftUI slider spans 0...1 in AppKit units; ladder position p is
    // p / 5. Drag from rung 3 to 2.4 of 5 and let go.
    let rungs = Double(GridZoom.columns.count - 1)
    let target = try #require(slider.target as? NSObject)
    let transitions = LoadingTransitions()
    transitions.track(model)
    #expect(model.gridColumns == GridZoom.columns(atSliderPosition: 3))
    target.perform(NSSelectorFromString("userInteractionStarted:"), with: slider)
    slider.doubleValue = 2.4 / rungs
    _ = slider.sendAction(slider.action, to: target)
    await spin(0.3)
    #expect(
      abs(slider.doubleValue * rungs - 2.4) < 0.001,
      "mid-drag the knob sits where the pointer is: \(slider.doubleValue * rungs)")
    #expect(model.gridColumns == GridZoom.columns(atSliderPosition: 2), "the grid follows the nearest rung")
    target.perform(NSSelectorFromString("userInteractionEnded:"), with: slider)
    await spin(0.4)

    #expect(abs(slider.doubleValue * rungs - 2) < 0.001, "released knob at \(slider.doubleValue * rungs)")
    #expect(model.gridColumns == GridZoom.columns(atSliderPosition: 2))
    #expect(transitions.count == 0, "the drag fired \(transitions.count) queries")
    window.orderOut(nil)
    gallery.orderOut(nil)
  }

  /// The title leads, then the grid pair. The title is the toolbar's one
  /// navigational item (the system title is hidden), so it is the item
  /// right before the grid group, and the grid group is not navigational.
  /// Real coordinates are measured in the running app; the hosted toolbar
  /// does not lay out like the app's.
  @Test("The window title precedes the grid pair in the toolbar")
  func titlePrecedesGridPair() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = hostWithToolbar(GalleryView(model: model))
    await spin(0.8)
    let items = window.toolbar?.items ?? []
    let grid = try #require(items.firstIndex { $0.view.flatMap(slider(in:)) != nil })
    try #require(grid > 0)
    #expect(items[grid - 1].isNavigational, "the title item sits right before the grid pair")
    #expect(items[..<(grid - 1)].allSatisfy { !$0.isNavigational })
    #expect(!items[grid].isNavigational, "the grid pair sits after the title")
    window.orderOut(nil)
  }

  private func slider(in view: NSView) -> NSSlider? {
    var stack: [NSView] = [view]
    while let next = stack.popLast() {
      if let slider = next as? NSSlider { return slider }
      stack.append(contentsOf: next.subviews)
    }
    return nil
  }

  // MARK: - Toolbar arrangement is stable

  /// View mode is the toolbar's centred item; after it
  /// the grid pair, Share, ♥ and Search, then the inspector toggle; and the
  /// item count holds under all four navigators in both view modes. The
  /// grid group is recognised by the zoom slider inside its view, the
  /// others by their labels.
  ///
  /// Order is asserted on `NSToolbar.items`, not on x: this hosted window
  /// lays its toolbar out unlike the app (measured: the first group at
  /// x = 27 over a 220 pt sidebar, the others at 419…555 of 1100). The real
  /// geometry was measured in the running app, not here — asserting it
  /// would test the fixture.
  @Test("The grid pair leads the toolbar and the item count is navigator- and mode-invariant")
  func toolbarArrangementIsStable() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = hostWithToolbar(GalleryView(model: model))
    await spin(0.8)

    func arrangement() -> [String] {
      (window.toolbar?.items ?? []).map { item in
        switch item.itemIdentifier {
        case .toggleSidebar, NSToolbarItem.Identifier("com.apple.SwiftUI.navigationSplitView.toggleSidebar"):
          return "sidebar"
        case .flexibleSpace: return "flex"
        case .toggleInspector: return "inspector"
        case _ where isInspectorSeparator(item.itemIdentifier): return "inspector-separator"
        default:
          if item.isNavigational { return "title" }
          if item.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI.splitViewSeparator") {
            return "sidebar-separator"
          }
          if item.view.map(containsSlider) == true { return "grid" }
          if window.toolbar?.centeredItemIdentifiers.contains(item.itemIdentifier) == true {
            return "centred:\(item.label)"
          }
          return item.label.isEmpty ? "item" : item.label
        }
      }
    }

    var arrangements: [String: [String]] = [:]
    for navigator in SidebarNavigator.allCases {
      for mode in [GalleryModel.ViewMode.grid, .table] {
        model.navigator = navigator
        model.viewMode = mode
        await spin(0.4)
        arrangements["\(navigator)/\(mode)"] = arrangement().filter { $0 != "inspector-separator" }
      }
    }

    // The inspector-tracking separator comes and goes with docking; it is
    // the mount's concern, so it is left out of the comparison.
    // View mode is AppKit's centred item; the trailing side reads
    // title → grid pair → Share → ♥ → Search → the inspector toggle.
    let expected = [
      "sidebar", "sidebar-separator", "centred:View mode", "flex", "title", "grid", "Share",
      "Favorite", "Search", "flex", "inspector",
    ]
    for (key, value) in arrangements.sorted(by: { $0.key < $1.key }) {
      #expect(value == expected, "\(key): \(value)")
    }
    #expect(Set(arrangements.values.map(\.count)).count == 1, "counts: \(arrangements)")
    window.orderOut(nil)
  }

  /// The inspector column's tracking separator: SwiftUI's "-<n>i" one, or
  /// the mount's old identifier.
  private func isInspectorSeparator(_ identifier: NSToolbarItem.Identifier) -> Bool {
    identifier == .inspectorTrackingSeparator
      || (identifier.rawValue.hasPrefix("com.apple.SwiftUI.splitViewSeparator")
        && identifier.rawValue.hasSuffix("i"))
  }

  private func containsSlider(_ view: NSView) -> Bool {
    var stack: [NSView] = [view]
    while let next = stack.popLast() {
      if next is NSSlider { return true }
      stack.append(contentsOf: next.subviews)
    }
    return false
  }

  /// The toolbar's private item viewers, left to right. Class-name match
  /// because `NSToolbarItemViewer` is AppKit-private; searched under the
  /// theme frame (`contentView.superview`) where the titlebar lives.
  private func toolbarItemViewers(in window: NSWindow) -> [NSView] {
    guard let root = window.contentView?.superview else { return [] }
    var viewers: [NSView] = []
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
      if NSStringFromClass(type(of: view)) == "NSToolbarItemViewer" {
        viewers.append(view)
      }
      stack.append(contentsOf: view.subviews)
    }
    return viewers.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
  }

  // MARK: - Report surfaces do not react to filter keystrokes

  /// Counts false→true transitions of `isLoadingPage` by subscription, not
  /// polling — a polling probe was measured to miss reloads fast enough to
  /// fall between samples on an empty database.
  private final class LoadingTransitions {
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

  @Test("Filter keystrokes re-run no scan on report surfaces, and do reload on the grid")
  func reportSurfacesDoNotReactToFilterKeystrokes() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    let window = host(GalleryView(model: model), size: CGSize(width: 1100, height: 720))
    await spin(0.6)

    let transitions = LoadingTransitions()
    transitions.track(model)

    model.sidebarSelection = .orphans
    await spin(0.8)
    let baseline = transitions.count

    // Two keystrokes on the report surface: the orphan reload does not read
    // the search text, so the reload token excludes it — no new scans.
    model.searchText = "a"
    await spin(0.4)
    model.searchText = "as"
    await spin(0.4)
    #expect(transitions.count == baseline)

    // Positive control, proving the instrument still counts reloads: on the
    // grid a text change does re-run the query.
    model.sidebarSelection = .all
    await spin(0.8)
    let controlBaseline = transitions.count
    model.searchText = "ass"
    await spin(0.6)
    #expect(transitions.count > controlBaseline)

    window.orderOut(nil)
  }

  // MARK: - The split view's width budget

  /// With both side columns shown, the sidebar's *max* plus its divider, the detail minimum
  /// and the inspector plus its divider must fit inside the window's own
  /// minimum width. At the old constants (180 + 480 + 300 + 2 = 962 inside
  /// 900) AppKit pushed the whole split view 31 pt past the window's left
  /// edge — measured in the running app, not derived. This turns "someone
  /// raised a minimum" back into that bug. The literals pin the chosen
  /// budget (a 900 pt window, the detail minimum 338).
  @Test("The split view's column minimums close inside the window's minimum width")
  func splitViewWidthBudgetCloses() {
    #expect(GalleryWidthBudget.budgetCloses)
    #expect(
      (GalleryWidthBudget.sidebarMax + 1) + GalleryWidthBudget.detailMin
        + (GalleryWidthBudget.inspectorWidth + 1) <= GalleryWidthBudget.windowMinWidth)
    #expect(GalleryWidthBudget.windowMinWidth == 900)
    #expect(GalleryWidthBudget.detailMin == 338)
    #expect(GalleryWidthBudget.sidebarReserve == 261)
    #expect(GalleryWidthBudget.inspectorReserve == 301)
  }

  // MARK: - Escape clears and dismisses the filter bar

  /// A manual check made measurable: the key event is sent
  /// in-process via `window.sendEvent` (no accessibility permission), which
  /// exercises the same delivery path a real Escape press takes — including
  /// any first crack AppKit's field editor might take at it.
  // Runs as `FocusSerial/LayoutStability/escapeClearsAndDismissesTheFilterBar()`.
  func escapeClearsAndDismissesTheFilterBar() async throws {
    let (model, directory) = try await makeSeededModel()
    defer { try? FileManager.default.removeItem(at: directory) }

    let window = host(GalleryView(model: model), size: CGSize(width: 1100, height: 720))
    window.makeKeyAndOrderFront(nil)
    await spin(0.6)

    model.isSearchPresented = true
    await spin(0.4)
    guard let field = firstTextField(in: window.contentView) else {
      Issue.record("the filter bar's text field was not found")
      return
    }
    #expect(window.makeFirstResponder(field))
    model.searchText = "abc"
    await spin(0.4)
    #expect(model.searchText == "abc")
    #expect(model.isSearchPresented)

    let escape = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil,
      characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false, keyCode: 53)
    // Through NSApp.sendEvent, the real delivery path: this is where local
    // event monitors are consulted, ahead of the responder chain that would
    // hand Escape to the field editor's cancelOperation:.
    NSApp.sendEvent(escape!)
    await spin(0.4)

    #expect(model.searchText == "")
    #expect(!model.isSearchPresented)

    window.orderOut(nil)
  }
}

/// The tests above that need key status or a first responder, run
/// only in the serial `FocusSerial` invocation (see `FocusSerial`).
extension FocusSerial {
  @MainActor
  @Suite struct LayoutStability {
    @Test("A hosted gallery keeps search text and field focus across a selection change")
    func hostedGalleryKeepsSearchState() async throws { try await LayoutStabilityTests().hostedGalleryKeepsSearchState() }

    @Test("The inserted toggleInspector item drives the same state as the menu command")
    func toolbarToggleItemDrivesTheSameStateAsTheCommand() async throws { try await LayoutStabilityTests().toolbarToggleItemDrivesTheSameStateAsTheCommand() }

    @Test("The inspector toggle still closes after selecting a sidebar row")
    func inspectorToggleClosesAfterSidebarSelection() async throws { try await LayoutStabilityTests().inspectorToggleClosesAfterSidebarSelection() }

    @Test("Escape reaches the filter bar and clears and dismisses it")
    func escapeClearsAndDismissesTheFilterBar() async throws { try await LayoutStabilityTests().escapeClearsAndDismissesTheFilterBar() }
  }
}


/// The old branch-swap inspector shape, kept as the falsifier for the
/// appearance counter: `Group { if let details ScrollView … else Text }`.
/// It is not a copy of any current product view — it is the shape the
/// stable root replaced.
private struct BranchSwapInspector: View {
  @ObservedObject var model: GalleryModel
  let probe: () -> Void

  var body: some View {
    Group {
      if let details = model.selectedDetails {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Color.clear
              .frame(width: 0, height: 0)
              .onAppear { probe() }
            Text(details.item.asset.key)
          }
          .padding(14)
        }
      } else {
        Text("Select an asset to inspect it.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}
