import SwiftUI

/// Root view for the gallery window: shows opening progress or the open
/// failure, and otherwise the gallery, driven by the shared app model so the
/// drop zone uploads land in the same catalog and cache.
public struct GalleryRootView: View {
  @ObservedObject public var app: PinaxAppModel

  public init(app: PinaxAppModel) {
    self.app = app
  }

  public var body: some View {
    Group {
      if let gallery = app.gallery {
        GalleryView(model: gallery)
          .usageEmptyScanConfirmation(app.usageSync, presenter: .gallery)
          .catalogRestoreSheets(app, presenter: .gallery)
      } else if let openError = app.openError {
        ContentUnavailableView(.couldNotOpenCatalog(error: openError)) {
          Button("Reveal in Finder") { app.revealCatalogInFinder() }
        }
      } else {
        ProgressView("Opening catalog…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // No minimum width here: SwiftUI's minimum follows the visible columns
    // and the window's floor is an AppKit constraint, both set by
    // GalleryView (GalleryWidthBudget explains why a fixed one jumps).
    .frame(minHeight: 560)
    .task {
      await app.start()
    }
  }
}
