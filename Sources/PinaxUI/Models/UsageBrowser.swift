import CatalogCore
import Foundation

/// The Usage page's two ways in: by image — the library's
/// own grid and table over the referenced assets — or by file.
public enum UsagePage: String, CaseIterable, Hashable, Identifiable, Sendable {
  // Files first: the page Usage opens on.
  case files
  case images

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .images: return "Images"
    case .files: return "Files"
    }
  }
}

/// How Usage's grid cells caption themselves. Images keep
/// the date line (source square + date); Files write the reference's line
/// and mark an image used twice with "same as above".
public enum UsageGridCaption: Equatable, Sendable {
  case none
  case images
  case files
}

/// One reference, read for display: the file is the source reference
/// without its `#L…`, the line the number after it (nil for a reference
/// that carries none — an external scanner's format).
public struct UsageReferenceRow: Identifiable, Equatable, Sendable {
  public let reference: LiveUsageReference
  public let file: String
  public let line: Int?

  public init(_ reference: LiveUsageReference) {
    self.reference = reference
    (file, line) = Self.split(reference.sourceReference)
  }

  public var id: String {
    [reference.projectSlug, reference.sourceReference, reference.rawURL, reference.kind]
      .joined(separator: "\u{0}")
  }

  /// "src/posts/foo.md#L12" → ("src/posts/foo.md", 12).
  public static func split(_ sourceReference: String) -> (file: String, line: Int?) {
    guard let marker = sourceReference.range(of: "#L", options: .backwards),
      let line = Int(sourceReference[marker.upperBound...]), line > 0
    else { return (sourceReference, nil) }
    return (String(sourceReference[..<marker.lowerBound]), line)
  }

  /// Display order inside an image or a file: project, file, line, URL.
  static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
    (lhs.reference.projectSlug, lhs.file, lhs.line ?? .max, lhs.reference.rawURL)
      < (rhs.reference.projectSlug, rhs.file, rhs.line ?? .max, rhs.reference.rawURL)
  }
}

/// One referenced image: its references, how many, whether any is on an
/// old domain.
public struct UsageImage: Equatable, Sendable {
  public let assetID: Int64
  public let references: [UsageReferenceRow]

  public var uses: Int { references.count }
  public var hasOldDomain: Bool { references.contains { $0.reference.isOldDomain } }
}

/// One reference inside a file: the image and the line it sits on. Files
/// list every reference: an image used twice in one file
/// appears twice on the grid, its second cell marked "same as above".
public struct UsageOccurrence: Equatable, Sendable {
  public let assetID: Int64
  public let line: Int?

  public init(assetID: Int64, line: Int?) {
    self.assetID = assetID
    self.line = line
  }
}

/// One referencing file of one project: its images in the order they first
/// appear in it, each with that first line, and every reference in line
/// order.
public struct UsageFile: Identifiable, Equatable, Sendable {
  public let projectSlug: String
  public let path: String
  public let images: [(assetID: Int64, line: Int?)]
  /// Every reference in the file, in line order (the grid's cells).
  public let occurrences: [UsageOccurrence]
  public let referenceCount: Int

  public var id: String { "\(projectSlug)\u{0}\(path)" }
  public var name: String { (path as NSString).lastPathComponent }
  public var directory: String { (path as NSString).deletingLastPathComponent }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.referenceCount == rhs.referenceCount
      && lhs.images.map(\.assetID) == rhs.images.map(\.assetID)
      && lhs.images.map(\.line) == rhs.images.map(\.line)
      && lhs.occurrences == rhs.occurrences
  }
}

/// The Usage page's data, cut from one `LiveUsageSet`. Pure: the tests
/// compute the same lists by hand.
public struct UsageBrowser: Sendable {
  public let usage: LiveUsageSet
  public let oldDomainsOnly: Bool
  /// The domain menu's prefix; nil is All
  /// Domains.
  public let domain: String?
  /// Images by uses, most first; equal counts by file name.
  public let images: [UsageImage]
  /// Files by references, most first; equal counts by project and path.
  public let files: [UsageFile]
  /// Every live reference in the scope, whatever the Old Domains switch
  /// says — what the range bar's summary counts, as the old header did.
  public let totalReferenceCount: Int
  /// The distinct files those references live in.
  public let totalFileCount: Int

