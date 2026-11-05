// Der Web-Speicher auf der echten IndexedDB des Browsers: Vertrag, Layout-Pin,
// Atomaritaet der Transaktion, Fehlerabbildung. Laeuft nur im Browser
// (flutter test --platform chrome [--wasm] test/local_store_web_test.dart).
@TestOn('browser')
library local_store_web_test;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/local_store/local_store.dart';
import 'package:ultracipher_flutter/src/local_store/local_store_platform.dart'
    as platform;
import 'package:ultracipher_flutter/src/local_store/local_store_web.dart';
import 'package:web/web.dart';

import 'local_store_contract.dart';

Uint8List _b(int fill, [int length = 4]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

// Das Layout steht hier als Literale, nicht aus der Implementierung: eine
// Umbenennung dort muss diese Tests rot machen.
const _db = 'ultracipher';
const _store = 'files';

Future<T> _await<T extends JSAny?>(IDBRequest request) {
  final done = Completer<T>();
  request.onsuccess = ((Event _) => done.complete(request.result as T)).toJS;
  request.onerror = ((Event _) => done.completeError(
      StateError('IndexedDB request failed: ${request.error?.name}'))).toJS;
  return done.future;
}

Future<void> _deleteDatabase() {
  final done = Completer<void>();
  final request = window.indexedDB.deleteDatabase(_db);
  request.onsuccess = ((Event _) => done.complete()).toJS;
  request.onerror =
      ((Event _) => done.completeError(StateError('delete'))).toJS;
  // onblocked: das Loeschen laeuft weiter, sobald die Verbindungen zu sind.
  return done.future;
}

// Rohe Verbindung, am Speicher vorbei: legt [version] an (mit Object-Store
// `files`, falls neu) und schliesst wieder.
Future<IDBDatabase> _rawOpen([int? version]) {
  final done = Completer<IDBDatabase>();
  final request = version == null
      ? window.indexedDB.open(_db)
      : window.indexedDB.open(_db, version);
  request.onupgradeneeded = ((Event _) {
    final db = request.result as IDBDatabase;
    if (!db.objectStoreNames.contains(_store)) db.createObjectStore(_store);
  }).toJS;
  request.onsuccess =
      ((Event _) => done.complete(request.result as IDBDatabase)).toJS;
  request.onerror = ((Event _) =>
          done.completeError(StateError('open failed: ${request.error?.name}')))
      .toJS;
  return done.future;
}

Future<void> _rawPut(String key, JSAny value) async {
  final db = await _rawOpen();
  try {
    final tx = db.transaction(_store.toJS, 'readwrite');
    final done = Completer<void>();
    tx.oncomplete = ((Event _) => done.complete()).toJS;
    tx.objectStore(_store).put(value, key.toJS);
    await done.future;
  } finally {
    db.close();
  }
}

class _RawState {
  final Map<String, Uint8List> bytes = {};
  final Map<String, int> bufferLength = {};
  late final int version;
  late final List<String> storeNames;
}

Future<_RawState> _rawState() async {
  final db = await _rawOpen();
  try {
    final state = _RawState()
      ..version = db.version
      ..storeNames = [
        for (var i = 0; i < db.objectStoreNames.length; i++)
          db.objectStoreNames.item(i)!,
      ];
    final store = db.transaction(_store.toJS).objectStore(_store);
    final keys =
        ((await _await<JSAny?>(store.getAllKeys())) as JSArray<JSAny?>).toDart;
    for (final key in keys) {
      final name = (key as JSString).toDart;
      final value = ((await _await<JSAny?>(store.get(key))) as JSUint8Array);
      state.bytes[name] = value.toDart;
      state.bufferLength[name] = value
          .getProperty<JSObject>('buffer'.toJS)
          .getProperty<JSNumber>('byteLength'.toJS)
          .toDartInt;
    }
    return state;
  } finally {
    db.close();
  }
}

class _WebHarness implements LocalStoreHarness {
  @override
  Future<LocalDatabaseStore> open() async {
    final store = WebLocalStore();
    await store.open();
    return store;
  }

  @override
  void setFailing(LocalDatabaseStore store, bool failing) {
    (store as WebLocalStore).beforeStep = failing
        ? (_) => throw const LocalStoreException(LocalStoreErrorKind.full)
        : null;
  }

  // Der Speicher haelt keine Verbindung offen, das Loeschen blockiert nicht.
  @override
  Future<void> dispose() => _deleteDatabase();
}

Matcher _storeError(LocalStoreErrorKind kind) =>
    throwsA(isA<LocalStoreException>().having((e) => e.kind, 'kind', kind));

void main() {
  // Jeder Test beginnt mit einem leeren Browser-Speicher.
  setUp(_deleteDatabase);
  tearDown(_deleteDatabase);

  group('WebLocalStore contract', () {
    runLocalStoreContract(() async => _WebHarness());
  });

  group('WebLocalStore', () {
    late WebLocalStore store;

    setUp(() async {
      store = await _WebHarness().open() as WebLocalStore;
    });

    Future<WebLocalStore> restart() async =>
        await _WebHarness().open() as WebLocalStore;

    test('layout pin: ultracipher/files, keys <name> and <name>.bak, raw bytes',
        () async {
      await store.write('abc', _b(1));
      await store.write('abc', _b(2));
      final raw = await _rawState();
      expect(raw.version, 1);
      expect(raw.storeNames, ['files']);
      expect(raw.bytes.keys.toList()..sort(), ['abc', 'abc.bak']);
      expect(raw.bytes['abc'], _b(2));
      expect(raw.bytes['abc.bak'], _b(1));
    });

    test('layout pin: records of an existing database are found', () async {
      // Richtung "bestehende Nutzer": so abgelegte Eintraege muss ein neuer
      // Speicher lesen, ohne dass er sie selbst geschrieben hat.
      await _rawPut('seedA', _b(7).toJS);
      await _rawPut('seedA.bak', _b(6).toJS);
      await _rawPut('seedB.bak', _b(5).toJS);
      final again = await restart();
      expect(again.names.toList()..sort(), ['seedA', 'seedB']);
      expect(again.read('seedA'), _b(7));
      expect(again.readBackup('seedA'), _b(6));
      expect(again.read('seedB'), isNull);
      expect(again.readBackup('seedB'), _b(5));
    });

    test('foreign records are ignored', () async {
      await _rawPut('a.b', _b(1).toJS);
      await _rawPut('a b', _b(1).toJS);
      await _rawPut('notBytes', 'text'.toJS);
      await _rawPut('good', _b(2).toJS);
      final again = await restart();
      expect(again.names, ['good']);
    });

    test('8 MiB survive a restart', () async {
      final big = Uint8List(8 * 1024 * 1024);
      for (var i = 0; i < big.length; i += 4099) {
        big[i] = i & 0xff;
      }
      await store.write('big', big);
      final again = await restart();
      expect(again.read('big'), big);
    });

    test('a view on a larger buffer stores exactly its bytes', () async {
      final backing = Uint8List.fromList(List<int>.generate(100, (i) => i));
      final view = Uint8List.sublistView(backing, 10, 20);
      await store.write('abc', view);
      final raw = await _rawState();
      expect(raw.bytes['abc'], view);
      // Sonst laege der ganze Puffer (inkl. fremder Bytes) in der Datenbank.
      expect(raw.bufferLength['abc'], 10);
    });

    test('the transaction is atomic: an error after the rotation keeps both',
        () async {
      await store.write('abc', _b(1));
      await store.write('abc', _b(2)); // bak = 1
      store.beforeStep = (step) {
        if (step == 'commit') throw StateError('crash after rotate-bak');
      };
      await expectLater(
          store.write('abc', _b(3)), _storeError(LocalStoreErrorKind.io));
      final raw = await _rawState();
      expect(raw.bytes['abc'], _b(2));
      expect(raw.bytes['abc.bak'], _b(1)); // die Rotation wurde zurueckgenommen
      final again = await restart();
      expect(again.read('abc'), _b(2));
      expect(again.readBackup('abc'), _b(1));
    });

    test('an error before the rotation changes nothing either', () async {
      await store.write('abc', _b(1));
      store.beforeStep = (step) {
        if (step == 'rotate-bak') throw StateError('boom');
      };
      await expectLater(
          store.write('abc', _b(2)), _storeError(LocalStoreErrorKind.io));
      final raw = await _rawState();
      expect(raw.bytes.keys, ['abc']);
      expect(raw.bytes['abc'], _b(1));
    });

    test('a failing remove between the two deletes removes neither', () async {
      await store.write('abc', _b(1));
      await store.write('abc', _b(2));
      store.beforeStep = (step) {
        if (step == 'remove-main') throw StateError('boom');
      };
      await expectLater(
          store.remove('abc'), _storeError(LocalStoreErrorKind.io));
      final raw = await _rawState();
      expect(raw.bytes['abc'], _b(2));
      expect(raw.bytes['abc.bak'], _b(1));
    });

    test('a write without a main copy leaves the .bak alone', () async {
      await _rawPut('abc.bak', _b(1).toJS);
      final again = await restart();
      await again.write('abc', _b(2));
      final raw = await _rawState();
      expect(raw.bytes['abc'], _b(2));
      expect(raw.bytes['abc.bak'], _b(1));
    });

    test('the error kind comes from the DOM error name', () {
      expect(webErrorKind('QuotaExceededError'), LocalStoreErrorKind.full);
      expect(webErrorKind(DOMException('x', 'QuotaExceededError').name),
          LocalStoreErrorKind.full);
      expect(webErrorKind('AbortError'), LocalStoreErrorKind.io);
      expect(webErrorKind('ConstraintError'), LocalStoreErrorKind.io);
      expect(webErrorKind(null), LocalStoreErrorKind.io);
    });

    test('a database that cannot be opened is unavailable', () async {
      // Eine neuere Version der Datenbank (VersionError beim Oeffnen mit 1).
      await _deleteDatabase();
      (await _rawOpen(2)).close();
      await expectLater(
          WebLocalStore().open(), _storeError(LocalStoreErrorKind.unavailable));
    });

    test('a database without the object store is unavailable', () async {
      // Version 1 ohne Object-Store `files`: die Transaktion in loadAll wirft.
      await _deleteDatabase();
      final done = Completer<void>();
      final request = window.indexedDB.open(_db, 1);
      request.onsuccess = ((Event _) {
        (request.result as IDBDatabase).close();
        done.complete();
      }).toJS;
      request.onerror = ((Event _) => done.completeError(StateError('open')))
          .toJS;
      await done.future;
      await expectLater(
          WebLocalStore().open(), _storeError(LocalStoreErrorKind.unavailable));
    });

    test('the platform switch picks the web store in the browser', () async {
      expect(await platform.createPlatformStore(), isA<WebLocalStore>());
    });

    test('names are validated before anything touches IndexedDB', () {
      expect(() => store.write('a.b', _b(1)), throwsArgumentError);
    });
  });
}
