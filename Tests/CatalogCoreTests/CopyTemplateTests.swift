import CatalogCore
import Testing

/// Template rendering is a pure function of the template and the fields;
/// unknown placeholders are left as written and reported.
@Suite struct CopyTemplateTests {
  private let fields = CopyFields(
    url: "https://img.example.com/blog/a.png", filename: "Screen Shot.v2.png",
    width: 800, height: 600, key: "blog/a.png", projects: ["blog", "notes"])

  @Test("Each placeholder renders its own field", arguments: [
    ("{url}", "https://img.example.com/blog/a.png"),
    ("{filename}", "Screen Shot.v2.png"),
    ("{name}", "Screen Shot.v2"),
    ("{width}", "800"),
    ("{height}", "600"),
    ("{key}", "blog/a.png"),
    ("{project}", "blog, notes"),
  ])
  func placeholder(template: String, expected: String) {
    #expect(CopyTemplate.render("<" + template + ">", fields: fields) == "<" + expected + ">")
  }

  @Test("Missing dimensions and projects render empty")
  func missingValues() {
    var bare = fields
    bare.width = nil
    bare.height = nil
    bare.projects = []
    #expect(CopyTemplate.render("{width}x{height}|{project}|", fields: bare) == "x||")
  }

  @Test("Several assets render one line each, in order")
  func lines() {
    var second = fields
    second.key = "blog/b.png"
    #expect(CopyTemplate.render("{key}", lines: [second, fields]) == "blog/b.png\nblog/a.png")
  }

  @Test("Unknown placeholders stay as written and are reported")
  func unknownPlaceholders() {
    let template = "{url} {URL} {nmae} {} {url"
    #expect(
      CopyTemplate.render(template, fields: fields)
        == "https://img.example.com/blog/a.png {URL} {nmae} {} {url")
    #expect(CopyTemplate.unknownPlaceholders(in: template) == ["{URL}", "{nmae}"])
    #expect(
      CopyTemplate.unknownPlaceholders(
        in: CopyTemplate.placeholders.map { "{\($0)}" }.joined()
      ).isEmpty)
  }
}
