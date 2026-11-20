import CatalogCore
import Foundation

/// The Externals page's order. Only what the
/// scan already gives — upload time and size would need a HEAD per object.
public struct ExternalSort: Equatable, Sendable {
  public enum Field: String, CaseIterable, Sendable {
    /// The referencing file, then the line: Usage's own order.
    case usedIn
    case name
    /// Problems first: the import's failure categories, in their own order.
    case status
    case kind
    /// The domain column's reference count (the Refs header). It orders
    /// the groups, not the rows inside them.
    case refs
  }

  public var field: Field
  public var direction: AssetSort.Direction

  public init(field: Field = .usedIn, direction: AssetSort.Direction = .ascending) {
    self.field = field
    self.direction = direction
  }

  /// A column header's click: the shown column turns around; another one
  /// sorts by itself. Refs opens largest first — a count column's useful
  /// end — every other column ascending, a table header's rule.
  public func clicking(_ field: Field) -> ExternalSort {
    if field == self.field {
      return ExternalSort(
        field: field, direction: direction == .ascending ? .descending : .ascending)
    }
    return ExternalSort(field: field, direction: field == .refs ? .descending : .ascending)
  }

  /// "usedIn.ascending", the gallery sort's stored shape; garbage reads as
  /// the default.
  public var stored: String { "\(field.rawValue).\(direction.rawValue)" }

  public init(stored: String?) {
    let parts = (stored ?? "").split(separator: ".").map(String.init)
    guard parts.count == 2, let field = Field(rawValue: parts[0]),
      let direction = AssetSort.Direction(rawValue: parts[1])
    else {
      self.init()
      return
    }
    self.init(field: field, direction: direction)
  }

  /// The sort menu's and the column headers' names.
  public static func title(_ field: Field) -> String {
    switch field {
    case .usedIn: "Used In"
    case .name: "Name"
    case .status: "Status"
    case .kind: "Kind"
    case .refs: "Refs"
    }
  }
}

/// The ⓘ popover's words: a sentence for
/// each half, then one line of facts.
public struct ExternalsInfo: Equatable, Sendable {
  public let notes: [ReportNote]
  public let facts: String
}

/// The first-visit card's words.
public enum ExternalsTip {
  public static let title = "These images aren’t in your catalog yet"
  public static let message =
    "They’re on your own domain, so Pinax can add them where they are. "
    + "Other Domains only lists links to other sites."
}

extension ExternalsModel {
  // MARK: - Order and groups

  /// `rows` in `sort`'s order. Every field falls back to Used In, so equal
  /// names or kinds still read in file-and-line order; descending turns
  /// the whole order around.
  public static func ordered(
    _ rows: [ExternalReference], by sort: ExternalSort,
    failure: (ExternalReference) -> ExternalImportFailure.Category?
  ) -> [ExternalReference] {
    let categories = ExternalImportFailure.Category.allCases
    func status(_ row: ExternalReference) -> Int {
      failure(row).flatMap { categories.firstIndex(of: $0) } ?? categories.count
    }
    func usedIn(_ lhs: ExternalReference, _ rhs: ExternalReference) -> Bool {
      let left = UsageReferenceRow.split(lhs.sourceReference)
      let right = UsageReferenceRow.split(rhs.sourceReference)
      return (lhs.projectSlug, left.file, left.line ?? .max, lhs.rawURL, lhs.kind)
        < (rhs.projectSlug, right.file, right.line ?? .max, rhs.rawURL, rhs.kind)
    }
    func precedes(_ lhs: ExternalReference, _ rhs: ExternalReference) -> Bool {
      switch sort.field {
      case .usedIn:
        break
      case .name:
        let order = ExternalsView.filename(lhs).localizedStandardCompare(ExternalsView.filename(rhs))
        if order != .orderedSame { return order == .orderedAscending }
      case .status:
        let left = status(lhs)
        let right = status(rhs)
        if left != right { return left < right }
      case .kind:
        let order = lhs.kind.localizedStandardCompare(rhs.kind)
        if order != .orderedSame { return order == .orderedAscending }
      case .refs:
        // A group-level count: rows keep Used In's order inside them.
        break
      }
      return usedIn(lhs, rhs)
    }
    return sort.direction == .ascending
      ? rows.sorted(by: precedes) : rows.sorted { precedes($1, $0) }
  }

  /// Group by File: a group per referencing file, in the order its first
  /// row comes; rows keep `sorted`'s order. The header is the file's path,
  /// after the project when the scope is All Projects.
  public static func fileGroups(_ sorted: [ExternalReference], showsProject: Bool)
    -> [ExternalGroup]
  {
    var order: [String] = []
    var grouped: [String: ExternalGroup] = [:]
    for row in sorted {
      let file = UsageReferenceRow.split(row.sourceReference).file
      let id = "file\u{0}\(row.projectSlug)\u{0}\(file)"
      if grouped[id] == nil {
        order.append(id)
        grouped[id] = ExternalGroup(
          id: id, host: showsProject ? "\(row.projectSlug) · \(file)" : file, match: nil,
          rows: [], isFile: true)
      }
      grouped[id]?.rows.append(row)
    }
    return order.compactMap { grouped[$0] }
  }

  // MARK: - ⓘ and the first-visit card

  /// The popover's words for a scope (nil = All Projects), the shown
  /// half's host count and how many of its rows an import found missing.
  public static func info(scope: String?, hosts: Int, notFound: Int) -> ExternalsInfo {
    var facts = [
      scope.map { "From the latest scan of \($0)" } ?? "From the latest scans of all projects",
      PinaxFormat.count(hosts, singular: "host"),
    ]
    if notFound > 0 { facts.append("\(notFound.formatted()) not found") }
    return ExternalsInfo(
      notes: [
        ReportNote(
          heading: "Your Domains",
          lines: [
            "On your backends’ domains but not in the catalog — usually uploaded by another "
              + "tool, removed outside Pinax, or mistyped. Import them to track their usage."
          ]),
        ReportNote(
          heading: "Other Domains",
          lines: ["Hosted elsewhere. Pinax lists them and never loads them."]),
      ],
      facts: facts.joined(separator: " · "))
  }

  /// This page's popover.
  public var info: ExternalsInfo {
    var rows: [ExternalReference] = []
    if case let .results(shown) = presentation { rows = shown }
    let hosts = Set(rows.map { URL(string: $0.rawURL)?.host?.lowercased() ?? "" })
    let notFound = rows.filter { importFailure($0)?.category == .notFound }.count
    return Self.info(scope: selectedProjectSlug, hosts: hosts.count, notFound: notFound)
  }

  /// The card shows on Your Domains, with rows, until its ✕.
  public var showsTip: Bool {
    guard !isTipDismissed, domain == .yours, case let .results(rows) = presentation else {
      return false
    }
    return !rows.isEmpty
  }
}
