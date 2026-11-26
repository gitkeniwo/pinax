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
