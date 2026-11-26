import CatalogCore
import CoreServices
import Foundation
@testable import PinaxUI
import Testing

/// Real file events from folders under the test's own temporary directory;
/// the quiet period runs on a clock the test moves.
@MainActor
@Suite struct SourceWatcherTests {
  @Test("A change to a file the scan reads becomes one rescan after the quiet period")
  func changesTrigger() async throws {
    let watched = try Watched()
    defer { watched.remove() }
    try watched.write("posts/a.md")
    await eventually { watched.watcher.isPending(project: "blog") }
    watched.clock.advance(by: 2.9)
    #expect(watched.changes.isEmpty)
    watched.clock.advance(by: 0.2)
    #expect(watched.changes == ["blog"])
    #expect(!watched.watcher.isPending(project: "blog"))
  }

  @Test("Writes the scan would not read start nothing")
  func ignoredWritesDoNotTrigger() async throws {
    let watched = try Watched()
    defer { watched.remove() }
    let ignored = [
      ".git/x.md", "node_modules/x.md", "dist/x.md", "posts/.hidden.md", "drafts/x.md",
      "posts/x.txt",
    ]
    for path in ignored {
      try watched.write(path)
      await eventually { watched.delivered.contains { $0.hasSuffix("/" + path) } }
    }
    #expect(!watched.watcher.isPending(project: "blog"))
    watched.clock.advance(by: 60)
    #expect(watched.changes.isEmpty)
  }

  @Test("A folder moved or removed counts; one only made does not")
  func folderEvents() {
    let watch = SourceWatcher.Watch(
      project: "blog", label: "src", path: "/site", include: ["**/*.md"], exclude: ["drafts/**"])
    func relevant(_ path: String, _ flags: Int...) -> Bool {
      SourceWatcher.isRelevant(
        FolderEvent(path: path, flags: FSEventStreamEventFlags(flags.reduce(0, |))),
        under: "/site", watch: watch)
    }
    let directory = kFSEventStreamEventFlagItemIsDir
    #expect(relevant("/site/posts", directory, kFSEventStreamEventFlagItemRenamed))
    #expect(relevant("/site/posts", directory, kFSEventStreamEventFlagItemRemoved))
    #expect(!relevant("/site/posts", directory, kFSEventStreamEventFlagItemCreated))
    #expect(!relevant("/site/drafts", directory, kFSEventStreamEventFlagItemRenamed))
    #expect(!relevant("/site/.git", directory, kFSEventStreamEventFlagItemRenamed))
    #expect(!relevant("/site-two/a.md", kFSEventStreamEventFlagItemModified))
    #expect(relevant("/site", kFSEventStreamEventFlagMustScanSubDirs))
  }

  @Test("Quiet for three seconds fires; changes that keep coming fire thirty seconds after the first")
  func debounce() {
    let clock = ManualScanClock()
    var fired: [TimeInterval] = []
    let start = clock.now
    let debouncer = ScanDebouncer(clock: clock) { fired.append(clock.now.timeIntervalSince(start)) }
    for _ in 0..<16 {
      debouncer.noteChange()
      clock.advance(by: 2)
    }
    #expect(fired == [30])
    clock.advance(by: 10)
    #expect(fired == [30, 33], "the change at 30 s starts the next burst")
  }

  @Test("A folder that goes is reported once and not scanned; once back it is watched again")
  func missingFolder() async throws {
    let watched = try Watched()
    defer { watched.remove() }
    try watched.write("posts/a.md")
    await eventually { watched.watcher.isPending(project: "blog") }

    // Found gone by a rebuild, before any event says so.
    try FileManager.default.removeItem(at: watched.root)
    watched.watcher.update(watched.projects)
    #expect(!watched.watcher.isPending(project: "blog"))
    watched.watcher.update(watched.projects)
    watched.clock.advance(by: 60)
    #expect(watched.missing == [.sourceNotFound(label: "src", path: watched.root.path)])
    #expect(watched.changes.isEmpty)
    #expect(watched.watcher.watched.isEmpty)

    try FileManager.default.createDirectory(at: watched.root, withIntermediateDirectories: true)
    watched.watcher.update(watched.projects)
    #expect(watched.watcher.watched.count == 1)
    try FileManager.default.removeItem(at: watched.root)
    watched.watcher.update(watched.projects)
    #expect(watched.missing.count == 2, "gone again is a new report")
  }

  @Test("Turning watching off, changing the source or removing the project rebuilds the watches")
  func rebuild() throws {
    let watched = try Watched()
    defer { watched.remove() }
    #expect(watched.watcher.watched.map(\.exclude) == [["drafts/**"]])
    var project = watched.projects[0]
    project.sources[0].exclude = []
    watched.watcher.update([project])
    #expect(watched.watcher.watched.map(\.exclude) == [[]])
    project.sources.append(
      ProjectSource(label: "cms", command: "export", workingDirectory: watched.root.path))
    watched.watcher.update([project])
    #expect(watched.watcher.watched.map(\.label) == ["src"], "folders only")
    project.autoScan.watch = false
    watched.watcher.update([project])
    #expect(watched.watcher.watched.isEmpty)
    watched.watcher.update(watched.projects)
    watched.watcher.update([])
    #expect(watched.watcher.watched.isEmpty)
  }

  @MainActor
  private final class Watched {
    let directory: URL
    let root: URL
    let clock = ManualScanClock()
    private(set) var watcher: SourceWatcher!
    private(set) var changes: [String] = []
    private(set) var missing: [UsageScanError] = []
    private(set) var delivered: [String] = []
    let projects: [AutoScanProject]

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pinaxui-watch-\(UUID().uuidString)", isDirectory: true)
      root = directory.appendingPathComponent("site", isDirectory: true)
      for folder in [".git", "node_modules", "dist", "drafts", "posts"] {
        try FileManager.default.createDirectory(
          at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
      }
      projects = [
        AutoScanProject(
          slug: "blog",
          sources: [
            ProjectSource(
              label: "src", path: root.path, include: ["**/*.md"], exclude: ["drafts/**"])
          ],
          autoScan: ProjectAutoScan(watch: true), lastScanAt: nil)
      ]
      watcher = SourceWatcher(
        clock: clock, onChange: { [weak self] in self?.changes.append($0) },
        onMissing: { [weak self] _, error in self?.missing.append(error) })
      watcher.onDelivery = { [weak self] in self?.delivered += $0 }
      watcher.update(projects)
    }

    func write(_ path: String) throws {
      try Data("text".utf8).write(to: root.appendingPathComponent(path))
    }

    func remove() {
      watcher.update([])
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
