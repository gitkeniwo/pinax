import ArgumentParser
import CatalogCore
import Foundation

#if canImport(AppKit)
  import AppKit
#endif

enum CLIUploadFormat: String, ExpressibleByArgument {
  case url
  case markdown
  case html
  case json

  var coreFormat: UploadOutputFormat {
    UploadOutputFormat(rawValue: rawValue)!
  }
}

struct UploadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upload",
    abstract: "Upload images and record them in the catalog."
  )

  @Argument(help: "Image files to upload.")
  var paths: [String] = []

  @Option(name: .long, help: "Associate uploads with this project.")
  var project: String?

  @Option(name: .long, help: "Use this backend instead of the project backend.")
  var backend: String?

  @Option(name: .long, help: "Output format.")
  var format: CLIUploadFormat?

  @Flag(name: .long, help: "Copy the formatted output to the pasteboard.")
  var copy = false

  @Flag(name: .long, help: "Read image data or file URLs from the pasteboard.")
  var clipboard = false

  @Flag(name: .long, help: "Print the planned key and dedupe status without writing.")
  var dryRun = false

  @Flag(name: .long, help: "Upload even when the catalog already contains the content.")
  var force = false

  @Flag(
    inversion: .prefixedNo,
    help: """
      Compress the uploaded copy, or upload the original. Default: as the project says; \
      without a project, the original. The files on disk are never changed.
      """)
  var compress: Bool?

  @OptionGroup var template: CopyTemplateOption

  func validate() throws {
    try template.validate(hasFormat: format != nil)
  }

  mutating func run() async throws {
    guard clipboard || !paths.isEmpty else {
      throw ValidationError("Provide at least one path or use --clipboard.")
    }
    guard !clipboard || paths.isEmpty else {
      throw ValidationError("Paths and --clipboard cannot be used together.")
    }

    let inputs = try uploadInputs()
    defer {
      for url in inputs.temporaryFiles {
        try? FileManager.default.removeItem(at: url)
      }
    }
    try validateFiles(inputs.urls)
    let database = try openCatalogDatabase()
    let projects = try CatalogConfiguration.projects(in: database)
    let selectedProject: Project?
    if let project {
      guard let match = projects.first(where: { $0.slug == project }) else {
        throw CatalogConfigurationError.projectNotFound(project)
      }
      selectedProject = match
    } else {
      selectedProject = nil
    }

    let backends = try CatalogConfiguration.backends(in: database)
    let selectedBackend: Backend
    if let backend {
      guard let match = backends.first(where: { $0.slug == backend }) else {
        throw CatalogConfigurationError.backendNotFound(backend)
      }
      selectedBackend = match
    } else if let backendID = selectedProject?.backendID,
      let match = backends.first(where: { $0.id == backendID })
    {
      selectedBackend = match
    } else if backends.count == 1, let match = backends.first {
      selectedBackend = match
    } else if backends.isEmpty {
      throw CLIError.notFound("No backends are configured.")
    } else {
      let available = backends.map(\.slug).joined(separator: ", ")
      throw ValidationError("Specify --backend. Available backends: \(available).")
    }

    let uploader: (any Uploader)?
    if dryRun {
      uploader = nil
    } else {
      guard let credentials = try Keychain().load(for: selectedBackend.keychainRef) else {
        throw CLIError.credentials(credentialMissingMessage(for: selectedBackend))
      }
      uploader = S3Uploader(backend: selectedBackend, credentials: credentials)
    }
    let pipeline = UploadPipeline(
      database: database,
      uploader: uploader,
      backend: selectedBackend,
      project: selectedProject
    )
    let attempts = await uploadAll(
      inputs.urls, with: pipeline, compression: compressionOptions(for: selectedProject))
    let outcomes = attempts.compactMap { attempt -> UploadOutcome? in
      guard case let .success(outcome) = attempt.result else { return nil }
      return outcome
    }
    if !outcomes.isEmpty {
      let output: String
      if let template = template.template {
        output = try templateLines(
          template, for: outcomes, backend: selectedBackend,
          plannedProject: dryRun ? selectedProject : nil, in: database
        ).joined(separator: "\n")
      } else if dryRun, format == nil {
        output = outcomes.map { outcome in
          "\(outcome.deduplicated ? "dedupe" : "upload")\t\(outcome.key)"
        }.joined(separator: "\n")
      } else {
        output = try UploadOutput.format(outcomes, as: (format ?? .url).coreFormat)
      }
      print(output)
      if copy {
        try copyToPasteboard(output)
      }
    }
    var failures: [Error] = []
    for attempt in attempts {
      guard case let .failure(error) = attempt.result else { continue }
      failures.append(error)
      writeError("\(attempt.url.path): \(error)")
    }
    if !failures.isEmpty {
      throw ExitCode(CLIExit.code(forAll: failures))
    }
  }

  /// `template` filled in for each upload. A project's asset carries the
  /// catalog's memberships; `plannedProject` is the one a dry run would add,
  /// since it writes none.
  func templateLines(
    _ template: String, for outcomes: [UploadOutcome], backend: Backend,
    plannedProject: Project?, in database: CatalogDatabasePool
  ) throws -> [String] {
    try outcomes.map { outcome in
      var projects = try CatalogAssets.projectSlugs(
        sha256: outcome.sha256, backendID: backend.id, in: database)
      if let plannedProject {
        projects.insert(plannedProject.slug)
      }
      // An asset with no original filename is reported under its key.
      let filename =
        outcome.originalFilename == outcome.key
        ? (outcome.key as NSString).lastPathComponent : outcome.originalFilename
      return CopyTemplate.render(
        template,
        fields: CopyFields(
          url: outcome.url, filename: filename, width: outcome.width, height: outcome.height,
          key: outcome.key, projects: projects.sorted()))
    }
  }

  /// The options each upload is compressed with, or nil for originals.
  func compressionOptions(for project: Project?) -> CompressionOptions? {
    CompressionChoice(flag: compress).options(for: project)
  }

  private func uploadAll(
    _ urls: [URL], with pipeline: UploadPipeline, compression: CompressionOptions?
  ) async -> [UploadAttempt] {
    var results = [UploadAttempt?](repeating: nil, count: urls.count)
    return await withTaskGroup(of: UploadAttempt.self) { group in
      var nextIndex = 0
      func submit(_ index: Int) {
        group.addTask {
          do {
            let outcome = try await pipeline.upload(
              fileURL: urls[index],
              force: force,
              dryRun: dryRun,
              compression: compression
            )
            return UploadAttempt(index: index, url: urls[index], result: .success(outcome))
          } catch {
            return UploadAttempt(index: index, url: urls[index], result: .failure(error))
          }
        }
      }
      while nextIndex < min(4, urls.count) {
        submit(nextIndex)
        nextIndex += 1
      }
      while let attempt = await group.next() {
        results[attempt.index] = attempt
        if nextIndex < urls.count {
          submit(nextIndex)
          nextIndex += 1
        }
      }
      return results.compactMap { $0 }
    }
  }

  private func validateFiles(_ urls: [URL]) throws {
    for url in urls {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw CLIError.notFound("File does not exist: \(url.path)")
      }
    }
  }

  private func uploadInputs() throws -> UploadInputs {
    if clipboard {
      return try clipboardInputs()
    }
    return UploadInputs(
      urls: paths.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
      },
      temporaryFiles: []
    )
  }

  private func clipboardInputs() throws -> UploadInputs {
    #if canImport(AppKit)
      let pasteboard = NSPasteboard.general
      if let objects = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL], !objects.isEmpty {
        return UploadInputs(urls: objects, temporaryFiles: [])
      }
      let candidates: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.tiff, "tiff")]
      for (type, fileExtension) in candidates {
        guard let data = pasteboard.data(forType: type) else { continue }
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("pinax-clipboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        let filename = "\(pastedFilename()).\(fileExtension)"
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return UploadInputs(urls: [fileURL], temporaryFiles: [directory])
      }
      throw CLIError.notFound("The pasteboard does not contain PNG, TIFF, or image file URLs.")
    #else
      throw CLIError.failure("Clipboard upload requires AppKit.")
    #endif
  }

  private func pastedFilename(at date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "'pasted-'yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }

  private func writeError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
  }

  private func copyToPasteboard(_ value: String) throws {
    #if canImport(AppKit)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(value, forType: .string) else {
        throw CLIError.failure("Could not write the upload output to the pasteboard.")
      }
    #else
      throw CLIError.failure("Copying output requires AppKit.")
    #endif
  }
}

extension CompressionChoice {
  /// `--compress` / `--no-compress`, or neither.
  init(flag: Bool?) {
    switch flag {
    case true?: self = .on
    case false?: self = .off
    case nil: self = .project
    }
  }
}

private struct UploadInputs {
  let urls: [URL]
  let temporaryFiles: [URL]
}

private struct UploadAttempt {
  let index: Int
  let url: URL
  let result: Result<UploadOutcome, Error>
}
