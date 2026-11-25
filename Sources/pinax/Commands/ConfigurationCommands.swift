import ArgumentParser
import CatalogCore
import Darwin
import Foundation

struct BackendCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "backend",
    abstract: "Manage object-store backends.",
    subcommands: [
      BackendAdd.self,
      BackendList.self,
      BackendShow.self,
      BackendSetPrefix.self,
      BackendSetCredentials.self,
      BackendImportPicGo.self,
      BackendOldDomainCommand.self,
      BackendMigrateDomain.self,
    ]
  )
}

struct BackendAdd: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add")

  @Option var slug: String
  @Option var endpoint: String
  @Option var bucket: String
  @Option var urlPrefix: String
  @Option var region = "auto"
  @Flag(name: .long, help: "Register without credentials (read-only); add them later with set-credentials.")
  var noCredentials = false

  mutating func run() throws {
    try addBackend(
      slug: slug,
      endpoint: endpoint,
      bucket: bucket,
      urlPrefix: urlPrefix,
      region: region,
      noCredentials: noCredentials
    )
  }
}

struct BackendList: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ls")

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    let database = try openCatalogDatabase()
    let backends = try CatalogConfiguration.backends(in: database)
    if format == .json {
      print(try encodedJSON(BackendListDocument(backends: backends.map(BackendJSON.init))))
      return
    }
    for backend in backends {
      print("\(backend.slug)\t\(backend.kind)\t\(backend.bucket)\t\(backend.urlPrefix)")
    }
  }
}

struct BackendShow: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "show")

  @Argument var slug: String

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    let database = try openCatalogDatabase()
    let backend = try CatalogConfiguration.backend(slug: slug, in: database)
    if format == .json {
      let links = try CatalogConfiguration.domainLinkCounts(backendSlug: slug, in: database)
        .current.links
      print(try encodedJSON(BackendDocument(backend: BackendJSON(backend), urlPrefixLinks: links)))
      return
    }
    print("slug: \(backend.slug)")
    print("kind: \(backend.kind)")
    print("endpoint: \(backend.endpoint)")
    print("bucket: \(backend.bucket)")
    print("region: \(backend.region)")
    print("url-prefix: \(backend.urlPrefix)")
    print("url-prefix-links: \(try CatalogConfiguration.domainLinkCounts(backendSlug: slug, in: database).current.links)")
    print("credentials: ********")
  }
}
struct BackendSetPrefix: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "set-prefix")

  @Argument var slug: String
  @Argument var newURLPrefix: String

  mutating func run() throws {
    try validateHTTPURL(newURLPrefix, name: "URL prefix")
    let backend = try CatalogConfiguration.setBackendURLPrefix(
      slug: slug,
      urlPrefix: newURLPrefix,
      in: openCatalogDatabase()
    )
    print(backend.urlPrefix)
  }
}

struct BackendSetCredentials: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set-credentials",
    abstract: "Store credentials for a backend, including one registered with --no-credentials."
  )

  @Option var slug: String

  mutating func run() throws {
    let database = try openCatalogDatabase()
    guard let backend = try CatalogConfiguration.backends(in: database).first(where: {
      $0.slug == slug
    }) else {
      throw CLIError.notFound("Backend '\(slug)' does not exist.")
    }
    let credentials = try readCredentials()
    let reference = backend.keychainRef.isEmpty ? "backend.\(slug)" : backend.keychainRef
    try Keychain().store(credentials, for: reference)
    if backend.keychainRef.isEmpty {
      _ = try CatalogConfiguration.attachKeychainReference(
        slug: slug, reference: reference, in: database)
    }
    print(slug)
  }
}

struct RewriteMapCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rewrite-map",
    abstract: "Export current and retired URL prefixes for a backend."
  )

  @Option var backend: String

  mutating func run() throws {
    let map = try CatalogConfiguration.rewriteMap(
      backendSlug: backend,
      in: openCatalogDatabase()
    )
    print(try encodedJSON(map))
  }
}

struct BackendImportPicGo: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "import-picgo")

  @Option var path = "~/.picgo/config.json"
  @Flag(name: .long, help: "Register without credentials (read-only); add them later with set-credentials.")
  var noCredentials = false

  mutating func run() throws {
    let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let config = try PicGoS3Config(contentsOf: fileURL)
    try addBackend(
      slug: config.slug,
      endpoint: config.endpoint,
      bucket: config.bucket,
      urlPrefix: config.urlPrefix,
      region: config.region,
      meta: config.backendMeta,
      noCredentials: noCredentials
    )
  }
}

