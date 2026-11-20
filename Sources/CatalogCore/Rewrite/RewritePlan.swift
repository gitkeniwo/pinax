import Foundation
import GRDB

/// What a rewrite would change, worked out without
/// writing anything. `RewriteApplier` writes exactly this.
public struct RewritePlan: Sendable {
  public let project: String
  public let rules: [RewriteRule]
  public let sources: [RewriteSourceState]
  /// Files with at least one edit or one skipped site, in source then path
  /// order.
  public let files: [RewriteFilePlan]
  /// The distinct new URLs, sorted.
  public let targets: [RewriteTarget]
  /// `//host/` occurrences for the rules' hosts not preceded by `:`.
  public let protocolRelative: [ProtocolRelativeHit]
  public let summary: RewriteSummary
}

public struct RewriteSourceState: Equatable, Sendable {
  public let label: String
  public let path: String
  public let git: SourceGitStatus

  public init(label: String, path: String, git: SourceGitStatus) {
    self.label = label
    self.path = path
    self.git = git
  }
}

public struct RewriteFilePlan: Sendable {
  public let sourceLabel: String
  /// Relative to the source folder.
  public let path: String
  public let absolutePath: String
  /// sha256 of the bytes the plan was made from.
  public let originalSHA256: String
  public let edits: [RewriteEdit]
  public let skips: [RewriteSkip]
  /// The file with every edit spliced in; nil when the file has no edits.
  public let newContent: Data?
  /// The file as read; kept for the diff.
  public let originalContent: Data
}

/// One change, located by 1-based line and column (column counted in
/// characters).
public struct RewriteEdit: Equatable, Sendable {
  public let line: Int
  public let column: Int
  public let oldText: String
  public let newText: String
  public let ruleIndex: Int
  /// Byte range of `oldText` in the original file.
  public let byteRange: Range<Int>
}

public enum RewriteSkipReason: String, Equatable, Hashable, Sendable, CaseIterable {
  /// The file is not strict UTF-8; it is never written.
  case notUTF8 = "not_utf8"
  /// The new URL would not read back as one URL in this spot.
  case unsafeTarget = "unsafe_target"
}

/// A site a rule matched but that is left as it is.
public struct RewriteSkip: Equatable, Sendable {
  public let line: Int
  public let column: Int
  public let oldText: String
  public let newURL: String
  public let ruleIndex: Int
  public let reason: RewriteSkipReason
}

public struct RewriteTarget: Equatable, Sendable {
  public let url: String
  /// The catalog asset the old URL resolves to, when one does.
  public let expectedSHA256: String?
  /// The old URLs rewritten to this one, sorted.
  public let oldURLs: [String]

  public init(url: String, expectedSHA256: String?, oldURLs: [String] = []) {
    self.url = url
    self.expectedSHA256 = expectedSHA256
    self.oldURLs = oldURLs
  }
}

public struct ProtocolRelativeHit: Equatable, Sendable {
  public let sourceLabel: String
  public let path: String
  public let line: Int
  public let host: String

  public init(sourceLabel: String, path: String, line: Int, host: String) {
    self.sourceLabel = sourceLabel
    self.path = path
    self.line = line
    self.host = host
  }
}

public struct RewriteSummary: Equatable, Sendable {
  public let files: Int
  public let edits: Int
  /// Edits per rule, indexed like the rules.
  public let editsByRule: [Int]
  public let skippedByReason: [RewriteSkipReason: Int]
  public let protocolRelative: Int
}

public enum RewritePlanError: Error, Equatable, CustomStringConvertible {
  case invalidRules([RewriteRuleProblem])

  public var description: String {
    switch self {
    case let .invalidRules(problems):
      return problems.map(\.description).joined(separator: "\n")
    }
  }
}

