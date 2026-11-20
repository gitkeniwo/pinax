import AppKit
import CatalogCore
import CoreGraphics
import Foundation

/// Runs `operation` on every item with at most `maxConcurrent` in flight,
/// submitting the next as each finishes — the same shape the CLI's upload
/// command uses. A 200-file drop therefore never opens 200 tasks at once.
public func boundedForEach<Item: Sendable>(
  _ items: [Item],
  maxConcurrent: Int = 4,
  operation: @escaping @Sendable (Item) async -> Void
) async {
  guard !items.isEmpty else { return }
  var iterator = items.makeIterator()
  await withTaskGroup(of: Void.self) { group in
    func submitNext() {
      guard let item = iterator.next() else { return }
      group.addTask { await operation(item) }
    }
    for _ in 0..<maxConcurrent { submitNext() }
    while await group.next() != nil {
      submitNext()
    }
  }
}

@MainActor
public final class DropZoneModel: ObservableObject {
  public struct UploadCard: Identifiable {
    public enum Phase: Equatable {
      case waiting
      case uploading
      case done(UploadOutcome)
      case failed(String)

      public var isPending: Bool {
        switch self {
        case .waiting, .uploading: return true
        case .done, .failed: return false
        }
      }
    }

    public let id: UUID
    public let fileURL: URL
    public let filename: String
    public var phase: Phase
    public var thumbnail: CGImage?
    /// The project this card uploads into — snapshotted at drop time so a
    /// later picker change never rewrites an in-flight upload's destination.
    public var projectSlug: String?
    /// Set when an inline project change was refused; cleared on the next try.
    public var moveError: String?
    /// When this run's upload landed as new bytes (not deduplicated): the
    /// card's brief glow and its "Just now" count from here. nil for every other card.
    public var landedAt: Date?
    /// The catalog row behind a card that Show Drop Zone brought up from the
    /// catalog; nil for a card dropped in this run.
    public let catalogItem: CatalogAssetItem?

    init(fileURL: URL, projectSlug: String?) {
      self.id = UUID()
      self.fileURL = fileURL
      self.filename = fileURL.lastPathComponent
      self.phase = .waiting
      self.projectSlug = projectSlug
      self.catalogItem = nil
    }

    /// A card made up whole, phase and all: the settings preview's samples.
    init(
      filename: String, fileURL: URL, phase: Phase, thumbnail: CGImage?,
      landedAt: Date? = nil, projectSlug: String?
    ) {
      self.id = UUID()
      self.fileURL = fileURL
      self.filename = filename
      self.phase = phase
      self.thumbnail = thumbnail
      self.landedAt = landedAt
      self.projectSlug = projectSlug
      self.catalogItem = nil
    }

    init(catalogItem item: CatalogAssetItem, projectSlug: String?) {
      let asset = item.asset
      let filename = asset.originalFilename ?? (asset.key as NSString).lastPathComponent
      self.id = UUID()
      self.fileURL = URL(string: item.url) ?? URL(fileURLWithPath: filename)
      self.filename = filename
      self.phase = .done(
        UploadOutcome(
          sha256: asset.sha256, key: asset.key, url: item.url, mime: asset.mime,
          originalFilename: filename, byteSize: asset.byteSize, width: asset.width,
          height: asset.height, uploadedAt: asset.uploadedAt, deduplicated: false,
          dryRun: false))
      self.projectSlug = projectSlug
      self.catalogItem = item
    }
  }

