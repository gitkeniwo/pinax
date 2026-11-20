import Foundation

public enum DatabaseLocationError: Error, Equatable, LocalizedError {
  case unsafePath(String)

  public var errorDescription: String? {
    switch self {
    case .unsafePath(let problem):
      return "FATAL: \(problem). Pinax refuses to open this database."
    }
  }
}

public enum DBLocation {
  public static func locate(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let configuredPath = environment["PINAX_DB"], !configuredPath.isEmpty {
      let expandedPath = (configuredPath as NSString).expandingTildeInPath
      return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }
    return
      homeDirectory
      .appendingPathComponent(
        "Library/Application Support/tech.gitkeniwo.pinax", isDirectory: true
      )
      .appendingPathComponent("catalog.sqlite", isDirectory: false)
  }

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) throws -> URL {
    let databaseURL = locate(environment: environment, homeDirectory: homeDirectory)
    try DatabasePathSafety.refuseNewDatabase(
      at: databaseURL,
      homeDirectory: homeDirectory,
      fileManager: fileManager
    )
    try fileManager.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    return databaseURL
  }
}
