import CatalogCore
import Foundation
import Testing

@Test("Keychain credentials persist while secrets stay out of SQLite")
func keychainPersistenceAndDatabaseSecrecy() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let databaseURL = directory.appendingPathComponent("catalog.sqlite")
  let database = try Database.open(at: databaseURL)
  try Database.migrate(database)

  let service = "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)"
  let reference = "backend.r2"
  let secret = "secret-\(UUID().uuidString)"
  let credentials = BackendCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: secret)
  let writer = Keychain(service: service)
  defer { try? writer.delete(for: reference) }

  try writer.store(credentials, for: reference)
  _ = try CatalogConfiguration.addBackend(
    slug: "r2",
    endpoint: "https://account.r2.cloudflarestorage.com/",
    bucket: "images",
    region: "auto",
    urlPrefix: "https://img.example.com/",
    keychainReference: reference,
    to: database,
    now: Date(timeIntervalSince1970: 0)
  )

  let readerAfterRestart = Keychain(service: service)
  #expect(try readerAfterRestart.load(for: reference) == credentials)

  try database.close()
  let secretBytes = Data(secret.utf8)
  let databaseFiles = [
    databaseURL,
    URL(fileURLWithPath: databaseURL.path + "-wal"),
    URL(fileURLWithPath: databaseURL.path + "-shm"),
  ]
  for file in databaseFiles where FileManager.default.fileExists(atPath: file.path) {
    #expect(try Data(contentsOf: file).range(of: secretBytes) == nil)
  }
}

@Test("Backend and project configuration persists normalized values")
func backendAndProjectConfiguration() throws {
  try withConfigurationDatabase { database in
    let now = Date(timeIntervalSince1970: 0)
    let backend = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://account.example.com///",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://img.example.com///",
      keychainReference: "backend.r2",
      to: database,
      now: now
    )
    #expect(backend.endpoint == "https://account.example.com")
    #expect(backend.urlPrefix == "https://img.example.com")
    #expect(try CatalogConfiguration.backend(slug: "r2", in: database).id != nil)

    let project = try CatalogConfiguration.addProject(
      slug: "blog",
      name: "Blog",
      keyPrefix: "/blog//drafts/",
      backendSlug: "r2",
      to: database,
      now: now
    )
    #expect(project.keyPrefix == "blog/drafts")
    #expect(project.backendID == backend.id)

    let updated = try CatalogConfiguration.setProject(
      slug: "blog",
      name: "Main Blog",
      keyPrefix: "published/",
      backendSlug: nil,
      in: database,
      now: Date(timeIntervalSince1970: 1)
    )
    #expect(updated.name == "Main Blog")
    #expect(updated.keyPrefix == "published")
    #expect(try CatalogConfiguration.projects(in: database).map(\.slug) == ["blog"])
  }
}

@Test("Clearing a project backend writes NULL, then setProject can set it again")
func clearingProjectBackend() throws {
  try withConfigurationDatabase { database in
    let now = Date(timeIntervalSince1970: 0)
    let backend = try CatalogConfiguration.addBackend(
      slug: "r2",
      endpoint: "https://account.example.com",
      bucket: "images",
      region: "auto",
      urlPrefix: "https://img.example.com",
      keychainReference: "backend.r2",
      to: database,
      now: now
    )
    _ = try CatalogConfiguration.addProject(
      slug: "blog", name: "Blog", keyPrefix: "blog", backendSlug: "r2",
      to: database, now: now
    )

    let cleared = try CatalogConfiguration.clearProjectBackend(
      slug: "blog", in: database, now: Date(timeIntervalSince1970: 5)
    )
    #expect(cleared.backendID == nil)
    let stored = try CatalogConfiguration.projects(in: database)[0]
    #expect(stored.backendID == nil)
    #expect(stored.updatedAt == ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 5)))

    // Clearing is idempotent and re-assigning through setProject still works.
    _ = try CatalogConfiguration.clearProjectBackend(slug: "blog", in: database)
    let reassigned = try CatalogConfiguration.setProject(
      slug: "blog", name: nil, keyPrefix: nil, backendSlug: "r2", in: database
    )
    #expect(reassigned.backendID == backend.id)

    #expect(throws: CatalogConfigurationError.projectNotFound("ghost")) {
      _ = try CatalogConfiguration.clearProjectBackend(slug: "ghost", in: database)
    }
  }
}

@Test("PicGo import normalizes R2 fields and preserves the legacy key template")
func picGoImportConfiguration() throws {
  let data = Data(
    """
    {
      "picBed": {
        "aws-s3": {
          "endpoint": "https://account.r2.cloudflarestorage.com",
          "bucketName": "images",
          "customUrl": "https://img.example.com",
          "region": "   ",
          "uploadPath": "{year}{month}/{day}-{md5}-{timestamp}.{extName}"
        }
      }
    }
    """.utf8
  )
  let config = try PicGoS3Config(data: data)
  #expect(config.region == "auto")
  #expect(config.bucket == "images")
  #expect(config.urlPrefix == "https://img.example.com")
  let meta = try #require(
    JSONSerialization.jsonObject(with: Data(config.backendMeta.utf8)) as? [String: String]
  )
  #expect(meta["picgo_upload_path"] == "{year}{month}/{day}-{md5}-{timestamp}.{extName}")
}

@Test("PicGo import names each missing required field")
func picGoImportMissingFields() {
  let cases: [(json: String, field: String)] = [
    (
      #"{"picBed":{"aws-s3":{"endpoint":"https://example.com","bucket":" ","urlPrefix":"https://img.example.com"}}}"#,
      "bucket"
    ),
    (
      #"{"picBed":{"aws-s3":{"endpoint":"https://example.com","bucket":"images","urlPrefix":""}}}"#,
      "urlPrefix"
    ),
  ]
  for testCase in cases {
    #expect(throws: PicGoS3ConfigError.missingField(testCase.field)) {
      _ = try PicGoS3Config(data: Data(testCase.json.utf8))
    }
  }
}

private func withConfigurationDatabase(
  _ body: (CatalogDatabasePool) throws -> Void
) throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  try body(database)
}
