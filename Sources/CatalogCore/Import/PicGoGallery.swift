import Foundation

/// One entry of PicGo's gallery store. Only the fields that become catalog
/// facts are modelled; `config` (which embeds live object-store
/// credentials), `type`, `shortUrl`, `id`, `updatedAt`, `imgUrl`, and
/// `extname` are deliberately never read, so they cannot leak into the
/// catalog, a log, or an error message.
public struct PicGoGalleryRecord: Sendable, Equatable {
  public let fileName: String
  public let url: String
  public let width: Int?
  public let height: Int?
  public let createdAtMilliseconds: Int64

  public init(
    fileName: String,
    url: String,
    width: Int?,
    height: Int?,
    createdAtMilliseconds: Int64
  ) {
    self.fileName = fileName
    self.url = url
    self.width = width
    self.height = height
    self.createdAtMilliseconds = createdAtMilliseconds
  }
}

public enum PicGoGalleryError: Error, Equatable, CustomStringConvertible {
  case notAnObject
  case galleryMissing
  case invalidRecord(String)
  case malformedGzip

  public var description: String {
    switch self {
    case .notAnObject:
      return "The PicGo store is not a JSON object."
    case .galleryMissing:
      return "The PicGo store has no gallery array."
    case let .invalidRecord(name):
      return "PicGo gallery record '\(name)' has no url."
    case .malformedGzip:
      return "The gzip-compressed PicGo store could not be parsed."
    }
  }
}

public enum PicGoGallery {
  public static func records(contentsOf fileURL: URL) throws -> [PicGoGalleryRecord] {
    try records(data: try Data(contentsOf: fileURL))
  }

  public static func records(data: Data) throws -> [PicGoGalleryRecord] {
    let json = try Self.decompressedIfNeeded(data)
    guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
      throw PicGoGalleryError.notAnObject
    }
    guard let gallery = root["gallery"] as? [[String: Any]] else {
      throw PicGoGalleryError.galleryMissing
    }
    return try gallery.map { entry in
      let name = (entry["fileName"] as? String) ?? "<unnamed>"
      guard let url = entry["url"] as? String, !url.isEmpty else {
        throw PicGoGalleryError.invalidRecord(name)
      }
      return PicGoGalleryRecord(
        fileName: name,
        url: url,
        width: Self.intValue(entry["width"]),
        height: Self.intValue(entry["height"]),
        createdAtMilliseconds: Int64(Self.intValue(entry["createdAt"]) ?? 0)
      )
    }
  }

  /// PicGo writes numbers as JSON numbers; some plugin versions wrote strings.
  /// Both are accepted, anything else is treated as absent.
  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = value as? String {
      return Int(string)
    }
    return nil
  }

  // MARK: - Gzip container

  /// PicGo stores its gallery as gzip-compressed JSON. The gzip magic bytes
  /// (`1f 8b`) are sniffed so callers never need to know which form a file is
  /// in. `NSData.decompressed(using: .zlib)` consumes raw deflate only, so the
  /// gzip header (including its optional fields) and the 8-byte CRC/size
  /// trailer are stripped here.
  static func decompressedIfNeeded(_ data: Data) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b else {
      return data
    }
    guard bytes[2] == 0x08 else {
      // gzip magic with a compression method other than deflate.
      throw PicGoGalleryError.malformedGzip
    }
    let flags = bytes[3]
    var offset = 10  // magic, method, flags, mtime, xfl, os
    if flags & 0x04 != 0 {  // FEXTRA: 2-byte length then that many bytes
      let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
      offset += 2 + extraLength
    }
    if flags & 0x08 != 0 {  // FNAME: zero-terminated
      while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x10 != 0 {  // FCOMMENT: zero-terminated
      while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x02 != 0 {  // FHCRC: 2-byte header checksum
      offset += 2
    }
    guard offset < bytes.count - 8 else {
      throw PicGoGalleryError.malformedGzip
    }
    let deflate = Data(bytes[offset..<(bytes.count - 8)])
    do {
      return try (deflate as NSData).decompressed(using: .zlib) as Data
    } catch {
      throw PicGoGalleryError.malformedGzip
    }
  }
}
