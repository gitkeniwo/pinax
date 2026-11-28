# `pinax` CLI reference

Checked against `pinax --help` of the current `main`. Every command takes `-h, --help`; `pinax --version` prints the version.

- **ID**: an exact object key, or a SHA-256 prefix of at least 6 characters. `ID...` takes several; nothing is written unless all resolve.
- **Catalog**: `~/Library/Application Support/tech.gitkeniwo.pinax/catalog.sqlite`, or `PINAX_DB`.
- **Credentials**: Keychain, or `PINAX_ACCESS_KEY_ID` and `PINAX_SECRET_ACCESS_KEY`. Never arguments.

## Output

`--format table` is the default. `--format json` prints one document on stdout; notes and warnings go to stderr.

| `schema` | Command |
|---|---|
| `pinax.asset.v1` | `show` |
| `pinax.curation.v1` | `archive`, `unarchive`, `favorite add\|rm`, `label add\|rm`, `project link\|unlink\|move` |
| `pinax.delete.v1` | `delete` |
| `pinax.pending-deletions.v1` | `delete --pending` |
| `pinax.used-in.v1` | `used-in` |
| `pinax.orphans.v1` | `orphans` |
| `pinax.externals.v1` | `externals list` |
| `pinax.stats.v1` | `stats` |
| `pinax.tags.v1` | `tag ls` |
| `pinax.labels.v1` | `label ls` |
| `pinax.project.v1` | `project show` |
| `pinax.projects.v1` | `project ls` |
| `pinax.backend.v1` | `backend show` |
| `pinax.backends.v1` | `backend ls` |
| `pinax.old-domains.v1` | `backend old-domain ls` |
| `pinax.note.v1` | `note show` |
| `pinax.object.v1` | `object head` |
| `pinax.optimize.v1` | `optimize` |
| `pinax.restore.v1` | `restore` |
| `pinax.rewrite.v1` | `rewrite`, `backend migrate-domain` |
| `pinax.externals.migrate.v1` | `externals migrate` |
| `pinax.runs.v1` | `runs ls` |
| `1` | `ls`, `upload`, `usage report`, `usage scan --dry-run`, `export`, `backup`, `rewrite-map`, `doctor`, `reindex`, `import bucket`, `import picgo-gallery`, `externals import` — see [FORMATS.md](FORMATS.md) |

Keys are snake_case; a missing value is `null`. `project source ls --format json` prints a bare array. `runs show` takes `--format jsonl`.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Other failure |
| 64 | Bad argument (usage is printed) |
| 66 | Not found: asset, backend, project, source, file or run |
| 69 | Object store or public URL failed |
| 77 | Refused by a safeguard |
| 78 | Credentials missing |

## Assets