  public init(_ usage: LiveUsageSet, oldDomainsOnly: Bool = false, domain: String? = nil) {
    self.usage = usage
    self.oldDomainsOnly = oldDomainsOnly
    self.domain = domain
    // A chosen domain narrows the summary too; the Old
    // Domains switch never did.
    let scoped = usage.references.filter { reference in
      domain.map { DomainHost.isUnder(reference.rawURL, prefix: $0) } ?? true
    }
    totalReferenceCount = scoped.count
    totalFileCount = Set(
      scoped.map {
        "\($0.projectSlug)\u{0}\(UsageReferenceRow.split($0.sourceReference).file)"
      }
    ).count
    let rows = scoped
      .filter { !oldDomainsOnly || $0.isOldDomain }
      .map(UsageReferenceRow.init)
    let byAsset = Dictionary(grouping: rows, by: \.reference.assetID)
    images = byAsset.map { id, references in
      UsageImage(assetID: id, references: references.sorted(by: UsageReferenceRow.precedes))
    }.sorted { lhs, rhs in
      if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
      let order = Self.name(usage.assets[lhs.assetID])
        .localizedStandardCompare(Self.name(usage.assets[rhs.assetID]))
      if order != .orderedSame { return order == .orderedAscending }
      return lhs.assetID < rhs.assetID
    }
    let byFile = Dictionary(grouping: rows) { "\($0.reference.projectSlug)\u{0}\($0.file)" }
    files = byFile.values.map { references in
      let sorted = references.sorted(by: UsageReferenceRow.precedes)
      var seen: Set<Int64> = []
      let images = sorted.compactMap { row -> (assetID: Int64, line: Int?)? in
        seen.insert(row.reference.assetID).inserted ? (row.reference.assetID, row.line) : nil
      }
      return UsageFile(
        projectSlug: sorted[0].reference.projectSlug, path: sorted[0].file, images: images,
        occurrences: sorted.map { UsageOccurrence(assetID: $0.reference.assetID, line: $0.line) },
        referenceCount: references.count)
    }.sorted { lhs, rhs in
      if lhs.referenceCount != rhs.referenceCount { return lhs.referenceCount > rhs.referenceCount }
      return (lhs.projectSlug, lhs.path) < (rhs.projectSlug, rhs.path)
    }
  }

  /// The grid's caption name: the original filename, else the key's last
  /// segment.
  static func name(_ item: CatalogAssetItem?) -> String {
    guard let item else { return "" }
    return item.asset.originalFilename ?? (item.asset.key as NSString).lastPathComponent
  }

  /// The domain menu's figures: the scope's references under `prefix`,
  /// whatever domain is chosen.
  public func links(on prefix: String) -> Int {
    usage.references.count { DomainHost.isUnder($0.rawURL, prefix: prefix) }
  }

  public func image(_ assetID: Int64) -> UsageImage? {
    images.first { $0.assetID == assetID }
  }

  static func displayDirectory(_ file: UsageFile, sources: [String: [ProjectSource]]) -> String {
    let display = UsageSourceFile.displayPath(
      project: file.projectSlug, path: file.path, sources: sources)
    return (display as NSString).deletingLastPathComponent
  }

  /// What the range bar's summary says: the scope's
  /// reference and file counts over every live reference — whatever the Old
  /// Domains switch says, as before — then when the last scan finished,
  /// read as "scanned 2 weeks ago". Without a completed scan there is
  /// nothing to count and the bar says so.
  public enum RangeSummary: Equatable, Sendable {
    case noScan
    case scanned(references: Int, files: Int, scan: String?)

    /// A word or a figure, so the bar can set the numbers semibold in the
    /// primary ink and the words secondary.
    public struct Piece: Equatable, Sendable {
      public let text: String
      public let isFigure: Bool

      public init(_ text: String, isFigure: Bool) {
        self.text = text
        self.isFigure = isFigure
      }
    }

    public var pieces: [Piece] {
      switch self {
      case .noScan:
        return [Piece("No completed scan", isFigure: false)]
      case let .scanned(references, files, scan):
        var parts = [
          Piece(references.formatted(), isFigure: true),
          Piece(" " + Self.word(references, "ref"), isFigure: false),
          Piece(" · ", isFigure: false),
          Piece(files.formatted(), isFigure: true),
          Piece(" " + Self.word(files, "file"), isFigure: false),
        ]
        if let scan {
          parts.append(Piece(" · ", isFigure: false))
          parts.append(Piece(scan, isFigure: false))
        }
        return parts
      }
    }

    public var text: String { pieces.map(\.text).joined() }

    static func word(_ count: Int, _ singular: String) -> String {
      count == 1 ? singular : singular + "s"
    }
  }

  public func rangeSummary(
    projects: [ProjectSummary], now: Date = Date(), locale: Locale = .current
  ) -> RangeSummary {
    guard !usage.scannedProjects.isEmpty else { return .noScan }
    let last = projects.compactMap(\.lastScanAt).max()
    return .scanned(
      references: totalReferenceCount,
      files: totalFileCount,
      scan: last.map { "scanned \(PinaxFormat.relativeDate($0, now: now, locale: locale))" })
  }
}

