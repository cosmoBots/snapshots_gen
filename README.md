# snapshots_gen

Migration of old cosmoSys instances (Redmine 4.2 with `cosmosys_rm`, `cosmosys_req_rm`, `cosmosys_git_rm` and, in some, `cosmosys_req_poris_rm`) to the current cosmoSys, through snapshots.

The tool has three pieces, each of which knows only one side:

- `exporter/`: runs inside the old instance with `rails runner` (Ruby 2.7, Rails 5.2). It only reads, installs nothing and restarts nothing. It writes a lossless legacy snapshot: every table by name, the attachment files and a report of what it could not capture.
- `converter/`: runs with a current Ruby, outside both instances. It turns a legacy snapshot into a `.csys` package that the cosmoSys import accepts, plus a conversion report.
- `importer/`: runs inside the new instance with `rails runner`, after the `.csys` import and before anyone works there. It brings users, history (notes, changes, wiki versions, time entries and watchers) and the original authors and dates.

The legacy snapshot format is specified in [docs/legacy-snapshot-format.md](docs/legacy-snapshot-format.md).

## Status

Work in progress. The format, its writer and its verifier exist; the pieces are being written.

## Data protection

A legacy snapshot contains user accounts with their password hashes, e-mail addresses and the whole content of the instance. Treat it like a database backup: keep it on encrypted or access-controlled storage, never commit it, and delete it when the migration is finished.

## Tests

The format code must run on Ruby 2.7 with rubyzip 2.3 (the old instances) and on a current Ruby with rubyzip 3 (the converter):

```sh
docker run --rm -v "$PWD":/w -w /w ruby:2.7 \
  bash -c 'gem install rubyzip -v 2.3.2 && ruby test/legacy_snapshot_format_test.rb'
docker run --rm -v "$PWD":/w -w /w ruby:3.3 \
  bash -c 'gem install rubyzip && ruby test/legacy_snapshot_format_test.rb'
```

To check a package:

```sh
bin/verify-legacy-snapshot PACKAGE.cslegacy
```

## License

GPL-3.0, like cosmoSys, whose snapshot code this tool derives from.
