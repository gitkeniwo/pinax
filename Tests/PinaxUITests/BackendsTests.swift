import AppKit
import CatalogCore
import GRDB
import SwiftUI
@testable import PinaxUI
import Testing

@MainActor
@Suite struct BackendsTests {
  @Test("Backend details show the Keychain reference and configured state, never the secret")
  func referenceWithoutSecret() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)"
    let keychain = Keychain(service: service)
    let sentinel = "SENTINEL-BACKEND-SECRET"
    try keychain.store(
      BackendCredentials(accessKeyID: "sentinel-access-key", secretAccessKey: sentinel),
      for: "backend.r2")
    defer { try? keychain.delete(for: "backend.r2") }

    let model = BackendsModel(
      reader: CatalogBackendsReader(database: database, keychain: keychain))
    await model.load()

    let details = try #require(model.details)
    #expect(details.keychainReference == "backend.r2")
    #expect(details.credentialsConfigured)
    #expect(String(describing: details).contains(sentinel) == false)
    #expect(String(describing: model).contains(sentinel) == false)

    let host = NSHostingView(
      rootView: BackendsSettingsContent(model: model).environment(\.settingsDefaults, islandTestDefaults()))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 470)
    host.layoutSubtreeIfNeeded()
    let text = renderedText(in: host)
    #expect(text.contains("Keychain: backend.r2"))
    #expect(BackendsSettingsContent.credentialsStatus(details) == ("Credentials OK", .pass))
    let chips = collectViews(BackendsSettingsContent(model: model).body, as: SettingsCodeChip.self)
    #expect(Set(chips.map(\.code)) == ["pinax backend set-credentials --slug r2"])
    #expect(text.contains(sentinel) == false)
  }

  @Test("Entering credentials does not write before explicit submission")
  func credentialsDoNotWriteBeforeSubmission() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = Keychain(service: "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)")
    defer { try? keychain.delete(for: "backend.r2") }
    let store = CatalogBackendsReader(database: database, keychain: keychain)
    let model = BackendsModel(reader: store)
    await model.load()

    model.beginCredentialsEntry()
    model.updateCredentialAccessKeyID("pending-access-key")
    model.updateCredentialSecretAccessKey("SENTINEL-PENDING-SECRET")

    #expect(try keychain.load(for: "backend.r2") == nil)
    #expect(model.details?.credentialsConfigured == false)
    #expect(model.isCredentialsFormPresented)
  }

  @Test("Credential submission stores in Keychain, clears fields, re-reads details, and never publishes the secret")
  func credentialsCommitClearsAndDoesNotLeak() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = Keychain(service: "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)")
    defer { try? keychain.delete(for: "backend.r2") }
    let store = CatalogBackendsReader(database: database, keychain: keychain)
    let model = BackendsModel(reader: store)
    let sentinel = "SENTINEL-SUBMITTED-BACKEND-SECRET"
    await model.load()

    model.beginCredentialsEntry()
    model.updateCredentialAccessKeyID("submitted-access-key")
    model.updateCredentialSecretAccessKey(sentinel)
    await model.submitCredentials()

    let loadedCredentials = try keychain.load(for: "backend.r2")
    let stored = try #require(loadedCredentials)
    #expect(stored.accessKeyID == "submitted-access-key")
    #expect(stored.secretAccessKey == sentinel)
    #expect(model.credentialAccessKeyID.isEmpty)
    #expect(model.credentialSecretAccessKey.isEmpty)
    #expect(!model.isCredentialsFormPresented)
    #expect(model.details?.credentialsConfigured == true)
    #expect(model.credentialsSaveError == nil)
    let publishedText = [
      model.loadError, model.operationMessage, model.reindexError,
      model.picGoImportError, model.credentialsSaveError,
    ].compactMap { $0 }.joined(separator: "\n")
    #expect(publishedText.contains(sentinel) == false)
    #expect(String(describing: model.details).contains(sentinel) == false)
    #expect(String(describing: model).contains(sentinel) == false)

    let host = NSHostingView(
      rootView: BackendsSettingsContent(model: model).environment(\.settingsDefaults, islandTestDefaults()))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 470)
    host.layoutSubtreeIfNeeded()
    let text = renderedText(in: host)
    #expect(BackendsSettingsContent.credentialsStatus(try #require(model.details)) == ("Credentials OK", .pass))
    #expect(text.contains(sentinel) == false)

    let leakProbe = BackendsModel(
      reader: store,
      credentialsWriter: AlwaysFailingCredentialsWriter(secret: sentinel))
    await leakProbe.load()
    leakProbe.beginCredentialsEntry()
    leakProbe.updateCredentialAccessKeyID("replacement-access-key")
    leakProbe.updateCredentialSecretAccessKey(sentinel)
    await leakProbe.submitCredentials()
    #expect(leakProbe.credentialsSaveError?.contains(sentinel) == false)
  }

  @Test("Credential-store failures never expose submitted secrets")
  func credentialFailureDoesNotLeak() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = Keychain(service: "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)")
    defer { try? keychain.delete(for: "backend.r2") }
    let sentinel = "SENTINEL-FAILING-BACKEND-SECRET"
    let reader = CatalogBackendsReader(database: database, keychain: keychain)
    let model = BackendsModel(
      reader: reader,
      credentialsWriter: AlwaysFailingCredentialsWriter(secret: sentinel))
    await model.load()

    model.beginCredentialsEntry()
    model.updateCredentialAccessKeyID("failing-access-key")
    model.updateCredentialSecretAccessKey(sentinel)
    await model.submitCredentials()

    let error = try #require(model.credentialsSaveError)
    #expect(error.contains(sentinel) == false)
    #expect(try keychain.load(for: "backend.r2") == nil)
    #expect(model.credentialAccessKeyID.isEmpty)
    #expect(model.credentialSecretAccessKey.isEmpty)
    #expect(String(describing: model).contains(sentinel) == false)

    let host = NSHostingView(
      rootView: BackendsSettingsContent(model: model).environment(\.settingsDefaults, islandTestDefaults()))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 470)
    host.layoutSubtreeIfNeeded()
    #expect(renderedText(in: host).contains(sentinel) == false)
  }

  @Test("The credential form uses SecureField and has no TextField or reveal control")
  func credentialFormUsesSecureFieldsOnly() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repository.appendingPathComponent(
        "Sources/PinaxUI/Settings/BackendsSettingsPane.swift"),
      encoding: .utf8)
    let start = try #require(source.range(of: "private struct BackendCredentialsControls"))
    let end = try #require(
      source.range(
        of: "struct BackendPicGoImportControls",
        range: start.upperBound..<source.endIndex))
    let formSource = source[start.lowerBound..<end.lowerBound]

    #expect(formSource.components(separatedBy: "SecureField(").count - 1 == 2)
    #expect(formSource.contains("TextField(") == false)
    #expect(formSource.contains("Toggle(") == false)
    #expect(formSource.contains("\"Replace…\""))
    #expect(formSource.contains("\"Set…\""))
  }

  @Test("Backend add cancels without writes, then re-reads normalized values without credentials")
  func addCancelAndNormalizedCommit() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)"
    let keychain = Keychain(service: service)
    defer { try? keychain.delete(for: "backend.archive") }
    let store = CatalogBackendsReader(database: database, keychain: keychain)
    let model = BackendsModel(reader: store)
    await model.load()
    let before = try tableDump(database)

    model.beginAddition()
    model.updateAdditionDraft {
      $0.slug = "archive"
      $0.endpoint = "https://s3.example.com///"
      $0.bucket = "archive-bucket"
      $0.region = "eu-west-1"
      $0.urlPrefix = "https://cdn.example.com/archive///"
    }
    #expect(model.additionDraft?.keychainReference == "backend.archive")
    model.cancelAddition()
    #expect(try tableDump(database) == before)

    model.beginAddition()
    model.updateAdditionDraft {
      $0.slug = "archive"
      $0.endpoint = "https://s3.example.com///"
      $0.bucket = "archive-bucket"
      $0.region = "eu-west-1"
      $0.urlPrefix = "https://cdn.example.com/archive///"
    }
    await model.submitAddition()

    let stored = try CatalogConfiguration.backend(slug: "archive", in: database)
    #expect(stored.endpoint == "https://s3.example.com")
    #expect(stored.urlPrefix == "https://cdn.example.com/archive")
    #expect(stored.keychainRef == "backend.archive")
    let displayed = try #require(model.details)
    #expect(displayed.slug == "archive")
    #expect(displayed.endpoint == stored.endpoint)
    #expect(displayed.urlPrefix == stored.urlPrefix)
    #expect(!displayed.credentialsConfigured)
    #expect(model.operationMessage?.contains("not configured") == true)
  }

  @Test("URL-prefix cancellation writes nothing, changes retire once, and no-op changes retire nothing")
  func prefixHistorySemantics() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = "tech.gitkeniwo.pinax.tests.\(UUID().uuidString)"
    let store = CatalogBackendsReader(
      database: database, keychain: Keychain(service: service))
    let model = BackendsModel(reader: store)
    await model.load()
    let before = try tableDump(database)

    model.requestURLPrefixChange("https://new.example.com/images/")
    model.cancelURLPrefixChange()
    #expect(try tableDump(database) == before)
    #expect(try prefixHistoryCount(database) == 0)

    model.requestURLPrefixChange("https://new.example.com/images/")
    await model.confirmURLPrefixChange()
    #expect(model.details?.urlPrefix == "https://new.example.com/images")
    #expect(try prefixHistoryCount(database) == 1)
    #expect(model.operationMessage?.contains("old prefix was retired") == true)

    model.requestURLPrefixChange("https://new.example.com/images///")
    await model.confirmURLPrefixChange()
    #expect(try prefixHistoryCount(database) == 1)
    #expect(model.operationMessage?.contains("unchanged") == true)
    #expect(model.operationMessage?.contains("no prefix was retired") == true)
  }

  private func renderedText(in view: NSView) -> String {
    var values: [String] = []
    if let field = view as? NSTextField, !field.stringValue.isEmpty {
      values.append(field.stringValue)
    }
    if let button = view as? NSButton, !button.title.isEmpty {
      values.append(button.title)
    }
    for child in view.subviews {
      values.append(renderedText(in: child))
    }
    return values.joined(separator: "\n")
  }

  private func tableDump(_ database: DatabasePool) throws -> String {
    try database.read { db in
      let projects = try Row.fetchAll(db, sql: "SELECT * FROM project ORDER BY id")
        .map(\.description)
      let backends = try Row.fetchAll(db, sql: "SELECT * FROM backend ORDER BY id")
        .map(\.description)
      let history = try Row.fetchAll(
        db, sql: "SELECT * FROM backend_prefix_history ORDER BY id"
      ).map(\.description)
      let projectDump = "projects:\n" + projects.joined(separator: "\n")
      let backendDump = "backends:\n" + backends.joined(separator: "\n")
      let historyDump = "history:\n" + history.joined(separator: "\n")
      return [projectDump, backendDump, historyDump].joined(separator: "\n")
    }
  }

  private func prefixHistoryCount(_ database: DatabasePool) throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backend_prefix_history") ?? 0
    }
  }
}

private struct AlwaysFailingCredentialsWriter: BackendCredentialsWriting {
  let secret: String

  func storeCredentials(
    _ credentials: BackendCredentials, for reference: String
  ) throws {
    throw CredentialStoreFailure(secret: secret)
  }
}

private struct CredentialStoreFailure: LocalizedError, CustomStringConvertible {
  let secret: String

  var errorDescription: String? { "Store failed for \(secret)" }
  var description: String { "CredentialStoreFailure(secret: \(secret))" }
}
