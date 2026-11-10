# snapshots_gen

Migration of old cosmoSys instances (Redmine 4.2 with `cosmosys_rm`, `cosmosys_req_rm`, `cosmosys_git_rm` and, in some, `cosmosys_req_poris_rm`) to the current cosmoSys, through snapshots.

The tool has three pieces, each of which knows only one side:

- `exporter/`: runs inside the old instance with `rails runner` (Ruby 2.7, Rails 5.2). It only reads, installs nothing and restarts nothing. It writes a lossless legacy snapshot: every table by name, the attachment files and a report of what it could not capture.
- `converter/`: runs with a current Ruby, outside both instances. It turns a legacy snapshot into a `.csys` package per root project that the cosmoSys import accepts, a history package, a tags package (`.cstags`) and a conversion report.
- `importer/`: runs inside the new instance with `rails runner`. Before the `.csys` import it creates users with their passwords, groups and custom fields; it runs the `.csys` import with the cosmoSys preflight; after it, before anyone works there, it writes the history (notes, changes, wiki versions, time entries and watchers) and restores the original authors and dates; and last it writes the tags, exactly as they were, into the tag plugin of the new instance.

The legacy snapshot format is specified in [docs/legacy-snapshot-format.md](docs/legacy-snapshot-format.md).

The migration procedure, in Spanish, is [docs/procedimiento-migracion.md](docs/procedimiento-migracion.md).

## Status

The three pieces work end to end on a synthetic old instance and on a copy of a real one: the history of every item reads as in the source. Old PORIS models already migrate with their items, hierarchy, custom fields and relations (their value trackers become `prValue` and their "blocks" relations are reversed); tags travel in their own package (`.cstags`, with tag changes kept in the history) and are imported name by name, without going through the tag plugin's API; moving PORIS fields to the `poris` profile comes later.

## Data protection

A legacy snapshot contains user accounts with their password hashes, e-mail addresses and the whole content of the instance. Treat it like a database backup: keep it on encrypted or access-controlled storage, never commit it, and delete it when the migration is finished.

## Tests

The format code must run on Ruby 2.7 with rubyzip 2.3 (the old instances) and on a current Ruby with rubyzip 3 (the converter):

```sh
docker run --rm -v "$PWD":/w -w /w ruby:2.7 \
  bash -c 'gem install rubyzip -v 2.3.2 && ruby test/legacy_snapshot_format_test.rb'
docker build -t snapshots_gen-converter converter/
docker run --rm -v "$PWD":/w -w /w snapshots_gen-converter \
  bash -c 'for t in legacy_snapshot_format converter_rules converter_history converter_tags; do ruby test/${t}_test.rb || exit 1; done'
```

To check a package:

```sh
bin/verify-legacy-snapshot PACKAGE.cslegacy
bin/verify-cstags PACKAGE.cstags history=PACKAGE.cshistory csys=ROOT.csys ...
```

The tags package is specified in [docs/cstags-format.md](docs/cstags-format.md).

`test/legacy_env/` runs disposable old instances (MySQL 5.7 and Redmine 4.2.10) on a copied or synthetic application tree, `test/legacy_env/synthesize.rb` fills one with invented history, `test/e2e.sh` runs the whole migration on a disposable new instance, and `test/importer_tags_e2e.sh` imports the synthetic tags of `test/importer_tags_fixture.rb` (case variants, commas, composed and decomposed accents, emoji, 255 characters, an unused tag, tag changes in the history) and compares what PostgreSQL holds byte by byte.

## License

GPL-3.0, like cosmoSys, whose snapshot code this tool derives from.
