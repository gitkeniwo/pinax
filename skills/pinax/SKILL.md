---
name: pinax
description: Drive the `pinax` CLI to find, upload, curate and delete images in a Pinax catalog (macOS, S3-compatible storage). Use when the user asks to list or search their images, get image URLs or Markdown links, upload screenshots, tag/label/archive images, check which pages use an image, or clean up unused images.
---

# pinax

`pinax` manages a local image catalog (SQLite) whose objects live in the user's own S3-compatible bucket. Full flags: `pinax <command> --help`. Reference: [docs/CLI.md](../../docs/CLI.md).

## Rules

1. Read with `--format json`. Parse stdout; it holds the JSON document only. Warnings and errors go to stderr.
2. Name assets by exact key or by a SHA-256 prefix of at least 6 characters. Use the full `sha256` from JSON when you have it.
3. Preview every write with `--dry-run` first when the command has it, and show the user what it will change.
4. Never run `pinax delete --confirm` unless the user named those assets and said to delete them for good, in this conversation. It cannot be undone.
5. Never pass credentials as arguments. Pinax reads them from Keychain or `PINAX_ACCESS_KEY_ID` / `PINAX_SECRET_ACCESS_KEY`.
6. Check the exit code, not the wording of messages.

## Which command

| Task | Command |
|---|---|
| Find assets | `pinax ls` (filters below) |
| One asset in full (projects, live usage) | `pinax show ID --format json` |
| Links | `pinax url ID...` · `--format markdown\|html` · `--template '![{name}]({url})'` |
| Upload | `pinax upload FILE... --project P --format json` (`--dry-run` first) |
| Download originals | `pinax get ID... -o DIR` |
| Where an asset is used | `pinax used-in ID --format json` |
| Unused assets | `pinax orphans --project P --format json` |
| Totals | `pinax stats --format json` |
| Tags | `pinax tag add\|rm ID TAG` · `pinax tag ls` |
| Color labels | `pinax label add\|rm COLOR ID...` · `pinax label ls` |
| Favorites | `pinax favorite add\|rm ID...` |
| Archive / restore | `pinax archive ID...` · `pinax unarchive ID...` |
| Projects | `pinax project ls\|show\|link\|unlink\|move` |
| Delete for good | `pinax delete ID...` (see Delete) |
| Health check | `pinax doctor --format json` |

`ls` filters: `--project` `--tag` `--state active|archived|all` (default `active`) `--since` `--until` (`YYYY-MM`, `YYYY-MM-DD` or ISO-8601) `--search TEXT` `--search-field any|filename|key|note` `--match contains|begins|ends|matches` `--case-sensitive` `--key-prefix` `--backend` `--favorites` `--label COLOR` `--source` `--sort uploaded|name|size|kind` `--asc|--desc` `--limit` (default 50).

Colors: `red orange yellow green blue purple gray`.

## JSON

Every document has a `schema` key. Keys are snake_case; a missing value is `null`, never an absent key.

| Schema | Printed by `--format json` of |
|---|---|
| `pinax.asset.v1` | `show` |
| `pinax.curation.v1` | `archive`, `unarchive`, `favorite add\|rm`, `label add\|rm`, `project link\|unlink\|move` |
| `pinax.delete.v1` | `delete` |
| `pinax.pending-deletions.v1` | `delete --pending` |
| `pinax.used-in.v1` | `used-in` |
| `pinax.orphans.v1` | `orphans` |
| `pinax.externals.v1` | `externals list` |
| `pinax.stats.v1` | `stats` |
| `pinax.tags.v1` / `pinax.labels.v1` | `tag ls` / `label ls` |
| `pinax.project.v1` / `pinax.projects.v1` | `project show` / `project ls` |
| `pinax.backend.v1` / `pinax.backends.v1` | `backend show` / `backend ls` |
| `pinax.note.v1` | `note show` |
| `pinax.object.v1` | `object head` |
| `pinax.old-domains.v1` | `backend old-domain ls` |
| `pinax.optimize.v1` | `optimize` |
| `pinax.restore.v1` | `restore` |
| `pinax.rewrite.v1` | `rewrite`, `backend migrate-domain` |
| `pinax.externals.migrate.v1` | `externals migrate` |
| `pinax.runs.v1` | `runs ls` |

`ls`, `upload`, `usage report` and `doctor` print the older `"schema": 1` documents of [docs/FORMATS.md](../../docs/FORMATS.md).

`ls` / `upload` asset keys: `sha256 key url width height bytes mime filename uploaded_at`; `ls` adds `backend state favorite labels tags source note`.

## Paging `ls`

`ls --format json` returns `{"schema": 1, "assets": [...], "next": CURSOR|null}`. Repeat the same command with `--after CURSOR` until `next` is `null`. Keep `--sort` and `--asc/--desc` unchanged; a cursor from another sort order exits 64.

```sh
pinax ls --project blog --limit 100 --format json            # page 1
pinax ls --project blog --limit 100 --format json --after "$NEXT"
```

## Delete

`pinax delete` removes the catalog row and the bucket object.

| Form | Effect | Exit |
|---|---|---|
| `delete ID...` | Prints the plan, deletes nothing | 77 |
| `delete ID... --dry-run` | Prints the plan | 0 |
| `delete ID... --confirm` | Deletes; prints `plan` and `results` | 0, or the failure's code |
| `delete --pending` | Lists deletes the bucket did not finish | 0 |
| `delete --resume [--backend B]` | Retries them | 0, or the failure's code |

Limits (each refuses the whole batch, exit 77):
- every asset must be archived first (`pinax archive`);
- at most 100 assets per call;
- assets that scanned sources still reference need `--include-used`; check `live_usage` in the plan and ask the user first;
- the object's `x-amz-meta-sha256` must match the catalog, or that one object is left (`refused_mismatch`).

An imported asset (`deletes_remote: false` in the plan) loses only its catalog row; its object stays.
Result `outcome`: `deleted`, `already_gone`, `superseded`, `refused_mismatch`, `failed`, `removed_from_catalog`.

Other guarded writes: `project unlink` and `project move` refuse (77) assets the project's latest scan still references, unless `--confirm`.

## Exit codes

| Code | Meaning | Do |
|---|---|---|
| 0 | Success | |
| 1 | Other failure (e.g. an ambiguous SHA-256 prefix) | Read stderr |
| 64 | Bad argument | Fix the command line |
| 66 | Not found (asset, project, backend, source, run) | Check the identifier |
| 69 | Object store or public URL failed | Retry later |
| 77 | Refused by a safeguard | Read stderr; ask the user before overriding |
| 78 | Credentials missing | Ask the user to run `pinax backend set-credentials --slug B` |

## Examples

Markdown links for this month's hero images:

```sh
pinax ls --tag hero --since 2026-11 --template '![{name}]({url})'
```

Upload a screenshot to a project and keep its URL:

```sh
pinax upload shot.png --project blog --dry-run --format json
pinax upload shot.png --project blog --format json | jq -r '.assets[0].url'
```

Archive what nothing uses, after review:

```sh
pinax orphans --project blog --format json | jq -r '.assets[].sha256'
pinax archive SHA1 SHA2 --dry-run --format json
pinax archive SHA1 SHA2
```

Delete archived assets the user named:

```sh
pinax delete SHA1 SHA2 --dry-run --format json   # show the plan to the user
pinax delete SHA1 SHA2 --confirm --format json   # only after their yes
```
