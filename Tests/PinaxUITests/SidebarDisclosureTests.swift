import AppKit
import CatalogCore
import Foundation
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

/// A row that opens does so by its square, without
/// selecting it; ← and → still open and close the selected row.
@MainActor
@Suite struct SidebarDisclosureTests {
  // MARK: - Configuration values

  @Test("First-level squares 6 in from the plate, 26 per level; stack, tree and count values")
  func indentValues() {
    let row = DesignMetrics.sidebarRow.self
    #expect(row.contentPadding == 6)
    // The List starts a row's content 8 in from the plate (measured), so
    // every first-level row pulls back 2 to put its square 6 in — Catalog's
    // 18 pt folders on the same line as Library's 20 pt squares.
    #expect(row.listContentInset == 8)
    #expect(SidebarDisclosure.leading(depth: 0) == -2)
    #expect(SidebarDisclosure.leading(depth: 2) == 50)
    #expect(row.levelIndent == 26)
    #expect(row.stackOffset == 3 && row.stackRing == 1.5)
    #expect(row.treeLineWidth == 1.5 && row.treeRadius == 7 && row.treeGap == 3)
    #expect(row.countWidth == 34)
    #expect(ColorSquare.Size.folder.side == 18 && ColorSquare.Size.folder.radius == 5)
  }

  @Test("The stack behind a closed folder: 58 % light, 62 % dark, white 50 % when selected")
  func stackOpacity() {
    #expect(SidebarEntrySquare.stackOpacity(isSelected: false, dark: false) == 0.58)
    #expect(SidebarEntrySquare.stackOpacity(isSelected: false, dark: true) == 0.62)
    #expect(SidebarEntrySquare.stackOpacity(isSelected: true, dark: true) == 0.5)
  }