  public let service: any DropZoneService
  public let thumbnails: ThumbnailCache
  public let quickLook: QuickLookController
  @Published public private(set) var cards: [UploadCard] = [] {
    didSet { refreshUploadProgress() }
  }
  /// The main window's status bar line while uploads run, nil when
  /// none is pending. The shell forwards every change to the gallery.
  public private(set) var uploadProgress: String? {
    didSet {
      if uploadProgress != oldValue { onUploadProgressChange?(uploadProgress) }
    }
  }
  public var onUploadProgressChange: ((String?) -> Void)?
  /// How far the pending batch is, as numbers (the menu bar panel's
  /// "Uploading 2 of 5"); nil when nothing is pending. Set with
  /// `uploadProgress`, which `cards` already republishes.
  public private(set) var uploadCounts: UploadCounts?
  /// The same progress, pushed to the menu bar icon's ring.
  public var onUploadCountsChange: ((UploadCounts?) -> Void)?
  /// A card failed.
  public var onUploadFailed: (() -> Void)?
  /// The drop zone window has just gone from hidden to shown: its failures
  /// are seen. Not called again while it stays visible.
  public var onWindowDidShow: (() -> Void)?
  /// Cards enqueued since nothing was last pending: the "of N" in the line.
  private var uploadBatchSize = 0
  /// A card of that same batch settled to done: only then does the batch's
  /// end copy URLs, so a batch of failures never re-copies older cards.
  private var batchHasSuccess = false
  @Published public private(set) var isDragActive = false
  /// The live drag's image files, as `DragMonitor` already read them: the
  /// drag-over state's count and photo stack. Never a second read
  /// of the drag pasteboard.
  @Published public private(set) var draggedFileURLs: [URL] = []
  /// The zone and the results list are one surface: the window shows
  /// while a qualifying drag is live, and from a drop (or Show Drop Zone)
  /// until the countdown, × or `disable()` ends the presentation.
  @Published public private(set) var isWindowVisible = false
  /// The cards are on screen because of a drop or the menu bar's Show Drop
  /// Zone — the cause the countdown ends. The cards themselves
  /// outlive it: this run's uploads come back on the next Show Drop Zone.
  @Published public private(set) var isPresenting = false
  /// While pinned the countdown never runs. This run only; never
  /// stored.
  @Published public private(set) var isPinned = false
  /// The pointer is over the panel (its tracking area reports this): the
  /// countdown is paused, and restarts from the top when the pointer leaves.
  public private(set) var isPointerInside = false
  /// Set by Window → Show Drop Zone (⌘⇧D): the panel stays up as a standing
  /// drop target until dismissed. Without this the panel would only ever be
  /// visible during a drag, and the command could not show anything.
  @Published public private(set) var isShownOnDemand = false
  @Published public private(set) var projects: [Project] = []
  /// The panel's project picker: the app's current project. The model stores
  /// nothing; the shell mirrors this both ways with
  /// `PreferencesStore.currentProjectSlug`. nil = no project.
  @Published public var selectedProjectSlug: String? {
    didSet {
      guard oldValue != selectedProjectSlug else { return }
      // A preview's picker is for show: only its seed moves it.
      if isPreview {
        if !isSeedingPreview {
          isSeedingPreview = true
          selectedProjectSlug = oldValue
          isSeedingPreview = false
        }
        return
      }
      onSelectedProjectChange?(selectedProjectSlug)
    }
  }
  public var onSelectedProjectChange: ((String?) -> Void)?
  /// Fires as the panel goes from hidden to shown, before anything is
  /// dropped on it: the app starts the appearance at Upload into's target.
  public var onWindowWillShow: (() -> Void)?
  /// Fires when a batch's last pending card settles. The app shell refreshes
  /// the gallery here so uploads appear without a manual reload.
  public var onUploadsSettled: (() -> Void)?

  // MARK: - Behaviour inputs (pushed by the shell from PreferencesStore)

  /// When non-nil, a qualifying drag surfaces the zone only while this
  /// modifier is held (Clop's `onlyShowDropZoneOnOption`). nil = ungated.
  public var dragVisibilityModifier: DropZoneModifier?
  /// "Auto hide after": seconds from the last upload ending (done
  /// or failed) until the presentation ends. 0 = never. The countdown ends
  /// the presentation only: an on-demand revealed zone (⌘⇧D) stays, and the
  /// cards stay for the next Show Drop Zone.
  public var autoHidesResultsAfter: TimeInterval = 0
  /// When a batch settles, every successful card's URL goes to the
  /// clipboard, newline-joined — the batch shown on the panel is the batch
  /// copied.
  public var copiesURLsAutomatically = true
  /// The copier seam: production gets the real clipboard; tests get a spy so
  /// no test ever writes the user's pasteboard.
  public var urlCopier: ((String) -> Void)?

  /// The countdown's clock seam: schedules `action` after the delay and
  /// returns its cancel. Production sleeps a task; tests hand in a fake
  /// clock so no test waits out a real countdown.
  public var autoHideScheduler:
    @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> @MainActor () -> Void =
      DropZoneModel.sleepingScheduler

