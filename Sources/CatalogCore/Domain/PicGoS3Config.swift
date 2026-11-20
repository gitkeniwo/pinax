import Foundation

public enum PicGoS3ConfigError: Error, Equatable, CustomStringConvertible {
  case missingS3Block
  case missingField(String)

  public var description: String {
    switch self {
    case .missingS3Block:
      return "PicGo config has no picBed.aws-s3 block."
    case let .missingField(field):
      return "PicGo aws-s3 field '\(field)' is missing or empty."
    }
  }
}

public struct PicGoS3Config: Sendable {
  public let slug: String
  public let endpoint: String
  public let bucket: String
  public let urlPrefix: String
  public let region: String
  public let backendMeta: String

  public init(contentsOf fileURL: URL) throws {
    try self.init(data: Data(contentsOf: fileURL))
  }

  public init(data: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let picBed = root["picBed"] as? [String: Any],
      let awsS3 = picBed["aws-s3"] as? [String: Any]
    else {
      throw PicGoS3ConfigError.missingS3Block
    }

    let selected: [String: Any]
    if let configs = awsS3["configList"] as? [[String: Any]], let first = configs.first {
      selected = first
    } else {
      selected = awsS3
    }

    self.endpoint = try Self.requiredString(in: selected, keys: ["endpoint"], field: "endpoint")
    self.bucket = try Self.requiredString(
      in: selected,
      keys: ["bucket", "bucketName"],
      field: "bucket"
    )
    self.urlPrefix = try Self.requiredString(
      in: selected,
      keys: ["urlPrefix", "customUrl", "customURL"],
      field: "urlPrefix"
    )
    self.slug = Self.nonEmptyString(in: selected, keys: ["slug"]) ?? "r2"
    self.region = Self.nonEmptyString(in: selected, keys: ["region"]) ?? "auto"

    if let uploadPath = Self.nonEmptyString(in: selected, keys: ["uploadPath"]) {
      let data = try JSONSerialization.data(
        withJSONObject: ["picgo_upload_path": uploadPath],
        options: [.sortedKeys]
      )
      self.backendMeta = String(decoding: data, as: UTF8.self)
    } else {
      self.backendMeta = "{}"
    }
  }

  private static func requiredString(
    in object: [String: Any],
    keys: [String],
    field: String
  ) throws -> String {
    guard let value = optionalString(in: object, keys: keys), !value.isEmpty else {
      throw PicGoS3ConfigError.missingField(field)
    }
    return value
  }

  private static func nonEmptyString(in object: [String: Any], keys: [String]) -> String? {
    guard let value = optionalString(in: object, keys: keys), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static func optionalString(in object: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = object[key] as? String {
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return nil
  }
}
