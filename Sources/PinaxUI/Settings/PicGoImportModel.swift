import AppKit
import CatalogCore
import Foundation
import GRDB

public protocol PicGoGalleryImporting: Sendable {
  func run(source: URL, backendSlug: String, dryRun: Bool) async throws -> PicGoImportResult
}

public struct CatalogPicGoGalleryImporter: PicGoGalleryImporting {
  private let database: DatabasePool
  private let fetcher: any PublicObjectFetching

  public init(
    database: DatabasePool,
    fetcher: any PublicObjectFetching = URLSessionPublicObjectFetcher()
  ) {
    self.database = database
    self.fetcher = fetcher
  }

  public func run(
    source: URL, backendSlug: String, dryRun: Bool
  ) async throws -> PicGoImportResult {
    let database = database
    let (records, backend) = try await Task.detached {
      (
        try PicGoGallery.records(contentsOf: source),
        try CatalogConfiguration.backend(slug: backendSlug, in: database)
      )
    }.value
    return try await PicGoGalleryImporter.importGallery(
      records: records,
      backend: backend,
      in: database,
      fetcher: fetcher,
      dryRun: dryRun)
  }
}

public enum PicGoGalleryOpenPanel {
  public static let defaultSource = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/picgo/picgo.db")

  @MainActor
  public static func choose(currentSource: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Choose PicGo Gallery"
    panel.message = "Choose PicGo's gallery database."
    panel.prompt = "Choose"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = currentSource.deletingLastPathComponent()
    panel.nameFieldStringValue = currentSource.lastPathComponent
    return panel.runModal() == .OK ? panel.url : nil
  }
}