  private var cancelCountdown: (@MainActor () -> Void)?

  /// A settings preview's model (`preview(...)`): everything that would
  /// upload, copy, move, open Quick Look or change the panel does nothing.
  /// The preview's own service and copier are the first line; this is the
  /// second.
  let isPreview: Bool
  /// Set while `seedPreview` writes the picker, the one write a preview
  /// takes.
  var isSeedingPreview = false

  public convenience init(
    service: any DropZoneService,
    thumbnails: ThumbnailCache,
    quickLook: QuickLookController? = nil
  ) {
    self.init(service: service, thumbnails: thumbnails, quickLook: quickLook, isPreview: false)
  }

  init(
    service: any DropZoneService,
    thumbnails: ThumbnailCache,
    quickLook: QuickLookController?,
    isPreview: Bool
  ) {
    self.isPreview = isPreview
    self.service = service
    self.thumbnails = thumbnails
    self.quickLook = quickLook ?? QuickLookController(thumbnails: thumbnails)
  }

  public func loadProjects() {
    do {
      projects = try service.projects()
    } catch {
      projects = []
    }
    // A project that is gone reads as no project (All Projects).
    if let slug = selectedProjectSlug, !projects.contains(where: { $0.slug == slug }) {
      selectedProjectSlug = nil
    }
  }

  // MARK: - Drag lifecycle

  public func dragDidChange(fileURLs: [URL], modifiers: NSEvent.ModifierFlags) {
    let gateSatisfied = dragVisibilityModifier?.isSatisfied(by: modifiers) ?? true
    let active = !fileURLs.isEmpty && gateSatisfied
    let wasActive = isDragActive
    isDragActive = active
    // Gate or no gate: a pinned or revealed panel is a target either way.
    if fileURLs != draggedFileURLs { draggedFileURLs = fileURLs }
    if active != wasActive {
      // A drag over the results is a new interaction: the countdown must not
      // fire mid-drag and yank the drop target away; it restarts afterwards.
      restartCountdown()
    }
    refreshVisibility()
  }

  /// The drag is over. Measured (real `DragMonitor` → model): when the
  /// mouse-up reaches the model before the drop, visibility reads
  /// true → false → true; drop first, it stays true. Either way the drop's
  /// presentation — not the drag — is what keeps the panel up afterwards.
  public func dragDidEnd() {
    isDragActive = false
    draggedFileURLs = []
    restartCountdown()
    refreshVisibility()
  }

  /// The zone's reaction to being disabled: every visibility cause goes,
  /// including the on-demand reveal — a revealed panel carries a live
  /// `.dropDestination` that does not pass through the (stopped) drag
  /// monitor, so leaving it up would keep a working upload entrance behind a
  /// feature the user just turned off.
  public func disable() {
    isDragActive = false
    draggedFileURLs = []
    isShownOnDemand = false
    endPresentation()
  }

  public func drop(fileURLs: [URL]) {
    guard !isPreview else { return }
    isDragActive = false
    draggedFileURLs = []
    guard !fileURLs.isEmpty else {
      refreshVisibility()
      return
    }
    // Cards Show Drop Zone brought up from the catalog were a view of it, not
    // this run's uploads; a real drop replaces them.
    cards.removeAll { $0.catalogItem != nil }
    let newCards = fileURLs.map { UploadCard(fileURL: $0, projectSlug: selectedProjectSlug) }
    // Newest first: a drop over existing cards lands on top,
    // where the pointer that just dropped it is looking.
    uploadBatchSize += newCards.count
    cards.insert(contentsOf: newCards, at: 0)
    isPresenting = true
    // New pending cards: no countdown until the last of them ends.
    restartCountdown()
    refreshVisibility()
    enqueueThumbnails(for: newCards)
    enqueueUploads(for: newCards)
  }

  /// ×: hide now and unpin. The cards stay for Show Drop Zone.
  public func dismiss() {
    guard !isPreview else { return }
    isDragActive = false
    draggedFileURLs = []
    isShownOnDemand = false
    endPresentation()
  }

  public func togglePin() {
    guard !isPreview else { return }
    isPinned.toggle()
    restartCountdown()
  }

