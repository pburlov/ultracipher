// Migration der v1-Kopien `ucdb_<name>` aus den Prefs in den lokalen Speicher
// (F4 Schritt 4, Entwurf Paragraph 7) und der Start, wenn der Speicher fehlt.
// Echte Verschlüsselung (Format v1, KDF einmal je Passphrase gemerkt); der
// Speicher ist ein FakeLocalStore, ein Neustart ein zweites init() über
// derselben FakeLocalDisk.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/main.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/local_store/local_store.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'fake_local_store.dart';
import 'memoized_key_derivation.dart';

const _pass = 'migration passphrase';

/// Wie [FakeLocalStore], aber das Zurücklesen vom Medium liefert andere Bytes:
/// die Verifikation der Migration muss das merken.
class _MisreadingStore extends FakeLocalStore {
  _MisreadingStore(FakeLocalDisk disk) : super(disk);

  @override
  Future<Uint8List?> readPersisted(String name) async =>
      Uint8List.fromList([1, 2, 3]);
}

/// Nur das Schreiben dieses einen Namens scheitert.
class _FailingForStore extends FakeLocalStore {
  final String failingName;

  _FailingForStore(FakeLocalDisk disk, this.failingName) : super(disk);

  @override
  Future<void> persistWrite(String name, Uint8List bytes) => name == failingName
      ? Future.error(const LocalStoreException(LocalStoreErrorKind.full))
      : super.persistWrite(name, bytes);
}

UltracipherDatabase _dbWith(List<String> labels) {
  var db = UltracipherDatabase();
  for (var label in labels) {
    db.addEntry().addNewVersion(Entry(label: label));
  }
  return db;
}

List<String> _labels(UltracipherDatabase db) =>
    db.allEntries.map((e) => e.latestEntry!.label).toList()..sort();

/// Was eine App mit der Speicherung in den Prefs (2.0.57) angelegt hätte:
/// Name, Datei v1 und der Prefs-Wert (base64).
class _Old {
  final String name;
  final Uint8List bytes;
  String get text => base64.encode(bytes);
  String get key => UltracipherApp.localPrefsKey(name);

  _Old(this.name, this.bytes);
}

Future<_Old> _oldCopy(List<String> labels, {String pass = _pass}) async {
  var key = await UltracipherApp().deriveRoot(pass);
  return _Old(
      databaseName(key), UltracipherApp.encryptDatabase(_dbWith(labels), key));
}

