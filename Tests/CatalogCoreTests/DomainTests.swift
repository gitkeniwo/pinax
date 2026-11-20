import CatalogCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Test("SHA-256 matches standard vectors")
func hashingStandardVectors() throws {
  let vectors: [(Data, String)] = [
    (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    (
      Data("The quick brown fox jumps over the lazy dog".utf8),
      "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
    ),
  ]

  try withDomainTemporaryDirectory { directory in
    for (index, vector) in vectors.enumerated() {
      let file = directory.appendingPathComponent("hash-\(index)")
      try vector.0.write(to: file)
      #expect(try Hashing.sha256(ofFileAt: file) == vector.1)
    }
  }
}

@Test("Image probe returns display dimensions and rejects non-images")
func imageProbeTable() throws {
  let onePixelPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  )!
  let cases: [(name: String, data: Data, expected: ImageDimensions?)] = [
    ("pixel.png", onePixelPNG, ImageDimensions(width: 1, height: 1)),
    ("notes.txt", Data("not an image".utf8), nil),
  ]

  try withDomainTemporaryDirectory { directory in
    for testCase in cases {
      let file = directory.appendingPathComponent(testCase.name)
      try testCase.data.write(to: file)
      #expect(ImageProbe.dimensions(ofFileAt: file) == testCase.expected)
    }

    let rotatedJPEG = directory.appendingPathComponent("orientation-6.jpg")
    try writeOrientedJPEG(to: rotatedJPEG, orientation: 6)
    #expect(
      ImageProbe.dimensions(ofFileAt: rotatedJPEG)
        == ImageDimensions(width: 2, height: 4)
    )
  }
}

@Test("MIME detector recognizes supported magic bytes")
func mimeMagicBytesTable() throws {
  let cases: [(name: String, data: Data, expected: String)] = [
    ("png", Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "image/png"),
    ("jpeg", Data([0xff, 0xd8, 0xff, 0xe0]), "image/jpeg"),
    ("gif", Data("GIF89a".utf8), "image/gif"),
    ("tiff", Data([0x49, 0x49, 0x2a, 0x00]), "image/tiff"),
    ("webp", Data("RIFF0000WEBP".utf8), "image/webp"),
    ("heic", Data([0, 0, 0, 24]) + Data("ftypheic".utf8), "image/heic"),
    ("svg", Data("<?xml version=\"1.0\"?><svg></svg>".utf8), "image/svg+xml"),
    ("pdf", Data("%PDF-1.7".utf8), "application/pdf"),
  ]

  try withDomainTemporaryDirectory { directory in
    for testCase in cases {
      let file = directory.appendingPathComponent("\(testCase.name).bin")
      try testCase.data.write(to: file)
      #expect(try MimeDetector.mimeType(ofFileAt: file) == testCase.expected)
    }
  }
}

@Test("MIME detector falls back to supported extensions")
func mimeExtensionTable() throws {
  let cases: [(extension: String, expected: String)] = [
    ("png", "image/png"),
    ("jpg", "image/jpeg"),
    ("JPEG", "image/jpeg"),
    ("gif", "image/gif"),
    ("webp", "image/webp"),
    ("heic", "image/heic"),
    ("heif", "image/heic"),
    ("tiff", "image/tiff"),
    ("svg", "image/svg+xml"),
    ("pdf", "application/pdf"),
  ]

  try withDomainTemporaryDirectory { directory in
    for (index, testCase) in cases.enumerated() {
      let file = directory.appendingPathComponent("fallback-\(index).\(testCase.extension)")
      try Data("no recognized header".utf8).write(to: file)
      #expect(try MimeDetector.mimeType(ofFileAt: file) == testCase.expected)
    }
  }
}

@Test("MIME magic takes precedence over extension and unknown files return nil")
func mimePrecedenceAndUnknown() throws {
  try withDomainTemporaryDirectory { directory in
    let disguisedPNG = directory.appendingPathComponent("image.jpg")
    try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).write(to: disguisedPNG)
    #expect(try MimeDetector.mimeType(ofFileAt: disguisedPNG) == "image/png")

    let unknown = directory.appendingPathComponent("image.bin")
    try Data("unknown".utf8).write(to: unknown)
    #expect(try MimeDetector.mimeType(ofFileAt: unknown) == nil)
  }
}

@Test("Key template normalizes prefixes and slugs")
func keyTemplateTable() throws {
  let date = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
  let sha = String(repeating: "a", count: 64)
  let cases: [(prefix: String, filename: String, ext: String, expected: String)] = [
    (
      "//blog///", "Dashboard Final!!.PNG", ".PNG",
      "blog/202608/dashboard-final-aaaaaaaaaaaa.png"
    ),
    ("", "!!!.jpg", "jpg", "202608/image-aaaaaaaaaaaa.jpg"),
    (
      "portfolio", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890-extra-long-name.png", "png",
      "portfolio/202608/abcdefghijklmnopqrstuvwxyz1234567890-ext-aaaaaaaaaaaa.png"
    ),
    ("blog", "截图 你好.png", "png", "blog/202608/jie-tu-ni-hao-aaaaaaaaaaaa.png"),
    ("blog", "../../ev il 😀 .PNG", "png", "blog/202608/ev-il-aaaaaaaaaaaa.png"),
    ("blog//drafts", "a___b--c.gif", "gif", "blog/drafts/202608/a-b-c-aaaaaaaaaaaa.gif"),
  ]

  for testCase in cases {
    #expect(
      try KeyTemplate.render(
        keyPrefix: testCase.prefix,
        originalFilename: testCase.filename,
        sha256: sha,
        fileExtension: testCase.ext,
        date: date
      ) == testCase.expected)
  }
}

