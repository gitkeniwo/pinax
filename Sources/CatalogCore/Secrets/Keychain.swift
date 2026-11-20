import Foundation
import Security

public struct BackendCredentials: Codable, Equatable, Sendable {
  public let accessKeyID: String
  public let secretAccessKey: String

  public init(accessKeyID: String, secretAccessKey: String) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
  }
}

public enum KeychainError: Error, Equatable, CustomStringConvertible {
  case invalidCredentialData
  case unexpectedStatus(OSStatus)

  public var description: String {
    switch self {
    case .invalidCredentialData:
      return "The Keychain item does not contain valid Pinax credentials."
    case let .unexpectedStatus(status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
      return "Keychain operation failed: \(message)"
    }
  }
}

public struct Keychain: Sendable {
  public static let defaultService = "tech.gitkeniwo.pinax"

  private let service: String

  public init(service: String = Keychain.defaultService) {
    self.service = service
  }

  public func store(_ credentials: BackendCredentials, for reference: String) throws {
    let data = try JSONEncoder().encode(credentials)
    let query = baseQuery(for: reference)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(updateStatus)
    }

    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.unexpectedStatus(addStatus)
    }
  }

  public func load(for reference: String) throws -> BackendCredentials? {
    var query = baseQuery(for: reference)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainError.unexpectedStatus(status)
    }
    guard let data = result as? Data,
      let credentials = try? JSONDecoder().decode(BackendCredentials.self, from: data)
    else {
      throw KeychainError.invalidCredentialData
    }
    return credentials
  }

  public func delete(for reference: String) throws {
    let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }

  private func baseQuery(for reference: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference,
    ]
  }
}