| Command | Does | Flags |
|---|---|---|
| `upload [FILE...]` | Upload and catalog images | `--project` `--backend` `--format url\|markdown\|html\|json` `--template` `--copy` `--clipboard` `--dry-run` `--force` `--compress/--no-compress` |
| `ls` | List assets | see below |
| `show ID` | Full record, tags, per-project live usage | `--format` |
| `url ID...` | One link per asset | `--format url\|markdown\|html` `--template` |
| `get ID... -o DIR` | Download originals, SHA-256 checked; never overwrites | |
| `note set ID TEXT` · `note show ID` · `note clear ID` | Asset note | `show --format` |
| `tag add ID TAG` · `tag rm ID TAG` · `tag ls` | Tags; `ls` counts active assets | `ls --format` |
| `label add COLOR ID...` · `label rm COLOR ID...` · `label ls` | Color labels: `red orange yellow green blue purple gray` | `--dry-run` `--format` |
| `favorite add ID...` · `favorite rm ID...` | Favorites | `--dry-run` `--format` |
| `archive ID...` · `unarchive ID...` | Catalog state only; objects stay | `--dry-run` `--format` |
| `delete ID...` | Delete archived assets for good | see [Delete](#delete) |
| `export --project P` | Project manifest ([schema](../Schemas/pinax-manifest-v1.schema.json)) | `-o FILE` |

`--template` placeholders: `{url} {filename} {name} {width} {height} {key} {project}`. It cannot be combined with `--format`.

### `ls`

| Flag | Values |
|---|---|
| `--project` `--tag` `--backend` | slug / tag |
| `--state` | `active` (default), `archived`, `all` |
| `--since` `--until` | `YYYY-MM`, `YYYY-MM-DD`, ISO-8601 |
| `--search TEXT` | with `--search-field any\|filename\|key\|note`, `--match contains\|begins\|ends\|matches`, `--case-sensitive` |
| `--key-prefix` | e.g. `blog/2026` |
| `--favorites` | |
| `--label` | a color |
| `--source` | `pinax`, `picgo`, `bucket`, `other_import`, `migrated`; repeatable |
| `--sort` | `uploaded` (default), `name`, `size`, `kind`; `--asc` / `--desc` (default) |
| `--limit` | default 50 |
| `--after CURSOR` | next page |
| `--format` | `table`, `json`, `url` |

Paging: JSON is `{"schema": 1, "assets": [...], "next": CURSOR}`. Pass `next` to `--after` with the same sort until `next` is `null`. A cursor from another sort exits 64.

```sh
pinax ls --project blog --label red --sort size --format json
pinax ls --search hero --match begins --search-field filename --format url
```

### Delete

| Form | Effect | Exit |
|---|---|---|
| `delete ID...` | Print the plan only | 77 |
| `delete ID... --dry-run` | Print the plan only | 0 |
| `delete ID... --confirm` | Delete catalog rows and objects | 0 |
| `delete ID... --confirm --include-used` | Also assets that scanned sources reference | 0 |
| `delete --pending` | List unfinished deletes | 0 |
| `delete --resume [--backend B]` | Retry them | 0 |

Refused (77) unless every asset is archived, at most 100 per call, and unused (or `--include-used`). Each object is deleted only if its `x-amz-meta-sha256` matches the catalog. An imported asset's object stays (`deletes_remote: false`); only its row goes.

`pinax.delete.v1`: `plan[]` (`sha256 key backend bytes deletes_remote live_usage`), `results[]` (`key outcome error`). `outcome`: `deleted`, `already_gone`, `superseded`, `refused_mismatch`, `failed`, `removed_from_catalog`.

## Projects and backends

| Command | Does | Flags |
|---|---|---|
| `project add` | New project | `--slug` `--name` `--key-prefix` `--backend` `--key-template` |
| `project ls` · `project show SLUG` | Read | `--format` |
| `project set --slug S` | Change settings | `--name` `--key-prefix` `--backend` `--no-backend` `--usage-tracking tracked\|not-tracked` `--key-template` `--reset-key-template` `--compress/--no-compress` `--longest-edge` `--quality high\|medium\|small` `--remove-metadata/--keep-metadata` `--watch on\|off` `--schedule off\|hourly\|daily` |
| `project source ls SLUG` | Usage-scan sources | `--format` |
| `project source add SLUG [PATH]` | Folder or command source | `--command` `--in` `--label` `--include` `--exclude` |
| `project source set SLUG LABEL` | Change one source | `--path` `--include` `--exclude` `--clear-include` `--clear-exclude` `--command` `--in` |
| `project source rm SLUG LABEL` | Remove a source | |
| `project link P ID...` | Add assets to a project | `--dry-run` `--format` |
| `project unlink P ID...` | Remove assets from a project | `--confirm` (needed if still referenced, else 77) `--dry-run` `--format` |
| `project move ID... --from P --to Q` | Move between projects | `--confirm` `--dry-run` `--format` |
| `backend add` | New backend | `--slug` `--endpoint` `--bucket` `--url-prefix` `--region` (default `auto`) `--no-credentials` |
| `backend ls` · `backend show SLUG` | Read; credentials redacted | `--format` |
| `backend set-credentials --slug S` | Store credentials (prompted) | |
| `backend set-prefix SLUG URL` | Change the URL prefix; old one is kept | |
| `backend old-domain ls\|add\|rm B [PREFIX]` | Old URL prefixes | `ls --format` |
| `backend migrate-domain` | Preview, then `--apply --from-run ID` | `--backend` `--to` `--from` `--project` `--keep-old-domains` `--diff` `--allow-source` `--format` |
| `backend import-picgo` | Import PicGo's S3 settings | `--path` `--no-credentials` |

## Usage scans and reports

| Command | Does | Flags |
|---|---|---|
| `usage scan --project P` | Scan sources and ingest | `--dry-run` `--run-commands` `--allow-empty` |
| `usage sync --project P` | Ingest a usage document ([format](FORMATS.md#usage-scan)) | `-f FILE` `--allow-empty` |
| `usage report --project P` | Live references | `--old-domains` `--source REF` `--format` |
| `used-in ID` | References to one asset | `--project` `--format` |
| `orphans` | Active, unpinned, unused, non-favorite assets | `--project` `--min-scans` (default 2) `--format` |
| `externals list` | URLs that match no asset | `--project` `--domain yours\|other` `--format` |
| `externals import [URL...]` | Claim your-domain URLs into the catalog | `--project` `--all` `--dry-run` `--format` |
| `externals migrate` | Copy other-domain images to your bucket; preview, then `--apply --from-run ID` | `--project` `--host` `--url` `--backend` `--allow-source` `--compress/--no-compress` `--format` |
| `stats` | Totals and uploads by day (local time; `TZ`) | `--project` `--format` |

## Rewrites

| Command | Does | Flags |
|---|---|---|
| `rewrite --project P` | Preview URL rewrites in sources; `--apply --from-run ID` writes it | `--map FILE` `--from-prefix` `--to-prefix` `--verify` `--diff` `--allow-source` `--run-commands` `--format` |
| `rewrite-map --backend B` | Current and retired prefixes as JSON | |
| `runs ls` · `runs show ID` | Run history and logs | `ls --limit` (default 20) `--format`; `show --format table\|jsonl` |

## Objects and maintenance

| Command | Does | Flags |
|---|---|---|
| `object head --backend B KEY` | Object headers | `--format` |
| `object get --backend B KEY -o FILE` | Save object bytes; never overwrites | |
| `optimize --backend B --dry-run` | Measure JPEG recompression savings; changes nothing | `--prefix` `--name` `--sample` `--longest-edge` `--quality` `--keep-metadata` `--seed` `--format` |
| `init` · `migrate` | Create / migrate the database | |
| `doctor` | Integrity and location checks | `--format` |
| `backup` | Whole database as JSON | `-o FILE` |
| `restore FILE` | Into an empty catalog | `--format` |
| `reindex --backend B` | Rebuild asset rows from object metadata | `--dry-run` |
| `import picgo-gallery --backend B` | Import PicGo's gallery | `--path` `--dry-run` `--backfill-object-metadata` `--yes` `--allow-acl-reset` |
| `import bucket --backend B` | Claim unknown, unused bucket objects | `--dry-run` `--format` |
