import AppKit
import Combine
import CatalogCore
import CryptoKit

public protocol ExternalUsageReading: Sendable {
  func externalReferences(project: String?) async throws -> ExternalReferenceSet
}

public enum ExternalsPresentation: Equatable, Sendable {
  case loading
  case error(String)
  /// No unmatched reference in either half.
  case empty
  /// The shown half's rows; empty when only the other half has any.
  case results([ExternalReference])
}

@MainActor
public final class ExternalsModel: ObservableObject {
  @Published public private(set) var referenceSet: ExternalReferenceSet?
  /// The report's scope: the app's current project,
  /// set by the gallery; nil = All Projects.
  @Published public var selectedProjectSlug: String? {
    didSet { if oldValue != selectedProjectSlug { selection = [] } }
  }
  /// The half shown: Your Domains, unless it is empty.
  @Published public var domain: ExternalDomain = .yours {
    didSet { if oldValue != domain { selection = [] } }
  }
  /// Each half's view, Grid or the grouped list (the
  /// toolbar's Table segment); in memory, like the library's own.
  @Published public private(set) var viewModes: [ExternalDomain: GalleryModel.ViewMode] = [
    .yours: .grid, .other: .table,
  ]
  /// Your Domains' remote thumbnails by URL, as values — loading,
  /// the image, or why there is none. Other Domains never gets an entry.
  @Published public private(set) var thumbnailStates: [String: ExternalThumbnail] = [:]
  /// The grouped list's open groups per half; nil until the user opens or
  /// closes one, when only the first is open.
  @Published var expandedGroups: [ExternalDomain: Set<String>] = [:]
  /// The table's selection, emptied when the half or the scope
  /// changes.
  @Published public var selection: Set<ExternalReference.ID> = []
  /// The page's order — Used In by default — and its
  /// Group by File switch; the shell remembers both (`PreferencesStore`).
  @Published public var sort: ExternalSort {
    didSet { if oldValue != sort { onSortChange?(sort) } }
  }
  @Published public var groupsByFile: Bool {
    didSet {
      guard oldValue != groupsByFile else { return }
      expandedGroups = [:]
      onGroupsByFileChange?(groupsByFile)
    }
  }
  /// The first-visit card, closed once for the whole app.
  @Published public private(set) var isTipDismissed: Bool
  var onSortChange: ((ExternalSort) -> Void)?
  var onGroupsByFileChange: ((Bool) -> Void)?
  var onTipDismissed: (() -> Void)?
  /// Open File, Open URL and double-click; Reveal in Finder. Tests record
  /// them instead.
  var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
  var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
  /// Copy URL and ⌘C write here; tests pass a named pasteboard.
  var pasteboard: NSPasteboard = .general
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: String?

  // MARK: Import into Catalog

  /// The sheet: the confirmation (Import All, a selection), or the CDN check's refusal.
  @Published public internal(set) var importSheet: ExternalImportSheet?
  /// The status bar's import while a batch runs.
  @Published public internal(set) var importActivity: ExternalImportActivity?
  /// Cells marked by the batch in flight, by raw URL.
  @Published public internal(set) var importCellStates: [String: ExternalImportCellState] = [:]
  /// Why a row stayed after an import, by raw URL.
  @Published public internal(set) var importFailures: [String: ExternalImportFailure] = [:]
  /// The closable result bar under the header.
  @Published public internal(set) var importSummary: ExternalImportSummary?
  /// A run that failed outright (the catalog, not a URL), for the status bar.
  @Published public internal(set) var importError: String?
  /// True from Import until the batch's rows have left.
  @Published public internal(set) var isImporting = false
  var importCancellation: ExternalsClaimCancellation?
  /// The run in flight; late GET events from an earlier run are dropped.
  var importRun = 0
  var reloadAfterImport = false
  /// The confirmation's rows and facts, between the sheet and Import.
  var importPending: (rows: [ExternalReference], preparation: ExternalImportPreparation)?
  /// Show in Usage and Show in Library, and the gallery's refresh after a
  /// batch: the gallery sets them (`GalleryModel.init`).
  var onShowInUsage: () -> Void = {}
  var onShowInLibrary: (String) async -> Void = { _ in }
  var onImportFinished: () async -> Void = {}

  // MARK: Bulk previews

  /// The status bar's preview batch: running, or the last one's result
  /// until the next.
  @Published public internal(set) var previewActivity: ExternalPreviewActivity?
  /// Rows waiting for one of the batch's slots, a URL each.
  var previewQueue: [ExternalReference] = []
  var previewInFlight = 0

