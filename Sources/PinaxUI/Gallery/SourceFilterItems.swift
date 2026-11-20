import CatalogCore
import SwiftUI

/// The Source filter's items — the find strip's
/// popup and the toolbar sort menu's Show section draw this one picker over
/// the one `GalleryModel.sourceFilter`, so their checkmarks always agree.
/// Every item carries its count; Other Imports is listed only when it has
/// any (or is the current choice, so the picker never holds an unlisted
/// value).
struct SourceFilterItems: View {
  @Binding var source: AssetSource?
  let counts: GalleryModel.SourceCounts

  var body: some View {
    Picker("Source", selection: $source) {
      ForEach(Self.entries(counts, selected: source), id: \.self) { entry in
        Text(entry.title).tag(entry.source)
      }
    }
    .labelsHidden()
  }

  struct Entry: Hashable {
    let source: AssetSource?
    let title: String
  }

  /// All Sources, then the five sources in order.
  static func entries(_ counts: GalleryModel.SourceCounts, selected: AssetSource?) -> [Entry] {
    var entries = [Entry(source: nil, title: FindStrip.sourceItemTitle("All Sources", counts.all))]
    let sources: [AssetSource] = [.pinax, .picgo, .bucket, .migrated, .otherImport]
    for source in sources {
      if source == .otherImport, counts[source] == 0, selected != source { continue }
      entries.append(Entry(source: source, title: FindStrip.sourceItemTitle(title(source), counts[source])))
    }
    return entries
  }

  static func title(_ source: AssetSource) -> String {
    switch source {
    case .pinax: return "Uploaded by Pinax"
    case .picgo: return "PicGo"
    case .bucket: return "Bucket"
    case .migrated: return "Migrated"
    case .otherImport: return "Other Imports"
    }
  }

  /// The report surfaces (Overview, Orphans, Externals, Usage) list no
  /// assets, so the filter does not apply there — the find strip's
  /// `appliesHere`.
  static func applies(to selection: GalleryModel.SidebarSelection) -> Bool {
    switch selection {
    case .overview, .orphans, .externals, .usage: return false
    default: return true
    }
  }

  /// What the counts depend on: refreshed from the always-present jump bar,
  /// since the sort menu shows them while the find strip is hidden.
  struct CountsKey: Equatable {
    let selection: GalleryModel.SidebarSelection
    let total: Int?
    let unfiltered: Int?
  }
}