  /// The panel's tracking area. Entering pauses the countdown; leaving
  /// restarts it from the top.
  public func pointerDidEnter() {
    isPointerInside = true
    restartCountdown()
  }

  public func pointerDidExit() {
    isPointerInside = false
    restartCountdown()
  }

  /// Whether this run has dropped anything (the cards Show Drop Zone brings
  /// back instead of the catalog's newest).
  public var hasSessionUploads: Bool {
    cards.contains { $0.catalogItem == nil }
  }

  /// Menu bar ▸ Show Drop Zone with this run's cards: present them again,
  /// counting down as after a drop.
  public func presentSession() {
    present()
  }

  /// Menu bar ▸ Show Drop Zone with no uploads this run: the catalog's
  /// newest rows as done cards. Thumbnails come from the cache only — no
  /// fetch for a card nobody dropped.
  public func presentRecent(_ items: [CatalogAssetItem], memberships: [Int64: Set<String>]) {
    let recent = items.map { item in
      UploadCard(
        catalogItem: item,
        projectSlug: item.asset.id.flatMap { memberships[$0]?.sorted().first })
    }
    cards = recent
    present()
    let thumbnails = self.thumbnails
    let requests = recent.compactMap { card -> (UUID, ThumbnailRequest)? in
      guard let item = card.catalogItem, let url = URL(string: item.url) else { return nil }
      return (card.id, ThumbnailRequest(sha256: item.asset.sha256, sourceURL: url))
    }
    Task { [weak self] in
      for (id, request) in requests {
        guard let image = await thumbnails.cachedImage(for: request) else { continue }
        self?.setThumbnail(image, for: id)
      }
    }
  }

  private func present() {
    isPresenting = true
    restartCountdown()
    refreshVisibility()
  }

  private func endPresentation() {
    isPresenting = false
    isPinned = false
    isPointerInside = false
    cancelAutoHide()
    refreshVisibility()
  }

  /// Reveals the panel as a standing drop target (no drag required). Used by
  /// the Show Drop Zone command; a later drag or drop supersedes nothing —
  /// all three visibility causes simply OR together.
  public func revealOnDemand() {
    isShownOnDemand = true
    refreshVisibility()
  }

  private func refreshVisibility() {
    let visible = isDragActive || isPresenting || isShownOnDemand
    let appearing = visible && !isWindowVisible
    if appearing { onWindowWillShow?() }
    isWindowVisible = visible
    if appearing { onWindowDidShow?() }
  }

  // MARK: - Uploads

  /// The cards of permanently deleted images go; an
  /// upload still in flight keeps its card.
  public func removeCards(for sha256s: Set<String>) {
    cards.removeAll { card in
      guard case let .done(outcome) = card.phase else { return false }
      return sha256s.contains(outcome.sha256)
    }
  }

  public func retry(_ id: UUID) {
    guard !isPreview else { return }
    guard let index = cards.firstIndex(where: { $0.id == id }),
      case .failed = cards[index].phase
    else { return }
    uploadBatchSize += 1
    cards[index].phase = .waiting
    restartCountdown()
    enqueueUploads(for: [cards[index]])
  }

  /// Drop-zone cards already point at the local source file, so this bypasses
  /// the original-image downloader and its cache entirely.
  public func quickLook(_ id: UUID) {
    guard !isPreview else { return }
    guard let card = cards.first(where: { $0.id == id }) else { return }
    if let item = card.catalogItem {
      quickLook.toggleRemote([item], at: 0)
    } else {
      quickLook.toggleLocal(card.fileURL)
    }
  }

  /// Changes where a landed card's asset belongs. The old membership is
  /// released and the new one added; a refusal (e.g. the project vanished)
  /// reverts the picker and is shown on the card, never swallowed.
  public func changeProject(_ id: UUID, to slug: String?) {
    guard !isPreview else { return }
    guard let index = cards.firstIndex(where: { $0.id == id }),
      case .done(let outcome) = cards[index].phase,
      cards[index].projectSlug != slug
    else { return }
    let oldSlug = cards[index].projectSlug
    cards[index].projectSlug = slug
    cards[index].moveError = nil
    let sha256 = outcome.sha256
    let service = self.service
    Task { [weak self] in
      do {
        // The zone never confirms an unlink: a move away from a project the
        // site still references is refused by the core guard, and the card
        // shows that reason instead of silently breaking the project.
        try await service.moveAsset(
          sha256: sha256, fromProject: oldSlug, toProject: slug, confirmed: false)
      } catch {
        let message = Self.failureMessage(error)
        await MainActor.run {
          guard let self, let index = self.cards.firstIndex(where: { $0.id == id }) else { return }
          self.cards[index].projectSlug = oldSlug
          self.cards[index].moveError = message
        }
      }
    }
  }

