# Security policy

## Supported versions

Security fixes go into the latest release only. While the version is 0.x, that is the latest 0.y.z.

## Reporting a vulnerability

Report it privately through GitHub: open the repository's Security tab and choose "Report a vulnerability". That is the only channel; please do not open a public issue or pull request for it, and do not send it by e-mail.

Tell us the version of snapshots_gen (the release tag or the commit), the versions of the old and the new instance (Redmine, cosmoSys and the tag plugins), what an attacker can do, and the steps to reproduce it.

## Never attach data from a real instance

Do not attach, paste or link a package (`.cslegacy`, `.csys`, `.cshistory`, `.cstags`), a report, a comparison extract, a database dump or a backup of a real instance, not even in a private report. They carry every user's e-mail address and password hash and the whole content of the instance. Describe the problem with error messages, counts or synthetic data instead; `test/legacy_env/` can build an old instance with invented content. See [Data protection](README.md#data-protection) in the README.
