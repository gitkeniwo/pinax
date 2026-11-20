import CatalogCore
import Combine
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// A sidebar switch moves the jump bar, the title area and
/// the centre column together. Until the new place's rows are here all three
/// keep drawing the old place (the sidebar's highlight moves at once); then
/// everything changes in one step, never the new layout over the old rows.
/// The reload is held by a GRDB barrier, so "before the rows arrive" is a
/// real state of the running model, not a guess about timing.
@MainActor
@Suite struct SwitchCommitTests {
  typealias Place = NavigationHistory.Place

  /// What the centre column, the jump bar and the title area draw.
  struct Drawn: Equatable, CustomStringConvertible {
    let place: Place
    let rows: [Int64]
    let totals: [String: Int]
    let count: Int?
    var description: String { "\(place.selection) rows \(rows) totals \(totals) count \(String(describing: count))" }
  }

  /// Every publish of the drawn state, and the state at every run-loop pass
  /// (where AppKit draws a frame).
  final class Recorder {
    var published: [Drawn] = []
    var frames: [Drawn] = []
    private var bag: Set<AnyCancellable> = []
    private var observer: CFRunLoopObserver?

    @MainActor init(_ model: GalleryModel) {
      func drawn(place: Place? = nil, rows: [GalleryModel.Row]? = nil, totals: [String: Int]? = nil)
        -> Drawn
      {
        Drawn(
          place: place ?? model.shownPlace, rows: (rows ?? model.rows).map(\.id),
          totals: totals ?? model.monthTotals, count: model.totalCount)
      }
      // `@Published` emits in willSet: the emitted value is the new one, the
      // rest of the model is as it stands at that moment.
      model.$rows.dropFirst().sink { [unowned self] in published.append(drawn(rows: $0)) }
        .store(in: &bag)
      model.$shownPlace.dropFirst().sink { [unowned self] in published.append(drawn(place: $0)) }
        .store(in: &bag)
      model.$monthTotals.dropFirst().sink { [unowned self] in published.append(drawn(totals: $0)) }
        .store(in: &bag)
      let observer = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
      ) { [unowned self] _, _ in
        MainActor.assumeIsolated { self.frames.append(drawn()) }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      self.observer = observer
    }

    func stop() {
      if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
      observer = nil
      bag.removeAll()
    }
  }

  /// Holds every read of the catalog until `open()`: a reload started while
  /// it is closed waits at its first query.
  final class ReadGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func close(_ database: DatabasePool) {
      Thread.detachNewThread { [self] in
        try? database.barrierWriteWithoutTransaction { _ in
          entered.signal()
          released.wait()
        }
      }
      entered.wait()
    }

