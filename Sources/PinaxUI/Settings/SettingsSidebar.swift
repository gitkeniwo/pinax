import SwiftUI

private typealias Metrics = DesignMetrics.settings

extension SettingsTab {
  /// The page's name, in the sidebar and over its content.
  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .dropZone: "Drop Zone"
    case .gallery: "Gallery"
    case .projects: "Projects"
    case .backends: "Backends"
    case .maintenance: "Maintenance"
    }
  }

  /// Projects and Backends add a list column between sidebar and detail.
  var hasListColumn: Bool { self == .projects || self == .backends }

  /// The sidebar's rows in order, a gap before Drop Zone, Projects and
  /// Maintenance.
  static let sidebarGroups: [[SettingsTab]] = [
    [.general, .appearance], [.dropZone, .gallery], [.projects, .backends], [.maintenance],
  ]
}

/// The settings window's sidebar: a native sidebar list,
/// its selected row on the main sidebar's teal plate in white, each row an
/// icon and the page's name in the main sidebar's type and colour; the system sidebar material runs
/// to the window's top edge, the rows starting under the traffic lights.
struct SettingsSidebar: View {
  @Binding var selection: SettingsTab
  var width = Metrics.sidebarWidth

  var body: some View {
    List(selection: Binding<SettingsTab?>(
      get: { selection }, set: { if let tab = $0 { selection = tab } })
    ) {
      ForEach(SettingsTab.sidebarGroups, id: \.self) { group in
        Section {
          ForEach(group, id: \.self) { tab in
            HStack(spacing: Metrics.sidebarIconSpacing) {
              SettingsIcon(kind: tab, size: Metrics.sidebarIconSize, rimmed: tab == selection)
              Text(tab.title)
                .pinaxRowTitle()
            }
            .foregroundStyle(
              tab == selection ? AnyShapeStyle(.white) : AnyShapeStyle(PinaxPalette.Settings.sidebarText))
            .tag(tab)
            // The main sidebar's teal plate, not the system accent.
            .listRowBackground(SidebarSelectionPlate(isSelected: tab == selection))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .padding(.top, Metrics.sidebarListTopInset)
    .background(SidebarMaterialBackground())
    .frame(width: width)
  }
}
