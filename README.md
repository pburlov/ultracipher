# Ultracipher

Ultracipher is a local-first, end-to-end encrypted database for passwords and
notes.

- **One passphrase, one database.** There is no username and no account. The
  database name is derived from the passphrase; a wrong passphrase simply finds
  no database.
- **Local first.** The database lives encrypted on your device. Every change is
  saved locally first; sync runs in the background and never blocks a save.
- **Optional sync through your own GitHub repository.** The encrypted file is
  stored as `<name>.txt` in a repository you choose and merged across devices.
  GitHub only ever sees ciphertext. The app has no server of its own.
- **Layered encryption.** Argon2id and scrypt for key derivation, then a
  cascade of AES-256, Twofish-256 and ChaCha20 with two independent MACs. The
  full description is in [docs/security.md](docs/security.md).

> **Not audited.** Neither the design nor the implementation has had an
> independent security audit. See [docs/security.md](docs/security.md) for the
> threat model and its limits.

## Platforms

Flutter app in [`ultracipher_flutter/`](ultracipher_flutter/) for

- desktop: macOS and Windows
- mobile: Android and iOS
- web: Chromium-based browsers run the WebAssembly (WASM) build; Firefox,
  Safari and all iOS browsers get the JavaScript build that Flutter falls back
  to (the same `flutter build web --wasm` output contains both). See [Hosting
  the web version yourself](#hosting-the-web-version-yourself).

## Building

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install) on the
stable channel.

```bash
cd ultracipher_flutter
flutter pub get
flutter analyze
flutter test
flutter build macos      # or: windows, apk, ios
```

Web:

```bash
flutter build web --wasm --no-web-resources-cdn
```

`--no-web-resources-cdn` bundles the rendering engine (CanvasKit/Skwasm) with
the build instead of loading it from a Google server, so the page needs nothing
from any third party. The output is in `ultracipher_flutter/build/web`.

The Android application ID and the iOS/macOS bundle ID are `de.pbsoftworks.*`,
and the Apple development team is not set in the Xcode projects. If you sign or
distribute your own builds, set your own bundle ID and your own Apple team.

## Hosting the web version yourself

The web version is **not** offered centrally. A web page is delivered fresh on
every visit, so whoever serves it controls the code that sees your passphrase.
Instead of trusting someone else's server, build and host it yourself, for
example on GitHub Pages in your own fork:

1. Fork this repository on GitHub and, in the Actions tab of your fork, enable
   Actions (GitHub disables workflows in new forks).
2. Settings, Pages, Source: **GitHub Actions**.
3. Settings, Secrets and variables, Actions, Variables: create the repository
   variable `DEPLOY_PAGES` with the value `true`. Without it the workflow only
   runs analysis and tests.
4. Start the workflow "CI and GitHub Pages" by hand (Actions tab, Run
   workflow); later pushes to `master` deploy automatically.
   [`.github/workflows/pages.yml`](.github/workflows/pages.yml) analyzes,
   tests, builds the web version and publishes it.
5. The app is then served at `https://<your-user>.github.io/<repository>/`. If
   the repository is named `<your-user>.github.io`, or you use a custom domain,
   it is served at the root `/` instead.

The page carries a strict Content-Security-Policy (a `<meta>` tag in
[`ultracipher_flutter/web/index.html`](ultracipher_flutter/web/index.html);
GitHub Pages cannot set HTTP headers): scripts and everything else only from
the same origin, network access only to the same origin and
`https://api.github.com`.

Subresource Integrity cannot help here, because Flutter loads
`main.dart.wasm`, `main.dart.mjs` and the engine files dynamically. The
protection comes from hosting it yourself plus the CSP. If you want to check a
deployment, build it yourself and compare the files.

Clickjacking: GitHub Pages sets no HTTP headers, and `frame-ancestors` has no
effect in a `<meta>` CSP, so the page cannot forbid being embedded in a frame.
If you host somewhere that can set headers, add `Content-Security-Policy:
frame-ancestors 'none'` (or `X-Frame-Options: DENY`).

### Limitations of the web version

- **Missing glyphs.** The web build only has Roboto and Source Code Pro. Flutter
  would fetch fallback fonts for other characters from `fonts.gstatic.com`; the
  CSP blocks that on purpose, so nothing is sent to Google. Emoji, CJK,
  Arabic, Hebrew and symbols such as the check mark or the star show up as boxes
  on the web. Umlauts, Cyrillic and Greek work. The stored data is not changed,
  and the native apps are not affected. A fork that accepts the trade-off can add
  `https://fonts.gstatic.com` to `connect-src` in `web/index.html`; Google then
  sees the visitor's IP address and which characters are needed.
- **Key derivation is slow** (about 12 s in a desktop browser, see
  [docs/security.md](docs/security.md)) and needs a lot of memory; mobile
  browsers are not guaranteed to cope.

## Data from older versions

Databases written by earlier app versions are not read, not even with the right
passphrase, and there is no automatic migration. Export a CSV from the old app
("Export CSV" in the open database's menu), then create a new database in the
new app and use "Import CSV". Old local data and old GitHub files are left
untouched.

## Documentation

- [docs/security.md](docs/security.md): key derivation, encryption layers, file
  format, sync, threat model.
- [CHANGELOG.md](CHANGELOG.md)

## License

Ultracipher is free software under the
[GNU General Public License, version 3](LICENSE).

Copyright (C) Paul Burlov

The app bundles Source Code Pro (Copyright 2023 Adobe), licensed under the SIL Open Font License 1.1; the license text is
in
[`ultracipher_flutter/assets/fonts/source_code_pro/OFL.txt`](ultracipher_flutter/assets/fonts/source_code_pro/OFL.txt).
