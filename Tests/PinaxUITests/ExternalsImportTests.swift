import Combine
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

/// Externals ▸ Your Domains ▸ Import into Catalog.
/// The claim is the CLI's real core on a temporary catalog with a fake fetcher;
/// every host is `.invalid`, so nothing here reaches a bucket or a CDN. No
/// menu, sheet or window is opened: the menu, the sheet and the marks are
/// read as the model's values.
@MainActor
@Suite struct ExternalsImportTests {
  static let prefix = "https://img.pinax.invalid"
  static let host = "img.pinax.invalid"

  // MARK: - Entry points

  @Test("Import into Catalog leads the menu on Your Domains only, once per URL; none without a claimer")
  func menuItem() async throws {
    try await withImportCatalog { database, fetcher in
      try sync(
        database, "blog",
        ["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png",
         "https://elsewhere.invalid/x.png"])
      let model = makeModel(database, fetcher: fetcher).externals
      await model.selectProject("blog")
      #expect(model.domain == .yours)
      let ids = Set(model.groups.flatMap(\.rows).map(\.id))
      #expect(ids.count == 3)
      let items = model.menuItems(for: ids)
      // Several rows lead with their "N Images" title; Import follows it.
      #expect(items.first == .title(2))
      #expect(items.dropFirst().first == .importIntoCatalog(["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png"]))
      #expect(items.dropFirst().first?.title == "Import into Catalog")
      #expect(items.map(\.id) == ["title", "importIntoCatalog", "copyURL", "openURL"])

      model.domain = .other
      let other = Set(model.groups.flatMap(\.rows).map(\.id))
      // An Other Domains row not yet loaded offers Load Preview.
      #expect(model.menuItems(for: other).map(\.id) == ["loadPreviews", "copyURL", "openURL"])

      // A read-only gallery has no claimer, and no import.
      let readOnly = ExternalsModel(reader: ReadOnlyCatalog(database: database))
      await readOnly.selectProject("blog")
      #expect(!readOnly.menuItems(for: ids).contains { $0.id == "importIntoCatalog" })
      #expect(!readOnly.showsImportAll)
    }
  }

  @Test("Import All… shows on Your Domains only, counts distinct URLs, and is greyed at 0")
  func importAllAvailability() async throws {
    try await withImportCatalog { database, fetcher in
      try sync(
        database, "blog",
        ["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png"])
      try sync(database, "notes", ["https://elsewhere.invalid/x.png"])
      let model = makeModel(database, fetcher: fetcher).externals
      await model.selectProject("blog")
      #expect(model.showsImportAll)
      #expect(model.isImportAllEnabled)
      #expect(model.importAllCount == 2)
      model.domain = .other
      #expect(!model.showsImportAll)

      await model.selectProject("notes")
      #expect(model.count(.yours) == 0)
      model.domain = .yours
      #expect(model.showsImportAll)
      #expect(model.importAllCount == 0)
      #expect(!model.isImportAllEnabled)
    }
  }

  // MARK: - The sheet

