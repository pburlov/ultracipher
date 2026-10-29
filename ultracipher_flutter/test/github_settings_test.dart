// Tests der GitHub-Einstellungen in core.dart (Plan Schritt 11):
// configureGithub, removeGithub und B4b (Backend-Wechsel aus dem Zustand
// nach einem Settings-Merge). Kein Netz: `resolveOwner` ueber MockClient, die
// Backends ueber die Testnaht backendForSettings (FakeRemoteBackend je Ziel).
// Echte Verschluesselung (Format v1); die KDF-Ableitung ist je Passphrase
// einmal echt und wird danach gemerkt (memoized_key_derivation.dart).
//
// SharedPreferences.setMockInitialValues ist global: zwei "Geraete" laufen
// nacheinander (_freshApp fuer das zweite), nie gleichzeitig.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/backend/github_backend.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

const _pass = 'passphrase A';

GithubSettings _gh(
        {String token = 'tok',
        String repo = 'r',
        String branch = 'main',
        String owner = 'owner1'}) =>
    GithubSettings(token: token, owner: owner, repo: repo, branch: branch);

UltracipherDatabase _dbWith(List<String> labels,
    {GithubSettings? github, DateTime? time}) {
  var db = UltracipherDatabase();
  for (var label in labels) {
    // Id und Zeit aus dem Label: dieselbe Zeile in zwei Datenbanken ist
    // derselbe Eintrag (sonst sind es zwei).
    var entry = Entry(label: label)..createTime = '2020-01-01T00:00:00.000Z';
    db.addEntry(entry: VersionedEntry('id-$label')).addNewVersion(entry);
  }
  if (github != null || time != null) {
    db.setSettings(github: github, time: time);
  }
  return db;
}

List<String> _labels(UltracipherDatabase db) =>
    db.allEntries.map((e) => e.latestEntry!.label).toList()..sort();

DateTime _later() => DateTime.now().add(const Duration(minutes: 5));

Future<UltracipherApp> _freshApp() async {
  SharedPreferences.setMockInitialValues({});
  var app = UltracipherApp();
  await app.init();
  return app;
}

/// `resolveOwner` antwortet mit `owner1`.
http.Client _okClient() => MockClient(
    (_) async => http.Response(jsonEncode({'login': 'owner1'}), 200));

http.Client _statusClient(int status) =>
    MockClient((_) async => http.Response('no', status));

/// Die "Remote-Welt": ein FakeRemoteBackend je Konto/Repo/Branch (nicht je
/// Token), von allen Geraeten geteilt.
class _World {
  final fakes = <String, FakeRemoteBackend>{};
  final built = <GithubSettings>[];

  FakeRemoteBackend at(String repo, {String owner = 'owner1', String branch = 'main'}) =>
      fakes.putIfAbsent('$owner/$repo/$branch', () => FakeRemoteBackend());

  void install(UltracipherApp app) {
    app.backendForSettings = (s, key) {
      if (s == null) return null;
      built.add(s);
      return at(s.repo, owner: s.owner, branch: s.branch);
    };
  }
}

/// Ein [GithubBackend] mit echten Feldern (fuer `_sameTarget`), dessen
/// Lesen/Schreiben ein FakeRemoteBackend uebernimmt.
class _GithubFake extends GithubBackend {
  final FakeRemoteBackend inner;
  bool closed = false;

  _GithubFake(this.inner, GithubSettings s)
      : super(
            owner: s.owner,
            repo: s.repo,
            token: s.token,
            branch: s.branch.isEmpty ? GithubBackend.defaultBranch : s.branch);

  @override
  Future<RemoteData> read(String name) => inner.read(name);

  @override
  Future<String?> write(String name, Uint8List bytes, {String? version}) =>
      inner.write(name, bytes, version: version);

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// Wie [_World.install], aber mit [_GithubFake]s (je Bau ein neues Objekt).
List<_GithubFake> _installGithubFakes(UltracipherApp app, _World world) {
  var all = <_GithubFake>[];
  app.backendForSettings = (s, key) {
    if (s == null) return null;
    var backend = _GithubFake(world.at(s.repo, owner: s.owner), s);
    all.add(backend);
    return backend;
  };
  return all;
}

/// SharedPreferences, deren Schreiben auf Wunsch scheitert.
class _FailingPrefs extends Fake implements SharedPreferences {
  final SharedPreferences inner;
  bool failWrites = false;

  _FailingPrefs(this.inner);

  @override
  String? getString(String key) => inner.getString(key);

  @override
  Future<bool> setString(String key, String value) => failWrites
      ? Future<bool>.error(StateError('disk full'))
      : inner.setString(key, value);

  @override
  bool containsKey(String key) => inner.containsKey(key);

  @override
  Set<String> getKeys() => inner.getKeys();

