import ArgumentParser
import CatalogCore
import Foundation
import Testing

@testable import pinax

/// `pinax import bucket`'s arguments, table and the
/// messages for a refused List and missing credentials. Parsing and pure
/// functions only — `run` would List and GET over the network.
@Suite struct BucketImportCommandTests {
  @Test("`import bucket` takes --backend, --dry-run and --format; reindex is untouched")
  func routing() throws {
    let parsed = try Pinax.parseAsRoot(
      ["import", "bucket", "--backend", "r2", "--dry-run", "--format", "json"])
    let command = try #require(parsed as? ImportBucketCommand)
    #expect(command.backend == "r2" && command.dryRun && command.format == .json)
    let plain = try #require(
      try Pinax.parseAsRoot(["import", "bucket", "--backend", "r2"]) as? ImportBucketCommand)
    #expect(!plain.dryRun && plain.format == .table)
    #expect(try Pinax.parseAsRoot(["reindex", "--backend", "r2"]) is ReindexCommand)
    for arguments in [
      ["import", "bucket"], ["import", "bucket", "--backend", "r2", "--format", "yaml"],
      ["reindex", "--backend", "r2", "--claim-unreferenced"],
    ] {
      do {
        _ = try Pinax.parseAsRoot(arguments)
        Issue.record("\(arguments) parsed")
      } catch {
        #expect(Pinax.exitCode(for: error).rawValue == 64, "\(arguments)")
      }
    }
  }

  @Test("The table counts every category, lists referenced keys and skips, and ends with the reindex note")
  func table() {
    let result = BucketClaimResult(
      dryRun: true, backend: "r2", listed: 9, alreadyInCatalog: 4, referenced: ["2024/used.png"],
      candidates: 2,
      claimed: [
        ExternalsClaimedItem(
          key: "2024/a.png", url: "https://img.invalid/2024/a.png", sha256: "aa", byteSize: 3,
          projects: [])
      ],
      skipped: [
        ExternalsClaimSkip(
          reason: "pending_deletion", url: "https://img.invalid/2024/d.png", key: "2024/d.png",
          detail: "staged for permanent deletion"),
        ExternalsClaimSkip(
          reason: "not_found", url: "https://img.invalid/2024/g.png", key: "2024/g.png",
          detail: "object no longer exists"),
      ],
      cdnCheck: [
        CDNByteCheck(
          backend: "r2", status: .unchecked, sampled: 0, matched: 0, mismatched: [],
          unreachable: 0)
      ],
      refused: false, cancelled: false, remaining: 0)
    #expect(
      ImportBucketCommand.table(result) == """
        dry_run\tnothing written
        listed\t9
        already_in_catalog\t4
        referenced\t1
        candidates\t2
        claimed\t1
        skipped\tpending_deletion\t1
        skipped\tbad_key\t0
        skipped\tnot_found\t1
        skipped\tforbidden\t0
        skipped\tsame_content\t0
        skipped\tfetch_failed\t0
        cdn_check\tr2\tunchecked\t0/0 matched
        REFERENCED\t2024/used.png\tused by a page; claim it with `pinax externals import`
        SKIPPED\tpending_deletion\thttps://img.invalid/2024/d.png\tstaged for permanent deletion
        SKIPPED\tnot_found\thttps://img.invalid/2024/g.png\tobject no longer exists
        NOTE\t\(ExternalsClaimResult.reindexNotice)

        """)
    #expect(result.hasFailures)
    #expect(
      ExternalsImportCommand.warnings(result.cdnCheck) == [
        "r2: CDN byte check not done — no image Pinax uploaded could be compared."
      ])
  }

  @Test("A 403 List reads as a permission problem; other errors are left alone")
  func listRefusal() async throws {
    let backend = Self.backend(keychainRef: "")
    for status in [401, 403] {
      #expect(
        BucketClaim.listRefusalMessage(
          for: S3UploaderError.http(statusCode: status, body: "<Error>AccessDenied</Error>"),
          backend: backend)
          == "images refused to list its objects (HTTP \(status)). The credentials for r2 need permission to list the bucket.")
    }
    #expect(
      BucketClaim.listRefusalMessage(
        for: S3UploaderError.http(statusCode: 500, body: ""), backend: backend) == nil)
    #expect(BucketClaim.listRefusalMessage(for: URLError(.timedOut), backend: backend) == nil)
  }

  @Test("No credentials stops before any request with the set-credentials hint")
  func missingCredentials() throws {
    let environment = ProcessInfo.processInfo.environment
    try #require(environment["PINAX_ACCESS_KEY_ID"] == nil)
    // An empty Keychain reference: the lookup never reaches the Keychain.
    do {
      _ = try reindexCredentials(for: Self.backend(keychainRef: ""))
      Issue.record("credentials resolved")
    } catch let error as ValidationError {
      #expect(
        error.message
          == "Backend 'r2' was registered without credentials. Run: pinax backend set-credentials --slug r2")
    }
  }

  static func backend(keychainRef: String) -> Backend {
    Backend(
      id: 1, slug: "r2", kind: "s3", endpoint: "https://s3.pinax.invalid", bucket: "images",
      region: "auto", urlPrefix: "https://img.pinax.invalid", keychainRef: keychainRef,
      createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
  }
}
