import AppKit
import CatalogCore
import Foundation
import SwiftUI
@testable import PinaxUI
import Testing

/// The drop zone's cards and hover preview.
///
/// Layout is measured hosted, through `DropZoneLayoutKey` (each part's frame
/// in the panel's space), never from a screenshot. Neither a system drag nor
/// a real pointer can be driven under test (measured: SwiftUI's hover does
/// not react to synthetic mouseMoved events sent to the hosting view, its
/// tracking-area owner, or the window), so the drop-target flag and the
/// hover are set on the view's own `DropZoneViewState`, the object the
/// view's `isTargeted` and `onContinuousHover` closures write. The hover
/// closure itself is also taken from the card's own body and called
/// (`cardHoverWiring`); `isTargeted` stays unreached (its `DropInfo` has no
/// public initializer).
///
/// Serialized: hosted windows do not survive interleaving at suspension
/// points (LayoutStabilityTests).
@MainActor
@Suite(.serialized) struct DropZoneCardTests {
  typealias Part = DropZoneLayoutKey.Part
  typealias Role = DropZoneLayoutKey.Role

  // MARK: - Actions

  @Test("Every action button has a help tag and an accessibility label, and a real symbol")
  func actionsAreLabelled() async throws {
    let (model, _, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/a.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let card = ResultCardView(card: model.cards[0], model: model, state: DropZoneViewState())
    #expect(card.actions.map(\.id) == ["copyURL", "copyMarkdown", "quickLook"])
    for action in card.actions {
      #expect(!action.help.isEmpty, "\(action.id)")
      #expect(
        NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil,
        "\(action.symbol)")
    }
    #expect(!DropZoneProjectMenu.help.isEmpty)
    // The action symbols.
    let symbols = [
      card.retryAction.symbol, "folder", "chevron.down",
      "pin", "pin.fill", "xmark.circle.fill",
    ]
    for symbol in symbols {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
  }

  @Test("The copy buttons copy the card's URL and Markdown through the model's copier")
  func copyButtonsCopy() async throws {
    let (model, _, _) = try makeModel()
    let copied = Copied()
    model.copiesURLsAutomatically = false
    model.urlCopier = { copied.values.append($0) }
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/a.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let card = ResultCardView(card: model.cards[0], model: model, state: DropZoneViewState())
    #expect(card.isDone)
    card.actions.first { $0.id == "copyURL" }?.perform()
    card.actions.first { $0.id == "copyMarkdown" }?.perform()
    #expect(copied.values == ["https://img.example.com/blog/a.png", model.markdown(for: model.cards[0])])
    #expect(copied.values[1].contains("](https://img.example.com/blog/a.png)"))
  }

  // MARK: - Hosted layout

  @Test("Every field is still on the card, per state")
  func everyFieldIsShown() async throws {
    let (model, service, _) = try makeModel()
    let cards = try await cardsInEveryState(model, service)
    defer { service.releaseAll() }
    let frames = await hostCards(model)
    func has(_ role: Role, _ id: UUID) -> Bool { (frames[Part(card: id, role: role)]?.width ?? 0) > 0 }
    let actionRoles: [Role] = ["copyURL", "copyMarkdown", "quickLook"].map { .action($0) }
    // The status words take the URL line; the status is drawn on the
    // thumbnail (the status layer) in every phase.
    let common: [Role] = [.thumbnail, .statusLayer, .filename, .statusText, .meta, .projectToken, .buttons]
      + actionRoles
    for (name, id) in cards {
      for role in common { #expect(has(role, id), "\(name) lacks \(role)") }
    }
    #expect(has(.error, cards["failed"]!) && has(.retry, cards["failed"]!))
    for name in ["waiting", "uploading", "done", "dedupe"] {
      #expect(!has(.error, cards[name]!) && !has(.retry, cards[name]!), "\(name)")
    }
    let done = try #require(model.cards.first { $0.id == cards["done"] })
    let meta = ResultCardView(card: done, model: model, state: DropZoneViewState()).metaLine
    #expect(meta == "800 × 600 · \(PinaxFormat.fileSize(1234)) · Blog", "\(meta)")
    let failed = try #require(model.cards.first { $0.id == cards["failed"] })
    #expect(ResultCardView(card: failed, model: model, state: DropZoneViewState()).metaLine == "Blog")
  }

  @Test("All five phases are one height in List, failed included")
  func cardHeights() async throws {
    let (model, service, _) = try makeModel()
    let cards = try await cardsInEveryState(model, service)
    defer { service.releaseAll() }
    let frames = await hostCards(model)
    let heights = cards.mapValues { frames[Part(card: $0, role: .card)]?.height ?? 0 }
    let done = try #require(heights["done"])
    #expect(done > 0)
    for name in ["waiting", "uploading", "dedupe", "failed"] {
      #expect(abs((heights[name] ?? 0) - done) < 0.5, "\(name) \(heights)")
    }
  }

  @Test("In the real panel, thumbnails, text columns and button rows share one left edge each")
  func cardsAlignInThePanel() async throws {
    let (model, service, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/fail-x.png")])
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/dedupe-x.png")])
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/a-long-name-for-a-screenshot-2026.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/block-x.png")])
    defer { service.releaseAll() }
    await waitUntil { model.cards.first?.phase == .uploading }
    let frames = await hostPanel(model, state: DropZoneViewState())
    let ids = model.cards.map(\.id).filter { frames[Part(card: $0, role: .card)] != nil }
    #expect(ids.count >= 3, "rendered \(ids.count) cards")
    for role in [Role.thumbnail, .text, .buttons] {
      let edges = Set(ids.compactMap { frames[Part(card: $0, role: role)].map { ($0.minX * 2).rounded() / 2 } })
      #expect(edges.count == 1, "\(role): \(edges)")
    }
  }

  @Test("Done cards' buttons are all inside the card and the panel, and none is squeezed")
  func buttonsVisibleAndUntruncated() async throws {
    let (model, _, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/a.png")])
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/dedupe-b.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let state = DropZoneViewState()
    let frames = await hostPanel(model, state: state)
    let panel = CGRect(origin: .zero, size: DropZonePanel.defaultSize)
    for card in model.cards {
      let view = ResultCardView(card: card, model: model, state: state)
      #expect(view.isDone)
      let cardFrame = try #require(frames[Part(card: card.id, role: .card)])
      // The ideal is measured the same way as the in-card frame (a
      // GeometryReader, unrounded): `fittingSize` rounds to whole points and
      // read 22 for a button the card lays out at 21 (and 20 for one at 20.5).
      var ideals: [String: CGFloat] = [:]
      for action in view.actions {
        ideals[action.id] = await idealWidth(view.actionButton(action))
      }
      for (id, ideal) in ideals {
        let frame = try #require(frames[Part(card: card.id, role: .action(id))], "\(id)")
        #expect(frame.width > 0 && frame.height > 0, "\(id) \(frame)")
        #expect(cardFrame.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(id) \(frame) in \(cardFrame)")
        #expect(panel.contains(frame), "\(id) \(frame)")
        // Content width ≤ frame width: the button got at least its ideal.
        #expect(frame.width + 0.5 >= ideal, "\(id) frame \(frame.width) < ideal \(ideal)")
      }
    }
  }

  // MARK: - Drop target over existing cards

  @Test("A drag hovering a panel that already has cards shows the drag-over state; new cards go first")
  func dropTargetOverCards() async throws {
    let (model, _, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/first.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let state = DropZoneViewState()
    state.isDropTargeted = true
    let frames = await hostPanel(model, state: state)
    let target = try #require(frames[Part(card: nil, role: .dropOverlay)], "no drag-over state over cards")
    let card = try #require(frames[Part(card: model.cards[0].id, role: .card)])
    #expect(target.contains(card), "\(target) ⊉ \(card)")

    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/second.png")])
    #expect(model.cards.map(\.filename) == ["second.png", "first.png"])
  }

  // MARK: - Hover preview

  @Test("The preview's size is fixed while the pointer moves; its frame is a pure function of it, inside the panel")
  func previewGeometry() {
    let panel = DropZonePanel.defaultSize
    let inset = DesignMetrics.dropZone.previewEdgeInset
    let bounds = CGRect(origin: .zero, size: panel).insetBy(dx: inset, dy: inset)
    let size = DropZoneViewState.previewSize(image: CGSize(width: 400, height: 300), panel: panel)
    #expect(size.width >= panel.width / 3 && size.width <= panel.width / 2, "\(size)")
    #expect(DesignMetrics.dropZone.previewRadius > DesignMetrics.radius.panel)
    let tall = DropZoneViewState.previewSize(image: CGSize(width: 100, height: 5000), panel: panel)
    #expect(tall.height <= bounds.height)

    let state = DropZoneViewState()
    let id = UUID()
    var sizes: Set<String> = []
    for x in stride(from: 0, through: panel.width, by: 17) {
      for y in stride(from: 0, through: panel.height, by: 23) {
        let pointer = CGPoint(x: x, y: y)
        state.thumbnailHover(.active(pointer), cardID: id, imageSize: CGSize(width: 400, height: 300))
        let frame = try? #require(state.preview?.frame)
        guard let frame else { return }
        sizes.insert("\(frame.size)")
        #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(frame), "\(pointer) → \(frame)")
        #expect(frame == DropZoneViewState.previewFrame(pointer: pointer, size: size, panel: panel))
      }
    }
    #expect(sizes.count == 1, "\(sizes)")
    // Where there is room, it follows the pointer below-right.
    let follow = DropZoneViewState.previewFrame(pointer: CGPoint(x: 40, y: 60), size: size, panel: panel)
    #expect(follow.minX == 40 + DesignMetrics.dropZone.previewPointerGap)
    #expect(follow.minY == 60 + DesignMetrics.dropZone.previewPointerGap)

    state.thumbnailHover(.ended, cardID: UUID(), imageSize: nil)
    #expect(state.preview != nil, "another card's exit must not hide this one")
    state.thumbnailHover(.ended, cardID: id, imageSize: nil)
    #expect(state.preview == nil)
    state.thumbnailHover(.active(.zero), cardID: id, imageSize: nil)
    #expect(state.preview == nil, "no cached thumbnail, no preview")
  }

  @Test("Hosted, the preview renders at the state's frame from the cached thumbnail; zero fetches")
  func hostedPreviewFromCache() async throws {
    let (model, _, fetches) = try makeModel()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("shot.png")
    try pngData(width: 400, height: 300).write(to: file)
    model.drop(fileURLs: [file])
    await waitUntil { model.cards.first?.thumbnail != nil && !model.cards[0].phase.isPending }
    let card = model.cards[0]
    let image = try #require(card.thumbnail)
    let state = DropZoneViewState()
    let imageSize = CGSize(width: image.width, height: image.height)

    var rendered: [CGRect] = []
    let box = FramesBox()
    let (window, pump) = host(model, state: state, box: box)
    defer { window.orderOut(nil) }
    await pump()
    #expect(box.frames[Part(card: nil, role: .preview)] == nil)
    for pointer in [CGPoint(x: 30, y: 70), CGPoint(x: 40, y: 80), CGPoint(x: 300, y: 400)] {
      state.thumbnailHover(.active(pointer), cardID: card.id, imageSize: imageSize)
      await pump()
      let frame = try #require(box.frames[Part(card: nil, role: .preview)], "no preview at \(pointer)")
      let expected = try #require(state.preview?.frame)
      #expect(abs(frame.minX - expected.minX) < 0.5 && abs(frame.minY - expected.minY) < 0.5, "\(frame) vs \(expected)")
      rendered.append(frame)
    }
    #expect(Set(rendered.map { "\($0.size)" }).count == 1, "\(rendered)")
    state.thumbnailHover(.ended, cardID: card.id, imageSize: imageSize)
    await pump()
    #expect(box.frames[Part(card: nil, role: .preview)] == nil)
    #expect(fetches.value == 0)
  }

  @Test("The card's own thumbnail hover shows that card's preview, and its exit hides it")
  func cardHoverWiring() async throws {
    let (model, _, _) = try makeModel()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-hover-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = ["a.png", "b.png"].map { directory.appendingPathComponent($0) }
    for file in files { try pngData(width: 400, height: 300).write(to: file) }
    model.drop(fileURLs: files)
    await waitUntil { model.cards.count == 2 && model.cards.allSatisfy { $0.thumbnail != nil } }
    let state = DropZoneViewState()

    for card in model.cards {
      // The hover closure the app's card view declares on its thumbnail.
      // The `as?` cast gives a function type that does not match the one
      // stored, so the point passed through it is not trustworthy: only
      // that a preview appears, whose card it is, and that exit clears it
      // are asserted. The frame's rules are `previewGeometry`'s.
      let hover = try #require(hoverAction(in: ResultCardView(card: card, model: model, state: state).body))
      hover(.active(CGPoint(x: 30, y: 42)))
      let preview = try #require(state.preview, "\(card.filename): no preview")
      #expect(preview.cardID == card.id, "\(card.filename)")
      hover(.ended)
      #expect(state.preview == nil, "\(card.filename): exit left the preview up")
    }
  }

  /// The first `onContinuousHover` callback in a view body. Stops at class
  /// instances: the card's observed objects are not view content.
  private func hoverAction(in view: Any) -> ((HoverPhase) -> Void)? {
    let mirror = Mirror(reflecting: view)
    if mirror.displayStyle == .class { return nil }
    if let action = mirror.descendant("callback", "spatial") as? (HoverPhase) -> Void { return action }
    for child in mirror.children {
      if let found = hoverAction(in: child.value) { return found }
    }
    return nil
  }

  // MARK: - Upload progress in the main window's status bar

  @Test("The app pushes the zone's upload progress to the gallery's status bar, then clears it")
  func uploadProgressReachesStatusBar() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-s28b-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let zone = try #require(app.dropZone?.model)
    let gallery = try #require(app.gallery)
    #expect(gallery.uploadProgress == nil)
    // An unreadable file fails fast: pending first, no network.
    let name = "pinax-\(UUID().uuidString).png"
    zone.drop(fileURLs: [URL(fileURLWithPath: "/nonexistent/\(name)")])
    #expect(gallery.uploadProgress == "Uploading \(name)…")
    #expect(GalleryStatusBar(model: gallery).activityText == "Uploading \(name)…")
    await waitUntil { zone.cards.allSatisfy { !$0.phase.isPending } }
    #expect(gallery.uploadProgress == nil)
    #expect(GalleryStatusBar(model: gallery).activityText == nil)
  }

  @Test("A batch reads 'Uploaded k of N…' until the last card settles")
  func batchProgressLine() async throws {
    let (model, service, _) = try makeModel()
    var lines: [String?] = []
    model.onUploadProgressChange = { lines.append($0) }
    model.drop(fileURLs: ["a", "block-b", "c"].map { URL(fileURLWithPath: "/pinax-dz/\($0).png") })
    await waitUntil { model.cards.filter { !$0.phase.isPending }.count == 2 }
    #expect(model.uploadProgress == "Uploaded 2 of 3…")
    service.releaseAll()
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(lines.first == "Uploaded 0 of 3…")
    #expect(lines.last == .some(nil))
  }

  // MARK: - Upload status on the thumbnail

  @Test("Five phases, five distinct accessibility labels; the status layer, which wraps the thumbnail by ≤ 4 pt")
  func statusLayer() async throws {
    let (model, service, _) = try makeModel()
    let cards = try await cardsInEveryState(model, service)
    defer { service.releaseAll() }
    let expected = [
      "waiting": "Waiting", "uploading": "Uploading", "done": "Uploaded",
      "dedupe": "Already in library", "failed": "Failed",
    ]
    let frames = await hostCards(model)
    for (name, id) in cards {
      let card = try #require(model.cards.first { $0.id == id })
      #expect(DropZoneCardStatus(card: card).accessibilityLabel == expected[name], "\(name)")
      let thumbnail = try #require(frames[Part(card: id, role: .thumbnail)], "\(name)")
      let layer = try #require(frames[Part(card: id, role: .statusLayer)], "\(name)")
      #expect(layer.insetBy(dx: -0.5, dy: -0.5).contains(thumbnail), "\(name) \(layer) ⊉ \(thumbnail)")
      let outset = max(
        thumbnail.minX - layer.minX, layer.maxX - thumbnail.maxX,
        thumbnail.minY - layer.minY, layer.maxY - thumbnail.maxY)
      #expect(outset <= DesignMetrics.dropZone.statusOutset + 0.5, "\(name) outset \(outset)")
    }
    #expect(Set(expected.values).count == 5)
    // The seal and the spinner are gone from the cards.
    for file in ["DropZone/DropZoneCards.swift", "DropZone/DropZoneView.swift", "DropZone/ShelfCellView.swift"] {
      let source = try String(contentsOf: DropZoneLookTests.source(file), encoding: .utf8)
      #expect(!source.contains("checkmark.seal"), "\(file)")
      #expect(!source.contains("ProgressView"), "\(file)")
    }
  }

  @Test("A failed card has the retry knob in List and in Shelf, and it retries")
  func retryKnobBothLayouts() async throws {
    let (model, _, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/fail-k.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let id = model.cards[0].id
    for layout in [DropZoneLayout.list, .shelf] {
      let state = DropZoneViewState()
      state.layout = layout
      let frames = await hostPanel(model, state: state)
      let knob = try #require(frames[Part(card: id, role: .retry)], "\(layout)")
      let thumbnail = try #require(frames[Part(card: id, role: .thumbnail)], "\(layout)")
      #expect(thumbnail.contains(CGPoint(x: knob.midX, y: knob.midY)), "\(layout) \(knob) in \(thumbnail)")
    }
    let card = ResultCardView(card: model.cards[0], model: model, state: DropZoneViewState())
    #expect(card.retryAction.symbol == "arrow.clockwise")
    card.retryAction.perform()
    #expect(model.cards[0].phase.isPending)
  }

  @Test("Reduce Motion stills the upload ring's fill and its fade-out; otherwise both move")
  func reduceMotion() async throws {
    let (model, service, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/fresh.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/block-m.png")])
    defer { service.releaseAll() }
    await waitUntil { model.cards.first?.phase == .uploading }
    let uploading = model.cards[0].id
    var fresh = model.cards[1].id
    #expect(model.cards[1].landedAt != nil)
    func landedAt(_ id: UUID) -> Date? { model.cards.first { $0.id == id }?.landedAt }
    for reduces in [false, true] {
      let state = DropZoneViewState()
      state.reducesMotion = reduces
      // Read the motions the moment both cards report them. The fresh
      // card's fade ends `UploadRing.finishTime` (1.05 s) after it landed,
      // and only a reading taken inside that window measures the fade: the
      // fixed 0.4 s pump, and in a parallel full run the setup before it,
      // measurably read it after the window (ringFades false with Reduce
      // Motion off — right for a card that old). A reading outside the
      // window is no reading: land a new fresh card and read again.
      for attempt in 1...5 {
        await hostPanel(model, state: state) {
          state.motions[uploading] != nil && state.motions[fresh] != nil
        }
        guard let landed = landedAt(fresh),
          Date().timeIntervalSince(landed) >= UploadRing.finishTime, attempt < 5
        else { break }
        model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/fresh-\(reduces)-\(attempt).png")])
        await waitUntil { model.cards.first.map { $0.id != fresh && $0.landedAt != nil } == true }
        fresh = model.cards[0].id
      }
      #expect(state.motions[uploading]?.ringFills == !reduces, "\(reduces) \(state.motions)")
      #expect(state.motions[fresh]?.ringFades == !reduces, "\(reduces) \(state.motions)")
    }
  }

  @Test("Upload ring: traced clockwise from 12 o'clock; while uploading it fills with time but never closes; once landed it closes, then fades out")
  func uploadRing() throws {
    let rect = CGRect(x: 0, y: 0, width: 160, height: 112)
    var points: [CGPoint] = []
    UploadRingShape(radius: 15).path(in: rect).forEach { element in
      switch element {
      case .move(let to), .line(let to): points.append(to)
      case .quadCurve(let to, _): points.append(to)
      case .curve(let to, _, _): points.append(to)
      case .closeSubpath: break
      }
    }
    let first = try #require(points.first)
    #expect(first == CGPoint(x: rect.midX, y: rect.minY), "starts at \(first)")
    // Clockwise on screen (y down): along the top to the right first.
    #expect(points.count > 1 && points[1].x > first.x && abs(points[1].y - first.y) < 0.5, "\(points.prefix(3))")

    let start = Date(timeIntervalSinceReferenceDate: 0)
    let fills = [0.0, 0.5, 2, 6, 60].map {
      UploadRing.at(start.addingTimeInterval($0), startedAt: start, landedAt: nil)
    }
    #expect(fills[0].fill == 0)
    #expect(zip(fills, fills.dropFirst()).allSatisfy { $0.fill < $1.fill }, "\(fills)")
    #expect(fills.allSatisfy { $0.fill < 1 && $0.opacity == 1 }, "\(fills)")
    let landed = start.addingTimeInterval(2)
    let atLanding = UploadRing.at(landed, startedAt: start, landedAt: landed)
    #expect(abs(atLanding.fill - UploadRing.fill(after: 2)) < 0.001 && atLanding.opacity == 1)
    let closed = UploadRing.at(landed.addingTimeInterval(UploadRing.closeTime), startedAt: start, landedAt: landed)
    #expect(closed.fill == 1 && closed.opacity == 1, "\(closed)")
    let gone = UploadRing.at(landed.addingTimeInterval(UploadRing.finishTime), startedAt: start, landedAt: landed)
    #expect(gone.opacity < 0.001, "\(gone)")
  }

  // MARK: - Empty and drag-over states

  @Test("With and without history a drag shows the drag-over layer over the content, with the count and the project; no accent stroke")
  func dragOver() async throws {
    let (model, _, _) = try makeModel()
    model.selectedProjectSlug = "notes"
    let dragged = (1...3).map { URL(fileURLWithPath: "/pinax-dz/drag-\($0).png") }
    for history in [false, true] {
      if history {
        model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/earlier.png")])
        await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
      }
      model.dragDidChange(fileURLs: dragged, modifiers: [])
      let state = DropZoneViewState()
      state.isDropTargeted = true
      let frames = await hostPanel(model, state: state)
      let overlay = try #require(frames[Part(card: nil, role: .dropOverlay)], "history \(history)")
      let content = try #require(
        history
          ? frames[Part(card: model.cards[0].id, role: .card)]
          : frames[Part(card: nil, role: .emptyState)], "history \(history)")
      #expect(overlay.insetBy(dx: -0.5, dy: -0.5).contains(content), "\(overlay) ⊉ \(content)")
      let view = DropZoneView(model: model, state: state)
      #expect(DropZoneDragOverlay.title == "Drop to upload")
      #expect(view.dragOverlayContent.subtitle == "3 images into Notes", "history \(history)")
      model.dragDidEnd()
    }
    // No project.
    model.selectedProjectSlug = nil
    model.dragDidChange(fileURLs: dragged, modifiers: [])
    let view = DropZoneView(model: model, state: DropZoneViewState())
    #expect(view.dragOverlayContent.subtitle.contains("No project"), "\(view.dragOverlayContent.subtitle)")
    #expect(view.dragOverlayContent.subtitle.hasPrefix("3 images"))
    model.dragDidEnd()
    #expect(model.draggedFileURLs.isEmpty)
    // The old whole-panel accent stroke is gone.
    let source = try String(contentsOf: DropZoneLookTests.source("DropZone/DropZoneView.swift"), encoding: .utf8)
    #expect(!source.contains("strokeBorder(Color.accentColor"))
  }

  @Test("The same bytes again move the existing card to the front in the in-library look with the new drop's project; no new row. Bytes never seen add one card")
  func duplicateMergesIntoExistingCard() async throws {
    let (model, _, _) = try makeModel()
    let url = { (name: String) in URL(fileURLWithPath: "/pinax-dz/\(name).png") }
    model.drop(fileURLs: [url("a")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    model.drop(fileURLs: [url("other")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let a = try #require(model.cards.first { $0.filename == "a.png" })
    #expect(DropZoneCardStatus(card: a).kind == .uploaded)
    #expect(model.cards.map(\.filename) == ["other.png", "a.png"])

    // A′: the same bytes, dropped into Notes.
    model.selectedProjectSlug = "notes"
    model.drop(fileURLs: [url("dedupe-a")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.cards.count == 2)
    #expect(model.cards.map(\.id) == [a.id, model.cards[1].id])
    #expect(model.cards.first?.projectSlug == "notes")
    #expect(model.cards.first.map { DropZoneCardStatus(card: $0).kind } == .inLibrary)
    #expect(model.cards.first?.landedAt == nil)

    // B: in the library already, but not in the list — a card of its own.
    model.drop(fileURLs: [url("dedupe-b")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    #expect(model.cards.count == 3)
    #expect(model.cards.first?.filename == "dedupe-b.png")
    #expect(model.cards.first.map { DropZoneCardStatus(card: $0).kind } == .inLibrary)
  }

  @Test("One viewfinder — the same frame and the same ink, empty and under a drag")
  func oneViewfinder() async throws {
    let (model, _, _) = try makeModel()
    let resting = DropZoneViewState()
    let empty = await hostPanel(model, state: resting)
    let dragged = DropZoneViewState()
    dragged.isDropTargeted = true
    model.dragDidChange(fileURLs: [URL(fileURLWithPath: "/pinax-dz/drag-1.png")], modifiers: [])
    let targeted = await hostPanel(model, state: dragged)
    model.dragDidEnd()
    let still = try #require(empty[Part(card: nil, role: .viewfinder)])
    let drag = try #require(targeted[Part(card: nil, role: .viewfinder)])
    for (a, b) in [(still.minX, drag.minX), (still.minY, drag.minY), (still.width, drag.width), (still.height, drag.height)] {
      #expect(abs(a - b) <= 0.5, "\(still) vs \(drag)")
    }
    let restingInk = DropZoneView(model: model, state: resting).viewfinder.ink
    let dragInk = DropZoneView(model: model, state: dragged).viewfinder.ink
    #expect(restingInk == dragInk)
    #expect(dragInk == DropZonePalette.light.ink)
  }

  @Test("Under a drag the scrim is the whole panel; the header lies above it, where it was without a drag")
  func scrimCoversPanel() async throws {
    let (model, _, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/earlier.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let before = await hostPanel(model, state: DropZoneViewState())
    let state = DropZoneViewState()
    state.isDropTargeted = true
    let during = await hostPanel(model, state: state)
    let panel = try #require(during[Part(card: nil, role: .panel)])
    let scrim = try #require(during[Part(card: nil, role: .dropOverlay)])
    #expect(scrim == panel, "\(scrim) ≠ \(panel)")
    #expect(DropZoneView.Layer.header.rawValue > DropZoneView.Layer.scrim.rawValue)
    for role: DropZoneLayoutKey.Role in [.projectPicker, .action("Pin"), .action("Close")] {
      let rest = try #require(before[Part(card: nil, role: role)], "\(role)")
      let drag = try #require(during[Part(card: nil, role: role)], "\(role)")
      #expect(rest == drag, "\(role): \(rest) vs \(drag)")
    }
  }

  @Test("An icon button grows a little under the pointer and shrinks a little when pressed, over a ~120 ms fade; with Reduce Motion it keeps its size")
  func iconButtonMotion() {
    let motion = DropZoneIconMotion.self
    #expect(abs(motion.fade - 0.12) < 0.03)
    #expect(motion.scale(hovered: false, pressed: false, reducesMotion: false) == 1)
    #expect(motion.scale(hovered: true, pressed: false, reducesMotion: false) == motion.hoverScale)
    #expect(motion.scale(hovered: true, pressed: true, reducesMotion: false) == motion.pressScale)
    #expect(abs(motion.hoverScale - 1.06) < 0.005)
    #expect(abs(motion.pressScale - 0.94) < 0.005)
    for hovered in [false, true] {
      for pressed in [false, true] {
        #expect(motion.scale(hovered: hovered, pressed: pressed, reducesMotion: true) == 1)
      }
    }
  }

  @Test("The empty state says where images go — the project, or No project")
  func emptyStateWords() async throws {
    let (model, _, _) = try makeModel()
    model.selectedProjectSlug = "notes"
    let frames = await hostPanel(model, state: DropZoneViewState())
    #expect(frames[Part(card: nil, role: .emptyState)] != nil)
    #expect(DropZoneEmptyState.title == "Drop images here")
    #expect(DropZoneView(model: model, state: DropZoneViewState()).emptyStateContent.destination == "They go to Notes")
    model.selectedProjectSlug = nil
    #expect(DropZoneView(model: model, state: DropZoneViewState()).emptyStateContent.destination == "No project")
  }

  // MARK: - Move to project

  @Test("One menu content — No project + every project, the card's checked — behind the token and the context menu; both off until landed")
  func moveMenu() async throws {
    let (model, service, _) = try makeModel()
    let items = DropZoneProjectMenu.items(projects: model.projects, current: "blog")
    #expect(items.map(\.title) == ["No project", "Blog", "Notes"])
    #expect(items.map(\.isChecked) == [false, true, false])
    #expect(DropZoneProjectMenu.items(projects: model.projects, current: nil).map(\.isChecked) == [true, false, false])

    let cards = try await cardsInEveryState(model, service)
    defer { service.releaseAll() }
    let isMenu: (Any) -> Bool = { _ in true }
    for (name, id) in cards {
      let card = try #require(model.cards.first { $0.id == id })
      let view = ResultCardView(card: card, model: model, state: DropZoneViewState())
      let landed = name == "done" || name == "dedupe"
      // p2: the token; p3: the context menu's Projects ▸.
      let p2 = buttonIsEnabled(
        in: DropZoneProjectToken(card: card, model: model, canMove: view.isDone).body,
        label: isMenu, control: "Menu<")
      let p3 = buttonIsEnabled(
        in: DropZoneCardContextMenu(
          card: card, model: model, actions: view.actions, retry: view.retryAction,
          canMove: view.isDone
        ).body, label: isMenu, control: "Menu<")
      #expect(p2 == landed && p3 == landed, "\(name): \(String(describing: p2)) \(String(describing: p3))")
    }
    // Choosing goes through the model's move.
    let done = try #require(cards["done"])
    model.changeProject(done, to: "notes")
    #expect(model.cards.first { $0.id == done }?.projectSlug == "notes")
  }

  // MARK: - Shelf cells and the List row

  @Test("Shelf: wide, tall, already-in-library and failed cells keep image, copy and words inside their own column and row")
  func shelfCellsStayInTheirCells() async throws {
    let (model, _, _) = try makeModel()
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-shelf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let files: [(String, Int, Int)] = [("wide.png", 1600, 400), ("tall.png", 300, 1200), ("dedupe-pano.png", 2400, 500)]
    var urls: [URL] = []
    for (name, width, height) in files {
      let url = folder.appendingPathComponent(name)
      try writePNG(width: width, height: height, to: url)
      urls.append(url)
    }
    let failed = folder.appendingPathComponent("fail-notes.md")
    try Data("# notes".utf8).write(to: failed)
    model.drop(fileURLs: urls + [failed])
    await waitUntil {
      model.cards.allSatisfy { !$0.phase.isPending }
        && model.cards.filter { $0.filename.hasSuffix(".png") }.allSatisfy { $0.thumbnail != nil }
    }
    #expect(model.cards.filter { $0.thumbnail != nil }.count == 3)
    let state = DropZoneViewState()
    state.layout = .shelf
    let frames = await hostPanel(model, state: state)
    let inset = DesignMetrics.dropZone.panelInset
    let width = DropZonePanel.defaultSize.width
    let column = (width - 2 * inset - DesignMetrics.dropZone.shelfColumnGap) / 2
    let columns = [inset...(inset + column), (width - inset - column)...(width - inset)]
    let cells = try model.cards.map { card in
      try #require(frames[Part(card: card.id, role: .card)], "\(card.filename)")
    }
    for (index, card) in model.cards.enumerated() {
      let range = columns[index % 2]
      for role: Role in [.card, .thumbnail, .statusLayer, .filename] {
        let frame = try #require(frames[Part(card: card.id, role: role)], "\(card.filename) \(role)")
        // The status drawing may reach `statusOutset` past its image, into
        // the column and row gaps; never further.
        let slack = role == .statusLayer ? DesignMetrics.dropZone.statusOutset + 0.5 : 0.5
        #expect(
          frame.minX >= range.lowerBound - slack && frame.maxX <= range.upperBound + slack,
          "\(card.filename) \(role) \(frame.minX)…\(frame.maxX) outside \(range)")
        // Nothing reaches into the row above.
        if index >= 2 {
          #expect(frame.minY >= cells[index - 2].maxY - slack, "\(card.filename) \(role) \(frame) over \(cells[index - 2])")
        }
      }
    }
  }

  @Test("Shelf: the status drawings of the first row and the left column (ring, in-library copy) stay inside the scroll area that clips them")
  func shelfStatusNotClipped() async throws {
    let (model, service, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/dedupe-x.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    model.drop(fileURLs: ["block-1", "block-2"].map { URL(fileURLWithPath: "/pinax-dz/\($0).png") })
    defer { service.releaseAll() }
    await waitUntil { model.cards.filter { $0.phase == .uploading }.count == 2 }
    let state = DropZoneViewState()
    state.layout = .shelf
    let frames = await hostPanel(model, state: state)
    let scroll = try #require(frames[Part(card: nil, role: .scroll)])
    for card in model.cards {
      let layer = try #require(frames[Part(card: card.id, role: .statusLayer)], "\(card.filename)")
      let image = try #require(frames[Part(card: card.id, role: .thumbnail)], "\(card.filename)")
      // The layer is the drawing's reach, not the image's frame.
      #expect(layer.width > image.width + 1, "\(card.filename) layer \(layer) image \(image)")
      #expect(scroll.contains(layer), "\(card.filename) \(layer) clipped by \(scroll)")
    }
  }

  @Test("List: the project token sits in the icon row after the actions; the row has no separate move icon")
  func listTokenInIconRow() async throws {
    let (model, _, _) = try makeModel()
    model.drop(fileURLs: [URL(fileURLWithPath: "/pinax-dz/a.png")])
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    let frames = await hostPanel(model, state: DropZoneViewState())
    let id = model.cards[0].id
    let token = try #require(frames[Part(card: id, role: .projectToken)])
    let row = try #require(frames[Part(card: id, role: .buttons)])
    let last = try #require(frames[Part(card: id, role: .action("quickLook"))])
    #expect(abs(token.midY - row.midY) <= 1, "token \(token) row \(row)")
    #expect(token.minX >= last.maxX, "token \(token) after \(last)")
    #expect(frames[Part(card: id, role: .action("project"))] == nil)
  }

  // MARK: - Helpers

  private func makeModel() throws -> (DropZoneModel, GatedUploadService, Counter) {
    let fetches = Counter()
    let thumbnails = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-cards-\(UUID().uuidString)", isDirectory: true),
      fetcher: { _ in
        fetches.increment()
        throw URLError(.unsupportedURL)
      })
    let service = GatedUploadService()
    let model = DropZoneModel(service: service, thumbnails: thumbnails)
    model.copiesURLsAutomatically = false
    model.loadProjects()
    // The zone starts on All Projects; the cards here are Blog's.
    model.selectedProjectSlug = "blog"
    return (model, service, fetches)
  }

  /// One card per state: done, dedupe, failed settle first; then four
  /// blocked uploads fill the four slots, so the fifth card stays waiting.
  private func cardsInEveryState(
    _ model: DropZoneModel, _ service: GatedUploadService
  ) async throws -> [String: UUID] {
    model.drop(fileURLs: ["done", "dedupe-d", "fail-f"].map { URL(fileURLWithPath: "/pinax-dz/\($0).png") })
    await waitUntil { model.cards.allSatisfy { !$0.phase.isPending } }
    model.drop(
      fileURLs: ["block-1", "block-2", "block-3", "block-4", "waiting"].map {
        URL(fileURLWithPath: "/pinax-dz/\($0).png")
      })
    await waitUntil { model.cards.filter { $0.phase == .uploading }.count == 4 }
    func id(_ filename: String) throws -> UUID {
      try #require(model.cards.first { $0.filename == filename }?.id)
    }
    let waiting = try id("waiting.png")
    #expect(model.cards.first { $0.id == waiting }?.phase == .waiting)
    return [
      "done": try id("done.png"), "dedupe": try id("dedupe-d.png"), "failed": try id("fail-f.png"),
      "uploading": try id("block-1.png"), "waiting": waiting,
    ]
  }

  /// Every card, non-lazily, at the list's width inside the panel.
  /// A plain grey PNG of the given pixel size.
  private func writePNG(width: Int, height: Int, to url: URL) throws {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let rep = NSBitmapImageRep(cgImage: image)
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
  }

  private func hostCards(_ model: DropZoneModel) async -> [Part: CGRect] {
    let box = FramesBox()
    let state = DropZoneViewState()
    let width = DropZonePanel.defaultSize.width - 2 * DesignMetrics.spacing.m
    let root = VStack(spacing: DesignMetrics.spacing.s) {
      ForEach(model.cards) { ResultCardView(card: $0, model: model, state: state) }
    }
    .frame(width: width)
    .fixedSize(horizontal: false, vertical: true)
    .coordinateSpace(name: DropZoneView.space)
    .onPreferenceChange(DropZoneLayoutKey.self) { box.frames = $0 }
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(0.4)
    return box.frames
  }

  private func hostPanel(_ model: DropZoneModel, state: DropZoneViewState) async -> [Part: CGRect] {
    let box = FramesBox()
    let (window, pump) = host(model, state: state, box: box)
    defer { window.orderOut(nil) }
    await pump()
    return box.frames
  }

  /// `hostPanel`, read as soon as `ready` holds instead of after the fixed
  /// pump: for a reading that itself goes stale with time.
  private func hostPanel(
    _ model: DropZoneModel, state: DropZoneViewState, until ready: () -> Bool
  ) async {
    let box = FramesBox()
    let (window, _) = host(model, state: state, box: box)
    defer { window.orderOut(nil) }
    await spin(until: ready)
  }

  /// The real panel view in a panel of its real size.
  private func host(
    _ model: DropZoneModel, state: DropZoneViewState, box: FramesBox
  ) -> (NSWindow, () async -> Void) {
    let root = DropZoneView(model: model, state: state)
      .onPreferenceChange(DropZoneLayoutKey.self) { box.frames = $0 }
    let window = NSPanel(
      contentRect: NSRect(origin: .zero, size: DropZonePanel.defaultSize),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: root)
    window.orderFrontRegardless()
    return (window, { await self.spin(0.4) })
  }

  /// A view's width at its ideal size, read by a GeometryReader.
  private func idealWidth<V: View>(_ view: V) async -> CGFloat {
    let box = WidthBox()
    let root = view.fixedSize()
      .background(GeometryReader { proxy in
        Color.clear.onAppear { box.width = proxy.size.width }
      })
      .frame(width: 400, height: 60)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 60), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: root)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    await spin(0.1)
    return box.width
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

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

@MainActor
private final class FramesBox {
  var frames: [DropZoneLayoutKey.Part: CGRect] = [:]
}

@MainActor
private final class WidthBox {
  var width: CGFloat = 0
}

@MainActor
private final class Copied {
  var values: [String] = []
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var backing = 0
  var value: Int { lock.withLock { backing } }
  func increment() { lock.withLock { backing += 1 } }
}

/// Uploads by filename: `fail-*` throws, `dedupe-*` lands deduplicated,
/// `block-*` holds until `releaseAll()`, anything else lands at once.
private final class GatedUploadService: DropZoneService, @unchecked Sendable {
  private let lock = NSLock()
  private var released = false

  func releaseAll() { lock.withLock { released = true } }

  func projects() throws -> [Project] {
    [
      Project(
        slug: "blog", name: "Blog", keyPrefix: "blog", backendID: 1,
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z"),
      Project(
        slug: "notes", name: "Notes", keyPrefix: "notes", backendID: 1,
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z"),
    ]
  }

  func upload(_ fileURL: URL, projectSlug: String?) async throws -> UploadOutcome {
    let name = fileURL.lastPathComponent
    if name.hasPrefix("fail-") { throw GatedError() }
    if name.hasPrefix("block-") {
      while !lock.withLock({ released }) {
        try? await Task.sleep(nanoseconds: 5_000_000)
      }
    }
    // The bytes: a "dedupe-" drop is the same image as the drop without
    // the prefix; every other name is its own image.
    let stem = name.hasPrefix("dedupe-") ? String(name.dropFirst("dedupe-".count)) : name
    return UploadOutcome(
      sha256: Hashing.sha256(of: Data(stem.utf8)), key: "blog/\(name)",
      url: "https://img.example.com/blog/\(name)", mime: "image/png", originalFilename: name,
      byteSize: 1234, width: 800, height: 600, uploadedAt: "2026-08-22T00:00:00Z",
      deduplicated: name.hasPrefix("dedupe-"), dryRun: false)
  }

  func moveAsset(sha256: String, fromProject: String?, toProject: String?, confirmed: Bool) async throws {}
}

private struct GatedError: LocalizedError {
  var errorDescription: String? { "The backend refused the upload." }
}