  @Test("The sheet's words — title, host, count, downloads, project, the no-sample line — from one pure function")
  func confirmationWords() {
    func row(_ project: String, _ url: String) -> ExternalReference {
      ExternalReference(
        projectSlug: project, sourceReference: "p.md#L1", rawURL: url, kind: "markdown",
        domain: .yours, match: ExternalDomainMatch(backendSlug: "r2", prefix: Self.prefix, isCurrent: true))
    }
    let a = "\(Self.prefix)/2020/a.png"
    let b = "\(Self.prefix)/2020/b.png"
    let c = "\(Self.prefix)/2020/c.png"
    let preparation = ExternalImportPreparation(
      fetchURLs: [a: a, b: b, c: c], projectNames: ["blog": "Blog", "notes": "Notes"])

    let three = ExternalImportConfirmation.make(
      rows: [row("blog", a), row("blog", b), row("blog", c), row("blog", a)], importAll: true,
      preparation: preparation)
    #expect(three.title == "Import 3 Images into the Catalog?")
    #expect(
      three.subtitle
        == "From img.pinax.invalid. Pinax downloads each image once to fingerprint it, then adds it to the catalog at the address it already has.")
    #expect(three.lines.map { "\($0.label)=\($0.value)" } == [
      "Images=3", "Downloads=about 3 downloads", "Project=Blog",
    ])
    #expect(three.finePrint == "Objects stay where they are; nothing is uploaded or deleted.")
    #expect(three.cdnWarning == nil)
    #expect(three.urls == nil)
    #expect(three.checkingText == "Checking that img.pinax.invalid serves the original bytes…")

    let selection = ExternalImportConfirmation.make(
      rows: [row("blog", a), row("notes", b)], importAll: false, preparation: preparation)
    #expect(selection.title == "Import 2 Images into the Catalog?")
    #expect(selection.lines.last?.value == "the projects that use them")
    #expect(selection.urls == [a, b])

    var unchecked = preparation
    unchecked.uncheckableBackends = ["r2"]
    let warned = ExternalImportConfirmation.make(
      rows: [row("blog", a)], importAll: true, preparation: unchecked)
    #expect(warned.title == "Import 1 Image into the Catalog?")
    #expect(warned.lines[1].value == "about 1 download")
    #expect(
      warned.cdnWarning
        == "Pinax can’t check whether the CDN changes bytes on this domain: none of your catalog’s images were uploaded by Pinax yet.")
  }

  @Test("A catalog with no image Pinax uploaded gets the no-sample line; one with a sample does not")
  func uncheckableFromCatalog() async throws {
    try await withImportCatalog { database, fetcher in
      try sync(database, "blog", ["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png"])
      let model = makeModel(database, fetcher: fetcher).externals
      await model.selectProject("blog")
      await model.requestImportAll()
      guard case let .confirm(bare, checking: false)? = model.importSheet else {
        Issue.record("no sheet: \(String(describing: model.importSheet))")
        return
      }
      #expect(bare.cdnWarning != nil)
      #expect(bare.lines.last?.value == "Blog")
      model.cancelImportSheet()
      #expect(model.importSheet == nil)

      try await seedSample(database, fetcher: fetcher)
      await model.requestImportAll()
      guard case let .confirm(sampled, checking: false)? = model.importSheet else {
        Issue.record("no sheet")
        return
      }
      #expect(sampled.cdnWarning == nil)
    }
  }

  @Test("One image — or several rows of one URL — imports at once, with no sheet")
  func singleImportSkipsSheet() async throws {
    try await withImportCatalog { database, fetcher in
      let a = "\(Self.prefix)/2020/a.png"
      try sync(database, "blog", [a, a, "\(Self.prefix)/2020/b.png"])
      let model = makeModel(database, fetcher: fetcher).externals
      await model.selectProject("blog")
      let ids = Set(model.groups.flatMap(\.rows).filter { $0.rawURL == a }.map(\.id))
      #expect(ids.count == 2)
      var sheets: [ExternalImportSheet?] = []
      let watch = model.$importSheet.sink { sheets.append($0) }
      defer { watch.cancel() }
      // Two rows lead with their title; the import item follows it.
      guard let item = model.menuItems(for: ids).first(where: { $0.id == "importIntoCatalog" }),
        case let .importIntoCatalog(urls) = item
      else {
        Issue.record("no import item")
        return
      }
      #expect(urls == [a])
      await model.requestImport(urls: urls)
      #expect(sheets.allSatisfy { $0 == nil })
      #expect(try assetKeys(database) == ["2020/a.png"])
      #expect(model.items?.map(\.rawURL) == ["\(Self.prefix)/2020/b.png"])
      #expect(model.importSummary?.title == "Imported 1")
    }
  }

  // MARK: - The batch

  @Test("Checking in the sheet, then a spinner per GET, ✓ when done; rows hold still until the batch ends, then leave in one step")
  func batchStateSequence() async throws {
    try await withImportCatalog { database, fetcher in
      let urls = ["a", "b", "c"].map { "\(Self.prefix)/2020/\($0).png" }
      try sync(database, "blog", urls)
      try await seedSample(database, fetcher: fetcher)
      fetcher.gated = true
      let model = makeModel(database, fetcher: fetcher, concurrency: 1).externals
      await model.selectProject("blog")
      let before = model.items
      var reloads = 0
      var log: [String] = []
      let watch = model.$referenceSet.dropFirst().sink { _ in
        reloads += 1
        log.append("rows")
      }
      let marks = model.$importCellStates.dropFirst().sink { log.append("marks \($0.count)") }
      defer {
        watch.cancel()
        marks.cancel()
      }

      await model.requestImportAll()
      let run = Task { await model.confirmImport() }

      // The CDN byte check's sample first: the sheet checks, no cell is marked.
      await until { fetcher.waiting.contains(Self.sampleURL) }
      guard case .confirm(_, checking: true)? = model.importSheet else {
        Issue.record("not checking: \(String(describing: model.importSheet))")
        return
      }
      #expect(model.importCellStates.isEmpty)
      #expect(model.importActivity == nil)
      #expect(!model.isImportAllEnabled)
      fetcher.release(Self.sampleURL)

      var done: [String] = []
      for step in 0..<3 {
        await until { fetcher.waiting.contains { urls.contains($0) } }
        let current = try #require(fetcher.waiting.first { urls.contains($0) })
        // The model hears of the GET, and of the one before it, on the main actor.
        let text = "Importing from img.pinax.invalid… \(step) of 3"
        await until {
          model.importCellStates[current] == .importing && model.importActivity?.text == text
        }
        #expect(model.importSheet == nil)
        #expect(model.importCellStates[current] == .importing)
        for url in done { #expect(model.importCellStates[url] == .imported) }
        #expect(
          model.importActivity?.text
            == "Importing from img.pinax.invalid… \(step) of 3")
        // The gallery reloads the surface meanwhile: nothing moves.
        if step == 1 { await model.load() }
        #expect(model.items == before)
        #expect(reloads == 0)
        fetcher.release(current)
        // The last one's ✓ lasts only until the batch's end.
        if step < 2 { await until { model.importCellStates[current] == .imported } }
        done.append(current)
      }
      await run.value
      #expect(reloads == 1)
      // One step: the rows go, then the marks clear in the same turn.
      #expect(log.suffix(2) == ["rows", "marks 0"])
      #expect(model.items?.isEmpty == true)
      #expect(model.importCellStates.isEmpty)
      #expect(model.importActivity == nil)
      #expect(!model.isImporting)
      #expect(model.importSummary?.title == "Imported 3")
      #expect(
        model.importSummary?.detail
          == "Find them in Usage. Reindex can’t rebuild imported images from the bucket; catalog backups keep them.")
      #expect(model.importSummary?.offersUsage == true)
    }
  }

  @Test("A GET that fails mid-batch leaves its cell unmarked — no ✓ — until the batch ends")
  func failedGetIsNotMarkedImported() async throws {
    try await withImportCatalog { database, fetcher in
      let urls = ["a", "b", "c"].map { "\(Self.prefix)/2020/\($0).png" }
      try sync(database, "blog", urls)
      fetcher.gated = true
      let model = makeModel(database, fetcher: fetcher, concurrency: 1).externals
      await model.selectProject("blog")
      await model.requestImportAll()
      let run = Task { await model.confirmImport() }

      await until { fetcher.waiting.contains { urls.contains($0) } }
      let failed = try #require(fetcher.waiting.first { urls.contains($0) })
      await until { model.importCellStates[failed] == .importing }
      fetcher.release(failed, failing: true)
      // The next GET's spinner lands after the failed one's end, on one stream.
      await until { fetcher.waiting.contains { urls.contains($0) && $0 != failed } }
      let next = try #require(fetcher.waiting.first { urls.contains($0) && $0 != failed })
      await until { model.importCellStates[next] == .importing }
      #expect(model.isImporting)
      #expect(model.importCellStates[failed] == nil)

      fetcher.release(next)
      await until { fetcher.waiting.contains { urls.contains($0) && $0 != failed && $0 != next } }
      let last = try #require(fetcher.waiting.first { urls.contains($0) && $0 != failed && $0 != next })
      await until { model.importCellStates[last] == .importing }
      #expect(model.importCellStates[next] == .imported)
      #expect(model.importCellStates[failed] == nil)
      fetcher.release(last)
      await run.value
      // The batch's end: the failed row stays with its reason.
      #expect(model.items?.map(\.rawURL) == [failed])
      #expect(model.importFailure(try #require(model.items?.first)) != nil)
    }
  }

  @Test("A stop keeps what was imported; the rest stay, and Import All asks for exactly them")
  func cancelThenResume() async throws {
    try await withImportCatalog { database, fetcher in
      let urls = ["a", "b", "c", "d"].map { "\(Self.prefix)/2020/\($0).png" }
      try sync(database, "blog", urls)
      fetcher.gated = true
      let model = makeModel(database, fetcher: fetcher, concurrency: 1).externals
      await model.selectProject("blog")
      await model.requestImportAll()
      let run = Task { await model.confirmImport() }
      var imported: [String] = []
      for _ in 0..<2 {
        await until { fetcher.waiting.contains { urls.contains($0) } }
        let current = try #require(fetcher.waiting.first)
        fetcher.release(current)
        await until { model.importCellStates[current] == .imported }
        imported.append(current)
      }
      // The third GET is in flight when Stop lands; the cancel tears it down.
      await until { !fetcher.waiting.isEmpty }
      let torn = try #require(fetcher.waiting.first)
      model.stopImport()
      #expect(model.importActivity?.isStopping == true)
      fetcher.release(torn, failing: true)
      await run.value

      #expect(try assetKeys(database).count == 2)
      #expect(model.importSummary?.title == "Imported 2 of 4 · Cancelled")
      #expect(
        model.importSummary?.detail
          == "The other 2 are still here. Import All picks up where it stopped.")
      #expect(model.importSummary?.offersUsage == false)
      #expect(Set(model.items?.map(\.rawURL) ?? []) == Set(urls).subtracting(imported))
      #expect(model.importFailures.isEmpty)
      #expect(model.importAllCount == 2)
      await model.requestImportAll()
      guard case let .confirm(again, checking: false)? = model.importSheet else {
        Issue.record("no sheet")
        return
      }
      #expect(again.title == "Import 2 Images into the Catalog?")
      fetcher.gated = false
      await model.confirmImport()
      #expect(model.items?.isEmpty == true)
      #expect(try assetKeys(database).count == 4)
    }
  }

  // MARK: - CDN byte-check refusal

  @Test("A CDN that rewrites bytes refuses the batch — nothing written, Nothing Was Imported")
  func cdnRefusal() async throws {
    try await withImportCatalog { database, fetcher in
      try sync(database, "blog", ["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png"])
      try await seedSample(database, fetcher: fetcher)
      fetcher.serve(Self.sampleURL, Data("polished".utf8))
      let model = makeModel(database, fetcher: fetcher).externals
      await model.selectProject("blog")
      let before = try counts(database)
      let rows = model.items
      await model.requestImportAll()
      await model.confirmImport()
      guard case let .refused(refusal)? = model.importSheet else {
        Issue.record("not refused: \(String(describing: model.importSheet))")
        return
      }
      #expect(refusal.title == "Nothing Was Imported")
      #expect(
        refusal.subtitle
          == "The CDN for img.pinax.invalid changed the bytes of images Pinax uploaded, so it can’t fingerprint the images on this domain. Nothing was imported.")
      #expect(refusal.lines.map { "\($0.label)=\($0.value)" } == [
        "Images checked=1", "Changed by the CDN=1",
      ])
      #expect(
        refusal.advice
          == "This usually means image optimization (such as Cloudflare Polish) is on for this domain. Turn it off, then import again.")
      #expect(try counts(database) == before)
      #expect(model.items == rows)
      #expect(model.importSummary == nil)
      #expect(!fetcher.requested.contains { $0.hasSuffix("/a.png") || $0.hasSuffix("/b.png") })
      model.cancelImportSheet()
      #expect(model.importSheet == nil)
    }
  }

  // MARK: - Failures

  @Test("Each skip maps to its category, badge, words and the inspector's explanation", arguments: [
    (ExternalsClaimSkipReason.notFound, nil as String?, nil as String?, "notFound", "rectangle.slash",
     "Not found", "Not found in the bucket", "Not found", "On your domain, not in the bucket",
     "The bucket has no object at this key. If the file name has a space, write the link as ![](<…>) so the whole name is kept."),
    (ExternalsClaimSkipReason.sameContent, "blog/2026/known.png", nil, "sameImage", "square.on.square",
     "Same image as blog/2026/known.png", "Same image as blog/2026/known.png", "Skipped",
     "Same image is already in the catalog",
     "Same image as blog/2026/known.png, which is already in the catalog. Pinax keeps one record per image."),
    (ExternalsClaimSkipReason.otherBackend, nil, nil, "otherBackend", "externaldrive",
     "On another backend (r2)", "On another backend (r2)", "Skipped", "On another backend’s domain",
     "The link is on r2’s domain, but its project uses another backend. Pinax imports an image only into a project on the backend that serves it."),
    (ExternalsClaimSkipReason.badKey, nil, "cdn-cgi/image/w=80/a.png", "skipped", "xmark",
     "Skipped: Cloudflare path", "Skipped: Cloudflare path", "Skipped", "On your domain, not in the catalog",
     "The link is a Cloudflare image transform, not an object’s address. Link the original image to import it."),
    (ExternalsClaimSkipReason.badKey, nil, "/a.png", "skipped", "xmark",
     "Skipped: not an object key", "Skipped: not an object key", "Skipped", "On your domain, not in the catalog",
     "The link’s path starts with a slash or is empty, so it names no object Pinax could import."),
    (ExternalsClaimSkipReason.pendingDeletion, nil, "a.png", "skipped", "xmark",
     "Skipped: being deleted", "Skipped: being deleted", "Skipped", "On your domain, not in the catalog",
     "An image at this key is being deleted permanently. Finish or undo that in Archived first."),
    (ExternalsClaimSkipReason.forbidden, nil, "a.png", "skipped", "xmark",
     "Skipped: access denied", "Skipped: access denied", "Skipped", "On your domain, not in the catalog",
     "The host refused the download (403). Make the object public, then import again."),
    (ExternalsClaimSkipReason.fetchFailed, nil, "a.png", "skipped", "xmark",
     "Skipped: download failed", "Skipped: download failed", "Skipped", "On your domain, not in the catalog",
     "The download failed: timed out. Import again to retry."),
    (ExternalsClaimSkipReason.lengthMismatch, nil, "a.png", "skipped", "xmark",
     "Skipped: download incomplete", "Skipped: download incomplete", "Skipped", "On your domain, not in the catalog",
     "The download was shorter than the host said. Import again to retry."),
  ])
  func failureMapping(
    _ reason: String, _ existing: String?, _ key: String?, _ category: String, _ symbol: String,
    _ label: String, _ caption: String, _ status: String, _ subtitle: String, _ explanation: String
  ) {
    let row = ExternalReference(
      projectSlug: "blog", sourceReference: "p.md#L1", rawURL: "\(Self.prefix)/a.png", kind: "markdown",
      domain: .yours, match: ExternalDomainMatch(backendSlug: "r2", prefix: Self.prefix, isCurrent: true))
    let skip = ExternalsClaimSkip(
      reason: reason, url: row.rawURL, key: key,
      detail: reason == ExternalsClaimSkipReason.fetchFailed ? "timed out" : nil, existingKey: existing)
    let failure = ExternalImportFailure.make(skip, row: row)
    #expect(failure.category.rawValue == category)
    #expect(failure.symbol == symbol)
    #expect(failure.label == label)
    #expect(failure.caption == caption)
    #expect(failure.inspectorStatus == status)
    #expect(failure.inspectorSubtitle == subtitle)
    #expect(ExternalInspector.subtitle(row, failure: failure) == subtitle)
    #expect(failure.explanation == explanation)
  }

  @Test("Failed rows stay with their reason; the bar counts each category")
  func failuresStayAndSummarise() async throws {
    try await withImportCatalog { database, fetcher in
      let gone = "\(Self.prefix)/2020/gone.png"
      let same = "\(Self.prefix)/2020/same.png"
      let cdnCGI = "\(Self.prefix)/cdn-cgi/image/width=80/2020/a.png"
      try sync(database, "blog", ["\(Self.prefix)/2020/a.png", gone, same, cdnCGI])
      let known = try await seedSample(database, fetcher: fetcher)
      fetcher.serve("\(Self.prefix)/2020/same.png", Self.sampleBytes)
      fetcher.notFound(gone)
      let gallery = makeModel(database, fetcher: fetcher)
      let model = gallery.externals
      await model.selectProject("blog")
      await model.requestImportAll()
      await model.confirmImport()
      #expect(Set(model.items?.map(\.rawURL) ?? []) == [gone, same, cdnCGI])
      let rows = Dictionary(uniqueKeysWithValues: (model.items ?? []).map { ($0.rawURL, $0) })
      #expect(model.importFailure(try #require(rows[gone])) == .notFound)
      #expect(model.importFailure(try #require(rows[same])) == .sameImage(existingKey: known))
      #expect(model.importFailure(try #require(rows[cdnCGI])) == .skipped(.cloudflarePath))
      #expect(
        model.importSummary?.title == "Imported 1 · 1 not found · 1 same image · 1 skipped")
      #expect(ExternalsView.badgeColor(.notFound) == .init(nsColor: .systemRed))
      // A same image's inspector: Show in Library selects the one already there.
      await model.showInLibrary(key: known)
      #expect(gallery.sidebarSelection == .all)
      let knownID = try await ReadOnlyCatalog(database: database).details(known).item.asset.id
      #expect(gallery.selectedIDs == Set([knownID].compactMap { $0 }))

      // Another backend's domain, in the bar's own words.
      let summary = ExternalImportSummary.make(
        imported: 180,
        requested: 189,
        failures: Array(repeating: .notFound, count: 4)
          + [.sameImage(existingKey: "k"), .sameImage(existingKey: "k")]
          + [.otherBackend("r2-old"), .otherBackend("r2-old"), .skipped(.cloudflarePath)],
        cancelled: false)
      #expect(
        summary.title
          == "Imported 180 · 4 not found · 2 same image · 2 other backend · 1 skipped")
    }
  }

  // MARK: - Afterwards

  @Test("Imported images are in Usage's data at once — no Scan Now — and Show in Usage opens it")
  func visibleInUsage() async throws {
    try await withImportCatalog { database, fetcher in
      try sync(database, "blog", ["\(Self.prefix)/2020/a.png", "\(Self.prefix)/2020/b.png?w=400"])
      let gallery = makeModel(database, fetcher: fetcher)
      await gallery.externals.selectProject("blog")
      let scansBefore = try counts(database)[2]
      await gallery.externals.requestImportAll()
      await gallery.externals.confirmImport()
      let report = try await ReadOnlyCatalog(database: database).usageReport(project: "blog")
      #expect(report.items.compactMap(\.key).sorted() == ["2020/a.png", "2020/b.png"])
      #expect(try counts(database)[2] == scansBefore)
      let id = try #require(
        try await ReadOnlyCatalog(database: database).details("2020/a.png").item.asset.id)
      let live = try await ReadOnlyCatalog(database: database).liveUsage(assetID: id)
      #expect(!live.references.isEmpty)

      gallery.externals.showImportedInUsage()
      #expect(gallery.sidebarSelection == .usage)
      #expect(gallery.usagePage == .images)
    }
  }

  @Test("The app hands the gallery its claimer; Import is offered in the real shell")
  func appWiresClaimer() async throws {
    try await withImportCatalog { database, _ in
      let defaults = try #require(UserDefaults(suiteName: "pinaxui-t31-\(UUID().uuidString)"))
      let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
      await app.start()
      let gallery = try #require(app.gallery)
      #expect(gallery.externals.canImport)
      #expect(gallery.externals.claimer is CatalogExternalsClaimer)
    }
  }

  // MARK: - Fixture

  static let sampleURL = "\(prefix)/blog/2026/known.png"
  static let sampleBytes = Data("known image bytes".utf8)

  /// A Pinax upload (no `imported_from`): the CDN byte check's sample,
  /// served truly.
  @discardableResult
  private func seedSample(_ database: DatabasePool, fetcher: ImportFetcher) async throws -> String {
    try await database.write { db in
      _ = try Asset(
        sha256: Hashing.sha256(of: Self.sampleBytes), backendID: 1, key: "blog/2026/known.png",
        byteSize: Int64(Self.sampleBytes.count), mime: "image/png", meta: "{}",
        uploadedAt: "2026-01-01T00:00:00Z", createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z"
      ).insertAndFetch(db)
    }
    fetcher.serve(Self.sampleURL, Self.sampleBytes)
    return "blog/2026/known.png"
  }

  private func sync(_ database: DatabasePool, _ project: String, _ urls: [String]) throws {
    _ = try CatalogUsage.sync(
      UsageDocument(
        project: project,
        refs: urls.enumerated().map {
          UsageReference(rawURL: $0.element, sourceReference: "posts/\(project).md#L\($0.offset + 1)")
        }),
      project: project, in: database)
  }

  private func assetKeys(_ database: DatabasePool) throws -> [String] {
    try database.read { db in
      try String.fetchAll(
        db, sql: "SELECT key FROM asset WHERE meta LIKE '%imported_from%' ORDER BY key")
    }
  }

  /// asset, asset_project, scan, linked usage rows.
  private func counts(_ database: DatabasePool) throws -> [Int] {
    try database.read { db in
      try [
        "SELECT COUNT(*) FROM asset", "SELECT COUNT(*) FROM asset_project",
        "SELECT COUNT(*) FROM scan", "SELECT COUNT(asset_id) FROM usage",
      ].map { try Int.fetchOne(db, sql: $0) ?? 0 }
    }
  }

  private func makeModel(
    _ database: DatabasePool, fetcher: ImportFetcher, concurrency: Int = 8
  ) -> GalleryModel {
    GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("pinaxui-thumbs-\(UUID().uuidString)"),
        fetcher: { _ in throw URLError(.unsupportedURL) }),
      externalsClaimer: CatalogExternalsClaimer(
        database: database, fetcher: fetcher, maxConcurrentFetches: concurrency))
  }

  private func until(seconds: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private func withImportCatalog(
    _ body: (DatabasePool, ImportFetcher) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-t31-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
    try Database.migrate(database)
    _ = try CatalogConfiguration.addBackend(
      slug: "r2", endpoint: "https://s3.pinax.invalid", bucket: "images", region: "auto",
      urlPrefix: Self.prefix, keychainReference: "", to: database)
    _ = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "blog", backendSlug: "r2", to: database)
    _ = try CatalogConfiguration.addProject(
      slug: "notes", name: "Notes", keyPrefix: "notes", backendSlug: "r2", to: database)
    try await body(database, ImportFetcher())
  }
}