  // MARK: Migrate to Bucket

  /// The activity slot's migration: preparing, ready, uploading,
  /// rewriting, or the last result until the next.
  @Published public internal(set) var migrationStatus: ExternalMigrationStatus?
  /// The preparation not yet applied; the sheet reads it.
  @Published public internal(set) var migrationConfirmation: ExternalMigrationConfirmation?
  @Published public internal(set) var isMigrationSheetPresented = false
  /// `project/label` of the unclean sources ticked Write anyway; none at
  /// first.
  @Published public internal(set) var migrationAllowedSources: Set<String> = []
  /// Why the last Migrate was refused, shown in the sheet.
  @Published public internal(set) var migrationRefusal: ExternalMigrationRefusal?
  /// Show Changes…'s text; non-nil shows the nested sheet.
  @Published public internal(set) var migrationDiff: String?
  /// Why a row stayed after a migration, by raw URL.
  @Published public internal(set) var migrationFailures: [String: ExternalMigrationFailure] = [:]
  /// True from an entry until the preparation, or the apply, returns.
  @Published public internal(set) var isMigrating = false {
    // The one lock the domain move shares.
    didSet {
      if isMigrating { migrationLock.take(.externals) } else { migrationLock.release(.externals) }
    }
  }
  /// Shared with the domain move (the gallery passes its own).
  public let migrationLock: MigrationLock
  private var lockWiring: AnyCancellable?
  var migrationCancellation: ExternalMigrationCancellation?
  /// The URLs per project the last entry asked for (Prepare Again).
  var migrationTargets: [ExternalMigrationTarget] = []
  var migrationSummary: ExternalMigrationSummary?
  /// The preparation's skipped rows, kept for after the apply.
  var migrationPreparedFailures: [String: ExternalMigrationFailure] = [:]
  /// The gallery's: the activity panel's live read, and its reload after an
  /// apply (`GalleryModel.init`).
  var onMigrationProgress: () -> Void = {}
  var onMigrationFinished: () async -> Void = {}

  private let reader: ExternalUsageReading
  /// The claim core; nil (a read-only gallery) offers no import.
  let claimer: ExternalsClaiming?
  /// The migration core; nil (a read-only gallery) offers no migration.
  let migrator: ExternalsMigrating?
  /// The gallery's thumbnail pipeline and cache (the same path,
  /// not a downloader of its own); nil draws placeholders only.
  let thumbnails: ThumbnailCache?
  private var generation = 0
  /// The scope the shown half was chosen for; a new scope chooses again.
  private var loadedScope: String??

  public init(
    reader: ExternalUsageReading, thumbnails: ThumbnailCache? = nil,
    claimer: ExternalsClaiming? = nil, migrator: ExternalsMigrating? = nil,
    sort: ExternalSort = ExternalSort(),
    groupsByFile: Bool = false, isTipDismissed: Bool = false,
    migrationLock: MigrationLock? = nil
  ) {
    self.reader = reader
    self.thumbnails = thumbnails
    self.claimer = claimer
    self.migrator = migrator
    let lock = migrationLock ?? MigrationLock()
    lock.externalWork = { migrator?.isRunning ?? false }
    self.migrationLock = lock
    _sort = Published(wrappedValue: sort)
    _groupsByFile = Published(wrappedValue: groupsByFile)
    _isTipDismissed = Published(wrappedValue: isTipDismissed)
    // The entries grey while the domain move holds the lock too.
    lockWiring = lock.$owner.sink { [weak self] _ in self?.objectWillChange.send() }
  }

  public func dismissTip() {
    guard !isTipDismissed else { return }
    isTipDismissed = true
    onTipDismissed?()
  }

  public var items: [ExternalReference]? { referenceSet?.references }

  public var presentation: ExternalsPresentation {
    if let loadError { return .error(loadError) }
    guard let items else { return .loading }
    return items.isEmpty ? .empty : .results(items.filter { $0.domain == domain })
  }

  public func count(_ domain: ExternalDomain) -> Int {
    items?.count { $0.domain == domain } ?? 0
  }

  public func selectProject(_ slug: String?) async {
    selectedProjectSlug = slug
    await load()
  }

