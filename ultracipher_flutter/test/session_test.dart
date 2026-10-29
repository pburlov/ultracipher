// Tests der neuen Sitzungs-API in core.dart (Plan Schritt 10):
// openLocalDatabase, createDatabase, importEncryptedText, removeLocalDatabase,
// hasUnsyncedChanges. Dazu die Pflichtbefunde B4a (lokal speichern haengt an
// "Sitzung offen", nicht an "Backend da") und R2 (unlesbare lokale Kopie
// sperrt nicht aus). Kein Netz: FakeRemoteBackend ueber die Testnaht
// backendForSettings. Echte Verschluesselung (Format v1); die KDF je Passphrase
// einmal echt, dann gemerkt
// (memoized_key_derivation.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/backend/github_backend.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
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

UltracipherDatabase _dbWith(List<String> labels, {GithubSettings? github}) {
  var db = UltracipherDatabase();
  for (var label in labels) {
    db.addEntry().addNewVersion(Entry(label: label));
  }
  if (github != null) {
    db.setSettings(github: github);
  }
  return db;
}

List<String> _labels(UltracipherDatabase db) =>
    db.allEntries.map((e) => e.latestEntry!.label).toList()..sort();

Future<UltracipherApp> _freshApp() async {
  SharedPreferences.setMockInitialValues({});
  var app = UltracipherApp();
  await app.init();
  return app;
}

/// Root key `R` and name for [pass] (memoized derivation, see main()).
Future<_KN> _keyAndName(UltracipherApp app, String pass) async {
  var key = await app.deriveRoot(pass);
  return _KN(key, databaseName(key));
}

class _KN {
  final Uint8List key;
  final String name;
  _KN(this.key, this.name);
}

/// Puts a local database for [pass] straight into the prefs (as an earlier
/// session would have).
Future<String> _seedLocal(
    UltracipherApp app, String pass, UltracipherDatabase db) async {
  var knkeyname = await _keyAndName(app, pass);
  var key = knkeyname.key;
  var name = knkeyname.name;
  await app.storage!.setString(UltracipherApp.localPrefsKey(name),
      base64.encode(UltracipherApp.encryptDatabase(db, key)));
  return name;
}

UltracipherDatabase _storedDb(UltracipherApp app, String name, Uint8List key) =>
    UltracipherApp.decryptDatabase(
        base64.decode(app.storage!.getString(UltracipherApp.localPrefsKey(name))!),
        key);

String _exportText(UltracipherDatabase db, Uint8List key) =>
    base64.encode(UltracipherApp.encryptDatabase(db, key));

Map<String, Object?> _prefs(UltracipherApp app) =>
    {for (var k in app.storage!.getKeys()) k: app.storage!.get(k)};

Set<String> _keyCacheEntries(UltracipherApp app) =>
    app.storage!.getKeys().where((k) => k.endsWith('_key')).toSet();

/// A legacy `_key` prefs entry for [pass] in the old shape (base64 of a
/// 32 byte digest plus `_key`). The app no longer writes or reads such
/// entries; the tests seed them to see that it leaves them alone.
String _legacyKeyEntry(String pass) =>
    '${base64.encode(Digest('SHA-256').process(Uint8List.fromList(utf8.encode(pass))))}_key';

/// Lets every GitHub setting resolve to [remote]; `null` (GitHub removed) to
/// no backend, like the default builder.
void _useFake(UltracipherApp app, FakeRemoteBackend remote,
    {List<GithubSettings>? builtFor}) {
  app.backendForSettings = (settings, key) {
    if (settings == null) return null;
    builtFor?.add(settings);
    return remote;
  };
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}