    func open() { released.signal() }
  }

  struct Fixture {
    let model: GalleryModel
    let database: DatabasePool
    let directory: URL
    /// Row ids per place, as the reload shows them.
    let all: [Int64]
    let archived: [Int64]
    let september: [Int64]
  }

  /// Three active images in August and three in September, two archived in
  /// October. All groups by month; Archived and a month do not.
  func makeFixture() async throws -> Fixture {
    let (database, directory) = try makeUITestDatabase()
    for index in 0..<8 {
      let month = index < 3 ? 8 : index < 6 ? 9 : 10
      try seedAsset(
        database, index: index,
        uploadedAt: String(format: "2026-%02d-%02dT12:00:00Z", month, 1 + index), key: "t29/\(index).png")
    }
    try await database.write { db in
      try db.execute(sql: "UPDATE asset SET state = 'archived' WHERE key IN ('t29/6.png', 't29/7.png')")
    }
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
      fetcher: { _ in throw URLError(.unsupportedURL) })
    let model = GalleryModel(catalog: ReadOnlyCatalog(database: database), thumbnails: thumbnails)
    await model.loadInitialData()
    let all = model.rows.map(\.id)
    model.select(.archived, in: .library)
    await model.reload()
    let archived = model.rows.map(\.id)
    model.select(.month("2026-09"), in: .time)
    await model.reload()
    let september = model.rows.map(\.id)
    model.select(.all, in: .library)
    await model.reload()
    #expect(all.count == 6 && archived.count == 2 && september.count == 3)
    #expect(model.rows.map(\.id) == all && model.shownSelection == .all)
    return Fixture(
      model: model, database: database, directory: directory, all: all, archived: archived,
      september: september)
  }

  nonisolated func pumpRunLoop(until date: Date) {
    RunLoop.main.run(until: date)
  }

  func spin(_ seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      pumpRunLoop(until: Date().addingTimeInterval(0.02))
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  /// The jump bar's path and the title area, through the views' own reads.
  func chrome(_ model: GalleryModel) -> (path: [String], title: WindowTitle) {
    (JumpBar(model: model).path.map(\.id), GalleryView(model: model).windowTitle)
  }

  @Test("Before the new rows arrive the old place is drawn; then all of it changes at once")
  func switchCommitsInOneStep() async throws {
    let f = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    let oldChrome = chrome(model)
    let oldTotals = model.monthTotals
    #expect(oldTotals == ["2026-08": 3, "2026-09": 3])
    #expect(model.showsRowsByMonth && model.totalCount == 6)

    let recorder = Recorder(model)
    defer { recorder.stop() }
    let gate = ReadGate()
    gate.close(f.database)
    model.select(.archived, in: .library)
    let reload = Task { await model.reload() }
    await spin(0.15)

    // The sidebar moved; nothing the centre column draws did.
    #expect(model.sidebarSelection == .archived)
    #expect(model.shownSelection == .all)
    #expect(model.rows.map(\.id) == f.all)
    #expect(model.monthTotals == oldTotals)
    #expect(model.totalCount == 6)
    #expect(model.showsRowsByMonth, "still All's month sections")
    #expect(chrome(model).path == oldChrome.path)
    #expect(chrome(model).title == oldChrome.title)
    #expect(!model.showsEmptyAssets)
    #expect(!model.showsLoadingActivity, "no spinner before the slow-switch delay")

    gate.open()
    await reload.value
    await spin(0.05)

    #expect(model.shownSelection == .archived)
    #expect(model.rows.map(\.id) == f.archived)
    #expect(model.monthTotals.isEmpty)
    #expect(model.totalCount == 2)
    #expect(!model.showsRowsByMonth)
    #expect(chrome(model).path != oldChrome.path)
    #expect(chrome(model).title != oldChrome.title)

    let new = Place(.library, .archived)
    let old = Place(.library, .all)
    // No publish ever pairs the new place with the old rows.
    #expect(!recorder.published.isEmpty)
    for state in recorder.published {
      #expect(!(state.place == new && state.rows == f.all), "\(state)")
    }
    // Every frame is wholly the old place or wholly the new one.
    #expect(!recorder.frames.isEmpty, "the run loop drew frames")
    let oldDrawn = Drawn(place: old, rows: f.all, totals: oldTotals, count: 6)
    let newDrawn = Drawn(place: new, rows: f.archived, totals: [:], count: 2)
    for frame in recorder.frames {
      #expect(frame == oldDrawn || frame == newDrawn, "\(frame)")
    }
    #expect(recorder.frames.first == oldDrawn && recorder.frames.last == newDrawn)
  }

  @Test("Past the slow-switch delay the status bar spins; the old rows stay up")
  func slowSwitchSpinsWithoutClearing() async throws {
    let f = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    let gate = ReadGate()
    gate.close(f.database)
    model.select(.archived, in: .library)
    let reload = Task { await model.reload() }
    await spin(0.2)
    #expect(!model.showsLoadingActivity, "inside 300 ms: no spinner")
    // Past the delay — waited for, not timed: the parallel suite is slow.
    let deadline = Date().addingTimeInterval(10)
    while !model.showsLoadingActivity && Date() < deadline { await spin(0.05) }

    #expect(model.showsLoadingActivity, "past 300 ms: the spinner")
    #expect(model.shownSelection == .all)
    #expect(model.rows.map(\.id) == f.all, "the centre column is not cleared")

    gate.open()
    await reload.value
    #expect(!model.showsLoadingActivity)
    #expect(model.shownSelection == .archived)
  }

  @Test("A → B → C in a row: C lands; B's rows and place are never published")
  func onlyTheLastSwitchLands() async throws {
    let f = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    let recorder = Recorder(model)
    defer { recorder.stop() }
    let gate = ReadGate()
    gate.close(f.database)
    model.select(.archived, in: .library)
    let toB = Task { await model.reload() }
    await spin(0.05)
    model.select(.month("2026-09"), in: .time)
    let toC = Task { await model.reload() }
    await spin(0.05)
    #expect(model.shownSelection == .all)

    gate.open()
    await toB.value
    await toC.value
    await spin(0.05)

    #expect(model.shownPlace == Place(.time, .month("2026-09")))
    #expect(model.rows.map(\.id) == f.september)
    #expect(!model.showsRowsByMonth)
    for state in recorder.published {
      #expect(state.rows != f.archived, "B's rows: \(state)")
      #expect(state.place.selection != .archived, "B's place: \(state)")
    }
    for frame in recorder.frames {
      #expect(frame.rows == f.all || frame.rows == f.september, "\(frame)")
    }
  }

  @Test("A reload that fails leaves the old place drawn and reports the error as before")
  func failedSwitchKeepsTheOldPlace() async throws {
    let f = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    let oldChrome = chrome(model)
    try await f.database.write { db in
      try db.execute(sql: "ALTER TABLE asset RENAME TO asset_t29")
    }
    model.select(.archived, in: .library)
    await model.reload()

    #expect(model.errorMessage != nil, "the failure is reported")
    #expect(model.shownSelection == .all)
    #expect(model.rows.map(\.id) == f.all)
    #expect(model.showsRowsByMonth)
    #expect(chrome(model).path == oldChrome.path && chrome(model).title == oldChrome.title)
    #expect(!model.showsLoadingActivity)

    // Once the catalog answers again the switch lands, error cleared.
    try await f.database.write { db in
      try db.execute(sql: "ALTER TABLE asset_t29 RENAME TO asset")
    }
    await model.reload()
    #expect(model.errorMessage == nil)
    #expect(model.shownSelection == .archived)
    #expect(model.rows.map(\.id) == f.archived)
  }
}