  @override
  Object? get(String key) => inner.get(key);

  @override
  Future<bool> remove(String key) => inner.remove(key);
}

class _KN {
  final Uint8List key;
  final String name;
  _KN(this.key, this.name);
}

Future<_KN> _keyAndName(UltracipherApp app, String pass) async {
  var key = await app.deriveRoot(pass);
  return _KN(key, databaseName(key));
}

Future<void> _seedLocal(
    UltracipherApp app, _KN kn, UltracipherDatabase db) async {
  await app.storage!.setString(UltracipherApp.localPrefsKey(kn.name),
      base64.encode(UltracipherApp.encryptDatabase(db, kn.key)));
}

UltracipherDatabase _storedDb(UltracipherApp app, _KN kn) =>
    UltracipherApp.decryptDatabase(
        base64.decode(
            app.storage!.getString(UltracipherApp.localPrefsKey(kn.name))!),
        kn.key);

UltracipherDatabase _remoteDb(FakeRemoteBackend fake, _KN kn) =>
    UltracipherApp.decryptDatabase(fake.storedBytes!, kn.key);

void _seedRemote(FakeRemoteBackend fake, _KN kn, UltracipherDatabase db) =>
    fake.seed(UltracipherApp.encryptDatabase(db, kn.key));

Map<String, Object?> _prefs(UltracipherApp app) =>
    {for (var k in app.storage!.getKeys()) k: app.storage!.get(k)};

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}

Future<Object?> _error(Future<Object?> f) async {
  try {
    await f;
  } catch (e) {
    return e;
  }
  return null;
}

