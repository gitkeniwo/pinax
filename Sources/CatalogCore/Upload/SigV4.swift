import CryptoKit
import Foundation

public enum SigV4Error: Error, Equatable, CustomStringConvertible {
  case invalidPayloadHash
  case invalidRequest
  case invalidPercentEncoding

  public var description: String {
    switch self {
    case .invalidPayloadHash:
      return "The SigV4 payload hash must be 64 lowercase hexadecimal characters."
    case .invalidRequest:
      return "The request needs an HTTP method and an absolute URL."
    case .invalidPercentEncoding:
      return "The request URL contains invalid percent encoding."
    }
  }
}

public struct SigV4Signer: Sendable {
  public let credentials: BackendCredentials
  public let region: String
  public let service: String

  public init(
    credentials: BackendCredentials,
    region: String,
    service: String = "s3"
  ) {
    self.credentials = credentials
    self.region = region
    self.service = service
  }

  public func sign(
    _ request: URLRequest,
    payloadHash: String,
    date: Date = Date()
  ) throws -> URLRequest {
    guard payloadHash.count == 64,
      payloadHash.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (97...102).contains($0.value)
      })
    else {
      throw SigV4Error.invalidPayloadHash
    }
    guard request.httpMethod != nil, request.url?.host != nil else {
      throw SigV4Error.invalidRequest
    }

    var signedRequest = request
    let amzDate = Self.amzDateFormatter.string(from: date)
    signedRequest.setValue(amzDate, forHTTPHeaderField: "x-amz-date")

    let canonical = try canonicalRequest(for: signedRequest, payloadHash: payloadHash)
    let dateStamp = Self.dateStampFormatter.string(from: date)
    let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      amzDate,
      scope,
      Self.sha256Hex(Data(canonical.request.utf8)),
    ].joined(separator: "\n")
    let signingKey = Self.hmac(
      key: Self.hmac(
        key: Self.hmac(
          key: Self.hmac(
            key: Data("AWS4\(credentials.secretAccessKey)".utf8),
            message: dateStamp
          ),
          message: region
        ),
        message: service
      ),
      message: "aws4_request"
    )
    let signature = Self.hex(Self.hmac(key: signingKey, message: stringToSign))
    let authorization =
      "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
      + "SignedHeaders=\(canonical.signedHeaders), Signature=\(signature)"
    signedRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
    return signedRequest
  }

  private func canonicalRequest(
    for request: URLRequest,
    payloadHash: String
  ) throws -> (request: String, signedHeaders: String) {
    guard let method = request.httpMethod,
      let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = components.host
    else {
      throw SigV4Error.invalidRequest
    }

    var headers: [String: String] = [:]
    for (name, value) in request.allHTTPHeaderFields ?? [:]
    where name.caseInsensitiveCompare("authorization") != .orderedSame {
      headers[name.lowercased()] = Self.normalizeHeaderValue(value)
    }
    let defaultPort =
      (components.scheme == "https" ? 443 : (components.scheme == "http" ? 80 : nil))
    headers["host"] =
      components.port == nil || components.port == defaultPort
      ? host
      : "\(host):\(components.port!)"

    let names = headers.keys.sorted()
    let canonicalHeaders = names.map { "\($0):\(headers[$0]!)" }.joined(separator: "\n")
    let signedHeaders = names.joined(separator: ";")

    let encodedPath = components.percentEncodedPath
    guard let decodedPath = encodedPath.removingPercentEncoding else {
      throw SigV4Error.invalidPercentEncoding
    }
    let canonicalPath = decodedPath.isEmpty ? "/" : Self.awsEncode(decodedPath, preserveSlash: true)
    let canonicalQuery = try Self.canonicalQuery(components.percentEncodedQuery)

    let canonicalRequest = [
      method,
      canonicalPath,
      canonicalQuery,
      canonicalHeaders,
      "",
      signedHeaders,
      payloadHash,
    ].joined(separator: "\n")
    return (canonicalRequest, signedHeaders)
  }

  private static func canonicalQuery(_ encodedQuery: String?) throws -> String {
    guard let encodedQuery, !encodedQuery.isEmpty else { return "" }
    let pairs = try encodedQuery.split(separator: "&", omittingEmptySubsequences: false).map {
      item in
      let pieces = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let name = String(pieces[0]).removingPercentEncoding,
        let value = String(pieces.count == 2 ? pieces[1] : "").removingPercentEncoding
      else {
        throw SigV4Error.invalidPercentEncoding
      }
      return (awsEncode(name), awsEncode(value))
    }
    return pairs.sorted {
      $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
    }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
  }

  private static func normalizeHeaderValue(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  static func awsEncode(_ value: String, preserveSlash: Bool = false) -> String {
    let hexadecimal = Array("0123456789ABCDEF".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
      let unreserved =
        (65...90).contains(byte)
        || (97...122).contains(byte)
        || (48...57).contains(byte)
        || byte == 45 || byte == 46 || byte == 95 || byte == 126
      if unreserved || (preserveSlash && byte == 47) {
        output.append(byte)
      } else {
        output.append(37)
        output.append(hexadecimal[Int(byte >> 4)])
        output.append(hexadecimal[Int(byte & 0x0f)])
      }
    }
    return String(decoding: output, as: UTF8.self)
  }

  private static func hmac(key: Data, message: String) -> Data {
    Data(
      HMAC<SHA256>.authenticationCode(
        for: Data(message.utf8),
        using: SymmetricKey(data: key)
      ))
  }

  private static func sha256Hex(_ data: Data) -> String {
    hex(Data(SHA256.hash(data: data)))
  }

  private static func hex(_ data: Data) -> String {
    let hexadecimal = Array("0123456789abcdef".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(data.count * 2)
    for byte in data {
      output.append(hexadecimal[Int(byte >> 4)])
      output.append(hexadecimal[Int(byte & 0x0f)])
    }
    return String(decoding: output, as: UTF8.self)
  }

  private static let amzDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()

  private static let dateStampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    return formatter
  }()
}
