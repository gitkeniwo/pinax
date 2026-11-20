import CatalogCore
import Foundation

/// The Key template block's state — the draft
/// against the stored template, and what shows under the field. Everything
/// it says comes from `KeyTemplate.evaluate`; it writes nothing itself, only
/// through the model on Set or Reset to Default.
struct KeyTemplateEditor: Equatable {
  /// The callout under the field: one issue, the first error or
  /// else the first warning.
  struct Callout: Equatable {
    enum Kind: Equatable { case warning, error }
    let kind: Kind
    let issue: KeyTemplateIssue
  }

  /// One line of the Insert menu: the token and its grey sample value
  /// (none for `prefix` when the key prefix is empty).
  struct InsertItem: Equatable, Identifiable {
    let placeholder: KeyTemplatePlaceholder
    let sample: String?
    var id: KeyTemplatePlaceholder { placeholder }
  }

  /// The stored template, the default when the project stores none.
  let stored: String
  let date: Date
  var draft: String { didSet { evaluate() } }
  /// The Key prefix field as it reads now, so the example follows it.
  var keyPrefix: String { didSet { evaluate() } }
  /// Where Insert puts a token: a UTF-16 offset into `draft`, nil until the
  /// field has had a cursor (then Insert appends).
  var cursor: Int?
  private(set) var evaluation: KeyTemplateEvaluation

  init(stored: String?, keyPrefix: String, date: Date = Date()) {
    let template = stored ?? KeyTemplate.defaultTemplate
    self.stored = template
    self.date = date
    self.draft = template
    self.keyPrefix = keyPrefix
    self.evaluation = KeyTemplate.evaluate(template, keyPrefix: keyPrefix, date: date)
  }

  private mutating func evaluate() {
    evaluation = KeyTemplate.evaluate(draft, keyPrefix: keyPrefix, date: date)
  }

  /// A change that has no error.
  var canSet: Bool { draft != stored && evaluation.isValid }

  /// Only while the draft is not the default.
  var showsReset: Bool { draft != KeyTemplate.defaultTemplate }

  var callout: Callout? {
    if let error = evaluation.errors.first { return Callout(kind: .error, issue: error) }
    return evaluation.warnings.first.map { Callout(kind: .warning, issue: $0) }
  }

  /// The example key, absent while an error replaces it.
  var example: [KeyTemplateSegment]? { evaluation.example }

  /// The example as a path: its folders, then the file. The line keeps the
  /// file whole and folds the middle folders into ⋯ when it is cut.
  struct ExamplePath: Equatable {
    let folders: [String]
    let file: String

    var text: String { (folders + [file]).joined(separator: "/") }
  }

  var examplePath: ExamplePath? {
    guard let example else { return nil }
    let parts = example.map(\.text).joined().components(separatedBy: "/")
    return ExamplePath(folders: Array(parts.dropLast()), file: parts.last ?? "")
  }

  /// The clock after the example: only for an example built from a date
  /// placeholder, whose dates are UTC's.
  var showsUTC: Bool {
    example?.contains { [.year, .month, .day].contains($0.kind) } ?? false
  }

  /// "27 Oct 2026, 23:30": the moment the example's dates come from.
  static func utcStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "d MMM yyyy, HH:mm"
    return formatter.string(from: date)
  }

  /// The clock's tip.
  var utcNote: String? { showsUTC ? "Dates use UTC: \(Self.utcStamp(date))." : nil }

  /// The key card's last line: what the example is of, and its dates.
  var sampleNote: String {
    let upload = KeyTemplate.sampleValue(for: .name, keyPrefix: keyPrefix, date: date)
      + "." + KeyTemplate.sampleExtension
    let note = "For a \(upload) uploaded now."
    return showsUTC ? note + " Dates use UTC (\(Self.utcStamp(date)))." : note
  }

  /// The token at the cursor, or at the end with none; the cursor
  /// then sits after it.
  mutating func insert(_ placeholder: KeyTemplatePlaceholder) {
    let text = draft as NSString
    let location = min(cursor ?? text.length, text.length)
    draft = text.replacingCharacters(in: NSRange(location: location, length: 0), with: placeholder.token)
    cursor = location + (placeholder.token as NSString).length
  }

  /// The Insert menu, in `KeyTemplate.placeholders` order.
  static func insertMenu(keyPrefix: String, date: Date = Date()) -> [InsertItem] {
    KeyTemplate.placeholders.map { placeholder in
      let sample = KeyTemplate.sampleValue(for: placeholder, keyPrefix: keyPrefix, date: date)
      return InsertItem(placeholder: placeholder, sample: sample.isEmpty ? nil : sample)
    }
  }

  /// Set, or Return in the field.
  @MainActor
  func submit(to model: ProjectSettingsModel, project slug: String) {
    guard canSet else { return }
    model.setKeyTemplate(draft, forProject: slug)
  }

  /// Reset to Default: stores NULL and puts the default back in the field,
  /// even when NULL was already stored.
  @MainActor
  mutating func reset(to model: ProjectSettingsModel, project slug: String) {
    model.resetKeyTemplate(forProject: slug)
    if model.saveError == nil { draft = KeyTemplate.defaultTemplate }
  }
}