/// Oeffnet eine lokale Datenbank mit github-Einstellungen und wartet auf den
/// ersten Sync gegen [world].
Future<_KN> _openWithGithub(UltracipherApp app, _World world,
    UltracipherDatabase local, {SyncState waitFor = SyncState.synced}) async {
  world.install(app);
  var kn = await _keyAndName(app, _pass);
  await _seedLocal(app, kn, local);
  await app.openLocalDatabase(_pass);
  await _until(() => app.syncStatus.value.state == waitFor);
  return kn;
}

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('configureGithub: first configuration and new device', () {
    test('first configuration creates the file, stores the settings and '
        'switches the backend; the token lives only in the database', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      var kn = await _keyAndName(app, _pass);
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'one'));
      await app.saveDatabase();
      var prefsKeysBefore = _prefs(app).keys.toSet();

      var result = await app.configureGithub(
          token: ' tok ', repo: 'r', branch: 'main', httpClient: _okClient());

      var remote = world.at('r');
      expect(result.created, isTrue);
      expect(result.oldLocationError, isNull);
      expect(app.remoteBackend, same(remote));
      expect(app.syncStatus.value.state, SyncState.synced);
      expect(app.hasUnsyncedChanges, isFalse);
      var github = app.loadedDatabase.value!.settings!.github!;
      expect([github.token, github.owner, github.repo, github.branch],
          equals(['tok', 'owner1', 'r', 'main']));
      expect(_labels(_remoteDb(remote, kn)), equals(['one']));
      expect(_remoteDb(remote, kn).settings!.github, github);
      expect(_storedDb(app, kn).settings!.github, github);
      // Keine Zugangsdaten ausserhalb der DB.
      expect(_prefs(app).keys.toSet(), equals(prefsKeysBefore));
    });

    test('defaults: empty repo and branch fall back to ultracipher-data/main',
        () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);

      await app.configureGithub(
          token: 't', repo: '  ', branch: null, httpClient: _okClient());

      expect(world.built.single.repo, GithubBackend.defaultRepo);
      expect(world.built.single.branch, GithubBackend.defaultBranch);
    });

    test('an existing file is merged (new device) and the settings win by '
        'time even against a clock that runs ahead', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      var kn = await _keyAndName(app, _pass);
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'local'));
      await app.saveDatabase();
      var remote = world.at('r');
      var remoteSettingsTime = _later();
      _seedRemote(
          remote,
          kn,
          _dbWith(['remote'],
              github: _gh(token: 'old'), time: remoteSettingsTime));

      var result = await app.configureGithub(
          token: 'new', repo: 'r', branch: 'main', httpClient: _okClient());

      expect(result.created, isFalse);
      var db = app.loadedDatabase.value!;
      expect(_labels(db), equals(['local', 'remote']));
      expect(db.settings!.github!.token, 'new');
      expect(_labels(_remoteDb(remote, kn)), equals(['local', 'remote']));
      expect(_remoteDb(remote, kn).settings!.github!.token, 'new');
      expect(_labels(_storedDb(app, kn)), equals(['local', 'remote']));
      expect(app.syncStatus.value.state, SyncState.synced);

      // A device that still holds the old settings (with the later clock)
      // must adopt the new ones: the explicit change has to be newer than
      // everything it replaced.
      var other = await _freshApp();
      world.install(other);
      await _seedLocal(
          other,
          kn,
          _dbWith(['remote'],
              github: _gh(token: 'old'), time: remoteSettingsTime));
      await other.openLocalDatabase(_pass);
      await _until(() => other.syncStatus.value.state == SyncState.synced);
      expect(other.loadedDatabase.value!.settings!.github!.token, 'new');
    });

    test('an identical remote needs no write', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureGithub(
          token: 't', repo: 'r', branch: 'main', httpClient: _okClient());
      var remote = world.at('r');
      expect(remote.committedWrites, 1);

      var result = await app.configureGithub(
          token: 't', repo: 'r', branch: 'main', httpClient: _okClient());

      expect(result.created, isFalse);
      expect(remote.committedWrites, 1);
      expect(app.syncStatus.value.state, SyncState.synced);
    });

    test('refused without a named session, nothing changes', () async {
      var app = await _freshApp();
      expect(await _error(app.configureGithub(token: 't')), 'No database open');
      await app.createDatabase(_pass);
      expect(await _error(app.configureGithub(token: '  ')),
          'Enter a GitHub token');
      expect(app.loadedDatabase.value!.settings, isNull);
    });
  });

  group('configureGithub: errors store nothing', () {
    Future<void> expectUntouched(UltracipherApp app, _KN kn,
        Map<String, Object?> prefs, UltracipherDatabase db) async {
      expect(_prefs(app), equals(prefs));
      expect(db.settings, isNull);
      expect(app.remoteBackend, isNull);
      expect(app.syncStatus.value.state, SyncState.noRemote);
    }

    test('token rejected by resolveOwner (auth)', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      var kn = await _keyAndName(app, _pass);
      var prefs = _prefs(app);

      var error = await _error(app.configureGithub(
          token: 'bad', httpClient: _statusClient(401)));

      expect(error, isA<RemoteAuthException>());
      expect(world.fakes, isEmpty);
      await expectUntouched(app, kn, prefs, app.loadedDatabase.value!);
    });

    test('token rejected when reading the file (auth)', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      var kn = await _keyAndName(app, _pass);
      var prefs = _prefs(app);
      world.at('r').readFailure = RemoteAuthException('rejected');

      var error = await _error(
          app.configureGithub(token: 'bad', repo: 'r', httpClient: _okClient()));

      expect(error, isA<RemoteAuthException>());
      await expectUntouched(app, kn, prefs, app.loadedDatabase.value!);
    });

    test('network error while reading or writing: nothing stored, the first '
        'configuration can simply be retried', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      var kn = await _keyAndName(app, _pass);
      var prefs = _prefs(app);
      var remote = world.at('r');

      remote.readFailure = RemoteBackendException('down');
      expect(
          await _error(
              app.configureGithub(token: 't', repo: 'r', httpClient: _okClient())),
          isA<RemoteBackendException>());
      remote.readFailure = null;
      remote.writeFailure = RemoteBackendException('down');
      expect(
          await _error(
              app.configureGithub(token: 't', repo: 'r', httpClient: _okClient())),
          isA<RemoteBackendException>());
      await expectUntouched(app, kn, prefs, app.loadedDatabase.value!);
      expect(remote.storedBytes, isNull);

      // Retry: still a first configuration, so it creates.
      remote.writeFailure = null;
      var result = await app.configureGithub(
          token: 't', repo: 'r', httpClient: _okClient());
      expect(result.created, isTrue);
      expect(remote.storedBytes, isNotNull);
    });

    test('an unreadable remote file is an error and is never overwritten',
        () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      var kn = await _keyAndName(app, _pass);
      var prefs = _prefs(app);
      var remote = world.at('r');
      remote.seed(Uint8List.fromList(List.generate(64, (i) => i)));
      var garbage = remote.storedBytes;

      var error = await _error(
          app.configureGithub(token: 't', repo: 'r', httpClient: _okClient()));

      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), isNot(contains('tok')));
      expect(remote.writeCount, 0);
      expect(remote.storedBytes, equals(garbage));
      await expectUntouched(app, kn, prefs, app.loadedDatabase.value!);
    });
  });

  group('configureGithub: authRequired and remoteMissing (E3)', () {
    test('token re-entry after authRequired recovers', () async {
      var app = await _freshApp();
      var world = _World();
      var remote = world.at('r');
      var kn = await _keyAndName(app, _pass);
      _seedRemote(remote, kn, _dbWith(['x']));
      remote.readFailure = RemoteAuthException('rejected');
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()),
          waitFor: SyncState.authRequired);
      remote.readFailure = null;

      var result = await app.configureGithub(
          token: 'fresh', repo: 'r', branch: 'main', httpClient: _okClient());

      expect(result.created, isFalse);
      expect(app.syncStatus.value.state, SyncState.synced);
      expect(app.loadedDatabase.value!.settings!.github!.token, 'fresh');
      expect(_remoteDb(remote, kn).settings!.github!.token, 'fresh');
      expect(_storedDb(app, kn).settings!.github!.token, 'fresh');
    });

    test('token re-entry at a missing file does NOT create; the signal changes '
        'nothing; an explicit confirmCreate then creates', () async {
      var app = await _freshApp();
      var world = _World();
      var remote = world.at('r');
      var kn = await _openWithGithub(
          app, world, _dbWith(['x'], github: _gh()),
          waitFor: SyncState.remoteMissing);
      var prefs = _prefs(app);
      var writesBefore = remote.writeCount;

      var error = await _error(app.configureGithub(
          token: 'fresh', repo: 'r', branch: 'main', httpClient: _okClient()));

      expect(error, isA<GithubFileMissingException>());
      expect(remote.writeCount, writesBefore);
      expect(remote.storedBytes, isNull);
      expect(_prefs(app), equals(prefs));
      expect(app.loadedDatabase.value!.settings!.github!.token, 'tok');
      expect(app.syncStatus.value.state, SyncState.remoteMissing);

      var result = await app.configureGithub(
          token: 'fresh',
          repo: 'r',
          branch: 'main',
          confirmCreate: true,
          httpClient: _okClient());

      expect(result.created, isTrue);
      expect(_remoteDb(remote, kn).settings!.github!.token, 'fresh');
      expect(_labels(_remoteDb(remote, kn)), equals(['x']));
      expect(app.syncStatus.value.state, SyncState.synced);
    });

    test('a normal sync never creates (remoteMissing stays)', () async {
      var app = await _freshApp();
      var world = _World();
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()),
          waitFor: SyncState.remoteMissing);
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'y'));
      await app.saveDatabase();
      expect((await app.syncNow()).state, SyncState.remoteMissing);
      expect(world.at('r').writeCount, 0);
    });
  });

  group('configureGithub: repo switch (E1)', () {
    test('writes the merged database to the new location first, then once to '
        'the old one as forwarding; the old file stays; backend switched',
        () async {
      var app = await _freshApp();
      var world = _World();
      var oldRemote = world.at('r');
      var newRemote = world.at('r2');
      var kn = await _keyAndName(app, _pass);
      _seedRemote(oldRemote, kn, _dbWith(['x']));
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()));
      var order = <String>[];
      oldRemote.beforeWrite = (_) => order.add('old');
      newRemote.beforeWrite = (_) => order.add('new');
      var oldWrites = oldRemote.committedWrites;

      var result = await app.configureGithub(
          token: 'tok', repo: 'r2', branch: 'main', httpClient: _okClient());

      expect(result.created, isTrue);
      expect(result.oldLocationError, isNull);
      expect(order, equals(['new', 'old']));
      expect(app.remoteBackend, same(newRemote));
      expect(_remoteDb(newRemote, kn).settings!.github!.repo, 'r2');
      expect(oldRemote.storedBytes, isNotNull);
      expect(oldRemote.committedWrites, oldWrites + 1);
      expect(_remoteDb(oldRemote, kn).settings!.github!.repo, 'r2');
      expect(_labels(_remoteDb(oldRemote, kn)), equals(['x']));
      expect(app.syncStatus.value.state, SyncState.synced);
      expect(_storedDb(app, kn).settings!.github!.repo, 'r2');
    });

    test('a failing forwarding write does not fail the switch; it is reported',
        () async {
      var app = await _freshApp();
      var world = _World();
      var oldRemote = world.at('r');
      var newRemote = world.at('r2');
      var kn = await _keyAndName(app, _pass);
      _seedRemote(oldRemote, kn, _dbWith(['x']));
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()));
      oldRemote.writeFailure = RemoteBackendException('down');

      var result = await app.configureGithub(
          token: 'tok', repo: 'r2', branch: 'main', httpClient: _okClient());

      expect(result.oldLocationError, isA<RemoteBackendException>());
      expect(app.remoteBackend, same(newRemote));
      expect(_remoteDb(newRemote, kn).settings!.github!.repo, 'r2');
      expect(_remoteDb(oldRemote, kn).settings!.github!.repo, 'r');
      expect(app.loadedDatabase.value!.settings!.github!.repo, 'r2');
    });

    test('a branch change counts as a switch and creates at the new location',
        () async {
      var app = await _freshApp();
      var world = _World();
      var kn = await _keyAndName(app, _pass);
      _seedRemote(world.at('r'), kn, _dbWith(['x']));
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()));

      var result = await app.configureGithub(
          token: 'tok', repo: 'r', branch: 'dev', httpClient: _okClient());

      expect(result.created, isTrue);
      expect(_remoteDb(world.at('r', branch: 'dev'), kn).settings!.github!.branch,
          'dev');
    });

    test('a token-only change is no switch: no forwarding write', () async {
      var app = await _freshApp();
      var world = _World();
      var remote = world.at('r');
      var kn = await _keyAndName(app, _pass);
      _seedRemote(remote, kn, _dbWith(['x']));
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()));
      var writes = remote.committedWrites;

      await app.configureGithub(
          token: 'other', repo: 'r', branch: 'main', httpClient: _okClient());

      // Exactly the one write of the new token, no forwarding on top.
      expect(remote.committedWrites, writes + 1);
    });

    test('another device follows the forwarding file to the new location',
        () async {
      var world = _World();
      var oldRemote = world.at('r');
      var newRemote = world.at('r2');
      var kn = await _keyAndName(await _freshApp(), _pass);
      _seedRemote(oldRemote, kn, _dbWith(['x']));
      // Device A switches.
      var a = await _freshApp();
      await _openWithGithub(a, world, _dbWith(['x'], github: _gh()));
      await a.configureGithub(
          token: 'tok', repo: 'r2', branch: 'main', httpClient: _okClient());
      // Device B still points to the old repo (its copy carries the old
      // settings, which are older than A's).
      var b = await _freshApp();
      var oldSettings = _dbWith(['x'], github: _gh(), time: DateTime(2020));
      world.install(b);
      await _seedLocal(b, kn, oldSettings);
      await b.openLocalDatabase(_pass);
      await _until(() => b.remoteBackend == newRemote);
      await _until(() => b.syncStatus.value.state == SyncState.synced);

      expect(b.loadedDatabase.value!.settings!.github!.repo, 'r2');
      expect(newRemote.readCount, greaterThan(0));
    });
    test('the old location is read and merged: an entry of another device '
        'reaches memory, the local copy, the old file and the new file',
        () async {
      var app = await _freshApp();
      var world = _World();
      var oldRemote = world.at('r');
      var newRemote = world.at('r2');
      var kn = await _keyAndName(app, _pass);
      _seedRemote(oldRemote, kn, _dbWith(['x']));
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()));
      // Device B wrote to the old file; this device has not seen it.
      _seedRemote(oldRemote, kn,
          _dbWith(['x', 'fromB'], github: _gh(), time: DateTime(2020)));

      var result = await app.configureGithub(
          token: 'tok', repo: 'r2', branch: 'main', httpClient: _okClient());
      await _until(() =>
          app.syncStatus.value.state == SyncState.synced &&
          _labels(_remoteDb(newRemote, kn)).length == 2);

      expect(result.oldLocationError, isNull);
      expect(_labels(app.loadedDatabase.value!), equals(['fromB', 'x']));
      expect(_labels(_storedDb(app, kn)), equals(['fromB', 'x']));
      expect(_labels(_remoteDb(oldRemote, kn)), equals(['fromB', 'x']));
      expect(_remoteDb(oldRemote, kn).settings!.github!.repo, 'r2');
      expect(_labels(_remoteDb(newRemote, kn)), equals(['fromB', 'x']));
    });

    test('a conflict while forwarding is retried (read, merge, write)',
        () async {
      var app = await _freshApp();
      var world = _World();
      var oldRemote = world.at('r');
      var kn = await _keyAndName(app, _pass);
      _seedRemote(oldRemote, kn, _dbWith(['x']));
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()));
      oldRemote.conflictAtWrite.add(oldRemote.writeCount + 1);
      var writes = oldRemote.writeCount;

      var result = await app.configureGithub(
          token: 'tok', repo: 'r2', branch: 'main', httpClient: _okClient());

      expect(result.oldLocationError, isNull);
      expect(oldRemote.writeCount, writes + 2);
      expect(_remoteDb(oldRemote, kn).settings!.github!.repo, 'r2');
    });

    test('a save that waits for the key while the backend is swapped is not '
        'invalidated', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      var kn = await _keyAndName(app, _pass);
      var remote = world.at('r');
      var gate = Completer<void>();
      remote.writeGate = gate;
      var configure = app.configureGithub(
          token: 't', repo: 'r', branch: 'main', httpClient: _okClient());
      await _until(() => remote.writeCount == 1);
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'during'));

      // The commit of configureGithub follows within microtasks, the save is
      // still deriving its key by then.
      gate.complete();
      var save = app.saveDatabase();
      expect(await save, isTrue);
      await configure;

      var github = app.loadedDatabase.value!.settings!.github!;
      expect(_labels(_storedDb(app, kn)), equals(['during']));
      expect(_storedDb(app, kn).settings!.github, github);
    });

    test('a failing configuration releases the new backend', () async {
      var app = await _freshApp();
      var world = _World();
      var backends = _installGithubFakes(app, world);
      await app.createDatabase(_pass);
      world.at('r').readFailure = RemoteAuthException('rejected');

      await _error(app.configureGithub(
          token: 't', repo: 'r', httpClient: _okClient()));

      expect(backends.single.closed, isTrue);
    });

    test('a failing local save after the swap closes the old backend and '
        'leaves the session consistent (remote and memory ahead of the copy)',
        () async {
      var app = await _freshApp();
      var world = _World();
      var kn = await _keyAndName(app, _pass);
      _seedRemote(world.at('r'), kn, _dbWith(['x']));
      var backends = _installGithubFakes(app, world);
      await _seedLocal(app, kn, _dbWith(['x'], github: _gh()));
      await app.openLocalDatabase(_pass);
      await _until(() => app.syncStatus.value.state == SyncState.synced);
      var prefs = _FailingPrefs(app.storage!);
      app.storage = prefs;
      prefs.failWrites = true;

      var error = await _error(app.configureGithub(
          token: 'tok', repo: 'r2', branch: 'main', httpClient: _okClient()));

      expect(error, isA<StateError>());
      expect(backends[0].closed, isTrue);
      expect(app.remoteBackend, same(backends.last));
      expect(backends.last.closed, isFalse);
      expect(_remoteDb(world.at('r2'), kn).settings!.github!.repo, 'r2');
      expect(app.loadedDatabase.value!.settings!.github!.repo, 'r2');
      expect(app.syncStatus.value.state, SyncState.notSynced);
      expect(_storedDb(app, kn).settings!.github!.repo, 'r');

      // The next save brings the copy up to date.
      prefs.failWrites = false;
      await app.saveDatabase();
      expect(_storedDb(app, kn).settings!.github!.repo, 'r2');
    });
  });

  group('configureGithub: a sync of the old backend that is still running', () {
    // Holds a sync of the old location at its write (gate) and starts
    // configureGithub to r2 on top of it. Returns once the new backend is in
    // place; the forwarding write to the old location is then waiting at the
    // same gate.
    Future<Future<GithubSettingsResult>> switchDuringHeldSync(
        UltracipherApp app, _World world, Completer<void> gate) async {
      var oldRemote = world.at('r');
      var newRemote = world.at('r2');
      var kn = await _keyAndName(app, _pass);
      _seedRemote(oldRemote, kn, _dbWith(['x']));
      await _openWithGithub(app, world, _dbWith(['x'], github: _gh()));
      oldRemote.writeGate = gate;
      var writes = oldRemote.writeCount;
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'held'));
      await app.saveDatabase();
      await _until(() => oldRemote.writeCount == writes + 1);
      var configure = app.configureGithub(
          token: 'tok', repo: 'r2', branch: 'main', httpClient: _okClient());
      await _until(() => app.remoteBackend == newRemote);
      return configure;
    }

    test('the abandoned run neither switches the backend back nor overwrites '
        'the status when it returns', () async {
      var app = await _freshApp();
      var world = _World();
      var gate = Completer<void>();
      var configure = await switchDuringHeldSync(app, world, gate);
      expect(app.syncStatus.value.state, SyncState.synced);

      // Both waiting writes (old run, forwarding) fail once released.
      world.at('r').writeFailure = RemoteBackendException('down');
      gate.complete();
      var result = await configure;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(result.oldLocationError, isA<RemoteBackendException>());
      expect(app.remoteBackend, same(world.at('r2')));
      expect(app.syncStatus.value.state, SyncState.synced);
      expect(app.syncStatus.value.error, isNull);
    });

    test('it does not block the first sync of the new backend', () async {
      var app = await _freshApp();
      var world = _World();
      var gate = Completer<void>();
      var configure = await switchDuringHeldSync(app, world, gate);

      // The old run still hangs at its write.
      var status = await app.syncNow().timeout(const Duration(seconds: 5));

      expect(status.state, SyncState.synced);
      expect(world.at('r2').readCount, greaterThan(0));
      gate.complete();
      await configure;
    });
  });

  group('removeGithub', () {
    test('writes github:null to the remote, drops the backend, noRemote, saved '
        'locally; a second device then goes noRemote by merge', () async {
      var world = _World();
      var remote = world.at('r');
      var a = await _freshApp();
      var kn = await _keyAndName(a, _pass);
      _seedRemote(remote, kn, _dbWith(['x']));
      await _openWithGithub(a, world, _dbWith(['x'], github: _gh()));

      var result = await a.removeGithub();

      expect(result.oldLocationError, isNull);
      expect(a.remoteBackend, isNull);
      expect(a.syncStatus.value.state, SyncState.noRemote);
      expect(a.loadedDatabase.value!.settings!.github, isNull);
      expect(_storedDb(a, kn).settings!.github, isNull);
      expect(_remoteDb(remote, kn).settings, isNotNull);
      expect(_remoteDb(remote, kn).settings!.github, isNull);
      // Saving still works without a backend (B4a).
      a.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'y'));
      expect(await a.saveDatabase(), isTrue);
      var writes = remote.writeCount;

      // Device B: still has GitHub in its (older) copy.
      var b = await _freshApp();
      world.install(b);
      await _seedLocal(b, kn, _dbWith(['x'], github: _gh(), time: DateTime(2020)));
      await b.openLocalDatabase(_pass);
      await _until(() => b.syncStatus.value.state == SyncState.noRemote);

      expect(b.remoteBackend, isNull);
      expect(b.loadedDatabase.value!.settings!.github, isNull);
      expect(_storedDb(b, kn).settings!.github, isNull);
      expect(remote.writeCount, writes);
    });

    test('offline or rejected token: removed locally anyway and the failure '
        'is reported', () async {
      var world = _World();
      var remote = world.at('r');
      var a = await _freshApp();
      var kn = await _keyAndName(a, _pass);
      _seedRemote(remote, kn, _dbWith(['x']));
      await _openWithGithub(a, world, _dbWith(['x'], github: _gh()));
      remote.readFailure = RemoteAuthException('rejected');

      var result = await a.removeGithub();

      expect(result.oldLocationError, isA<RemoteAuthException>());
      expect(a.remoteBackend, isNull);
      expect(a.syncStatus.value.state, SyncState.noRemote);
      expect(_storedDb(a, kn).settings!.github, isNull);
      expect(_remoteDb(remote, kn).settings!.github, isNotNull);
    });

    test('B1: settings from a clock that runs ahead come back with the sync; '
        'removal is repeated with the merged time, settings and backend agree',
        () async {
      var world = _World();
      var remote = world.at('r');
      var a = await _freshApp();
      var kn = await _keyAndName(a, _pass);
      // Not merged yet: the first sync fails.
      remote.readFailure = RemoteBackendException('down');
      await _openWithGithub(a, world, _dbWith(['x'], github: _gh()),
          waitFor: SyncState.notSynced);
      remote.readFailure = null;
      var future = DateTime.now().add(const Duration(days: 1));
      _seedRemote(remote, kn, _dbWith(['x'], github: _gh(), time: future));

      var result = await a.removeGithub();

      expect(result.oldLocationError, isNull);
      expect(a.loadedDatabase.value!.settings!.github, isNull);
      expect(a.remoteBackend, isNull);
      expect(a.syncStatus.value.state, SyncState.noRemote);
      expect(_remoteDb(remote, kn).settings!.github, isNull);
      expect(_remoteDb(remote, kn).settings!.time.isAfter(future), isTrue);
      expect(_storedDb(a, kn).settings!.github, isNull);
    });

    test('a failing local save changes nothing: no in-memory-only removal',
        () async {
      var world = _World();
      var remote = world.at('r');
      var a = await _freshApp();
      var kn = await _keyAndName(a, _pass);
      _seedRemote(remote, kn, _dbWith(['x']));
      await _openWithGithub(a, world, _dbWith(['x'], github: _gh()));
      var prefs = _FailingPrefs(a.storage!);
      a.storage = prefs;
      prefs.failWrites = true;
      var writes = remote.writeCount;

      var error = await _error(a.removeGithub());

      expect(error, isA<StateError>());
      expect(a.loadedDatabase.value!.settings!.github, isNotNull);
      expect(a.remoteBackend, isNotNull);
      expect(_storedDb(a, kn).settings!.github, isNotNull);
      expect(remote.writeCount, writes);
    });

    test('is a no-op without GitHub; refused without a session', () async {
      var app = await _freshApp();
      expect(await _error(app.removeGithub()), 'No database open');
      await app.createDatabase(_pass);
      var prefs = _prefs(app);
      var result = await app.removeGithub();
      expect(result.oldLocationError, isNull);
      expect(_prefs(app), equals(prefs));
      expect(app.loadedDatabase.value!.settings, isNull);
    });

    test('configuring again after removal is a first configuration (creates)',
        () async {
      var world = _World();
      var a = await _freshApp();
      var kn = await _keyAndName(a, _pass);
      _seedRemote(world.at('r'), kn, _dbWith(['x']));
      await _openWithGithub(a, world, _dbWith(['x'], github: _gh()));
      await a.removeGithub();
      world.at('r').deleteFile();

      var result = await a.configureGithub(
          token: 't', repo: 'r', branch: 'main', httpClient: _okClient());

      expect(result.created, isTrue);
      expect(a.syncStatus.value.state, SyncState.synced);
    });
  });

  group('B4b: the backend follows the merged settings', () {
    test('settings of another device switch the backend, the old one is '
        'closed and the new location is read', () async {
      var app = await _freshApp();
      var world = _World();
      var kn = await _keyAndName(app, _pass);
      var oldRemote = world.at('r');
      var newRemote = world.at('r2');
      _seedRemote(oldRemote, kn,
          _dbWith(['x'], github: _gh(repo: 'r2'), time: _later()));
      _seedRemote(newRemote, kn, _dbWith(['x']));
      var backends = _installGithubFakes(app, world);
      await _seedLocal(app, kn, _dbWith(['x'], github: _gh()));

      await app.openLocalDatabase(_pass);
      await _until(() => backends.length == 2);
      await _until(() => app.syncStatus.value.state == SyncState.synced);

      expect((app.remoteBackend as GithubBackend).repo, 'r2');
      expect(app.remoteBackend, same(backends[1]));
      expect(backends[0].closed, isTrue);
      expect(backends[1].closed, isFalse);
      expect(newRemote.readCount, greaterThan(0));
    });

    test('the same github with a newer time is no switch (no rebuild)',
        () async {
      var app = await _freshApp();
      var world = _World();
      var kn = await _keyAndName(app, _pass);
      _seedRemote(world.at('r'), kn,
          _dbWith(['x'], github: _gh(), time: _later()));
      var backends = _installGithubFakes(app, world);
      await _seedLocal(app, kn, _dbWith(['x'], github: _gh()));

      await app.openLocalDatabase(_pass);
      await _until(() => app.syncStatus.value.state == SyncState.synced);

      expect(backends.length, 1);
      expect(app.remoteBackend, same(backends.single));
      expect(backends.single.closed, isFalse);
    });

    test('an explicit branch equal to the default is no fake switch', () async {
      var app = await _freshApp();
      var world = _World();
      var kn = await _keyAndName(app, _pass);
      // Local settings carry no branch (backend falls back to the default);
      // the other device wrote the explicit default.
      _seedRemote(world.at('r'), kn,
          _dbWith(['x'], github: _gh(branch: 'main'), time: _later()));
      var backends = _installGithubFakes(app, world);
      await _seedLocal(app, kn, _dbWith(['x'], github: _gh(branch: '')));

      await app.openLocalDatabase(_pass);
      await _until(() => app.syncStatus.value.state == SyncState.synced);

      var first = backends.first;
      expect(app.remoteBackend, same(first));
      expect(first.closed, isFalse);
      // The rebuilt one was released, nothing else switched.
      expect(backends.length, 2);
      expect(backends[1].closed, isTrue);
      expect(app.loadedDatabase.value!.settings!.github!.branch, 'main');
    });

    test('a failed write after the merge still switches on the next '
        'successful run (derived from the state, not from the delta)',
        () async {
      var app = await _freshApp();
      var world = _World();
      var kn = await _keyAndName(app, _pass);
      var oldRemote = world.at('r');
      var newRemote = world.at('r2');
      _seedRemote(oldRemote, kn,
          _dbWith(['x'], github: _gh(repo: 'r2'), time: _later()));
      _seedRemote(newRemote, kn, _dbWith(['x']));
      oldRemote.writeFailure = RemoteBackendException('down');
      var backends = _installGithubFakes(app, world);
      // A local-only change forces a write in the first run.
      await _seedLocal(
          app, kn, _dbWith(['x', 'local'], github: _gh()));

      await app.openLocalDatabase(_pass);
      await _until(() => app.syncStatus.value.state == SyncState.notSynced);

      // The merge happened, the write failed: no switch yet.
      expect(app.loadedDatabase.value!.settings!.github!.repo, 'r2');
      expect((app.remoteBackend as GithubBackend).repo, 'r');
      expect(backends.length, 1);

      oldRemote.writeFailure = null;
      await app.syncNow();
      await _until(() => app.syncStatus.value.state == SyncState.synced);

      expect((app.remoteBackend as GithubBackend).repo, 'r2');
      expect(backends[0].closed, isTrue);
      expect(_labels(_remoteDb(newRemote, kn)), equals(['local', 'x']));
    });

    test('a merged github:null drops the backend once the run succeeded',
        () async {
      var app = await _freshApp();
      var world = _World();
      var kn = await _keyAndName(app, _pass);
      var remoteDb = _dbWith(['x'], github: _gh());
      remoteDb.setSettings(github: null, time: _later());
      _seedRemote(world.at('r'), kn, remoteDb);
      var backends = _installGithubFakes(app, world);
      await _seedLocal(app, kn, _dbWith(['x'], github: _gh()));

      await app.openLocalDatabase(_pass);
      await _until(() => app.syncStatus.value.state == SyncState.noRemote);

      expect(app.remoteBackend, isNull);
      expect(backends.single.closed, isTrue);
    });
  });
}
