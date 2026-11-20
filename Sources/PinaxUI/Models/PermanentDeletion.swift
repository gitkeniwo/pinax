import CatalogCore
import Foundation

/// Delete Permanently…'s sheet, produced from the selection's facts by
/// one pure function so every line is asserted on the real strings.
public struct DeletionConfirmation: Equatable, Sendable {
  public enum DefaultButton: Equatable, Sendable {
    /// Return cancels — no default for an act that can't be undone.
    case cancel
    /// "Remove from <project>".
    case removeFromProject
  }

  public struct Line: Equatable, Sendable {
    public let label: String
    public let value: String
  }

  /// A titled warning or note under the rows; `items` lists files.
  public struct Note: Equatable, Sendable {
    public let title: String
    public let detail: String
    public var items: [String] = []
  }

  /// Every selected image leaves the current project; the ones
  /// still used there stay (the core's guard).
  public struct ProjectRemoval: Equatable, Sendable {
    public let slug: String
    public let name: String
    /// Selected images in the project, in selection order.
    public let members: [String]
    /// Of those, the ones a live reference keeps in the project.
    public let keptByUsage: Int
    /// Selected images that belong to another project too.
    public let sharedCount: Int
    public let otherProjects: [String]
  }

  public let title: String
  public let subtitle: String
  public let lines: [Line]
  public let notes: [Note]
  public let finePrint: String
  public let deleteTitle: String
  public let removal: ProjectRemoval?
  public let defaultButton: DefaultButton

  /// This confirmation's images (at most `CatalogDeletion.limit`), by sha256.
  public let deleting: [String]
  /// Of this time's images, the ones only the row goes for.
  public let keeping: [String]
  /// The rest of the selection, still selected afterwards.
  public let leftSelected: [String]
  public let byteTotal: Int64
  /// Scanned files still referencing an image whose file goes.
  public let referencingFiles: [String]
  public let usedImageCount: Int

  public var imageCount: Int { deleting.count + keeping.count }
  public var removeTitle: String? { removal.map { "Remove from \($0.name)" } }

  public static let finePrintDeleting =
    "You can’t undo this. Public links may keep loading for a while from CDN and browser caches. "
    + "In a versioned bucket, only the current version is deleted."
  public static let finePrintKeeping =
    "You can’t undo this. The files stay in the bucket, so their links keep working."

