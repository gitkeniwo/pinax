import Foundation

/// Which scan of each project an automatic scan last made, so the Projects
/// page can say so while it is still the latest one. Kept in this machine's
/// preferences: the catalog does not record who asked for a scan.
public struct AutomaticScanMarks: @unchecked Sendable {
  /// Project slug → the scan's id.
  static let defaultsKey = "automaticScanIDs"

  /// `UserDefaults` is safe to read from any thread.
  private let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  public func record(project: String, scanID: Int64) {
    var all = stored
    all[project] = Int(scanID)
    defaults.set(all, forKey: Self.defaultsKey)
  }

  public func scanID(project: String) -> Int64? {
    stored[project].map(Int64.init)
  }

  private var stored: [String: Int] {
    defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int] ?? [:]
  }
}
