import Foundation

/// What fetching a rewrite's new URL found.
public enum TargetVerification: Equatable, Sendable {
  case ok(sha256: String)
  case mismatch(expected: String, actual: String)
  case unreachable(reason: String)
}

public protocol RewriteTargetVerifying: Sendable {
  func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification
}

/// Fetches the whole object and hashes it. Without an expected sha256, an
/// object that can be fetched is `.ok`.
public struct PublicTargetVerifier: RewriteTargetVerifying {
  public let fetcher: PublicObjectFetching

  public init(fetcher: PublicObjectFetching = URLSessionPublicObjectFetcher()) {
    self.fetcher = fetcher
  }

  public func verify(_ url: String, expectedSHA256: String?) async -> TargetVerification {
    guard let target = URL(string: url) else { return .unreachable(reason: "Not a URL: \(url)") }
    do {
      let sha = Hashing.sha256(of: try await fetcher.fetch(target).data)
      if let expectedSHA256, expectedSHA256 != sha {
        return .mismatch(expected: expectedSHA256, actual: sha)
      }
      return .ok(sha256: sha)
    } catch {
      return .unreachable(reason: String(describing: error))
    }
  }
}

public enum RewriteTargetCheck {
  public static let maximumConcurrency = 4

  /// Verifies every target, at most `maximumConcurrency` at a time, keyed
  /// by URL. Once `cancellation` is set no further target is started; the
  /// ones in flight finish and are returned. `checked` runs after each.
  public static func verify(
    _ targets: [RewriteTarget], with verifier: RewriteTargetVerifying,
    cancellation: ExternalMigrationCancellation? = nil,
    checked: (@Sendable () -> Void)? = nil
  ) async -> [String: TargetVerification] {
    await withTaskGroup(of: (String, TargetVerification).self) { group in
      var results: [String: TargetVerification] = [:]
      var pending = targets.makeIterator()
      func startNext() -> Bool {
        guard cancellation?.isCancelled != true, let target = pending.next() else { return false }
        group.addTask {
          (target.url, await verifier.verify(target.url, expectedSHA256: target.expectedSHA256))
        }
        return true
      }
      for _ in 0..<maximumConcurrency where !startNext() { break }
      while let (url, verification) = await group.next() {
        results[url] = verification
        checked?()
        _ = startNext()
      }
      return results
    }
  }
}