struct ProjectCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "project",
    abstract: "Manage upload projects.",
    subcommands: [ProjectAdd.self, ProjectList.self, ProjectSet.self, ProjectSourceCommand.self]
  )
}

struct ProjectAdd: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add")

  @Option var slug: String
  @Option var name: String
  @Option var keyPrefix: String
  @Option(help: "Object key template; the default is \(KeyTemplate.defaultTemplate).")
  var keyTemplate: String?
  @Option var backend: String

  func validate() throws {
    try validateSlug(slug)
    guard !name.isEmpty else { throw ValidationError("Project name must not be empty.") }
  }

  mutating func run() throws {
    let result = try perform(in: openCatalogDatabase())
    writeWarnings(result.warnings)
    print(result.output)
  }

  /// What `run` prints: the slug on stdout, key template warnings for stderr.
  func perform(in database: CatalogDatabasePool) throws -> (output: String, warnings: [String]) {
    let project = try CatalogConfiguration.addProject(
      slug: slug,
      name: name,
      keyPrefix: keyPrefix,
      keyTemplate: keyTemplate,
      backendSlug: backend,
      to: database
    )
    return (project.slug, keyTemplateWarnings(for: project))
  }
}

struct ProjectList: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ls")

  @Option(name: .long)
  var format: OutputFormat = .table

  mutating func run() throws {
    print(try output(in: openCatalogDatabase()), terminator: "")
  }

  /// One tab-separated line per project; the key template is the last
  /// column, `default` when the project has none.
  func output(in database: CatalogDatabasePool) throws -> String {
    let backendSlugs = Dictionary(
      uniqueKeysWithValues: try CatalogConfiguration.backends(in: database).compactMap { backend in
        backend.id.map { ($0, backend.slug) }
      }
    )
    let projects = try CatalogConfiguration.projects(in: database)
    if format == .json {
      let records = projects.map { project in
        ProjectJSON(
          slug: project.slug, name: project.name, keyPrefix: project.keyPrefix,
          keyTemplate: project.keyTemplate,
          backend: project.backendID.flatMap { backendSlugs[$0] })
      }
      return try encodedJSON(ProjectListDocument(projects: records)) + "\n"
    }
    return projects.map { project in
      let backend = project.backendID.flatMap { backendSlugs[$0] } ?? "-"
      let template = project.keyTemplate ?? "default"
      return "\(project.slug)\t\(project.name)\t\(project.keyPrefix)\t\(backend)\t\(template)\n"
    }.joined()
  }
}

struct ProjectSet: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "set")

  @Option var slug: String
  @Option var name: String?
  @Option var keyPrefix: String?
  @Option var backend: String?
  @Option(help: "Object key template; the default is \(KeyTemplate.defaultTemplate).")
  var keyTemplate: String?
  @Flag(help: "Go back to the default key template.")
  var resetKeyTemplate = false
  @Flag(
    inversion: .prefixedNo,
    help: "Compress the uploaded copy of this project's images. The files on disk are never changed.")
  var compress: Bool?
  @Option(help: "Longest edge of a compressed copy in pixels, or none to keep the size.")
  var longestEdge: LongestEdgeArgument?
  @Option(help: "Quality of a compressed copy: high, medium or small.")
  var quality: QualityArgument?
  @Flag(help: "Whether a compressed copy drops the original's metadata, location included.")
  var metadata: MetadataArgument?
  @Option(help: "Rescan when the project's source folders change: on or off.")
  var watch: WatchArgument?
  @Option(help: "Rescan on a schedule while the app is open: off, hourly or daily.")
  var schedule: ScheduleArgument?

  func validate() throws {
    if keyTemplate != nil, resetKeyTemplate {
      throw ValidationError("Give --key-template or --reset-key-template, not both.")
    }
  }

  private var changesCompression: Bool {
    compress != nil || longestEdge != nil || quality != nil || metadata != nil
  }

  private var changesAutoScan: Bool {
    watch != nil || schedule != nil
  }

  private var changesProject: Bool {
    name != nil || keyPrefix != nil || backend != nil || keyTemplate != nil || resetKeyTemplate
  }

  mutating func run() throws {
    let result = try perform(in: openCatalogDatabase())
    writeWarnings(result.warnings)
    print(result.output)
  }

  func perform(in database: CatalogDatabasePool) throws -> (output: String, warnings: [String]) {
    // Compression or automatic scanning alone is a change too; with nothing
    // at all given, setProject reports that nothing changed. The project's
    // own fields go first, so a refused change leaves the others as they were.
    var warnings: [String] = []
    if changesProject || !(changesCompression || changesAutoScan) {
      let change: KeyTemplateChange =
        resetKeyTemplate ? .reset : keyTemplate.map { .set($0) } ?? .unchanged
      let project = try CatalogConfiguration.setProject(
        slug: slug,
        name: name,
        keyPrefix: keyPrefix,
        backendSlug: backend,
        keyTemplate: change,
        in: database
      )
      warnings = keyTemplateWarnings(for: project)
    }
    if changesCompression {
      try CatalogConfiguration.setCompression(slug: slug, in: database) { compression in
        if let compress { compression.isEnabled = compress }
        if let longestEdge { compression.options.longestEdge = longestEdge.pixels }
        if let quality { compression.options.quality = quality.value }
        if let metadata { compression.options.removesMetadata = metadata == .removeMetadata }
      }
    }
    if changesAutoScan {
      var autoScan = try CatalogConfiguration.projectSettings(slug: slug, in: database).autoScan
      if let watch { autoScan.watch = watch == .on }
      if let schedule { autoScan.schedule = schedule.value }
      try CatalogConfiguration.setAutoScan(slug: slug, autoScan, in: database)
    }
    return (slug, warnings)
  }
}

