import Foundation

public enum MetadataValueCodecError: Error, Equatable {
  case invalidEncodedWord
}

public enum MetadataValueCodec {
  private static let prefix = "=?UTF-8?B?"
  private static let suffix = "?="

  public static func encode(_ value: String) -> String {
    guard value.unicodeScalars.contains(where: { $0.value > 127 }) else {
      return value
    }
    return prefix + Data(value.utf8).base64EncodedString() + suffix
  }

  public static func decode(_ value: String) throws -> String {
    guard value.hasPrefix(prefix), value.hasSuffix(suffix) else {
      return value
    }
    let encoded = value.dropFirst(prefix.count).dropLast(suffix.count)
    guard let data = Data(base64Encoded: String(encoded)),
      let decoded = String(data: data, encoding: .utf8)
    else {
      throw MetadataValueCodecError.invalidEncodedWord
    }
    return decoded
  }
}
