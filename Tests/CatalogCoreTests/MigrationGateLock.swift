import Foundation
import Testing

/// `ExternalMigration` lets one migration run at a time in the process,
/// and `swift test` runs every target's suites in one process,
/// in parallel. Suites that run real migrations take this trait so they
/// run one after another: it holds an exclusive `flock` on a file named
/// for the process for the suite's whole run. A file, not a Swift lock,
/// because the suites live in different test targets (CatalogCoreTests'
/// and PinaxUITests' copies of this file must stay the same).
struct MigrationGateLock: SuiteTrait, TestScoping {
  func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    test.isSuite ? self : nil
  }

  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinax-migration-gate-\(getpid()).lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    precondition(fd >= 0, "cannot open \(path)")
    defer { close(fd) }
    // Off the cooperative pool: the wait blocks its thread.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      Thread.detachNewThread {
        flock(fd, LOCK_EX)
        done.resume()
      }
    }
    defer { flock(fd, LOCK_UN) }
    try await function()
  }
}

extension Trait where Self == MigrationGateLock {
  /// Runs the suite while no other migration suite does.
  static var migrationGate: Self { MigrationGateLock() }
}