Future<Object?> _error(Future<void> f) async {
  try {
    await f;
  } catch (e) {
    return e;
  }
  return null;
}

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('openLocalDatabase', () {
    test('opens the database of the passphrase, writes no key cache, '
        'no github settings means noRemote and local saving works', () async {
      var app = await _freshApp();
      var name = await _seedLocal(app, _passA, _dbWith(['one', 'two']));
      expect(_keyCacheEntries(app), isEmpty);

      await app.openLocalDatabase(_passA);

      expect(_labels(app.loadedDatabase.value!), equals(['one', 'two']));
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(app.remoteBackend, isNull);
      expect(_keyCacheEntries(app), isEmpty);

      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'three'));
      expect(await app.saveDatabase(), isTrue);
      var knkey = await _keyAndName(app, _passA);
      var key = knkey.key;
      expect(_labels(_storedDb(app, name, key)), equals(['one', 'three', 'two']));
    });

    test('an entry of the older app version is not opened or migrated',
        () async {
      var app = await _freshApp();
      var key = (await _keyAndName(app, _passA)).key;
      var data = UltracipherApp.encryptDatabase(_dbWith(['old']), key);
      // What the older app versions left behind: `<user>_database` in the
      // clear. Only `ucdb_<name>` counts.
      await app.storage!.setString('someone_database', base64.encode(data));
      var before = _prefs(app);

      expect(await _error(app.openLocalDatabase(_passA)),
          isA<NoLocalDatabaseException>());

      expect(_prefs(app), equals(before));
      expect(app.localDatabaseNames(), isEmpty);
    });

    test('the passphrase is trimmed', () async {
      var app = await _freshApp();
      await _seedLocal(app, _passA, _dbWith(['one']));
      await app.openLocalDatabase('  $_passA \n');
      expect(_labels(app.loadedDatabase.value!), equals(['one']));
    });

    test('a wrong passphrase finds nothing and writes nothing to the prefs',
        () async {
      var app = await _freshApp();
      await _seedLocal(app, _passA, _dbWith(['one']));
      var before = _prefs(app);

      var error = await _error(app.openLocalDatabase('wrong'));

      expect(error, isA<NoLocalDatabaseException>());
      expect(error.toString(), 'No database found for this password');
      expect(_prefs(app), equals(before));
      expect(app.loadedDatabase.value, isNull);
    });

    test('a failed open leaves an open session untouched', () async {
      var app = await _freshApp();
      await _seedLocal(app, _passA, _dbWith(['one']));
      await app.openLocalDatabase(_passA);
      var opened = app.loadedDatabase.value;

      expect(await _error(app.openLocalDatabase('wrong')),
          isA<NoLocalDatabaseException>());

      expect(app.loadedDatabase.value, same(opened));
      expect(app.syncStatus.value.state, SyncState.noRemote);
    });

    test('two databases side by side: each passphrase opens its own, saving '
        'in one leaves the other untouched', () async {
      var app = await _freshApp();
      var nameA = await _seedLocal(app, _passA, _dbWith(['a1']));
      var nameB = await _seedLocal(app, _passB, _dbWith(['b1']));
      expect(nameA, isNot(nameB));
      expect(app.localDatabaseNames().toSet(), equals({nameA, nameB}));

      await app.openLocalDatabase(_passA);
      expect(_labels(app.loadedDatabase.value!), equals(['a1']));
      var aBefore = app.storage!.getString(UltracipherApp.localPrefsKey(nameA));

      await app.openLocalDatabase(_passB);
      expect(_labels(app.loadedDatabase.value!), equals(['b1']));
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'b2'));
      await app.saveDatabase();

      var knkeyB = await _keyAndName(app, _passB);
      var keyB = knkeyB.key;
      expect(_labels(_storedDb(app, nameB, keyB)), equals(['b1', 'b2']));
      expect(app.storage!.getString(UltracipherApp.localPrefsKey(nameA)),
          equals(aBefore));
      expect(_keyCacheEntries(app), isEmpty);
    });

    test('github settings build the backend from the settings and start the '
        'first sync', () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      var built = <GithubSettings>[];
      _useFake(app, remote, builtFor: built);
      var knkey = await _keyAndName(app, _passA);
      var key = knkey.key;
      remote.seed(UltracipherApp.encryptDatabase(_dbWith(['remote']), key));
      await _seedLocal(app, _passA, _dbWith(['local'], github: _github));

      await app.openLocalDatabase(_passA);
      expect(app.remoteBackend, same(remote));
      expect(built.single.repo, 'r');
      await _until(() => app.syncStatus.value.state == SyncState.synced);

      expect(_labels(app.loadedDatabase.value!), equals(['local', 'remote']));
      expect(remote.writeCount, 1);
      expect(app.hasUnsyncedChanges, isFalse);
    });

    test('an unreadable local copy is a distinct, content-free error',
        () async {
      var app = await _freshApp();
      var knname = await _keyAndName(app, _passA);
      var name = knname.name;
      await app.storage!
          .setString(UltracipherApp.localPrefsKey(name), 'AAAAAAAAAAAAAAAAAAAA');
      var before = _prefs(app);

      var error = await _error(app.openLocalDatabase(_passA));

      expect(error, isA<LocalDatabaseUnreadableException>());
      expect(error.toString(), contains('cannot be read'));
      expect(_prefs(app), equals(before));
      expect(app.loadedDatabase.value, isNull);
    });
  });

  group('createDatabase', () {
    test('creates an empty database under the name and opens it as noRemote',
        () async {
      var app = await _freshApp();

      await app.createDatabase(_passA);

      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      expect(app.loadedDatabase.value!.allEntries, isEmpty);
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(app.remoteBackend, isNull);
      expect(_storedDb(app, name, key).allEntries, isEmpty);
      expect(_keyCacheEntries(app), isEmpty);

      // And it can be opened again after a close.
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
      await app.saveDatabase();
      app.closeDatabase();
      await app.openLocalDatabase(_passA);
      expect(_labels(app.loadedDatabase.value!), equals(['x']));
    });

    test('refuses an existing database and never overwrites it', () async {
      var app = await _freshApp();
      await _seedLocal(app, _passA, _dbWith(['keep']));
      var before = _prefs(app);

      var error = await _error(app.createDatabase(_passA));

      expect(error, isA<LocalDatabaseExistsException>());
      expect(_prefs(app), equals(before));
      expect(app.loadedDatabase.value, isNull);
    });

    test('refuses an unreadable existing copy as well', () async {
      var app = await _freshApp();
      var knname = await _keyAndName(app, _passA);
      var name = knname.name;
      await app.storage!.setString(UltracipherApp.localPrefsKey(name), 'junk');
      expect(await _error(app.createDatabase(_passA)),
          isA<LocalDatabaseExistsException>());
      expect(app.storage!.getString(UltracipherApp.localPrefsKey(name)), 'junk');
    });
  });

  group('importEncryptedText', () {
    test('into an empty device: stored under the name and opened', () async {
      var app = await _freshApp();
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      var text = _exportText(_dbWith(['x', 'y']), key);

      await app.importEncryptedText(text, _passA);

      expect(_labels(app.loadedDatabase.value!), equals(['x', 'y']));
      expect(_labels(_storedDb(app, name, key)), equals(['x', 'y']));
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(_keyCacheEntries(app), isEmpty);
    });

    test('whitespace and line breaks in the text are ignored', () async {
      var app = await _freshApp();
      var knkey = await _keyAndName(app, _passA);
      var key = knkey.key;
      var text = _exportText(_dbWith(['x']), key);
      var broken = ' ${text.substring(0, 30)}\n\t${text.substring(30)}\r\n';

      await app.importEncryptedText(broken, _passA);

      expect(_labels(app.loadedDatabase.value!), equals(['x']));
    });

    test('into an existing local database: merged, nothing lost', () async {
      var app = await _freshApp();
      var name = await _seedLocal(app, _passA, _dbWith(['local']));
      var knkey = await _keyAndName(app, _passA);
      var key = knkey.key;
      var text = _exportText(_dbWith(['imported']), key);

      await app.importEncryptedText(text, _passA);

      expect(_labels(app.loadedDatabase.value!), equals(['imported', 'local']));
      expect(_labels(_storedDb(app, name, key)), equals(['imported', 'local']));
    });

    test('bad base64, a non-export and a wrong passphrase give the same '
        'neutral error and write nothing', () async {
      var app = await _freshApp();
      var knkeyB = await _keyAndName(app, _passB);
      var keyB = knkeyB.key;
      var before = _prefs(app);

      for (var text in [
        '!!!not base64!!!',
        // Right magic, but too short / junk after the header.
        base64.encode([0x55, 0x43, 0x44, 0x42, 0, 1]),
        _exportText(_dbWith(['x']), keyB), // exported under another passphrase
      ]) {
        var error = await _error(app.importEncryptedText(text, _passA));
        expect(error, UltracipherApp.importFailedMessage);
      }

      expect(_prefs(app), equals(before));
      expect(app.loadedDatabase.value, isNull);
    });

    test('an old-format text (no UCDB magic) names the CSV way out before any '
        'key derivation', () async {
      var app = await _freshApp();
      var before = _prefs(app);
      resetRootDerivationCount();

      // First byte 0x00 is what the former v2 format started with.
      var error = await _error(app.importEncryptedText(
          base64.encode(List.generate(100, (i) => i)), _passA));

      expect(error, UltracipherApp.oldFormatMessage);
      expect(error as String, contains('CSV'));
      expect(rootDerivationCount, 0);
      expect(_prefs(app), equals(before));
      expect(app.loadedDatabase.value, isNull);
    });

    test('into an unreadable local copy: refuses and does not overwrite it',
        () async {
      var app = await _freshApp();
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      await app.storage!.setString(UltracipherApp.localPrefsKey(name), 'junk');

      var error = await _error(
          app.importEncryptedText(_exportText(_dbWith(['x']), key), _passA));

      expect(error, isA<LocalDatabaseUnreadableException>());
      expect(app.storage!.getString(UltracipherApp.localPrefsKey(name)), 'junk');
      expect(app.loadedDatabase.value, isNull);
    });

    test('with github settings: syncs at once and pushes the imported state',
        () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      remote.seed(UltracipherApp.encryptDatabase(_dbWith(['remote']), key));

      await app.importEncryptedText(
          _exportText(_dbWith(['imported'], github: _github), key), _passA);

      expect(app.remoteBackend, same(remote));
      await _until(() => app.syncStatus.value.state == SyncState.synced);
      expect(remote.readCount, greaterThan(0));
      expect(_labels(app.loadedDatabase.value!), equals(['imported', 'remote']));
      expect(_labels(_storedDb(app, name, key)), equals(['imported', 'remote']));
      expect(_labels(UltracipherApp.decryptDatabase(remote.storedBytes!, key)),
          equals(['imported', 'remote']));
    });

    test('with github settings and no remote file: remoteMissing, the file is '
        'not created', () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;

      await app.importEncryptedText(
          _exportText(_dbWith(['imported'], github: _github), key), _passA);
      await _until(
          () => app.syncStatus.value.state == SyncState.remoteMissing);

      expect(remote.readCount, greaterThan(0));
      expect(remote.writeCount, 0);
      expect(remote.storedBytes, isNull);
      // The local copy stays; so does the session.
      expect(_labels(_storedDb(app, name, key)), equals(['imported']));
      expect(_labels(app.loadedDatabase.value!), equals(['imported']));
      expect(app.hasUnsyncedChanges, isTrue);

      // A later save and sync still does not create it.
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'more'));
      await app.saveDatabase();
      var status = await app.syncNow();
      expect(status.state, SyncState.remoteMissing);
      expect(remote.writeCount, 0);
    });

    test('the default backend for github settings targets <name>.txt, and the '
        'sync keeps the local copy under ucdb_<name>', () async {
      var app = await _freshApp();
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      await app.importEncryptedText(
          _exportText(_dbWith(['x'], github: _github), key), _passA);

      var backend = app.remoteBackend as GithubBackend;
      expect(backend.pathFor(name), '$name.txt');
      expect([backend.owner, backend.repo, backend.branch, backend.token],
          equals(['o', 'r', 'main', 'tok']));
      // (The default client fails under the test binding: notSynced.)
      await app.syncNow();
      expect(app.storage!.getKeys().where((k) => k.endsWith('_database')),
          isEmpty);
    });
  });

  group('local copy of a named session', () {
    test('save and a sync that merges a remote change write ucdb_<name>, '
        'never an old-style _database key', () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      remote.seed(UltracipherApp.encryptDatabase(_dbWith(['remote']), key));
      await _seedLocal(app, _passA, _dbWith(['local'], github: _github));
      await app.openLocalDatabase(_passA);
      await _until(() => app.syncStatus.value.state == SyncState.synced);

      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'edit'));
      await app.saveDatabase();
      await app.syncNow();

      // Another device adds an entry; the next sync merges it into the copy.
      var other = UltracipherApp.decryptDatabase(remote.storedBytes!, key);
      other.addEntry().addNewVersion(Entry(label: 'from other'));
      remote.seed(UltracipherApp.encryptDatabase(other, key));
      await app.syncNow();

      var expected = ['edit', 'from other', 'local', 'remote'];
      expect(_labels(app.loadedDatabase.value!), equals(expected));
      expect(_labels(_storedDb(app, name, key)), equals(expected));
      expect(app.storage!.getKeys().where((k) => k.endsWith('_database')),
          isEmpty);
    });

    test('the session writes no _key entry at all', () async {
      var app = await _freshApp();
      await app.createDatabase(_passA);

      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
      await app.saveDatabase();

      expect(_keyCacheEntries(app), isEmpty);
    });
  });

  group('removeLocalDatabase', () {
    test('removes ucdb_<name>, closes the session, leaves other databases '
        'and legacy _key entries alone', () async {
      var app = await _freshApp();
      var nameA = await _seedLocal(app, _passA, _dbWith(['a']));
      var nameB = await _seedLocal(app, _passB, _dbWith(['b']));
      await app.storage!.setString(_legacyKeyEntry(_passA), 'old');
      await app.openLocalDatabase(_passB);
      await app.openLocalDatabase(_passA);
      var bBefore = app.storage!.getString(UltracipherApp.localPrefsKey(nameB));

      expect(await app.removeLocalDatabase(), isTrue);

      expect(app.storage!.containsKey(UltracipherApp.localPrefsKey(nameA)),
          isFalse);
      expect(_keyCacheEntries(app), equals({_legacyKeyEntry(_passA)}));
      expect(app.storage!.getString(UltracipherApp.localPrefsKey(nameB)),
          equals(bBefore));
      expect(app.loadedDatabase.value, isNull);
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(app.remoteBackend, isNull);
      expect(app.hasUnsyncedChanges, isFalse);

      // The other one still opens, A does not.
      await app.openLocalDatabase(_passB);
      app.closeDatabase();
      expect(await _error(app.openLocalDatabase(_passA)),
          isA<NoLocalDatabaseException>());
    });

    test('N2: the session is closed before anything is removed', () async {
      var app = await _freshApp();
      await app.createDatabase(_passA);
      var removal = app.removeLocalDatabase();
      expect(app.loadedDatabase.value, isNull,
          reason: 'closed synchronously, before the prefs are touched');
      await removal;
    });

    test('without an open database it is an error and changes nothing',
        () async {
      var app = await _freshApp();
      await _seedLocal(app, _passA, _dbWith(['a']));
      var before = _prefs(app);
      expect(await _error(app.removeLocalDatabase()), 'No database open');
      expect(_prefs(app), equals(before));
    });

    test('R2: with a corrupt local copy the passphrase variant still removes '
        'it (never decrypts), and the user is not locked out', () async {
      var app = await _freshApp();
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      await app.storage!
          .setString(UltracipherApp.localPrefsKey(name), 'AAAAAAAAAAAAAAAAAAAA');
      expect(await _error(app.openLocalDatabase(_passA)),
          isA<LocalDatabaseUnreadableException>());

      expect(await app.removeLocalDatabase(passphrase: _passA), isTrue);
      expect(app.storage!.containsKey(UltracipherApp.localPrefsKey(name)),
          isFalse);

      // Starting over works: the same passphrase creates a fresh database.
      await app.createDatabase(_passA);
      expect(app.loadedDatabase.value!.allEntries, isEmpty);
      expect(_storedDb(app, name, key).allEntries, isEmpty);
    });

    test('R2: a legacy _key entry is left alone by the passphrase variant',
        () async {
      var app = await _freshApp();
      var name = await _seedLocal(app, _passA, _dbWith(['a']));
      var cacheKey = _legacyKeyEntry(_passA);
      await app.storage!.setString(cacheKey, 'AAAA');

      expect(await app.removeLocalDatabase(passphrase: _passA), isTrue);

      expect(app.storage!.containsKey(UltracipherApp.localPrefsKey(name)),
          isFalse);
      expect(app.storage!.getString(cacheKey), 'AAAA');
    });

    test('the passphrase variant closes the matching open session but not '
        'another one', () async {
      var app = await _freshApp();
      await _seedLocal(app, _passA, _dbWith(['a']));
      var nameB = await _seedLocal(app, _passB, _dbWith(['b']));
      await app.openLocalDatabase(_passB);
      var opened = app.loadedDatabase.value;

      expect(await app.removeLocalDatabase(passphrase: _passA), isTrue);
      expect(app.loadedDatabase.value, same(opened));

      expect(await app.removeLocalDatabase(passphrase: _passB), isTrue);
      expect(app.loadedDatabase.value, isNull);
      expect(app.storage!.containsKey(UltracipherApp.localPrefsKey(nameB)),
          isFalse);
    });

    test('a wrong passphrase removes nothing and reports false', () async {
      var app = await _freshApp();
      await _seedLocal(app, _passA, _dbWith(['a']));
      var before = _prefs(app);
      expect(await app.removeLocalDatabase(passphrase: 'wrong'), isFalse);
      expect(_prefs(app), equals(before));
    });

    test('a sync that is in flight during the removal does not bring the '
        'copy back', () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      remote.seed(UltracipherApp.encryptDatabase(_dbWith(['remote']), key));
      await _seedLocal(app, _passA, _dbWith(['local'], github: _github));
      var gate = Completer<void>();
      remote.readGate = gate;
      await app.openLocalDatabase(_passA);
      await _until(() => remote.readCount > 0);

      await app.removeLocalDatabase();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(app.storage!.containsKey(UltracipherApp.localPrefsKey(name)),
          isFalse);
      expect(remote.writeCount, 0);
      expect(app.loadedDatabase.value, isNull);
      expect(app.syncStatus.value.state, SyncState.noRemote);
    });
  });

  group('hasUnsyncedChanges', () {
    test('false without a session, true for noRemote and before the first '
        'sync, false once synced, true again after a local change', () async {
      var app = await _freshApp();
      expect(app.hasUnsyncedChanges, isFalse);

      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      var knkey = await _keyAndName(app, _passA);
      var key = knkey.key;
      remote.seed(UltracipherApp.encryptDatabase(_dbWith(['remote']), key));
      await _seedLocal(app, _passA, _dbWith(['local'], github: _github));
      var gate = Completer<void>();
      remote.readGate = gate;
      await app.openLocalDatabase(_passA);
      expect(app.hasUnsyncedChanges, isTrue, reason: 'no sync finished yet');

      gate.complete();
      await _until(() => app.syncStatus.value.state == SyncState.synced);
      expect(app.hasUnsyncedChanges, isFalse);

      remote.readFailure = Exception('offline');
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
      await app.saveDatabase();
      await app.syncNow();
      expect(app.syncStatus.value.state, SyncState.notSynced);
      expect(app.hasUnsyncedChanges, isTrue);

      app.closeDatabase();
      expect(app.hasUnsyncedChanges, isFalse);
    });

    test('a local-only database reports true (the copy is the only one)',
        () async {
      var app = await _freshApp();
      await app.createDatabase(_passA);
      expect(app.hasUnsyncedChanges, isTrue);
      expect(app.syncStatus.value.state, SyncState.noRemote);
    });
  });

  group('B4a: saving depends on an open session, not on a backend', () {
    test('a merged github:null sets noRemote and local saving keeps working',
        () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      var knkeyname = await _keyAndName(app, _passA);
      var key = knkeyname.key;
      var name = knkeyname.name;
      // The remote was changed by another device: GitHub removed (newer time).
      var local = _dbWith(['base'], github: _github);
      var removed = UltracipherDatabase.fromJson(local.toJson());
      removed.setSettings(
          github: null, time: DateTime.now().add(const Duration(minutes: 5)));
      remote.seed(UltracipherApp.encryptDatabase(removed, key));
      await _seedLocal(app, _passA, local);
      await app.openLocalDatabase(_passA);
      expect(app.remoteBackend, same(remote));

      var status = await app.syncNow();

      expect(status.state, SyncState.noRemote);
      expect(app.remoteBackend, isNull);
      expect(app.loadedDatabase.value!.settings!.github, isNull);

      // The mandatory part: saving must not throw without a backend.
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'after'));
      expect(await app.saveDatabase(), isTrue);
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(_labels(_storedDb(app, name, key)), equals(['after', 'base']));
      // And the remote was not written to any more.
      expect(remote.writeCount, 0);
    });

  });

  group('session counter', () {
    test('a sync that returns after the session was replaced is discarded',
        () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      var knkeynameA = await _keyAndName(app, _passA);
      var key = knkeynameA.key;
      var nameA = knkeynameA.name;
      remote.seed(UltracipherApp.encryptDatabase(_dbWith(['remote']), key));
      await _seedLocal(app, _passA, _dbWith(['local'], github: _github));
      await _seedLocal(app, _passB, _dbWith(['b']));
      var gate = Completer<void>();
      remote.readGate = gate;
      await app.openLocalDatabase(_passA);
      await _until(() => remote.readCount > 0);
      var aBefore = app.storage!.getString(UltracipherApp.localPrefsKey(nameA));

      await app.openLocalDatabase(_passB);
      var opened = app.loadedDatabase.value;
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(app.loadedDatabase.value, same(opened));
      expect(_labels(opened!), equals(['b']));
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(app.storage!.getString(UltracipherApp.localPrefsKey(nameA)),
          equals(aBefore));
      expect(remote.writeCount, 0);
    });

    test('a sync that returns after closeDatabase is discarded', () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      var knkeynameA = await _keyAndName(app, _passA);
      var key = knkeynameA.key;
      var nameA = knkeynameA.name;
      remote.seed(UltracipherApp.encryptDatabase(_dbWith(['remote']), key));
      await _seedLocal(app, _passA, _dbWith(['local'], github: _github));
      var gate = Completer<void>();
      remote.readGate = gate;
      await app.openLocalDatabase(_passA);
      await _until(() => remote.readCount > 0);
      var aBefore = app.storage!.getString(UltracipherApp.localPrefsKey(nameA));

      app.closeDatabase();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(app.loadedDatabase.value, isNull);
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(app.storage!.getString(UltracipherApp.localPrefsKey(nameA)),
          equals(aBefore));
      expect(remote.writeCount, 0);
    });
  });
  group('closeDatabase', () {
    test('ends the session: no database, no backend, noRemote, nothing to '
        'save or export', () async {
      var app = await _freshApp();
      var remote = FakeRemoteBackend();
      _useFake(app, remote);
      await _seedLocal(app, _passA, _dbWith(['one'], github: _github));
      await app.openLocalDatabase(_passA);
      expect(app.remoteBackend, same(remote));

      app.closeDatabase();

      expect(app.loadedDatabase.value, isNull);
      expect(app.remoteBackend, isNull);
      expect(app.syncStatus.value.state, SyncState.noRemote);
      expect(await _error(app.saveDatabase()), isA<RemoteBackendException>());
      expect(await _error(app.exportEncryptedDatabase()), isNotNull);
      expect(app.hasUnsyncedChanges, isFalse);
    });
  });

  group('legacy _key entries', () {
    test('open, save and sync neither read, change nor add a _key entry',
        () async {
      var app = await _freshApp();
      await _seedLocal(app, _passA, _dbWith(['one']));
      var legacy = _legacyKeyEntry(_passA);
      await app.storage!.setString(legacy, 'AAAA');

      await app.openLocalDatabase(_passA);
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
      await app.saveDatabase();
      await app.syncNow();

      expect(_keyCacheEntries(app), equals({legacy}));
      expect(app.storage!.getString(legacy), 'AAAA');
      expect(_labels(app.loadedDatabase.value!), equals(['one', 'x']));
    });
  });
}
