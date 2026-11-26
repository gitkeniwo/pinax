import AppKit
import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import Testing

@MainActor
@Suite struct ScanSchedulerTests {
  @Test("Hourly and daily are due a whole interval after the last scan")
  func dueAfterAnInterval() {
    for (schedule, interval) in [(ProjectAutoScan.Schedule.hourly, 3600.0), (.daily, 86400.0)] {
      let early = Scheduled(schedule, lastScanAgo: interval - 60)
      early.scheduler.check(reason: .schedule)
      #expect(early.due.isEmpty)
      let late = Scheduled(schedule, lastScanAgo: interval + 60)
      late.scheduler.check(reason: .schedule)
      #expect(late.due == [.schedule])
    }
  }

  @Test("Off, or no sources, is never due; never scanned is due at once")
  func offAndNeverScanned() {
    let off = Scheduled(.off, lastScanAgo: nil)
    off.scheduler.start()
    off.clock.advance(by: 2 * 86400)
    #expect(off.due.isEmpty)
    let empty = Scheduled(.hourly, lastScanAgo: nil)
    empty.project.sources = []
    empty.scheduler.start()
    #expect(empty.due.isEmpty)
    let fresh = Scheduled(.daily, lastScanAgo: nil)
    fresh.scheduler.start()
    #expect(fresh.due == [.schedule])
  }

  @Test("The start checks once, then every five minutes")
  func checksWhileRunning() {
    let scheduled = Scheduled(.hourly, lastScanAgo: 56 * 60)
    scheduled.scheduler.start()
    scheduled.clock.advance(by: 4 * 60)
    #expect(scheduled.due.isEmpty)
    scheduled.clock.advance(by: 60)
    #expect(scheduled.due == [.schedule])
  }

  @Test("Five hours asleep are made up once, on waking")
  func missedScansAreMadeUpOnce() {
    let scheduled = Scheduled(.hourly, lastScanAgo: 60)
    scheduled.scheduler.start()
    scheduled.clock.sleep(for: 5 * 3600)
    scheduled.wake.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(scheduled.due == [.wake])
    scheduled.wake.post(name: NSWorkspace.didWakeNotification, object: nil)
    scheduled.clock.advance(by: 10 * 60)
    #expect(scheduled.due == [.wake])
  }

  @Test("A scan the user ran puts the next one off")
  func manualScanPostpones() {
    let scheduled = Scheduled(.hourly, lastScanAgo: 50 * 60)
    scheduled.scheduler.start()
    scheduled.clock.advance(by: 5 * 60)
    scheduled.project.lastScanAt = scheduled.clock.now
    scheduled.clock.advance(by: 55 * 60)
    #expect(scheduled.due.isEmpty)
    scheduled.clock.advance(by: 5 * 60)
    #expect(scheduled.due.count == 1)
  }

  @Test("After a failure, which leaves the last scan as it was, the next try waits a full interval")
  func failureWaitsAnInterval() {
    let scheduled = Scheduled(.hourly, lastScanAgo: 2 * 3600)
    scheduled.scheduler.start()
    #expect(scheduled.due.count == 1)
    scheduled.clock.advance(by: 5 * 60)
    #expect(scheduled.due.count == 1)
    scheduled.clock.advance(by: 54 * 60)
    #expect(scheduled.due.count == 1)
    scheduled.clock.advance(by: 60)
    #expect(scheduled.due.count == 2)
  }

  @Test("The last scan's time is read from the catalog")
  func loadsLastScanTime() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try AutoScanProject.load(from: database).allSatisfy { $0.lastScanAt == nil })
    let when = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try CatalogUsage.sync(
      UsageDocument(project: "blog", sourceRevision: nil, coverage: [], refs: []),
      project: "blog", in: database, now: when)
    let blog = try AutoScanProject.load(from: database).first { $0.slug == "blog" }
    #expect(blog?.lastScanAt == when)
  }

  @MainActor
  private final class Scheduled {
    let clock = ManualScanClock()
    let wake = NotificationCenter()
    var project: AutoScanProject
    private(set) var due: [UsageAutoScanReason] = []
    private(set) var scheduler: ScanScheduler!

    init(_ schedule: ProjectAutoScan.Schedule, lastScanAgo: TimeInterval?) {
      project = AutoScanProject(
        slug: "blog", sources: [ProjectSource(label: "src", path: "/nowhere")],
        autoScan: ProjectAutoScan(schedule: schedule), lastScanAt: nil)
      project.lastScanAt = lastScanAgo.map { clock.now.addingTimeInterval(-$0) }
      scheduler = ScanScheduler(
        clock: clock, wakeNotifications: wake,
        projects: { [weak self] in self.map { [$0.project] } ?? [] },
        onDue: { [weak self] _, reason in self?.due.append(reason) })
    }
  }
}