  @Test("Tree lines: a first child's elbow ends 3 before its square; an open row hangs a stub")
  func treeLinePath() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 22)
    let elbow = SidebarTreeLines(depth: 1, continues: [false], hangsChildren: false, squareSide: 18)
      .path(in: rect).boundingRect
    // From the parent square's middle (-2 + 9 = 7) to 3 before the child's (24 - 3).
    #expect(abs(elbow.minX - 7) < 0.01 && abs(elbow.maxX - 21) < 0.01)
    #expect(abs(elbow.minY - -4) < 0.01 && abs(elbow.maxY - 11) < 0.01)
    let stub = SidebarTreeLines(depth: 0, continues: [], hangsChildren: true, squareSide: 18)
      .path(in: rect).boundingRect
    #expect(abs(stub.minY - 20) < 0.01 && abs(stub.maxY - 26) < 0.01)
  }

  @Test("→ opens a closed row, ← closes an open one, ← on a child selects its parent")
  func arrowKeyActions() {
    let month = SidebarEntry(
      navigator: .time, selection: .month("2026-07"), label: "July", systemImage: "calendar",
      iconTint: .library)
    let year = SidebarEntry(
      navigator: .time, selection: .year("2026"), label: "2026", systemImage: "calendar",
      iconTint: .library, children: [month])
    let sections = [SidebarSection(id: "time", title: "Time", entries: [year])]
    let act = { (key: SidebarDisclosure.Key, selection: SidebarSelection, open: Set<String>) in
      SidebarDisclosure.action(for: key, selection: selection, in: sections, expanded: open)
    }
    #expect(act(.open, .year("2026"), []) == .setExpanded(year, true))
    #expect(act(.open, .year("2026"), [year.id]) == nil)
    #expect(act(.close, .year("2026"), [year.id]) == .setExpanded(year, false))
    #expect(act(.close, .year("2026"), []) == nil)
    #expect(act(.close, .month("2026-07"), [year.id]) == .select(.year("2026")))
    #expect(act(.open, .month("2026-07"), [year.id]) == nil)
    // A row under a closed parent is not on screen.
    #expect(act(.close, .month("2026-07"), []) == nil)
  }

  // MARK: - Hosted (key window: FocusSerial)

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-disclosure-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  private func hostTimeNavigator() async throws -> (GalleryModel, NSWindow, NSOutlineView, URL) {
    let (database, directory) = try makeUITestDatabase()
    try seedAsset(database, index: 0, uploadedAt: "2026-08-01T00:00:00Z")
    try seedAsset(database, index: 1, uploadedAt: "2026-07-02T00:00:00Z")
    try seedAsset(database, index: 2, uploadedAt: "2025-12-02T00:00:00Z")
    let model = makeModel(database)
    await model.loadInitialData()
    model.navigator = .time
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: GalleryView(model: model))
    window.makeKeyAndOrderFront(nil)
    await spin(0.8)
    let outline = try #require(sidebarOutline(in: window.contentView), "no sidebar outline")
    return (model, window, outline, directory)
  }

  // Runs as `FocusSerial/SidebarDisclosure/arrowKeysOpenAndClose()`.
  func arrowKeysOpenAndClose() async throws {
    let (model, window, outline, directory) = try await hostTimeNavigator()
    defer {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: directory)
    }
    // Time header, 2026 open by default with August and July, 2025 closed.
    #expect(outline.numberOfRows == 5)
    model.sidebarSelection = .year("2025")
    window.makeFirstResponder(outline)
    await spin(until: { outline.selectedRow == 4 })

    await press(NSRightArrowFunctionKey, 124, in: window)
    await spin(until: { outline.numberOfRows == 6 })
    #expect(outline.numberOfRows == 6, "→ opened 2025")
    #expect(model.sidebarSelection == .year("2025"))

    await press(NSDownArrowFunctionKey, 125, in: window)
    await spin(until: { model.sidebarSelection == .month("2025-12") })
    #expect(model.sidebarSelection == .month("2025-12"), "↓ is still the outline's")

    await press(NSLeftArrowFunctionKey, 123, in: window)
    await spin(until: { model.sidebarSelection == .year("2025") })
    #expect(model.sidebarSelection == .year("2025"), "← on a month selects its year")
    await spin(until: { outline.selectedRow == 4 })

    await press(NSLeftArrowFunctionKey, 123, in: window)
    await spin(until: { outline.numberOfRows == 5 })
    #expect(outline.numberOfRows == 5, "← closed 2025")
  }

  // Runs as `FocusSerial/SidebarDisclosure/squareOpensWithoutSelecting()`.
  func squareOpensWithoutSelecting() async throws {
    let (model, window, outline, directory) = try await hostTimeNavigator()
    defer {
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: directory)
    }
    // 2026 starts open: header, 2026, its two
    // months, 2025.
    #expect(outline.numberOfRows == 5)
    model.sidebarSelection = .year("2026")
    await spin(until: { outline.selectedRow == 1 })

    // The square's middle hits a view inside the row's cell, where the
    // SwiftUI button lives — not the row view, which would select the row.
    // (Measured: a button pulled left of the cell got no clicks. A
    // synthetic click on a row's name does not select it in this hosted
    // window either, so the selection checks below cannot see a click that
    // fell through; this hit test is what pins it.)
    let cell = try #require(outline.view(atColumn: 0, row: 4, makeIfNecessary: false))
    let squarePoint = NSPoint(
      x: sidebarSquareX(row: 4, depth: 0, in: outline),
      y: outline.rect(ofRow: 4).midY)
    let hit = try #require(outline.hitTest(outline.convert(squarePoint, to: outline.superview)))
    #expect(hit.isDescendant(of: cell), "the square's point hits \(type(of: hit))")

    // 2025's square opens 2025 and leaves 2026 selected.
    await clickSidebarSquare(row: 4, depth: 0, in: outline, window: window)
    await spin(until: { outline.numberOfRows == 6 })
    #expect(outline.numberOfRows == 6, "the square opened 2025")
    #expect(model.sidebarSelection == .year("2026"))

    await clickSidebarSquare(row: 4, depth: 0, in: outline, window: window)
    await spin(until: { outline.numberOfRows == 5 })
    #expect(outline.numberOfRows == 5, "the square closed 2025")
    #expect(model.sidebarSelection == .year("2026"))
  }

  // MARK: - Helpers

  private func press(_ key: Int, _ code: UInt16, in window: NSWindow) async {
    let characters = String(UnicodeScalar(UInt16(key))!)
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
    window.sendEvent(event)
    await spin(0.15)
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

  private func spin(until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      await spin(0.05)
    }
  }

  private func sidebarOutline(in view: NSView?) -> NSOutlineView? {
    guard let view else { return nil }
    var stack: [NSView] = [view]
    while let next = stack.popLast() {
      if let outline = next as? NSOutlineView { return outline }
      stack.append(contentsOf: next.subviews)
    }
    return nil
  }
}

/// A mouse click at a point in the sidebar outline, delivered to its window.
@MainActor
func sidebarClick(at point: NSPoint, in outline: NSOutlineView, window: NSWindow) async {
  let location = outline.convert(point, to: nil)
  for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    let event = NSEvent.mouseEvent(
      with: type, location: location, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    window.sendEvent(event)
    for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }
}

/// The middle of a row's square, in the outline's coordinates.
@MainActor
func sidebarSquareX(row: Int, depth: Int, in outline: NSOutlineView) -> CGFloat {
  outline.frameOfCell(atColumn: 0, row: row).minX + SidebarDisclosure.leading(depth: depth)
    + ColorSquare.Size.sidebar.side / 2
}

/// Clicks a row's square, which opens or closes it.
@MainActor
func clickSidebarSquare(
  row: Int, depth: Int, in outline: NSOutlineView, window: NSWindow
) async {
  let x = sidebarSquareX(row: row, depth: depth, in: outline)
  await sidebarClick(at: NSPoint(x: x, y: outline.rect(ofRow: row).midY), in: outline, window: window)
}

extension FocusSerial {
  @MainActor
  @Suite struct SidebarDisclosure {
    @Test("← and → open and close the selected sidebar row; ↓ still moves")
    func arrowKeysOpenAndClose() async throws {
      try await SidebarDisclosureTests().arrowKeysOpenAndClose()
    }

    @Test("A row's square opens and closes it without selecting it")
    func squareOpensWithoutSelecting() async throws {
      try await SidebarDisclosureTests().squareOpensWithoutSelecting()
    }
  }
}
