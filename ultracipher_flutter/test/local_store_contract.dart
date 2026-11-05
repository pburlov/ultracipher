// Vertragstests fuer LocalDatabaseStore (Entwurf F4, Paragraph 3.2, 9). Laufen
// gegen jede Implementierung ueber ein [LocalStoreHarness]; kein dart:io, damit
// die Datei auch im Browser uebersetzt. Jeder Test bekommt ein frisches Medium.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/local_store/local_store.dart';

abstract class LocalStoreHarness {
  /// Ein geoeffneter Speicher ueber demselben Medium. Jeder Aufruf ist ein
  /// "Neustart": er sieht nur, was persistiert wurde.
  Future<LocalDatabaseStore> open();

  /// Laesst jedes weitere Persistieren (write, restoreBackup, remove) von
  /// [store] mit [LocalStoreErrorKind.full] scheitern, oder nicht mehr.
  void setFailing(LocalDatabaseStore store, bool failing);

  Future<void> dispose();
}

Uint8List _b(int fill, [int length = 4]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

Matcher _storeError(LocalStoreErrorKind kind) =>
    isA<LocalStoreException>().having((e) => e.kind, 'kind', kind);

void runLocalStoreContract(Future<LocalStoreHarness> Function() create) {
  late LocalStoreHarness harness;
  late LocalDatabaseStore store;

  setUp(() async {
    harness = await create();
    store = await harness.open();
  });
  tearDown(() => harness.dispose());

  test('write is visible at once, before the future completes', () async {
    final f = store.write('nameA', _b(1));
    expect(store.read('nameA'), _b(1));
    expect(store.contains('nameA'), isTrue);
    expect(store.names, ['nameA']);
    await f;
    expect(store.read('nameA'), _b(1));
  });

  test('a written copy survives a restart', () async {
    await store.write('nameA', _b(1));
    await store.write('nameA', _b(2));
    final again = await harness.open();
    expect(again.read('nameA'), _b(2));
    expect(again.readBackup('nameA'), _b(1));
    expect(again.names, ['nameA']);
  });

  test('two writes without await: the second wins, in cache and on disk',
      () async {
    final f1 = store.write('nameA', _b(1));
    final f2 = store.write('nameA', _b(2));
    expect(store.read('nameA'), _b(2));
    await Future.wait([f1, f2]);
    expect(store.read('nameA'), _b(2));
    expect(await store.readPersisted('nameA'), _b(2));
    expect(store.readBackup('nameA'), _b(1));
  });

  test('readPersisted waits for the queue and bypasses the cache', () async {
    expect(await store.readPersisted('nameA'), isNull);
    final f = store.write('nameA', _b(1));
    expect(await store.readPersisted('nameA'), _b(1));
    await f;
  });

  test('a failing write rolls the cache back and throws the fixed error',
      () async {
    await store.write('nameA', _b(1));
    await store.write('nameA', _b(2)); // bak = 1
    harness.setFailing(store, true);
    final f = store.write('nameA', _b(3));
    expect(store.read('nameA'), _b(3)); // sofort sichtbar
    await expectLater(f, throwsA(_storeError(LocalStoreErrorKind.full)));
    expect(store.read('nameA'), _b(2));
    expect(store.readBackup('nameA'), _b(1));
    expect(await store.readPersisted('nameA'), _b(2));
  });

  test('a failed write of a new name leaves nothing behind', () async {
    harness.setFailing(store, true);
    await expectLater(store.write('nameA', _b(1)),
        throwsA(_storeError(LocalStoreErrorKind.full)));
    expect(store.contains('nameA'), isFalse);
    expect(store.names, isEmpty);
    expect((await harness.open()).names, isEmpty);
  });

  test('the cache only rolls back when no later job for the name is pending',
      () async {
    await store.write('nameA', _b(1));
    harness.setFailing(store, true);
    final f1 = store.write('nameA', _b(2));
    final f2 = store.write('nameA', _b(3));
    Uint8List? seenAfterFirst;
    final first = f1.then((_) {}, onError: (_) {
      seenAfterFirst = store.read('nameA');
    });
    await first;
    expect(seenAfterFirst, _b(3));
    await expectLater(f2, throwsA(_storeError(LocalStoreErrorKind.full)));
    expect(store.read('nameA'), _b(1));
  });

  test('the backup in the cache only follows after a successful persist',
      () async {
    await store.write('nameA', _b(1));
    final f = store.write('nameA', _b(2));
    expect(store.readBackup('nameA'), isNull);
    await f;
    expect(store.readBackup('nameA'), _b(1));
    harness.setFailing(store, true);
    await expectLater(store.write('nameA', _b(3)), throwsA(anything));
    expect(store.readBackup('nameA'), _b(1)); // nie nur im Cache
    harness.setFailing(store, false);
    await store.write('nameA', _b(4));
    expect(store.readBackup('nameA'), _b(2));
  });

  test('write twice: readBackup is the first state', () async {
    await store.write('nameA', _b(1));
    expect(store.readBackup('nameA'), isNull);
    await store.write('nameA', _b(2));
    expect(store.readBackup('nameA'), _b(1));
    await store.write('nameA', _b(3));
    expect(store.readBackup('nameA'), _b(2));
  });

  test('remove drops main and backup, also after a restart', () async {
    await store.write('nameA', _b(1));
    await store.write('nameA', _b(2));
    await store.write('nameB', _b(9));
    final f = store.remove('nameA');
    expect(store.contains('nameA'), isFalse);
    expect(store.read('nameA'), isNull);
    expect(store.readBackup('nameA'), isNull);
    expect(store.names, ['nameB']);
    await f;
    final again = await harness.open();
    expect(again.contains('nameA'), isFalse);
    expect(again.readBackup('nameA'), isNull);
    expect(again.names, ['nameB']);
  });

  test('a failing remove brings the copies back', () async {
    await store.write('nameA', _b(1));
    await store.write('nameA', _b(2));
    harness.setFailing(store, true);
    await expectLater(
        store.remove('nameA'), throwsA(_storeError(LocalStoreErrorKind.full)));
    expect(store.read('nameA'), _b(2));
    expect(store.readBackup('nameA'), _b(1));
  });

  test('restoreBackup: main = backup, the backup stays', () async {
    await store.write('nameA', _b(1));
    await store.write('nameA', _b(2));
    final f = store.restoreBackup('nameA');
    expect(store.read('nameA'), _b(1)); // sofort sichtbar
    await f;
    expect(store.readBackup('nameA'), _b(1));
    expect(await store.readPersisted('nameA'), _b(1));
    final again = await harness.open();
    expect(again.read('nameA'), _b(1));
    expect(again.readBackup('nameA'), _b(1));
  });

  test('restoreBackup without a backup is a StateError', () async {
    await store.write('nameA', _b(1));
    expect(() => store.restoreBackup('nameA'), throwsStateError);
    expect(() => store.restoreBackup('nameB'), throwsStateError);
  });

  test('a failing restoreBackup rolls the cache back', () async {
    await store.write('nameA', _b(1));
    await store.write('nameA', _b(2));
    harness.setFailing(store, true);
    await expectLater(store.restoreBackup('nameA'),
        throwsA(_storeError(LocalStoreErrorKind.full)));
    expect(store.read('nameA'), _b(2));
    expect(store.readBackup('nameA'), _b(1));
  });

  test('invalid names throw ArgumentError', () async {
    for (final name in ['a/b', 'a.b', '', 'a\n', 'a b', '..', 'a\\b']) {
      expect(() => store.write(name, _b(1)), throwsArgumentError,
          reason: 'write($name)');
      expect(() => store.remove(name), throwsArgumentError,
          reason: 'remove($name)');
      expect(() => store.restoreBackup(name), throwsArgumentError,
          reason: 'restoreBackup($name)');
      expect(() => store.read(name), throwsArgumentError,
          reason: 'read($name)');
      expect(() => store.readBackup(name), throwsArgumentError,
          reason: 'readBackup($name)');
      expect(() => store.contains(name), throwsArgumentError,
          reason: 'contains($name)');
      expect(() => store.readPersisted(name), throwsArgumentError,
          reason: 'readPersisted($name)');
    }
    expect(isValidLocalStoreName('AZaz09_-'), isTrue);
    expect(store.names, isEmpty);
  });

  test('clear removes everything', () async {
    await store.write('nameA', _b(1));
    await store.write('nameA', _b(2));
    await store.write('nameB', _b(3));
    final f = store.clear();
    expect(store.names, isEmpty);
    await f;
    expect((await harness.open()).names, isEmpty);
  });
}
