import CatalogCore
@testable import PinaxUI

/// Every Catalog level belongs to a backend. The fixtures
/// (`makeUITestDatabase`) have one, `r2`; these name "its" level and
/// prefix row so tests need not spell the backend out.
enum FixtureBackend {
  static let slug = "r2"
  static let root = CatalogRoot(slug: slug, prefix: "https://img.example.com", assetCount: 0)
}

extension SidebarSelection {
  /// The fixture backend's prefix row.
  static func keyPrefix(_ prefix: String) -> SidebarSelection {
    .keyPrefix(prefix, backend: FixtureBackend.slug)
  }
}

extension KeyPrefixLevel {
  /// The fixture backend's level under `prefix` (nil: its root).
  static func r2(_ prefix: String?) -> KeyPrefixLevel {
    KeyPrefixLevel(backend: FixtureBackend.slug, prefix: prefix)
  }
}

extension Dictionary where Key == KeyPrefixLevel {
  /// The fixture backend's level by prefix.
  subscript(r2 prefix: String?) -> Value? { self[.r2(prefix)] }
}

extension GalleryModel {
  func loadFolderChildren(under prefix: String?) async {
    await loadFolderChildren(under: .r2(prefix))
  }
}
