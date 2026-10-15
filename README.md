# snapshots_gen

Migration of old cosmoSys instances (Redmine 4.2 with `cosmosys_rm`, `cosmosys_req_rm`, `cosmosys_git_rm` and, in some, `cosmosys_req_poris_rm`) to the current cosmoSys, through snapshots.

The tool has three pieces, each of which knows only one side:

- `exporter/`: runs inside the old instance with `rails runner` (Ruby 2.7, Rails 5.2). It only reads, installs nothing and restarts nothing. It writes a lossless legacy snapshot: every table by name, the attachment files and a report of what it could not capture.
- `converter/`: runs with a current Ruby, outside both instances. It turns a legacy snapshot into a `.csys` package that the cosmoSys import accepts, plus a conversion report.
- `importer/`: runs inside the new instance with `rails runner`. Before the `.csys` import it creates users with their passwords, groups and custom fields; it runs the `.csys` import with the cosmoSys preflight; and after it, before anyone works there, it writes the history (notes, changes, wiki versions, time entries and watchers) and restores the original authors and dates.

The legacy snapshot format is specified in [docs/legacy-snapshot-format.md](docs/legacy-snapshot-format.md).

The migration procedure, in Spanish, is [docs/procedimiento-migracion.md](docs/procedimiento-migracion.md).

## Status

The three pieces work end to end on a synthetic old instance and on a copy of a real one: the history of every item reads as in the source. Old PORIS models already migrate with their items, hierarchy, custom fields and relations (their value trackers become `prValue` and their "blocks" relations are reversed); tags, and moving PORIS fields to the `poris` profile, come later.

## Data protection

A legacy snapshot contains user accounts with their password hashes, e-mail addresses and the whole content of the instance. Treat it like a database backup: keep it on encrypted or access-controlled storage, never commit it, and delete it when the migration is finished.

## Tests

The format code must run on Ruby 2.7 with rubyzip 2.3 (the old instances) and on a current Ruby with rubyzip 3 (the converter):

```sh
docker run --rm -v "$PWD":/w -w /w ruby:2.7 \
  bash -c 'gem install rubyzip -v 2.3.2 && ruby test/legacy_snapshot_format_test.rb'
docker build -t snapshots_gen-converter converter/
docker run --rm -v "$PWD":/w -w /w snapshots_gen-converter \
  bash -c 'ruby test/legacy_snapshot_format_test.rb && ruby test/converter_rules_test.rb'
```

To check a package:

```sh
bin/verify-legacy-snapshot PACKAGE.cslegacy
```

`test/legacy_env/` runs disposable old instances (MySQL 5.7 and Redmine 4.2.10) on a copied or synthetic application tree, `test/legacy_env/synthesize.rb` fills one with invented history, and `test/e2e.sh` runs the whole migration on a disposable new instance.

## License

GPL-3.0, like cosmoSys, whose snapshot code this tool derives from.
