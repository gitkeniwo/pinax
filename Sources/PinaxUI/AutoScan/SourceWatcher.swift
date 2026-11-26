import CatalogCore
import CoreServices
import Foundation

/// Watches the source folders of the projects that rescan on changes, one
/// stream per project and folder source. A change counts only when the scan
/// would read the file; a burst of changes becomes one request to rescan the
/// whole project. A folder that is not there is not watched and is reported
/// once, until it has been seen again.
@MainActor
final class SourceWatcher {
  /// Everything that decides a stream and its filter.
  struct Watch: Hashable {
    var project: String
    var label: String
    var path: String
    var include: [String]
    var exclude: [String]
  }

  private struct Running {
    var stream: FolderEventStream
    /// The folder as events spell it, with symbolic links resolved.
    var root: String
  }

  private let clock: ScanClock
  private let onChange: (String) -> Void
  private let onMissing: (String, UsageScanError) -> Void
  private var wanted: [Watch] = []
  private var running: [Watch: Running] = [:]
  private var reportedMissing: Set<Watch> = []
  private var debouncers: [String: ScanDebouncer] = [:]

  /// The paths of every delivery, before filtering.
  var onDelivery: (([String]) -> Void)?

  init(
    clock: ScanClock, onChange: @escaping (String) -> Void,
    onMissing: @escaping (String, UsageScanError) -> Void
  ) {
    self.clock = clock
    self.onChange = onChange
    self.onMissing = onMissing
  }

  var watched: Set<Watch> { Set(running.keys) }

  func isPending(project: String) -> Bool { debouncers[project]?.isPending == true }

  /// Brings the streams in line with the projects: unchanged watches keep
  /// theirs, and a folder that has come back is watched again.
  func update(_ projects: [AutoScanProject]) {
    wanted = projects.filter(\.autoScan.watch).flatMap { project in
      project.sources.filter { $0.kind == .folder }.map {
        Watch(
          project: project.slug, label: $0.label, path: $0.path, include: $0.effectiveInclude,
          exclude: $0.exclude)
      }
    }
    let keep = Set(wanted)
    running = running.filter { keep.contains($0.key) }
    reportedMissing.formIntersection(keep)
    let watchedProjects = Set(wanted.map(\.project))
    for (project, debouncer) in debouncers where !watchedProjects.contains(project) {
      debouncer.cancel()
      debouncers[project] = nil
    }
    for watch in wanted {
      if !Self.folderExists(watch.path) {
        lose(watch)
      } else if running[watch] == nil {
        start(watch)
      }
    }
  }

  private func start(_ watch: Watch) {
    let root = Self.resolved(watch.path)
    guard
      let stream = FolderEventStream(
        path: root, deliver: { [weak self] events in self?.receive(events, for: watch) })
    else { return }
    running[watch] = Running(stream: stream, root: root)
    reportedMissing.remove(watch)
  }

  /// Stops watching a folder that is gone, and reports it the first time.
  /// A rescan still waiting out its quiet period is dropped with it:
  /// removing a folder reports its files too.
  private func lose(_ watch: Watch) {
    if running.removeValue(forKey: watch) != nil { debouncers[watch.project]?.cancel() }
    guard reportedMissing.insert(watch).inserted else { return }
    onMissing(watch.project, .sourceNotFound(label: watch.label, path: watch.path))
  }

  private func receive(_ events: [FolderEvent], for watch: Watch) {
    defer { onDelivery?(events.map(\.path)) }
    guard let current = running[watch] else { return }
    guard Self.folderExists(watch.path) else {
      lose(watch)
      return
    }
    var changed = false
    if events.contains(where: { $0.has(kFSEventStreamEventFlagRootChanged) }) {
      // Replaced by another folder at the same path.
      running[watch] = nil
      start(watch)
      changed = true
    }
    if changed || events.contains(where: { Self.isRelevant($0, under: current.root, watch: watch) })
    {
      debouncer(for: watch.project).noteChange()
    }
  }

  private func debouncer(for project: String) -> ScanDebouncer {
    if let debouncer = debouncers[project] { return debouncer }
    let debouncer = ScanDebouncer(clock: clock) { [weak self] in self?.fire(project) }
    debouncers[project] = debouncer
    return debouncer
  }

  private func fire(_ project: String) {
    // A folder that vanished during the quiet period is reported as
    // missing rather than scanned.
    let vanished = wanted.filter {
      $0.project == project && running[$0] != nil && !Self.folderExists($0.path)
    }
    guard vanished.isEmpty else {
      vanished.forEach(lose)
      return
    }
    onChange(project)
  }

  /// Whether an event could change what a scan of the source reads: the
  /// scanner's own exclusions and the source's patterns decide, as they do
  /// when it walks the folder.
  static func isRelevant(_ event: FolderEvent, under root: String, watch: Watch) -> Bool {
    // The system lost track of the details.
    if event.has(kFSEventStreamEventFlagMustScanSubDirs) { return true }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard event.path.hasPrefix(prefix) else { return false }
    let relative = String(event.path.dropFirst(prefix.count))
    let names = relative.split(separator: "/").map(String.init)
    guard !names.isEmpty, !names.contains(where: UsageScanner.isBuiltInExclusion) else {
      return false
    }
    if event.has(kFSEventStreamEventFlagItemIsSymlink) { return false }
    if event.has(kFSEventStreamEventFlagItemIsDir) {
      // A folder moved in or out brings no events for its files.
      return
        (event.has(kFSEventStreamEventFlagItemRenamed)
        || event.has(kFSEventStreamEventFlagItemRemoved))
        && !PathGlob.matchesAny(watch.exclude, relative)
    }
    return PathGlob.matchesAny(watch.include, relative)
      && !PathGlob.matchesAny(watch.exclude, relative)
  }

  private static func folderExists(_ path: String) -> Bool {
    ProjectSettingsModel.folderExists(path)
  }

  private static func resolved(_ path: String) -> String {
    guard let pointer = realpath(path, nil) else { return path }
    defer { free(pointer) }
    return String(cString: pointer)
  }
}