  private func enqueueUploads(for targets: [UploadCard]) {
    let service = self.service
    let items = targets.map { (id: $0.id, fileURL: $0.fileURL, projectSlug: $0.projectSlug) }
    Task { [weak self] in
      await boundedForEach(items) { item in
        await MainActor.run { self?.setPhase(.uploading, for: item.id) }
        let phase: UploadCard.Phase
        do {
          phase = .done(try await service.upload(item.fileURL, projectSlug: item.projectSlug))
        } catch {
          phase = .failed(Self.failureMessage(error))
        }
        await MainActor.run { self?.settle(phase, for: item.id) }
      }
    }
  }

  private func refreshUploadProgress() {
    let pending = cards.filter(\.phase.isPending)
    guard !pending.isEmpty else {
      uploadBatchSize = 0
      batchHasSuccess = false
      uploadProgress = nil
      uploadCounts = nil
      onUploadCountsChange?(nil)
      return
    }
    let total = max(uploadBatchSize, pending.count)
    let counts = UploadCounts(completed: total - pending.count, total: total)
    uploadCounts = counts
    onUploadCountsChange?(counts)
    uploadProgress =
      total == 1
      ? "Uploading \(pending[0].filename)…" : "Uploaded \(total - pending.count) of \(total)…"
  }

  private func setPhase(_ phase: UploadCard.Phase, for id: UUID) {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[index].phase = phase
  }

  private func settle(_ phase: UploadCard.Phase, for id: UUID) {
    // Read before setPhase: the last card settling ends the batch, which
    // resets the flag.
    if case .done = phase { batchHasSuccess = true }
    let batchSucceeded = batchHasSuccess
    setPhase(phase, for: id)
    if case .failed = phase { onUploadFailed?() }
    if case .done(let outcome) = phase, !outcome.deduplicated,
      let index = cards.firstIndex(where: { $0.id == id })
    {
      cards[index].landedAt = Date()
    }
    if case .done(let outcome) = phase, outcome.deduplicated {
      mergeDuplicate(id, outcome: outcome)
    }
    if !cards.isEmpty, cards.allSatisfy({ !$0.phase.isPending }) {
      if batchSucceeded { copySettledURLs() }
      restartCountdown()
      onUploadsSettled?()
    }
  }

  /// A drop that the library already held: when a done
  /// card with the same bytes is in the list, the new card goes and that one
  /// moves to the front, now in the already-in-library look and labelled
  /// with this drop's project. With no such card the new one stays.
  private func mergeDuplicate(_ id: UUID, outcome: UploadOutcome) {
    guard let index = cards.firstIndex(where: { $0.id == id }),
      let existingIndex = cards.firstIndex(where: { card in
        guard card.id != id, case .done(let earlier) = card.phase else { return false }
        return earlier.sha256 == outcome.sha256
      })
    else { return }
    let dropped = cards[index]
    var existing = cards[existingIndex]
    existing.phase = .done(outcome)
    existing.projectSlug = dropped.projectSlug
    existing.moveError = nil
    existing.landedAt = nil
    existing.thumbnail = existing.thumbnail ?? dropped.thumbnail
    cards.remove(at: max(index, existingIndex))
    cards.remove(at: min(index, existingIndex))
    cards.insert(existing, at: 0)
  }

  /// Copies what the panel shows: every currently-done card's URL, in card
  /// order, newline-joined (a single card gets a bare URL). Failures are
  /// skipped. Called only when the settled batch had a success: a batch with
  /// none copies nothing, neither emptiness nor earlier batches' URLs.
  private func copySettledURLs() {
    guard copiesURLsAutomatically, let urlCopier else { return }
    let urls = cards.compactMap { card -> String? in
      guard case .done(let outcome) = card.phase else { return nil }
      return outcome.url
    }
    guard !urls.isEmpty else { return }
    urlCopier(urls.joined(separator: "\n"))
  }

