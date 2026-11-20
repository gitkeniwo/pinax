# Changelog

All notable changes to Pinax. Versions are published on the [Releases page](https://github.com/gitkeniwo/pinax/releases); versions up to 0.3.3 are on the [homebrew-pinax Releases page](https://github.com/gitkeniwo/homebrew-pinax/releases). The procedure is in [docs/RELEASING.md](docs/RELEASING.md).

Entries marked **Upgrade note** need action before or after upgrading.

## Unreleased

## 0.3.4 — 2026-11-20

### Changed
- Pinax is open source under the GLWT Public License, and releases are downloaded from this repository's Releases page.
- The app and the CLI are signed with a stable self-signed certificate, so Keychain keeps "Always Allow" for backend credentials across updates. Keychain asks once more on the first update to a signed version.

### Added
- Nightly builds of `main` as a rolling `nightly` prerelease.

## 0.3.3 — 2026-11-12

### Added
- Domain moves are now available in the app: Settings › Backends lists the current and old domains with their link counts, and offers Move to New Domain…, Move N Links to Current…, Add Old Domain, Switch Without Rewriting… and Remove for unused old domains. Checks run in the main window with progress, Continue in Background, a review sheet, Show Changes… and the shared activity panel.
- `pinax backend migrate-domain --from OLD` moves only the links on the named old domains to the current domain, without changing the prefix.
- `pinax backend old-domain ls` shows each old domain's link count, with `--format json`; `pinax backend show` reports the current domain's link count.
- Usage has a domain menu that filters Files and Images by current or old domain, with counts, an empty state and Move N Links to Current….
- The Storage sidebar groups the catalog by backend, and the Library tab has optional Projects and Time shortcut sections. Project rows open to their source folders and files, the Time tab opens the current year, and the Tags header has a `+`.
- The Table has an optional Domain column, and the Domain header sorts it.

### Changed
- Domain link counts now agree across Settings, Projects, Usage, the migration sheet and the confirmation sheet, including links to images that are not in the catalog.
- A domain belongs to one backend: registering, switching to or moving to a domain owned by another backend is refused.
- Links written with an uppercase scheme or host are now counted and rewritten; the path still matches exactly.
- Show Changes… uses a read-only text view, so large diffs appear immediately and can be selected, copied and scrolled horizontally.
- The activity log supports shift-click ranges, command-click, ⌘A and ⌘C, and run rows have Copy Log.
- After Switch Without Rewriting or Add Old Domain, Pinax scans the affected backend's projects.

### Fixed
- Grid thumbnails stay inside their cell when a late or retried image arrives, so images no longer draw over other cells and date rows.
- Sidebar section headers no longer show a system disclosure triangle on hover, and the `+` and shortcut arrows stay aligned.
- The Switch Without Rewriting sheet explains what it changes.

## 0.3.2 — 2026-10-31

**Upgrade note:** adds catalog migration `v5_run`. Back up the catalog before upgrading (Settings › Maintenance › Backup); older versions cannot restore a backup made after the upgrade.

### Added
- URL rewrite engine: `pinax rewrite` previews exact or prefix rules in a project's source files, checks the new URLs, shows a diff and records the run. `pinax rewrite --apply --from-run` writes only an unchanged preview.
- Rewrite and migration logs: `pinax runs` lists runs, and `pinax runs show` prints their events, changed files and raw JSONL log.
- `pinax backend migrate-domain` moves a backend to a new URL prefix across projects, keeps the old domains, and refuses unsafe or stale rewrites.
- Externals › Other Domains: bulk preview loading, multi-select previews, and Migrate to Bucket… with a confirmation sheet, progress and per-image results. Migrated images keep their source URL and are labelled Migrated.
- CLI: `pinax externals migrate` prepares an Other Domains migration, and `--apply --from-run` uploads and rewrites it.
- Activity slot in the status bar and the View › Show Activity Panel panel (⇧⌘Y), covering uploads, downloads, deletes, scans, imports, previews, rewrites and migrations, with events, raw logs, filters, changed files and Copy Log.
- Source filters now include all five sources, including Migrated and Other Imports, in both the find strip and the sort menu.

### Changed
- Other Domains previews load on demand or in bulk, with host totals, image bytes, pixel dimensions and type in the inspector, table and grid. The Group pop-up switches between domain and file grouping.
- The status bar now shows one activity slot with `+N` for concurrent work, instead of one status per operation.
- The activity panel remembers its height and run-list width per window, and its log rows support selection and copying.

### Fixed
- The centre column stays inside the window at its minimum width; the Externals scope bar and activity panel adapt, and Used In drops before Size.
- The migration sheet aligns its summary, host and image rows, old cached previews gain their size, and image-strip tiles stay square.
- The activity panel, activity slot and migration sheet use the project's teal instead of the system blue.
- The app loads `http://` preview images.

## 0.3.1 — 2026-10-29

**Upgrade note:** adds catalog migration `v4_project_key_template`. Back up the catalog before upgrading (Settings › Maintenance › Backup); older versions cannot restore a backup made after the upgrade.

### Added
- Per-project object key templates: parse, check, warn and store a template for each project. A new object key never overwrites an existing object, including one still pending deletion.
- CLI: `pinax project add/set --key-template`, `--reset-key-template`, and a key-template column in `pinax project ls`.
- Settings › Projects › Storage: key template editor with an Insert `{}` popover and a live example key.

### Changed
- Settings redesigned (GUI7): a sidebar window whose icons and selection match the main window; General, Gallery, Appearance, Drop Zone, Maintenance, Projects and Backends rebuilt on one set of grouped-form parts. The window's height and the sidebar's and list column's widths are draggable and remembered.

## 0.3.0 — 2026-10-26

### Changed
- New look (GUI6) in a gruvbox palette across the sidebar, grid, jump bar, month headers, inspector, Overview, Externals and Usage.
- Sidebar Catalog rows drawn as a tree with arc lines; chevrons removed.
- Overview: hero band, heat map, Uploads chart and grouped lists. An empty period's chart starts from 0 and draws no average line.
- Inspector: header with stat pills and bands, link icon buttons, a page-specific empty state.
- Externals and Usage: new row, scope bar and inspector layouts; Usage lists Files first, with a sortable folder list.

### Added
- Menu bar Library page: the storage bar splits by file type, project or backend.
- Menu bar panel: ⌘D opens the gallery, ⌘, opens Settings.

### Fixed
- A grid click lands on the cell under the pointer; a wide thumbnail no longer takes the next cell's clicks.
- The menu bar panel's first open no longer plays the card animation.

## 0.2.3 — 2026-10-22

### Added
- Menu bar panel home page: clipboard card, the eight most recent uploads, and a first-run view.
- Menu bar icon states: upload progress ring, a dot for an unseen failure, a ✓ after a copy.
- Menu bar statistics card that unrolls into a Library page, like a Control Center module.

### Fixed
- A batch in which every upload failed no longer copies old URLs again.
- Every upload failure shows the menu bar dot.

## 0.2.2 — 2026-10-21

**Upgrade note:** adds catalog migration `v3_pending_deletion`. Back up the catalog before upgrading (Settings › Catalog › Back Up); older versions cannot restore backups made by 0.2.2.

### Added
- Archived › Delete Permanently…: removes the asset and its bucket object. Deletion is staged; an unfinished deletion shows a banner and a ⚠ badge and can be resumed.
- Externals › Your Domains: Import into Catalog and Import All…; Settings › Backends › Unreferenced Objects imports bucket objects the catalog does not know. CLI: `pinax externals import`, `pinax import bucket`.
- Source tags: shown in the grid caption, a Table column, the Inspector and the ⌘F filter, and printed by `pinax show`. View › Show Source Tags toggles them.
- Externals: info button, first-visit card, sort, Group by File.
- Settings › Appearance › Menu Bar Icon: seven icons.

### Changed
- App Icon list trimmed to seven; Ivory Glyph is the default everywhere.
- Archiving or putting back hands the selection to the next image without a jump; Edit and View menu items enable and disable as the selection changes.

### Fixed
- Resizing the window or opening and closing the sidebar and inspector keeps the top row in place.
- The usage scanner reads a `<…>` URL up to its closing bracket, spaces included.

## 0.2.1 — 2026-10-10

### Fixed
- Changing the grid's column count below the top keeps the anchored image in place and moves the scroller one way, instead of jumping away and back during the fade. Scrolling during the change ends it at once; a click before the new grid shows does nothing.

## 0.2.0 — 2026-10-09

### Added
- Projects: one current project (Project menu, title-area picker, Choose Project… ⌃0); project sources and Scan Now. CLI: `pinax project source ls|add|rm`, `pinax usage scan`.
- Reports › Overview, the default report: heat map, Uploads chart, metric cards, tags, By Kind / By Backend, Usage by Project.
- Usage per current project, with Images, Files, Open File, Reveal, Copy New URL and Show in Library.
- Externals split into Your Domains and Other Domains, grouped by domain in Grid and List views. Old domains can be registered (`pinax backend old-domain`, Settings › Backends › Old Domains).
- Orphans: an untracked set and a "Not yet scanned" group.
- Catalog backup and restore: Settings › Maintenance › Backup, File › Import / Export Catalog Backup…, `pinax restore FILE`. Restoring into a non-empty catalog asks twice and offers to save the current catalog first.
- Drag images out of the grid and table as text in the default copy format.
- Double-click opens Quick Look; Add Tag… and Edit Note… open popovers; table rows have the grid's context menu.
- Drop zone: translucent glass, Shelf grid layout, Look settings, an upload ring on each thumbnail, a resizable panel that remembers its size, Settings › Drop Zone › Upload into and Size.
- Settings › Appearance › App Icon: selectable Dock icons that can follow the system appearance.

### Changed
- Inspector redesigned as one flat column of sections, always docked, on sidebar material.
- Settings pages rebuilt as grouped forms.
- Every empty state uses the system's standard empty-state view.
- Grid cells are square in both modes; the original-aspect mode crops like Photos.

### Fixed
- An untouched Edit Note draft is no longer saved over a mixed selection's notes; Esc that closes the popover does not save.
- Usage and Externals no longer show the library's selection.

## 0.1.0 — 2026-09-27

First public release.

### Added
- Command-line catalog `pinax`: backends and projects, signed S3 upload with deduplication, list / url / show, notes, usage scans, backend domain migration, PicGo gallery import, doctor and recovery.
- macOS app:
  - gallery with Time, Collections, Catalog (key-prefix tree) and Reports navigators;
  - grid and table views with month groups, a jump bar and an in-content find strip;
  - continuous zoom, sorting and selection;
  - tags, notes, project membership, Favorites, color labels and Archive;
  - Copy As and custom copy formats, Download Original;
  - Quick Look with paging.
- Drop zone panel: stays after a drop, pin and ×, Auto Hide durations, icon buttons, hover preview, upload progress in the status bar. Show Drop Zone in the menu bar.
- Settings: General, Drop Zone, Projects, Backends.
- Homebrew distribution: `brew install --cask gitkeniwo/pinax/pinax` and `brew install gitkeniwo/pinax/pinax`.
