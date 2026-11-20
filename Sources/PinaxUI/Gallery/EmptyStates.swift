import SwiftUI

/// Every empty state in the app. `EmptyStates.text(for:)` is the one
/// place the words live, and the tests pin them line by line, so a
/// rewording changes the tests too.
public enum EmptyStateKind: Equatable, Sendable {
  /// An asset view with no results and no search.
  case noAssets
  /// A key prefix with nothing under it.
  case emptyFolder
  case noOrphanCandidates
  /// Every project with assets has never completed a scan.
  case usageUnknown(projects: [String])
  /// The sentence says what to do next — scan the
  /// project's sources, or add one first.
  case noCompletedScan(project: String, hasSources: Bool)
  case noReferences
  case noExternalReferences
  case noBackends
  case noProjects
  case couldNotOpenCatalog(error: String)
  /// The inspector with nothing selected on an asset surface:
  /// Grid / Table / Usage / Orphans.
  case noSelection
  /// The inspector on Overview, which has nothing to select.
  case nothingToInspect
  /// The inspector on Externals with no reference picked.
  case noReferenceSelected
}

public enum EmptyStates {
  /// The state's title (three words at most) and its one sentence, if any.
  public static func text(for kind: EmptyStateKind) -> (title: String, description: String?) {
    switch kind {
    case .noAssets:
      return ("No Assets", "Drop images on the drop zone or press ⌘U to upload.")
    case .emptyFolder:
      return ("Empty Folder", "No assets under this prefix.")
    case .noOrphanCandidates:
      return ("No Orphan Candidates", "Every active asset was seen in the latest scans.")
    case .usageUnknown(let projects):
      return (
        "Usage Unknown",
        "Scan \(projects.joined(separator: ", ")) before reading this list.")
    case .noCompletedScan(let project, let hasSources):
      return (
        "No Completed Scan",
        hasSources
          ? "Scan \(project)'s sources to see its references."
          : "Add a source folder for \(project) to scan it.")
    case .noReferences:
      return ("No References", "The latest completed scan found no references.")
    case .noExternalReferences:
      return ("No External References", "Every scanned URL matches a catalog asset.")
    case .noBackends:
      return ("No Backends", "Add a backend to start uploading.")
    case .noProjects:
      return ("No Projects", "Create a project to group uploads.")
    case .couldNotOpenCatalog(let error):
      return ("Could Not Open Catalog", error)
    case .noSelection:
      return ("No Selection", "Select an image to see its details.")
    case .nothingToInspect:
      return ("Nothing to Inspect", "Overview summarizes the whole project.")
    case .noReferenceSelected:
      return ("No Selection", "Pick a reference to see its link and where it's used.")
    }
  }

  /// The state's SF Symbol.
  public static func symbol(for kind: EmptyStateKind) -> String {
    switch kind {
    case .noAssets: return "photo.on.rectangle.angled"
    case .emptyFolder: return "folder"
    case .noOrphanCandidates: return "checkmark.circle"
    case .usageUnknown, .noCompletedScan: return "questionmark.circle"
    case .noReferences, .noExternalReferences: return "link"
    case .noBackends: return "externaldrive"
    case .noProjects: return "folder.badge.plus"
    case .couldNotOpenCatalog: return "exclamationmark.triangle"
    case .noSelection, .noReferenceSelected: return "photo"
    case .nothingToInspect: return "chart.bar.xaxis"
    }
  }

  /// The inspector's empty state on a surface.
  public static func inspectorKind(on surface: SidebarSelection) -> EmptyStateKind {
    switch surface {
    case .overview: return .nothingToInspect
    case .externals: return .noReferenceSelected
    default: return .noSelection
    }
  }
}

/// The inspector's empty state: quieter than the centre column's
/// `ContentUnavailableView` — a faint glyph, a semibold title and one hint
/// line, a little above the middle of the column.
struct InspectorEmptyState: View {
  let kind: EmptyStateKind

  var body: some View {
    let text = EmptyStates.text(for: kind)
    let metrics = DesignMetrics.inspectorEmpty.self
    VStack(spacing: metrics.spacing) {
      Image(systemName: EmptyStates.symbol(for: kind))
        .pinaxGlyph(metrics.glyph, weight: .light)
        .foregroundStyle(.tertiary)
        .opacity(metrics.glyphOpacity)
        .accessibilityHidden(true)
      Text(text.title).pinaxEmptyTitle()
      if let hint = text.description {
        Text(hint).pinaxEmptyHint()
      }
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, metrics.horizontalPadding)
    .padding(.bottom, metrics.bottomPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

/// `ContentUnavailableView` for one `EmptyStateKind`: its symbol, title and
/// sentence from `EmptyStates`, and the state's action when it has one.
extension ContentUnavailableView {
  init(_ kind: EmptyStateKind, @ViewBuilder actions: () -> Actions)
  where Label == SwiftUI.Label<Text, Image>, Description == Text? {
    let text = EmptyStates.text(for: kind)
    self.init {
      SwiftUI.Label(text.title, systemImage: EmptyStates.symbol(for: kind))
    } description: {
      text.description.map(Text.init)
    } actions: {
      actions()
    }
  }

  init(_ kind: EmptyStateKind)
  where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    self.init(kind) { EmptyView() }
  }
}

/// A failure where a list should be — the message as it came, in the
/// empty-state control, for the states that have no empty-state row (a query that
/// failed, a report that did not load).
struct FailureStateView: View {
  let message: String

  var body: some View {
    ContentUnavailableView {
      Label(message, systemImage: "exclamationmark.triangle")
    }
  }
}
