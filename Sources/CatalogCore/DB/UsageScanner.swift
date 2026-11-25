import Foundation
import GRDB

public enum UsageScanError: Error, Equatable, CustomStringConvertible {
  case noSources(String)
  case sourceNotFound(label: String, path: String)
  case unreadable(path: String, reason: String)

  public var description: String {
    switch self {
    case let .noSources(slug):
      return "Project '\(slug)' has no source folders to scan."
    case let .sourceNotFound(label, path):
      return "Source '\(label)' folder not found: \(path)"
    case let .unreadable(path, reason):
      return "Could not read \(path): \(reason)"
    }
  }
}

/// What one scan produced: the usage document, plus how many files it read
/// and how many it skipped (too large, or binary).
public struct UsageScanResult: Equatable, Sendable {
  public let document: UsageDocument
  public let files: Int
  public let skipped: Int
}

/// The prefixes a scanned URL is resolved against: one backend's current
/// prefix and its retired ones.
public struct UsageScanBackend: Sendable {
  public var backend: Backend
  public var retiredPrefixes: [String]

  public init(backend: Backend, retiredPrefixes: [String]) {
    self.backend = backend
    self.retiredPrefixes = retiredPrefixes
  }
}

/// Reads a project's sources and produces the usage document
/// `CatalogUsage.sync` ingests. Only reads; never writes inside a source
/// folder. Any missing folder, unreadable file or failed command fails the
/// whole scan, so an incomplete scan never replaces a complete one.
public enum UsageScanner {
  /// Files larger than this are skipped.
  public static let maximumFileSize = 5 * 1024 * 1024
  /// A NUL byte within this many leading bytes marks a file as binary.
  public static let binaryProbeLength = 8 * 1024

