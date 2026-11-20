import Foundation

/// A placeholder of a project's object key template.
/// `allCases` is the fixed order the UI's insert chips use.
public enum KeyTemplatePlaceholder: String, CaseIterable, Sendable {
  case prefix, year, month, day, name, hash, ext

  /// The placeholder as written in a template, e.g. `{prefix}`.
  public var token: String { "{\(rawValue)}" }
}

/// One rule a key template is checked against: an error in the template
/// (E1–E7), a problem with the rendered key (R1–R4), or a warning (W1–W2).
public enum KeyTemplateIssueCode: String, Sendable, Comparable {
  case empty = "E1"
  case unknownPlaceholder = "E2"
  case unmatchedBrace = "E3"
  case disallowedCharacter = "E4"
  case missingExtension = "E5"
  case slashEdges = "E6"
  case dotSegment = "E7"
  case renderedSlashEdges = "R1"
  case renderedReservedPrefix = "R2"
  case renderedBadSegment = "R3"
  case renderedTooLong = "R4"
  case noHash = "W1"
  case prefixIgnored = "W2"

  public var isWarning: Bool { rawValue.hasPrefix("W") }

  private var order: Int {
    let all: [KeyTemplateIssueCode] = [
      .empty, .unknownPlaceholder, .unmatchedBrace, .disallowedCharacter, .missingExtension,
      .slashEdges, .dotSegment, .renderedSlashEdges, .renderedReservedPrefix,
      .renderedBadSegment, .renderedTooLong, .noHash, .prefixIgnored,
    ]
    return all.firstIndex(of: self)!
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// An error or warning with the English text the UI and CLI show verbatim.
public struct KeyTemplateIssue: Equatable, Sendable, CustomStringConvertible {
  public let code: KeyTemplateIssueCode
  public let message: String

  public init(code: KeyTemplateIssueCode, message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { message }
}

/// A piece of a rendered key: the value of one placeholder, or template text.
public struct KeyTemplateSegment: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case prefix, year, month, day, name, hash, ext, literal
  }

  public let kind: Kind
  public let text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

/// A stretch of a template as typed: text, a placeholder, or
/// a `{…}` that is not one, with where it sits in the template.
public struct KeyTemplatePart: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case literal
    case placeholder(KeyTemplatePlaceholder)
    case invalid
  }

  public let kind: Kind
  public let range: Range<String.Index>
}

/// A template's check in one value: errors and warnings kept apart, and the
/// example key in segments — present exactly when there are no errors.
public struct KeyTemplateEvaluation: Equatable, Sendable {
  public let errors: [KeyTemplateIssue]
  public let warnings: [KeyTemplateIssue]
  public let example: [KeyTemplateSegment]?

  public var isValid: Bool { errors.isEmpty }
  /// The example's segments joined: the key a `photo.png` would get.
  public var exampleKey: String? { example.map { $0.map(\.text).joined() } }
}

public enum KeyTemplateError: Error, Equatable, CustomStringConvertible {
  case invalidSHA256
  case missingFileExtension
  /// Errors of the template, or problems of the rendered key, in
  /// code order.
  case invalid([KeyTemplateIssue])

  public var description: String {
    switch self {
    case .invalidSHA256:
      return "The content hash is not a lowercase hexadecimal sha256."
    case .missingFileExtension:
      return "The file has no extension."
    case let .invalid(issues):
      return issues.map(\.message).joined(separator: "\n")
    }
  }
}

public enum KeyTemplate {
  /// The template a project without one uses. It renders the
  /// same key, byte for byte, as the rule it replaced.
  public static let defaultTemplate = "{prefix}/{year}{month}/{name}-{hash}.{ext}"
  /// The fixed placeholder order, for the UI's insert chips and the CLI's help.
  public static let placeholders = KeyTemplatePlaceholder.allCases

  /// The fixed example file: a `photo.png` whose sha256 starts `3fa9c2e1b07d`.
  public static let sampleFilename = "photo.png"
  public static let sampleSHA256 = "3fa9c2e1b07d" + String(repeating: "0", count: 52)
  public static let sampleExtension = "png"

  /// Renders with the default template (the pre-template entry point).
  public static func render(
    keyPrefix: String,
    originalFilename: String,
    sha256: String,
    fileExtension: String,
    date: Date = Date()
  ) throws -> String {
    try render(
      template: defaultTemplate, keyPrefix: keyPrefix, originalFilename: originalFilename,
      sha256: sha256, fileExtension: fileExtension, date: date)
  }