  public func load() async {
    // The grid and the list hold still while a batch runs; the
    // batch's own reload at its end is the one step its rows leave in.
    guard !isImporting else {
      reloadAfterImport = true
      return
    }
    generation += 1
    let currentGeneration = generation
    let scope = selectedProjectSlug
    isLoading = true
    defer {
      if generation == currentGeneration { isLoading = false }
    }
    do {
      let result = try await reader.externalReferences(project: scope)
      guard generation == currentGeneration else { return }
      referenceSet = result
      loadError = nil
      if loadedScope != .some(scope) {
        loadedScope = .some(scope)
        expandedGroups = [:]
        domain = count(.yours) == 0 ? .other : .yours
      }
      // A failure is not kept: the next appearance asks again, as the
      // gallery's cells do.
      thumbnailStates = thumbnailStates.filter {
        if case .failed = $0.value { return false }
        return true
      }
      let ids = Set(result.references.map(\.id))
      selection = selection.filter(ids.contains)
      let urls = Set(result.references.map(\.rawURL))
      importFailures = importFailures.filter { urls.contains($0.key) }
      migrationFailures = migrationFailures.filter { urls.contains($0.key) }
    } catch {
      guard generation == currentGeneration else { return }
      referenceSet = nil
      loadedScope = nil
      loadError = UserFacingErrorMessage.resolve(error)
    }
  }

  // MARK: - Views, groups, thumbnails

  /// The shown half's view; setting it changes only that half's.
  public var viewMode: GalleryModel.ViewMode {
    get { viewModes[domain] ?? Self.defaultViewMode(domain) }
    set { viewModes[domain] = newValue }
  }

  public static func defaultViewMode(_ domain: ExternalDomain) -> GalleryModel.ViewMode {
    domain == .yours ? .grid : .table
  }

  /// The shown half's rows by domain, the one grouping both views draw:
  /// Your Domains by the prefix that matched — current prefixes ahead of
  /// old ones; Other Domains by host. Larger groups first, then by name;
  /// rows in the page's order. Group by File groups by the
  /// referencing file instead (`fileGroups`).
  public var groups: [ExternalGroup] {
    guard case let .results(shown) = presentation else { return [] }
    let rows = Self.ordered(shown, by: sort) { self.importFailure($0)?.category }
    if groupsByFile {
      let files = Self.fileGroups(rows, showsProject: selectedProjectSlug == nil)
      guard sort.field == .refs else { return files }
      return files.sorted { lhs, rhs in
        Self.refsPrecede(lhs, rhs, direction: sort.direction)
      }
    }
    var order: [String] = []
    var grouped: [String: ExternalGroup] = [:]
    for row in rows {
      let key = Self.groupKey(row)
      if grouped[key.id] == nil {
        order.append(key.id)
        grouped[key.id] = ExternalGroup(
          id: key.id, host: key.host, match: row.match, rows: [])
      }
      grouped[key.id]?.rows.append(row)
    }
    return order.compactMap { grouped[$0] }.sorted { lhs, rhs in
      if sort.field == .refs { return Self.refsPrecede(lhs, rhs, direction: sort.direction) }
      let lhsOld = lhs.match.map { !$0.isCurrent } ?? false
      let rhsOld = rhs.match.map { !$0.isCurrent } ?? false
      if lhsOld != rhsOld { return !lhsOld }
      if lhs.rows.count != rhs.rows.count { return lhs.rows.count > rhs.rows.count }
      return lhs.host < rhs.host
    }
  }

  /// Refs' order: the larger group first descending (the header's first
  /// click), the smaller first ascending; equal counts keep the page's own
  /// current-then-old, host order.
  private static func refsPrecede(
    _ lhs: ExternalGroup, _ rhs: ExternalGroup, direction: AssetSort.Direction
  ) -> Bool {
    if lhs.rows.count != rhs.rows.count {
      return direction == .descending ? lhs.rows.count > rhs.rows.count : lhs.rows.count < rhs.rows.count
    }
    let lhsOld = lhs.match.map { !$0.isCurrent } ?? false
    let rhsOld = rhs.match.map { !$0.isCurrent } ?? false
    if lhsOld != rhsOld { return !lhsOld }
    return lhs.host < rhs.host
  }

  private static func groupKey(_ row: ExternalReference) -> (id: String, host: String) {
    if let match = row.match {
      let host = URL(string: match.prefix)?.host?.lowercased() ?? match.prefix
      return ("\(match.backendSlug)\u{0}\(match.prefix)", host)
    }
    let host = URL(string: row.rawURL)?.host?.lowercased() ?? ""
    return (host, host.isEmpty ? "No Host" : host)
  }

