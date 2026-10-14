# Legacy snapshot format, version 1

A legacy snapshot is the lossless copy of an old cosmoSys instance (Redmine 4.2 with the `cosmosys_*` plugins) that the exporter writes and the converter reads. It holds every relevant table of the instance as it is, by table and column name, plus the attachment files. It does not interpret anything: mapping old concepts to the new cosmoSys is the converter's job.

This document is the contract between the two sides. A package that the verifier accepts must be readable by any converter that supports `schema_version` `1`.

## Container

A package is a ZIP archive, by convention named `<label>-<UTC timestamp>.cslegacy`. The verifier also accepts the same tree as a plain directory, which is useful while debugging.

```text
manifest.json
tables/<table>.jsonl
assets/index.jsonl
assets/sha256/<sha256>
reports/<name>.jsonl
reports/inventory.json
```

No other entry is allowed. Entry names are relative, use `/` as separator, and never contain `..`, absolute paths or symbolic links.

## Canonical JSON

Every JSON document and every JSONL line is canonical JSON, with the same rules as cosmoSys (`Cosmosys::CanonicalJson`):

- object keys sorted by their UTF-8 byte order, at every level;
- no insignificant whitespace (Ruby `JSON.generate`);
- UTF-8 text, with only the escapes JSON requires.

JSONL files end every line, including the last, with a single `\n`.

## Manifest

`manifest.json` is one canonical JSON object:

```json
{
  "content": { "...": "..." },
  "content_sha256": "<sha256 of the canonical JSON of content>",
  "schema": "cosmosys-legacy-snapshot",
  "schema_version": "1"
}
```

`content` holds:

