# Tags package format (.cstags), version 1

The tags package carries the tags of an old cosmoSys instance (the `additional_tags` plugin, fork 1.0.4, over `acts-as-taggable-on`) to the tag plugin of the new cosmoSys (`additional_tags` 4.6.0 with `additionals` 4.6.0, the `tags` option of the deploy). The converter writes one per conversion, next to the history package, from the same legacy snapshot:

```text
<label>-<root identifier>.csys   one per root project tree
<label>.cshistory                users, history, wiki versions...
<label>.cstags                   tags (this document)
```

It is one package for the whole instance, not one per tree: the tag catalog is global, and a tag can be on items of several trees and on wiki pages.

This document is the contract between the converter and the tags importer. `converter/lib/snapshots_gen/tags_package.rb` holds its writer, reader and verifier; it only needs `exporter/legacy_snapshot_format.rb` and rubyzip, so the importer can load it inside the new instance. `bin/verify-cstags` runs the verifier from the command line.

## What the package promises

- **Nothing is dropped.** Every row of `additional_tags` and `additional_taggings` is in the package, valid or not, with every column. Every issue and every wiki page of the source is listed, tagged or not, so an importer can check that untagged objects stay untagged.
- **Names are exact.** A name is the exact sequence of characters the source stored: no strip, no case change, no Unicode normalization, no transliteration, no truncation and no split at commas. `A,B` is one tag; `A` and `a` are two; `café` written with one code point and with two are two.
- **Nothing is decided in silence.** Whatever the destination cannot hold exactly is an anomaly with a code. A blocking anomaly makes the package not importable. The converter does not repair, merge, rename or reassign anything.
- **Identities are logical.** Objects are named by what the new instance can find: an item by its project and final CSID, a wiki page by its project and title. Source ids are only evidence.

## The strict profile

The destination plugin stores a tag as a name, and a tagging as (tag, object type, object id) with a creation time. It has no context, no tagger, no position and a unique index on (tag, type, id) (migrations `20260418000000` and `20260418100000` of 4.6.0). The old plugin stored a context, a tagger and allowed duplicates through null keys. The profile `additional-tags-4.6-postgresql-exact-v1` accepts only what maps one to one:

| Field | Value | Meaning |
| --- | --- | --- |
| `name` | `additional-tags-4.6-postgresql-exact-v1` | The profile itself. A reader rejects any other. |
| `implicit_context` | `tags` | Only taggings with context exactly `tags` are importable; the destination implies it. `NULL`, empty or any other context blocks. |
| `tagger_policy` | `null-only` | `tagger_id` and `tagger_type` must both be `NULL`. An empty `tagger_type` is not `NULL`. |
| `duplicate_policy` | `reject` | Two taggings that would be one row in the destination (same object, same exact name) block. |
| `name_policy` | `exact` | Names are inserted byte for byte; a name the destination model would change or reject blocks. |
| `order_policy` | `not-preserved` | The order of an object's tags is not carried (decision of 2026-11-10, see below). |

Every field is part of the meaning of the package. A reader must reject a package whose `profile` is not exactly this object.

### Order of tags

The order is not preserved, by decision (2026-11-10). The old plugin kept no position column; the new one always lists an object's tags by name (`ORDER BY LOWER(name)`), so no import could keep another order. The order is therefore neither an anomaly nor a reason to refuse the import. `objects.source_order` is always `null` in version 1, and comparisons of source and destination compare sets (multisets, to catch duplicates) of tags per object, never lists.

## Container

A ZIP archive with exactly these entries:

```text
manifest.json
tables/tags.jsonl
tables/taggings.jsonl
tables/objects.jsonl
reports/anomalies.jsonl
```

No other entry is allowed: no assets, no directories that hold files, no symbolic links, no absolute or `..` names, no repeated names. The entries must follow each other with nothing hidden between them and the central directory (a repeated name leaves a second local entry that some ZIP readers would see). Each entry is at most 1 GiB.

JSON follows the legacy snapshot rules (see [legacy-snapshot-format.md](legacy-snapshot-format.md), "Canonical JSON"): canonical JSON, keys sorted by UTF-8 bytes, no whitespace, UTF-8. `manifest.json` has no final newline; every JSONL line, including the last, ends with one `\n`. Values copied from the legacy snapshot keep its encoding: datetimes as UTC strings with microseconds (`2021-03-04T05:06:07.000000Z`), integers as integers, and text that was not valid UTF-8 as `{"$base64": "<base64 of the raw bytes>"}`.

## Manifest