  /// The grouped list's disclosure state: only the first group is open
  /// until one is opened or closed.
  /// File groups all start open: a file is a handful of rows.
  public func isExpanded(_ group: ExternalGroup) -> Bool {
    if let open = expandedGroups[domain] { return open.contains(group.id) }
    return groupsByFile || groups.first?.id == group.id
  }

  public func setExpanded(_ group: ExternalGroup, _ expanded: Bool) {
    var open = expandedGroups[domain] ?? Set(groups.prefix(groupsByFile ? .max : 1).map(\.id))
    if expanded { open.insert(group.id) } else { open.remove(group.id) }
    expandedGroups[domain] = open
  }

  /// A cell's or a row's image: Your Domains through the gallery's
  /// pipeline; for Other Domains only what a Load asked for, else nil
  /// — the placeholder, nothing asked of the host.
  public func thumbnail(_ row: ExternalReference) -> ExternalThumbnail? {
    guard row.domain == .yours else { return thumbnailStates[row.rawURL] }
    return thumbnailStates[row.rawURL] ?? .loading
  }

  /// Asks the gallery's cache for a Your Domains row's image, once per URL
  /// until a reload; Other Domains rows are never asked for.
  public func loadThumbnail(_ row: ExternalReference) {
    load(row, allowingOther: false)
  }

  /// "Load preview" on an Other Domains row.
  /// It asks for exactly that one URL through the same thumbnail pipeline,
  /// and only when no image is already on its way; a failed attempt may be
  /// asked again. The page's lists and grid still never call this.
  public func loadPreview(_ row: ExternalReference) {
    load(row, allowingOther: true)
  }

  /// The inspector's preview: Your Domains reads its thumbnail state;
  /// Other Domains reads one only after `loadPreview` asked for it.
  public func preview(_ row: ExternalReference) -> ExternalThumbnail? {
    if row.domain == .yours { return thumbnail(row) }
    return thumbnailStates[row.rawURL]
  }

  /// Starts `row`'s request; false when it was not asked (another half,
  /// no web URL, already loading or loaded). `finished` hears whether an
  /// image came back.
  @discardableResult
  func load(
    _ row: ExternalReference, allowingOther: Bool,
    finished: (@MainActor (Bool) -> Void)? = nil
  ) -> Bool {
    guard (row.domain == .yours || allowingOther), let thumbnails, let url = Self.webURL(row)
    else { return false }
    let rawURL = row.rawURL
    if let state = thumbnailStates[rawURL] {
      // A row already loading or loaded is not asked again; a failure may
      // be retried by the inspector's button.
      if case .failed = state {} else { return false }
    }
    thumbnailStates[rawURL] = .loading
    Task {
      let state: ExternalThumbnail
      do {
        // The original's facts come back with the image, from this
        // one request or the record a past one left.
        let load = try await thumbnails.load(for: Self.thumbnailRequest(url, rawURL: rawURL))
        state = load.map { .loaded($0.image, $0.info) } ?? .failed("Not an image")
      } catch {
        state = .failed(UserFacingErrorMessage.resolve(error))
      }
      // A reload in between dropped the entry; a later appearance asks again.
      if thumbnailStates[rawURL] == .loading { thumbnailStates[rawURL] = state }
      if case .loaded = state { finished?(true) } else { finished?(false) }
    }
    return true
  }

