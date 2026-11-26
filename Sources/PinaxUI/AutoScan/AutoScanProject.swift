import CatalogCore
import Foundation
import GRDB

/// What asked for an automatic scan.
public enum UsageAutoScanReason: Equatable, Sendable {
  case watch
  case schedule
  case wake
}

/// What the watcher and the schedule need to know about one project.
struct AutoScanProject: Equatable, Sendable {
  var slug: String
  var sources: [ProjectSource]
  var autoScan: ProjectAutoScan
  /// When the project's latest completed scan started; nil before the first.
  var lastScanAt: Date?

  static func load(from database: DatabasePool) throws -> [AutoScanProject] {
    let lastScans = Dictionary(
      try CatalogConfiguration.projectSummaries(in: database).map { ($0.slug, $0.lastScanAt) },
      uniquingKeysWith: { first, _ in first })
    let formatter = ISO8601DateFormatter()
    return try CatalogConfiguration.projects(in: database).map { project in
      let settings = ProjectSettings(meta: project.meta)
      return AutoScanProject(
        slug: project.slug, sources: settings.sources, autoScan: settings.autoScan,
        lastScanAt: (lastScans[project.slug] ?? nil).flatMap(formatter.date(from:)))
    }
  }
}
