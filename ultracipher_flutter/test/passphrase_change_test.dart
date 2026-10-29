// Tests des Passwortwechsels (Plan Schritt 12, §3.5):
// changeDatabasePassphrase. Kein Netz: ein Fake-Repo mit einer Datei je Name
// (FakeRemoteBackend je Datei) ueber die Testnaht backendForSettings. Echte
// Verschluesselung (Format v1); die KDF je Passphrase einmal echt, dann gemerkt
// (memoized_key_derivation.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/backend/github_backend.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/commons.dart' show describeError;
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

const _passA = 'passphrase A';
const _passB = 'passphrase B';

final _github =
    GithubSettings(token: 'tok', owner: 'o', repo: 'r', branch: 'main');

/// Ein Repo mit einer Datei je Name, von allen "Geraeten" geteilt.
class _Repo implements RemoteBackend {
  final files = <String, FakeRemoteBackend>{};

  FakeRemoteBackend file(String name) =>
      files.putIfAbsent(name, () => FakeRemoteBackend());

  @override
  String get id => 'repo';

  @override
  String get displayName => 'Repo';

  @override
  Future<RemoteData> read(String name) => file(name).read(name);

  @override
  Future<String?> write(String name, Uint8List bytes, {String? version}) =>
      file(name).write(name, bytes, version: version);

  @override
  Future<void> delete(String name, String version) =>
      file(name).delete(name, version);

  @override
  Future<void> whenWritesSettled() =>
      Future.wait([for (var f in files.values) f.whenWritesSettled()]);

  @override
  void close() {}
}

/// Die GitHub-Contents-API im Speicher, fuer ein echtes [GithubBackend]
/// (nur der Pfad `/contents/<name>.txt` zaehlt). Auf Wunsch haengen PUTs
/// ([hangPuts]) und beachten dabei, wie der IOClient, den Abbruch.
class _ApiFile {
  final String content;
  final String sha;
  _ApiFile(this.content, this.sha);
}

class _ApiClient extends http.BaseClient {
  /// Dateiname -> (API-content, sha).
  final files = <String, _ApiFile>{};
  bool hangPuts = false;
  int abortedPuts = 0;
  int _sha = 0;

  void seed(String name, Uint8List ciphertext) => files['$name.txt'] = _ApiFile(
      base64.encode(utf8.encode(base64.encode(ciphertext))), 'sha${_sha++}');

  Uint8List? bytes(String name) {
    var file = files['$name.txt'];
    if (file == null) return null;
    return base64.decode(utf8.decode(base64.decode(file.content)));
  }

  http.StreamedResponse _reply(Object json, int status) =>
      http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(json))), status);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var file = request.url.pathSegments.last;
    var body = request is http.Request && request.body.isNotEmpty
        ? jsonDecode(request.body) as Map<String, dynamic>
        : <String, dynamic>{};
    var current = files[file];
    switch (request.method) {
      case 'GET':
        return current == null
            ? _reply({}, 404)
            : _reply({
                'sha': current.sha,
                'content': current.content,
                // Wie die echte API: ohne `encoding` liest das Backend nicht.
                'encoding': 'base64',
              }, 200);
      case 'PUT':
        if (hangPuts) {
          var never = Completer<http.StreamedResponse>();
          var trigger =
              request is http.Abortable ? request.abortTrigger : null;
          trigger?.whenComplete(() {
            abortedPuts++;
            never.completeError(http.RequestAbortedException(request.url));
          });
          return never.future;
        }
        if ((body['sha'] as String?) != current?.sha) return _reply({}, 409);
        var sha = 'sha${_sha++}';
        files[file] = _ApiFile(body['content'] as String, sha);
        return _reply({'content': {'sha': sha}}, current == null ? 201 : 200);
      case 'DELETE':
        if (current == null || body['sha'] != current.sha) {
          return _reply({}, 409);
        }
        files.remove(file);
        return _reply({}, 200);
    }
    return _reply({}, 404);
  }
}

class _KN {
  final Uint8List key;
  final String name;
  _KN(this.key, this.name);
}

late _KN _a;
late _KN _b;

Future<_KN> _derive(String pass) async {
  // Gleiches Ergebnis wie UltracipherApp.deriveRoot (`R`), ohne App.
  var key = await memoizedRoot(pass);
  return _KN(key, databaseName(key));
}