public enum RewritePlanner {
  /// Plans against the project's sources, resolving old URLs to catalog
  /// assets through every backend's current and retired prefixes.
  public static func plan(
    project slug: String,
    rules: [RewriteRule],
    database: CatalogDatabasePool,
    git: GitStatusProviding = GitStatusProvider()
  ) throws -> RewritePlan {
    let problems = RewriteRules.validate(rules)
    guard problems.isEmpty else { throw RewritePlanError.invalidRules(problems) }
    let (sources, backends) = try database.read { db in
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
      return (ProjectSettings(meta: project.meta).sources, backends)
    }
    return try plan(project: slug, sources: sources, rules: rules, git: git) { url in
      try? database.read { db in
        for scanBackend in backends {
          guard
            let key = URLResolver.key(
              from: url, backend: scanBackend.backend, retiredPrefixes: scanBackend.retiredPrefixes)
          else { continue }
          if let sha = try String.fetchOne(
            db, sql: "SELECT sha256 FROM asset WHERE backend_id = ? AND key = ? ORDER BY id",
            arguments: [scanBackend.backend.id, key])
          {
            return sha
          }
        }
        return nil
      }
    }
  }

  /// Plans against `sources`. `assetSHA256` maps an old URL to the sha256
  /// of the catalog asset it names.
  public static func plan(
    project slug: String,
    sources: [ProjectSource],
    rules: [RewriteRule],
    git: GitStatusProviding,
    assetSHA256: (String) -> String? = { _ in nil }
  ) throws -> RewritePlan {
    let problems = RewriteRules.validate(rules)
    guard problems.isEmpty else { throw RewritePlanError.invalidRules(problems) }
    guard !sources.isEmpty else { throw UsageScanError.noSources(slug) }
    let hosts = Set(rules.compactMap { URLComponents(string: $0.from)?.host?.lowercased() }).sorted()
    var states: [RewriteSourceState] = []
    var files: [RewriteFilePlan] = []
    var protocolRelative: [ProtocolRelativeHit] = []
    var targetURLs = Set<String>()
    var targetSHA256: [String: String] = [:]
    var targetOldURLs: [String: Set<String>] = [:]
    for source in sources {
      let root = URL(fileURLWithPath: source.path, isDirectory: true)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw UsageScanError.sourceNotFound(label: source.label, path: source.path)
      }
      states.append(RewriteSourceState(label: source.label, path: source.path, git: git.status(of: root)))
      for relativePath in try UsageScanner.walk(root, source: source) {
        let fileURL = root.appendingPathComponent(relativePath)
        guard let data = try UsageScanner.readData(fileURL) else { continue }
        let planned = planFile(data, rules: rules, hosts: hosts)
        protocolRelative += planned.protocolRelative.map {
          ProtocolRelativeHit(sourceLabel: source.label, path: relativePath, line: $0.line, host: $0.host)
        }
        guard !planned.edits.isEmpty || !planned.skips.isEmpty else { continue }
        for edit in planned.edits where targetURLs.insert(edit.newURL).inserted
          || targetSHA256[edit.newURL] == nil
        {
          targetSHA256[edit.newURL] = assetSHA256(edit.decodedOld)
        }
        for edit in planned.edits { targetOldURLs[edit.newURL, default: []].insert(edit.decodedOld) }
        files.append(
          RewriteFilePlan(
            sourceLabel: source.label, path: relativePath, absolutePath: fileURL.path,
            originalSHA256: Hashing.sha256(of: data), edits: planned.edits.map(\.edit),
            skips: planned.skips, newContent: planned.newContent, originalContent: data))
      }
    }
    var editsByRule = Array(repeating: 0, count: rules.count)
    var skipped: [RewriteSkipReason: Int] = [:]
    for file in files {
      for edit in file.edits { editsByRule[edit.ruleIndex] += 1 }
      for skip in file.skips { skipped[skip.reason, default: 0] += 1 }
    }
    return RewritePlan(
      project: slug, rules: rules, sources: states, files: files,
      targets: targetURLs.sorted().map {
        RewriteTarget(
          url: $0, expectedSHA256: targetSHA256[$0], oldURLs: (targetOldURLs[$0] ?? []).sorted())
      },
      protocolRelative: protocolRelative,
      summary: RewriteSummary(
        files: files.filter { !$0.edits.isEmpty }.count,
        edits: editsByRule.reduce(0, +),
        editsByRule: editsByRule,
        skippedByReason: skipped,
        protocolRelative: protocolRelative.count))
  }

  // MARK: - One file

  struct PlannedEdit {
    let edit: RewriteEdit
    let decodedOld: String
    let newURL: String
  }

  struct PlannedFile {
    var edits: [PlannedEdit] = []
    var skips: [RewriteSkip] = []
    var newContent: Data?
    var protocolRelative: [(line: Int, host: String)] = []
  }

  /// The edits for one file's bytes. A file that is not strict UTF-8 gets
  /// no edits; the sites a rule would match in its lenient decoding are
  /// reported as `not_utf8` skips.
  static func planFile(_ data: Data, rules: [RewriteRule], hosts: [String]) -> PlannedFile {
    let text = String(decoding: data, as: UTF8.self)
    let strict = Data(text.utf8) == data
    var result = PlannedFile()
    for (index, line) in UsageScanner.lines(of: text).enumerated() {
      for host in hosts {
        for _ in 0..<protocolRelativeCount(in: line, host: host) {
          result.protocolRelative.append((index + 1, host))
        }
      }
      for span in UsageScanner.urlSpans(in: line) {
        guard let match = RewriteRules.match(span.url, in: rules) else { continue }
        let column = line.distance(from: line.startIndex, to: span.range.lowerBound) + 1
        func skip(_ reason: RewriteSkipReason) -> RewriteSkip {
          RewriteSkip(
            line: index + 1, column: column, oldText: span.literal, newURL: match.url,
            ruleIndex: match.index, reason: reason)
        }
        guard strict else {
          result.skips.append(skip(.notUTF8))
          continue
        }
        guard let newText = writtenText(for: match.url, replacing: span, in: line) else {
          result.skips.append(skip(.unsafeTarget))
          continue
        }
        let start = text.utf8.distance(from: text.startIndex, to: span.range.lowerBound)
        let end = text.utf8.distance(from: text.startIndex, to: span.range.upperBound)
        result.edits.append(
          PlannedEdit(
            edit: RewriteEdit(
              line: index + 1, column: column, oldText: span.literal, newText: newText,
              ruleIndex: match.index, byteRange: start..<end),
            decodedOld: span.url, newURL: match.url))
      }
    }
    if !result.edits.isEmpty {
      var content = Data()
      var cursor = 0
      for edit in result.edits.map(\.edit) {
        content.append(data[data.startIndex + cursor..<data.startIndex + edit.byteRange.lowerBound])
        content.append(Data(edit.newText.utf8))
        cursor = edit.byteRange.upperBound
      }
      content.append(data[(data.startIndex + cursor)...])
      result.newContent = content
    }
    return result
  }

  /// The text that puts `url` where `span` is, written the way the original
  /// was (`&amp;` kept, `<…>` kept by leaving the brackets alone), or nil
  /// when the line would not read back as `url` in that spot.
  static func writtenText(for url: String, replacing span: URLSpan, in line: Substring) -> String? {
    let text = span.literal.contains("&amp;") ? url.replacingOccurrences(of: "&", with: "&amp;") : url
    let prefix = line[..<span.range.lowerBound]
    let rewritten = String(prefix) + text + String(line[span.range.upperBound...])
    let offset = prefix.utf8.count
    let readBack = UsageScanner.urlSpans(in: rewritten[...]).first {
      rewritten.utf8.distance(from: rewritten.startIndex, to: $0.range.lowerBound) == offset
    }
    guard let readBack, readBack.literal == text, readBack.url == url,
      readBack.angled == span.angled
    else { return nil }
    return text
  }

  /// Occurrences of `//host/` (host without regard to case) not preceded
  /// by `:`.
  static func protocolRelativeCount(in line: Substring, host: String) -> Int {
    let needle = "//" + host + "/"
    var count = 0
    var rest = line[...]
    while let found = rest.range(of: needle, options: .caseInsensitive) {
      if found.lowerBound == line.startIndex || line[line.index(before: found.lowerBound)] != ":" {
        count += 1
      }
      rest = line[found.upperBound...]
    }
    return count
  }
}
