import AppKit
import CatalogCore
import SwiftUI
@testable import PinaxUI
import Testing

@MainActor
@Suite struct MaintenanceTests {
  @Test("Production doctor detects credentials without exposing their secret")
  func productionReaderKeepsCredentialSecretOutOfReportAndView() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reference = "backend.r2"
    let keychain = Keychain(service: "tech.gitkeniwo.pinax.tests.\(UUID())")
    let sentinel = "SENTINEL-DOCTOR-SECRET"
    try keychain.store(
      BackendCredentials(accessKeyID: "sentinel-access-key", secretAccessKey: sentinel),
      for: reference)
    defer { try? keychain.delete(for: reference) }

    let reader = CatalogMaintenanceReader(
      database: database,
      databaseURL: directory.appendingPathComponent("catalog.sqlite"),
      keychain: keychain)
    let report = try await reader.doctorReport()

    let credentialCheck = try #require(
      report.checks.first { $0.name == "backend-credentials" })
    #expect(credentialCheck.status == .pass)
    #expect(credentialCheck.detail == "All backend credentials are available.")
    for check in report.checks {
      #expect(check.name.contains(sentinel) == false)
      #expect(check.detail.contains(sentinel) == false)
    }

    let model = MaintenanceModel(reader: reader)
    await model.load()
    #expect(String(describing: model).contains(sentinel) == false)

    let host = NSHostingView(rootView: MaintenanceSettingsContent(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 470)
    host.layoutSubtreeIfNeeded()
    let text = renderedText(in: host)
    // The check in words; its id is the row's help tag.
    #expect(text.contains("Backend credentials"))
    #expect(text.contains(sentinel) == false)
  }

  @Test("Doctor renders each check and never publishes a credential value")
  func rendersChecksWithoutCredential() async throws {
    let sentinel = "SENTINEL-SECRET"
    let report = DoctorReport(checks: [
      DoctorCheck(name: "database-location", status: .pass, detail: "Location is safe"),
      DoctorCheck(name: "usage-scans", status: .warning, detail: "One project needs a scan"),
      DoctorCheck(name: "integrity-check", status: .failure, detail: "Integrity failed"),
    ])
    let reader = CredentialProbeMaintenanceReader(secret: sentinel, report: report)
    let model = MaintenanceModel(reader: reader)

    await model.load()

    #expect(reader.credentialChecks == 1)
    #expect(String(describing: model).contains(sentinel) == false)
    #expect(model.report == report)
    #expect(model.loadError == nil)

    let host = NSHostingView(rootView: MaintenanceSettingsContent(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 470)
    host.layoutSubtreeIfNeeded()
    let text = renderedText(in: host) + "\n" + accessibilityText(in: host)
    for expected in [
      "Database location", "Location is safe",
      "Usage scans", "One project needs a scan",
      "Integrity check", "Integrity failed",
    ] {
      #expect(text.contains(expected), "Missing rendered doctor text: \(expected)")
    }
    #expect(text.contains(sentinel) == false)
  }

  private func renderedText(in view: NSView) -> String {
    var values: [String] = []
    if let field = view as? NSTextField, !field.stringValue.isEmpty {
      values.append(field.stringValue)
    }
    for child in view.subviews {
      values.append(renderedText(in: child))
    }
    return values.joined(separator: "\n")
  }

  private func accessibilityText(in view: NSView) -> String {
    var values = [view.accessibilityLabel()].compactMap { $0 }
    for child in view.subviews {
      values.append(accessibilityText(in: child))
    }
    return values.joined(separator: "\n")
  }
}

private final class CredentialProbeMaintenanceReader: MaintenanceReading, @unchecked Sendable {
  let secret: String
  let report: DoctorReport
  private let lock = NSLock()
  private var checks = 0

  init(secret: String, report: DoctorReport) {
    self.secret = secret
    self.report = report
  }

  var credentialChecks: Int {
    lock.withLock { checks }
  }

  func doctorReport() async throws -> DoctorReport {
    let exists = credentialExists("backend.r2")
    #expect(exists)
    return report
  }

  private func credentialExists(_ reference: String) -> Bool {
    let loadedSecret = reference == "backend.r2" ? secret : nil
    lock.withLock { checks += 1 }
    return loadedSecret != nil
  }
}