/// `--longest-edge`: a positive number of pixels, or `none`.
struct LongestEdgeArgument: ExpressibleByArgument, Equatable {
  let pixels: Int?

  init?(argument: String) {
    if argument == "none" {
      pixels = nil
    } else if let value = Int(argument), value > 0 {
      pixels = value
    } else {
      return nil
    }
  }
}

/// `--quality high|medium|small`.
enum QualityArgument: String, ExpressibleByArgument, CaseIterable {
  case high, medium, small

  var value: CompressionQuality { CompressionQuality(rawValue: rawValue)! }
}

/// `--remove-metadata` / `--keep-metadata`.
enum MetadataArgument: String, EnumerableFlag {
  case removeMetadata
  case keepMetadata
}

/// `--watch on|off`.
enum WatchArgument: String, ExpressibleByArgument, CaseIterable {
  case on, off
}

/// `--schedule off|hourly|daily`.
enum ScheduleArgument: String, ExpressibleByArgument, CaseIterable {
  case off, hourly, daily

  var value: ProjectAutoScan.Schedule { ProjectAutoScan.Schedule(rawValue: rawValue)! }
}

/// The key template warnings for the project's template and key prefix as saved.
private func keyTemplateWarnings(for project: Project) -> [String] {
  KeyTemplate.evaluate(
    project.keyTemplate ?? KeyTemplate.defaultTemplate, keyPrefix: project.keyPrefix
  ).warnings.map(\.message)
}

private func writeWarnings(_ warnings: [String]) {
  for warning in warnings {
    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
  }
}

func openCatalogDatabase() throws -> CatalogDatabasePool {
  let database = try Database.open(
    at: DBLocation.resolve(),
    onLocationWarning: writeDatabaseLocationWarning
  )
  try Database.migrate(database)
  return database
}

func writeDatabaseLocationWarning(_ warning: DatabaseLocationWarning) {
  let problem: String
  switch warning {
  case .unsafeExistingDatabase(let value):
    problem = value
  }
  let message =
    "WARNING: \(problem). Pinax is opening this existing database. "
    + "Move it to local storage to prevent corruption.\n"
  FileHandle.standardError.write(Data(message.utf8))
}

/// Every code path that needs to sign a request reports the same two cases:
/// a backend deliberately registered without credentials (with the exact
/// remedy), versus credentials that were stored and have gone missing.
func credentialMissingMessage(for backend: Backend) -> String {
  if backend.keychainRef.isEmpty {
    return
      "Backend '\(backend.slug)' was registered without credentials. "
      + "Run: pinax backend set-credentials --slug \(backend.slug)"
  }
  return
    "Credentials for backend '\(backend.slug)' are missing. "
    + "Re-store them with: pinax backend set-credentials --slug \(backend.slug)"
}

