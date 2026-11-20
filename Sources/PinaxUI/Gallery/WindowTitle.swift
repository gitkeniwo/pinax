import CatalogCore

/// The window's title and subtitle: the
/// title names the sidebar's leaf row, the subtitle the current project —
/// its name, or "All Projects". The surface's count shows on the status
/// bar's left side; its sentence is built here.
///
/// Pure so every selection can be asserted without a window. The count
/// sentence obeys the status bar's honesty rule: a real `COUNT`
/// (`totalCount`), "N of M" only when the unfiltered twin exists, and
/// "N loaded" — what is actually known — when the count is unavailable.
struct WindowTitle: Equatable {
  let title: String
  let subtitle: String

  static func compose(
    selection: SidebarSelection, projects: [ProjectSummary], currentProjectSlug: String?,
    backends: [DomainBackend] = []
  ) -> WindowTitle {
    WindowTitle(
      title: leafLabel(selection, projects: projects, backends: backends),
      subtitle: currentProjectName(currentProjectSlug, projects: projects))
  }

  /// The current project's name, its slug while the names are loading, or
  /// "All Projects".
  static func currentProjectName(_ slug: String?, projects: [ProjectSummary]) -> String {
    guard let slug else { return "All Projects" }
    return projects.first(where: { $0.slug == slug })?.name ?? slug
  }

  /// "1,204 assets" / "38 of 1,204 assets" / "120 loaded" / "" (nothing known).
  static func countSentence(totalCount: Int?, unfilteredTotalCount: Int?, rowsCount: Int) -> String {
    if let total = totalCount {
      if let unfiltered = unfilteredTotalCount {
        return "\(total.formatted()) of \(unfiltered.formatted()) assets"
      }
      return PinaxFormat.count(total, singular: "asset")
    }
    return rowsCount > 0 ? "\(rowsCount.formatted()) loaded" : ""
  }

  /// The label the sidebar draws for the selected row (`SidebarModel.sections`).
  private static func leafLabel(
    _ selection: SidebarSelection, projects: [ProjectSummary], backends: [DomainBackend]
  ) -> String {
    switch selection {
    case .all: return "All Assets"
    case .recent: return "Recent"
    case .favorites: return "Favorites"
    case .archived: return "Archived"
    case .orphans: return "Orphans"
    case .externals: return "Externals"
    case .overview: return "Overview"
    case .usage: return "Usage"
    case .project(let slug):
      return projects.first(where: { $0.slug == slug })?.name ?? slug
    case .tag(let name): return name
    case .year(let year): return year
    case .month(let month):
      let parts = PinaxFormat.monthTitle(month)
      return parts.year.isEmpty ? parts.month : "\(parts.month) \(parts.year)"
    case .keyPrefix(let prefix, _):
      return prefix.split(separator: "/").last.map(String.init) ?? prefix
    case .backend(let slug):
      // The root's name: the backend's slug.
      return slug
    case .label(let label): return label.title
    // The row's own name.
    case .projectFolder(_, let directory):
      return directory.split(separator: "/").last.map(String.init) ?? "/"
    case .projectFile(_, let path):
      return path.split(separator: "/").last.map(String.init) ?? path
    }
  }
}
