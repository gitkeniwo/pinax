import CatalogCore
import Foundation

/// One row of the title-area project picker: All
/// Projects (`slug` nil) or a project, its name over a secondary line.
struct ProjectPickerRow: Identifiable, Equatable {
  let slug: String?
  let name: String
  let detail: String

  /// All Projects has no slug; no project's slug is empty.
  var id: String { slug ?? "" }
}

/// The picker's two sections, as Xcode's branch popover draws them: the
/// current row alone, then the rest with All Projects first. Both are
/// filtered; the keyboard walks `rows`, top to bottom.
struct ProjectPickerSections: Equatable {
  let current: [ProjectPickerRow]
  let others: [ProjectPickerRow]

  var rows: [ProjectPickerRow] { current + others }
}

enum ProjectPicker {
  /// The rows for `projects`, the current one (a slug no longer in the
  /// list reads as All Projects, like the preference) and the Find text,
  /// matched against name and slug, case-insensitively.
  static func sections(
    projects: [ProjectSummary], sourced: Set<String>, current: String?, query: String,
    now: Date = Date()
  ) -> ProjectPickerSections {
    let all = ProjectPickerRow(
      slug: nil, name: "All Projects",
      detail: PinaxFormat.count(projects.count, singular: "project"))
    let rows = [all] + projects.map { project in
      ProjectPickerRow(
        slug: project.slug, name: project.name,
        detail: detail(project, sourced: sourced.contains(project.slug), now: now))
    }
    let currentID = projects.contains { $0.slug == current } ? current : nil
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown = rows.filter { row in
      needle.isEmpty
        || row.name.localizedCaseInsensitiveContains(needle)
        || (row.slug?.localizedCaseInsensitiveContains(needle) ?? false)
    }
    return ProjectPickerSections(
      current: shown.filter { $0.slug == currentID },
      others: shown.filter { $0.slug != currentID })
  }

  /// "83 assets · Scanned 2 days ago", "… · No sources", "… · Never scanned".
  static func detail(_ project: ProjectSummary, sourced: Bool, now: Date) -> String {
    let count = PinaxFormat.count(project.assetCount, singular: "asset")
    let scan: String
    if !sourced {
      scan = "No sources"
    } else if let lastScanAt = project.lastScanAt {
      scan = "Scanned \(PinaxFormat.relativeDate(lastScanAt, now: now))"
    } else {
      scan = "Never scanned"
    }
    return "\(count) · \(scan)"
  }
}

/// A project row's ⋯ menu, as values: what each item says, whether it is
/// enabled, and what it does — the view renders exactly these.
struct ProjectRowMenu {
  struct Item: Identifiable {
    let title: String
    let isEnabled: Bool
    /// The view opens the Settings window after `action`.
    let opensSettings: Bool
    let action: () -> Void

    var id: String { title }
  }

  let items: [Item]
}