  /// The key an upload gets: `segments(...)` joined, so an example and a
  /// real upload cannot disagree.
  public static func render(
    template: String,
    keyPrefix: String,
    originalFilename: String,
    sha256: String,
    fileExtension: String,
    date: Date = Date()
  ) throws -> String {
    try segments(
      template: template, keyPrefix: keyPrefix, originalFilename: originalFilename,
      sha256: sha256, fileExtension: fileExtension, date: date
    ).map(\.text).joined()
  }

  /// The rendered key as segments. Throws `.invalid` for errors in the
  /// template or problems in the result; never truncates or rewrites.
  public static func segments(
    template: String,
    keyPrefix: String,
    originalFilename: String,
    sha256: String,
    fileExtension: String,
    date: Date = Date()
  ) throws -> [KeyTemplateSegment] {
    guard sha256.count >= 12,
      sha256.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (97...102).contains($0.value)
      })
    else {
      throw KeyTemplateError.invalidSHA256
    }
    let normalizedExtension =
      fileExtension
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .drop(while: { $0 == "." })
      .lowercased()
    guard !normalizedExtension.isEmpty else {
      throw KeyTemplateError.missingFileExtension
    }

    let parsed = parse(template)
    let errors = templateErrors(template, parsed)
    guard errors.isEmpty else { throw KeyTemplateError.invalid(errors) }

    func value(_ placeholder: KeyTemplatePlaceholder) -> String {
      Self.value(
        placeholder, keyPrefix: keyPrefix, originalFilename: originalFilename, sha256: sha256,
        normalizedExtension: normalizedExtension, date: date)
    }

    // One pass: each token appends its text; a value is never re-read as
    // template text.
    var result = parsed.tokens.map { token -> KeyTemplateSegment in
      switch token {
      case let .literal(text):
        return KeyTemplateSegment(kind: .literal, text: text)
      case let .placeholder(placeholder):
        return KeyTemplateSegment(kind: Self.kind(placeholder), text: value(placeholder))
      }
    }
    // An empty {prefix} that would leave an empty path segment merges it
    // away: the `/` after it goes, or the one before it at the end.
    for index in result.indices where result[index].kind == .prefix && result[index].text.isEmpty {
      let before = result[..<index].last(where: { !$0.text.isEmpty })
      let afterIndex = result[(index + 1)...].firstIndex(where: { !$0.text.isEmpty })
      let beforeChar = before?.text.last
      let afterChar = afterIndex.flatMap { result[$0].text.first }
      guard beforeChar == nil || beforeChar == "/", afterChar == nil || afterChar == "/" else {
        continue
      }
      if let afterIndex, afterChar == "/" {
        result[afterIndex] = KeyTemplateSegment(
          kind: result[afterIndex].kind, text: String(result[afterIndex].text.dropFirst()))
      } else if beforeChar == "/",
        let beforeIndex = result[..<index].lastIndex(where: { !$0.text.isEmpty })
      {
        result[beforeIndex] = KeyTemplateSegment(
          kind: result[beforeIndex].kind, text: String(result[beforeIndex].text.dropLast()))
      }
    }
    result.removeAll { $0.text.isEmpty }

    let keyErrors = renderedKeyErrors(result.map(\.text).joined())
    guard keyErrors.isEmpty else { throw KeyTemplateError.invalid(keyErrors) }
    return result
  }

  /// The template's errors and warnings for this key prefix,
  /// and — when there are no errors — the example key for `photo.png`.
  public static func evaluate(
    _ template: String,
    keyPrefix: String,
    date: Date = Date()
  ) -> KeyTemplateEvaluation {
    let parsed = parse(template)
    let warnings = templateWarnings(template, parsed, keyPrefix: keyPrefix)
    var errors = templateErrors(template, parsed)
    var example: [KeyTemplateSegment]?
    if errors.isEmpty {
      do {
        example = try segments(
          template: template, keyPrefix: keyPrefix, originalFilename: sampleFilename,
          sha256: sampleSHA256, fileExtension: sampleExtension, date: date)
      } catch let KeyTemplateError.invalid(issues) {
        errors = issues
      } catch {
        // The sample's hash and extension are valid by construction.
        preconditionFailure("\(error)")
      }
    }
    return KeyTemplateEvaluation(errors: errors, warnings: warnings, example: example)
  }

  /// The template a project stores: nil for the default.
  public static func storedValue(for template: String) -> String? {
    template == defaultTemplate ? nil : template
  }

  // MARK: - Parsing

  enum Token: Equatable {
    case literal(String)
    case placeholder(KeyTemplatePlaceholder)
  }

  struct Parsed {
    var tokens: [Token] = []
    var unknownPlaceholders: [String] = []
    /// 1-based character positions of braces that do not pair up.
    var unmatchedBraces: [Int] = []
    /// Character offsets of each known placeholder, braces included.
    var placeholderSpans: [(span: Range<Int>, placeholder: KeyTemplatePlaceholder)] = []
    /// Character offsets of each `{…}` that is not a placeholder: an unknown
    /// name with its braces, an unclosed `{` up to where its name stops, a
    /// stray `}`.
    var invalidSpans: [Range<Int>] = []
  }

  static func parse(_ template: String) -> Parsed {
    var parsed = Parsed()
    let characters = Array(template)
    var literal = ""
    var index = 0
    func flush() {
      if !literal.isEmpty { parsed.tokens.append(.literal(literal)) }
      literal = ""
    }
    while index < characters.count {
      let character = characters[index]
      if character == "}" {
        parsed.unmatchedBraces.append(index + 1)
        parsed.invalidSpans.append(index..<(index + 1))
        index += 1
        continue
      }
      guard character == "{" else {
        literal.append(character)
        index += 1
        continue
      }
      var end = index + 1
      while end < characters.count, characters[end] != "}", characters[end] != "{" {
        end += 1
      }
      guard end < characters.count, characters[end] == "}" else {
        parsed.unmatchedBraces.append(index + 1)
        parsed.invalidSpans.append(index..<end)
        index += 1
        continue
      }
      let name = String(characters[(index + 1)..<end])
      flush()
      if let placeholder = KeyTemplatePlaceholder(rawValue: name) {
        parsed.tokens.append(.placeholder(placeholder))
        parsed.placeholderSpans.append(((index..<(end + 1)), placeholder))
      } else {
        parsed.unknownPlaceholders.append(name)
        parsed.invalidSpans.append(index..<(end + 1))
        // Kept as text so later rules see the template's shape.
        parsed.tokens.append(.literal(""))
      }
      index = end + 1
    }
    flush()
    return parsed
  }

  /// The template as the settings field draws it — tokens,
  /// literal text, and the `{…}` that are not placeholders — each with its
  /// range in `template`. The parts cover the template in order; read off
  /// the same parse that renders keys.
  public static func parts(of template: String) -> [KeyTemplatePart] {
    let parsed = parse(template)
    let characters = Array(template.indices)
    var kinds = [KeyTemplatePart.Kind](repeating: .literal, count: characters.count)
    // A run of one kind is one part, except that each placeholder is its own.
    var starts = Set<Int>()
    for (span, placeholder) in parsed.placeholderSpans {
      for offset in span { kinds[offset] = .placeholder(placeholder) }
      starts.insert(span.lowerBound)
    }
    for span in parsed.invalidSpans {
      for offset in span { kinds[offset] = .invalid }
      starts.insert(span.lowerBound)
    }
    guard !characters.isEmpty else { return [] }
    var parts: [KeyTemplatePart] = []
    var start = 0
    for offset in 1...characters.count where offset == characters.count
      || kinds[offset] != kinds[start] || starts.contains(offset)
    {
      let upper = offset == characters.count ? template.endIndex : characters[offset]
      parts.append(KeyTemplatePart(kind: kinds[start], range: characters[start]..<upper))
      start = offset
    }
    return parts
  }

  // MARK: - Checks

  private static let allowedLiteral = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/")

  static func templateErrors(_ template: String, _ parsed: Parsed) -> [KeyTemplateIssue] {
    if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return [KeyTemplateIssue(code: .empty, message: "Template is empty.")]
    }
    var issues: [KeyTemplateIssue] = []
    for name in unique(parsed.unknownPlaceholders) {
      issues.append(
        KeyTemplateIssue(code: .unknownPlaceholder, message: "Unknown placeholder {\(name)}."))
    }
    for position in parsed.unmatchedBraces {
      issues.append(
        KeyTemplateIssue(
          code: .unmatchedBrace, message: "Unmatched brace at position \(position)."))
    }
    let literals = parsed.tokens.compactMap { token -> String? in
      if case let .literal(text) = token { return text }
      return nil
    }
    let disallowed = literals.joined().filter {
      !allowedLiteral.contains($0) && $0 != "{" && $0 != "}"
    }
    for character in unique(disallowed.map { String($0) }) {
      issues.append(
        KeyTemplateIssue(
          code: .disallowedCharacter,
          message: "\"\(character)\" is not allowed in a key template."))
    }
    if !template.hasSuffix(".{ext}") {
      issues.append(
        KeyTemplateIssue(code: .missingExtension, message: "Template must end with .{ext}."))
    }
    if template.hasPrefix("/") || template.hasSuffix("/") || literals.contains(where: {
      $0.contains("//")
    }) {
      issues.append(
        KeyTemplateIssue(
          code: .slashEdges,
          message: "Template can't start or end with \"/\", or contain \"//\"."))
    }
    if template.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
      $0 == "." || $0 == ".."
    }) {
      issues.append(
        KeyTemplateIssue(code: .dotSegment, message: "\".\" and \"..\" can't be a path segment."))
    }
    return issues.sorted { $0.code < $1.code }
  }

  static func renderedKeyErrors(_ key: String) -> [KeyTemplateIssue] {
    var issues: [KeyTemplateIssue] = []
    if key.hasPrefix("/") || key.hasSuffix("/") {
      issues.append(
        KeyTemplateIssue(
          code: .renderedSlashEdges, message: "The key can't start or end with \"/\"."))
    }
    if key.hasPrefix("cdn-cgi/") {
      issues.append(
        KeyTemplateIssue(
          code: .renderedReservedPrefix, message: "The key can't start with \"cdn-cgi/\"."))
    }
    let inner = key.split(separator: "/", omittingEmptySubsequences: false)
    if inner.contains(where: { $0 == "." || $0 == ".." })
      || inner.dropFirst().dropLast().contains(where: \.isEmpty)
    {
      issues.append(
        KeyTemplateIssue(
          code: .renderedBadSegment,
          message: "The key can't have an empty, \".\" or \"..\" path segment."))
    }
    if key.utf8.count > 1024 {
      issues.append(
        KeyTemplateIssue(
          code: .renderedTooLong,
          message: "The key is \(key.utf8.count) bytes; the limit is 1024."))
    }
    return issues
  }

  static func templateWarnings(
    _ template: String, _ parsed: Parsed, keyPrefix: String
  ) -> [KeyTemplateIssue] {
    guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    var issues: [KeyTemplateIssue] = []
    if !parsed.tokens.contains(.placeholder(.hash)) {
      issues.append(
        KeyTemplateIssue(
          code: .noHash,
          message: "Without {hash}, two images can get the same key. Pinax refuses the second upload."))
    }
    let prefix = normalizedPrefix(keyPrefix)
    if !prefix.isEmpty, !parsed.tokens.contains(.placeholder(.prefix)) {
      issues.append(
        KeyTemplateIssue(
          code: .prefixIgnored,
          message: "The key prefix “\(prefix)” isn’t used by this template."))
    }
    return issues
  }

  // MARK: - Values

  /// What a placeholder stands for in the example — the
  /// Insert menu's grey value. Empty for `{prefix}` without a key prefix.
  public static func sampleValue(
    for placeholder: KeyTemplatePlaceholder, keyPrefix: String, date: Date = Date()
  ) -> String {
    value(
      placeholder, keyPrefix: keyPrefix, originalFilename: sampleFilename, sha256: sampleSHA256,
      normalizedExtension: sampleExtension, date: date)
  }

  private static func value(
    _ placeholder: KeyTemplatePlaceholder, keyPrefix: String, originalFilename: String,
    sha256: String, normalizedExtension: String, date: Date
  ) -> String {
    switch placeholder {
    case .prefix: return normalizedPrefix(keyPrefix)
    case .year: return String(format: "%04d", utcComponents(of: date).year)
    case .month: return String(format: "%02d", utcComponents(of: date).month)
    case .day: return String(format: "%02d", utcComponents(of: date).day)
    case .name:
      return slug(
        from: URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent)
    case .hash: return String(sha256.prefix(12))
    case .ext: return normalizedExtension
    }
  }

  /// A key prefix without leading, trailing or repeated `/`.
  public static func normalizedPrefix(_ prefix: String) -> String {
    prefix.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
  }

  private static func kind(_ placeholder: KeyTemplatePlaceholder) -> KeyTemplateSegment.Kind {
    KeyTemplateSegment.Kind(rawValue: placeholder.rawValue)!
  }

  private static func slug(from basename: String) -> String {
    let latin = basename.applyingTransform(.toLatin, reverse: false) ?? basename
    let normalized = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    var result = ""
    result.reserveCapacity(min(normalized.utf8.count, 40))
    var previousWasHyphen = false

    for scalar in normalized.lowercased().unicodeScalars {
      let isLetter = scalar.value >= 97 && scalar.value <= 122
      let isDigit = scalar.value >= 48 && scalar.value <= 57
      if isLetter || isDigit {
        result.unicodeScalars.append(scalar)
        previousWasHyphen = false
      } else if !previousWasHyphen && !result.isEmpty {
        result.append("-")
        previousWasHyphen = true
      }
    }

    result = String(result.prefix(40))
    while result.last == "-" {
      result.removeLast()
    }
    return result.isEmpty ? "image" : result
  }

  private static func utcComponents(of date: Date) -> (year: Int, month: Int, day: Int) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return (components.year!, components.month!, components.day!)
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
}
