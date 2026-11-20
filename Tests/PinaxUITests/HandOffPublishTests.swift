import Combine
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// Publishing a hand-off. The rows that leave the surface go from `rows`
/// in the same synchronous step as the hand-off, before the reload — no
/// frame shows the selection on the next image while the one that left is
/// still drawn. The Edit / View menu items take computed values from
/// `PinaxCommands`, so a model change reaches them as a changed input.
/// Fixtures are `SelectionHandOffTests`' (PicGo imports, a remote that
/// throws and counts, host `t28.invalid`).
@MainActor
@Suite struct HandOffPublishTests {
  let base = SelectionHandOffTests()

  /// Every `rows` / `selectedIDs` publish as the pair the next frame could
  /// draw (`@Published` emits in willSet: the emitted value is the new one,
  /// the rest of the model is as it stands), and the pair standing when the
  /// reload starts (`isAwaitingRows` turning true).
  @MainActor final class Recorder {
    struct Frame: Equatable {
      let rows: [Int64]
      let selection: Set<Int64>
    }
    var frames: [Frame] = []
    var atReload: Frame?
    private var bag: Set<AnyCancellable> = []

    init(_ model: GalleryModel) {
      model.$rows.dropFirst().sink { [unowned self, unowned model] rows in
        MainActor.assumeIsolated {
          frames.append(Frame(rows: rows.map(\.id), selection: model.selectedIDs))
        }
      }.store(in: &bag)
      model.$selectedIDs.dropFirst().sink { [unowned self, unowned model] selection in
        MainActor.assumeIsolated {
          frames.append(Frame(rows: model.rows.map(\.id), selection: selection))
        }
      }.store(in: &bag)
      model.$isAwaitingRows.dropFirst().sink { [unowned self, unowned model] awaiting in
        MainActor.assumeIsolated {
          guard awaiting, atReload == nil else { return }
          atReload = Frame(rows: model.rows.map(\.id), selection: model.selectedIDs)
        }
      }.store(in: &bag)
    }

    /// "The selection has moved on while the image that left is still in
    /// the rows" — the jump the user saw.
    func jumps(leaving removed: Int64) -> [Frame] {
      frames.filter { $0.selection != [removed] && $0.rows.contains(removed) }
    }
  }

  /// One curation step: before the reload starts, the image that left is
  /// out of `rows` and the next one holds the selection; no published pair
  /// in between shows the hand-off with the old row.
  func expectOneStep(
    _ model: GalleryModel, removing removed: Int64, handingTo next: Int64,
    _ action: () async throws -> Void
  ) async throws {
    let recorder = Recorder(model)
    try await action()
    let atReload = try #require(recorder.atReload, "the action reloads")
    #expect(!atReload.rows.contains(removed), "the row left before the reload")
    #expect(atReload.selection == [next], "the hand-off is in place before the reload")
    #expect(recorder.jumps(leaving: removed) == [], "\(recorder.frames)")
    #expect(model.selectedIDs == [next])
    #expect(!model.rows.contains { $0.id == removed })
  }

