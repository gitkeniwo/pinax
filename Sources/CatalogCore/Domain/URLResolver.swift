import Foundation

public enum URLResolver {
  // Asset keys stay decoded in the catalog. Encoding happens only at the URL boundary.
  public static func url(for asset: Asset, backend: Backend) -> String {
    url(forKey: asset.key, backend: backend)
  }

  /// A key's URL under the backend's current prefix.
  public static func url(forKey key: String, backend: Backend) -> String {
    let prefix = backend.urlPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return "\(prefix)/\(percentEncodedPath(key[...]))"
  }

  public static func key(
    from rawURL: String,
    backend: Backend,
    retiredPrefixes: [String] = []
  ) -> String? {
    guard let raw = URLComponents(string: rawURL),
      raw.scheme != nil,
      raw.host != nil
    else {
      return nil
    }

    for candidate in [backend.urlPrefix] + retiredPrefixes {
      guard let prefix = URLComponents(string: candidate), sameOrigin(raw, prefix) else {
        continue
      }

      let prefixPath = prefix.path.trimmingTrailingSlashes()
      let boundary = prefixPath.isEmpty ? "/" : prefixPath + "/"
      guard raw.path.hasPrefix(boundary) else { continue }

      let key = raw.path.dropFirst(boundary.count)
      if !key.isEmpty {
        return String(key)
      }
    }
    return nil
  }

  private static func percentEncodedPath(_ path: Substring) -> String {
    let hexadecimal = Array("0123456789ABCDEF".utf8)
    var encoded: [UInt8] = []
    encoded.reserveCapacity(path.utf8.count)
    for byte in path.utf8 {
      let isUppercaseLetter = byte >= 65 && byte <= 90
      let isLowercaseLetter = byte >= 97 && byte <= 122
      let isDigit = byte >= 48 && byte <= 57
      if isUppercaseLetter || isLowercaseLetter || isDigit
        || byte == 45 || byte == 46 || byte == 95 || byte == 126 || byte == 47
      {
        encoded.append(byte)
      } else {
        encoded.append(37)
        encoded.append(hexadecimal[Int(byte >> 4)])
        encoded.append(hexadecimal[Int(byte & 0x0f)])
      }
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  private static func sameOrigin(_ lhs: URLComponents, _ rhs: URLComponents) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && effectivePort(lhs) == effectivePort(rhs)
  }

  private static func effectivePort(_ components: URLComponents) -> Int? {
    if let port = components.port { return port }
    switch components.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }
}

extension String {
  fileprivate func trimmingTrailingSlashes() -> String {
    var value = self
    while value.last == "/" {
      value.removeLast()
    }
    return value
  }
}