@Test("Key template rejects invalid hashes and empty extensions")
func keyTemplateValidation() throws {
  let date = Date(timeIntervalSince1970: 0)
  #expect(throws: KeyTemplateError.invalidSHA256) {
    try KeyTemplate.render(
      keyPrefix: "", originalFilename: "a.png", sha256: "xyz",
      fileExtension: "png", date: date
    )
  }
  #expect(throws: KeyTemplateError.missingFileExtension) {
    try KeyTemplate.render(
      keyPrefix: "", originalFilename: "a", sha256: String(repeating: "a", count: 64),
      fileExtension: "...", date: date
    )
  }
}

@Test("URL resolver builds catalog URLs")
func urlResolverBuildsURL() {
  let backend = makeBackend(urlPrefix: "https://img.example.com/")
  let asset = makeAsset(key: "blog/image.png")
  #expect(URLResolver.url(for: asset, backend: backend) == "https://img.example.com/blog/image.png")
}

@Test("URL resolver handles current, retired, encoded, queried, and foreign URLs")
func urlResolverTable() {
  let backend = makeBackend(urlPrefix: "https://img.example.com/images")
  let retired = ["https://old.example.com/assets"]
  let cases: [(rawURL: String, expected: String?)] = [
    ("https://img.example.com/images/blog/image.png", "blog/image.png"),
    ("https://old.example.com/assets/blog/image.png", "blog/image.png"),
    ("https://img.example.com/images/blog/my%20image.png?download=1", "blog/my image.png"),
    ("https://img.example.com/images/blog/%E4%B8%AD.png#preview", "blog/中.png"),
    ("https://foreign.example.com/images/blog/image.png", nil),
    ("https://img.example.com/images-other/blog/image.png", nil),
    ("https://img.example.com/images", nil),
  ]

  for testCase in cases {
    #expect(
      URLResolver.key(
        from: testCase.rawURL,
        backend: backend,
        retiredPrefixes: retired
      ) == testCase.expected)
  }
}

@Test("URL resolver round-trips decoded object keys")
func urlResolverRoundTrip() {
  let backend = makeBackend(urlPrefix: "https://img.example.com/images")
  let keys = [
    "blog/image.png",
    "legacy/my image.png",
    "legacy/中文图片.png",
    "legacy/100%?#.png",
    "/leading/slash.png",
  ]

  for key in keys {
    let asset = makeAsset(key: key)
    let url = URLResolver.url(for: asset, backend: backend)
    #expect(URLResolver.key(from: url, backend: backend) == key)
  }
}

/// The scanner reports `<…>` destinations with raw
/// spaces; the resolver already reads them and decodes to the stored key.
@Test("URL resolver reads a raw space in the path")
func urlResolverRawSpace() {
  let backend = makeBackend(urlPrefix: "https://x.invalid")
  #expect(
    URLResolver.key(from: "https://x.invalid/2024/09/Screenshot 2024-09-22 at 23.21.24.png", backend: backend)
      == "2024/09/Screenshot 2024-09-22 at 23.21.24.png")
  #expect(URLResolver.key(from: "https://x.invalid/a%20b.png", backend: backend) == "a b.png")
}

private enum FixtureError: Error {
  case couldNotCreateJPEG
}

private func writeOrientedJPEG(to fileURL: URL, orientation: Int) throws {
  let width = 4
  let height = 2
  guard
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else {
    throw FixtureError.couldNotCreateJPEG
  }
  context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))

  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      fileURL as CFURL,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    )
  else {
    throw FixtureError.couldNotCreateJPEG
  }
  CGImageDestinationAddImage(
    destination,
    image,
    [kCGImagePropertyOrientation: orientation] as CFDictionary
  )
  guard CGImageDestinationFinalize(destination) else {
    throw FixtureError.couldNotCreateJPEG
  }
}

private func withDomainTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func makeBackend(urlPrefix: String) -> Backend {
  Backend(
    slug: "r2",
    kind: "s3",
    endpoint: "https://example.r2.cloudflarestorage.com",
    bucket: "images",
    urlPrefix: urlPrefix,
    keychainRef: "r2",
    createdAt: "2026-08-20T00:00:00Z",
    updatedAt: "2026-08-20T00:00:00Z"
  )
}

private func makeAsset(key: String) -> Asset {
  Asset(
    sha256: String(repeating: "a", count: 64),
    backendID: 1,
    key: key,
    byteSize: 100,
    mime: "image/png",
    uploadedAt: "2026-08-20T00:00:00Z",
    createdAt: "2026-08-20T00:00:00Z",
    updatedAt: "2026-08-20T00:00:00Z"
  )
}
