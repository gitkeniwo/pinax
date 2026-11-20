import CatalogCore
import Foundation

/// One original to save — the catalog's sha256 for it,
/// where its bytes live, and the name to save it under.
public struct DownloadRequest: Equatable, Sendable {
  public let sha256: String
  public let sourceURL: URL
  public let filename: String

  public init(sha256: String, sourceURL: URL, filename: String) {
    self.sha256 = sha256
    self.sourceURL = sourceURL
    self.filename = filename
  }
}

public enum OriginalDownloadError: LocalizedError, Equatable {
  case invalidURL
  case fetch(String)
  case checksumMismatch

  public var errorDescription: String? {
    switch self {
    case .invalidURL: return "the catalog URL is not valid"
    case let .fetch(reason): return reason
    case .checksumMismatch: return "the downloaded bytes don't match the catalog's SHA-256"
    }
  }
}

/// Saves originals into a folder: the bytes are checked against the catalog's
/// sha256 before anything touches disk, and an existing file is never
/// overwritten — a taken name gets Finder's " 2", " 3" suffix instead.
public struct OriginalDownloader: Sendable {
  private let fetcher: any PublicObjectFetching

  /// The import's fetcher: Cloudflare in front of R2 403s unrecognised
  /// agents, so the same identifying User-Agent is needed here.
  public init(fetcher: any PublicObjectFetching = URLSessionPublicObjectFetcher()) {
    self.fetcher = fetcher
  }

  public static var defaultFolder: URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
  }

  /// The first of `name.ext`, `name 2.ext`, `name 3.ext`, … not present in
  /// `folder`.
  public static func availableURL(for filename: String, in folder: URL) -> URL {
    let ext = (filename as NSString).pathExtension
    let base = (filename as NSString).deletingPathExtension
    var number = 1
    while true {
      let name =
        number == 1 ? filename : ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
      let candidate = folder.appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      number += 1
    }
  }

  public func download(_ request: DownloadRequest, to folder: URL) async throws -> URL {
    let data: Data
    do {
      data = try await fetcher.fetch(request.sourceURL).data
    } catch let error as PublicObjectFetchError {
      throw OriginalDownloadError.fetch(Self.reason(error))
    }
    guard Hashing.sha256(of: data) == request.sha256 else {
      throw OriginalDownloadError.checksumMismatch
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // `.withoutOverwriting` makes the no-overwrite rule hold even when a file
    // appears between the name check and the write: that write fails, and
    // the next free name is taken.
    while true {
      let destination = Self.availableURL(for: request.filename, in: folder)
      do {
        try data.write(to: destination, options: .withoutOverwriting)
        return destination
      } catch CocoaError.fileWriteFileExists {
        continue
      }
    }
  }

  private static func reason(_ error: PublicObjectFetchError) -> String {
    switch error {
    case .forbidden: return "the server refused it (HTTP 403)"
    case .notFound: return "it no longer exists (HTTP 404)"
    case let .failed(_, detail): return detail
    }
  }
}