| Key | Meaning |
| --- | --- |
| `captured_at` | UTC time when the read transaction started, ISO 8601 with microseconds. |
| `generator` | `name` and `version` of the exporter. |
| `source` | Platform facts: `redmine_version`, `rails_version`, `ruby_version`, `database` (`adapter`, `version`, `name`), `settings` (effective values, see below), `plugins` (`id`, `name`, `version`, `directory`) and `label` (the operator's name for the instance, free text). |
| `consistency` | How the read was isolated, for example `mysql_consistent_snapshot_read_only`, and whether the row counts were checked inside the same transaction. |
| `tables` | One entry per exported table, sorted by `name`. |
| `excluded_tables` | Tables present in the database and deliberately left out, each with a `reason`. |
| `assets` | `index` (the file entry of `assets/index.jsonl`), `count` and `bytes` of the distinct blobs. |
| `reports` | File entries of the reports, sorted by `name`. |

A file entry is `{ "path": ..., "sha256": ..., "bytes": ..., "rows": ... }`. `rows` is the number of lines for JSONL files and is absent for plain JSON files.

A table entry is a file entry plus:

| Key | Meaning |
| --- | --- |
| `name` | Table name in the source database. |
| `columns` | Ordered list of `{ "name", "type", "sql_type", "null" }`, where `type` is the Rails abstract type (`integer`, `string`, `text`, `datetime`, `date`, `boolean`, `decimal`, `float`, `binary`, ...). |
| `primary_key` | Column names of the primary key, empty when the table has none. |
| `order_by` | Columns the rows are sorted by: the primary key, or every column for a table without one. |
| `redacted_columns` | Columns whose values were replaced by `null` on purpose (secrets that must not leave the instance). |

The effective settings are those the instance actually uses, including Redmine defaults that are not stored in the `settings` table: at least `text_formatting`, `wiki_compression`, `default_language`, `attachment_max_size`, `cross_project_issue_relations` and `parent_issue_*`.

## Tables

`tables/<table>.jsonl` holds one row per line, as an object whose keys are exactly the table's column names. Rows are sorted by `order_by`, comparing the encoded values column by column: `null` first, then numbers by value, strings by UTF-8 byte order (never by a database collation), `false` before `true`, and `$base64` objects by their base64 text.

Values are encoded by the column's `type`:

| Type | Encoding |
| --- | --- |
| null | `null` |
| `integer`, `bigint` | JSON integer |
| `float` | JSON number |
| `decimal` | string with the exact decimal value, for example `"12.50"` |
| `boolean` | `true` or `false` (MySQL `tinyint(1)` included) |
| `datetime`, `timestamp` | UTC string with microseconds, `2023-04-05T10:11:12.000000Z` |
| `date` | `YYYY-MM-DD` |
| `time` | `HH:MM:SS` |
| `string`, `text` | JSON string |
| `binary` | `{ "$base64": "<base64>" }` |

A `string` or `text` value that is not valid UTF-8 is written as `{ "$base64": "<base64 of the raw bytes>" }` and reported as an `invalid_utf8` gap, so nothing is lost and nothing is guessed. Redmine's serialized columns (YAML in `settings.value`, `user_preferences.others`, `custom_fields.format_store`, `queries.*`, `roles.permissions`) stay as the text the database holds.

### Which tables

The exporter writes every table of the instance database except:

- `tokens`: sessions, API keys, feeds and recovery tokens. They are credentials, and the new instance issues its own.
- `sessions`, if present, for the same reason.

The following values are redacted (written as `null` and listed in `redacted_columns`):

- `users.twofa_totp_key`: the 2FA secret, encrypted with the old instance's key. 2FA is reset in the new instance.
- `auth_sources.account_password` and `repositories.password`: service credentials.
- `settings.value` when the setting name or its stored value mentions an API key, a password, a secret or a token.

`users.hashed_password` and `users.salt` are exported on purpose: Redmine 4.2.10 and 7.0.1 hash passwords the same way, so users keep their passwords. This makes every package confidential. It must be stored and moved like a database backup, and deleted when the migration is done.

## Assets

`assets/index.jsonl` has one line per row of the `attachments` table, sorted by `attachment_id`:

```json
{"attachment_id":12,"bytes":4567,"sha256":"<hex>","status":"present"}
```

`status` is one of:

- `present`: the file exists and was copied. `sha256` and `bytes` describe it.
- `missing`: the row exists but the file does not. `sha256` and `bytes` are `null`.
- `unreadable`: the file exists but could not be read. `sha256` and `bytes` are `null`.

A `present` file whose size differs from `attachments.filesize`, or whose SHA-256 differs from a SHA-256 `attachments.digest`, is still copied as it is, and the difference is reported as a gap.

Each distinct blob is stored once, as `assets/sha256/<sha256>` with the lowercase hexadecimal SHA-256 of its bytes as name.

## Reports

- `reports/inventory.json`: the inventory of the instance, the same document the exporter's inventory mode prints. It describes counts and structure, never content.
- `reports/gaps.jsonl`: everything the exporter could not capture faithfully, one gap per line, sorted by `code`, `table` and `id`:

  ```json
  {"code":"attachment_file_missing","detail":{"disk_filename":"..."},"id":301,"table":"attachments"}
  ```

  Gap codes in version 1: `attachment_file_missing`, `attachment_unreadable`, `attachment_size_mismatch`, `attachment_digest_mismatch` and `invalid_utf8`.
- `reports/redactions.jsonl`: every value the exporter left out on purpose, one per line, as `{ "column", "id", "reason", "table" }`. Redacted columns are also listed in their table entry; redacted settings appear only here.

An empty package (no tables, no assets) is valid. It is what the skeleton writes and verifies.

## Verification

The verifier accepts a package only when all of this holds:

1. `manifest.json` exists, is canonical JSON, and has `schema` `cosmosys-legacy-snapshot` and a supported `schema_version`.
2. `content_sha256` equals the SHA-256 of the canonical JSON of `content`.
3. Every file entry exists, and its SHA-256, size and line count match.
4. Every table line is a canonical JSON object whose keys are exactly the declared columns, rows follow `order_by`, and primary keys are unique.
5. Every `present` asset exists under `assets/sha256/`, its SHA-256 equals its name and its size matches. Every blob is referenced by at least one index line.
6. The archive holds no entry outside the layout above.

## Versioning

`schema_version` changes only when a reader written for the previous version would misread a package. Adding a report, a gap code, a setting or a manifest key that readers can ignore does not change it.