/// Neues "Gerät": Prefs mit [prefs], Speicher über [disk].
Future<UltracipherApp> _start(Map<String, Object> prefs, FakeLocalDisk disk,
    {void Function(FakeLocalStore store)? configure}) async {
  SharedPreferences.setMockInitialValues(prefs);
  useLocalDisk(disk, configure: configure);
  var app = UltracipherApp();
  await app.init();
  return app;
}

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('migration', () {
    test(
        'a copy that an app version with prefs storage left is in the store '
        'byte for byte after init, the prefs entry is gone, and it opens',
        () async {
      var old = await _oldCopy(['from 2.0.57']);
      var disk = FakeLocalDisk();

      var app = await _start({old.key: old.text}, disk);

      expect(localBytes(app, old.name), old.bytes);
      expect(disk.main[old.name], old.bytes, reason: 'persisted, not cached');
      expect(app.storage!.containsKey(old.key), isFalse);
      expect(app.localDatabaseNames(), [old.name]);
      await app.openLocalDatabase(_pass);
      expect(_labels(app.loadedDatabase.value!), ['from 2.0.57']);
    });

    test('an old-format copy is neither migrated nor touched', () async {
      var v2 = UltracipherApp.localPrefsKey('oldname');
      var v2Text = base64.encode([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      var disk = FakeLocalDisk();

      var app = await _start({v2: v2Text}, disk);

      expect(app.storage!.getString(v2), v2Text);
      expect(app.localStore!.names, isEmpty);
      expect(app.localDatabaseNames(), isEmpty);
      expect(app.hasLegacyLocalCopies, isTrue);
    });

    test(
        'a prefs entry is only removed after the stored bytes were read '
        'back from the medium and matched', () async {
      var old = await _oldCopy(['x']);
      var disk = FakeLocalDisk();
      SharedPreferences.setMockInitialValues({old.key: old.text});
      UltracipherApp.localStoreFactory = () async => _MisreadingStore(disk);
      addTearDown(() =>
          UltracipherApp.localStoreFactory = () async => FakeLocalStore());
      var app = UltracipherApp();

      await app.init();

      // Not verified: the prefs entry stays and is still the only source.
      expect(app.storage!.getString(old.key), old.text);
      expect(app.localStore!.contains(old.name), isFalse);
      expect(disk.main, isEmpty);
      expect(disk.bak, isEmpty);
      expect(app.localDatabaseNames(), [old.name]);
    });

    test(
        'a failing migration keeps the database listed and readable from '
        'the prefs; the next start moves it', () async {
      var old = await _oldCopy(['still here']);
      var disk = FakeLocalDisk();

      var app = await _start({old.key: old.text}, disk,
          configure: (s) => s.failWrites = LocalStoreErrorKind.full);

      expect(app.storage!.getString(old.key), old.text);
      expect(app.localStore!.contains(old.name), isFalse);
      expect(disk.main, isEmpty);
      expect(app.localDatabaseNames(), [old.name]);
      expect(app.hasLegacyLocalCopies, isFalse);
      await app.openLocalDatabase(_pass);
      expect(_labels(app.loadedDatabase.value!), ['still here']);
      app.closeDatabase();

      // The next start, with working storage, finishes the move.
      var again = await _start({old.key: old.text}, disk);
      expect(localBytes(again, old.name), old.bytes);
      expect(again.storage!.containsKey(old.key), isFalse);
      expect(again.localDatabaseNames(), [old.name]);
    });

    test('a failed migration does not stop the others', () async {
      var a = await _oldCopy(['a'], pass: 'pass a');
      var b = await _oldCopy(['b'], pass: 'pass b');
      var disk = FakeLocalDisk();
      SharedPreferences.setMockInitialValues({a.key: a.text, b.key: b.text});
      UltracipherApp.localStoreFactory =
          () async => _FailingForStore(disk, a.name);
      addTearDown(() =>
          UltracipherApp.localStoreFactory = () async => FakeLocalStore());
      var app = UltracipherApp();

      await app.init();

      expect(app.storage!.getString(a.key), a.text);
      expect(app.storage!.containsKey(b.key), isFalse);
      expect(localBytes(app, b.name), b.bytes);
      expect(app.localDatabaseNames().toSet(), {a.name, b.name});
    });

    test(
        'the store and the prefs hold the same bytes (a run was cut off '
        'after writing): the prefs entry goes, the store is unchanged',
        () async {
      var old = await _oldCopy(['same']);
      var disk = FakeLocalDisk()..main[old.name] = old.bytes;

      var app = await _start({old.key: old.text}, disk);

      expect(app.storage!.containsKey(old.key), isFalse);
      expect(localBytes(app, old.name), old.bytes);
      expect(disk.bak, isEmpty, reason: 'nothing was rewritten');
    });

    test(
        'the store and the prefs hold different bytes: the store wins, the '
        'prefs rest stays until "Erase local data"', () async {
      var old = await _oldCopy(['in prefs']);
      var newer = await _oldCopy(['in store', 'newer']);
      var disk = FakeLocalDisk()..main[old.name] = newer.bytes;

      var app = await _start({old.key: old.text}, disk);

      expect(localBytes(app, old.name), newer.bytes);
      expect(app.storage!.getString(old.key), old.text);
      expect(app.localDatabaseNames(), [old.name]);
      await app.openLocalDatabase(_pass);
      expect(_labels(app.loadedDatabase.value!), ['in store', 'newer']);
      app.closeDatabase();

      await app.eraseLocalData();
      expect(app.storage!.containsKey(old.key), isFalse);
      expect(app.localStore!.names, isEmpty);
    });

    test('a second init changes nothing', () async {
      var old = await _oldCopy(['x']);
      var disk = FakeLocalDisk();
      var first = await _start({old.key: old.text}, disk);
      var before = localSnapshot(first);

      // Restart: the migrated prefs are what the first run left.
      var prefs = {
        for (var k in first.storage!.getKeys()) k: first.storage!.get(k)!
      };
      var second = await _start(prefs, disk);

      expect(localSnapshot(second), before);
      expect(disk.bak, isEmpty);
    });

    test(
        'a prefs entry with a name the store cannot hold is skipped and '
        'stays', () async {
      var text = base64.encode([0x55, 0x43, 0x44, 0x42, 0, 1, 0, 1, 7, 7]);
      var key = UltracipherApp.localPrefsKey('bad.name');
      var disk = FakeLocalDisk();

      var app = await _start({key: text}, disk);

      expect(app.storage!.getString(key), text);
      expect(app.localStore!.names, isEmpty);
    });

    test('removing a database also removes the left-over prefs entry',
        () async {
      var old = await _oldCopy(['x']);
      var disk = FakeLocalDisk();
      var app = await _start({old.key: old.text}, disk,
          configure: (s) => s.failWrites = LocalStoreErrorKind.io);

      expect(await app.removeLocalDatabase(passphrase: _pass), isTrue);

      expect(app.storage!.containsKey(old.key), isFalse);
      expect(app.localDatabaseNames(), isEmpty);
    });

    test(
        'saving after a failed migration writes only to the store, which '
        'wins from then on', () async {
      var old = await _oldCopy(['one']);
      var disk = FakeLocalDisk();
      var app = await _start({old.key: old.text}, disk,
          configure: (s) => s.failWrites = LocalStoreErrorKind.full);
      await app.openLocalDatabase(_pass);
      (app.localStore as FakeLocalStore).failWrites = null;
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'two'));

      await app.saveDatabase();

      expect(app.storage!.getString(old.key), old.text,
          reason: 'never written');
      app.closeDatabase();
      await app.openLocalDatabase(_pass);
      expect(_labels(app.loadedDatabase.value!), ['one', 'two']);
    });
  });

  group('not migrated prefs copies and the store together', () {
    test('create over a not migrated prefs copy refuses and writes nothing',
        () async {
      var old = await _oldCopy(['old']);
      var disk = FakeLocalDisk();
      var app = await _start({old.key: old.text}, disk,
          configure: (s) => s.failWrites = LocalStoreErrorKind.full);
      (app.localStore as FakeLocalStore).failWrites = null;

      await expectLater(app.createDatabase(_pass),
          throwsA(isA<LocalDatabaseExistsException>()));

      expect(disk.main, isEmpty);
      expect(app.storage!.getString(old.key), old.text);
    });

    test('a passphrase change onto a name that only exists as a not '
        'migrated prefs copy asks first and then merges into it', () async {
      var target = await _oldCopy(['target'], pass: 'pass b');
      var disk = FakeLocalDisk();
      var app = await _start({target.key: target.text}, disk,
          configure: (s) => s.failWrites = LocalStoreErrorKind.full);
      (app.localStore as FakeLocalStore).failWrites = null;
      await app.createDatabase('pass a');
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'mine'));
      await app.saveDatabase();

      await expectLater(
          app.changeDatabasePassphrase(
              oldPassphrase: 'pass a', newPassphrase: 'pass b'),
          throwsA(isA<LocalDatabaseExistsException>()));
      await app.changeDatabasePassphrase(
          oldPassphrase: 'pass a', newPassphrase: 'pass b', mergeLocal: true);

      expect(_labels(app.loadedDatabase.value!), ['mine', 'target']);
      expect(app.localDatabaseNames(), [target.name]);
    });

    test('a passphrase change removes the old name from the prefs as well, '
        'or the left-over entry would come back as a database', () async {
      var stale = await _oldCopy(['stale']);
      var current = await _oldCopy(['current', 'newer']);
      // The store has the newer state, the prefs a stale rest (the store
      // won at the last start).
      var disk = FakeLocalDisk()..main[stale.name] = current.bytes;
      var app = await _start({stale.key: stale.text}, disk);
      await app.openLocalDatabase(_pass);

      await app.changeDatabasePassphrase(
          oldPassphrase: _pass, newPassphrase: 'another passphrase');

      expect(app.storage!.containsKey(stale.key), isFalse);
      expect(app.localStore!.contains(stale.name), isFalse);
      expect(app.localDatabaseNames(),
          [databaseName(await app.deriveRoot('another passphrase'))]);
    });

    test('the store wins even when it only holds a .bak: that is read, not '
        'the prefs rest', () async {
      var stale = await _oldCopy(['from prefs']);
      var backup = await _oldCopy(['from bak']);
      var disk = FakeLocalDisk()..bak[stale.name] = backup.bytes;

      var app = await _start({stale.key: stale.text}, disk);
      await app.openLocalDatabase(_pass);

      expect(_labels(app.loadedDatabase.value!), ['from bak']);
      expect(app.storage!.getString(stale.key), stale.text);
    });

    test('a store entry with an empty main copy and no .bak is listed, and '
        'opening it gives the "cannot be read" way out', () async {
      var old = await _oldCopy(['x']);
      var disk = FakeLocalDisk()..main[old.name] = Uint8List(0);

      var app = await _start({}, disk);

      expect(app.localDatabaseNames(), [old.name]);
      await expectLater(app.openLocalDatabase(_pass),
          throwsA(isA<LocalDatabaseUnreadableException>()));
      expect(await app.removeLocalDatabase(passphrase: _pass), isTrue);
      expect(app.localDatabaseNames(), isEmpty);
    });
  });

  group('init and the error page', () {
    test('a store that cannot be opened makes init throw the fixed message',
        () async {
      SharedPreferences.setMockInitialValues({});
      useLocalDisk(FakeLocalDisk(),
          configure: (s) => s.failOpen = LocalStoreErrorKind.unavailable);

      await expectLater(
          UltracipherApp().init(),
          throwsA(isA<LocalStoreException>().having((e) => e.toString(),
              'message', 'The storage of this app is not available')));
    });

    testWidgets(
        'buildApp shows an error page with that message instead of '
        'the app', (tester) async {
      SharedPreferences.setMockInitialValues({});
      useLocalDisk(FakeLocalDisk(),
          configure: (s) => s.failOpen = LocalStoreErrorKind.unavailable);

      var root = await tester.runAsync(buildApp);
      await tester.pumpWidget(root!);

      expect(root, isA<StartupErrorApp>());
      expect(find.text('The storage of this app is not available'),
          findsOneWidget);
      expect(find.byType(MyApp), findsNothing);
    });
  });
}
