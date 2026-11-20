import Foundation

/// A project's sources and usage-tracking state, stored in
/// the existing `project.meta` JSON object (no migration).
public struct ProjectSettings: Equatable, Sendable {
  public var sources: [ProjectSource]
  public var usageTracking: UsageTracking

  public init(sources: [ProjectSource] = [], usageTracking: UsageTracking = .tracked) {
    self.sources = sources
    self.usageTracking = usageTracking
  }

  /// At most this many sources per project.
  public static let maximumSources = 16

  /// Reads `meta` tolerantly: anything that is not a JSON object, a missing
  /// key or a value of the wrong type reads as "no sources, tracked".
  /// Never throws.
  public init(meta: String) {
    self.init()
    guard let object = Self.object(meta) else { return }
    if let array = object["sources"] as? [Any] {
      let decoded = array.compactMap(ProjectSource.init(json:))
      if decoded.count == array.count { sources = decoded }
    }
    if let raw = object["usageTracking"] as? String, let value = UsageTracking(rawValue: raw) {
      usageTracking = value
    }
  }

  static func object(_ meta: String) -> [String: Any]? {
    guard let data = meta.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

public enum UsageTracking: String, Equatable, Sendable, Codable {
  case tracked
  case notTracked
}

public struct ProjectSource: Equatable, Sendable, Codable {
  public var label: String
  /// Absolute, standardized, local to this machine.
  public var path: String
  /// Empty means `defaultInclude`.
  public var include: [String]
  public var exclude: [String]

  public init(label: String, path: String, include: [String] = [], exclude: [String] = []) {
    self.label = label
    self.path = path
    self.include = include
    self.exclude = exclude
  }

  /// What an empty or missing `include` scans.
  public static let defaultInclude = [
    "**/*.{md,mdx,markdown,html,htm,astro,vue,svelte,jsx,tsx,css,scss,yml,yaml}"
  ]

  /// The include patterns in effect.
  public var effectiveInclude: [String] { include.isEmpty ? Self.defaultInclude : include }

  /// The label rule: `^[A-Za-z0-9._-]{1,64}$`.
  public static func isValidLabel(_ label: String) -> Bool {
    (1...64).contains(label.unicodeScalars.count)
      && label.unicodeScalars.allSatisfy { labelCharacters.contains($0) }
  }

  /// The label a new source gets: its folder's name, with characters the
  /// label rule does not allow replaced by `-`, cut to 64 characters, and
  /// `-2`, `-3`… appended when the project already has that label.
  public static func defaultLabel(forPath path: String, existing: [String]) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    var base = String(
      String.UnicodeScalarView(
        name.unicodeScalars.map { labelCharacters.contains($0) ? $0 : "-" }))
    if base.isEmpty || base == "/" { base = "source" }
    base = String(base.prefix(64))
    let taken = Set(existing)
    guard taken.contains(base) else { return base }
    var number = 2
    while true {
      let suffix = "-\(number)"
      let candidate = String(base.prefix(64 - suffix.count)) + suffix
      if !taken.contains(candidate) { return candidate }
      number += 1
    }
  }

  private static let labelCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

  init?(json: Any) {
    guard let object = json as? [String: Any],
      let label = object["label"] as? String,
      let path = object["path"] as? String
    else { return nil }
    let include = object["include"] ?? [String]()
    let exclude = object["exclude"] ?? [String]()
    guard let include = include as? [String], let exclude = exclude as? [String] else { return nil }
    self.init(label: label, path: path, include: include, exclude: exclude)
  }

  var json: [String: Any] {
    ["label": label, "path": path, "include": include, "exclude": exclude]
  }
}