UltracipherDatabase _dbWith(List<String> labels, {GithubSettings? github}) {
  var db = UltracipherDatabase();
  for (var label in labels) {
    // Id und Zeit aus dem Label: dieselbe Zeile in zwei Datenbanken ist
    // derselbe Eintrag.
    var entry = Entry(label: label)..createTime = '2020-01-01T00:00:00.000Z';
    db.addEntry(entry: VersionedEntry('id-$label')).addNewVersion(entry);
  }
  if (github != null) {
    db.setSettings(github: github);
  }
  return db;
}

void _add(UltracipherDatabase db, String label) =>
    db.addEntry(entry: VersionedEntry('id-$label'))
        .addNewVersion(Entry(label: label));

List<String> _labels(UltracipherDatabase db) =>
    db.allEntries.map((e) => e.latestEntry!.label).toList()..sort();

Uint8List _enc(UltracipherDatabase db, _KN kn) =>
    UltracipherApp.encryptDatabase(db, kn.key);

Future<UltracipherApp> _freshApp(_Repo repo) async {
  SharedPreferences.setMockInitialValues({});
  var app = UltracipherApp();
  await app.init();
  app.backendForSettings = (s, key) => s == null ? null : repo;
  return app;
}

Future<void> _seedLocal(
    UltracipherApp app, _KN kn, UltracipherDatabase db) async {
  await app.storage!.setString(
      UltracipherApp.localPrefsKey(kn.name), base64.encode(_enc(db, kn)));
}

/// Die lokale Kopie unter [kn] (entschluesselt) oder null.
UltracipherDatabase? _local(UltracipherApp app, _KN kn) {
  var text = app.storage!.getString(UltracipherApp.localPrefsKey(kn.name));
  return text == null
      ? null
      : UltracipherApp.decryptDatabase(base64.decode(text), kn.key);
}

/// Die Remote-Datei unter [kn] (entschluesselt) oder null.
UltracipherDatabase? _remote(_Repo repo, _KN kn) {
  var bytes = repo.file(kn.name).storedBytes;
  return bytes == null ? null : UltracipherApp.decryptDatabase(bytes, kn.key);
}

/// Alle Prefs-Eintraege im Form des alten `_key`-Caches (seit v1 gibt es keine).
Set<String> _keyCacheEntries(UltracipherApp app) =>
    app.storage!.getKeys().where(UltracipherApp.isKeyCachePrefsKey).toSet();

Map<String, Object?> _prefs(UltracipherApp app) =>
    {for (var k in app.storage!.getKeys()) k: app.storage!.get(k)};

Future<Object?> _error(Future<Object?> f) async {
  try {
    await f;
  } catch (e) {
    return e;
  }
  return null;
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}

/// Oeffnet unter [_passA] eine Datenbank mit [labels] und GitHub; die
/// Remote-Datei hat denselben Stand. Danach synchron.
Future<UltracipherApp> _openRemoteA(_Repo repo, List<String> labels) async {
  var app = await _freshApp(repo);
  var db = _dbWith(labels, github: _github);
  await _seedLocal(app, _a, db);
  repo.file(_a.name).seed(_enc(db, _a));
  await app.openLocalDatabase(_passA);
  expect((await app.syncNow()).state, SyncState.synced);
  return app;
}

Future<PassphraseChangeResult> _change(UltracipherApp app,
        {bool mergeLocal = false}) =>
    app.changeDatabasePassphrase(
        oldPassphrase: _passA, newPassphrase: _passB, mergeLocal: mergeLocal);

/// SharedPreferences, deren Schreiben bzw. Entfernen auf Wunsch scheitert.
class _FailingPrefs extends Fake implements SharedPreferences {
  final SharedPreferences inner;
  bool failWrites = false;
  bool failRemoves = false;

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
  Future<bool> remove(String key) => failRemoves
      ? Future<bool>.error(StateError('locked'))
      : inner.remove(key);
}

