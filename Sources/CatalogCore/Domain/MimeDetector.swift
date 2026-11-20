import Foundation

public enum MimeDetector {
  public static func mimeType(ofFileAt fileURL: URL) throws -> String? {
    let file = try FileHandle(forReadingFrom: fileURL)
    defer { try? file.close() }
    let header = try file.read(upToCount: 512) ?? Data()

    return mimeType(fromMagicBytes: header)
      ?? mimeType(forExtension: fileURL.pathExtension)
  }

  public static func mimeType(of data: Data, fileExtension: String) -> String? {
    mimeType(fromMagicBytes: data.prefix(512))
      ?? mimeType(forExtension: fileExtension)
  }

  public static func mimeType(forExtension fileExtension: String) -> String? {
    switch fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic", "heif": return "image/heic"
    case "tif", "tiff": return "image/tiff"
    case "svg": return "image/svg+xml"
    case "pdf": return "application/pdf"
    default: return nil
    }
  }

  private static func mimeType(fromMagicBytes bytes: Data) -> String? {
    if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
      return "image/png"
    }
    if bytes.starts(with: [0xff, 0xd8, 0xff]) {
      return "image/jpeg"
    }
    if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
      return "image/gif"
    }
    if bytes.starts(with: [0x49, 0x49, 0x2a, 0x00])
      || bytes.starts(with: [0x4d, 0x4d, 0x00, 0x2a])
    {
      return "image/tiff"
    }
    if bytes.count >= 12,
      bytes[0..<4].elementsEqual("RIFF".utf8),
      bytes[8..<12].elementsEqual("WEBP".utf8)
    {
      return "image/webp"
    }
    if isHEIC(bytes) {
      return "image/heic"
    }
    if bytes.starts(with: Array("%PDF-".utf8)) {
      return "application/pdf"
    }
    if isSVG(bytes) {
      return "image/svg+xml"
    }
    return nil
  }

  private static func isHEIC(_ bytes: Data) -> Bool {
    guard bytes.count >= 12, bytes[4..<8].elementsEqual("ftyp".utf8) else {
      return false
    }
    let brands: Set<[UInt8]> = [
      Array("heic".utf8), Array("heix".utf8),
      Array("hevc".utf8), Array("hevx".utf8),
    ]
    var offset = 8
    while offset + 4 <= bytes.count {
      if brands.contains(Array(bytes[offset..<(offset + 4)])) {
        return true
      }
      offset += 4
    }
    return false
  }

  private static func isSVG(_ bytes: Data) -> Bool {
    guard let text = String(data: bytes, encoding: .utf8) else { return false }
    let normalized =
      text
      .trimmingCharacters(
        in: CharacterSet.whitespacesAndNewlines.union(
          CharacterSet(charactersIn: "\u{feff}")
        )
      )
      .lowercased()
    return normalized.hasPrefix("<svg")
      || (normalized.hasPrefix("<?xml") && normalized.contains("<svg"))
  }
}
