import AppKit
import Foundation

/// Pasteboard surfaces for the menu bar and menu commands. Reads run off the
/// main thread: pasteboard access round-trips to the pasteboard server, and
/// the same reasoning that keeps drag-pasteboard reads off the main thread
/// applies to every read.
enum PasteboardUploads {
  /// Collects image files for "Upload from Clipboard", with the CLI's exact
  /// semantics: file URLs win; otherwise PNG then TIFF image data is written
  /// to a unique temporary file named `pasted-<timestamp>`. The temporary
  /// files intentionally outlive the call — the drop zone may retry the
  /// upload later, so cleanup here would break retry.
  static func collectImageFiles(now: Date = Date()) async -> [URL] {
    await Task.detached(priority: .userInitiated) {
      let pasteboard = NSPasteboard.general
      if let urls = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL], !urls.isEmpty {
        return urls
      }
      let candidates: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.tiff, "tiff")]
      for (type, fileExtension) in candidates {
        guard let data = pasteboard.data(forType: type) else { continue }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "'pasted-'yyyyMMdd-HHmmss"
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("pinax-clipboard-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent(
          "\(formatter.string(from: now)).\(fileExtension)")
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try data.write(to: fileURL, options: .atomic)
          return [fileURL]
        } catch {
          continue
        }
      }
      return []
    }.value
  }
}

/// Small write helper shared by the inspector, the menu commands, and the
/// menu bar's recent-upload rows.
@MainActor
enum Clipboard {
  /// Fires after every write: the menu bar icon's ✓.
  static var onCopy: (@MainActor () -> Void)?

  static func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    onCopy?()
  }
}