/// Beide Namen lesbar, nichts verloren: alte lokale Kopie da,
/// alte Datei mit [labels]; neue Datei/Kopie, falls vorhanden, ebenso.
Future<void> _bothReadable(
    UltracipherApp app, _Repo repo, List<String> labels) async {
  expect(_labels(_local(app, _a)!), containsAll(labels));
  expect(_labels(_remote(repo, _a)!), containsAll(labels));
  var newRemote = _remote(repo, _b);
  if (newRemote != null) expect(_labels(newRemote), containsAll(labels));
  var newLocal = _local(app, _b);
  if (newLocal != null) expect(_labels(newLocal), containsAll(labels));
}

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _a = await _derive(_passA);
    _b = await _derive(_passB);
  });

  group('local-only', () {
    test('stores under the new name, removes the old copy, writes no _key; the '
        'session continues under the new passphrase', () async {
      var repo = _Repo();
      var app = await _freshApp(repo);
      await _seedLocal(app, _a, _dbWith(['x']));
      await app.openLocalDatabase(_passA);
      _add(app.loadedDatabase.value!, 'y');
      await app.saveDatabase();
      var database = app.loadedDatabase.value;

      var result = await _change(app);

      expect(result.cleanupError, isNull);
      expect(identical(app.loadedDatabase.value, database), isTrue);
      expect(_labels(_local(app, _b)!), ['x', 'y']);
      expect(_local(app, _a), isNull);
      expect(_keyCacheEntries(app), isEmpty);
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(repo.files, isEmpty);

      // Speichern geht an den neuen Namen.
      _add(app.loadedDatabase.value!, 'z');
      await app.saveDatabase();
      expect(_labels(_local(app, _b)!), ['x', 'y', 'z']);
      expect(_local(app, _a), isNull);

      // Und die neue Passphrase oeffnet sie, die alte nicht mehr.
      app.closeDatabase();
      expect(await _error(app.openLocalDatabase(_passA)),
          isA<NoLocalDatabaseException>());
      await app.openLocalDatabase(_passB);
      expect(_labels(app.loadedDatabase.value!), ['x', 'y', 'z']);
    });

    test('refuses a wrong old passphrase, an empty or unchanged new one, and '
        'a closed session, without touching anything', () async {
      var repo = _Repo();
      var app = await _freshApp(repo);
      expect(await _error(_change(app)), 'No database open');
      await _seedLocal(app, _a, _dbWith(['x']));
      await app.openLocalDatabase(_passA);
      var before = _prefs(app);
      expect(
          await _error(app.changeDatabasePassphrase(
              oldPassphrase: 'nope', newPassphrase: _passB)),
          'Invalid old passphrase');
      expect(
          await _error(app.changeDatabasePassphrase(
              oldPassphrase: _passA, newPassphrase: '  ')),
          isNotNull);
      expect(
          await _error(app.changeDatabasePassphrase(
              oldPassphrase: ' $_passA ', newPassphrase: '$_passA ')),
          isNotNull);
      expect(_prefs(app), before);
    });
  });

  group('with GitHub', () {
    test('merges the old file into the new one; old file and old copy '
        'are gone; later saves go to the new name', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      // Ein anderes Geraet hat inzwischen an die alte Datei geschrieben.
      repo.file(_a.name).seed(_enc(_dbWith(['x', 'other'], github: _github), _a));
      _add(app.loadedDatabase.value!, 'mine');
      await app.saveDatabase();
      await app.syncNow();

      var result = await _change(app);

      expect(result.cleanupError, isNull);
      expect(_labels(_remote(repo, _b)!), ['mine', 'other', 'x']);
      expect(_labels(_local(app, _b)!), ['mine', 'other', 'x']);
      expect(_labels(app.loadedDatabase.value!), ['mine', 'other', 'x']);
      expect(repo.file(_a.name).storedBytes, isNull);
      expect(_local(app, _a), isNull);
      expect(_keyCacheEntries(app), isEmpty);
      expect(app.syncStatus.value.state, SyncState.synced);
      // Die Einstellungen kamen mit (GitHub bleibt konfiguriert).
      expect(_remote(repo, _b)!.settings?.github, _github);

      _add(app.loadedDatabase.value!, 'later');
      await app.saveDatabase();
      expect((await app.syncNow()).state, SyncState.synced);
      expect(_labels(_remote(repo, _b)!), ['later', 'mine', 'other', 'x']);
      expect(_labels(_local(app, _b)!), ['later', 'mine', 'other', 'x']);
      expect(repo.file(_a.name).storedBytes, isNull);
      expect(_local(app, _a), isNull);
    });

    test('target exists remotely: it is merged, nothing is overwritten',
        () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      repo.file(_b.name).seed(_enc(_dbWith(['b1', 'b2']), _b));

      await _change(app);

      expect(_labels(_remote(repo, _b)!), ['b1', 'b2', 'x']);
      expect(_labels(_local(app, _b)!), ['b1', 'b2', 'x']);
      expect(repo.file(_a.name).storedBytes, isNull);
    });

    test('a local hit under the new name is signalled first (nothing '
        'changes), and merged after confirmation', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      await _seedLocal(app, _b, _dbWith(['hit']));
      var prefs = _prefs(app);

      expect(await _error(_change(app)),
          isA<LocalDatabaseExistsException>());
      expect(_prefs(app), prefs);
      expect(repo.file(_b.name).writeCount, 0);
      expect(repo.file(_a.name).deleteCount, 0);

      await _change(app, mergeLocal: true);
      expect(_labels(_local(app, _b)!), ['hit', 'x']);
      expect(_labels(_remote(repo, _b)!), ['hit', 'x']);
      expect(repo.file(_a.name).storedBytes, isNull);
      expect(_local(app, _a), isNull);
    });

    test('a local hit that cannot be read is refused even when confirmed',
        () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      await app.storage!
          .setString(UltracipherApp.localPrefsKey(_b.name), 'AAAA');
      expect(await _error(_change(app, mergeLocal: true)),
          isA<LocalDatabaseUnreadableException>());
      expect(app.storage!.getString(UltracipherApp.localPrefsKey(_b.name)),
          'AAAA');
      expect(repo.file(_b.name).storedBytes, isNull);
      expect(_labels(_local(app, _a)!), ['x']);
      expect(_labels(_remote(repo, _a)!), ['x']);
    });

    for (var failure in <String, Object>{
      'offline': RemoteBackendException('offline'),
      'auth': RemoteAuthException('rejected', statusCode: 401),
    }.entries) {
      test('${failure.key}: error, nothing changed at all', () async {
        var repo = _Repo();
        var app = await _openRemoteA(repo, ['x']);
        var database = app.loadedDatabase.value;
        var prefs = _prefs(app);
        repo.file(_a.name).readFailure = failure.value;

        var error = await _error(_change(app));
        expect(error, same(failure.value));
        expect(_prefs(app), prefs);
        expect(repo.file(_b.name).storedBytes, isNull);
        expect(repo.file(_a.name).deleteCount, 0);
        // Die Sitzung laeuft unveraendert unter dem alten Namen weiter.
        expect(identical(app.loadedDatabase.value, database), isTrue);
        repo.file(_a.name).readFailure = null;
        _add(app.loadedDatabase.value!, 'after');
        await app.saveDatabase();
        expect((await app.syncNow()).state, SyncState.synced);
        expect(_labels(_remote(repo, _a)!), ['after', 'x']);
        expect(_local(app, _b), isNull);
      });
    }
  });

  group('abort after each sub-step: both names stay readable', () {
    test('step 1: reading the new name fails', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var prefs = _prefs(app);
      repo.file(_b.name).readFailure = RemoteBackendException('offline');
      expect(await _error(_change(app)), isA<RemoteBackendException>());
      expect(_prefs(app), prefs);
      await _bothReadable(app, repo, ['x']);
    });

    test('step 2 remote: writing the new file fails', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var prefs = _prefs(app);
      repo.file(_b.name).writeFailure = RemoteBackendException('offline');
      expect(await _error(_change(app)), isA<RemoteBackendException>());
      expect(_prefs(app), prefs);
      expect(repo.file(_b.name).storedBytes, isNull);
      await _bothReadable(app, repo, ['x']);
    });

    test('step 2 local: the new file is written, the new local copy fails; '
        'the session stays under the old name', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var prefs = _FailingPrefs(app.storage!);
      app.storage = prefs;
      prefs.failWrites = true;
      expect(await _error(_change(app)), isA<StateError>());
      prefs.failWrites = false;
      expect(_labels(_remote(repo, _b)!), ['x']);
      expect(_local(app, _b), isNull);
      await _bothReadable(app, repo, ['x']);

      // Noch die alte Sitzung: Speichern geht an den alten Namen.
      _add(app.loadedDatabase.value!, 'old');
      await app.saveDatabase();
      expect(_labels(_local(app, _a)!), ['old', 'x']);

      // Wiederholen: die neue Datei wird gefunden und gemergt.
      await _change(app);
      expect(_labels(_remote(repo, _b)!), ['old', 'x']);
      expect(repo.file(_a.name).storedBytes, isNull);
      expect(_local(app, _a), isNull);
    });

    test('step 3: deleting the old file fails; the change holds, the old '
        'copies stay and a repeated change from the old name finishes it',
        () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      repo.file(_a.name).deleteFailure = RemoteBackendException('offline');

      var result = await _change(app);

      expect(result.cleanupError, isA<RemoteBackendException>());
      await _bothReadable(app, repo, ['x']);
      // Die Sitzung laeuft unter dem neuen Namen.
      _add(app.loadedDatabase.value!, 'new');
      await app.saveDatabase();
      await app.syncNow();
      expect(_labels(_remote(repo, _b)!), ['new', 'x']);
      expect(_labels(_local(app, _a)!), ['x']);

      // Ausweg: alte Passphrase oeffnen, erneut wechseln (lokaler Treffer
      // bestaetigen), dann ist aufgeraeumt.
      repo.file(_a.name).deleteFailure = null;
      app.closeDatabase();
      await app.openLocalDatabase(_passA);
      await app.syncNow();
      expect(await _error(_change(app)),
          isA<LocalDatabaseExistsException>());
      var again = await _change(app, mergeLocal: true);
      expect(again.cleanupError, isNull);
      expect(_labels(_remote(repo, _b)!), ['new', 'x']);
      expect(repo.file(_a.name).storedBytes, isNull);
      expect(_local(app, _a), isNull);
    });

    test('step 4: removing the old local copy fails; the old file is gone, '
        'the old local copy stays readable', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var prefs = _FailingPrefs(app.storage!);
      app.storage = prefs;
      prefs.failRemoves = true;

      var result = await _change(app);

      expect(result.cleanupError, isNotNull);
      expect(repo.file(_a.name).storedBytes, isNull);
      expect(_labels(_local(app, _a)!), ['x']);
      expect(_labels(_remote(repo, _b)!), ['x']);
      expect(_labels(_local(app, _b)!), ['x']);
    });

    test('the old file changed since it was read: the delete conflicts, its '
        'state is merged into the new file, then it is deleted', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var old = repo.file(_a.name);
      // Kurz bevor die neue Datei geschrieben wird, schreibt ein anderes
      // Geraet noch an die alte.
      repo.file(_b.name).beforeWrite = (n) {
        if (n == 1) old.seed(_enc(_dbWith(['x', 'late'], github: _github), _a));
      };

      var result = await _change(app);

      expect(result.cleanupError, isNull);
      expect(old.deleteCount, 2);
      expect(old.storedBytes, isNull);
      expect(_labels(_remote(repo, _b)!), ['late', 'x']);
      expect(_labels(_local(app, _b)!), ['late', 'x']);
      expect(app.syncStatus.value.state, SyncState.synced);
    });
  });

  test('B1: a save during the rewrite after a delete conflict is not '
      'overwritten in the new local copy by the older rewrite', () async {
    var repo = _Repo();
    var app = await _openRemoteA(repo, ['x']);
    var old = repo.file(_a.name);
    var fresh = repo.file(_b.name);
    var gate = Completer<void>();
    fresh.beforeWrite = (n) {
      // Vor dem ersten Schreiben: ein anderes Geraet schreibt an die alte
      // Datei (Loeschkonflikt). Das zweite Schreiben (Neuschreiben nach dem
      // Konflikt) wird festgehalten.
      if (n == 1) old.seed(_enc(_dbWith(['x', 'late'], github: _github), _a));
      if (n == 2) fresh.writeGate = gate;
    };
    var change = _change(app);
    await _until(() => fresh.writeCount == 2);

    _add(app.loadedDatabase.value!, 'edit');
    await app.saveDatabase();
    // Der Folge-Sync scheitert: die lokale Kopie ist die einzige mit der
    // Aenderung.
    fresh.readFailure = RemoteBackendException('offline');
    fresh.writeGate = null;
    gate.complete();
    await change;
    await app.syncNow();

    expect(old.storedBytes, isNull);
    expect(_labels(_local(app, _b)!), ['edit', 'late', 'x']);
  });

  test('second device: remoteMissing after the change; changing to the new '
      'passphrase there merges its local edits into the new database',
      () async {
    var repo = _Repo();
    // Geraet 2 zuerst; seine Prefs bleiben im Cache seines
    // SharedPreferences-Objekts (das Geraet 1 danach nicht liest).
    var device2 = await _openRemoteA(repo, ['x']);
    repo.file(_a.name).readFailure = RemoteBackendException('offline');
    _add(device2.loadedDatabase.value!, 'd2 offline edit');
    await device2.saveDatabase();
    expect((await device2.syncNow()).state, SyncState.notSynced);
    repo.file(_a.name).readFailure = null;

    var device1 = await _freshApp(repo);
    var db1 = _dbWith(['x'], github: _github);
    await _seedLocal(device1, _a, db1);
    await device1.openLocalDatabase(_passA);
    await device1.syncNow();
    _add(device1.loadedDatabase.value!, 'd1 edit');
    await device1.saveDatabase();
    await device1.syncNow();
    expect((await _change(device1)).cleanupError, isNull);
    expect(repo.file(_a.name).storedBytes, isNull);

    // Geraet 2 ist wieder online.
    var status = await device2.syncNow();
    expect(status.state, SyncState.remoteMissing);
    expect(repo.file(_a.name).storedBytes, isNull,
        reason: 'the normal sync never creates');

    expect((await _change(device2)).cleanupError, isNull);
    expect(_labels(_remote(repo, _b)!), ['d1 edit', 'd2 offline edit', 'x']);
    expect(_labels(_local(device2, _b)!), ['d1 edit', 'd2 offline edit', 'x']);
    expect(_local(device2, _a), isNull);
    expect(repo.file(_a.name).storedBytes, isNull);
    expect(device2.syncStatus.value.state, SyncState.synced);
  });

  group('lock and in-flight writes of the old name', () {
    test('R3: a write the timeout gave up on is waited for; it cannot '
        'recreate the old file after the delete', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var old = repo.file(_a.name);
      // Schlimmster Fall: GitHub legt bei einem PUT mit sha auf eine
      // geloeschte Datei neu an (nicht geprueft).
      old.createOnStaleVersionWhenMissing = true;
      old.abandonWrites = true;
      var gate = Completer<void>();
      old.writeGate = gate;
      _add(app.loadedDatabase.value!, 'late');
      await app.saveDatabase();
      // Der Sync gibt auf (Timeout), der Write bleibt unterwegs.
      expect((await app.syncNow()).state, SyncState.notSynced);
      old.abandonWrites = false;
      old.writeGate = null;
      var reads = old.readCount;

      var change = _change(app);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(old.readCount, reads, reason: 'the old file is read only after '
          'the pending write settled');
      expect(old.deleteCount, 0);
      expect(repo.file(_b.name).writeCount, 0);

      gate.complete();
      var result = await change;

      expect(result.cleanupError, isNull);
      expect(old.deletesWhileWritePending, 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(old.storedBytes, isNull);
      expect(_labels(_remote(repo, _b)!), ['late', 'x']);
    });

    test('a write hanging at network level is aborted at the timeout, tells '
        'the user, and no longer blocks the passphrase change', () async {
      var api = _ApiClient();
      var app = await _freshApp(_Repo());
      app.backendForSettings = (s, key) => s == null
          ? null
          : GithubBackend(
              owner: s.owner,
              repo: s.repo,
              token: s.token,
              client: api,
              requestTimeout: const Duration(milliseconds: 100));
      var db = _dbWith(['x'], github: _github);
      await _seedLocal(app, _a, db);
      api.seed(_a.name, _enc(db, _a));
      await app.openLocalDatabase(_passA);
      expect((await app.syncNow()).state, SyncState.synced);

      api.hangPuts = true;
      _add(app.loadedDatabase.value!, 'late');
      await app.saveDatabase();
      var status = await app.syncNow();
      expect(status.state, SyncState.notSynced);
      expect(status.error, contains('did not respond within 100 ms'));
      expect(describeError(status.error!), status.error);
      expect(api.abortedPuts, greaterThan(0));
      api.hangPuts = false;

      // Frueher: wartet bis pendingWriteWait (60 s) und scheitert dann.
      var result = await _change(app).timeout(const Duration(seconds: 10));

      expect(result.cleanupError, isNull);
      expect(api.bytes(_a.name), isNull);
      expect(_labels(UltracipherApp.decryptDatabase(api.bytes(_b.name)!, _b.key)),
          ['late', 'x']);
    });

    test('R3: if the pending write does not settle in time, nothing changes',
        () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var old = repo.file(_a.name);
      old.abandonWrites = true;
      var gate = Completer<void>();
      old.writeGate = gate;
      _add(app.loadedDatabase.value!, 'late');
      await app.saveDatabase();
      await app.syncNow();
      old.abandonWrites = false;
      old.writeGate = null;
      app.pendingWriteWait = const Duration(milliseconds: 50);
      var prefs = _prefs(app);

      expect(await _error(_change(app)), isA<RemoteBackendException>());
      expect(_prefs(app), prefs);
      expect(old.deleteCount, 0);
      expect(repo.file(_b.name).storedBytes, isNull);
      gate.complete();
    });

    test('a running sync of the old name finishes before the change starts '
        'reading, and syncs requested meanwhile run afterwards under the new '
        'name', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var old = repo.file(_a.name);
      var readGate = Completer<void>();
      old.readGate = readGate;
      var reads = old.readCount;
      _add(app.loadedDatabase.value!, 'during sync');
      await app.saveDatabase();
      await _until(() => old.readCount == reads + 1);

      var change = _change(app);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(old.readCount, reads + 1,
          reason: 'the change waits for the running sync');
      expect(repo.file(_b.name).readCount, 0);

      old.readGate = null;
      readGate.complete();
      // Ein Trigger waehrend des Wechsels: er laeuft erst danach.
      var newWriteGate = Completer<void>();
      repo.file(_b.name).writeGate = newWriteGate;
      await _until(() => repo.file(_b.name).writeCount == 1);
      var oldReads = old.readCount;
      var oldWrites = old.writeCount;
      _add(app.loadedDatabase.value!, 'during change');
      await app.saveDatabase();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(old.readCount, oldReads,
          reason: 'no sync of the old name runs while the change holds the '
              'lock');
      repo.file(_b.name).writeGate = null;
      newWriteGate.complete();
      await change;
      expect(old.readCount, oldReads);
      expect(old.writeCount, oldWrites);

      await app.syncNow();
      expect(app.syncStatus.value.state, SyncState.synced);
      expect(_labels(_remote(repo, _b)!), ['during change', 'during sync', 'x']);
      expect(_labels(_local(app, _b)!), ['during change', 'during sync', 'x']);
      expect(old.storedBytes, isNull);
      expect(_local(app, _a), isNull);
    });

    test('the backend swapped during the change (e.g. by GitHub settings): '
        'the change aborts before writing anything', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var fresh = repo.file(_b.name);
      var gate = Completer<void>();
      fresh.readGate = gate;
      var change = _error(_change(app));
      await _until(() => fresh.readCount == 1);

      app.remoteBackend = FakeRemoteBackend();
      fresh.readGate = null;
      gate.complete();

      expect(await change, isA<RemoteBackendException>());
      expect(fresh.writeCount, 0);
      expect(_local(app, _b), isNull);
      expect(_labels(_remote(repo, _a)!), ['x']);
      expect(_labels(_local(app, _a)!), ['x']);
    });

    test('a local copy under the new name that appears while the change '
        'waits for the lock is still signalled, not overwritten', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var old = repo.file(_a.name);
      var readGate = Completer<void>();
      old.readGate = readGate;
      var reads = old.readCount;
      _add(app.loadedDatabase.value!, 'y');
      await app.saveDatabase();
      await _until(() => old.readCount == reads + 1);

      var change = _error(_change(app));
      // Der Wechsel ist an der ersten Pruefung vorbei und wartet auf die
      // Sperre.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _seedLocal(app, _b, _dbWith(['hit']));
      old.readGate = null;
      readGate.complete();

      expect(await change, isA<LocalDatabaseExistsException>());
      expect(_labels(_local(app, _b)!), ['hit']);
      expect(repo.file(_b.name).writeCount, 0);
      expect(old.deleteCount, 0);
    });

    test('a save of the old name during the change does not bring the old '
        'local copy back; its edit is kept under the new name', () async {
      var repo = _Repo();
      var app = await _openRemoteA(repo, ['x']);
      var gate = Completer<void>();
      repo.file(_b.name).writeGate = gate;
      var change = _change(app);
      await _until(() => repo.file(_b.name).writeCount == 1);

      _add(app.loadedDatabase.value!, 'edit');
      var save = _error(app.saveDatabase());
      repo.file(_b.name).writeGate = null;
      gate.complete();
      await change;
      expect(await save, isNull);

      expect(_local(app, _a), isNull);
      expect(_labels(_local(app, _b)!), ['edit', 'x']);
      expect((await app.syncNow()).state, SyncState.synced);
      expect(_labels(_remote(repo, _b)!), ['edit', 'x']);
    });
  });
}
