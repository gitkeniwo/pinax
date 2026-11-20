import Foundation
@testable import PinaxUI
import Testing

/// The menu bar icon's state. The state is a pure
/// function of (upload counts, unseen failures, last copy, chosen icon, now);
/// the real menu bar item is never created, the clock and the ✓ timer are
/// injected, nothing sleeps and the real pasteboard is never written.
@MainActor
@Suite struct MenuBarIconStateTests {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)

  // MARK: - The pure function

  @Test("Nothing going on shows the chosen icon; an unknown id shows Tablet")
  func idle() {
    for icon in MenuBarIconCatalog.icons {
      #expect(resolve(icon: icon.id) == .idle(iconID: icon.id), "\(icon.id)")
    }
    #expect(resolve(icon: "retired") == .idle(iconID: "tablet"))
  }

  @Test("Uploads show a ring with completed / total; nothing pending shows no ring")
  func progress() {
    #expect(resolve(uploads: UploadCounts(completed: 2, total: 5)) == .progress(completed: 2, total: 5))
    #expect(resolve(uploads: UploadCounts(completed: 0, total: 1)).fraction == 0)
    #expect(resolve(uploads: UploadCounts(completed: 2, total: 5)).fraction == 0.4)
    #expect(resolve(uploads: nil) == .idle(iconID: "tablet"))
    #expect(resolve(uploads: UploadCounts(completed: 0, total: 0)) == .idle(iconID: "tablet"))
  }

  @Test("An unseen failure puts the dot on the chosen icon; none, no dot")
  func failureDot() {
    #expect(resolve(icon: "aten", failures: 1) == .failureDot(iconID: "aten"))
    #expect(resolve(icon: "aten", failures: 3) == .failureDot(iconID: "aten"))
    #expect(resolve(icon: "aten", failures: 0) == .idle(iconID: "aten"))
  }

  @Test("The ✓ lasts 1.5 s from the copy and not a moment longer")
  func copiedWindow() {
    #expect(MenuBarIconState.copyConfirmationDuration == 1.5)
    #expect(resolve(copy: t0, now: t0) == .copied)
    #expect(resolve(copy: t0, now: t0.addingTimeInterval(1.49)) == .copied)
    #expect(resolve(copy: t0, now: t0.addingTimeInterval(1.5)) == .idle(iconID: "tablet"))
    #expect(resolve(copy: t0, now: t0.addingTimeInterval(60)) == .idle(iconID: "tablet"))
    #expect(resolve(copy: t0.addingTimeInterval(5), now: t0) == .idle(iconID: "tablet"))
  }

  @Test("Priority is ✓ > ring > failure dot > chosen icon, every combination")
  func priority() {
    let ring = UploadCounts(completed: 1, total: 3)
    #expect(resolve(uploads: ring, failures: 2, copy: t0, now: t0) == .copied)
    #expect(resolve(uploads: ring, copy: t0, now: t0) == .copied)
    #expect(resolve(failures: 2, copy: t0, now: t0) == .copied)
    #expect(resolve(uploads: ring, failures: 2) == .progress(completed: 1, total: 3))
    #expect(resolve(failures: 2) == .failureDot(iconID: "tablet"))
    // The ✓ ends: back to the ring, then the dot, then the icon.
    let later = t0.addingTimeInterval(2)
    #expect(resolve(uploads: ring, failures: 2, copy: t0, now: later) == .progress(completed: 1, total: 3))
    #expect(resolve(failures: 2, copy: t0, now: later) == .failureDot(iconID: "tablet"))
    #expect(resolve(copy: t0, now: later) == .idle(iconID: "tablet"))
  }

  @Test("The accessibility value names the state; idle has none")
  func accessibilityValues() {
    #expect(MenuBarIconState.idle(iconID: "tablet").accessibilityValue == "")
    #expect(MenuBarIconState.progress(completed: 2, total: 5).accessibilityValue == "Uploading, 2 of 5 done")
    #expect(MenuBarIconState.failureDot(iconID: "tablet").accessibilityValue == "An upload failed")
    #expect(MenuBarIconState.copied.accessibilityValue == "Link copied")
  }

  // MARK: - The activity model: injected clock and timer

  @Test("The ✓ falls back after 1.5 s on the injected clock, and the label redraws then")
  func copyConfirmationExpires() {
    let clock = IconClock(t0)
    let timer = IconTimer()
    let activity = MenuBarActivity(clock: { clock.now }, scheduler: timer.schedule)
    var redraws = 0
    let token = activity.objectWillChange.sink { redraws += 1 }
    defer { token.cancel() }

    activity.noteCopy()
    #expect(activity.state(iconID: "tablet") == .copied)
    #expect(timer.delays == [1.5])
    clock.now = t0.addingTimeInterval(1.4)
    #expect(activity.state(iconID: "tablet") == .copied)

    clock.now = t0.addingTimeInterval(1.5)
    let before = redraws
    timer.fireLast()
    #expect(redraws == before + 1)
    #expect(activity.state(iconID: "tablet") == .idle(iconID: "tablet"))
  }

  @Test("A second copy restarts the 1.5 s and cancels the first timer")
  func secondCopyRestarts() {
    let clock = IconClock(t0)
    let timer = IconTimer()
    let activity = MenuBarActivity(clock: { clock.now }, scheduler: timer.schedule)
    activity.noteCopy()
    clock.now = t0.addingTimeInterval(1)
    activity.noteCopy()
    #expect(timer.cancelled == [0])
    clock.now = t0.addingTimeInterval(2)  // 1 s after the second copy
    #expect(activity.state(iconID: "tablet") == .copied)
    clock.now = t0.addingTimeInterval(2.5)
    #expect(activity.state(iconID: "tablet") == .idle(iconID: "tablet"))
  }

  @Test("Seen = the drop zone or the panel was opened; the dot goes and stays gone")
  func failuresAreSeen() {
    let activity = MenuBarActivity(clock: { self.t0 }, scheduler: IconTimer().schedule)
    activity.noteFailure()
    activity.noteFailure()
    #expect(activity.state(iconID: "tablet") == .failureDot(iconID: "tablet"))
    activity.markFailuresSeen()
    #expect(activity.state(iconID: "tablet") == .idle(iconID: "tablet"))
    activity.markFailuresSeen()
    #expect(activity.unseenFailures == 0)
  }

  // MARK: - The drop zone feeds it, through the app's own wiring

  @Test("A failed upload in the app's drop zone puts the dot up, even with the zone visible; re-showing the zone takes it down; the ring ends with the batch")
  func appWiring() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try makeDefaults(), databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    await app.start()
    let zone = try #require(app.dropZone).model
    let activity = app.menuBarActivity
    #expect(activity.state(iconID: "tablet") == .idle(iconID: "tablet"))

    let missing = directory.appendingPathComponent("not-there.png")
    zone.drop(fileURLs: [missing])
    #expect(zone.cards.first?.phase.isPending == true)
    #expect(activity.uploads == UploadCounts(completed: 0, total: 1))
    await waitUntil { zone.cards.allSatisfy { !$0.phase.isPending } }
    #expect(activity.uploads == nil)
    guard case .failed = zone.cards[0].phase else {
      Issue.record("the missing file must fail, got \(zone.cards[0].phase)")
      return
    }
    // Every failure counts, even one that lands while the zone is on
    // screen: the dot shows.
    #expect(zone.isWindowVisible)
    #expect(activity.unseenFailures == 1)
    #expect(activity.state(iconID: "tablet") == .failureDot(iconID: "tablet"))

    // Refreshes while the zone stays visible are not a fresh look.
    zone.revealOnDemand()
    zone.dragDidEnd()
    #expect(activity.state(iconID: "tablet") == .failureDot(iconID: "tablet"))

    // The zone appearing again from hidden is the look: the dot goes.
    zone.dismiss()
    #expect(!zone.isWindowVisible)
    #expect(activity.state(iconID: "tablet") == .failureDot(iconID: "tablet"))
    zone.revealOnDemand()
    #expect(activity.state(iconID: "tablet") == .idle(iconID: "tablet"))
  }

  @Test("The app model installs the clipboard hook that shows the ✓; Clipboard.copy calls it")
  func clipboardHook() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = PinaxAppModel(
      dockIcon: inertDockIcon,
      defaults: try makeDefaults(), databaseOpener: { database }, chooseSourceFolder: { _ in nil })
    let hook = try #require(Clipboard.onCopy)
    #expect(app.menuBarActivity.lastCopyAt == nil)
    hook()  // what Clipboard.copy runs after its write; the real pasteboard is not touched
    #expect(app.menuBarActivity.state(iconID: "tablet") == .copied)

    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PinaxUI/AppLifecycle/PasteboardUploads.swift"),
      encoding: .utf8)
    let copy = try #require(source.range(of: "static func copy"))
    #expect(source[copy.upperBound...].contains("onCopy?()"))
  }

  @Test("The App scene passes the live activity to the label; opening the panel counts as a look at the panel's own refresh point, not .onAppear")
  func sceneWiring() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PinaxApp/PinaxApp/PinaxAppApp.swift"),
      encoding: .utf8)
    #expect(source.contains("activity: app.menuBarActivity"))
    #expect(!source.contains(".onAppear"))
    #expect(!source.contains("markFailuresSeen"))
  }

  // MARK: - Helpers

  private func resolve(
    icon: String = "tablet", uploads: UploadCounts? = nil, failures: Int = 0,
    copy: Date? = nil, now: Date? = nil
  ) -> MenuBarIconState {
    MenuBarIconState.resolve(
      iconID: icon, uploads: uploads, unseenFailures: failures, lastCopyAt: copy,
      now: now ?? t0)
  }

  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "pinaxui-menubar-state-\(UUID().uuidString)"))
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

@MainActor
private final class IconClock {
  var now: Date
  init(_ now: Date) { self.now = now }
}

@MainActor
private final class IconTimer {
  private(set) var delays: [TimeInterval] = []
  private(set) var cancelled: [Int] = []
  private var actions: [@MainActor () -> Void] = []

  var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    { [self] delay, action in
      let index = actions.count
      delays.append(delay)
      actions.append(action)
      return { self.cancelled.append(index) }
    }
  }

  func fireLast() { actions.last?() }
}