private func addBackend(
  slug: String,
  endpoint: String,
  bucket: String,
  urlPrefix: String,
  region: String,
  meta: String = "{}",
  noCredentials: Bool = false
) throws {
  try validateSlug(slug)
  try validateHTTPURL(endpoint, name: "Endpoint")
  try validateHTTPURL(urlPrefix, name: "URL prefix")
  guard !bucket.isEmpty else { throw ValidationError("Bucket must not be empty.") }
  guard !region.isEmpty else { throw ValidationError("Region must not be empty.") }

  let database = try openCatalogDatabase()
  if try CatalogConfiguration.backends(in: database).contains(where: { $0.slug == slug }) {
    throw CLIError.failure("Backend '\(slug)' already exists.")
  }

  if noCredentials {
    // Read-only registration: an empty keychain_ref, nothing stored, nothing
    // prompted for. The importer and the gallery need no credentials at all.
    let backend = try CatalogConfiguration.addBackend(
      slug: slug,
      endpoint: endpoint,
      bucket: bucket,
      region: region,
      urlPrefix: urlPrefix,
      keychainReference: "",
      meta: meta,
      to: database
    )
    print(backend.slug)
    return
  }

  let credentials = try readCredentials()
  let reference = "backend.\(slug)"
  let keychain = Keychain()
  try keychain.store(credentials, for: reference)
  do {
    let backend = try CatalogConfiguration.addBackend(
      slug: slug,
      endpoint: endpoint,
      bucket: bucket,
      region: region,
      urlPrefix: urlPrefix,
      keychainReference: reference,
      meta: meta,
      to: database
    )
    print(backend.slug)
  } catch {
    try? keychain.delete(for: reference)
    throw error
  }
}

private func readCredentials() throws -> BackendCredentials {
  let environment = ProcessInfo.processInfo.environment
  let accessKeyID = environment["PINAX_ACCESS_KEY_ID"]
  let secretAccessKey = environment["PINAX_SECRET_ACCESS_KEY"]
  if let accessKeyID, let secretAccessKey {
    guard !accessKeyID.isEmpty, !secretAccessKey.isEmpty else {
      throw CLIError.credentials("Credential environment variables must not be empty.")
    }
    return BackendCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
  }
  if accessKeyID != nil || secretAccessKey != nil {
    throw CLIError.credentials("Set both PINAX_ACCESS_KEY_ID and PINAX_SECRET_ACCESS_KEY.")
  }
  guard isatty(STDIN_FILENO) == 1 else {
    throw CLIError.credentials(
      "Credentials require a TTY or PINAX_ACCESS_KEY_ID and PINAX_SECRET_ACCESS_KEY."
    )
  }
  let promptedAccessKeyID = try readSecret(prompt: "Access key ID: ")
  let promptedSecretAccessKey = try readSecret(prompt: "Secret access key: ")
  guard !promptedAccessKeyID.isEmpty, !promptedSecretAccessKey.isEmpty else {
    throw CLIError.credentials("Credentials must not be empty.")
  }
  return BackendCredentials(
    accessKeyID: promptedAccessKeyID,
    secretAccessKey: promptedSecretAccessKey
  )
}

private func readSecret(prompt: String) throws -> String {
  FileHandle.standardError.write(Data(prompt.utf8))
  var settings = termios()
  guard tcgetattr(STDIN_FILENO, &settings) == 0 else {
    throw CLIError.failure("Could not read terminal settings.")
  }
  let original = settings
  settings.c_lflag &= ~tcflag_t(ECHO)
  guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings) == 0 else {
    throw CLIError.failure("Could not disable terminal echo.")
  }
  defer {
    var restored = original
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &restored)
    FileHandle.standardError.write(Data("\n".utf8))
  }
  guard let value = readLine() else {
    throw CLIError.credentials("Credential input ended unexpectedly.")
  }
  return value
}

private func validateSlug(_ slug: String) throws {
  let scalars = slug.unicodeScalars
  guard !scalars.isEmpty,
    scalars.allSatisfy({
      (97...122).contains($0.value)
        || (48...57).contains($0.value)
        || $0 == "-"
    }),
    scalars.first != "-",
    scalars.last != "-"
  else {
    throw ValidationError("Slugs may contain lowercase ASCII letters, digits, and inner hyphens.")
  }
}

private func validateHTTPURL(_ value: String, name: String) throws {
  guard let components = URLComponents(string: value),
    components.scheme == "https" || components.scheme == "http",
    components.host != nil
  else {
    throw ValidationError("\(name) must be an absolute HTTP or HTTPS URL.")
  }
}
