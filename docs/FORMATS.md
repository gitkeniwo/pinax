# Data formats

The JSON documents other tools exchange with Pinax. Each carries `"schema": 1`. A breaking change bumps the number, and the previous reader stays for at least one release.

## Manifest export

`pinax export --project blog` (JSON Schema: `Schemas/pinax-manifest-v1.schema.json`):

```json
{
  "schema": 1,
  "generated_at": "2026-08-19T10:00:00Z",
  "project": "blog",
  "backend": { "slug": "r2", "url_prefix": "https://img.example.com" },
  "assets": [
    {
      "sha256": "f58e6db5…",
      "key": "blog/202511/dashboard-a1b2c3d4e5f6.png",
      "url": "https://img.example.com/blog/202511/dashboard-a1b2c3d4e5f6.png",
      "width": 990,
      "height": 720,
      "bytes": 148213,
      "mime": "image/png",
      "filename": "20251112233829358.png",
      "uploaded_at": "2025-11-12T23:38:29Z"
    }
  ]
}
```

The manifest contains active assets only. The top-level `backend` is the project's current backend; each asset's `url` uses the backend that owns that asset. `sha256` is the stable public identifier.

`pinax upload --format json` and `pinax ls --format json` use the same asset fields, always inside `{"schema": 1, "assets": [...]}`, even for one asset. Upload output can add `deduplicated` and `dry_run` to each asset. None of these documents contain database ids, backend records or Keychain references.

## Usage scan

`pinax usage sync --project blog < refs.json` imports the image references a scanner found in a site's sources. The scanner lives in the consuming repository; Pinax never parses `source_ref`.

```json
{
  "schema": 1,
  "project": "blog",
  "source_rev": "b3bc22ff",
  "coverage": ["content/**/*.md", "static/**/*.html"],
  "refs": [
    { "raw_url": "https://img.example.com/blog/202511/x-a1b2.png",
      "source_ref": "content/posts/2026/foo.md#L12",
      "kind": "markdown" },
    { "raw_url": "https://i.imgur.com/legacy.png",
      "source_ref": "content/posts/2019/old.md#L4",
      "kind": "markdown" }
  ]
}
```

`schema` and `project` are required. `source_rev`, `coverage` and `refs` are optional; missing `coverage` and `refs` are empty arrays. Each ref requires `raw_url`, `source_ref` and `kind`.

## Rewrite map

`pinax rewrite-map --backend r2` lists a backend's current URL prefix and the prefixes it used before, for tools that rewrite stale links:

```json
{ "schema": 1,
  "current": "https://img.example.com",
  "retired": ["https://pub-0123abcd.r2.dev", "https://old.example.com"] }
```

## Object metadata

Pinax stores `sha256`, `orig-filename`, `width` and `height` as S3 user metadata (`x-amz-meta-*`). Header values must be ASCII: ASCII values are stored as is, and any non-ASCII value is stored as one RFC 2047 UTF-8 Base64 encoded-word:

```text
=?UTF-8?B?<base64-encoded UTF-8>?=
```

`pinax reindex` decodes this form when it rebuilds the catalog from object metadata.
