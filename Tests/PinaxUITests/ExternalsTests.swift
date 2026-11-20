import CatalogCore
import AppKit
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// Externals in two halves — Your Domains | Other
/// Domains — scoped to the current project.
@MainActor
@Suite struct ExternalsTests {
  // MARK: - Property 1: the two halves

  @Test("Your Domains and Other Domains, hand-counted, current and retired prefixes both yours")
  func twoHalves() async throws {
    try await withFixture { database in
      let all = try await CatalogUsage.externalReferences(in: database)
      #expect(urls(all, .yours) == [
        "https://img.example.com/blog/missing.png",
        "https://old.example.net/blog/lost.png",
        "https://cdn.example.net/blog/gone.png",
        "https://img.example.com/notes/missing.png",
      ])
      #expect(urls(all, .other) == [
        "https://elsewhere.example.org/x.png",
        "https://third.example.com/z.gif",
        "https://elsewhere.example.org/w.png",
        "https://elsewhere.example.org/y.png",
        "https://elsewhere.example.org/n.png",
        "https://elsewhere.example.org/m.png",
        "https://elsewhere.example.org/s.png",
      ])
      let blog = try await CatalogUsage.externalReferences(project: "blog", in: database)
      #expect(blog.references.filter { $0.domain == .yours }.map(\.sourceReference) == [
        "posts/a.md#L11", "posts/a.md#L4", "posts/b.md#L2",
      ])
      #expect(blog.references.filter { $0.domain == .other }.count == 4)
      #expect(Set(blog.references.map(\.projectSlug)) == ["blog"])

      // The model: Your Domains first; the segment titles carry the counts.
      let model = ExternalsModel(reader: ReadOnlyCatalog(database: database))
      await model.selectProject("blog")
      #expect(model.domain == .yours)
      #expect(model.count(.yours) == 3)
      #expect(model.count(.other) == 4)
      #expect(ExternalScopeBar.title(.yours) == "Your domains")
      #expect(ExternalScopeBar.title(.other) == "Other domains")
      #expect(shown(model) == [
        "https://img.example.com/blog/missing.png",
        "https://old.example.net/blog/lost.png",
        "https://cdn.example.net/blog/gone.png",
      ])
      model.domain = .other
      #expect(shown(model) == [
        "https://elsewhere.example.org/x.png",
        "https://third.example.com/z.gif",
        "https://elsewhere.example.org/w.png",
        "https://elsewhere.example.org/y.png",
      ])
      // A reload of the same scope keeps the half the user chose.
      await model.load()
      #expect(model.domain == .other)
      // A scope with no Your Domains row opens on Other Domains.
      await model.selectProject("shots")
      #expect(model.count(.yours) == 0)
      #expect(model.domain == .other)
      #expect(shown(model) == ["https://elsewhere.example.org/s.png"])
      // The explanation sits under Details, not in a popover.
      #expect(
        ReportHeaderModel.compose(externals: 1).details.last
          == ReportNote(
            heading: "Your Domains",
            lines: [
              "On your backends' domains but not in the catalog: a typo, an object removed "
                + "outside Pinax, or one uploaded by another tool."
            ]))
    }
  }

  // MARK: - Property 2: the current project scopes it

  @Test("Externals follows the current project, with no picker of its own")
  func followsCurrentProject() async throws {
    try await withFixture { database in
      let model = makeModel(database)
      await model.loadInitialData()
      model.select(.externals, in: .reports)
      await model.reload()
      #expect(model.externals.items?.count == 11)

      model.currentProjectSlug = "notes"
      await until { model.externals.items?.count == 3 }
      #expect(model.externals.items?.map(\.rawURL) == [
        "https://elsewhere.example.org/n.png",
        "https://elsewhere.example.org/m.png",
        "https://img.example.com/notes/missing.png",
      ])
      #expect(model.externals.count(.yours) == 1)

      model.currentProjectSlug = "blog"
      await until { model.externals.items?.count == 7 }
      #expect(Set(model.externals.items?.map(\.projectSlug) ?? []) == ["blog"])

      model.currentProjectSlug = nil
      await until { model.externals.items?.count == 11 }
      #expect(model.externals.selectedProjectSlug == nil)
    }
  }

  // MARK: - Property 3: selection, context menu, ⌘C, double-click

  @Test("The list's selection is the model's; the menu, ⌘C and double-click read as values; switching halves empties it")
  func selectionAndMenu() async throws {
    try await withFixture { database in
      let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-src-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: source) }
      // Only a.md is there: b.md's rows fail the Open File rule.
      let aFile = source.appendingPathComponent("a.md")
      try "x\n".write(to: aFile, atomically: true, encoding: .utf8)
      try CatalogConfiguration.setProjectSources(
        slug: "blog", [ProjectSource(label: "posts", path: source.path)], in: database)

      let model = ExternalsModel(reader: ReadOnlyCatalog(database: database))
      var opened: [URL] = []
      var revealed: [URL] = []
      model.open = { opened.append($0) }
      model.reveal = { revealed += $0 }
      await model.selectProject("blog")
      guard case let .results(rows) = model.presentation else {
        Issue.record("no rows")
        return
      }
      try #require(rows.map(\.sourceReference) == ["posts/a.md#L11", "posts/a.md#L4", "posts/b.md#L2"])

      // The grouped list's own binding drives the model (the Grid's taps
      // go through `clickCell`).
      model.viewMode = .table
      let bindings = collectViews(
        ExternalsView(model: model).body, as: Binding<Set<ExternalReference.ID>>.self)
      #expect(bindings.count == 1)
      bindings.first?.wrappedValue = [rows[2].id, rows[0].id]
      #expect(model.selection == [rows[0].id, rows[2].id])

      // Two rows: two lines in table order, LF as the library's Copy URL;
      // Open File only for a.md, the one the rule allows.
      let missing = URL(string: "https://img.example.com/blog/missing.png")!
      let gone = URL(string: "https://cdn.example.net/blog/gone.png")!
      let text = "https://img.example.com/blog/missing.png\nhttps://cdn.example.net/blog/gone.png"
      #expect(model.menuItems(for: model.selection) == [
        .title(2), .copyURL(text), .openURL([missing, gone]), .openFile([aFile]), .revealInFinder([aFile]),
      ])
      let board = NSPasteboard(name: NSPasteboard.Name("PinaxExternalsTests-\(UUID().uuidString)"))
      model.pasteboard = board
      // ⌘C through the action each view's copy: command holds.
      for mode in GalleryModel.ViewMode.allCases {
        model.viewMode = mode
        board.clearContents()
        let copy = try #require(commandAction(in: ExternalsView(model: model).body), "\(mode)")
        copy()
        #expect(board.string(forType: .string) == text, "\(mode)")
      }
      model.viewMode = .table
      #expect(model.menuItems(for: [rows[2].id]) == [.copyURL(gone.absoluteString), .openURL([gone])])
      #expect(model.menuItems(for: []).isEmpty)
      model.perform(.revealInFinder([aFile]))
      #expect(revealed == [aFile])

      // Double-click through the closure the view installs: the file where
      // the rule allows it, else the URL.
      // (SwiftUI's stored copy crashes when called from a test; the table
      // hands it its `open`, and the modifier is checked to hold one.)
      let list = try #require(collectViews(ExternalsView(model: model).body, as: ExternalsList.self).first)
      #expect(hasPrimaryAction(list.body))
      list.open([rows[0].id, rows[2].id])
      #expect(opened == [aFile, gone])

      // Switching halves, or the scope, empties the selection.
      model.domain = .other
      #expect(model.selection.isEmpty)
      model.domain = .yours
      model.selection = [rows[1].id]
      model.selectedProjectSlug = "notes"
      #expect(model.selection.isEmpty)
      await model.load()
      // A reload of the same scope keeps what is still there.
      await model.selectProject("blog")
      model.selection = [rows[1].id]
      await model.load()
      #expect(model.selection == [rows[1].id])
    }
  }

  // MARK: - Grouped by domain

  @Test("Both views draw one grouping, hand-counted — Your Domains by the prefix matched, current ahead of old; Other Domains by host")
  func groupsByDomain() async throws {
    try await withFixture { database in
      // A second row on b2's old domain: by count alone it would lead.
      try await database.write { db in
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            VALUES (1, NULL, 'https://old.example.net/blog/lost-2.png', 'posts/c.md#L3', 'markdown',
              '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z', 2)
            """)
      }
      let model = ExternalsModel(reader: ReadOnlyCatalog(database: database))
      await model.selectProject("blog")
      let yours = [
        "cdn.example.net · current domain of b2 · 1 · gone.png",
        "img.example.com · current domain of r2 · 1 · missing.png",
        "old.example.net · old domain of b2 · 2 · lost.png lost-2.png",
      ]
      let other = [
        "elsewhere.example.org · 3 · x.png w.png y.png",
        "third.example.com · 1 · z.gif",
      ]
      for mode in GalleryModel.ViewMode.allCases {
        model.domain = .yours
        model.viewMode = mode
        #expect(described(model) == yours, "\(mode)")
        model.domain = .other
        model.viewMode = mode
        #expect(described(model) == other, "\(mode)")
        // The view each mode puts up, both reading `groups`.
        let body = ExternalsView(model: model).body
        #expect(collectViews(body, as: ExternalsGrid.self).count == (mode == .grid ? 1 : 0))
        #expect(collectViews(body, as: ExternalsList.self).count == (mode == .table ? 1 : 0))
      }
      // The grouped list opens on the first group only.
      #expect(model.groups.map(model.isExpanded) == [true, false])
      model.setExpanded(model.groups[1], true)
      #expect(model.groups.map(model.isExpanded) == [true, true])
    }
  }

  // MARK: - Other Domains loads nothing it is not asked for

  @Test("Other Domains asks no host for a thumbnail in either view with every group open; Quick Look loads the one selected row's original, once")
  func otherDomainsLoadsNothing() async throws {
    try await withFixture { database in
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-externals-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let thumbs = ExternalsFetchLog()
      let originals = ExternalsFetchLog()
      let panel = FakeQuickLookPanel()
      let thumbnails = ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbs", isDirectory: true),
        fetcher: { url in
          thumbs.add(url)
          return pngData(width: 8, height: 8)
        })
      let model = GalleryModel(
        catalog: ReadOnlyCatalog(database: database),
        thumbnails: thumbnails,
        quickLook: QuickLookController(
          thumbnails: thumbnails,
          originals: OriginalImageCache(
            cacheDirectory: directory.appendingPathComponent("originals", isDirectory: true),
            fetcher: { url in
              originals.add(url)
              return pngData(width: 8, height: 8)
            }),
          placeholderDirectory: directory.appendingPathComponent("placeholders", isDirectory: true),
          panel: { panel }))
      await model.loadInitialData()
      model.currentProjectSlug = "blog"
      model.select(.externals, in: .reports)
      await model.reload()
      await until { model.externals.items?.count == 7 }
      let externals = model.externals
      externals.domain = .other

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      // The library's smallest rung, so all three domains' tiles are on
      // screen: the grid is lazy, as the library's is.
      window.contentView = NSHostingView(rootView: ExternalsView(model: externals, columns: 8))
      window.orderFront(nil)
      defer { window.close() }
      for mode in [GalleryModel.ViewMode.table, .grid, .table] {
        externals.viewMode = mode
        for group in externals.groups { externals.setExpanded(group, true) }
        await spin(0.5)
        externals.loadThumbnail(externals.groups[0].rows[0])
        #expect(externals.thumbnail(externals.groups[0].rows[0]) == nil)
      }
      #expect(thumbs.urls == [])

      // The same window does ask for Your Domains' images: the log sees it.
      externals.domain = .yours
      await until(seconds: 10) { thumbs.urls.count == 3 }
      #expect(Set(thumbs.urls.map(\.absoluteString)) == [
        "https://img.example.com/blog/missing.png",
        "https://old.example.net/blog/lost.png",
        "https://cdn.example.net/blog/gone.png",
      ])

      // Quick Look on one Other Domains row: its original, once.
      externals.domain = .other
      let row = try #require(externals.groups.first?.rows.first)
      externals.selection = [row.id]
      model.toggleQuickLookFromCommand()
      await until { panel.isVisible }
      #expect(panel.isVisible)
      #expect(originals.urls == [URL(string: "https://elsewhere.example.org/x.png")!])
      #expect(thumbs.urls.count == 3)
    }
  }

  // MARK: - Your Domains through the gallery's pipeline

  @Test("Your Domains' thumbnails come through the gallery's fetcher; a 404 reads as its status, a value")
  func yourDomainsThroughTheGallery() async throws {
    try await withFixture { database in
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-externals-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let thumbs = ExternalsFetchLog()
      let model = GalleryModel(
        catalog: ReadOnlyCatalog(database: database),
        thumbnails: ThumbnailCache(
          cacheDirectory: directory,
          fetcher: { url in
            thumbs.add(url)
            if url.lastPathComponent == "gone.png" { throw RemoteImageStatusError(statusCode: 404) }
            return pngData(width: 8, height: 8)
          }))
      let externals = model.externals
      await externals.selectProject("blog")
      let rows = externals.groups.flatMap(\.rows)
      try #require(rows.count == 3)
      for row in rows { externals.loadThumbnail(row) }
      // Asked once per URL.
      for row in rows { externals.loadThumbnail(row) }
      await until { rows.allSatisfy { externals.thumbnail($0) != .loading } }
      #expect(thumbs.urls.map(\.lastPathComponent).sorted() == ["gone.png", "lost.png", "missing.png"])
      let gone = try #require(rows.first { $0.rawURL.hasSuffix("gone.png") })
      #expect(externals.thumbnail(gone) == .failed("404 · not found"))
      #expect(ExternalInspector.remote(externals.thumbnail(gone)) == "404 · not found")
      for row in rows where row.id != gone.id {
        guard case .loaded = externals.thumbnail(row) else {
          Issue.record("\(row.rawURL): \(String(describing: externals.thumbnail(row)))")
          continue
        }
      }
      // The status check both default fetchers run, as values.
      let url = URL(string: "https://img.example.com/blog/missing.png")!
      let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
      let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      #expect(throws: RemoteImageStatusError(statusCode: 404)) {
        try RemoteImageStatusError.check(Data([1]), notFound)
      }
      #expect(try RemoteImageStatusError.check(Data([1]), ok) == Data([1]))
    }
  }

  // MARK: - Views per half; the selection stays

  @Test("Each half keeps its own view (Your Domains Grid, Other Domains List by default); switching views keeps the selection; Grid clicks select as the library's")
  func viewsPerHalf() async throws {
    try await withFixture { database in
      let gallery = makeModel(database)
      await gallery.loadInitialData()
      gallery.currentProjectSlug = "blog"
      gallery.select(.externals, in: .reports)
      await gallery.reload()
      await until { gallery.externals.items?.count == 7 }
      let model = gallery.externals
      #expect(model.domain == .yours)
      #expect(model.viewMode == .grid)
      model.domain = .other
      #expect(model.viewMode == .table)
      // The toolbar's Grid | List is the shown half's.
      let libraryMode = gallery.viewMode
      gallery.surfaceViewMode = .grid
      #expect(model.viewMode == .grid)
      #expect(gallery.viewMode == libraryMode)
      model.domain = .yours
      #expect(gallery.surfaceViewMode == .grid)
      gallery.surfaceViewMode = .table
      model.domain = .other
      #expect(model.viewMode == .grid)
      model.domain = .yours
      #expect(model.viewMode == .table)

      // Grid clicks, in the groups' order: cdn's gone, img's missing, old's lost.
      let rows = model.groups.flatMap(\.rows)
      try #require(rows.map(\.rawURL).map { URL(string: $0)!.lastPathComponent } == ["gone.png", "missing.png", "lost.png"])
      model.currentEvent = { self.click([]) }
      model.clickCell(rows[0])
      model.currentEvent = { self.click(.shift) }
      model.clickCell(rows[2])
      #expect(model.selection == Set(rows.map(\.id)))
      model.currentEvent = { self.click(.command) }
      model.clickCell(rows[1])
      let chosen: Set<ExternalReference.ID> = [rows[0].id, rows[2].id]
      #expect(model.selection == chosen)
      for mode in [GalleryModel.ViewMode.grid, .table, .grid] {
        gallery.surfaceViewMode = mode
        #expect(model.selection == chosen, "\(mode)")
      }
    }
  }

  // MARK: - A reload prunes the selection

  @Test("A reload keeps the selected rows still there and drops the rest")
  func reloadPrunesSelection() async throws {
    try await withFixture { database in
      let model = ExternalsModel(reader: ReadOnlyCatalog(database: database))
      await model.selectProject("blog")
      let rows = model.groups.flatMap(\.rows)
      let gone = try #require(rows.first { $0.rawURL.hasSuffix("gone.png") })
      let missing = try #require(rows.first { $0.rawURL.hasSuffix("missing.png") })
      model.selection = [gone.id, missing.id]
      try await database.write { db in
        try db.execute(sql: "DELETE FROM usage WHERE raw_url = ?", arguments: [gone.rawURL])
      }
      await model.load()
      #expect(model.groups.flatMap(\.rows).count == 2)
      #expect(model.selection == [missing.id])
    }
  }

  @Test("Every symbol Externals draws exists")
  func symbolsExist() {
    for name in ExternalsView.symbols {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  // MARK: - Found in the real app

  @Test("A loaded image takes the frame it is given — a wide one widens neither its tile nor the inspector's column")
  func wideImageClaimsNoWidth() throws {
    let context = try #require(
      CGContext(
        data: nil, width: 4000, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    for mode in [ContentMode.fill, .fit] {
      let host = NSHostingView(
        rootView: ExternalThumbnailView(state: .loaded(image), contentMode: mode).frame(height: 100))
      #expect(host.fittingSize.width < 100, "\(mode): \(host.fittingSize)")
    }
  }

  @Test("Externals' Grid zooms on the library's ladder — its columns, whatever the library's own mode — and its list has none")
  func gridZoomsWithTheLibrary() async throws {
    try await withFixture { database in
      let gallery = makeModel(database)
      await gallery.loadInitialData()
      gallery.currentProjectSlug = "blog"
      gallery.select(.externals, in: .reports)
      await gallery.reload()
      await until { gallery.externals.items?.count == 7 }
      gallery.viewMode = .table
      let rowHeight = gallery.tableRowHeight
      #expect(gallery.externals.viewMode == .grid)
      gallery.setGridColumns(4)
      #expect(gallery.canMakeBigger && gallery.canMakeSmaller)
      gallery.makeBigger()
      #expect(gallery.gridColumns == 3)
      gallery.makeSmaller()
      gallery.makeSmaller()
      #expect(gallery.gridColumns == 5)
      #expect(gallery.tableRowHeight == rowHeight)
      gallery.surfaceViewMode = .table
      #expect(!gallery.canMakeBigger && !gallery.canMakeSmaller)
      gallery.makeBigger()
      #expect(gallery.gridColumns == 5)
      #expect(gallery.tableRowHeight == rowHeight)

      // The grid lays out that many columns, and pins its domain headers.
      gallery.surfaceViewMode = .grid
      let view = ExternalsView(model: gallery.externals, columns: gallery.gridColumns)
      let grid = try #require(collectViews(view.body, as: ExternalsGrid.self).first)
      #expect(grid.columns == 5)
      #expect(ExternalsGrid.gridItems(columns: grid.columns).count == 5)
      #expect(collectViews(grid.body, as: PinnedScrollableViews.self) == [.sectionHeaders])
    }
  }

  // MARK: - Group headers and the thumbnail cache

  @Test("Each Grid group's header sits in its Section's header slot — the slot pinnedViews pins — and nowhere in its content or footer")
  func domainHeaderIsTheSectionHeader() async throws {
    try await withFixture { database in
      let gallery = makeModel(database)
      await gallery.loadInitialData()
      gallery.currentProjectSlug = "blog"
      gallery.select(.externals, in: .reports)
      await gallery.reload()
      await until { gallery.externals.items?.count == 7 }
      let externals = gallery.externals
      let view = ExternalsView(model: externals, columns: 4)
      let grid = try #require(collectViews(view.body, as: ExternalsGrid.self).first)
      // Your Domains: three prefixes (r2 current, b2 retired, b2 current).
      try #require(externals.groups.count > 1)
      for group in externals.groups {
        let section = grid.section(group)
        let slots = try sectionSlots(section)
        #expect(
          collectViews(slots.header, as: ExternalGroupHeader.self).map(\.group.id) == [group.id],
          "\(group.host): header slot")
        #expect(
          collectViews(slots.content, as: ExternalGroupHeader.self).isEmpty,
          "\(group.host): content slot")
        #expect(
          collectViews(slots.footer, as: ExternalGroupHeader.self).isEmpty,
          "\(group.host): footer slot")
      }
      #expect(ExternalsGrid.pinnedViews == [.sectionHeaders])
    }
  }

  @Test("A Your Domains thumbnail is cached under its own URL — three URLs loaded one after another keep three images, three fetches")
  func thumbnailKeyIsPerURL() async throws {
    try await withFixture { database in
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-externals-keys-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let asked = ExternalsFetchLog()
      let size: [String: (Int, Int)] = [
        "missing.png": (8, 8), "lost.png": (24, 8), "gone.png": (8, 24),
      ]
      let model = GalleryModel(
        catalog: ReadOnlyCatalog(database: database),
        thumbnails: ThumbnailCache(
          cacheDirectory: directory,
          fetcher: { url in
            asked.add(url)
            let (width, height) = size[url.lastPathComponent] ?? (1, 1)
            return pngData(width: width, height: height)
          }))
      let externals = model.externals
      await externals.selectProject("blog")
      let rows = externals.groups.flatMap(\.rows)
      try #require(rows.count == 3)
      // One at a time: a shared key would let the second find the first's
      // image already on disk and never ask its host.
      for row in rows {
        externals.loadThumbnail(row)
        await until { externals.thumbnail(row) != .loading }
      }
      #expect(asked.urls.count == 3)
      var shapes: [String: [Int]] = [:]
      for row in rows {
        guard case let .loaded(image, _) = externals.thumbnail(row) else {
          Issue.record("\(row.rawURL): \(String(describing: externals.thumbnail(row)))")
          continue
        }
        shapes[URL(string: row.rawURL)!.lastPathComponent] = [image.width, image.height]
      }
      #expect(shapes.count == 3)
      // Each keeps its own proportions (8:8, 24:8, 8:24), whatever the
      // thumbnail's scale.
      #expect(shapes["missing.png"].map { $0[0] == $0[1] } == true)
      #expect(shapes["lost.png"].map { $0[0] > $0[1] } == true)
      #expect(shapes["gone.png"].map { $0[0] < $0[1] } == true)
      // And the keys themselves differ per URL, and are stable for one.
      let keys = Set(rows.map { ExternalsModel.urlKey($0.rawURL) })
      #expect(keys.count == 3)
    }
  }

  @Test("A host's square takes its gruvbox hue from the host, stably, and shows its first letter past www.")
  func domainColourByHost() {
    let hosts = [
      "github.com", "i.imgur.com", "upload.wikimedia.org", "img.shields.io", "images.unsplash.com",
    ]
    // The one domain → hue map (`PinaxPalette.domainToken`): FNV-1a over
    // the lowercased host, so the same host is the same colour in every
    // instance and launch.
    #expect(hosts.map(PinaxPalette.domainToken) == [
      .yellow, .green, .blue, .orange, .red,
    ])
    #expect(PinaxPalette.domainToken("GitHub.com") == PinaxPalette.domainToken("github.com"))
    #expect(Set(hosts.map(PinaxPalette.domainToken)).count > 1)
    #expect(ExternalHostRow.hostParts("upload.wikimedia.org") == ("upload.", "wikimedia.org"))
    #expect(ExternalHostRow.hostParts("tva1.sinaimg.cn") == ("tva1.", "sinaimg.cn"))
    #expect(ExternalHostRow.hostParts("github.com") == ("", "github.com"))
    #expect(ExternalHostRow.avatarLetter("www.example.com") == "E")
    #expect(ExternalHostRow.avatarLetter("i.imgur.com") == "I")
  }

  @Test("The inspector's Used In is the library's, in its line shape")
  func inspectorUsedIn() async throws {
    try await withFixture { database in
      let gallery = makeModel(database)
      await gallery.loadInitialData()
      gallery.currentProjectSlug = "blog"
      gallery.select(.externals, in: .reports)
      await gallery.reload()
      await until { gallery.externals.items?.count == 7 }
      let url = "https://img.example.com/blog/missing.png"
      let state = gallery.externals.usedIn(url)
      #expect(
        state
          == .used(
            rows: [UsedInRow(project: "blog", path: "posts/a.md", line: 11)], total: 1,
            projects: ["blog"]))
      #expect(UsedInGroup(state: state, isMultiple: false) {}.showAllTitle == nil)
      #expect(gallery.externals.usedIn("https://nowhere.example/x.png") == .notUsed)
    }
  }

  // MARK: - Helpers

  /// The action `onCommand(#selector(NSText.copy(_:)))` holds.
  private func commandAction(in root: Any) -> (() -> Void)? {
    var stack: [Any] =
      collectViews(root, as: ExternalsList.self).map(\.body)
      + collectViews(root, as: ExternalsGrid.self).map(\.body)
    while let value = stack.popLast() {
      let name = String(reflecting: type(of: value))
      if !name.hasPrefix("SwiftUI.ModifiedContent"), name.contains("OnCommandModifier") {
        let children = Mirror(reflecting: value).children
        guard children.contains(where: { $0.label == "command" && "\($0.value)" == "copy:" }),
          let standard = children.first(where: { $0.label == "action" })?.value,
          let optional = Mirror(reflecting: standard).children.first(where: { $0.label == "action" })?.value
        else { return nil }
        return Mirror(reflecting: optional).children.first?.value as? () -> Void
      }
      if type(of: value) is AnyClass { continue }
      stack.append(contentsOf: Mirror(reflecting: value).children.map(\.value))
    }
    return nil
  }

  /// Whether `contextMenu(forSelectionType:primaryAction:)` holds a
  /// double-click action.
  private func hasPrimaryAction(_ root: Any) -> Bool {
    var stack: [Any] = [root]
    while let value = stack.popLast() {
      let name = String(reflecting: type(of: value))
      if !name.hasPrefix("SwiftUI.ModifiedContent"), name.contains("SelectionActionModifier") {
        return Mirror(reflecting: value).children.contains { child in
          child.label == "action" && Mirror(reflecting: child.value).children.count == 1
        }
      }
      if type(of: value) is AnyClass { continue }
      stack.append(contentsOf: Mirror(reflecting: value).children.map(\.value))
    }
    return false
  }

  /// A `Section` value's three slots, read off its own storage.
  private func sectionSlots(_ section: Any) throws -> (header: Any, content: Any, footer: Any) {
    let mirror = Mirror(reflecting: section)
    try #require(
      String(describing: Swift.type(of: section)).hasPrefix("Section<"),
      "not a Section: \(Swift.type(of: section))")
    func child(_ name: String) throws -> Any {
      try #require(mirror.children.first { $0.label == name }, "Section has no \(name): \(mirror.children.map(\.label))").value
    }
    return (try child("header"), try child("content"), try child("footer"))
  }

  private func urls(_ set: ExternalReferenceSet, _ domain: ExternalDomain) -> [String] {
    set.references.filter { $0.domain == domain }.map(\.rawURL)
  }

  private func shown(_ model: ExternalsModel) -> [String] {
    guard case let .results(rows) = model.presentation else { return [] }
    return rows.map(\.rawURL)
  }

  private func makeModel(_ database: DatabasePool) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-thumbs-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
  }

  private func until(seconds: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      pump(until: Date().addingTimeInterval(0.02))
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  nonisolated private func pump(until date: Date) { RunLoop.main.run(until: date) }

  private func spin(_ seconds: TimeInterval) async {
    await until(seconds: seconds) { false }
  }

  /// A mouse-up as AppKit would hand the tap: built, not posted.
  private func click(_ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.mouseEvent(
      with: .leftMouseUp, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
  }

  private func described(_ model: ExternalsModel) -> [String] {
    model.groups.map { group in
      "\(group.host) · \(group.note) · "
        + group.rows.map { URL(string: $0.rawURL)!.lastPathComponent }.joined(separator: " ")
    }
  }

  /// Two backends: r2 on img.example.com; b2 on cdn.example.net, retired
  /// from old.example.net. Unmatched references of the live scans:
  ///
  ///   blog   yours 3 (current r2, retired b2, current b2), other 4
  ///   notes  yours 1, other 2
  ///   shots  other 1
  ///
  /// plus a matched one (blog) and an unmatched one in blog's dead scan,
  /// neither listed.
  private func withFixture(_ body: (DatabasePool) async throws -> Void) async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedAsset(database, index: 0, uploadedAt: "2026-08-20T12:00:00Z")
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backend
            (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
             created_at, updated_at)
          VALUES
            (2, 'b2', 's3', 'https://s3.example.net', 'pics', 'auto',
             'https://cdn.example.net', 'backend.b2', '{}',
             '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO backend_prefix_history (backend_id, url_prefix, retired_at)
          VALUES (2, 'https://old.example.net', '2026-08-10T00:00:00Z');
          INSERT INTO project
            (id, slug, name, key_prefix, backend_id, last_scan_id, created_at, updated_at)
          VALUES
            (3, 'shots', 'Shots', 'shots', 1, NULL, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
          INSERT INTO scan (id, project_id, started_at, finished_at) VALUES
            (1, 1, '2026-08-19T00:00:00Z', '2026-08-19T00:00:00Z'),
            (2, 1, '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z'),
            (3, 2, '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z'),
            (4, 3, '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z');
          UPDATE project SET last_scan_id = 2 WHERE slug = 'blog';
          UPDATE project SET last_scan_id = 3 WHERE slug = 'notes';
          UPDATE project SET last_scan_id = 4 WHERE slug = 'shots';
          """)
      let references: [(String, String?, String, String, Int)] = [
        ("blog", nil, "https://img.example.com/blog/missing.png", "posts/a.md#L11", 2),
        ("blog", nil, "https://old.example.net/blog/lost.png", "posts/a.md#L4", 2),
        ("blog", nil, "https://cdn.example.net/blog/gone.png", "posts/b.md#L2", 2),
        ("blog", nil, "https://elsewhere.example.org/x.png", "posts/a.md#L7", 2),
        ("blog", nil, "https://third.example.com/z.gif", "posts/a.md#L9", 2),
        ("blog", nil, "https://elsewhere.example.org/w.png", "posts/b.md#L5", 2),
        ("blog", nil, "https://elsewhere.example.org/y.png", "posts/c.md#L1", 2),
        ("blog", "blog/asset-0.png", "https://img.example.com/blog/asset-0.png", "posts/a.md#L1", 2),
        ("blog", nil, "https://img.example.com/blog/dead.png", "posts/a.md#L2", 1),
        ("notes", nil, "https://elsewhere.example.org/n.png", "notes/n.md#L3", 3),
        ("notes", nil, "https://elsewhere.example.org/m.png", "notes/n.md#L5", 3),
        ("notes", nil, "https://img.example.com/notes/missing.png", "notes/o.md#L1", 3),
        ("shots", nil, "https://elsewhere.example.org/s.png", "s.md#L1", 4),
      ]
      for (slug, key, url, source, scan) in references {
        try db.execute(
          sql: """
            INSERT INTO usage
              (project_id, asset_id, raw_url, source_ref, kind, first_seen, last_seen, last_scan_id)
            SELECT p.id, (SELECT id FROM asset WHERE key = ?), ?, ?, 'markdown',
              '2026-08-21T00:00:00Z', '2026-08-21T00:00:00Z', ?
            FROM project p WHERE p.slug = ?
            """,
          arguments: [key, url, source, scan, slug])
      }
    }
    try await body(database)
  }
}

/// The URLs a fetcher was asked for, from whatever task asked.
final class ExternalsFetchLog: @unchecked Sendable {
  private let lock = NSLock()
  private var asked: [URL] = []
  func add(_ url: URL) { lock.withLock { asked.append(url) } }
  var urls: [URL] { lock.withLock { asked } }
}
