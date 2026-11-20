import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import Testing

/// Bulk previews on Other Domains — one request
/// per distinct URL, at most four at once, Stop dropping only the queued
/// ones, nothing asked unless a Load was — the capsule's three states,
/// the group headers' N, the menu's shape, several rows' summary, and
/// Group by File behaving as host grouping does.
@MainActor
@Suite struct ExternalsPreviewsTests {
  static func row(
    _ source: String, _ url: String, domain: ExternalDomain = .other
  ) -> ExternalReference {
    ExternalReference(
      projectSlug: "blog", sourceReference: source, rawURL: url, kind: "markdown",
      domain: domain,
      match: domain == .yours
        ? ExternalDomainMatch(
          backendSlug: "r2", prefix: "https://img.pinax.invalid", isCurrent: true) : nil)
  }

  /// Ten distinct Other Domains URLs on two hosts, two of them referenced
  /// twice, in three files; one Your Domains row.
  static let rows: [ExternalReference] =
    (0..<6).map { row("posts/a.md#L\($0 + 1)", "https://one.example.org/\($0).png") }
    + (0..<4).map { row("posts/b.md#L\($0 + 1)", "https://two.example.net/\($0).png") }
    + [
      row("posts/c.md#L1", "https://one.example.org/0.png"),
      row("posts/c.md#L2", "https://two.example.net/0.png"),
      row("posts/a.md#L9", "https://img.pinax.invalid/blog/mine.png", domain: .yours),
    ]

  private struct StaticExternals: ExternalUsageReading {
    let rows: [ExternalReference]
    var sources: [String: [ProjectSource]] = [:]
    func externalReferences(project: String?) async throws -> ExternalReferenceSet {
      ExternalReferenceSet(references: rows, projectSources: sources)
    }
  }

  /// A fetcher that holds every request until opened, counting how many
  /// are inside it at once.
  final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var inside = 0
    private var peak = 0
    private var asked: [URL] = []

    func setOpen() { lock.withLock { open = true } }
    var isOpen: Bool { lock.withLock { open } }
    var urls: [URL] { lock.withLock { asked } }
    var maxInside: Int { lock.withLock { peak } }