  /// A URL outside the catalog has no content hash; its cache entries are
  /// keyed by the URL's.
  static func urlKey(_ rawURL: String) -> String {
    SHA256.hash(data: Data(rawURL.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func thumbnailRequest(_ url: URL, rawURL: String) -> ThumbnailRequest {
    ThumbnailRequest(sha256: urlKey(rawURL), sourceURL: url)
  }

  /// Quick Look's one original: the single selected row's, in
  /// either half — the only image Other Domains ever loads.
  public var quickLookRequest: OriginalImageRequest? {
    guard selection.count == 1, let row = rows(selection).first, let url = Self.webURL(row)
    else { return nil }
    return OriginalImageRequest(
      sha256: Self.urlKey(row.rawURL), sourceURL: url, filename: url.lastPathComponent)
  }

  /// The event being handled; tests replace it.
  var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
  /// Where ⇧-click extends from: the last row clicked without ⇧.
  private var anchorID: ExternalReference.ID?

  /// A Grid cell's tap, read off its own event as the library's
  /// (`GalleryModel.cellClick`): ⇧ extends in display order, ⌘ toggles,
  /// else the row alone; a plain double-click opens Quick Look.
  public func clickCell(_ row: ExternalReference) {
    let event = currentEvent()
    let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
    let clickCount = event.flatMap { mouse.contains($0.type) ? $0.clickCount : nil } ?? 1
    let click = GalleryModel.cellClick(clickCount: clickCount, modifiers: event?.modifierFlags ?? [])
    switch click.mode {
    case .replace:
      selection = [row.id]
      anchorID = row.id
    case .toggle:
      if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) }
      anchorID = row.id
    case .extend:
      let order = groups.flatMap(\.rows).map(\.id)
      guard let anchorID, let from = order.firstIndex(of: anchorID),
        let to = order.firstIndex(of: row.id)
      else {
        selection = [row.id]
        anchorID = row.id
        return
      }
      selection = Set(order[min(from, to)...max(from, to)])
    }
    if click.opensQuickLook { openPrimary([row.id]) }
  }

  /// Every row with the selected row's URL, for the inspector's Used In.
  public func references(to rawURL: String) -> [ExternalReference] {
    items?.filter { $0.rawURL == rawURL } ?? []
  }

  /// The inspector's Used In, in the library's own state and line shape
  /// ("astro · posts/foo.md:12"): every reference, so it never offers a
  /// Show All it has nowhere to send.
  public func usedIn(_ rawURL: String) -> UsedInState {
    let rows = references(to: rawURL)
    guard !rows.isEmpty else { return .notUsed }
    return .used(
      rows: rows.map { reference in
        let split = UsageReferenceRow.split(reference.sourceReference)
        return UsedInRow(
          project: reference.projectSlug, path: split.file, line: split.line)
      },
      total: rows.count, projects: Set(rows.map(\.projectSlug)))
  }

  // MARK: - Selection, context menu, ⌘C, double-click

  /// The shown half's rows among `ids`, in the page's order.
  public func rows(_ ids: Set<ExternalReference.ID>) -> [ExternalReference] {
    guard case let .results(rows) = presentation else { return [] }
    return Self.ordered(rows.filter { ids.contains($0.id) }, by: sort) {
      self.importFailure($0)?.category
    }
  }

  /// The referencing file, when the Open File rule allows it.
  public func fileURL(_ reference: ExternalReference) -> URL? {
    guard let sources = referenceSet?.projectSources else { return nil }
    return UsageSourceFile.url(
      project: reference.projectSlug,
      path: UsageReferenceRow.split(reference.sourceReference).file, sources: sources)
  }

  /// The reference itself, when a browser can open it.
  public static func webURL(_ reference: ExternalReference) -> URL? {
    guard let url = URL(string: reference.rawURL),
      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else { return nil }
    return url
  }

  /// The context menu for `ids`: Copy URL (a line each), Open URL, and
  /// Open File / Reveal in Finder for the rows the rule allows — absent
  /// when no row does.
  /// Several rows lead with the "N Images" title (distinct
  /// URLs); then Load Preview(s) for the Other Domains URLs a Load would
  /// ask for. Files are each once.
  public func menuItems(for ids: Set<ExternalReference.ID>) -> [ExternalMenuItem] {
    let rows = rows(ids)
    guard let text = copyText(rows) else { return [] }
    var items: [ExternalMenuItem] = []
    if rows.count > 1 {
      items.append(.title(ExternalsImportFacts.distinctURLs(rows).count))
    }
    // Import into Catalog leads, on Your Domains only;
    // a URL several rows share is imported once.
    if canImport, !isImporting, rows.allSatisfy({ $0.domain == .yours }) {
      items.append(.importIntoCatalog(ExternalsImportFacts.distinctURLs(rows)))
    }
    let candidates = previewCandidates(rows)
    if !candidates.isEmpty { items.append(.loadPreviews(candidates.map(\.rawURL))) }
    // Under Load Previews, Other Domains only; greyed while
    // a migration runs (`isEnabled`).
    let migratable = migrationURLs(rows)
    if !migratable.isEmpty { items.append(.migrateToBucket(migratable)) }
    items.append(.copyURL(text))
    let web = rows.compactMap(Self.webURL)
    if !web.isEmpty { items.append(.openURL(web)) }
    var seen = Set<URL>()
    let files = rows.compactMap(fileURL).filter { seen.insert($0).inserted }
    if !files.isEmpty { items += [.openFile(files), .revealInFinder(files)] }
    return items
  }

  /// ⌘C: the selection's URLs, a line each, as Copy URL.
  public func copySelection() {
    guard let text = copyText(rows(selection)) else { return }
    PasteboardWriter.copy(text, to: pasteboard)
  }

  /// Double-click: each row's file, or its URL when the rule does not
  /// allow the file.
  public func primaryURLs(for ids: Set<ExternalReference.ID>) -> [URL] {
    rows(ids).compactMap { fileURL($0) ?? Self.webURL($0) }
  }

  public func openPrimary(_ ids: Set<ExternalReference.ID>) {
    primaryURLs(for: ids).forEach(open)
  }

  public func perform(_ item: ExternalMenuItem) {
    switch item {
    case let .copyURL(text): PasteboardWriter.copy(text, to: pasteboard)
    case let .openURL(urls), let .openFile(urls): urls.forEach(open)
    case let .revealInFinder(urls): reveal(urls)
    case let .importIntoCatalog(urls): Task { await requestImport(urls: urls) }
    case let .loadPreviews(urls):
      let wanted = Set(urls)
      loadPreviews(items?.filter { wanted.contains($0.rawURL) } ?? [])
    case let .migrateToBucket(urls):
      let wanted = Set(urls)
      Task { await migrate(items?.filter { wanted.contains($0.rawURL) } ?? []) }
    case .title: break
    }
  }

  /// A menu item drawn greyed: Migrate to Bucket… while a migration runs.
  public func isEnabled(_ item: ExternalMenuItem) -> Bool {
    if case .migrateToBucket = item { return !isMigrationBusy }
    return true
  }

  /// One line per URL, as the library's Copy URL and drag-out join.
  private func copyText(_ rows: [ExternalReference]) -> String? {
    rows.isEmpty ? nil : rows.map(\.rawURL).joined(separator: "\n")
  }
}

/// A remote thumbnail's state, read as a value.
public enum ExternalThumbnail: Equatable {
  case loading
  /// The image, and its original's bytes, pixels and type when the
  /// Load that fetched it recorded them.
  case loaded(CGImage, RemoteImageInfo? = nil)
  /// Why there is no image: "404 · not found", a network error's sentence.
  case failed(String)
}

/// One domain's rows: a Your Domains prefix, or an Other
/// Domains host.
public struct ExternalGroup: Identifiable, Equatable {
  public let id: String
  /// The prefix's host, or the URL's; under Group by File, the file.
  public let host: String
  /// Which backend prefix; nil in Other Domains.
  public let match: ExternalDomainMatch?
  public var rows: [ExternalReference]
  /// Group by File: `host` is then the file's path.
  public var isFile = false

