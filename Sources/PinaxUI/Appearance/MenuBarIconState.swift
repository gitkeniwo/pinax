import Combine
import Foundation

/// What the menu bar item draws right now: the
/// chosen icon, an upload progress ring, the icon with an unseen-failure dot,
/// or a check after a copy. A pure function of the inputs below; the view
/// only draws the answer.
public enum MenuBarIconState: Equatable, Sendable {
  case idle(iconID: String)
  case progress(completed: Int, total: Int)
  case failureDot(iconID: String)
  case copied

  /// How long the check stays after a copy.
  public static let copyConfirmationDuration: TimeInterval = 1.5

  /// Priority when several hold at once: copied ✓ > progress ring > failure
  /// dot > the chosen icon. The ✓ is the shortest and answers what the user
  /// just did; a ring means work is in flight; the dot waits for the ring to
  /// end because the icon cannot carry both.
  public static func resolve(
    iconID: String,
    uploads: UploadCounts?,
    unseenFailures: Int,
    lastCopyAt: Date?,
    now: Date
  ) -> MenuBarIconState {
    if let lastCopyAt, now >= lastCopyAt,
      now.timeIntervalSince(lastCopyAt) < copyConfirmationDuration
    {
      return .copied
    }
    if let uploads, uploads.total > 0 {
      return .progress(completed: uploads.completed, total: uploads.total)
    }
    let id = MenuBarIconCatalog.known(iconID) ?? MenuBarIconCatalog.defaultID
    return unseenFailures > 0 ? .failureDot(iconID: id) : .idle(iconID: id)
  }

  /// The menu bar item's accessibility value; its name stays "Pinax".
  public var accessibilityValue: String {
    switch self {
    case .idle: ""
    case .progress(let completed, let total): "Uploading, \(completed) of \(total) done"
    case .failureDot: "An upload failed"
    case .copied: "Link copied"
    }
  }

  /// 0...1 for the ring.
  public var fraction: Double {
    guard case .progress(let completed, let total) = self, total > 0 else { return 0 }
    return min(1, max(0, Double(completed) / Double(total)))
  }
}

/// The batch the Drop Zone is working through: `completed` of `total`
/// uploads settled (done or failed).
public struct UploadCounts: Equatable, Sendable {
  public var completed: Int
  public var total: Int

  public init(completed: Int, total: Int) {
    self.completed = completed
    self.total = total
  }
}

/// The live inputs behind `MenuBarIconState`: upload counts, failures the
/// user has not looked at yet, and the last copy. "Looked at" = the Drop Zone
/// window appeared again from hidden, or the menu bar panel opened
/// (`markFailuresSeen`). Every failure counts, including one that lands
/// while the Drop Zone is already on screen. The clock and the ✓ timer are seams so tests
/// neither sleep nor wait.
@MainActor
public final class MenuBarActivity: ObservableObject {
  @Published public private(set) var uploads: UploadCounts?
  @Published public private(set) var unseenFailures = 0
  @Published public private(set) var lastCopyAt: Date?

  private let clock: @MainActor () -> Date
  private let scheduler: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> @MainActor () -> Void
  private var cancelExpiry: (@MainActor () -> Void)?

  public init(
    clock: @escaping @MainActor () -> Date = { Date() },
    scheduler: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) ->
      @MainActor () -> Void = MenuBarActivity.sleepingScheduler
  ) {
    self.clock = clock
    self.scheduler = scheduler
  }

  public func state(iconID: String) -> MenuBarIconState {
    MenuBarIconState.resolve(
      iconID: iconID, uploads: uploads, unseenFailures: unseenFailures,
      lastCopyAt: lastCopyAt, now: clock())
  }

  public func setUploads(_ counts: UploadCounts?) {
    if uploads != counts { uploads = counts }
  }

  /// A card failed.
  public func noteFailure() {
    unseenFailures += 1
  }

  public func markFailuresSeen() {
    if unseenFailures != 0 { unseenFailures = 0 }
  }

  /// A link or markdown went to the clipboard: show the ✓, then draw again
  /// once it has run out.
  public func noteCopy() {
    lastCopyAt = clock()
    cancelExpiry?()
    cancelExpiry = scheduler(MenuBarIconState.copyConfirmationDuration) { [weak self] in
      self?.objectWillChange.send()
    }
  }

  nonisolated public static func sleepingScheduler(
    _ delay: TimeInterval, _ action: @escaping @MainActor () -> Void
  ) -> @MainActor () -> Void {
    let task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      action()
    }
    return { task.cancel() }
  }
}
