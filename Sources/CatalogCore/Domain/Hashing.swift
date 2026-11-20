import CryptoKit
import Foundation

public enum Hashing {
  private static let readSize = 1024 * 1024
  private static let hexadecimal = Array("0123456789abcdef".utf8)

  public static func sha256(ofFileAt fileURL: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: fileURL)
    defer { try? file.close() }

    var hasher = SHA256()
    while let chunk = try file.read(upToCount: readSize), !chunk.isEmpty {
      hasher.update(data: chunk)
    }

    return hexadecimalString(hasher.finalize())
  }

  public static func sha256(of data: Data) -> String {
    hexadecimalString(SHA256.hash(data: data))
  }

  private static func hexadecimalString<D: Sequence>(_ digest: D) -> String
  where D.Element == UInt8 {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(64)
    for byte in digest {
      bytes.append(hexadecimal[Int(byte >> 4)])
      bytes.append(hexadecimal[Int(byte & 0x0f)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