```json
{
  "content": {"...": "..."},
  "content_sha256": "<sha256 of the canonical JSON of content>",
  "schema": "cosmosys-tags",
  "schema_version": "1"
}
```

`content` has exactly these keys:

| Key | Meaning |
| --- | --- |
| `captured_at` | `captured_at` of the legacy snapshot. |
| `generator` | `name` and `version` of the converter. |
| `source` | What the package was read from (below). |
| `dependencies` | The sibling packages it belongs to (below). |
| `profile` | The strict profile, exactly as above. |
| `counts` | Counts recomputable from the rows (below). |
| `importable` | `true` when there is no blocking anomaly, `false` otherwise. It never means that a comparison of source and destination has passed. |
| `files` | One entry per file, sorted by `path`: `{"bytes", "path", "rows", "sha256"}`, with the SHA-256 and size of the file's bytes and its number of lines. |

### source

| Key | Meaning |
| --- | --- |
| `legacy_snapshot_sha256` | `content_sha256` of the legacy snapshot. |
| `plugins` | `{"id", "version"}` of `additional_tags` and `additionals` as the exporter's inventory reported them; empty when the inventory does not have them. Never a revision guessed from elsewhere. |
| `tables_present` | `{"additional_taggings": bool, "additional_tags": bool}`: whether each table is in the legacy snapshot. A missing table is never turned into an empty one. |
| `table_descriptors` | For each present table, its `name`, `columns` (`name`, `type`, `sql_type`, `null`), `primary_key` and `rows` as the legacy snapshot declares them. Collation and indexes are not captured by the exporter and are not invented here. |
| `settings` | The ten settings of the destination plugin (below). |
| `settings_provenance` | `stored` (the setting row was read), `plugin_defaults` (the setting was never saved: the old plugin's defaults apply) or `incomplete` (at least one setting is `unavailable`). |

### settings

`settings` has exactly the keys of `Setting.plugin_additional_tags` in 4.6.0. Each is `{"provenance", "source_key", "source_value", "value"}`:

- `value`: what the destination should hold, `"0"`/`"1"` for switches or one of the allowed words, or `null` when it is unavailable;
- `provenance`: `stored`, `default` (old plugin default, the setting was never saved), `mapped` (translated from an old key), `destination_default` (no old equivalent: the new default) or `unavailable` (`value` is then `null`, and only then);
- `source_key` and `source_value`: the old key and its raw value, for evidence.

| Key | Rule |
| --- | --- |
| `active_issue_tags`, `active_wiki_tags` | Critical. `1`, `"1"` or `true` give `"1"`; `0`, `"0"` or `false` give `"0"`; anything else, or a missing key in a stored setting, is unavailable and a blocking `missing_settings`. |
| `open_issues_only`, `show_with_count` | Same switch rule; when unavailable, `invalid_setting` (warning) and the destination keeps its default. |
| `tags_sidebar` | One of `none`, `list`, `cloud`, `simple_cloud`. |
| `tags_sort_by`, `tags_sort_order` | `name`/`count` and `asc`/`desc`. |
| `tags_suggestion_order` | `name`, `last_created` or `count`. |
| `tags_color_theme` | Mapped from the old `use_colors` switch: `"0"` or `"1"`. It keeps colors on or off; the new color algorithm may give other colors. |
| `show_tags_after_queries` | No old equivalent: `"0"`, the destination default. |

The old plugin's defaults (all switches off, `use_colors` on, sidebar `none`, sort by `name` `asc`, suggestions by `name`) apply only when there is no `plugin_additional_tags` row. A legacy snapshot without a `settings` table, or a row redacted by the exporter, without a value, repeated, or that is not a safe YAML map, makes every old setting unavailable and is a blocking `missing_settings`. The YAML is read with `YAML.safe_load` (no Ruby objects, no aliases); the only tag accepted is `!ruby/hash:ActiveSupport::HashWithIndifferentAccess` on the root, which Redmine writes.

Installing the plugin does not switch tags on, and roles need `view_issue_tags` (and the others) to see them. A tagged object type whose switch is `"0"` gives a `tags_not_visible` warning: the tags import, but nobody sees them until someone switches them on.

### dependencies

| Key | Meaning |
| --- | --- |
| `history_content_sha256` | `content_sha256` of the sibling `.cshistory`. |
| `history_sha256` | SHA-256 of the bytes of that `.cshistory`. |
| `csys_packages` | One `{"content_sha256", "root_identifier", "sha256"}` per sibling `.csys`, sorted by `root_identifier`: the manifest digest and the SHA-256 of the file's bytes. |

An importer must be given the `.cshistory` and every `.csys` of the conversion and check them against these digests (`verify(history:, csys:)` does it). It must not trust file names, and it must not take matching ids or CSIDs in a database as proof that the right packages were imported.

### counts

All of them are recomputed by the verifier from the rows and must match.

| Key | Meaning |
| --- | --- |
| `source_tags`, `source_taggings` | Rows of `tags.jsonl` and `taggings.jsonl` (every source row). |
| `objects`, `issue_objects`, `wiki_objects`, `unsupported_objects` | Rows of `objects.jsonl`, in total and by `source_type` (`Issue`, `WikiPage`, anything else). |
| `tagged_objects` | Distinct `object_id` of the taggings. |
| `unused_tags` | Tags whose `id` no tagging names. |
| `distinct_contexts` | Distinct `context` values of the taggings, `null` included as a value of its own. A statistic: the rows keep each value. |
| `non_null_taggers` | Taggings with `tagger_id` or `tagger_type` set. |
| `duplicate_projection_groups` | Groups of taggings with the same `object_id` and the same exact tag name (or the same unknown `tag_id`). |
| `blocking_anomalies`, `warning_anomalies`, `information_anomalies` | Anomalies by severity. |

## Rows

Every file is sorted as described and every row has exactly the listed keys.

### tables/tags.jsonl

One line per row of `additional_tags`, in the legacy snapshot's order (by `id`).

| Key | Meaning |
| --- | --- |
| `ordinal` | Position of the row in the source table, from 1. A key for evidence when `id` is null or repeated. |
| `id` | Source id. A package key, never the destination id. |
| `name` | The exact name: a string, `null`, or `{"$base64": ...}` when it was not valid UTF-8. |
| `source_taggings_count` | The stored counter, only for diagnosis: the destination counter is recomputed. |
| `created_at`, `updated_at` | As stored. |
| `source_extra` | Columns of the source table that the format does not know, with their encoded values; `{}` normally. |

A column the format expects but the table lacks is `null` in every row, and `table_descriptors` shows it is absent (with a `missing_column` anomaly), so absence is never confused with a `NULL` value.

Example (invented): `{"created_at":"2021-03-04T05:06:07.000000Z","id":11,"name":"A,B","ordinal":1,"source_extra":{},"source_taggings_count":1,"updated_at":"2021-03-04T05:06:07.000000Z"}`

### tables/taggings.jsonl

One line per row of `additional_taggings`, in the legacy snapshot's order.

| Key | Meaning |
| --- | --- |
| `ordinal`, `id`, `source_extra` | As in tags. |
| `tag_id`, `taggable_type`, `taggable_id`, `tagger_type`, `tagger_id`, `context`, `created_at` | The source columns, as stored. |
| `object_id` | The `id` of the row of `objects.jsonl` this tagging is on. |

Example: `{"context":"tags","created_at":"2021-03-04T05:06:07.000000Z","id":21,"object_id":"Issue:7","ordinal":1,"source_extra":{},"tag_id":11,"taggable_id":7,"taggable_type":"Issue","tagger_id":null,"tagger_type":null}`

### tables/objects.jsonl

Every issue and every wiki page of the source, plus one row for every other (type, id) a tagging names. Sorted by issues, wiki pages, then the rest, each by source id.

| Key | Meaning |
| --- | --- |
| `id` | `Issue:<source id>`, `WikiPage:<source id>`, or `unsupported:<n>` for any other (type, id), numbered in the order of their encoded values. |
| `source_type`, `source_id` | The source type and id (for `unsupported`, as the tagging names them, even `null`). |
| `target` | The destination identity, or `null`. |
| `untargeted_reason` | `null` when there is a target; otherwise `absorbed_into_document` (an `AD n`/`RD n`/`CD n` item that became a document), `not_migrated`, `project_missing`, `wiki_missing`, `invalid_title`, `not_in_source` (a tagging names an issue or page that does not exist) or `unsupported_type`. |
| `source_order` | Always `null` in version 1 (order not preserved). |

Issue target: `{"csid", "item_key", "project_identifier", "type": "Issue"}`. `project_identifier` is the identifier of the item's project, as the `.csys` creates it; `csid` is the final CSID of the conversion plan, after prefixes are normalized and repeated CSIDs renumbered, never the raw old identifier; `item_key` is the item key of the `.csys` and `.cshistory`. The history importer finds an item by project and CSID ignoring case; the tags importer must find exactly one issue for (project, CSID) and refuse when it finds none or several.

Wiki page target: `{"project_identifier", "title", "type": "WikiPage"}` with the exact title. A page is found in its project's wiki by title, without following redirects. The same title in two projects is two objects.

Two objects with the same target ignoring case (the way Redmine finds wiki pages and the history importer finds CSIDs) are reported: `ambiguous_object` (blocking) when one of them is tagged, `ambiguous_untagged_object` (warning) otherwise.

### reports/anomalies.jsonl

| Key | Meaning |
| --- | --- |
| `id` | 1, 2, ... in file order. |
| `code`, `severity` | The code and its fixed severity (table below). |
| `table` | `tags`, `taggings`, `objects` or `settings`. |
| `source_ids` | The ids involved: tag or tagging ids (`"ordinal:<n>"` when the id is null), object ids, or setting keys. |
| `reason` | A generic sentence. It never holds a tag name or any content. |

Sorted by `code`, `table` and `source_ids`. The codes of version 1:

| Code | Severity | When |
| --- | --- | --- |
| `missing_table` | blocking | `additional_tags` or `additional_taggings` is not in the legacy snapshot. Both missing means the snapshot has no evidence of tags; it is never read as "no tags". |
| `missing_column` | blocking | An expected column is not in a table. |
| `unknown_column` | blocking | A table has columns without an approved mapping (their values are in `source_extra`). |
| `invalid_key` | blocking | A tag or tagging `id` is null or repeated. |
| `invalid_name` | blocking | A name is null, empty, only spaces, has leading or trailing spaces (the destination model strips them), holds U+0000 (PostgreSQL cannot store it) or is longer than 255 characters. |
| `invalid_encoding` | blocking | A name is not valid UTF-8. |
| `duplicate_name` | blocking | Two tags have exactly the same name. |
| `orphan_tag` | blocking | A tagging's `tag_id` is null or names no unique tag. |
| `orphan_object` | blocking | A tagging is on an issue or page that does not exist or has no target. |
| `unsupported_type` | blocking | A tagging's type is not exactly `Issue` or `WikiPage` (another class, `null`, another case). |
| `absorbed_issue` | blocking | A tagging is on an item absorbed into a document. It is not moved to the document or to a parent. |
| `unsupported_context` | blocking | A tagging's context is not exactly `tags`. |
| `non_null_tagger` | blocking | A tagging has a tagger. |
| `duplicate_projection` | blocking | Taggings that would collapse into one destination row. |
| `ambiguous_object` | blocking | A tagged object shares its destination identity with another. |
| `missing_settings` | blocking | `active_issue_tags` or `active_wiki_tags` cannot be determined. |
| `ambiguous_untagged_object` | warning | An untagged object shares its destination identity with another. |
| `invalid_setting` | warning | A display setting cannot be determined; the destination keeps its default. |
| `tags_not_visible` | warning | A tagged object type is switched off. |
| `unused_tag` | warning | A tag has no taggings. It is imported, but the 4.6.0 plugin deletes unused tags after any later edit of an item (`AdditionalTagsRemoveUnusedTagJob`). |
| `case_variant_names` | warning | Names equal except for case. They stay apart, but the new tag API looks names up ignoring case. |
| `scoped_tag_conflict` | warning | An object has two tags of the same `group::` scope, which 4.6.0 rejects when the object is edited. |
| `counter_mismatch` | information | A stored `taggings_count` differs from the real count. |

## Verification

`TagsPackage::Verifier#verify(history:, csys:)` accepts a package only when:

1. the archive holds exactly the five entries, safely named, contiguous and within the size limit;
2. `manifest.json` is canonical, has exactly its four keys, `schema` `cosmosys-tags` and `schema_version` `"1"`, and its `content_sha256` matches;
3. `content` has exactly its keys, `profile` is the profile of version 1 and `importable` is a boolean;
4. every file matches its SHA-256, size and line count, is UTF-8, and each line is a canonical object with exactly the keys of its file;
5. ordinals run 1, 2, ...; objects are unique and sorted; every tagging names an object; every object has either a well-formed target or a known reason; anomalies have known codes with their severity and are sorted;
6. `counts` equal the counts of the rows and `importable` equals "no blocking anomaly";
7. `source` has its keys, `settings` exactly the ten keys with well-formed entries;
8. when `importable` is `true`, the strict profile holds row by row, recomputed rather than read from the anomalies: both tables present, critical settings `"0"` or `"1"`, unique ids, exact valid unique names, no `source_extra`, every tagging with a unique tag, context `tags`, no tagger, type `Issue` or `WikiPage`, an object with a target, no collapsing taggings and no shared target among tagged objects;
9. when given, the `.cshistory` verifies and matches both digests, and the `.csys` files are exactly those of `csys_packages`.

`TagsPackage.read(path, history:, csys:)` returns the manifest and rows only when all of this holds. `bin/verify-cstags PACKAGE [history=...] [csys=... ...]` exits 0 when the package verifies and is importable, 3 when it verifies but is not importable, and 1 when it does not verify.

## Importing

`importer/tags_importer.rb` (`import.rb tags PACKAGE.cstags [dry_run=yes] [packages=DIRECTORY]`) imports the package. It runs after `prepare`, every `.csys` and `history`, on a PostgreSQL instance where the deploy's `tags` option is installed and migrated. This is what it does, and what the format needs from any importer:

- **The package.** It reads the package with `TagsPackage.read`, always giving it the `.cshistory` and every `.csys` found next to the `.cstags` (or in `packages=`), and refuses a package that does not verify, whose siblings are not exactly those of the conversion, or that is not importable.
- **The destination.** Before writing it requires PostgreSQL with UTF-8, `additional_tags` 4.6 and `additionals` registered with every migration applied, and the two tables exactly as 4.6.0 leaves them: the same columns, types and `NOT NULL`, the unique indexes on `name` and on (`tag_id`, `taggable_id`, `taggable_type`) and no other, the foreign key of `tag_id`, and no trigger or check constraint. The collation of `name` must be deterministic, and all the names of the package must be distinct under it (asked to the database, not assumed).
- **Identities.** Every object with a target, tagged or not, must be exactly one object: an issue by project and CSID ignoring case, a wiki page by project and identical title, never through a redirect. The `.cshistory` must have the same items (same `item_key`, project and CSID), and the items must already have the creation dates the history import restores; otherwise the history has not been imported and the tags import refuses.
- **What is already there.** A destination tag is reused only when its name is byte-equal and its dates are those of the package. The import refuses, without writing, when a tag has the same name and other dates, when a destination tag differs only in case from a tag of the package, when an object of the package has a tagging that is not in the package, or when a tagging exists with another date. Tags and taggings that are not of the package, on objects that are not of the package, are left alone.
- **Writing.** One `REPEATABLE READ` transaction, with both tag tables locked. Rows are inserted through bare models over the two tables: no callbacks, no validations, no normalization, no `tag_list=`, no `find_or_create_all_with_like_by_name`, no lookup by `LOWER(name)`, and no issue or wiki page is saved. `created_at` (tags and taggings) and `updated_at` (tags) are those of the package. `taggings_count` of every tag of the package is set to the real count of all its taggings, not only the package's.
- **Settings.** The `settings` values whose provenance is not `unavailable` are stored as the settings page stores them, and only when one differs from what the instance has; the others keep the destination value. A tagged type left switched off is reported (`tags_not_visible`), and so are the roles in use that lack `view_issue_tags`: the import never changes roles.
- **Verification before the commit.** The tables are read again and compared: for every object of `objects.jsonl` with a target, also the untagged ones, the multiset of exact names (and their dates) with the package's; every tag of the package once in the catalog, with its dates, unused tags included; every counter with the real count; every tag and tagging that was there before, unchanged; and nothing else written: the content of every other table of the database is digested before and after, the rows written by the transaction are read from PostgreSQL's own statistics, and any job enqueued or mail sent counts as a failure. Any difference rolls everything back and is listed by ids and short SHA-256 of the names, never by name. After the commit the same comparison runs once more on a new connection.
- **Twice.** `dry_run=yes` does everything and rolls back (sequences advance; nothing else stays). A second import finds everything there, writes no row and says so.

## History

Tag changes in the history are not part of this package. The old plugin recorded them as journal details `property` `attr`, `prop_key` `tag_list`, with the old and new lists printed as text. The `.cshistory` carries them as literal attributes, exactly as stored (`null`, commas and quotes included), without parsing or rewriting them; the history package format does not change. The new plugin labels `tag_list` in English and Spanish and hides these details from users without `view_issue_tags`.

## Versioning

Version 1 readers accept only `schema` `cosmosys-tags` and `schema_version` `"1"`. Any change to identity, names, context, tagger, order, the profile or the meaning of a row needs a new version, and so does any new exception to the strict profile. The version 1 verifier also rejects keys, anomaly codes and counts it does not know, so adding any of them needs a new version as well.