    func fetch(_ url: URL) async throws -> Data {
      lock.withLock {
        asked.append(url)
        inside += 1
        peak = max(peak, inside)
      }
      while !isOpen { try await Task.sleep(nanoseconds: 5_000_000) }
      lock.withLock { inside -= 1 }
      return pngData(width: 8, height: 8)
    }
  }

  private func makeModel(gate: Gate, sources: [String: [ProjectSource]] = [:]) async
    -> ExternalsModel
  {
    // The cache's own bound is lifted, so the one measured is the model's.
    let thumbnails = ThumbnailCache(
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-m0-\(UUID().uuidString)", isDirectory: true),
      fetcher: { try await gate.fetch($0) }, maxConcurrentDownloads: 32)
    let model = ExternalsModel(
      reader: StaticExternals(rows: Self.rows, sources: sources), thumbnails: thumbnails)
    await model.selectProject("blog")
    model.domain = .other
    return model
  }

  private func until(seconds: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func shown(_ model: ExternalsModel) -> [ExternalReference] {
    model.groups.flatMap(\.rows)
  }

  private func isLoaded(_ state: ExternalThumbnail?) -> Bool {
    if case .loaded? = state { return true }
    return false
  }

  // MARK: - Batch

  @Test("Load All asks each distinct URL once, never more than four at a time")
  func dedupeAndConcurrency() async {
    let gate = Gate()
    let model = await makeModel(gate: gate)
    let rows = shown(model)
    #expect(rows.count == 12)

    model.loadPreviews(rows)
    model.loadPreviews(rows)  // a second Load while queued adds nothing
    await until { gate.urls.count == 4 }
    await until(seconds: 0.2) { false }
    #expect(gate.urls.count == ExternalsModel.previewConcurrency)
    #expect(model.previewActivity?.total == 10)
    #expect(model.previewActivity?.text.hasPrefix("Loading previews 0 of 10 · ") == true)

    gate.setOpen()
    await until { model.previewActivity?.isFinished == true }
    #expect(gate.maxInside == 4)
    #expect(gate.urls.count == 10)
    #expect(Set(gate.urls.map(\.absoluteString)) == Set(rows.map(\.rawURL)))
    #expect(rows.allSatisfy { isLoaded(model.thumbnail($0)) })
    #expect(model.previewActivity?.text == "Loaded 10 previews")

    // Loaded URLs are not asked again.
    model.loadPreviews(rows)
    #expect(gate.urls.count == 10)
  }

  @Test("Stop drops the queued URLs; the four already asked finish")
  func stopOnlyQueued() async {
    let gate = Gate()
    let model = await makeModel(gate: gate)
    let rows = shown(model)
    model.loadPreviews(rows)
    await until { gate.urls.count == 4 }

    model.stopPreviews()
    #expect(model.previewActivity?.total == 4)
    #expect(model.previewActivity?.isStopping == true)
    gate.setOpen()
    await until { model.previewActivity?.isFinished == true }
    await until(seconds: 0.2) { false }
    #expect(gate.urls.count == 4)
    #expect(model.previewActivity?.text == "Loaded 4 previews")
    let loaded = Set(rows.filter { isLoaded(model.thumbnail($0)) }.map(\.rawURL))
    #expect(loaded == Set(gate.urls.map(\.absoluteString)))
    #expect(model.previewCapsule?.text == "4 of 10 previews loaded")
    #expect(model.previewCapsule?.showsLoadAll == true)
  }

  @Test("Switching halves or grouping, reloading and drawing ask nothing; loaded previews stay")
  func privacy() async throws {
    let gate = Gate()
    gate.setOpen()
    let model = await makeModel(gate: gate)
    for row in shown(model) {
      model.loadThumbnail(row)
      _ = model.thumbnail(row)
    }
    model.domain = .yours
    model.domain = .other
    model.groupsByFile = true
    model.groupsByFile = false
    await model.load()
    _ = model.previewCapsule
    _ = model.groups.map(model.groupPreview)
    _ = model.menuItems(for: Set(shown(model).map(\.id)))
    await until(seconds: 0.2) { false }
    #expect(gate.urls.isEmpty)
    #expect(shown(model).allSatisfy { model.thumbnail($0) == nil })

    let first = try #require(shown(model).first)
    model.loadPreviews([first])
    await until { isLoaded(model.thumbnail(first)) }
    model.domain = .yours
    model.domain = .other
    model.groupsByFile = true
    await model.load()
    #expect(isLoaded(model.thumbnail(first)))
    #expect(gate.urls.count == 1)
  }

  // MARK: - Capsule, group headers

  @Test("The capsule reads N of M with Load All, then All M alone; none on Your Domains")
  func capsule() async {
    let gate = Gate()
    gate.setOpen()
    let model = await makeModel(gate: gate)
    #expect(model.previewCapsule?.text == "0 of 10 previews loaded")
    #expect(model.previewCapsule?.showsLoadAll == true)

    let one = shown(model).filter { $0.rawURL.contains("two.example.net") }
    model.loadPreviews(one)
    await until { model.previewActivity?.isFinished == true }
    #expect(model.previewCapsule?.text == "4 of 10 previews loaded")

    model.loadPreviews(shown(model))
    await until { model.previewCapsule?.loaded == 10 }
    #expect(model.previewCapsule?.text == "All 10 previews loaded")
    #expect(model.previewCapsule?.showsLoadAll == false)

    model.domain = .yours
    #expect(model.previewCapsule == nil)

    let empty = ExternalsModel(reader: StaticExternals(rows: [Self.rows.last!]))
    await empty.selectProject("blog")
    empty.domain = .other
    #expect(empty.previewCapsule == nil)
  }

  @Test("A group's Load N counts its unloaded distinct URLs, then ✓ Previews; host and file groups alike")
  func groupHeaders() async throws {
    let gate = Gate()
    gate.setOpen()
    let model = await makeModel(gate: gate)
    let hosts = Dictionary(uniqueKeysWithValues: model.groups.map { ($0.host, $0) })
    let one = try #require(hosts["one.example.org"])
    let two = try #require(hosts["two.example.net"])
    #expect(one.rows.count == 7)
    #expect(model.groupPreview(one) == .load(6))
    #expect(model.groupPreview(two) == .load(4))

    model.loadPreviews(two.rows)
    await until { model.groupPreview(two) == .loaded }
    #expect(model.groupPreview(two) == .loaded)
    #expect(model.groupPreview(one) == .load(6))

    // Group by File: c.md shares one URL from each host; one is loaded.
    model.groupsByFile = true
    let files = Dictionary(uniqueKeysWithValues: model.groups.map { ($0.host, $0) })
    #expect(model.groupPreview(try #require(files["posts/c.md"])) == .load(1))
    #expect(model.groupPreview(try #require(files["posts/b.md"])) == .loaded)
    #expect(model.groupPreview(try #require(files["posts/a.md"])) == .load(6))

    model.domain = .yours
    #expect(model.groups.allSatisfy { model.groupPreview($0) == .none })
  }

  // MARK: - Menu, several rows

  @Test("One row keeps the singular names with Load Preview; several lead with N Images")
  func menu() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinaxui-m0-src-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: source) }
    for name in ["a.md", "b.md", "c.md"] {
      try "x\n".write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let gate = Gate()
    gate.setOpen()
    let model = await makeModel(
      gate: gate, sources: ["blog": [ProjectSource(label: "posts", path: source.path)]])
    let rows = shown(model)
    let a0 = try #require(rows.first { $0.sourceReference == "posts/a.md#L1" })
    let b0 = try #require(rows.first { $0.sourceReference == "posts/b.md#L1" })
    let c1 = try #require(rows.first { $0.sourceReference == "posts/c.md#L1" })

    let single = model.menuItems(for: [a0.id])
    #expect(single.map(\.title) == ["Load Preview", "Copy URL", "Open URL", "Open File", "Reveal in Finder"])

    // a0 and c1 share a URL: three rows, two images, three files.
    let several = model.menuItems(for: [a0.id, b0.id, c1.id])
    #expect(several.map(\.title) == [
      "2 Images", "Load Previews", "Copy URLs", "Open URLs", "Open Files", "Reveal in Finder",
    ])
    #expect(several.first { $0.id == "openFile" }?.badge == 3)
    let load = try #require(several.first { $0.id == "loadPreviews" })
    #expect(ExternalMenuButtons.dividesAfter(load, in: several))

    model.perform(load)
    await until { model.previewActivity?.isFinished == true }
    #expect(Set(gate.urls.map(\.absoluteString)) == [a0.rawURL, b0.rawURL])
    #expect(!model.menuItems(for: [a0.id, b0.id, c1.id]).contains { $0.id == "loadPreviews" })
    #expect(model.menuItems(for: [a0.id, c1.id]).first?.title == "1 Image")
  }

  @Test("Several rows read as images, hosts and files, in the inspector and the status bar")
  func selectionSummary() async throws {
    let model = await makeModel(gate: Gate())
    let rows = shown(model)
    let a0 = try #require(rows.first { $0.sourceReference == "posts/a.md#L1" })
    let b0 = try #require(rows.first { $0.sourceReference == "posts/b.md#L1" })
    let c1 = try #require(rows.first { $0.sourceReference == "posts/c.md#L1" })
    #expect(model.selectionStatusText == nil)

    model.selection = [a0.id, b0.id, c1.id]
    let summary = try #require(model.selectionSummary(model.selection))
    #expect(summary.images.count == 2)
    #expect(summary.hosts == [.init(host: "one.example.org", refs: 2), .init(host: "two.example.net", refs: 1)])
    #expect(summary.files == 3)
    #expect(model.selectionStatusText == "3 selected · 2 hosts · 3 files")

    model.selection = [a0.id]
    #expect(model.selectionStatusText == "1 selected · 1 host · 1 file")
  }

  // MARK: - Group pop-up, Group by File

  @Test("The Group pop-up names Host, Domain or Used In, with a filled grouping symbol")
  func groupPopUp() {
    #expect(ExternalsGroupByFileToggle.title(byFile: false, domain: .other) == "Group: Host")
    #expect(ExternalsGroupByFileToggle.title(byFile: false, domain: .yours) == "Group: Domain")
    #expect(ExternalsGroupByFileToggle.title(byFile: true, domain: .other) == "Group: Used In")
    #expect(JumpBar.Control.groupByFile.systemImage == ExternalsView.groupSymbol)
    for symbol in ExternalsView.symbols {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
  }

  @Test("Under Group by File, ⌘ and ⇧ selection, the menu and Load behave as under hosts")
  func groupByFileSameBehaviour() async throws {
    let gate = Gate()
    gate.setOpen()
    let model = await makeModel(gate: gate)
    var event: NSEvent?
    model.currentEvent = { event }
    func click(_ flags: NSEvent.ModifierFlags) -> NSEvent {
      NSEvent.mouseEvent(
        with: .leftMouseUp, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    var menus: [[ExternalMenuItem]] = []
    for byFile in [false, true] {
      model.groupsByFile = byFile
      let order = shown(model)
      event = click([])
      model.clickCell(order[1])
      event = click(.shift)
      model.clickCell(order[4])
      #expect(model.selection == Set(order[1...4].map(\.id)), "byFile \(byFile)")
      event = click(.command)
      model.clickCell(order[6])
      #expect(model.selection.count == 5, "byFile \(byFile)")
      menus.append(model.menuItems(for: Set(order[1...4].map(\.id))))
    }
    // The same rows give the same menu either way (order aside: the rows
    // themselves differ by grouping, so compare one fixed set).
    let fixed = Set(Self.rows.prefix(3).map(\.id))
    model.groupsByFile = false
    let byHost = model.menuItems(for: fixed)
    model.groupsByFile = true
    #expect(model.menuItems(for: fixed) == byHost)
    #expect(menus.allSatisfy { $0.first?.id == "title" })

    model.loadPreviews(model.groups.first?.rows ?? [])
    await until { model.previewActivity?.isFinished == true }
    #expect(model.groupPreview(try #require(model.groups.first)) == .loaded)
  }
}
