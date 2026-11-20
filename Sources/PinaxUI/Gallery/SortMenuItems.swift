import CatalogCore
import SwiftUI

/// The sort choices, written once for the two menus that offer them: View ▸
/// Sort By and the jump bar's sort menu. Both hand in a
/// binding to the one order — the store and the gallery model mirror each
/// other both ways (`PinaxAppModel`) — so a change in either menu is the
/// checkmark the other one reads, and the table's column headers too.
struct SortMenuItems: View {
  @Binding var sort: AssetSort

  var body: some View {
    Picker("Sort By", selection: $sort.field) {
      ForEach(AssetSort.Field.menuCases, id: \.self) { field in
        Text(Self.title(field)).tag(field)
      }
    }
    .pickerStyle(.inline)
    .labelsHidden()

    Divider()

    Picker("Order", selection: $sort.direction) {
      Text("Ascending").tag(AssetSort.Direction.ascending)
      Text("Descending").tag(AssetSort.Direction.descending)
    }
    .pickerStyle(.inline)
    .labelsHidden()
  }

  /// Finder's names for the same four columns.
  static func title(_ field: AssetSort.Field) -> String {
    switch field {
    case .uploadedAt: return "Date Uploaded"
    case .name: return "Name"
    case .byteSize: return "Size"
    case .kind: return "Kind"
    case .source: return "Source"
    case .domain: return "Domain"
    }
  }
}
