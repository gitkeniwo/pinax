import CatalogCore
import CryptoKit
import Foundation

/// Which source commands have been allowed to run on this Mac. A command
/// travels with the catalog, so the answer lives in this machine's
/// preferences: a catalog restored from a backup or copied from elsewhere
/// starts with nothing allowed. An approval covers one project's source with
/// one label, command and working directory; changing any of them asks again.
public struct CommandApprovalStore: @unchecked Sendable {
  /// Project slug → the hashes of its approved commands.
  static let defaultsKey = "approvedSourceCommands"

  /// `UserDefaults` is safe to read from any thread.
  private let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  public func isApproved(project: String, source: ProjectSource) -> Bool {
    source.kind == .command
      && stored[project]?.contains(Self.hash(project: project, source: source)) == true
  }

  public func approve(project: String, source: ProjectSource) {
    guard source.kind == .command, !isApproved(project: project, source: source) else { return }
    var all = stored
    all[project, default: []].append(Self.hash(project: project, source: source))
    defaults.set(all, forKey: Self.defaultsKey)
  }

  /// Forgets every approval of a project, for when it is deleted.
  public func revokeAll(project: String) {
    var all = stored
    guard all.removeValue(forKey: project) != nil else { return }
    defaults.set(all, forKey: Self.defaultsKey)
  }

  /// Allows what has been approved, asked at the moment of each scan.
  public var policy: CommandSourcePolicy {
    CommandSourcePolicy(allowsInProject: { isApproved(project: $0, source: $1) })
  }

  private var stored: [String: [String]] {
    defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
  }

  /// Encoded as a JSON array, so no value can run into the next.
  static func hash(project: String, source: ProjectSource) -> String {
    let fields = [project, source.label, source.command, source.workingDirectory]
    let data = (try? JSONEncoder().encode(fields)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
