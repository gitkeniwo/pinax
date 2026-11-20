import Foundation

/// One object to claim: the object stays where it is in the
/// bucket and the catalog gains a row pointing at its key. `fetchURL` is
/// where the bytes are read from; `reportURL` is what a skip names.
struct ObjectClaimCandidate: Sendable {
  let key: String
  let fetchURL: String
  let reportURL: String
  /// Dimension hints; a missing or non-positive one is probed from the bytes.
  let width: Int?
  let height: Int?
  let originalFilename: String?
  /// nil falls back per `ObjectClaim.UploadedAtFallback`.
  let uploadedAt: String?
  let meta: String
}

enum ObjectClaimOutcome: Sendable {
  case prepared(Asset)
  case skipped(PicGoImportSkipped)
  /// The bytes are already in the catalog under `existingKey`.
  case contentDuplicate(existingKey: String)
}

/// The claim layer shared by the PicGo import and the Externals import:
/// given (backend, key) and a URL, GET the bytes, measure sha256, size,
/// dimensions and mime, and build the row. It writes nothing and never
/// synthesises a sha256; callers decide what
/// to insert, in which transaction.
enum ObjectClaim {
  enum UploadedAtFallback: Sendable {
    /// The PicGo import's rule: no recorded time means now.
    case now
    /// The response's `Last-Modified`, else now.
    case lastModified
  }

  static let iso8601 = ISO8601DateFormatter()

  static func prepare(
    _ candidate: ObjectClaimCandidate,
    backendID: Int64,
    knownHashes: [String: String],
    now: Date,
    uploadedAtFallback: UploadedAtFallback,
    fetcher: any PublicObjectFetching,
    gate: ImportSlotGate
  ) async throws -> ObjectClaimOutcome {
    let url: URL
    if let parsed = URL(string: candidate.fetchURL) {
      url = parsed
    } else {
      return .skipped(
        PicGoImportSkipped(
          url: candidate.reportURL, reason: PicGoSkipReason.fetchFailed,
          detail: "malformed URL"))
    }
    let fetched: PublicObject
    do {
      fetched = try await gate.withSlot { try await fetcher.fetchObject(url) }
    } catch let error as PublicObjectFetchError {
      switch error {
      case .forbidden:
        return .skipped(
          PicGoImportSkipped(
            url: candidate.reportURL, reason: PicGoSkipReason.forbidden,
            detail: "rejected — check User-Agent / object ACL"))
      case .notFound:
        return .skipped(
          PicGoImportSkipped(
            url: candidate.reportURL, reason: PicGoSkipReason.notFound,
            detail: "object no longer exists"))
      case let .failed(_, detail):
        return .skipped(
          PicGoImportSkipped(
            url: candidate.reportURL, reason: PicGoSkipReason.fetchFailed, detail: detail))
      }
    }
    let data = fetched.data
    if let contentLength = fetched.contentLength, contentLength != Int64(data.count) {
      return .skipped(
        PicGoImportSkipped(
          url: candidate.reportURL, reason: PicGoSkipReason.lengthMismatch,
          detail: "content-length \(contentLength) but received \(data.count) bytes"))
    }
    let sha256 = Hashing.sha256(of: data)
    if let existingKey = knownHashes[sha256] {
      return .contentDuplicate(existingKey: existingKey)
    }
    var width = candidate.width
    var height = candidate.height
    if (width ?? 0) <= 0 || (height ?? 0) <= 0 {
      if let dimensions = ImageProbe.dimensions(of: data) {
        width = (width ?? 0) > 0 ? width : dimensions.width
        height = (height ?? 0) > 0 ? height : dimensions.height
      }
    }
    let mime = usableMime(fetched.mime) ?? mimeFromBytes(data, key: candidate.key)
    let fallbackDate: Date
    switch uploadedAtFallback {
    case .now: fallbackDate = now
    case .lastModified: fallbackDate = fetched.lastModified ?? now
    }
    let timestamp = iso8601.string(from: now)
    let asset = Asset(
      sha256: sha256,
      backendID: backendID,
      key: candidate.key,
      byteSize: Int64(data.count),
      width: (width ?? 0) > 0 ? width : nil,
      height: (height ?? 0) > 0 ? height : nil,
      mime: mime,
      originalFilename: candidate.originalFilename,
      state: "active",
      pinned: false,
      note: nil,
      meta: candidate.meta,
      uploadedAt: candidate.uploadedAt ?? iso8601.string(from: fallbackDate),
      createdAt: timestamp,
      updatedAt: timestamp
    )
    return .prepared(asset)
  }

  private static func usableMime(_ mime: String?) -> String? {
    guard let mime, !mime.isEmpty, mime.lowercased() != "application/octet-stream" else {
      return nil
    }
    return mime
  }

  private static func mimeFromBytes(_ data: Data, key: String) -> String {
    let extention = key.split(separator: ".").last.map(String.init) ?? ""
    return MimeDetector.mimeType(of: data, fileExtension: extention) ?? "application/octet-stream"
  }
}
