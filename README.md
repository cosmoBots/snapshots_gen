# snapshots_gen

Migration of old cosmoSys instances (Redmine 4.2 with `cosmosys_rm`, `cosmosys_req_rm`, `cosmosys_git_rm` and, in some, `cosmosys_req_poris_rm`) to the current cosmoSys (Redmine 7, deployed with `cosmoSys_deploy`), through snapshots, with their history, their users and passwords, and their tags.

**The migration procedure is written in Spanish:** [docs/procedimiento-migracion.md](docs/procedimiento-migracion.md). It is meant to be followed end to end, without help, by an administrator who knows Docker and Linux but not cosmoSys internals. Start there, and follow it from a released version, not from the tip of `main`:

```sh
git clone --branch v0.1.0 https://github.com/cosmoBots/snapshots_gen.git
```

## Data protection

Read this before running anything against a real instance. Every file the migration produces is a copy of the old instance and must be handled like a database backup:

- the legacy snapshot (`.cslegacy`) and the history package (`.cshistory`) carry every user's e-mail address and password hash (salted SHA-1, the scheme of Redmine 4.2 and 7, which a weak password does not survive);
- the `.csys` packages carry the whole content of each project, the `.cstags` package the names of every tag, and the conversion report (`report.md`, `report.json`), the import reports and the comparison extracts carry logins, subjects, notes and values.

Keep them in a private working directory (`umask 077`, modes 700 and 600, outside any Git checkout or synchronized folder), move them only over SSH or on an encrypted disk, never by e-mail, chat, issue or public link, and delete them when the migration is over. The procedure has a section on this ("Material sensible") with what each file holds, how to check permissions, how to move and delete them, and what to do if one ends up in the wrong place.

To report a security problem, see [SECURITY.md](SECURITY.md): only through GitHub's private vulnerability reporting, and never with data from a real instance.

## Rehearsed versions

The procedure was rehearsed from Redmine 4.2.10 on MySQL 5.7 (with `additionals` 3.0.5.2 and the cosmoBots fork of `additional_tags` 1.0.4) to cosmoSys 0.2.10 with cosmoSys Requirements, on Redmine 7.0.1 and PostgreSQL 16, with the `tags` plugin set of `cosmoSys_deploy` (`additionals` and `additional_tags` 4.6.0). It needs a `cosmoSys_deploy` that pins cosmoSys 0.2.10; the procedure says how to check it. Other versions have not been rehearsed: the importer relies on internal classes of cosmoSys, so another version means rehearsing on a copy first.

## How it works

The tool has three pieces, each of which knows only one side:

- `exporter/`: runs inside the old instance with `rails runner` (Ruby 2.7, Rails 5.2). It only reads, installs nothing and restarts nothing. It writes a lossless legacy snapshot: every table by name, the attachment files and a report of what it could not capture.
- `converter/`: runs with a current Ruby, outside both instances. It turns a legacy snapshot into a `.csys` package per root project that the cosmoSys import accepts, a history package, a tags package (`.cstags`) and a conversion report.
- `importer/`: runs inside the new instance with `rails runner`. Before the `.csys` import it creates users with their passwords, groups and custom fields; it runs the `.csys` import with the cosmoSys preflight; after it, before anyone works there, it writes the history (notes, changes, wiki versions, time entries and watchers) and restores the original authors and dates; and last it writes the tags, exactly as they were, into the tag plugin of the new instance, and gives each role the tag permissions its old role had. No notification is queued or sent while it runs.

`test/history_text.rb` with `test/compare_history.rb`, and `test/tags/`, compare the history and the tags of the new instance with those of the old one; the procedure runs them before the new instance is opened.

The legacy snapshot format is specified in [docs/legacy-snapshot-format.md](docs/legacy-snapshot-format.md) and the tags package in [docs/cstags-format.md](docs/cstags-format.md).

## Status and known limitations

The three pieces work end to end on a synthetic old instance and on a copy of a real one: the history of every item reads as in the source, and every tag arrives with its exact name on the same items and pages. Known limitations:

- PORIS models cannot be migrated yet: the converter writes their "blocks" relations, which the current `cosmosys_poris` plugin rejects, so the `.csys` import of a package that has them fails. The procedure tells you to stop if the inventory shows PORIS trackers.
- The order of the tags of an item is not kept: the new tag plugin always sorts them by name.
- The new tag plugin splits names with a comma, merges names that differ only in case and deletes unused tags when an item is edited after the migration. The import keeps them exact; the inventory and the conversion report count those cases so that they can be dealt with before migrating.
- Two-factor authentication is reset, and users of external authentication (LDAP) need a password from an administrator.

## Tests

These are for maintainers of the tool; the migration itself does not need them. The format code must run on Ruby 2.7 with rubyzip 2.3 (the old instances) and on a current Ruby with rubyzip 3 (the converter):

```sh
docker run --rm -v "$PWD":/w -w /w ruby:2.7 \
  bash -c 'gem install rubyzip -v 2.3.2 && ruby test/legacy_snapshot_format_test.rb'
docker build -t snapshots_gen-converter converter/
docker run --rm -v "$PWD":/w -w /w snapshots_gen-converter \
  bash -c 'for t in test/*_test.rb; do ruby "$t" || exit 1; done'
```

To check a package:

```sh
bin/verify-legacy-snapshot PACKAGE.cslegacy
bin/verify-cstags PACKAGE.cstags history=PACKAGE.cshistory csys=ROOT.csys ...
```

`test/legacy_env/` runs disposable old instances (MySQL 5.7 and Redmine 4.2.10) on a copied or synthetic application tree, `test/legacy_env/synthesize.rb` fills one with invented history, `test/e2e.sh` runs the whole migration on a disposable new instance, and `test/importer_tags_e2e.sh` imports the synthetic tags of `test/importer_tags_fixture.rb` (case variants, commas, composed and decomposed accents, emoji, 255 characters, an unused tag, tag changes in the history, roles with and without tag permissions) and compares what PostgreSQL holds byte by byte; it also checks the refusals, a second pass, the tag permissions given to the roles and that a history of another package is refused. `test/exporter_inventory_test.rb` checks the tag counts of the inventory. These end-to-end scripts expect a disposable working directory and deployment of their own (see the variables at the top of each script); never point them at an instance whose data matters.

## License

Copyright (C) 2026 cosmoBots.eu. GPL-3.0-only, like cosmoSys, whose snapshot code this tool derives from. `LICENSE` holds the licence text and, at its end, the Redmine licensing note of snapshots_gen, as in the cosmoSys repositories. The canonical JSON writer in `exporter/legacy_snapshot_format.rb` is adapted from `lib/cosmosys/canonical_json.rb` of cosmoSys, with changes for date values; the importer calls the snapshot classes of the cosmoSys instance it runs in and copies none of them.
