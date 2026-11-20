import AppKit
import CatalogCore
import Foundation
import GRDB

public struct ManifestExportResult: Equatable, Sendable {
  public let project: String
  public let assetCount: Int
  public let byteCount: Int
  public let destination: URL
}

public protocol ManifestExporting: Sendable {
  func export(project: String, to destination: URL) async throws -> ManifestExportResult
}

public struct CatalogManifestExporter: ManifestExporting {
  private let database: DatabasePool
  private let generatedAt: Date?

  public init(database: DatabasePool, generatedAt: Date? = nil) {
    self.database = database
    self.generatedAt = generatedAt
  }

  public func export(
    project: String, to destination: URL
  ) async throws -> ManifestExportResult {
    let database = database
    let generatedAt = generatedAt
    return try await Task.detached {
      let manifest = try CatalogManifest.export(
        project: project, from: database, generatedAt: generatedAt ?? Date())
      let data = Data((try manifest.json() + "\n").utf8)
      try data.write(to: destination, options: .atomic)
      return ManifestExportResult(
        project: project,
        assetCount: manifest.assets.count,
        byteCount: data.count,
        destination: destination)
    }.value
  }
}

@MainActor
public final class ManifestExportModel: ObservableObject {
  @Published public private(set) var isExporting = false
  @Published public private(set) var notice: String?

  private let exporter: ManifestExporting
  private let chooseDestination: @MainActor (String) -> URL?

  public init(
    exporter: ManifestExporting,
    chooseDestination: @escaping @MainActor (String) -> URL?
  ) {
    self.exporter = exporter
    self.chooseDestination = chooseDestination
  }

  public func export(project: String) async {
    guard !isExporting,
      let destination = chooseDestination("\(project)-manifest.json")
    else { return }
    isExporting = true
    defer { isExporting = false }
    do {
      let result = try await exporter.export(project: project, to: destination)
      notice = "Exported \(result.assetCount) assets (\(result.byteCount) bytes) to \(destination.lastPathComponent)."
    } catch {
      notice = UserFacingErrorMessage.resolve(error)
    }
  }

  public func dismissNotice() {
    notice = nil
  }
}

@MainActor
enum ManifestSavePanel {
  static func choose(defaultFilename: String) -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultFilename
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.message = "Export project manifest"
    return panel.runModal() == .OK ? panel.url : nil
  }
}
