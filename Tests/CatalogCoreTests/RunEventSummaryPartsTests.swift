import CatalogCore
import Foundation
import Testing

/// `summaryParts` splits each sentence into verb / object / detail, and
/// `summaryLine` (joined from it) reads word for word as each event's
/// sentence — one example per event and per branch. The expected strings
/// are written out in full.
@Suite("RunEventSummaryParts")
struct RunEventSummaryPartsTests {
  private static let sha = String(repeating: "a", count: 64)

  private static func migration(_ edit: (inout ExternalMigrationSummary) -> Void) -> ExternalMigrationSummary {
    var summary = ExternalMigrationSummary()
    edit(&summary)
    return summary
  }

  private static func finished(errors: Int = 0, written: Int? = nil, migration: ExternalMigrationSummary? = nil)
    -> RunEvent
  {
    var summary = RewriteRunSummary(files: 3, edits: 1, written: written, errors: errors)
    summary.migration = migration
    return .runFinished(summary)
  }

  static let cases: [(RunEvent, String)] = [
    (.runStarted(RewriteRunParams(targets: [RewriteRunTarget(project: "blog", rules: [.exact(from: "a", to: "b")])])),
     "Started blog · 1 rule"),
    (.runStarted(
      RewriteRunParams(
        targets: [
          RewriteRunTarget(project: "blog", rules: [.exact(from: "a", to: "b"), .exact(from: "c", to: "d")]),
          RewriteRunTarget(project: "astro", rules: []),
        ],
        domain: DomainMigrationParams(
          backend: "r2", from: "https://a", to: "https://b", oldDomains: [], keepOldDomains: false))),
     "Started moving r2 to https://b · blog, astro · 2 rules"),
    (.sourceStatus(SourceStatusEvent(project: "blog", source: "site", git: .clean)), "blog/site is clean"),
    (.sourceStatus(SourceStatusEvent(project: "blog", source: "site", git: .notGit)), "blog/site isn’t in git"),
    (.sourceStatus(SourceStatusEvent(project: "blog", source: "site", git: .dirty(paths: ["a", "b"]))),
     "blog/site has 2 uncommitted changes"),
    (.sourceStatus(SourceStatusEvent(project: "blog", source: "site", git: .unknown(reason: "no git"))),
     "blog/site: git status unknown — no git"),
    (.filePlanned(
      FilePlannedEvent(project: "blog", source: "site", path: "posts/a.md", sha256: sha, edits: 2, editsDigest: "x")),
     "Will rewrite posts/a.md · 2 refs"),
    (.editSkipped(EditSkippedEvent(project: "blog", source: "site", path: "a.md", line: 4, reason: "not_utf8")),
     "Left a.md:4 as is — the file isn’t UTF-8"),
    (.editSkipped(EditSkippedEvent(project: "blog", source: "site", path: "a.md", line: 4, reason: "unsafe_target")),
     "Left a.md:4 as is — the new URL wouldn’t read back here"),
    (.protocolRelativeFound(
      ProtocolRelativeEvent(project: "blog", source: "site", path: "a.md", host: "img.x", count: 1)),
     "a.md has 1 protocol-relative link to img.x — change by hand"),
    (.targetVerified(TargetVerifiedEvent(url: "https://n/a.png", expectedSHA256: sha, verification: .ok(sha256: sha))),
     "Checked https://n/a.png"),
    (.targetVerified(
      TargetVerifiedEvent(
        url: "https://n/a.png", expectedSHA256: sha, verification: .mismatch(expected: sha, actual: "b"))),
     "https://n/a.png serves a different file"),
    (.targetVerified(
      TargetVerifiedEvent(url: "https://n/a.png", expectedSHA256: sha, verification: .unreachable(reason: "HTTP 404"))),
     "Couldn’t fetch https://n/a.png — HTTP 404"),
    (.targetVerified(
      TargetVerifiedEvent(
        url: "https://n/a.png", expectedSHA256: nil, verification: .unreachable(reason: "HTTP 404"),
        oldReason: "HTTP 404")),
     "https://n/a.png was already broken — the old URL fails too"),
    (.prefixChanged(PrefixChangedEvent(backend: "r2", from: "https://a", to: "https://b")),
     "Changed r2’s URL prefix to https://b"),
    (.fileWritten(
      FileWrittenEvent(
        project: "blog", source: "site", path: "a.md", beforeSHA256: sha, afterSHA256: sha, edits: 1,
        backupPath: nil)),
     "Rewrote a.md · 1 ref"),
    (.fileSkipped(FileSkippedEvent(project: "blog", source: "site", path: "a.md", reason: "symlink")),
     "Skipped a.md — it’s a symbolic link"),
    (.fileSkipped(FileSkippedEvent(project: "blog", source: "site", path: "a.md", reason: "changed_since_plan")),
     "Skipped a.md — changed since the preview"),
    (.fileFailed(FileFailedEvent(project: "blog", source: "site", path: "a.md", error: "disk full")),
     "Couldn’t write a.md — disk full"),
    (.rescanFinished(RescanFinishedEvent(project: "blog", refs: 12, files: 1)), "Rescanned blog · 12 refs in 1 file"),
    (.rescanFailed(RescanFailedEvent(project: "blog", error: "gone")), "Couldn’t rescan blog — gone"),
    (.migrationStarted(
      MigrationStartedEvent(
        targets: [.init(project: "astro", urls: 2, links: 3, hosts: 2)], backend: "r2", hosts: 2)),
     "Started — 3 links from 2 hosts"),
    (.downloadFinished(
      DownloadFinishedEvent(
        url: "https://h/x.jpg", host: "h", sha256: sha, bytes: 1_800_000, mime: "image/jpeg", filename: "x.jpg",
        sniffed: false, cachePath: "c")),
     "Downloaded x.jpg · 1.8 MB"),
    (.downloadFinished(
      DownloadFinishedEvent(
        url: "https://h/x.jpg", host: "h", sha256: sha, bytes: 412_000, mime: "image/jpeg", filename: "x.jpg",
        sniffed: false, cachePath: "c")),
     "Downloaded x.jpg · 412 KB"),
    (.downloadFailed(DownloadFailedEvent(url: "https://h.com/a/b/c.png", host: "h.com", reason: .httpStatus, status: 404)),
     "Skipped h.com/…/c.png — 404, left as is"),
    (.migrationPlanned(
      MigrationPlannedEvent(url: "https://h/x.jpg", sha256: sha, key: "202610/x.jpg", newURL: "https://n/x")),
     "Will upload x.jpg → 202610/x.jpg"),
    (.migrationPlanned(
      MigrationPlannedEvent(
        url: "https://h/x.jpg", sha256: sha, key: "k", newURL: "https://n/x", reusedAssetID: 7, filename: "y.jpg")),
     "Will reuse y.jpg — already in the library"),
    (.uploadFinished(
      UploadFinishedEvent(url: "https://h/x.jpg", key: "202610/x.jpg", newURL: "https://n/x", assetID: 1, bytes: 3)),
     "Uploaded x.jpg → 202610/x.jpg"),
    (.assetReused(AssetReusedEvent(url: "https://h/x.jpg", assetID: 1, newURL: "https://n/x")),
     "Reused x.jpg — already in the library"),
    (.uploadFailed(UploadFailedEvent(url: "https://h/x.jpg", error: "e", fatal: true, status: 403)),
     "Couldn’t upload x.jpg — the bucket refused it (403)"),
    (.uploadFailed(UploadFailedEvent(url: "https://h/x.jpg", error: "e", fatal: false, status: 500)),
     "Couldn’t upload x.jpg — the storage answered 500"),
    (.uploadFailed(UploadFailedEvent(url: "https://h/x.jpg", error: "timed out", fatal: false)),
     "Couldn’t upload x.jpg — timed out"),
    (.verifyFailed(VerifyFailedEvent(url: "https://h/x.jpg", newURL: "https://n/x", reason: "404")),
     "New link for x.jpg doesn’t load — not rewritten"),
    (.keyChanged(KeyChangedEvent(url: "https://h/x.jpg", plannedKey: "a", key: "b")), "Key for x.jpg changed to b"),
    (.migrationStopped(MigrationStoppedEvent(done: 2, total: 5)), "Stopped after 2 of 5 images"),
    (finished(), "Finished · 3 files, 1 ref to rewrite"),
    (finished(errors: 2, written: 1), "Finished · wrote 1 file · 2 errors"),
    (finished(
      migration: migration {
        $0.migratable = .init(images: 2, links: 2)
        $0.skipped = .init(images: 1, links: 1)
      }),
     "Ready · 2 images to upload, 0 reused, 1 skipped"),
    (finished(
      errors: 1, written: 3,
      migration: migration {
        $0.uploaded = .init(images: 4, links: 4)
        $0.reused = .init(images: 1, links: 1)
        $0.failed = .init(images: 1, links: 1)
        $0.skipped = .init(images: 2, links: 2)
      }),
     "Finished · uploaded 4, reused 1, 1 failed, 2 skipped · wrote 3 files · 1 error"),
    (finished(migration: migration { $0.uploaded = .init(); $0.stoppedAfter = 1 }), "Stopped after 1 image"),
  ]

