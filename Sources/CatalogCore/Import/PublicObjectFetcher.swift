import Foundation

/// Fetches bytes from a public object URL. The PicGo import needs no
/// credentials and no signing: the objects are public, and
/// sha256 is computed locally from the fetched bytes.
public protocol PublicObjectFetching: Sendable {
  /// - Parameters:
  ///   - contentLength: the response's `Content-Length` when present, used to
  ///     cross-check that the received bytes are complete.
  func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?)

  /// `fetch` plus the response's `Last-Modified`. The
  /// default forwards to `fetch` and reports no date.
  func fetchObject(_ url: URL) async throws -> PublicObject
}

/// One public GET's result, with the headers the claim needs.
public struct PublicObject: Sendable {
  public let data: Data
  public let mime: String?
  public let contentLength: Int64?
  public let lastModified: Date?

  public init(data: Data, mime: String?, contentLength: Int64?, lastModified: Date? = nil) {
    self.data = data
    self.mime = mime
    self.contentLength = contentLength
    self.lastModified = lastModified
  }
}

extension PublicObjectFetching {
  public func fetchObject(_ url: URL) async throws -> PublicObject {
    let fetched = try await fetch(url)
    return PublicObject(
      data: fetched.data, mime: fetched.mime, contentLength: fetched.contentLength)
  }
}

public enum PublicObjectFetchError: Error, Equatable, CustomStringConvertible {
  /// The server refused the client. With Cloudflare in front of R2 this means
  /// the User-Agent was rejected, not that the object is gone.
  case forbidden(URL)
  /// The object no longer exists at this URL.
  case notFound(URL)
  case failed(URL, detail: String)

  public var description: String {
    switch self {
    case let .forbidden(url):
      return
        "Rejected (HTTP 403) — check User-Agent / object ACL: \(url.absoluteString)"
    case let .notFound(url):
      return "Object no longer exists (HTTP 404): \(url.absoluteString)"
    case let .failed(url, detail):
      return "Fetch failed for \(url.absoluteString): \(detail)"
    }
  }
}

public struct URLSessionPublicObjectFetcher: PublicObjectFetching {
  /// Cloudflare 403s unrecognised agents; an explicit, identifying
  /// agent is therefore mandatory, not cosmetic.
  public static let userAgent = "pinax/\(PinaxVersion.current) (+import)"

  private let session: URLSession
  private let requestTimeout: TimeInterval
  private let throttleBackoff: TimeInterval

  /// - Parameter throttleBackoff: the wait before the one retry after an
  ///   HTTP 429 or 503, when the response names no shorter `Retry-After`.
  public init(
    session: URLSession = .shared, requestTimeout: TimeInterval = 60,
    throttleBackoff: TimeInterval = 2
  ) {
    self.session = session
    self.requestTimeout = requestTimeout
    self.throttleBackoff = throttleBackoff
  }

  public func fetch(_ url: URL) async throws -> (data: Data, mime: String?, contentLength: Int64?) {
    let object = try await fetchObject(url)
    return (object.data, object.mime, object.contentLength)
  }

  public func fetchObject(_ url: URL) async throws -> PublicObject {
    do {
      return try await attempt(url)
    } catch Throttled.status(_, let retryAfter) {
      // A 429 or 503 is the server asking for a pause, so it alone
      // among HTTP statuses waits and retries once; a second one is final.
      let wait = min(retryAfter ?? throttleBackoff, max(throttleBackoff, 30))
      try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
      do {
        return try await attempt(url)
      } catch Throttled.status(let status, _) {
        throw PublicObjectFetchError.failed(url, detail: "HTTP \(status)")
      } catch let error as PublicObjectFetchError {
        throw error
      } catch {
        throw PublicObjectFetchError.failed(url, detail: Self.describe(error))
      }
    } catch let error as PublicObjectFetchError {
      // Other HTTP statuses are definitive; only transport failures retry once.
      throw error
    } catch {
      // A short backoff before the single retry: transport stalls (DNS,
      // connection establishment) are transient, and re-firing immediately
      // into the same stall is a wasted retry, not a faster one.
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      do {
        return try await attempt(url)
      } catch {
        throw PublicObjectFetchError.failed(url, detail: Self.describe(error))
      }
    }
  }

  private enum Throttled: Error {
    case status(Int, retryAfter: TimeInterval?)
  }

  private func attempt(_ url: URL) async throws -> PublicObject {
    var request = URLRequest(url: url)
    request.timeoutInterval = requestTimeout
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw PublicObjectFetchError.failed(url, detail: "non-HTTP response")
    }
    switch http.statusCode {
    case 200..<300:
      break
    case 403:
      throw PublicObjectFetchError.forbidden(url)
    case 404:
      throw PublicObjectFetchError.notFound(url)
    case 429, 503:
      throw Throttled.status(
        http.statusCode,
        retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    default:
      throw PublicObjectFetchError.failed(url, detail: "HTTP \(http.statusCode)")
    }
    let mime = http.value(forHTTPHeaderField: "Content-Type")?
      .split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    let lastModified = http.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
    return PublicObject(
      data: data, mime: mime, contentLength: contentLength, lastModified: lastModified)
  }

  /// RFC 9110's IMF-fixdate, the only form a conforming server sends.
  static func httpDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
  }

  private static func describe(_ error: Error) -> String {
    if case let Throttled.status(status, _) = error {
      return "HTTP \(status)"
    }
    if let urlError = error as? URLError {
      return urlError.localizedDescription
    }
    return String(describing: error)
  }
}
