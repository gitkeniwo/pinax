import Foundation
import GRDB

public typealias CatalogDatabasePool = DatabasePool

public enum Database {
  public static func open(
    at databaseURL: URL? = nil,
    onLocationWarning: (DatabaseLocationWarning) -> Void = { _ in }
  ) throws -> DatabasePool {
    let url = (databaseURL ?? DBLocation.locate()).standardizedFileURL
    if let warning = try DatabasePathSafety.prepareToOpen(at: url) {
      onLocationWarning(warning)
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.foreignKeysEnabled = true
    configuration.journalMode = .wal
    configuration.prepareDatabase { db in
      db.add(function: AssetSource.sqlFunction)
    }
    return try DatabasePool(path: url.path, configuration: configuration)
  }

  public static func migrate(_ database: DatabasePool) throws {
    try migrator.migrate(database)
  }
}
