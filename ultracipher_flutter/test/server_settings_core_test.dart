// Tests des Sync-Servers (REST) in core.dart: configureServer, removeRemote,
// Wechsel GitHub <-> Server, Settings-Merge von einem anderen Geraet,
// Passwortwechsel ueber DELETE. Das Netz ist der protokolltreue
// FakeRestServer (MockClient) fuer den Server und ein FakeRemoteBackend fuer
// GitHub; kein echtes Netz, auch die Neubauten der Sitzung laufen ueber die
// Naht serverBackendForSettings.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/backend/rest_backend.dart';
import 'package:ultracipher_flutter/src/commons.dart' show describeError;
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'fake_local_store.dart';
import 'fake_remote_backend.dart';
import 'fake_rest_server.dart';
import 'memoized_key_derivation.dart';

const _pass = 'passphrase A';
const _url = 'https://sync.example.test/ucdb';
const _url2 = 'https://other.example.test/ucdb';

Future<UltracipherApp> _freshApp() async {
  SharedPreferences.setMockInitialValues({});
  var app = UltracipherApp();
  await app.init();
  return app;
}

http.Client _ghClient() => MockClient(
    (_) async => http.Response(jsonEncode({'login': 'owner1'}), 200));

/// Die "Welt": ein REST-Server und ein GitHub-Fake, von allen Geraeten geteilt.
class _World {
  final server = FakeRestServer();
  final github = FakeRemoteBackend();
  final restBuilt = <String>[];
  int githubBuilt = 0;

  void install(UltracipherApp app) {
    app.backendForSettings = (s, key) {
      if (s == null) return null;
      githubBuilt++;
      return github;
    };
    app.serverBackendForSettings = (s, key) {
      restBuilt.add(s.url);
      return RestBackend(url: s.url, client: server.client, log: app.syncLog);
    };
  }
}

Future<String> _name(UltracipherApp app, String pass) async =>
    databaseName(await app.deriveRoot(pass));

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

void _addEntry(UltracipherApp app, String label) {
  var entry = Entry(label: label)..createTime = '2020-01-01T00:00:00.000Z';
  app.loadedDatabase.value!
      .addEntry(entry: VersionedEntry('id-$label'))
      .addNewVersion(entry);
}

List<String> _labels(UltracipherDatabase db) =>
    db.allEntries.map((e) => e.latestEntry!.label).toList()..sort();

