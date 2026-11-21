<p align="center">
  <img src="Design/AppIcon/pinax.svg" width="256" alt="Pinax app icon">
</p>

# Pinax

Pinax is a native macOS app and CLI for managing a local-first image catalog. It tracks assets, tags, and live project references while uploading directly to your own S3-compatible object storage, keeping your image history independent of any uploader GUI.

<img width="1250" height="775" alt="image" src="https://github.com/user-attachments/assets/4602fbfb-ffc0-4097-8187-f04e9ac00d65" />


## Install

Install the app and the command-line tool with Homebrew:

```sh
brew install --cask gitkeniwo/pinax/pinax
brew install gitkeniwo/pinax/pinax
```

Pinax requires macOS 14 or later.

Pinax is not notarized, because it has no Apple Developer ID. macOS blocks the first open of every new version:

1. Open Pinax once and dismiss the warning.
2. Open System Settings › Privacy & Security.
3. Click "Open Anyway" next to the Pinax message, then confirm.

Releases and nightly builds are signed with the same self-signed certificate, so after you click "Always Allow" once when Pinax first reads a backend credential, Keychain keeps that answer across updates.

### Nightly builds

Every commit to `main` that passes CI updates the [`nightly` prerelease](https://github.com/gitkeniwo/pinax/releases/tag/nightly) with fresh `Pinax-nightly.zip` and `pinax-cli-nightly.zip`. Nightly builds are not tested beyond CI.

### Build from source

Build the command-line tool:

```sh
swift build -c release --product pinax
cp .build/release/pinax /usr/local/bin/
```

Build the app with Xcode, or from the command line:

```sh
xcodebuild -project PinaxApp/PinaxApp.xcodeproj -scheme PinaxApp -configuration Release \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - .build/xcode/Build/Products/Release/PinaxApp.app
```

To build and run from Xcode with automatic signing, put your team in `PinaxApp/Local.xcconfig` (gitignored): `DEVELOPMENT_TEAM = <your team ID>`.

Run the tests with `swift test --skip FocusSerial`. The `FocusSerial` tests need a focused window; run them on their own with `swift test --no-parallel --filter FocusSerial`.

Releases are built and published by CI; see [docs/RELEASING.md](docs/RELEASING.md).

## Safety rules

Changes to Pinax must keep these rules:

1. Pinax deletes an object from the object store only in `CatalogDeletion`, and only when every one of these holds: the user confirmed this deletion of these named assets (the GUI dialog, or `pinax delete --confirm`); each asset is archived; the key is exactly one catalog row's key — never empty, a prefix, a pattern or a bucket — and no other backend names the same bucket and key; a HEAD just before shows `x-amz-meta-sha256` equal to the row's sha256. One object per request, at most 100 per confirmation. Never use DeleteObjects, DeleteBucket, list-driven deletion or lifecycle rules, and never delete on a timer or without a confirmed request.
2. Never store thumbnails or image bytes in SQLite.
3. Never edit a committed migration; add a new migration instead.
4. Never place the database on iCloud Drive, Dropbox, or another network filesystem. `pinax doctor` must detect and warn about these locations.
5. `CatalogCore` must not import `ArgumentParser`.
6. Credentials must only be stored in Keychain. They must never be stored in the database or another file.

## Dependencies

The package resolves GRDB 7.11.1 and Swift Argument Parser 1.8.2 in `Package.resolved`.

## Configure a backend

Create the database:

```sh
pinax init
```

Set the credentials in the environment for a noninteractive shell:

```sh
export PINAX_ACCESS_KEY_ID='...'
export PINAX_SECRET_ACCESS_KEY='...'
```

Add the backend:

```sh
pinax backend add \
  --slug r2 \
  --endpoint https://ACCOUNT.r2.cloudflarestorage.com \
  --bucket images \
  --url-prefix https://img.example.com \
  --region auto
```

Pinax prompts for both credentials without terminal echo when the environment variables are absent. Pinax never accepts credentials as command arguments.

Use these commands to read the configuration:

```sh
pinax backend ls
pinax backend show r2
```

`backend show` redacts the credentials. Use `pinax backend import-picgo` to import the `picBed.aws-s3` storage fields from PicGo.

Configure a project:

```sh
pinax project add --slug blog --name Blog --key-prefix blog --backend r2
pinax project ls
pinax project set --slug blog --name 'Main Blog'
```

## Upload images

Upload one or more image files:

```sh
pinax upload image.png other.jpg --project blog
```

Use `--format markdown`, `--format html`, or `--format json` to change the output.
Use `--copy` to copy that output to the pasteboard.
Use `--clipboard` without paths to read PNG, TIFF, or image file URLs from the pasteboard.

Use `--dry-run` to inspect an upload without network or database writes.
When `--dry-run` has no explicit format, it prints the planned key and dedupe status.
When it has `--format`, Pinax honors that format. JSON output always has this shape:

```json
{"schema": 1, "assets": []}
```

The `assets` field is always an array, even for one file. Upload and list JSON use the same
public asset fields and never expose database ids or Keychain references.
Use `--force` to upload a known asset again under its existing object key.
Pinax processes at most four files concurrently and prints results in argument order.

If an upload deduplicates across projects, it keeps the object key from the first upload.
Project key prefixes select the first upload path. They do not define asset ownership.

## Read catalog assets

List assets and apply optional filters:

```sh
pinax ls --project blog --state active --since 2026-01 --limit 50
pinax ls --tag hero --format json
```

Resolve an asset by its exact key or an unambiguous SHA-256 prefix of at least six characters:

```sh
pinax url 431ced
pinax show 431ced
```

`pinax show` includes the full asset record, tags, and each associated project's live usage count.

Export a versioned manifest. The schema is `Schemas/pinax-manifest-v1.schema.json`.

```sh
pinax export --project blog
pinax export --project blog -o images.json
```

Add or remove a tag. Use an exact key or a SHA-256 prefix.

```sh
pinax tag add 431ced hero
pinax tag rm 431ced hero
```

## Import usage scans

The input document format is described in [docs/FORMATS.md](docs/FORMATS.md#usage-scan).
Read the document from standard input or from a file.

```sh
pinax usage sync --project blog < refs.json
pinax usage sync --project blog -f refs.json
```

Each import uses one database transaction. An import failure does not change the current scan.

Pinax rejects an empty scan after a nonempty scan. Use `--allow-empty` only when the empty
result is intentional.

Show the live references from the latest completed scan:

```sh
pinax usage report --project blog
pinax usage report --project blog --format json
pinax externals --project blog
```

List active, unpinned assets that have no live references:

```sh
pinax orphans --project blog --min-scans 2
```

Pinax always prints a lower-bound warning before orphan rows. A project filter ignores usage
from other projects. Pinax also lists projects that have fewer than `--min-scans` completed scans.

## Migrate a backend domain

Change a backend's public URL prefix without losing the old domain:

```sh
pinax backend set-prefix r2 https://new-images.example.com
pinax rewrite-map --backend r2
```

`set-prefix` stores the previous prefix in `backend_prefix_history`. Usage scans resolve both
the current prefix and all retired prefixes. The rewrite map is versioned JSON for consumers
that need to replace stale URLs.

## Check and recover the catalog

Run all local safety checks:

```sh
pinax doctor
```

Doctor runs SQLite `integrity_check` and reports the WAL mode. It lists unscanned projects
and missing Keychain items. Doctor refuses a database on a network filesystem or in a known
synced-storage directory. Other commands refuse to create one there. They open an existing
database with a warning.

Export every database table as schema-versioned JSON:

```sh
pinax backup
pinax backup -o dump.json
```

The backup contains database IDs and Keychain references because it is a complete database
snapshot. It never contains access keys or secret keys.

Rebuild asset rows from `ListObjectsV2` and each object's `HEAD` metadata:

```sh
pinax reindex --backend r2 --dry-run
pinax reindex --backend r2
```

Reindex never downloads object bodies. It reports objects that lack Pinax's immutable
`sha256`, `orig-filename`, `width`, or `height` metadata.

Reindex restores image asset rows only. It cannot restore projects, tags, project membership,
or usage history. Only `pinax backup` captures those catalog relationships. Doctor warns if
the database contains assets but no projects.

If the SQLite file is lost, the credentials remain in Keychain. Use one of these methods to
recover the backend configuration:

1. Add the backend again.
2. Set `PINAX_S3_ENDPOINT`, `PINAX_S3_BUCKET`, and `PINAX_S3_URL_PREFIX`.

`PINAX_S3_REGION` is optional. Then run:

```sh
pinax init && pinax reindex --backend r2
```

Pinax recreates the backend and all recoverable asset rows. You can use
`PINAX_ACCESS_KEY_ID` and `PINAX_SECRET_ACCESS_KEY` as temporary credential values. Pinax
never writes these values to the database.

## S3 integration test

The default test suite uses local HTTP mocks. Set these variables only to run the real-bucket test:

```sh
PINAX_INTEGRATION=1
PINAX_S3_ENDPOINT=https://ACCOUNT.r2.cloudflarestorage.com
PINAX_S3_BUCKET=images
PINAX_S3_URL_PREFIX=https://img.example.com
PINAX_S3_REGION=auto
PINAX_ACCESS_KEY_ID=...
PINAX_SECRET_ACCESS_KEY=...
```

Then run `swift test`. The live test uploads one permanent 1×1 PNG under `pinax-test/` and never deletes it.

## License

Pinax is released under the [GLWT (Good Luck With That) Public License](LICENSE).