/// Serves distinct bytes per URL unless told otherwise; with `gated` on,
/// each GET waits until the test releases it. No network.
final class ImportFetcher: PublicObjectFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var bodies: [String: Data] = [:]
  private var missing: Set<String> = []
  private var requests: [String] = []
  private var parked: [String: CheckedContinuation<Bool, Never>] = [:]
  private var _gated = false

  var gated: Bool {
    get { lock.withLock { _gated } }
    set { lock.withLock { _gated = newValue } }
  }

  var requested: [String] { lock.withLock { requests } }
  /// GETs waiting for `release`, in no particular order.
  var waiting: [String] { lock.withLock { Array(parked.keys).sorted() } }

  func serve(_ url: String, _ data: Data) { lock.withLock { bodies[url] = data } }
  func notFound(_ url: String) { _ = lock.withLock { missing.insert(url) } }

  func release(_ url: String, failing: Bool = false) {
    let continuation = lock.withLock { parked.removeValue(forKey: url) }
    continuation?.resume(returning: !failing)
  }

  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    let object = try await fetchObject(url)
    return (object.data, object.mime, object.contentLength)
  }

  func fetchObject(_ url: URL) async throws -> PublicObject {
    let key = url.absoluteString
    let (gate, body, isMissing) = lock.withLock {
      requests.append(key)
      return (_gated, bodies[key], missing.contains(key))
    }
    if gate {
      let proceed = await withCheckedContinuation { continuation in
        lock.withLock { parked[key] = continuation }
      }
      if !proceed { throw PublicObjectFetchError.failed(url, detail: "cancelled") }
    }
    if isMissing { throw PublicObjectFetchError.notFound(url) }
    let data = body ?? Data("bytes of \(key)".utf8)
    return PublicObject(data: data, mime: "image/png", contentLength: Int64(data.count), lastModified: nil)
  }
}
