# Changelog

All notable changes to snapshots_gen are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first release. It migrates an old cosmoSys instance (Redmine 4.2 on MySQL 5.7 with the `cosmosys_*` plugins) to the current cosmoSys (Redmine 7 on PostgreSQL, deployed with `cosmoSys_deploy`) with its history, its users and passwords, and its tags. Added describes the whole tool; Changed and Fixed also say what differs from the code that was on `main` before this release.

### Added

- The exporter (`exporter/export.rb`), which runs inside the old instance with `rails runner` on Ruby 2.7 and Rails 5.2. It only reads, installs nothing and restarts nothing.
  - `inventory` prints counts and structure without content: plugins, trackers, statuses, custom fields, journals by detail type, wiki versions, private notes, users with 2FA or external authentication, indented Markdown tables that CommonMark would break, and a `Tags:` line with the tag cases the new tag plugin treats differently (unused tags, contexts, taggers, commas, names equal except for case, `group::` conflicts, edge spaces and tag changes in the history).
  - `capture` writes a lossless legacy snapshot (`.cslegacy`): every table by name except sessions and tokens, inside one read-only transaction, the attachment files addressed by SHA-256 and a report of what it could not copy, and verifies the package before finishing.
- The legacy snapshot format, specified in `docs/legacy-snapshot-format.md` and checked with `bin/verify-legacy-snapshot`. The format code runs on Ruby 2.7 with rubyzip 2.3 and on a current Ruby with rubyzip 3.
- The converter (`converter/convert.rb`), which runs in its own Docker image outside both instances. From a legacy snapshot it writes one `.csys` package per root project tree that the cosmoSys import accepts, with the definitions of the custom fields it carries; a history package (`.cshistory`); a tags package (`.cstags`); and a conversion report (`report.md` and `report.json`) with everything it transforms, drops or cannot recover, including what the old cosmoSys never recorded in the history.
  - It applies the rules of the cosmoSys legacy pipeline: `rq*` fields to native fields, AD, RD and CD items to documents and catalogue references, chapters around items that cannot have children, `rqVar` and `rqValue` to project data, and the old statuses, trackers and roles to the current ones.
  - An old CSID is kept whenever it is unique in its tree, also with the prefix of another project when the item was moved; only items without a usable CSID are renumbered. Every item that exists only in the new instance (group chapters, "Project data" chapters and their data) is reported with its final CSID.
- The tags package (`.cstags`), specified in `docs/cstags-format.md` and checked with `bin/verify-cstags`: every tag with its exact name, every tagging of an issue or wiki page bound to its item in the history package, the plugin settings with their provenance, and the tag permissions of every source role. The conversion applies a strict profile: what the new tag plugin cannot hold exactly blocks the conversion instead of being repaired, and tag names with a comma, names equal except for case and `group::` conflicts are reported as warnings before migrating.
- The importer (`importer/import.rb`), which runs inside the new instance with `rails runner`, in four steps:
  - `prepare` creates users with their password hashes, groups and custom fields before the `.csys` import;
  - `csys` runs the cosmoSys preflight and import of each package, in one transaction per package;
  - `history` writes notes, changes, wiki versions, time entries, watchers and memberships with their original authors and dates, verifies them in the same transaction, has a dry run, and writes a versioned report that names every dropped journal and says whether the conversion announced it;
  - `tags` (step 6.4 of the procedure) writes the tags exactly into the tables of `additional_tags` 4.6.0, without going through its API, after checking the destination and that the history imported there is the one of the same conversion; it reads everything back before committing, gives each role the tag permissions its source roles had (it only adds permissions), has a dry run, and a second pass writes nothing.
- Every importer command shows its progress by phase, keeps showing it during long phases, keeps the Rails log to warnings and errors while it runs, and ends with its total time.
- The checks of step 7: `test/history_text.rb` with `test/compare_history.rb` compare the history of every item with the source and pass only when each difference is explained by a narrow rule or a report entry, and `test/tags/` compares the tags of both instances by SQL, in both directions, independently of the tag plugin.
- The migration procedure, in Spanish (`docs/procedimiento-migracion.md`), from the inventory to the open instance, with rollback and the deletion of every file of the migration.
- Disposable old instances for testing (`test/legacy_env/`), synthetic history and tag edge cases, end-to-end scripts for the whole migration (`test/e2e.sh`) and for the tags import (`test/importer_tags_e2e.sh`), and unit tests for the format, the converter, the importer and the checks.

### Changed

- The rehearsed target is cosmoSys 0.2.10 with cosmoSys Requirements, on Redmine 7.0.1 and PostgreSQL 16, with the `tags` plugin set of `cosmoSys_deploy` (`additionals` and `additional_tags` 4.6.0). The new instance needs a `cosmoSys_deploy` that pins cosmoSys 0.2.10, and the procedure says how to check it.
- The procedure is rewritten for an administrator who knows Docker and Linux but not cosmoSys internals: the sensitive material comes first; it states the rehearsed versions and what is needed before starting; steps 1 to 3 run in the old server, with the reference extracts for step 7, and step 3.4 carries the files to the new one; step 5 gives the commands that create the new instance; step 6.4 imports the tags; step 7.2 compares the history and step 7.3 the tags; step 8 takes a checked backup before opening and publishes through the deploy proxy, a proxy of its own or no proxy; step 9 explains how to go back; and a table lists the messages seen in the rehearsals.
- PORIS models are a known limitation: the conversion writes their "blocks" relations, which the current `cosmosys_poris` plugin rejects, so the procedure stops when the inventory shows PORIS trackers.
- The `.csys` import runs the cosmoSys materializer for materialization explicitly, and the history import captures the approved presentation baselines of consolidated requirements at the end, when every relation exists.
- The README puts data protection first, points to the Spanish procedure, clones over HTTPS, states the rehearsed versions and the known limitations, and states the licence as GPL-3.0-only.

### Fixed

- Tag changes in the history were dropped by the converter, and a journal with only a tag change disappeared. They now arrive byte for byte, and the importer no longer rewrites tag names that look like item references.
- History changes that named an item, status, tracker, priority, category, version or project deleted from the old instance were dropped by the importer without notice. The converter now keeps the other side, drops the change only when nothing is left, and reports both cases.
- History changes of attachments that the item no longer has were written with id 0 without notice. They now keep their file names and are reported.
- A requirement whose `rqVar` cannot become project data lost its current `rqVar` and `rqValue` and their history. They now stay as custom fields, and a project without data no longer gets an empty "Project data" chapter.
- Consolidated requirements read "missing evidence" after the migration, because their approved presentation baselines were never captured.
- The history comparison no longer reports as unexplained the values of a multiple custom field that Redmine renders in one line.
- The tag checks read the plugin settings as Redmine saves them, and no longer fail on the help projects that every new cosmoSys instance brings.

### Security

- No mail or notification job is queued while the importer runs. Before, Redmine queued one for each recipient of each imported item and journal, which were not sent only because of how the instance was configured.
- The exporter does not export sessions or tokens, redacts 2FA secrets and service passwords, and writes files readable only by their owner. The comparison extracts are written with mode 600.
- The procedure has a section on sensitive material (what each file holds, how to keep, move and delete it, and what to do if one ends up in the wrong place), and the format documents and the README point to it.
- `.gitignore` ignores every package, report, comparison extract, database dump and environment file that a migration produces.

[Unreleased]: https://github.com/cosmoBots/snapshots_gen/commits/main
