import CatalogCore
import SwiftUI

/// Sources' second group: whether the project is rescanned without being
/// asked, when its folders change and on a schedule. Both are off until the
/// user turns them on, and both wait for a first source.
struct ProjectAutomationGroup: View {
  let row: ProjectSettingsRow
  @ObservedObject var model: ProjectSettingsModel

  static let watchTitle = "Rescan when files change"
  static let watchNote = "Folders only."
  static let scheduleTitle = "Scheduled scan"

  static func title(_ schedule: ProjectAutoScan.Schedule) -> String {
    switch schedule {
    case .off: return "Off"
    case .hourly: return "Hourly"
    case .daily: return "Daily"
    }
  }

  var isEnabled: Bool { !row.sources.isEmpty }

  var watch: Binding<Bool> {
    Binding(
      get: { row.autoScan.watch },
      set: { write(watch: $0, schedule: row.autoScan.schedule) })
  }

  var schedule: Binding<ProjectAutoScan.Schedule> {
    Binding(
      get: { row.autoScan.schedule },
      set: { write(watch: row.autoScan.watch, schedule: $0) })
  }

  private func write(watch: Bool, schedule: ProjectAutoScan.Schedule) {
    model.setAutoScan(ProjectAutoScan(watch: watch, schedule: schedule), forProject: row.slug)
  }

  var body: some View {
    SettingsGroup {
      SettingsRow(Self.watchTitle, subtitle: Self.watchNote) {
        SettingsRowSwitch(Self.watchTitle, isOn: watch)
          .disabled(!isEnabled)
      }
      SettingsRowDivider()
      SettingsRow(Self.scheduleTitle) {
        SettingsMenuPicker(Self.scheduleTitle, selection: schedule) {
          ForEach(ProjectAutoScan.Schedule.allCases, id: \.self) { choice in
            Text(Self.title(choice)).tag(choice)
          }
        } label: {
          Text(Self.title(row.autoScan.schedule))
        }
        .disabled(!isEnabled)
      }
    }
  }
}
