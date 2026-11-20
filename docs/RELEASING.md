# Releasing Pinax

Releases and nightly builds are built and published by GitHub Actions in this repository.

## Where things live

| What | Where |
|---|---|
| Source, CI, release assets | `gitkeniwo/pinax` |
| Cask and formula | `Casks/pinax.rb` and `Formula/pinax.rb` in `gitkeniwo/homebrew-pinax` |
| Templates for the cask, formula and tap README | `Packaging/homebrew-pinax/` |
| Workflows | `.github/workflows/ci.yml` (tests, PR app build, nightly), `.github/workflows/release.yml` |
| Build scripts | `Scripts/build-dist.sh`, `Scripts/render-tap.sh`, `Scripts/release-notes.sh` |

Users install the app with `brew install --cask gitkeniwo/pinax/pinax` and the CLI with `brew install gitkeniwo/pinax/pinax`.

## Workflows

- **CI** runs the core and CLI tests on every pull request and every push to `main`. The UI tests run serially in a separate `ui-tests` job that never blocks, since their timing waits are not reliable on hosted runners. Pull requests also build the app unsigned.
- **Nightly**: after the tests pass on `main`, CI builds the app and CLI, moves the `nightly` tag to that commit, and replaces the assets of the `nightly` prerelease (`Pinax-nightly.zip`, `pinax-cli-nightly.zip`, `SHA256SUMS`).
- **Release**: pushing a `vX.Y.Z` tag checks the version and changelog, runs the core and CLI tests, builds and signs both products, creates the GitHub release with the changelog section as notes, then renders the cask and formula and pushes them to the tap.

Both builds are universal (arm64 and x86_64) and use the dependency versions in `Package.resolved`.

## Secrets

Set in `gitkeniwo/pinax` › Settings › Secrets and variables › Actions:

| Secret | Used by | Contents |
|---|---|---|
| `SIGNING_CERT_P12` | nightly, release | base64 of the `.p12` made by `Scripts/make-signing-cert.sh` |
| `SIGNING_CERT_PASSWORD` | nightly, release | its password |
| `TAP_DEPLOY_KEY` | release | private half of an SSH deploy key with write access to `gitkeniwo/homebrew-pinax` |

Without the signing secrets the builds are ad-hoc signed. Every build then has a new signature and Keychain asks again for backend credentials after each update. Keep a copy of the `.p12` and its password somewhere safe: a new certificate also makes Keychain ask again.

The release job runs in the `release` environment, so a required reviewer can be added there to approve each release.

## Procedure

1. **Bump the version** in one commit on `main`:
   - set `PinaxVersion.current` in `Sources/CatalogCore/CatalogCore.swift`, which is what `pinax --version` prints;
   - in `CHANGELOG.md`, turn the Unreleased entries into a `## <version> — <YYYY-MM-DD>` section (see "Changelog" below).
2. **Run the UI and focus tests locally**, since the release job runs only the core and CLI tests:

   ```bash
   swift test --skip FocusSerial
   ```
   ```bash
   swift test --no-parallel --filter FocusSerial
   ```

3. **Tag and push:**

   ```bash
   git tag v<version> && git push origin v<version>
   ```

4. **Verify:** the release has both zips and `SHA256SUMS`; the tap's `Casks/pinax.rb` names the new version; then on a real machine:

   ```bash
   brew upgrade --cask gitkeniwo/pinax/pinax && brew upgrade gitkeniwo/pinax/pinax
   ```

   The app is not notarized, so the first launch of each new version is blocked; open it with "Open Anyway" in System Settings › Privacy & Security. `pinax --version` prints the new version.

If the release job fails before creating the release, fix the problem, delete the tag (`git push --delete origin v<version>` and `git tag -d v<version>`), and tag again.

To ship a subset of `main`, create a `release/<version>` branch, cherry-pick onto it, bump there, and tag that branch's tip. Afterwards bring the version bump and changelog section back to `main`.

## Local dry run

```bash
Scripts/release-notes.sh <version>
Scripts/build-dist.sh <version> <version> .build/dist
Scripts/render-tap.sh <version> .build/dist
```

This builds, ad-hoc signs, zips and renders the tap without publishing anything. Set `PINAX_SIGN_IDENTITY` to sign with a certificate from your keychain.

## Changelog

`CHANGELOG.md` lists the changes users can notice, newest version first.

- **Format.** The top section is `## Unreleased`. Each release is a `## <version> — <YYYY-MM-DD>` section with `### Added`, `### Changed`, `### Fixed` and `### Removed` subsections, using only the ones that have entries.
- **Content.** Entries describe what a user sees or does, in plain words, without commit hashes. Test-only, docs-only and refactor-only changes get no entry.
- **Upgrade notes.** A release that adds a catalog migration starts its section with an **Upgrade note** that names the migration, asks for a backup first, and says that older versions cannot restore backups made after the upgrade. Find the migrations with `git grep registerMigration`.

## Rules

- Never edit a committed migration, the bundle id, or signing settings as part of a release.
- The release never removes quarantine; the cask caveats explain how to open the app.
