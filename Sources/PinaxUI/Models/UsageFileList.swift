import CatalogCore
import Foundation

/// Usage ▸ Files' list order: the sort menu over
/// the file list. The dates are the files' own on disk; front matter is not
/// read.
public enum UsageFileSortField: String, CaseIterable, Identifiable, Sendable {
  case name
  case modified
  case created
  case references

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .name: return "Name"
    case .modified: return "Date Modified"
    case .created: return "Date Created"
    case .references: return "References"
    }
  }

  /// The direction a field starts in when picked: names A to Z, dates
  /// newest first, references most first.
  public var startsAscending: Bool { self == .name }

  /// The menu's two direction items, ascending first.
  public var directionLabels: (ascending: String, descending: String) {
    switch self {
    case .name: return ("A to Z", "Z to A")
    case .modified, .created: return ("Oldest First", "Newest First")
    case .references: return ("Fewest First", "Most First")
    }
  }
}

public struct UsageFileSort: Equatable, Sendable {
  public var field: UsageFileSortField
  public var ascending: Bool

  public init(field: UsageFileSortField, ascending: Bool) {
    self.field = field
    self.ascending = ascending
  }

  /// The most recently edited files first.
  public static let standard = UsageFileSort(field: .modified, ascending: false)

  /// Picking a field starts it in its own direction.
  public static func picking(_ field: UsageFileSortField) -> UsageFileSort {
    UsageFileSort(field: field, ascending: field.startsAscending)
  }
}

/// A referencing file's dates on disk; nil for a file Pinax cannot open (an
/// external scanner's reference, a moved file).
public struct UsageFileDates: Equatable, Sendable {
  public let created: Date?
  public let modified: Date?

  public init(created: Date?, modified: Date?) {
    self.created = created
    self.modified = modified
  }

  /// The file system's dates, read once per reload.
  public static func read(_ url: URL) -> UsageFileDates {
    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return UsageFileDates(created: values?.creationDate, modified: values?.contentModificationDate)
  }
}

/// The folder the file list is narrowed to: a project, and the directory
/// components under its source (the display path's). Empty components is
/// the whole project.
public struct UsageFolderScope: Hashable, Sendable {
  public let project: String
  public let components: [String]

  public init(project: String, components: [String]) {
    self.project = project
    self.components = components
  }

  /// Whether a file in `project` whose directory is `directory` sits in it.
  func contains(project: String, directory: [String]) -> Bool {
    project == self.project && directory.starts(with: components)
  }
}

/// One group of the file list: a project's directory, its files in the
/// list's order, and the path's segments, each a scope to enter.
public struct UsageFileListGroup: Identifiable, Equatable, Sendable {
  public let projectSlug: String
  public let directory: [String]
  public let files: [UsageFile]

  public var id: String { ([projectSlug] + directory).joined(separator: "\u{0}") }

  /// "astro › src › content › blog": the project, then each directory.
  public var segments: [(label: String, scope: UsageFolderScope)] {
    [(projectSlug, UsageFolderScope(project: projectSlug, components: []))]
      + directory.indices.map { index in
        (
          directory[index],
          UsageFolderScope(project: projectSlug, components: Array(directory[...index]))
        )
      }
  }

  public var title: String { segments.map(\.label).joined(separator: " › ") }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.files == rhs.files
  }
}

extension UsageBrowser {
  /// A file's directory as the list shows it: the display path's (source
  /// label off), cut into components.
  func displayDirectoryComponents(_ file: UsageFile) -> [String] {
    Self.displayDirectory(file, sources: usage.projectSources)
      .split(separator: "/").map(String.init)
  }

  /// Every file in `sort`'s order; files without the date sorted on go
  /// last, ties by name then project.
  public func sortedFiles(
    by sort: UsageFileSort, dates: [UsageFile.ID: UsageFileDates]
  ) -> [UsageFile] {
    files.sorted { lhs, rhs in
      Self.precedes(lhs, rhs, sort: sort, dates: dates)
    }
  }

  static func precedes(
    _ lhs: UsageFile, _ rhs: UsageFile, sort: UsageFileSort,
    dates: [UsageFile.ID: UsageFileDates]
  ) -> Bool {
    func byName() -> Bool {
      let order = lhs.name.localizedStandardCompare(rhs.name)
      if order != .orderedSame { return order == .orderedAscending }
      return (lhs.projectSlug, lhs.path) < (rhs.projectSlug, rhs.path)
    }
    func byDate(_ date: (UsageFileDates?) -> Date?) -> Bool {
      switch (date(dates[lhs.id]), date(dates[rhs.id])) {
      case let (l?, r?) where l != r: return sort.ascending ? l < r : l > r
      case (.some, nil): return true
      case (nil, .some): return false
      default: return byName()
      }
    }
    switch sort.field {
    case .name:
      return sort.ascending ? byName() : !byName()
    case .modified:
      return byDate { $0?.modified }
    case .created:
      return byDate { $0?.created }
    case .references:
      if lhs.referenceCount != rhs.referenceCount {
        return sort.ascending
          ? lhs.referenceCount < rhs.referenceCount : lhs.referenceCount > rhs.referenceCount
      }
      return byName()
    }
  }

  /// The file list: the files in `scope` (all with nil), in `sort`'s order,
  /// one group per project directory, the groups by project then path.
  public func fileListGroups(
    sort: UsageFileSort, dates: [UsageFile.ID: UsageFileDates], scope: UsageFolderScope?
  ) -> [UsageFileListGroup] {
    var groups: [String: UsageFileListGroup] = [:]
    var order: [String] = []
    for file in sortedFiles(by: sort, dates: dates) {
      let directory = displayDirectoryComponents(file)
      if let scope, !scope.contains(project: file.projectSlug, directory: directory) { continue }
      let group = UsageFileListGroup(projectSlug: file.projectSlug, directory: directory, files: [])
      if let existing = groups[group.id] {
        groups[group.id] = UsageFileListGroup(
          projectSlug: existing.projectSlug, directory: existing.directory,
          files: existing.files + [file])
      } else {
        groups[group.id] = UsageFileListGroup(
          projectSlug: file.projectSlug, directory: directory, files: [file])
        order.append(group.id)
      }
    }
    return order.compactMap { groups[$0] }.sorted {
      ([$0.projectSlug] + $0.directory).lexicographicallyPrecedes([$1.projectSlug] + $1.directory)
    }
  }
}

/// What a Usage ▸ Images grid cell carries for its section: the
/// file it sits under and the image's first line there.
public struct UsageRowSection: Equatable, Sendable {
  public let fileID: UsageFile.ID
  public let line: Int?

  public init(fileID: UsageFile.ID, line: Int?) {
    self.fileID = fileID
    self.line = line
  }
}
