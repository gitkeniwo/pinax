import Foundation

/// One entry of the user's copy-format list — a name
/// for the Copy As menu and a template rendered once per copied asset.
public struct CopyFormat: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var template: String

  public init(id: UUID = UUID(), name: String, template: String) {
    self.id = id
    self.name = name
    self.template = template
  }

  /// The list a fresh install starts with. Fixed ids so the factory default
  /// (URL) can be named before any list has been stored.
  public static let url = CopyFormat(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000F101")!,
    name: "URL", template: "{url}")
  public static let markdown = CopyFormat(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000F102")!,
    name: "Markdown", template: "![{name}]({url})")
  public static let html = CopyFormat(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000F103")!,
    name: "HTML",
    template: #"<img src="{url}" alt="{name}" width="{width}" height="{height}">"#)

  public static let factory: [CopyFormat] = [url, markdown, html]
}

/// The values a template can name, for one asset.
public struct CopyFields: Equatable, Sendable {
  public var url: String
  public var filename: String
  public var width: Int?
  public var height: Int?
  public var key: String
  /// Slugs of the projects the asset belongs to, in the order to print.
  public var projects: [String]

  public init(
    url: String, filename: String, width: Int?, height: Int?, key: String, projects: [String]
  ) {
    self.url = url
    self.filename = filename
    self.width = width
    self.height = height
    self.key = key
    self.projects = projects
  }
}

/// Template rendering, a pure function of the template and the fields.
public enum CopyTemplate {
  public static let placeholders = [
    "url", "filename", "name", "width", "height", "key", "project",
  ]

  /// Replaces every known `{placeholder}`; anything else in braces is left
  /// exactly as written, so a typo shows up in the output instead of
  /// vanishing. A missing width or height renders empty.
  public static func render(_ template: String, fields: CopyFields) -> String {
    tokens(in: template).map { token in
      switch token {
      case let .text(text): return text
      case let .placeholder(name, raw): return value(of: name, in: fields) ?? raw
      }
    }.joined()
  }

  /// One rendered line per asset, in the order given — the text ⌘C, Copy As
  /// and a drag out of the grid or table all carry.
  public static func render(_ template: String, lines fields: [CopyFields]) -> String {
    fields.map { render(template, fields: $0) }.joined(separator: "\n")
  }

  /// The `{word}` tokens in `template` that `render` will leave untouched,
  /// in order of appearance, for the settings list to flag.
  public static func unknownPlaceholders(in template: String) -> [String] {
    tokens(in: template).compactMap { token in
      guard case let .placeholder(name, raw) = token, !placeholders.contains(name) else {
        return nil
      }
      return raw
    }
  }

  private enum Token {
    case text(String)
    /// `{word}`: the word and the braces as written.
    case placeholder(String, String)
  }

  /// Splits on `{word}` where word is letters, digits or `_`; any other
  /// brace (`{}`, an unclosed `{`, `{a b}`) is plain text.
  private static func tokens(in template: String) -> [Token] {
    var tokens: [Token] = []
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{") {
      let after = rest.index(after: open)
      let word = rest[after...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      guard !word.isEmpty, word.endIndex < rest.endIndex, rest[word.endIndex] == "}" else {
        tokens.append(.text(String(rest[...open])))
        rest = rest[after...]
        continue
      }
      tokens.append(.text(String(rest[..<open])))
      let close = rest.index(after: word.endIndex)
      tokens.append(.placeholder(String(word), String(rest[open..<close])))
      rest = rest[close...]
    }
    tokens.append(.text(String(rest)))
    return tokens
  }

  private static func value(of placeholder: String, in fields: CopyFields) -> String? {
    switch placeholder {
    case "url": return fields.url
    case "filename": return fields.filename
    case "name": return (fields.filename as NSString).deletingPathExtension
    case "width": return fields.width.map(String.init) ?? ""
    case "height": return fields.height.map(String.init) ?? ""
    case "key": return fields.key
    case "project": return fields.projects.joined(separator: ", ")
    default: return nil
    }
  }
}