  /// (Re)starts the countdown from the top when it may run, and cancels it
  /// otherwise. It runs only while presenting, unpinned, with the pointer
  /// outside, no drag live, and no card still pending (it starts when the
  /// last upload ends, done or failed).
  private func restartCountdown() {
    cancelAutoHide()
    let delay = autoHidesResultsAfter
    guard delay > 0, isPresenting, !isPinned, !isPointerInside, !isDragActive,
      !cards.contains(where: { $0.phase.isPending })
    else { return }
    cancelCountdown = autoHideScheduler(delay) { [weak self] in
      self?.cancelCountdown = nil
      self?.autoHideFired()
    }
  }

  private func cancelAutoHide() {
    cancelCountdown?()
    cancelCountdown = nil
  }

  private func autoHideFired() {
    // Ends the presentation, never the user's standing target: a panel
    // revealed on demand (⌘⇧D) survives it.
    endPresentation()
  }

  nonisolated public static func sleepingScheduler(
    _ delay: TimeInterval, _ action: @escaping @MainActor () -> Void
  ) -> @MainActor () -> Void {
    let task = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      action()
    }
    return { task.cancel() }
  }

  /// Failures are converted without reflecting the error value: an unknown
  /// error can carry request details or credentials in associated values.
  nonisolated private static func failureMessage(_ error: Error) -> String {
    UserFacingErrorMessage.resolve(error)
  }

  // MARK: - Free thumbnails

  /// The dropped file's bytes are local, so its thumbnail is generated here
  /// and written straight into the cache — a newly uploaded image never costs
  /// a download, in the zone or later in the gallery grid.
  private func enqueueThumbnails(for targets: [UploadCard]) {
    let thumbnails = self.thumbnails
    let items = targets.map { (id: $0.id, fileURL: $0.fileURL) }
    Task { [weak self] in
      await boundedForEach(items, maxConcurrent: 2) { item in
        guard let data = try? Data(contentsOf: item.fileURL) else { return }
        let request = ThumbnailRequest(sha256: Hashing.sha256(of: data), sourceURL: item.fileURL)
        guard let image = await thumbnails.store(data: data, for: request) else { return }
        await MainActor.run { self?.setThumbnail(image, for: item.id) }
      }
    }
  }

  private func setThumbnail(_ image: CGImage, for id: UUID) {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[index].thumbnail = image
  }

  // MARK: - Copy payloads

  public func markdown(for card: UploadCard) -> String {
    guard case .done(let outcome) = card.phase else { return "" }
    return (try? UploadOutput.format([outcome], as: .markdown)) ?? outcome.url
  }

  /// The card's Copy URL / Copy Markdown buttons. Through the same copier
  /// seam as the automatic copy, so no test writes the user's pasteboard.
  public func copyURL(_ id: UUID) {
    guard !isPreview else { return }
    guard let card = cards.first(where: { $0.id == id }), case .done = card.phase else { return }
    copy(url(for: card))
  }

  public func copyMarkdown(_ id: UUID) {
    guard !isPreview else { return }
    guard let card = cards.first(where: { $0.id == id }), case .done = card.phase else { return }
    copy(markdown(for: card))
  }

  private func copy(_ string: String) {
    if let urlCopier {
      urlCopier(string)
    } else {
      PasteboardWriter.copy(string)
    }
  }

  public func url(for card: UploadCard) -> String {
    guard case .done(let outcome) = card.phase else { return "" }
    return outcome.url
  }

  // MARK: - Settings preview

  /// What the preview shows, written straight in: the cards, the drag's
  /// files, the projects and the picker. A preview's state changes only
  /// here.
  func seedPreview(
    cards: [UploadCard], draggedFileURLs: [URL], projects: [Project], selectedProjectSlug: String?
  ) {
    precondition(isPreview, "seedPreview is for a preview's model only")
    self.projects = projects
    self.cards = cards
    self.draggedFileURLs = draggedFileURLs
    isSeedingPreview = true
    self.selectedProjectSlug = selectedProjectSlug
    isSeedingPreview = false
  }
}
