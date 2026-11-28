import Foundation

/// A project's sources, usage-tracking state and upload compression, stored
/// in the existing `project.meta` JSON object (no migration).
public struct ProjectSettings: Equatable, Sendable {
  public var sources: [ProjectSource]
  public var usageTracking: UsageTracking
  public var compression: ProjectCompression
  public var autoScan: ProjectAutoScan

  public init(
    sources: [ProjectSource] = [],
    usageTracking: UsageTracking = .tracked,
    compression: ProjectCompression = ProjectCompression(),
    autoScan: ProjectAutoScan = .off
  ) {
    self.sources = sources
    self.usageTracking = usageTracking
    self.compression = compression
    self.autoScan = autoScan
  }

  /// At most this many sources per project.
  public static let maximumSources = 16

  /// Reads `meta` tolerantly: anything that is not a JSON object, a missing
  /// key or a value of the wrong type reads as "no sources, tracked,
  /// compression off with the default options". Never throws.
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
    if let value = object["compression"] {
      compression = ProjectCompression(json: value)
    }
    if let value = object["autoScan"].flatMap(ProjectAutoScan.init(json:)) {
      autoScan = value
    }
  }

  static func object(_ meta: String) -> [String: Any]? {
    guard let data = meta.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

/// Whether a project's uploads are recompressed, and how. Only the uploaded
/// copy is ever compressed; the file on disk is left as it is.
public struct ProjectCompression: Equatable, Sendable {
  public var isEnabled: Bool
  public var options: CompressionOptions

  public init(isEnabled: Bool = false, options: CompressionOptions = .default) {
    self.isEnabled = isEnabled
    self.options = options
  }

  /// The options an upload into this project uses, or nil when it is off.
  public var effectiveOptions: CompressionOptions? { isEnabled ? options : nil }

  /// Tolerant: a value that is not an object reads as off with the default
  /// options, and each field that is missing or of the wrong type reads as
  /// its default. An explicit `null` longest edge means "don't resize".
  init(json: Any) {
    self.init()
    guard let object = json as? [String: Any] else { return }
    if let value = object["enabled"] as? Bool { isEnabled = value }
    switch object["longestEdge"] {
    case is NSNull: options.longestEdge = nil
    case let number as NSNumber where !CFNumberIsFloatType(number) && number.intValue > 0:
      options.longestEdge = number.intValue
    default: break
    }
    if let value = CompressionQuality(json: object["quality"]) { options.quality = value }
    if let value = object["removeMetadata"] as? Bool { options.removesMetadata = value }
  }

  var json: [String: Any] {
    [
      "enabled": isEnabled,
      "longestEdge": options.longestEdge.map { $0 as Any } ?? NSNull(),
      "quality": options.quality.percent,
      "removeMetadata": options.removesMetadata,
    ]
  }
}

/// Whether one upload is compressed: as its project says, or forced on or off.
public enum CompressionChoice: Equatable, Sendable {
  case project
  case on
  case off

  /// The options for an upload into `project` (nil: No Project). `.project`
  /// follows the project's switch, and No Project is never compressed by
  /// default. `.on` uses the project's options even when its switch is off,
  /// and the default options for No Project.
  public func options(for project: Project?) -> CompressionOptions? {
    let settings = project.map { ProjectSettings(meta: $0.meta).compression }
    switch self {
    case .off: return nil
    case .project: return settings?.effectiveOptions
    case .on: return settings?.options ?? .default
    }
  }
}

public enum UsageTracking: String, Equatable, Sendable, Codable {
  case tracked
  case notTracked
}

/// When a project is rescanned without being asked. Both are off unless set.
public struct ProjectAutoScan: Equatable, Sendable {
  public enum Schedule: String, Equatable, Sendable, CaseIterable {
    case off
    case hourly
    case daily
  }

  /// Rescan when something changes in the project's source folders.
  public var watch: Bool
  public var schedule: Schedule

  public init(watch: Bool = false, schedule: Schedule = .off) {
    self.watch = watch
    self.schedule = schedule
  }

  public static let off = ProjectAutoScan()

  /// Nil unless both values are there and readable.
  init?(json: Any) {
    guard let object = json as? [String: Any],
      let watch = object["watch"] as? NSNumber, CFGetTypeID(watch) == CFBooleanGetTypeID(),
      let raw = object["schedule"] as? String, let schedule = Schedule(rawValue: raw)
    else { return nil }
    self.init(watch: watch.boolValue, schedule: schedule)
  }

  var json: [String: Any] {
    ["watch": watch, "schedule": schedule.rawValue]
  }
}

/// A place a project's usage scan reads references from: a folder of files,
/// or a command whose output lists them.
public struct ProjectSource: Equatable, Sendable, Codable {
  public enum Kind: String, Equatable, Sendable, Codable {
    case folder
    case command
  }

  public var kind: Kind
  public var label: String
  /// A folder source's folder: absolute, standardized, local to this
  /// machine. Empty for a command source.
  public var path: String
  /// Empty means `defaultInclude`. Folder sources only.
  public var include: [String]
  /// Folder sources only.
  public var exclude: [String]
  /// A command source's shell command line. Empty for a folder source.
  public var command: String
  /// The folder the command runs in: absolute, standardized. Empty for a
  /// folder source.
  public var workingDirectory: String

  /// A folder source.
  public init(label: String, path: String, include: [String] = [], exclude: [String] = []) {
    self.kind = .folder
    self.label = label
    self.path = path
    self.include = include
    self.exclude = exclude
    self.command = ""
    self.workingDirectory = ""
  }

  /// A command source.
  public init(label: String, command: String, workingDirectory: String) {
    self.kind = .command
    self.label = label
    self.path = ""
    self.include = []
    self.exclude = []
    self.command = command
    self.workingDirectory = workingDirectory
  }

  /// The folder on this machine the source needs: the one it scans, or the
  /// one its command runs in.
  public var directory: String { kind == .command ? workingDirectory : path }

  /// The longest command a command source may hold.
  public static let maximumCommandLength = 4096

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

  /// Nil for a kind this version does not know.
  init?(json: Any) {
    guard let object = json as? [String: Any],
      let label = object["label"] as? String
    else { return nil }
    var kind = Kind.folder
    if let value = object["kind"] {
      guard let known = (value as? String).flatMap(Kind.init(rawValue:)) else { return nil }
      kind = known
    }
    if kind == .command {
      guard let command = object["command"] as? String,
        let workingDirectory = object["workingDirectory"] as? String
      else { return nil }
      self.init(label: label, command: command, workingDirectory: workingDirectory)
      return
    }
    guard let path = object["path"] as? String else { return nil }
    let include = object["include"] ?? [String]()
    let exclude = object["exclude"] ?? [String]()
    guard let include = include as? [String], let exclude = exclude as? [String] else { return nil }
    self.init(label: label, path: path, include: include, exclude: exclude)
  }

  /// A folder source is stored without a `kind`.
  var json: [String: Any] {
    switch kind {
    case .folder:
      return ["label": label, "path": path, "include": include, "exclude": exclude]
    case .command:
      return [
        "kind": kind.rawValue, "label": label, "command": command,
        "workingDirectory": workingDirectory,
      ]
    }
  }

  // MARK: Codable, the shape `pinax project source ls --format json` prints

  private enum CodingKeys: String, CodingKey {
    case kind, label, path, include, exclude, command
    case workingDirectory = "working_directory"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let label = try container.decode(String.self, forKey: .label)
    switch try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .folder {
    case .folder:
      self.init(
        label: label,
        path: try container.decode(String.self, forKey: .path),
        include: try container.decode([String].self, forKey: .include),
        exclude: try container.decode([String].self, forKey: .exclude))
    case .command:
      self.init(
        label: label,
        command: try container.decode(String.self, forKey: .command),
        workingDirectory: try container.decode(String.self, forKey: .workingDirectory))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(label, forKey: .label)
    switch kind {
    case .folder:
      try container.encode(path, forKey: .path)
      try container.encode(include, forKey: .include)
      try container.encode(exclude, forKey: .exclude)
    case .command:
      try container.encode(kind, forKey: .kind)
      try container.encode(command, forKey: .command)
      try container.encode(workingDirectory, forKey: .workingDirectory)
    }
  }
}