  /// "current domain of r2 · 3", "old domain of b2 · 1", "4".
  public var note: String {
    let count = rows.count.formatted()
    guard let match else { return count }
    return "\(match.isCurrent ? "current" : "old") domain of \(match.backendSlug) · \(count)"
  }
}

/// The Externals context menu, read as values.
public enum ExternalMenuItem: Identifiable, Equatable, Sendable {
  /// A selection's heading, "N Images" (distinct URLs); not a command.
  case title(Int)
  /// The selection's distinct URLs.
  case importIntoCatalog([String])
  /// The Other Domains URLs a Load would ask for.
  case loadPreviews([String])
  /// The Other Domains URLs to migrate.
  case migrateToBucket([String])
  case copyURL(String)
  case openURL([URL])
  case openFile([URL])
  case revealInFinder([URL])

  public var id: String {
    switch self {
    case .title: return "title"
    case .importIntoCatalog: return "importIntoCatalog"
    case .loadPreviews: return "loadPreviews"
    case .migrateToBucket: return "migrateToBucket"
    case .copyURL: return "copyURL"
    case .openURL: return "openURL"
    case .openFile: return "openFile"
    case .revealInFinder: return "revealInFinder"
    }
  }

  public var title: String {
    // Plural when the item carries several: a single row keeps the
    // singular names.
    switch self {
    case let .title(count): return PinaxFormat.count(count, singular: "Image")
    case .importIntoCatalog: return "Import into Catalog"
    case let .loadPreviews(urls): return urls.count > 1 ? "Load Previews" : "Load Preview"
    case .migrateToBucket: return "Migrate to Bucket…"
    case let .copyURL(text): return text.contains("\n") ? "Copy URLs" : "Copy URL"
    case let .openURL(urls): return urls.count > 1 ? "Open URLs" : "Open URL"
    case let .openFile(urls): return urls.count > 1 ? "Open Files" : "Open File"
    case .revealInFinder: return "Reveal in Finder"
    }
  }
  /// The figure at the item's trailing end: Open Files' file count.
  public var badge: Int? {
    if case let .openFile(urls) = self, urls.count > 1 { return urls.count }
    return nil
  }
}