/// What a library row carries on the Usage page.
public enum UsageRowInfo: Equatable, Sendable {
  /// Images: the grid's `link` count and OLD mark; the table's Uses
  /// column, and the references its row opens to.
  case image(uses: Int, hasOldDomain: Bool, references: [UsageReferenceRow])
  /// Files: the line the image first appears on in the selected file.
  case line(Int?)
  /// The table's child row for one reference.
  case reference(UsageReferenceRow)
}

/// The Open File / Reveal rule: a reference names a file Pinax can
/// open only when its source reference starts `<label>/`, the label is one
/// of the project's configured folder sources, and the file is there. An
/// external scanner's references, and a command source's, never pass.
public enum UsageSourceFile {
  public static func url(
    project: String, path: String, sources: [String: [ProjectSource]],
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> URL? {
    guard let (source, rest) = split(project: project, path: path, sources: sources),
      source.kind == .folder
    else { return nil }
    let url = URL(fileURLWithPath: source.path, isDirectory: true).appendingPathComponent(rest)
    return fileExists(url.path) ? url : nil
  }

  /// Used In's path: the source label taken off when it is one.
  public static func displayPath(
    project: String, path: String, sources: [String: [ProjectSource]]
  ) -> String {
    split(project: project, path: path, sources: sources)?.rest ?? path
  }

  private static func split(
    project: String, path: String, sources: [String: [ProjectSource]]
  ) -> (source: ProjectSource, rest: String)? {
    guard let slash = path.firstIndex(of: "/") else { return nil }
    let label = String(path[..<slash])
    let rest = String(path[path.index(after: slash)...])
    guard !rest.isEmpty, let source = sources[project]?.first(where: { $0.label == label })
    else { return nil }
    return (source, rest)
  }
}

/// One row of the inspector's Used In group: the file, where it lives in
/// its project, and the line. The Usage page draws the file name over
/// "project › directory" with the line's capsule; the
/// other pages read `text`, their one-line form.
public struct UsedInRow: Equatable, Sendable {
  public let project: String
  /// The source label taken off, as the page shows it.
  public let path: String
  public let line: Int?

  public init(project: String, path: String, line: Int?) {
    self.project = project
    self.path = path
    self.line = line
  }

  /// The one-line form the library inspector and Externals show:
  /// "astro · posts/foo.md:12".
  public var text: String {
    "\(project) · \(path)" + (line.map { ":\($0)" } ?? "")
  }

  public var fileName: String { (path as NSString).lastPathComponent }

  /// "astro › src/content/blog"; the project alone when the file sits at a
  /// source's root.
  public var location: String {
    let directory = (path as NSString).deletingLastPathComponent
    return directory.isEmpty ? project : "\(project) › \(directory)"
  }
}

/// The inspector's Used In group, for one asset across every
/// project: "Unknown" until any project completed a scan, "Not used" when
/// none of them references it, else the first few references.
public enum UsedInState: Equatable, Sendable {
  case unknown
  case notUsed
  /// `rows` holds at most `limit` of the `total` references; `projects`
  /// are the slugs referencing it.
  case used(rows: [UsedInRow], total: Int, projects: Set<String>)

  public static let limit = 5

  public init(_ usage: LiveUsageSet) {
    guard !usage.scannedProjects.isEmpty else {
      self = .unknown
      return
    }
    let rows = usage.references.map(UsageReferenceRow.init).sorted(by: UsageReferenceRow.precedes)
    guard !rows.isEmpty else {
      self = .notUsed
      return
    }
    self = .used(
      rows: rows.prefix(Self.limit).map { row in
        let slug = row.reference.projectSlug
        return UsedInRow(
          project: slug,
          path: UsageSourceFile.displayPath(
            project: slug, path: row.file, sources: usage.projectSources),
          line: row.line)
      },
      total: rows.count, projects: Set(rows.map(\.reference.projectSlug)))
  }
}

/// What the Usage page adds to a row's context menu, read as
/// values: the tests never open a menu.
public enum UsageMenuItem: Identifiable, Equatable, Sendable {
  case openFile(URL)
  case revealInFinder(URL)
  /// The asset's URL on its backend's current prefix.
  case copyNewURL(String)
  case showInLibrary(Int64)

  public var id: String {
    switch self {
    case .openFile: return "openFile"
    case .revealInFinder: return "revealInFinder"
    case .copyNewURL: return "copyNewURL"
    case .showInLibrary: return "showInLibrary"
    }
  }
}