Future<UltracipherDatabase> _serverDb(
    UltracipherApp app, _World world, String pass) async {
  var key = await app.deriveRoot(pass);
  return UltracipherApp.decryptDatabase(
      world.server.stored(databaseName(key))!, key);
}

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('configureServer: first configuration and new device', () {
    test('first configuration creates the file with raw bytes, stores the '
        'settings and switches the backend', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      _addEntry(app, 'one');
      await app.saveDatabase();
      var name = await _name(app, _pass);

      var result = await app.configureServer(url: ' $_url/ ');

      expect(result.created, isTrue);
      expect(result.oldLocationError, isNull);
      expect(app.remoteBackend, isA<RestBackend>());
      expect(app.remoteBackend!.displayName, 'Sync server');
      expect(app.syncStatus.value.state, SyncState.synced);
      var settings = app.loadedDatabase.value!.settings!;
      expect(settings.server, ServerSettings(url: _url));
      expect(settings.github, isNull);
      expect(world.restBuilt, [_url]);
      // Die Bytes auf dem Server sind der Chiffretext (Magic UCDB), nicht base64.
      expect(utf8.decode(world.server.stored(name)!.sublist(0, 4)), 'UCDB');
      expect(_labels(await _serverDb(app, world, _pass)), ['one']);
      expect((await _serverDb(app, world, _pass)).settings!.server,
          ServerSettings(url: _url));
      var put = world.server.requests.firstWhere((r) => r.method == 'PUT');
      expect(put.headers['If-None-Match'], '*');
      expect(put.headers['Content-Type'], 'application/octet-stream');
    });

    test('without the test seam the session gets a real RestBackend over '
        'the injected client, logging into the app log', () async {
      var app = await _freshApp();
      var server = FakeRestServer();
      await app.createDatabase(_pass);

      await app.configureServer(url: _url, httpClient: server.client);

      var backend = app.remoteBackend;
      expect(backend, isA<RestBackend>());
      expect((backend as RestBackend).log, same(app.syncLog));
      expect(backend.url, _url);
      expect(server.requests.any((r) => r.method == 'PUT'), isTrue);
      // Kein Neubau mit dem Standard-Client, bevor die Sitzung endet.
      app.closeDatabase();
    });

    test('an invalid URL is refused with a message and changes nothing',
        () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      for (var bad in [
        '',
        'example.test/ucdb',
        'http://example.test/ucdb',
        'https://example.test/ucdb?x=1',
        'https://user:pw@example.test/ucdb',
      ]) {
        var error = await _error(app.configureServer(url: bad));
        expect(error, isA<String>(), reason: bad);
        expect(describeError(error!), error);
      }
      expect(app.loadedDatabase.value!.settings, isNull);
      expect(app.remoteBackend, isNull);
      expect(world.server.requests, isEmpty);
      expect(world.restBuilt, isEmpty);
    });

    test('http://localhost is accepted (emulator)', () async {
      var app = await _freshApp();
      _World().install(app);
      await app.createDatabase(_pass);
      await app.configureServer(url: 'http://localhost:5001/p/us-central1/ucdb');
      expect(app.loadedDatabase.value!.settings!.server!.url,
          'http://localhost:5001/p/us-central1/ucdb');
    });

    test('no database open', () async {
      var app = await _freshApp();
      expect(await _error(app.configureServer(url: _url)), 'No database open');
    });

    test('a second device finds the file and merges it, nothing is created',
        () async {
      var world = _World();
      var a = await _freshApp();
      world.install(a);
      await a.createDatabase(_pass);
      _addEntry(a, 'from-a');
      await a.configureServer(url: _url);

      var b = await _freshApp();
      world.install(b);
      await b.createDatabase(_pass);
      _addEntry(b, 'from-b');
      var result = await b.configureServer(url: _url);

      expect(result.created, isFalse);
      expect(_labels(b.loadedDatabase.value!), ['from-a', 'from-b']);
      expect(_labels(await _serverDb(b, world, _pass)), ['from-a', 'from-b']);
      expect(b.syncStatus.value.state, SyncState.synced);
    });

    test('a file of another passphrase-derived name that cannot be read is '
        'never overwritten', () async {
      var world = _World();
      var a = await _freshApp();
      world.install(a);
      await a.createDatabase(_pass);
      var name = await _name(a, _pass);
      world.server.seed(name, junk());
      var before = world.server.stored(name);

      var error = await _error(a.configureServer(url: _url));

      expect(error, isA<RemoteBackendException>());
      expect(world.server.stored(name), before);
      expect(a.remoteBackend, isNull);
      expect(a.loadedDatabase.value!.settings, isNull);
    });

    test('a network or server error leaves the state unchanged', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      world.server.failWith = 500;

      var error = await _error(app.configureServer(url: _url));

      expect(error, isA<RemoteBackendException>());
      expect((error as RemoteBackendException).statusCode, 500);
      expect(app.remoteBackend, isNull);
      expect(app.loadedDatabase.value!.settings, isNull);
      expect(app.syncStatus.value.state, SyncState.noRemote);
    });
  });

  group('configureServer: a missing file needs confirmation after the first '
      'setup', () {
    test('same URL again while the file is gone: ServerFileMissingException '
        'without any change; confirmCreate creates it', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureServer(url: _url);
      var name = await _name(app, _pass);
      var settingsBefore = app.loadedDatabase.value!.settings;
      world.server.deleteFile(name);

      var error = await _error(app.configureServer(url: _url));

      expect(error, isA<ServerFileMissingException>());
      expect(error, isA<RemoteFileMissingException>());
      expect(describeError(error!), error.toString());
      expect(error.toString(), contains('the sync server'));
      expect(world.server.stored(name), isNull);
      expect(app.loadedDatabase.value!.settings, settingsBefore);

      var result = await app.configureServer(url: _url, confirmCreate: true);
      expect(result.created, isTrue);
      expect(world.server.stored(name), isNotNull);
    });

    test('the same URL in another spelling is not a move: the missing file '
        'still needs confirmation', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureServer(url: _url);
      var name = await _name(app, _pass);
      expect(app.loadedDatabase.value!.settings!.server!.url, _url);
      world.server.deleteFile(name);

      for (var spelling in [
        'HTTPS://Sync.Example.test/ucdb',
        'https://sync.example.test/a/../ucdb/',
        'https://sync.example.test:443/ucdb',
      ]) {
        var error = await _error(app.configureServer(url: spelling));
        expect(error, isA<ServerFileMissingException>(), reason: spelling);
      }
      expect(world.server.stored(name), isNull);
      expect(app.loadedDatabase.value!.settings!.server!.url, _url);
    });

    test('a stored URL in another spelling (from elsewhere) is compared '
        'canonically too', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      var key = await app.deriveRoot(_pass);
      var name = databaseName(key);
      var db = UltracipherDatabase()
        ..setSettings(server: ServerSettings(url: 'HTTPS://Sync.Example.test/ucdb/'));
      await seedLocal(app, name, UltracipherApp.encryptDatabase(db, key));
      await app.openLocalDatabase(_pass);
      await _until(
          () => app.syncStatus.value.state == SyncState.remoteMissing);

      var error = await _error(app.configureServer(url: _url));

      expect(error, isA<ServerFileMissingException>());
      expect(world.server.stored(name), isNull);
    });

    test('a normal sync never creates the file: remoteMissing', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureServer(url: _url);
      var name = await _name(app, _pass);
      world.server.deleteFile(name);

      var status = await app.syncNow();

      expect(status.state, SyncState.remoteMissing);
      expect(status.error, contains('the sync server'));
      expect(world.server.stored(name), isNull);
      expect(world.server.requests.last.method, 'GET');
    });

    test('a different URL counts as a move: created without asking, the old '
        'place gets a forward copy with the new settings', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      _addEntry(app, 'one');
      await app.configureServer(url: _url);
      var name = await _name(app, _pass);
      // Zweiter Server fuer die zweite URL.
      var second = FakeRestServer();
      app.serverBackendForSettings = (s, key) => RestBackend(
          url: s.url,
          client: (s.url == _url2 ? second : world.server).client,
          log: app.syncLog);

      var result = await app.configureServer(url: _url2);

      expect(result.created, isTrue);
      expect(result.oldLocationError, isNull);
      expect(second.stored(name), isNotNull);
      expect(app.loadedDatabase.value!.settings!.server!.url, _url2);
      // Die Datei am alten Ort bleibt und traegt die neuen Einstellungen.
      var key = await app.deriveRoot(_pass);
      var old = UltracipherApp.decryptDatabase(world.server.stored(name)!, key);
      expect(old.settings!.server!.url, _url2);
      expect(_labels(old), ['one']);
    });
  });

  group('switching between GitHub and the sync server', () {
    test('GitHub -> server: created without asking, forward copy on GitHub '
        'carries the server and no github', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      _addEntry(app, 'one');
      await app.configureGithub(token: 'tok', repo: 'r', httpClient: _ghClient());
      expect(app.remoteBackend, same(world.github));
      var name = await _name(app, _pass);
      var key = await app.deriveRoot(_pass);

      var result = await app.configureServer(url: _url);

      expect(result.created, isTrue);
      expect(result.oldLocationError, isNull);
      expect(app.remoteBackend, isA<RestBackend>());
      var settings = app.loadedDatabase.value!.settings!;
      expect(settings.github, isNull);
      expect(settings.server, ServerSettings(url: _url));
      expect(world.server.stored(name), isNotNull);
      var forwarded = UltracipherApp.decryptDatabase(world.github.storedBytes!, key);
      expect(forwarded.settings!.github, isNull);
      expect(forwarded.settings!.server, ServerSettings(url: _url));
      expect(_labels(forwarded), ['one']);
      expect(app.syncStatus.value.state, SyncState.synced);
    });

    test('server -> GitHub: created without asking, forward copy on the '
        'server carries github and no server', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      _addEntry(app, 'one');
      await app.configureServer(url: _url);
      var name = await _name(app, _pass);
      var key = await app.deriveRoot(_pass);

      var result = await app.configureGithub(
          token: 'tok', repo: 'r', httpClient: _ghClient());

      expect(result.created, isTrue);
      expect(result.oldLocationError, isNull);
      expect(app.remoteBackend, same(world.github));
      var settings = app.loadedDatabase.value!.settings!;
      expect(settings.server, isNull);
      expect(settings.github, isNotNull);
      var forwarded = UltracipherApp.decryptDatabase(world.server.stored(name)!, key);
      expect(forwarded.settings!.server, isNull);
      expect(forwarded.settings!.github!.repo, 'r');
    });

    test('a failing forward does not undo the switch', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureGithub(token: 'tok', repo: 'r', httpClient: _ghClient());
      world.github.writeFailure = RemoteBackendException('down');

      var result = await app.configureServer(url: _url);

      expect(result.created, isTrue);
      expect(result.oldLocationError, isA<RemoteBackendException>());
      expect(app.remoteBackend, isA<RestBackend>());
    });

    test('a database that has both set takes GitHub; configuring the server '
        'clears github', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      var key = await app.deriveRoot(_pass);
      var name = databaseName(key);
      var db = UltracipherDatabase()
        ..setSettings(
            github: GithubSettings(
                token: 't', owner: 'o', repo: 'r', branch: 'main'),
            server: ServerSettings(url: _url));
      world.github.seed(UltracipherApp.encryptDatabase(db, key));
      await seedLocal(app, name, UltracipherApp.encryptDatabase(db, key));

      await app.openLocalDatabase(_pass);
      await _until(() => app.syncStatus.value.state == SyncState.synced);

      expect(app.remoteBackend, same(world.github));
      expect(world.restBuilt, isEmpty);
      expect(world.server.requests, isEmpty);

      await app.configureServer(url: _url);

      var settings = app.loadedDatabase.value!.settings!;
      expect(settings.github, isNull);
      expect(settings.server, ServerSettings(url: _url));
      expect(app.remoteBackend, isA<RestBackend>());
    });

    test('another device that changed GitHub -> server: this device follows '
        'with its next sync and rebuilds the backend', () async {
      var world = _World();
      var a = await _freshApp();
      world.install(a);
      await a.createDatabase(_pass);
      _addEntry(a, 'from-a');
      await a.configureGithub(token: 'tok', repo: 'r', httpClient: _ghClient());
      expect(a.remoteBackend, same(world.github));

      var b = await _freshApp();
      world.install(b);
      await b.createDatabase(_pass);
      await b.configureGithub(token: 'tok', repo: 'r', httpClient: _ghClient());
      _addEntry(b, 'from-b');
      await b.configureServer(url: _url);
      expect(b.remoteBackend, isA<RestBackend>());

      // A sieht die Weiterleitung auf GitHub und wechselt auf den Server.
      var status = await a.syncNow();
      await _until(() =>
          a.remoteBackend is RestBackend &&
          a.syncStatus.value.state == SyncState.synced);

      expect(status.state, isNot(SyncState.authRequired));
      var settings = a.loadedDatabase.value!.settings!;
      expect(settings.server, ServerSettings(url: _url));
      expect(settings.github, isNull);
      expect(_labels(a.loadedDatabase.value!), ['from-a', 'from-b']);
      expect(world.restBuilt, contains(_url));
    });

    test('settings merged from the server file to "removed" switch to no '
        'backend', () async {
      var world = _World();
      var a = await _freshApp();
      world.install(a);
      await a.createDatabase(_pass);
      await a.configureServer(url: _url);

      var b = await _freshApp();
      world.install(b);
      await b.createDatabase(_pass);
      await b.configureServer(url: _url);
      await b.removeRemote();
      expect(b.remoteBackend, isNull);

      await a.syncNow();

      expect(a.remoteBackend, isNull);
      expect(a.syncStatus.value.state, SyncState.noRemote);
      expect(a.loadedDatabase.value!.settings!.server, isNull);
    });
  });

  group('removeRemote', () {
    test('removes the server: both fields null, no backend, the file stays, '
        'removeGithub forwards', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureServer(url: _url);
      var name = await _name(app, _pass);

      var result = await app.removeRemote();

      expect(result.oldLocationError, isNull);
      expect(app.remoteBackend, isNull);
      expect(app.syncStatus.value.state, SyncState.noRemote);
      var settings = app.loadedDatabase.value!.settings!;
      expect(settings.server, isNull);
      expect(settings.github, isNull);
      expect(world.server.stored(name), isNotNull);
      // Die Datei traegt "entfernt", damit andere Geraete es erfahren.
      var key = await app.deriveRoot(_pass);
      var onServer = UltracipherApp.decryptDatabase(world.server.stored(name)!, key);
      expect(onServer.settings!.server, isNull);
      expect(onServer.settings!.time, settings.time);

      // Nichts mehr zu tun.
      var again = await app.removeGithub();
      expect(again.oldLocationError, isNull);
    });

    test('removeRemote also removes GitHub', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureGithub(token: 'tok', repo: 'r', httpClient: _ghClient());

      await app.removeRemote();

      expect(app.remoteBackend, isNull);
      expect(app.loadedDatabase.value!.settings!.github, isNull);
      expect(world.github.storedBytes, isNotNull);
    });
  });

  group('sync over the server', () {
    test('a change is saved locally and pushed with If-Match', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureServer(url: _url);
      world.server.requests.clear();

      _addEntry(app, 'later');
      await app.saveDatabase();
      await _until(() => app.syncStatus.value.state == SyncState.synced);

      var puts = world.server.requests.where((r) => r.method == 'PUT');
      expect(puts, hasLength(1));
      expect(puts.single.headers['If-Match'], isNotNull);
      expect(puts.single.headers.containsKey('If-None-Match'), isFalse);
      expect(_labels(await _serverDb(app, world, _pass)), ['later']);
    });

    test('a conflict is merged and retried (another device wrote first)',
        () async {
      var world = _World();
      var a = await _freshApp();
      world.install(a);
      await a.createDatabase(_pass);
      await a.configureServer(url: _url);
      var b = await _freshApp();
      world.install(b);
      await b.createDatabase(_pass);
      await b.configureServer(url: _url);
      _addEntry(b, 'from-b');
      await b.saveDatabase();
      await _until(() => b.syncStatus.value.state == SyncState.synced);

      _addEntry(a, 'from-a');
      await a.saveDatabase();
      await _until(() => a.syncStatus.value.state == SyncState.synced);

      expect(_labels(a.loadedDatabase.value!), ['from-a', 'from-b']);
      expect(_labels(await _serverDb(a, world, _pass)), ['from-a', 'from-b']);
    });

    test('429 is notSynced with the wait time, 503 is notSynced without; '
        'never authRequired', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      await app.configureServer(url: _url);

      world.server
        ..failWith = 429
        ..failHeaders = {'Retry-After': '30'};
      var limited = await app.syncNow();
      expect(limited.state, SyncState.notSynced);
      expect(limited.retryAfter, const Duration(seconds: 30));

      world.server
        ..failWith = 503
        ..failHeaders = {'Retry-After': '1'};
      var down = await app.syncNow();
      expect(down.state, SyncState.notSynced);
      expect(down.retryAfter, isNull);

      world.server
        ..failWith = 403
        ..failHeaders = {};
      var forbidden = await app.syncNow();
      expect(forbidden.state, SyncState.notSynced);
    });

    test('opening a database with server settings builds a RestBackend and '
        'syncs', () async {
      var world = _World();
      var a = await _freshApp();
      world.install(a);
      await a.createDatabase(_pass);
      _addEntry(a, 'one');
      await a.configureServer(url: _url);
      var export = base64.encode(await a.exportEncryptedDatabase());
      a.closeDatabase();

      var b = await _freshApp();
      world.install(b);
      await b.importEncryptedText(export, _pass);
      await _until(() => b.syncStatus.value.state == SyncState.synced);

      expect(b.remoteBackend, isA<RestBackend>());
      expect((b.remoteBackend as RestBackend).url, _url);
    });
  });

  group('passphrase change over the server', () {
    test('writes the new name, deletes the old file with If-Match and '
        'keeps working with the new name', () async {
      var app = await _freshApp();
      var world = _World()..install(app);
      await app.createDatabase(_pass);
      _addEntry(app, 'one');
      await app.configureServer(url: _url);
      var oldName = await _name(app, _pass);
      var oldVersion = world.server.generation(oldName);
      world.server.requests.clear();

      var result = await app.changeDatabasePassphrase(
          oldPassphrase: _pass, newPassphrase: 'passphrase B');

      var newName = await _name(app, 'passphrase B');
      expect(result.cleanupError, isNull);
      expect(world.server.stored(oldName), isNull);
      expect(world.server.stored(newName), isNotNull);
      var deletes = world.server.requests.where((r) => r.method == 'DELETE');
      expect(deletes, hasLength(1));
      expect(deletes.single.url.pathSegments.last, oldName);
      expect(deletes.single.headers['If-Match'], '"$oldVersion"');
      var newPut = world.server.requests
          .firstWhere((r) => r.method == 'PUT' && r.url.pathSegments.last == newName);
      expect(newPut.headers['If-None-Match'], '*');
      expect(app.syncStatus.value.state, SyncState.synced);
      expect(app.remoteBackend, isA<RestBackend>());
      expect(_labels(await _serverDb(app, world, 'passphrase B')), ['one']);
    });

    test('a device on the old name sees remoteMissing after the change',
        () async {
      var world = _World();
      var a = await _freshApp();
      world.install(a);
      await a.createDatabase(_pass);
      await a.configureServer(url: _url);

      var b = await _freshApp();
      world.install(b);
      await b.createDatabase(_pass);
      await b.configureServer(url: _url);

      await a.changeDatabasePassphrase(
          oldPassphrase: _pass, newPassphrase: 'passphrase B');
      var status = await b.syncNow();

      expect(status.state, SyncState.remoteMissing);
      expect(status.error, contains('the sync server'));
    });

    test('a pending write that never settles refuses the change and names '
        'the sync server', () async {
      var app = await _freshApp();
      _World().install(app);
      await app.createDatabase(_pass);
      await app.configureServer(url: _url);
      app.pendingWriteWait = const Duration(milliseconds: 30);
      var gate = Completer<void>();
      var held = _HoldingBackend(gate.future);
      app.remoteBackend = held;

      var error = await _error(app.changeDatabasePassphrase(
          oldPassphrase: _pass, newPassphrase: 'passphrase B'));

      expect(error.toString(), contains('earlier request to the sync server'));
      gate.complete();
    });
  });
}

/// Eine Datei, die kein Chiffretext ist.
Uint8List junk() => Uint8List.fromList(utf8.encode('this is not a database'));

class _HoldingBackend extends FakeRemoteBackend {
  final Future<void> hold;
  _HoldingBackend(this.hold) {
    displayName = 'Sync server';
  }

  @override
  Future<void> whenWritesSettled() => hold;
}
