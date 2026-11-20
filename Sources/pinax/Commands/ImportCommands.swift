import ArgumentParser
import CatalogCore
import Foundation

struct ImportCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import",
    abstract: "Import libraries from other tools.",
    subcommands: [ImportPicGoGalleryCommand.self, ImportBucketCommand.self]
  )
}

struct ImportPicGoGalleryCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "picgo-gallery",
    abstract: "Import PicGo's gallery by fetching each public object and hashing it locally."
  )

  @Option(help: "Backend whose url_prefix identifies the objects.")
  var backend: String

  @Option(help: "Path to PicGo's store (gzip-compressed JSON).")
  var path = "~/Library/Application Support/picgo/picgo.db"

  @Flag(help: "Parse, resolve, fetch, hash, report — insert nothing.")
  var dryRun = false

  @Flag(name: .long, help: "After importing, write catalog metadata onto the objects themselves.")
  var backfillObjectMetadata = false

  @Flag(help: "Skip the backfill confirmation prompt.")
  var yes = false

  @Flag(
    name: .long,
    help: "Acknowledge that on non-R2 S3 providers a metadata rewrite resets per-object ACLs to the bucket default."
  )
  var allowAclReset = false

  mutating func run() async throws {
    let database = try openCatalogDatabase()
    let selected = try CatalogConfiguration.backend(slug: backend, in: database)
    let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let records = try PicGoGallery.records(contentsOf: fileURL)

    // The import itself needs no credentials: objects are public and sha256
    // is computed from the fetched bytes.
    let result = try await PicGoGalleryImporter.importGallery(
      records: records,
      backend: selected,
      in: database,
      fetcher: URLSessionPublicObjectFetcher(),
      dryRun: dryRun
    )
    print(try encodedJSON(result))
    for skip in result.skipped {
      FileHandle.standardError.write(
        Data("SKIPPED\t\(skip.reason)\t\(skip.url)\n".utf8))
    }

    guard backfillObjectMetadata else { return }

    // Never in the same pass as the insert. The import above has
    // committed; backfill runs against the now-known-good catalog rows.
    if PicGoBackfill.requiresACLResetAcknowledgement(selected) && !allowAclReset {
      throw ValidationError(
        "Backfill re-uploads each object onto itself, and on S3 providers with per-object "
          + "ACLs that resets visibility to the bucket default — HEAD cannot read an object's "
          + "ACL, so it cannot be preserved. R2 backends are unaffected (no per-object ACL). "
          + "Pass --allow-acl-reset to proceed anyway.")
    }
    let credentials: BackendCredentials
    if selected.keychainRef.isEmpty {
      throw ValidationError(credentialMissingMessage(for: selected))
    } else if let stored = try Keychain().load(for: selected.keychainRef) {
      credentials = stored
    } else {
      throw ValidationError(credentialMissingMessage(for: selected))
    }
    let inventory = S3ObjectInventory(backend: selected, credentials: credentials)
    let assets = try PicGoBackfill.assets(for: selected, in: database)
    let plan = try await PicGoBackfill.plan(assets: assets, inventory: inventory)

    FileHandle.standardError.write(
      Data(
        (
          "Backfill: \(assets.count) objects checked — "
            + "\(plan.matchingKeys.count) already carry matching metadata, "
            + "\(plan.candidates.count) will be re-uploaded onto themselves "
            + "with sha256/orig-filename/width/height metadata "
            + "(Content-Type preserved; Cache-Control set to the immutable policy where "
            + "absent; no ACL is sent).\n"
        ).utf8
      ))
    for candidate in plan.candidates {
      FileHandle.standardError.write(Data("WRITE\t\(candidate.asset.key)\n".utf8))
    }
    for failure in plan.headFailures {
      FileHandle.standardError.write(
        Data("HEAD-FAILED\t\(failure.key)\t\(failure.detail)\n".utf8))
    }

    if !plan.candidates.isEmpty && !yes {
      FileHandle.standardError.write(
        Data("Proceed with \(plan.candidates.count) writes? [y/N] ".utf8))
      guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
        answer == "y" || answer == "yes"
      else {
        throw ValidationError("Aborted; no objects were modified.")
      }
    }

    let backfillResult = try await PicGoBackfill.apply(
      plan: plan,
      backend: selected,
      uploader: S3Uploader(backend: selected, credentials: credentials),
      fetcher: URLSessionPublicObjectFetcher(),
      dryRun: dryRun
    )
    print(try encodedJSON(backfillResult))
    if dryRun {
      FileHandle.standardError.write(
        Data(
          (
            "Dry run: nothing was written; 'backfilled' counts objects that would "
              + "have been updated.\n"
          ).utf8))
    }
    for failure in backfillResult.failed {
      FileHandle.standardError.write(
        Data("FAILED\t\(failure.key)\t\(failure.detail)\n".utf8))
    }
  }
}