  @Test("summaryLine joined from summaryParts is word for word the old sentence", arguments: 0..<cases.count)
  func lineIsUnchanged(_ index: Int) {
    let (event, line) = Self.cases[index]
    #expect(event.summaryLine == line)
    #expect(event.summaryParts.line == line)
  }

  @Test("the three layers: verb, object, detail")
  func layers() {
    let downloaded = Self.cases.first { $0.1 == "Downloaded x.jpg · 1.8 MB" }!.0.summaryParts
    #expect(downloaded.verb == "Downloaded")
    #expect(downloaded.object == "x.jpg")
    #expect(downloaded.detail == "1.8 MB")
    let clean = Self.cases.first { $0.1 == "blog/site is clean" }!.0.summaryParts
    #expect(clean.object == "blog/site")
    #expect(clean.objectFirst)
    let ready = Self.cases.first { $0.1.hasPrefix("Ready") }!.0.summaryParts
    #expect(ready.verb == "Ready")
    #expect(ready.object == nil)
  }

  @Test("the event JSON carries no summary parts")
  func jsonUnchanged() throws {
    let event = Self.cases[22].0
    let json = try event.dataJSON()
    #expect(!json.contains("verb"))
    #expect(try RunEvent(type: event.type, data: json) == event)
  }
}
