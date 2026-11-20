import AppKit
import CatalogCore
import Foundation

/// The settings preview's service: it lists the projects it was given and
/// does nothing else. Nothing it is asked to do reaches a backend or the
/// catalog.
struct PreviewDropZoneService: DropZoneService {
  struct Inert: Error {}

  let projectList: [Project]

  func projects() throws -> [Project] { projectList }

  func upload(_ fileURL: URL, projectSlug: String?) async throws -> UploadOutcome {
    throw Inert()
  }

  func moveAsset(
    sha256: String, fromProject: String?, toProject: String?, confirmed: Bool
  ) async throws {}
}

extension DropZoneModel {
  /// A model for Settings ▸ Drop Zone's preview, never the app's: its own
  /// service, thumbnail cache and Quick Look under `directory`, a copier
  /// that drops what it is given, and no callbacks into the app. `service`
  /// and `urlCopier` are seams for a test's spies.
  static func preview(
    projects: [Project] = [],
    directory: URL,
    service: (any DropZoneService)? = nil,
    urlCopier: ((String) -> Void)? = nil
  ) -> DropZoneModel {
    let thumbnails = ThumbnailCache(
      cacheDirectory: directory.appendingPathComponent("thumbs", isDirectory: true),
      fetcher: { _ in throw PreviewDropZoneService.Inert() })
    let quickLook = QuickLookController(
      thumbnails: thumbnails,
      originals: OriginalImageCache(
        cacheDirectory: directory.appendingPathComponent("originals", isDirectory: true),
        fetcher: { _ in throw PreviewDropZoneService.Inert() }),
      placeholderDirectory: directory.appendingPathComponent("placeholders", isDirectory: true),
      panel: { nil })
    let model = DropZoneModel(
      service: service ?? PreviewDropZoneService(projectList: projects),
      thumbnails: thumbnails, quickLook: quickLook, isPreview: true)
    model.urlCopier = urlCopier ?? { _ in }
    model.copiesURLsAutomatically = false
    model.seedPreview(cards: [], draggedFileURLs: [], projects: projects, selectedProjectSlug: nil)
    return model
  }
}
