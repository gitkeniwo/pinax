import AppKit
import UniformTypeIdentifiers

/// The item a drag out of the grid or table hands
/// the receiver — text and a URL, never the file.
public enum AssetDrag {
  /// The types a drag of `memberCount` assets offers, in the order a
  /// receiver sees them. A provider holds one URL, so a multiple drag
  /// offers its text alone rather than naming one asset's URL for all.
  public static func typeIdentifiers(memberCount: Int) -> [String] {
    memberCount == 1
      ? [UTType.utf8PlainText.identifier, UTType.url.identifier]
      : [UTType.utf8PlainText.identifier]
  }

  public static func itemProvider(text: String, urls: [String]) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all
    ) { completion in
      completion(Data(text.utf8), nil)
      return nil
    }
    if urls.count == 1, let url = URL(string: urls[0]) {
      provider.registerObject(url as NSURL, visibility: .all)
    }
    return provider
  }
}
