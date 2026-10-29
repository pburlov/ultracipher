# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries before the storage rework are reconstructed from commit messages — the
repository has no tags.

## [Unreleased]

### Open source

- Released under the GPL-3.0 (`LICENSE`), with a root `README.md`.
- Web build: `index.html` uses the current `flutter_bootstrap.js` loader and a
  strict Content-Security-Policy (same origin plus `https://api.github.com`).
  Build with `flutter build web --wasm --no-web-resources-cdn`.
- `.github/workflows/pages.yml`: CI (analyze, tests) on every push and pull
  request; with the repository variable `DEPLOY_PAGES=true` it also publishes
  the web build to GitHub Pages, so anyone can host their own copy. The web
  version is not hosted centrally.
- Source Code Pro (static Regular, entry editor) is bundled as an asset instead of being loaded
  from fonts.gstatic.com at runtime; the `google_fonts` dependency is gone.
- Apple development team removed from the iOS and macOS Xcode projects;
  copyright lines (macOS, Windows) now name Paul Burlov.

The database now lives on the device first and syncs to GitHub in the
background. GitHub (optional) is the only remote; the App Engine REST backend
is gone.

**Upgrade note: databases from older app versions are NOT read.** The naming
of the databases changed (a database is now named after its key, there is no
username any more), so the new app does not find old local copies or old
GitHub files, and there is no automatic migration. Before updating, export a
CSV from the old app ("Export CSV" in the open database's menu), then import
that CSV in the new app (create a new database with "New", then "Import CSV"
in its menu). Old local data and old GitHub files are left untouched; a build
from the git history can still read them. "Erase local data" on the start
screen removes old local entries on request.

The same applies to the new encryption format below: databases written by
earlier app versions (AES/CBC) are not read either, not even with the right
passphrase, because the passphrase now derives a different name and key.
Export a CSV with the old app version first.

### New encryption format (Ultracipher format v1)

- Layered encryption: the compressed database passes through three independent
  stream ciphers (AES-256-CTR, Twofish-256-CTR, ChaCha20) and is authenticated
  by two MACs from different hash families (HMAC-SHA-512 and HMAC-SHA3-256,
  encrypt-then-MAC). Every save uses a fresh random file salt, so all keys and
  nonces change with each write. The payload is JSON -> BZip2 (the TAR
  container is gone). The file has a plain header (magic `UCDB`, version,
  suite, KDF profile) so that old and newer formats are recognised before any
  key derivation.
- Key derivation: Argon2id (32 MiB, t=3) and scrypt (N=2^16, r=8) run on the
  passphrase and are combined by a dual HKDF (SHA-512 and SHA3-512) into one
  64-byte root secret. The database name is its own branch of that secret, so
  guessing a passphrase against a public file name costs the full derivation.
  About 0.5 s natively; about 12 s in the browser, where the page does not
  respond meanwhile (the progress dialog now says so).
- No key cache any more: the app keeps only the root secret in memory while a
  database is open, and nothing derived from the passphrase is stored on the
  device. Old key-cache entries are removed by "Erase local data".
- Old copies on the device (older app versions) are hidden from the start
  screen, which shows a hint to export and import a CSV; importing an
  old-format text gives the same hint before any derivation. "Erase local
  data" first removes the current databases, then, after a second
  confirmation, the old data as well.
- Setting or changing a passphrase with non-ASCII characters (umlauts, accents)
  asks for confirmation: such characters can be entered in different ways on
  other devices, and the passphrase is not normalised.
- Size caps: file 64 MiB and the matching base64 text length before any
  decoding, 512 MiB decompressed after the MACs verify.
- The primitives come from `pointycastle`; the tests include known-answer
  vectors and run on the VM and under WebAssembly, because `pointycastle`'s
  Argon2 is wrong in one of its variants under WebAssembly.
- `docs/security.md` describes the design and the byte layout.

### Added

- Start screen: with local databases, a passphrase field with "Open" and
  buttons "New" and "Import"; without one, a short explanation. One
  passphrase is one database; a wrong passphrase just finds nothing ("No
  database found for this password"). Several databases per device work.
  The menu has "Erase local data" and "About".
- "New" creates a database (passphrase twice) and offers GitHub setup (token,
  repository, branch; "Skip" keeps it on this device only). With the same
  passphrase and GitHub access, "New" on a second device loads and merges the
  existing file.
- "Import" opens an encrypted base64 text (see "Export encrypted (base64)")
  with its passphrase; an existing local copy is merged, not overwritten.
- Local-first with background sync: every change is saved on the device
  immediately and synced afterwards, so editing works offline and never fails
  because of the network. A status icon in the title bar shows synced /
  syncing / not synced / token rejected / file missing on GitHub / no remote;
  tapping it (or "Sync now") syncs. Sync also runs on open and when the app
  returns to the foreground. Rate limits are shown with the wait time; a
  conflicting write is re-merged and retried.
- "GitHub settings" in the open database: change token, repository or branch,
  or remove GitHub. The settings are stored inside the database (the token
  encrypted with it) and spread to other devices by the merge; the latest
  change wins. A token therefore also sits, encrypted, in the repository
  history and in every encrypted export.
- Closing with unsynced changes asks first ("Changes stay on this device and
  sync next time"); "Remove local database" warns about unsynced changes or
  the only copy.
- Change passphrase, now a rename: the database moves to the name of the new
  passphrase (new file written first, old one removed afterwards; an abort
  loses nothing). With GitHub configured it needs the network. Other devices
  then see "file missing on GitHub" and follow with the same change to the new
  passphrase.
- CSV export now has an `id` column; CSV import merges by id and never
  deletes. It still accepts the old 4-column and 3-column files, skips rows
  that equal an existing entry (a second import creates no duplicates), and
  blank rows never create entries. The CSV never contains the GitHub settings.
- "Export encrypted (base64)" and the start screen's "Import" move a database
  between devices by copy and paste. The text is the same text the GitHub file
  holds.
- Deleted entries are tracked in a deletion list that is merged between
  devices (kept 365 days), so a deletion on one device is no longer undone by
  syncing another. Timestamps are stored in UTC.

### Changed

- GitHub storage is one line of base64 text per database in a file
  `<name>.txt`, where the name is derived from the database's root secret
  (was `<hash>.ucdb`, binary, derived from username and key). The text is the
  base64 of the new v1 file (see above).
- A hung GitHub request is now really aborted at its timeout (30 s) instead
  of only being abandoned, so an unreachable server cannot block syncing
  until the app restarts; it shows as "not synced".
- Known limitation: a device whose clock runs ahead can make its deletion win
  over a later edit made on a device with a correct clock. This is accepted
  and not corrected.
- The separate core package is merged into the app: the data model and its
  serialization live in `ultracipher_flutter/lib/src/model/`, its tests in
  `ultracipher_flutter/test/model/`. The repo now contains a single Flutter
  package.
- Dependencies updated: `pointycastle` 4.0.0, `archive` 4.3.0, `http` 1.5,
  `csv` 8.0.0, `uuid` 4.6.0, `intl` 0.20.3, `google_fonts` 8.2.1,
  `package_info` → `package_info_plus` 10.2.1.
- `pointycastle` and `archive` are no longer exact-pinned (now caret ranges):
  the pins guarded old clients reading data written by a new one, a direction
  the project decided not to test. The golden vectors remain the
  guard for the direction that matters (old data staying readable by new
  code); the tracked `pubspec.lock` keeps resolution reproducible day to day.
- SDK constraints allow Dart 3; the project resolves again.

### Security

- Generated passphrases and the per-file salt use a cryptographic PRNG
  (`Random.secure()`). The old AES-CBC IV generator (which also never emitted
  byte 255) is gone with the old format.
- Plaintext secrets no longer reach logs or error dialogs: CSV import content,
  decrypted-database snippets in `FormatException` messages, and the server
  security code inside request URIs.

### Removed

- `UltracipherApp.deriveSecurityCode`, which nothing in the app used; only the
  golden-vector test called it.
- The App Engine backend (`GAEBackend/`) and the app's client for it, including
  the Server/GitHub switch on the login screen. GitHub is the only persistence.
- The security code that the App Engine API required with every read and
  write (derived from the database key). GitHub authenticates with the token
  instead.
- The original encryption format (Salsa20/GZip). It was superseded years ago
  and any database was rewritten in the next format on its first save. A
  database that has *not* been saved since then is no longer readable —
  recovery requires checking out an older revision.
- The AES/CBC (JSON -> TAR -> BZip2) format of earlier app versions, its
  key-derivation chain, the cached second-stage key and the `worker_manager`
  dependency (key derivation now runs through Flutter's `compute`).
- The username. A database is identified by its passphrase alone; there is
  nothing to type or remember besides it, and the "stored username" is gone.
- The read-only modes and everything that served them: "Load from local" and
  "Open from text…" on the login screen, "Save to GitHub" (replaced by
  "GitHub settings"), and the separately stored GitHub token ("Forget stored
  GitHub token").
- The CSV "Replace" import (it replaced the whole database). CSV import now
  merges.

### Fixed

- Entries whose JSON has no `versions` key no longer crash the load; a
  wrong-typed value now fails loudly instead of silently emptying the list.
- CSV: trailing `\r` on CRLF input, BOM stripping, export/import round trip on
  multiline fields. A quote not at field start is now literal (RFC-correct).

### Internal

- Golden-vector tests: a committed ciphertext fixture and derived keys,
  decrypted not round-tripped, so format changes cannot pass unnoticed.
- Linting enabled for the app, including the merged model code.
- The golden fixture was frozen for the v1 format on 2026-10-28
  (`golden_v1_test.dart`, `tool/generate_fixtures_v1.dart` refuses to
  overwrite it), and `user_key_hash_golden_test.dart` pins the root-derived
  database name, the `ucdb_<name>` local key and the `<name>.txt` GitHub path
  (re-pinned once with approval when the name moved to the root secret).
- The crypto tests, the golden vectors and the name pins also run under
  WebAssembly (`flutter test --platform chrome --wasm
  --dart-define=EXPECT_WASM=true test/crypto/ test/golden_v1_test.dart
  test/user_key_hash_golden_test.dart`).
- Tests run with `flutter test --concurrency=6`; slow test files share
  memoized root derivation.

## [1.5.3] — Release build

## [1.5.1] — Web build

## [1.5.0] — iOS release. Runtime data obfuscation; freed buffers overwritten

## [1.4.1] — Release build

## [1.4.0] — Android/web/desktop. Last-changed time shown; local-load crash fixed

## [1.3.0] — Null-safe Dart migration; remote database merged before commit
