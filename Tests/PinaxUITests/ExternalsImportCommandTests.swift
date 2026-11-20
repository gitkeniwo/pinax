import ArgumentParser
import CatalogCore
import Testing

@testable import pinax

/// `pinax externals import`'s argument rules, exit
/// codes and table. Parsing only — `run` would GET over the network.
@Suite struct ExternalsImportCommandTests {
  @Test("Bare `externals` still lists; `externals import` is the claim")
  func routing() throws {
    let list = try Pinax.parseAsRoot(["externals", "--project", "blog"])
    #expect(list is ExternalsListCommand)
    #expect((list as? ExternalsListCommand)?.project == "blog")
    let claim = try Pinax.parseAsRoot(
      ["externals", "import", "--project", "blog", "--all", "--dry-run", "--format", "json"])
    let command = try #require(claim as? ExternalsImportCommand)
    #expect(command.project == "blog")
    #expect(command.all && command.dryRun && command.format == .json)
    let named = try #require(
      try Pinax.parseAsRoot(["externals", "import", "https://a.invalid/x.png"])
        as? ExternalsImportCommand)
    #expect(named.urls == ["https://a.invalid/x.png"])
  }

  @Test("URLs with --all, or neither, is a usage error: exit 64")
  func argumentErrorsExit64() {
    for arguments in [
      ["externals", "import", "--all", "https://a.invalid/x.png"],
      ["externals", "import"],
      ["externals", "import", "--all", "--format", "yaml"],
    ] {
      do {
        _ = try Pinax.parseAsRoot(arguments)
        Issue.record("\(arguments) parsed")
      } catch {
        #expect(Pinax.exitCode(for: error).rawValue == 64, "\(arguments)")
      }
    }
  }

  @Test("The table lists every skip category, the CDN check, the relink count and the reindex note")
  func table() {
    let result = ExternalsClaimResult(
      dryRun: false, references: 5, distinctKeys: 4, alreadyInCatalog: 1,
      claimed: [
        ExternalsClaimedItem(
          key: "2020/a.png", url: "https://img.invalid/2020/a.png", sha256: "aa", byteSize: 3,
          projects: ["blog"])
      ],
      skipped: [
        ExternalsClaimSkip(
          reason: "same_content", url: "https://img.invalid/2020/b.png", key: "2020/b.png",
          detail: "same image as blog/x.png", existingKey: "blog/x.png")
      ],
      cdnCheck: [
        CDNByteCheck(
          backend: "r2", status: .unchecked, sampled: 0, matched: 0, mismatched: [],
          unreachable: 0)
      ],
      refused: false, cancelled: false, remaining: 0, relinkedUsage: 2)
    let table = ExternalsImportCommand.table(result)
    #expect(table.contains("claimed\t1\n"))
    for reason in [
      "not_found", "forbidden", "same_content", "other_backend", "bad_key", "fetch_failed",
    ] {
      #expect(table.contains("skipped\t\(reason)\t"), "\(reason)")
    }
    #expect(table.contains("skipped\tsame_content\t1\n"))
    #expect(table.contains("SKIPPED\tsame_content\thttps://img.invalid/2020/b.png\tsame image as blog/x.png"))
    #expect(table.contains("cdn_check\tr2\tunchecked\t0/0 matched"))
    #expect(table.contains("relinked_usage\t2\n"))
    #expect(table.hasSuffix("NOTE\t\(ExternalsClaimResult.reindexNotice)\n"))
    #expect(!result.hasFailures)
    #expect(ExternalsImportCommand.warnings(result).count == 1)
  }
}
