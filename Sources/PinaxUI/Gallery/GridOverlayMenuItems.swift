import SwiftUI

/// The grid-metadata choices, written once for the two menus that
/// offer them: View ▸ Show and the jump bar's display-options menu.
/// Both hand in a binding to the one preference — the
/// store and the gallery model mirror each other both ways (`PinaxAppModel`)
/// — so a change in either menu is the checkmark the other one reads.
struct GridOverlayMenuItems: View {
  @Binding var overlays: GridOverlayOptions

  var body: some View {
    // The filename is the cell's own caption, not metadata, so the master
    // switch leaves it alone.
    Toggle("Filename Below Thumbnail", isOn: $overlays.showsFilename)

    Divider()

    Picker("Grid Metadata", selection: $overlays.metadataVisibility) {
      ForEach(GridOverlayOptions.MetadataVisibility.allCases) { visibility in
        Text(visibility.label).tag(visibility)
      }
    }

    Divider()

    Group {
      Toggle("Upload Date Below Filename", isOn: $overlays.showsUploadDateBelowImage)
      cornerPicker("First Field", selection: $overlays.leadingCorner)
      cornerPicker("Second Field", selection: $overlays.trailingCorner)
    }
    .disabled(overlays.metadataVisibility == .off)
  }

  private func cornerPicker(
    _ title: String, selection: Binding<GridOverlayOptions.CornerField>
  ) -> some View {
    Picker(title, selection: selection) {
      ForEach(GridOverlayOptions.CornerField.allCases) { field in
        Text(field.label).tag(field)
      }
    }
  }
}
