import CatalogCore
import Foundation
import GRDB

public protocol MaintenanceReading: Sendable {
  func doctorReport() async throws -> DoctorReport
}

public struct CatalogMaintenanceReader: MaintenanceReading {
  private let database: DatabasePool
  private let databaseURL: URL
  private let keychain: Keychain

  public init(database: DatabasePool, databaseURL: URL, keychain: Keychain = Keychain()) {
    self.database = database
    self.databaseURL = databaseURL
    self.keychain = keychain
  }

  public func doctorReport() async throws -> DoctorReport {
    let database = database
    let databaseURL = databaseURL
    let keychain = keychain
    return try await Task.detached {
      try CatalogDoctor.run(
        database: database,
        databaseURL: databaseURL,
        credentialExists: { (try? keychain.load(for: $0)) != nil }
      )
    }.value
  }
}

@MainActor
public final class MaintenanceModel: ObservableObject {
  @Published public private(set) var report: DoctorReport?
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: String?

  private let reader: MaintenanceReading

  public init(reader: MaintenanceReading) {
    self.reader = reader
  }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      report = try await reader.doctorReport()
      loadError = nil
    } catch {
      report = nil
      loadError = UserFacingErrorMessage.resolve(error)
    }
  }
}
