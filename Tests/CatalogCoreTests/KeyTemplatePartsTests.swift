import CatalogCore
import Foundation
import Testing

/// The read-only parse with ranges the
/// settings field draws its tokens from, and the Insert menu's sample values.
@Suite struct KeyTemplatePartsTests {
  private let october = ISO8601DateFormatter().date(from: "2026-10-27T23:30:00Z")!

  /// Each part as (kind, the template text it covers).
  private func parts(_ template: String) -> [(KeyTemplatePart.Kind, String)] {
    KeyTemplate.parts(of: template).map { ($0.kind, String(template[$0.range])) }
  }

  @Test("The default template splits into its seven tokens and literals")
  func defaultParts() {
    let parsed = parts(KeyTemplate.defaultTemplate)
    #expect(parsed.map(\.0) == [
      .placeholder(.prefix), .literal, .placeholder(.year), .placeholder(.month), .literal,
      .placeholder(.name), .literal, .placeholder(.hash), .literal, .placeholder(.ext),
    ])
    #expect(parsed.map(\.1) == [
      "{prefix}", "/", "{year}", "{month}", "/", "{name}", "-", "{hash}", ".", "{ext}",
    ])
  }

  @Test("A misspelt or unclosed {…} and a stray } are invalid ranges, not tokens")
  func invalidRanges() {
    let parsed = parts("{prefix}/{nme}-{hash}.{ext")
    #expect(parsed.map(\.0) == [
      .placeholder(.prefix), .literal, .invalid, .literal, .placeholder(.hash), .literal, .invalid,
    ])
    #expect(parsed.map(\.1) == ["{prefix}", "/", "{nme}", "-", "{hash}", ".", "{ext"])

    // An unclosed { stops at the next {, which can still open a token.
    let reopened = parts("a{b{name}}.{ext}")
    #expect(reopened.map(\.1) == ["a", "{b", "{name}", "}", ".", "{ext}"])
    #expect(reopened.map(\.0) == [
      .literal, .invalid, .placeholder(.name), .invalid, .literal, .placeholder(.ext),
    ])
  }

  @Test("The parts cover the template exactly, beyond ASCII too")
  func partsCoverTemplate() {
    for template in ["", "{prefix}/ü😀/{name}.{ext}", "}}{", "{year}{month}{day}"] {
      #expect(KeyTemplate.parts(of: template).map { String(template[$0.range]) }.joined() == template)
    }
    #expect(KeyTemplate.parts(of: "").isEmpty)
  }

  @Test("The Insert menu's sample values: the prefix, UTC date, photo, the sample hash, png")
  func sampleValues() {
    let values = KeyTemplate.placeholders.map {
      KeyTemplate.sampleValue(for: $0, keyPrefix: "/blog/", date: october)
    }
    #expect(values == ["blog", "2026", "10", "27", "photo", "3fa9c2e1b07d", "png"])
    #expect(KeyTemplate.sampleValue(for: .prefix, keyPrefix: "", date: october) == "")
    // The same values the example key is built from.
    #expect(
      KeyTemplate.evaluate(KeyTemplate.defaultTemplate, keyPrefix: "blog", date: october).exampleKey
        == "blog/202610/photo-3fa9c2e1b07d.png")
  }
}