  static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "avif", "svg", "heic", "heif", "bmp", "tif", "tiff", "ico",
  ]

  /// Scans the project's sources against every backend's current and
  /// retired prefixes.
  /// `progress` gets the running count of files read, after each one.
  /// Command sources run only when `commands` allows them; by default none
  /// is, and a project that has one fails with `commandNotAllowed`.
  public static func scan(
    project slug: String,
    in database: CatalogDatabasePool,
    commands: CommandSourcePolicy = .deny,
    runner: CommandSourceRunning = ShellCommandRunner(),
    progress: (@Sendable (Int) -> Void)? = nil
  ) throws -> UsageScanResult {
    let (settings, backends) = try database.read { db in
      guard let project = try Project.filter(Column("slug") == slug).fetchOne(db) else {
        throw CatalogConfigurationError.projectNotFound(slug)
      }
      let backends = try Backend.order(Column("id")).fetchAll(db).map { backend in
        UsageScanBackend(
          backend: backend,
          retiredPrefixes: try String.fetchAll(
            db,
            sql: "SELECT url_prefix FROM backend_prefix_history WHERE backend_id = ? ORDER BY id",
            arguments: [backend.id]))
      }
      return (ProjectSettings(meta: project.meta), backends)
    }
    return try scan(
      project: slug, sources: settings.sources, backends: backends, commands: commands,
      runner: runner, progress: progress)
  }

  public static func scan(
    project slug: String,
    sources: [ProjectSource],
    backends: [UsageScanBackend],
    commands: CommandSourcePolicy = .deny,
    runner: CommandSourceRunning = ShellCommandRunner(),
    progress: (@Sendable (Int) -> Void)? = nil
  ) throws -> UsageScanResult {
    guard !sources.isEmpty else { throw UsageScanError.noSources(slug) }
    // Asked before anything is read or run, so one command that is not
    // allowed keeps the others from running too.
    for source in sources where source.kind == .command && !commands.allows(source) {
      throw CommandSourceError.commandNotAllowed(label: source.label)
    }
    var references = Set<UsageReference.Identity>()
    var files = 0
    var skipped = 0
    var revisions: [String] = []
    for source in sources {
      if source.kind == .command {
        let output = try commandOutput(
          of: source, project: slug, backends: backends, runner: runner)
        let prefix = source.label + "/"
        for item in output.references where keeps(item.rawURL, backends: backends) {
          references.insert(
            UsageReference.Identity(
              sourceReference: prefix + item.sourceReference.precomposedStringWithCanonicalMapping,
              rawURL: item.rawURL, kind: item.kind))
        }
        if let revision = output.sourceRevision {
          revisions.append("\(source.label):\(revision)")
        }
        continue
      }
      let root = URL(fileURLWithPath: source.path, isDirectory: true)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw UsageScanError.sourceNotFound(label: source.label, path: source.path)
      }
      for relativePath in try walk(root, source: source) {
        let fileURL = root.appendingPathComponent(relativePath)
        guard let text = try readText(fileURL) else {
          skipped += 1
          continue
        }
        files += 1
        progress?(files)
        let kind = kind(forPath: relativePath)
        let reference =
          "\(source.label)/\(relativePath.precomposedStringWithCanonicalMapping)#L"
        for (index, line) in lines(of: text).enumerated() {
          for url in urls(in: line) where keeps(url, backends: backends) {
            references.insert(
              UsageReference.Identity(
                sourceReference: reference + String(index + 1), rawURL: url, kind: kind))
          }
        }
      }
      if let revision = gitRevision(root) {
        revisions.append("\(source.label):\(revision)")
      }
    }
    let refs = references.sorted {
      ($0.sourceReference, $0.rawURL, $0.kind) < ($1.sourceReference, $1.rawURL, $1.kind)
    }.map { UsageReference(rawURL: $0.rawURL, sourceReference: $0.sourceReference, kind: $0.kind) }
    let coverage = sources.flatMap { source in
      source.kind == .command
        ? ["\(source.label)/*"] : source.effectiveInclude.map { "\(source.label)/\($0)" }
    }
    return UsageScanResult(
      document: UsageDocument(
        project: slug,
        sourceRevision: revisions.isEmpty ? nil : revisions.joined(separator: ","),
        coverage: coverage,
        refs: refs),
      files: files,
      skipped: skipped)
  }

  // MARK: - Commands

  /// Every backend's current and retired prefixes, once each.
  static func urlPrefixes(_ backends: [UsageScanBackend]) -> [String] {
    var seen = Set<String>()
    return backends.flatMap { [$0.backend.urlPrefix] + $0.retiredPrefixes }
      .filter { seen.insert($0).inserted }
  }

  private static func commandOutput(
    of source: ProjectSource, project: String, backends: [UsageScanBackend],
    runner: CommandSourceRunning
  ) throws -> CommandSourceOutput {
    let data = try runner.run(
      CommandSourceRequest(
        label: source.label, command: source.command,
        workingDirectory: source.workingDirectory,
        environment: [
          "PINAX_PROJECT": project,
          "PINAX_SOURCE": source.label,
          "PINAX_URL_PREFIXES": urlPrefixes(backends).joined(separator: "\n"),
        ]))
    return try CommandSourceOutput.parse(data, label: source.label, project: project)
  }

  // MARK: - Walking

  /// The relative paths of the regular files under `root` that the source
  /// includes, sorted. Symbolic links are never followed, to files or to
  /// folders; a segment starting with `.`, `node_modules`, `dist` and
  /// `build` are always left out.
  static func walk(_ root: URL, source: ProjectSource) throws -> [String] {
    let include = source.effectiveInclude
    var result: [String] = []
    var pending: [String] = [""]
    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
    while let relative = pending.popLast() {
      let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      } catch {
        throw UsageScanError.unreadable(path: directory.path, reason: error.localizedDescription)
      }
      for name in names.sorted() where !isBuiltInExclusion(name) {
        let path = relative.isEmpty ? name : relative + "/" + name
        let values = try? root.appendingPathComponent(path).resourceValues(forKeys: Set(keys))
        if values?.isSymbolicLink == true { continue }
        if values?.isDirectory == true {
          pending.append(path)
        } else if values?.isRegularFile == true,
          PathGlob.matchesAny(include, path),
          !PathGlob.matchesAny(source.exclude, path)
        {
          result.append(path)
        }
      }
    }
    return result.sorted()
  }

  static func isBuiltInExclusion(_ name: String) -> Bool {
    name.hasPrefix(".") || name == "node_modules" || name == "dist" || name == "build"
  }

  /// The file's text, decoded leniently as UTF-8, or nil when it is too
  /// large or looks binary.
  static func readText(_ url: URL) throws -> String? {
    try readData(url).map { String(decoding: $0, as: UTF8.self) }
  }

  /// The file's bytes, or nil when it is too large or looks binary.
  static func readData(_ url: URL) throws -> Data? {
    do {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      if size > maximumFileSize { return nil }
      let data = try Data(contentsOf: url)
      if data.prefix(binaryProbeLength).contains(0) { return nil }
      return data
    } catch {
      throw UsageScanError.unreadable(path: url.path, reason: error.localizedDescription)
    }
  }

  public static func kind(forPath path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "md", "mdx", "markdown": return "markdown"
    case "html", "htm", "astro", "vue", "svelte", "jsx", "tsx": return "html"
    case "css", "scss": return "css"
    case "yml", "yaml": return "yaml"
    default: return "text"
    }
  }

  // MARK: - Extraction

  /// `text` split into lines at `\n` and `\r\n`, terminators left out.
  static func lines(of text: String) -> [Substring] {
    text.split(
      omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
  }

  private static let terminators: Set<Character> = ["\"", "'", "<", ">", "`", "]", "|"]
  private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

  /// Every `http://` and `https://` URL in `line`, in order.
  public static func urls(in line: Substring) -> [String] {
    urlSpans(in: line).map(\.url)
  }

  /// Every `http://` and `https://` URL in `line`, in order, with where it
  /// sits in the line as written.
  public static func urlSpans(in line: Substring) -> [URLSpan] {
    var result: [URLSpan] = []
    var rest = line[...]
    while let start = nextScheme(in: rest) {
      // A `<…>` destination (CommonMark) runs to its `>`, spaces included,
      // and is reported as written. Unclosed, the bare rule below applies.
      if start > rest.startIndex, rest[rest.index(before: start)] == "<",
        let close = rest[start...].firstIndex(where: { $0 == ">" || $0 == "<" }),
        rest[close] == ">"
      {
        result.append(URLSpan(range: start..<close, literal: rest[start..<close], angled: true))
        rest = rest[close...]
        continue
      }
      var end = start
      var depth = 0
      while end < rest.endIndex {
        let character = rest[end]
        if character.isWhitespace || terminators.contains(character) { break }
        if character == "(" { depth += 1 }
        if character == ")" {
          if depth == 0 { break }
          depth -= 1
        }
        end = rest.index(after: end)
      }
      var url = rest[start..<end]
      while let last = url.last, trailingPunctuation.contains(last) { url = url.dropLast() }
      result.append(URLSpan(range: url.startIndex..<url.endIndex, literal: url, angled: false))
      rest = rest[end...]
    }
    return result
  }

  private static func nextScheme(in text: Substring) -> Substring.Index? {
    // The scheme ignores case (`HTTPS://…`), so a
    // scan counts and a rewrite finds the same links.
    let http = text.range(of: "http://", options: .caseInsensitive)?.lowerBound
    let https = text.range(of: "https://", options: .caseInsensitive)?.lowerBound
    switch (http, https) {
    case let (a?, b?): return min(a, b)
    case let (a?, nil): return a
    case let (nil, b?): return b
    case (nil, nil): return nil
    }
  }

  /// The keep rule: the URL resolves under a backend's current or
  /// retired prefix, or its path ends in an image extension.
  public static func keeps(_ url: String, backends: [UsageScanBackend]) -> Bool {
    if backends.contains(where: {
      URLResolver.key(from: url, backend: $0.backend, retiredPrefixes: $0.retiredPrefixes) != nil
    }) {
      return true
    }
    guard let scheme = url.range(of: "://") else { return false }
    let afterScheme = url[scheme.upperBound...]
    let beforeQuery = afterScheme.prefix { $0 != "?" && $0 != "#" }
    guard let slash = beforeQuery.firstIndex(of: "/") else { return false }
    let name = beforeQuery[beforeQuery.index(after: slash)...].split(separator: "/").last ?? ""
    guard let dot = name.lastIndex(of: ".") else { return false }
    return imageExtensions.contains(name[name.index(after: dot)...].lowercased())
  }

  // MARK: - Revision

  /// The commit `HEAD` names in `root/.git`, read from the files directly
  /// (no `git` process): a detached sha, a loose ref, or a `packed-refs`
  /// line. Nil when `.git` is not a folder (a worktree) or nothing resolves.
  public static func gitRevision(_ root: URL) -> String? {
    let git = root.appendingPathComponent(".git", isDirectory: true)
    guard let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8)
    else { return nil }
    let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("ref: ") else { return isSHA(trimmed) ? trimmed : nil }
    let ref = String(trimmed.dropFirst("ref: ".count))
    if let loose = try? String(contentsOf: git.appendingPathComponent(ref), encoding: .utf8) {
      let sha = loose.trimmingCharacters(in: .whitespacesAndNewlines)
      if isSHA(sha) { return sha }
    }
    guard
      let packed = try? String(
        contentsOf: git.appendingPathComponent("packed-refs"), encoding: .utf8)
    else { return nil }
    for line in packed.split(separator: "\n") {
      let parts = line.split(separator: " ")
      if parts.count == 2, parts[1] == ref, isSHA(String(parts[0])) { return String(parts[0]) }
    }
    return nil
  }

  private static func isSHA(_ text: String) -> Bool {
    (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
  }
}

/// One URL as `UsageScanner.urlSpans(in:)` found it: where it sits in the
/// line, the text as written, and the URL that text decodes to (`&amp;`
/// read as `&`). `angled` marks a `<…>` destination; `range` and `literal`
/// leave the brackets out.
public struct URLSpan: Equatable, Sendable {
  public let range: Range<Substring.Index>
  public let literal: String
  public let url: String
  public let angled: Bool

  init(range: Range<Substring.Index>, literal: Substring, angled: Bool) {
    self.range = range
    self.literal = String(literal)
    self.url = literal.replacingOccurrences(of: "&amp;", with: "&")
    self.angled = angled
  }
}

extension UsageReference {
  struct Identity: Hashable {
    let sourceReference: String
    let rawURL: String
    let kind: String
  }
}