  /// - Parameters:
  ///   - facts: the selection, in grid order.
  ///   - currentProject: the app's current project; nil = All Projects.
  ///   - projectNames: slug → display name.
  public static func make(
    facts: [DeletionFacts], currentProject: String?, projectNames: [String: String] = [:]
  ) -> DeletionConfirmation? {
    guard !facts.isEmpty else { return nil }
    let limit = CatalogDeletion.limit
    let now = Array(facts.prefix(limit))
    let later = Array(facts.dropFirst(limit))
    let remote = now.filter(\.deletesRemote)
    let kept = now.filter { !$0.deletesRemote }
    let bytes = now.reduce(0) { $0 + $1.byteSize }
    let used = remote.filter { !$0.usedInFiles.isEmpty }
    let files = Array(Set(used.flatMap(\.usedInFiles))).sorted()
    let name = { (slug: String) in projectNames[slug] ?? slug }

    var removal: ProjectRemoval?
    if let current = currentProject {
      let members = facts.filter { $0.projects.contains(current) }
      let shared = members.filter { $0.projects.count > 1 }
      if !shared.isEmpty {
        removal = ProjectRemoval(
          slug: current, name: name(current), members: members.map(\.sha256),
          keptByUsage: members.filter { ($0.liveUsageByProject[current] ?? 0) > 0 }.count,
          sharedCount: facts.filter { $0.projects.count > 1 }.count,
          otherProjects: Array(Set(shared.flatMap(\.projects)).subtracting([current]))
            .sorted().map(name))
      }
    }

    let allKept = remote.isEmpty
    let title: String
    let deleteTitle: String
    if allKept {
      title = "Remove \(images(kept.count, capital: true)) from the Library?"
      deleteTitle = "Remove from Library"
    } else if !later.isEmpty {
      title = "Delete \(now.count) of \(images(facts.count, capital: true)) Permanently?"
      deleteTitle = "Delete \(now.count) Permanently"
    } else {
      title = "Delete \(images(now.count, capital: true)) Permanently?"
      deleteTitle = "Delete Permanently"
    }

    let subtitle: String
    if !later.isEmpty {
      subtitle =
        "Pinax deletes at most \(limit) images per confirmation. "
        + "The other \(later.count) stay selected so you can continue."
    } else if let removal {
      subtitle =
        removal.sharedCount == 1 && facts.count == 1
        ? "It also belongs to other projects."
        : "\(removal.sharedCount) of them also belong to other projects."
    } else if allKept {
      subtitle = "They will be removed from the library; their files stay in the bucket."
    } else if !kept.isEmpty {
      subtitle =
        "\(remote.count) will be deleted from the bucket. "
        + "\(kept.count) can only be removed from the library."
    } else {
      subtitle = "They will be removed from the library, and their files deleted from the bucket."
    }

    var lines: [Line] = []
    if !later.isEmpty {
      lines.append(Line(label: "This time", value: countAndSize(now)))
      lines.append(Line(label: "Still selected afterwards", value: countAndSize(later)))
      if !files.isEmpty {
        lines.append(Line(label: "Still used in \(filesPhrase(files.count))", value: "\(used.count)"))
      }
    } else if !kept.isEmpty, !remote.isEmpty, removal == nil {
      lines.append(Line(label: "Delete from bucket", value: countAndSize(remote)))
      lines.append(Line(label: "Remove from library only", value: countAndSize(kept)))
      lines.append(Line(label: "Total", value: countAndSize(now)))
    } else {
      lines.append(Line(label: "Images", value: now.count.formatted()))
      lines.append(Line(label: "Total size", value: PinaxFormat.fileSize(bytes)))
      if let removal {
        lines.append(
          Line(
            label: "Also in \(removal.otherProjects.joined(separator: ", "))",
            value: "\(removal.sharedCount)"))
      } else if !allKept {
        let buckets = Array(Set(remote.map { "\($0.bucket) · \($0.backendSlug)" })).sorted()
        lines.append(
          Line(label: buckets.count == 1 ? "Bucket" : "Buckets", value: buckets.joined(separator: ", ")))
      }
    }

    var notes: [Note] = []
    if !files.isEmpty, later.isEmpty {
      let shown = Array(files.prefix(3))
      notes.append(
        Note(
          title:
            "\(images(used.count)) \(used.count == 1 ? "is" : "are") still used in \(filesPhrase(files.count))",
          detail: "These pages will show broken images once the files are gone.",
          items: shown + (files.count > 3 ? ["and \(files.count - 3) more"] : [])))
    }
    if !kept.isEmpty {
      let sources = Set(kept.map(\.importedFrom))
      let from = sources == ["picgo"] ? "imported from PicGo" : "not uploaded by Pinax"
      notes.append(
        Note(
          title: "\(kept.count) \(kept.count == 1 ? "was" : "were") \(from)",
          detail:
            "Pinax can’t confirm it uploaded \(kept.count == 1 ? "this file" : "these files"), "
            + "so it leaves \(kept.count == 1 ? "it" : "them") in the bucket. "
            + "Delete \(kept.count == 1 ? "it" : "them") in your provider’s console if you need to."))
    }
    if let removal {
      let leaving = removal.members.count - removal.keptByUsage
      var detail =
        leaving == facts.count
        ? "All \(leaving) leave \(removal.name) and stay archived; their files stay in the bucket."
        : "\(leaving) \(leaving == 1 ? "leaves" : "leave") \(removal.name) and "
          + "\(leaving == 1 ? "stays" : "stay") archived; their files stay in the bucket."
      if leaving == 1, facts.count == 1 {
        detail = "It leaves \(removal.name) and stays archived; its file stays in the bucket."
      }
      detail +=
        " The \(removal.sharedCount) shared \(removal.sharedCount == 1 ? "image remains" : "images remain")"
        + " in \(listed(removal.otherProjects))."
      if removal.keptByUsage > 0 {
        detail +=
          " \(images(removal.keptByUsage)) \(removal.keptByUsage == 1 ? "is" : "are") still used in "
          + "\(removal.name) and \(removal.keptByUsage == 1 ? "stays" : "stay") there."
      }
      notes.append(Note(title: "Remove from \(removal.name) deletes nothing", detail: detail))
    }

    return DeletionConfirmation(
      title: title, subtitle: subtitle, lines: lines, notes: notes,
      finePrint: allKept ? finePrintKeeping : finePrintDeleting, deleteTitle: deleteTitle,
      removal: removal, defaultButton: removal == nil ? .cancel : .removeFromProject,
      deleting: remote.map(\.sha256), keeping: kept.map(\.sha256),
      leftSelected: later.map(\.sha256), byteTotal: bytes, referencingFiles: files,
      usedImageCount: used.count)
  }