  @Test("⌘⌫ on All: the archived row goes and the next is selected in one step, before the reload")
  func archiveInOneStep() async throws {
    let f = try base.makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await base.show(.all, model)
    // Display order 4 3 2 1 0.
    for (index, next) in [(2, 1), (1, 0), (0, 3)] {
      let removed = try base.rowID(index, model)
      model.select(try #require(model.rows.first { $0.id == removed }))
      try await expectOneStep(model, removing: removed, handingTo: try base.rowID(next, model)) {
        await model.archiveOrPutBackFromCommand()
      }
    }
  }

  @Test("⌘⌫ on Archived (Put Back): the row goes and the next is selected in one step")
  func putBackInOneStep() async throws {
    let f = try base.makeFixture(archived: [0, 1, 2, 3, 4])
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await base.show(.archived, model)
    let removed = try base.rowID(3, model)
    model.select(try #require(model.rows.first { $0.id == removed }))
    try await expectOneStep(model, removing: removed, handingTo: try base.rowID(2, model)) {
      await model.archiveOrPutBackFromCommand()
    }
  }

  @Test("⌥⌘⌫ then Delete: the row goes and the next is selected in one step; nothing reaches a bucket")
  func deleteInOneStep() async throws {
    let f = try base.makeFixture(archived: [0, 1, 2, 3, 4])
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await base.show(.archived, model)
    let removed = try base.rowID(2, model)
    model.select(try #require(model.rows.first { $0.id == removed }))
    await model.deletePermanentlyFromCommand()
    let pending = try #require(model.pendingDeletion)
    try await expectOneStep(model, removing: removed, handingTo: try base.rowID(1, model)) {
      await model.confirmDeletion(pending)
    }
    #expect(f.remoteCalls.value == 0)
  }

  // MARK: - Menu items

  /// The item's stored inputs as SwiftUI compares them to decide whether
  /// its body runs again: a class by identity, a value by its description;
  /// closures are left out (they never compare equal, and carry no state).
  func inputs(_ item: Any) -> [String] {
    Mirror(reflecting: item).children.compactMap { child in
      var value = child.value
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .optional {
        guard let wrapped = mirror.children.first?.value else { return "\(child.label ?? ""): nil" }
        value = wrapped
      }
      if String(describing: type(of: value)).contains("->") { return nil }
      if Mirror(reflecting: value).displayStyle == .class {
        return "\(child.label ?? ""): \(ObjectIdentifier(value as AnyObject))"
      }
      return "\(child.label ?? ""): \(value)"
    }
  }

  @Test("A model change from not-deletable to deletable changes Delete Permanently…'s inputs")
  func deleteItemInputsFollowTheModel() async throws {
    let f = try base.makeFixture(archived: [4])
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    await base.show(.all, model)
    model.select(model.rows[0])
    #expect(!model.canDeleteSelectionPermanently)
    let before = inputs(PinaxCommands.deleteItems(model))

    await base.show(.archived, model)
    model.select(model.rows[0])
    #expect(model.canDeleteSelectionPermanently)
    let after = inputs(PinaxCommands.deleteItems(model))
    #expect(before != after, "the same inputs: SwiftUI keeps the disabled item (\(before))")
  }

  @Test("Reaching the grid's big end changes Make Bigger's inputs")
  func sizeItemInputsFollowTheModel() async throws {
    let f = try base.makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    #expect(model.canMakeBigger)
    let before = inputs(PinaxCommands.sizeItems(model))
    for _ in 0..<12 where model.canMakeBigger { model.makeBigger() }
    let after = inputs(PinaxCommands.sizeItems(model))
    #expect(before != after, "the same inputs: SwiftUI keeps Make Bigger enabled (\(before))")
  }

  @Test("Delete Permanently…'s inputs from PinaxCommands: on for Archived with an archived selection; off elsewhere, with nothing selected, and while deleting")
  func deleteItemValues() async throws {
    let f = try base.makeFixture(archived: [3, 4])
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()
    let isItem: (Any) -> Bool = { "\($0)".contains("\"Delete Permanently…\"") }

    #expect(PinaxCommands.deleteItems(nil).isEnabled == false, "no window")

    await base.show(.all, model)
    model.select(model.rows[0])
    let off = PinaxCommands.deleteItems(model)
    #expect(off.isEnabled == false, "not Archived")
    #expect(buttonIsEnabled(in: off.body, label: isItem) == false)

    await base.show(.archived, model)
    model.clearSelection()
    #expect(PinaxCommands.deleteItems(model).isEnabled == false, "nothing selected")
    model.select(model.rows[0])
    let on = PinaxCommands.deleteItems(model)
    #expect(on.isEnabled == true, "Archived, an archived selection")
    #expect(buttonIsEnabled(in: on.body, label: isItem) == true)

    // While a delete runs: read at the rows publish inside `confirmDeletion`
    // (Archived, the archived row still selected, `isDeleting` set).
    var whileDeleting: [Bool] = []
    let watch = model.$rows.dropFirst().sink { _ in
      MainActor.assumeIsolated {
        whileDeleting.append(PinaxCommands.deleteItems(model).isEnabled)
      }
    }
    // Through the item's own action: it opens the confirmation.
    await on.deletePermanently()
    let pending = try #require(model.pendingDeletion)
    await model.confirmDeletion(pending)
    watch.cancel()
    #expect(!whileDeleting.isEmpty && whileDeleting.allSatisfy { !$0 }, "\(whileDeleting)")
    #expect(PinaxCommands.deleteItems(model).isEnabled == true, "done: the next one is ready")
    #expect(f.remoteCalls.value == 0)
  }

  @Test("Make Bigger / Make Smaller's inputs from PinaxCommands follow the ladder's ends")
  func sizeItemValues() async throws {
    let f = try base.makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let model = f.model
    await model.loadInitialData()

    let none = PinaxCommands.sizeItems(nil)
    #expect(!none.canMakeBigger && !none.canMakeSmaller, "no window")

    var items = PinaxCommands.sizeItems(model)
    #expect(items.canMakeBigger && items.canMakeSmaller)
    items.makeBigger()
    for _ in 0..<12 where model.canMakeBigger { PinaxCommands.sizeItems(model).makeBigger() }
    items = PinaxCommands.sizeItems(model)
    #expect(!items.canMakeBigger && items.canMakeSmaller, "the big end")
    for _ in 0..<12 where model.canMakeSmaller { PinaxCommands.sizeItems(model).makeSmaller() }
    items = PinaxCommands.sizeItems(model)
    #expect(items.canMakeBigger && !items.canMakeSmaller, "the small end")

    model.viewMode = .table
    items = PinaxCommands.sizeItems(model)
    #expect(items.canMakeBigger == model.canMakeBigger)
    #expect(items.canMakeSmaller == model.canMakeSmaller)
    for _ in 0..<12 where model.canMakeBigger { PinaxCommands.sizeItems(model).makeBigger() }
    #expect(!PinaxCommands.sizeItems(model).canMakeBigger, "the table's big end")
  }
}
