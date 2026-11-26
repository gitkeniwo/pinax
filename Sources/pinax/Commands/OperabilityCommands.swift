import ArgumentParser
import CatalogCore
import Foundation

struct DoctorCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Check catalog integrity and operational safety."
  )

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    let databaseURL = DBLocation.locate()
    if let problem = DatabasePathSafety.problem(at: databaseURL) {
      throw CLIError.refused("FATAL: \(problem). Pinax refuses to open this database.")
    }
    let database = try Database.open(at: databaseURL)
    try Database.migrate(database)
    let keychain = Keychain()
    let report = try CatalogDoctor.run(
      database: database,
      databaseURL: databaseURL,
      credentialExists: { try keychain.load(for: $0) != nil }
    )
    // The JSON document carries the warnings itself.
    if format == .json { print(try encodedJSON(report)) }
    for check in report.checks where format == .table {
      let line = "\(check.status.rawValue.uppercased())\t\(check.name)\t\(check.detail)\n"
      let handle = check.status == .warning ? FileHandle.standardError : FileHandle.standardOutput
      handle.write(Data(line.utf8))
    }
    if report.hasFailures {
      throw ExitCode.failure
    }
  }
}

struct BackupCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "backup",
    abstract: "Export the complete catalog database as versioned JSON."
  )

  @Option(name: [.short, .long]) var output: String?

  mutating func run() throws {
    let backup = try CatalogBackups.create(from: openCatalogDatabase())
    let data = Data((try encodedJSON(backup) + "\n").utf8)
    if let output {
      try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    } else {
      FileHandle.standardOutput.write(data)
    }
  }
}

struct RestoreCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "restore",
    abstract: "Restore a catalog backup into an empty catalog (for moving to another Mac)."
  )

  @Argument var file: String

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    let keychain = Keychain()
    let output = try RestoreCommandOperations.restore(
      file: URL(fileURLWithPath: file),
      into: openCatalogDatabase(),
      format: format,
      credentialExists: { try keychain.load(for: $0) != nil })
    print(output, terminator: "")
  }
}

/// `pinax restore` without the process: the same `CatalogBackups.restore`
/// the app calls, then the two follow-ups.
enum RestoreCommandOperations {
  static func restore(
    file: URL,
    into database: CatalogDatabasePool,
    format: OutputFormat = .table,
    credentialExists: (String) throws -> Bool,
    folderExists: (String) -> Bool = CatalogBackups.directoryExists
  ) throws -> String {
    let backup = try CatalogBackups.decode(try Data(contentsOf: file))
    let counts = try CatalogBackups.restore(backup, into: database)
    let followUps = try CatalogBackups.followUps(
      in: database, credentialExists: credentialExists, folderExists: folderExists)
    if format == .json {
      return try encodedJSON(RestoreDocument(counts: counts, followUps: followUps)) + "\n"
    }
    var lines = counts.tables.map { "\($0.name)\t\($0.count)" }
    lines.append("favorite\t\(counts.favorites)")
    let backends = followUps.backendsWithoutCredentials
    lines.append(
      "Backends without credentials on this Mac: \(backends.count)"
        + (backends.isEmpty ? "" : " (\(backends.joined(separator: ", "))); "
          + "add them in Settings ▸ Backends"))
    let projects = followUps.projectsWithMissingSources
    lines.append(
      "Projects whose source folders are not on this Mac: \(projects.count)"
        + (projects.isEmpty ? "" : " (\(projects.map(\.projectSlug).joined(separator: ", "))); "
          + "use Locate… in Settings ▸ Projects or `pinax project source set`"))
    return lines.joined(separator: "\n") + "\n"
  }
}

struct ReindexCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "reindex",
    abstract: "Rebuild asset rows from S3 object metadata."
  )

  @Option var backend: String
  @Flag var dryRun = false

  mutating func run() async throws {
    let database = try openCatalogDatabase()
    let selectedBackend = try resolveReindexBackend(
      slug: backend,
      persistIfMissing: !dryRun,
      in: database
    )
    let credentials = try reindexCredentials(for: selectedBackend)
    let inventory = S3ObjectInventory(backend: selectedBackend, credentials: credentials)
    let result = try await CatalogReindex.run(
      backend: selectedBackend,
      inventory: inventory,
      database: database,
      dryRun: dryRun
    )
    print(try encodedJSON(result))
    for item in result.missingMetadata {
      let fields = item.missing.joined(separator: ", ")
      FileHandle.standardError.write(
        Data("WARNING: \(item.key) is missing metadata: \(fields)\n".utf8)
      )
    }
  }
}

private func resolveReindexBackend(
  slug: String,
  persistIfMissing: Bool,
  in database: CatalogDatabasePool
) throws -> Backend {
  if let backend = try CatalogConfiguration.backends(in: database).first(where: { $0.slug == slug })
  {
    return backend
  }
  let environment = ProcessInfo.processInfo.environment
  guard let endpoint = environment["PINAX_S3_ENDPOINT"],
    let bucket = environment["PINAX_S3_BUCKET"],
    let urlPrefix = environment["PINAX_S3_URL_PREFIX"]
  else {
    throw CLIError.notFound(
      "Backend '\(slug)' does not exist. Disaster recovery requires PINAX_S3_ENDPOINT, "
        + "PINAX_S3_BUCKET, and PINAX_S3_URL_PREFIX."
    )
  }
  let region = environment["PINAX_S3_REGION"] ?? "auto"
  let keychainReference = "backend.\(slug)"
  guard persistIfMissing else {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    return Backend(
      slug: slug,
      kind: "s3",
      endpoint: endpoint,
      bucket: bucket,
      region: region,
      urlPrefix: urlPrefix,
      keychainRef: keychainReference,
      createdAt: timestamp,
      updatedAt: timestamp
    )
  }
  return try CatalogConfiguration.addBackend(
    slug: slug,
    endpoint: endpoint,
    bucket: bucket,
    region: region,
    urlPrefix: urlPrefix,
    keychainReference: keychainReference,
    to: database
  )
}

func reindexCredentials(for backend: Backend) throws -> BackendCredentials {
  if !backend.keychainRef.isEmpty,
    let credentials = try Keychain().load(for: backend.keychainRef)
  {
    return credentials
  }
  let environment = ProcessInfo.processInfo.environment
  if let accessKeyID = environment["PINAX_ACCESS_KEY_ID"],
    let secretAccessKey = environment["PINAX_SECRET_ACCESS_KEY"],
    !accessKeyID.isEmpty,
    !secretAccessKey.isEmpty
  {
    return BackendCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
  }
  throw CLIError.credentials(credentialMissingMessage(for: backend))
}