  static func images(_ count: Int, capital: Bool = false) -> String {
    let noun = capital ? (count == 1 ? "Image" : "Images") : (count == 1 ? "image" : "images")
    return "\(count.formatted()) \(noun)"
  }

  static func filesPhrase(_ count: Int) -> String {
    "\(count.formatted()) \(count == 1 ? "file" : "files")"
  }

  static func countAndSize(_ facts: [DeletionFacts]) -> String {
    "\(facts.count.formatted()) · \(PinaxFormat.fileSize(facts.reduce(0) { $0 + $1.byteSize }))"
  }

  /// "blog", "blog and notes", "a, b and c".
  static func listed(_ names: [String]) -> String {
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
  }
}

/// The Archived banner for deletions that did not finish: what it says, from the tombstones alone.
public struct DeletionBanner: Equatable, Sendable {
  public let title: String
  public let detail: String

  public static func make(_ unfinished: [UnfinishedDeletion], checking: Bool) -> DeletionBanner? {
    guard !unfinished.isEmpty else { return nil }
    let buckets = Array(Set(unfinished.map(\.bucket))).sorted().joined(separator: ", ")
    let count = unfinished.count
    if checking {
      return DeletionBanner(
        title: "Checking \(buckets)…",
        detail:
          "Making sure the \(count == 1 ? "file is" : "\(count) files are") still there "
          + "before the \(count == 1 ? "image comes" : "images come") back to Archived.")
    }
    var reasons: [String] = []
    for item in unfinished {
      let reason = Self.reason(for: item)
      if !reasons.contains(reason) { reasons.append(reason) }
    }
    let tail =
      unfinished.contains(where: Self.mayBeGone)
      ? "The images are already out of the library; some files may already be gone from the bucket."
      : "The images are already out of the library; their files are still in the bucket."
    return DeletionBanner(
      title: "\(count.formatted()) \(count == 1 ? "deletion" : "deletions") didn’t finish",
      detail: (reasons + [tail]).joined(separator: " "))
  }

  /// The DELETE went out and nothing says it failed: the file may be gone.
  /// AccessDenied, or the file still there afterwards, means it is not.
  static func mayBeGone(_ item: UnfinishedDeletion) -> Bool {
    guard item.phase == .deleteSent else { return false }
    guard let error = item.lastError else { return true }
    return !error.contains("has no permission to delete")
      && !error.contains("still there after the delete")
  }

  /// `last_error` in plain words.
  public static func reason(for item: UnfinishedDeletion) -> String {
    let bucket = item.bucket
    guard let error = item.lastError else {
      return "Pinax stopped before the \(item.phase == .deleteSent ? "delete was confirmed" : "files were deleted")."
    }
    if error.contains("has no permission to delete") {
      return "The access key for \(bucket) isn’t allowed to delete files (AccessDenied)."
    }
    if error.contains("has no permission for") {
      return "The access key for \(bucket) isn’t allowed to read files (AccessDenied)."
    }
    if error.contains("x-amz-meta-sha256") {
      return "The file at this key changed since upload, so Pinax left it alone."
    }
    if error.contains("NSURLErrorDomain") {
      return "Couldn’t reach \(bucket)."
    }
    if error.contains("No credentials for backend") {
      return "Pinax has no credentials for \(bucket)."
    }
    if error.contains("still there after the delete") {
      return "The file was still in \(bucket) after the delete."
    }
    if let range = error.range(of: #"HTTP \d{3}"#, options: .regularExpression),
      error.hasPrefix("S3 returned")
    {
      return "\(bucket) answered \(error[range])."
    }
    // Anything else may carry a URL or request detail; it never reaches the UI.
    return "Deleting from \(bucket) failed."
  }
}
