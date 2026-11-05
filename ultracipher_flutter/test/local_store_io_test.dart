// Der IO-Speicher auf einem echten Temp-Verzeichnis (nie dem App-Verzeichnis):
// Vertrag, Absturz mitten im Schreiben, Layout-Pin, Fehlerabbildung.
@TestOn('vm')
library local_store_io_test;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/local_store/local_store.dart';
import 'package:ultracipher_flutter/src/local_store/local_store_io.dart';

import 'local_store_contract.dart';

Uint8List _b(int fill, [int length = 4]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

FileSystemException _osError(int code) =>
    FileSystemException('x', '/some/path', OSError('os text', code));

// Ein Fehlercode, der auf dieser Plattform "Platte voll" heisst.
final int _fullCode = Platform.isWindows ? 112 : 28;

class _IoHarness implements LocalStoreHarness {
  final Directory root = Directory.systemTemp.createTempSync('ucdb_store_');

  Directory get dir => Directory('${root.path}/databases');

  @override
  Future<LocalDatabaseStore> open() async {
    final store = IoLocalStore(dir);
    await store.open();
    return store;
  }

  @override
  void setFailing(LocalDatabaseStore store, bool failing) {
    (store as IoLocalStore).beforeStep =
        failing ? (_) => throw _osError(_fullCode) : null;
  }

  @override
  Future<void> dispose() async => root.delete(recursive: true);
}

Matcher _storeError(LocalStoreErrorKind kind) =>
    throwsA(isA<LocalStoreException>().having((e) => e.kind, 'kind', kind));

void main() {
  group('IoLocalStore contract', () {
    runLocalStoreContract(() async => _IoHarness());
  });

  group('IoLocalStore', () {
    late _IoHarness h;
    late IoLocalStore store;

    setUp(() async {
      h = _IoHarness();
      store = await h.open() as IoLocalStore;
    });
    tearDown(() => h.dispose());

    File file(String name) => File('${h.dir.path}/$name');

    List<String> fileNames() =>
        h.dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

    // Neustart der App: ein neuer Speicher ueber demselben Verzeichnis.
    Future<IoLocalStore> restart() async => await h.open() as IoLocalStore;

    // Spielt einen Absturz kurz vor [step] des naechsten write.
    Future<void> crashBefore(String step, String name, Uint8List bytes) async {
      store.beforeStep = (s) {
        if (s == step) throw _osError(5);
      };
      await expectLater(
          store.write(name, bytes), _storeError(LocalStoreErrorKind.io));
    }

    test('layout pin: databases/<name> and databases/<name>.bak', () async {
      await store.write('abc', _b(1));
      expect(fileNames(), ['abc']);
      expect(file('abc').readAsBytesSync(), _b(1)); // roh, kein base64
      await store.write('abc', _b(2));
      expect(fileNames(), ['abc', 'abc.bak']);
      expect(file('abc').readAsBytesSync(), _b(2));
      expect(file('abc.bak').readAsBytesSync(), _b(1));
      expect(h.dir.path.endsWith('databases'), isTrue);
    });

    test('layout pin: the platform store lives in <support>/databases',
        () async {
      final created =
          await createPlatformStore(supportDirectory: () async => h.root);
      await created.open();
      await created.write('abc', _b(1));
      expect(File('${h.root.path}/databases/abc').readAsBytesSync(), _b(1));
    });

    test('an unavailable support directory is reported as unavailable',
        () async {
      await expectLater(
          createPlatformStore(
              supportDirectory: () async => throw StateError("no plugin")),
          _storeError(LocalStoreErrorKind.unavailable));
    });

    test('a failed write leaves no .tmp behind, so clear() empties the dir',
        () async {
      await crashBefore('rotate-bak', 'abc', _b(1));
      expect(store.contains('abc'), isFalse); // neuer Name: Cache zurueck
      store.beforeStep = null;
      await store.clear();
      expect(fileNames(), isEmpty);
    });

    test('a failed restoreBackup leaves no .tmp behind', () async {
      await store.write('abc', _b(1));
      await store.write('abc', _b(2));
      store.beforeStep = (s) {
        if (s == 'commit') throw _osError(_fullCode);
      };
      await expectLater(
          store.restoreBackup('abc'), _storeError(LocalStoreErrorKind.full));
      expect(fileNames(), ['abc', 'abc.bak']);
    });

    test('open survives a .tmp that cannot be removed', () async {
      if (Platform.isWindows) return;
      await store.write('abc', _b(1));
      file('zzz.tmp').writeAsBytesSync(_b(7));
      // Verzeichnis ohne Schreibrecht: loeschen scheitert.
      Process.runSync('chmod', ['555', h.dir.path]);
      try {
        var removable = true;
        try {
          File('${h.dir.path}/probe').writeAsBytesSync(_b(1));
        } on FileSystemException {
          removable = false;
        }
        if (removable) return; // z. B. als root: Voraussetzung fehlt
        final again = await restart();
        expect(again.read('abc'), _b(1));
        expect(file('zzz.tmp').existsSync(), isTrue);
      } finally {
        Process.runSync('chmod', ['755', h.dir.path]);
      }
    });

    test('a crash after the temp file was written leaves the old copy',
        () async {
      await store.write('abc', _b(1, 100));
      // Nach Schritt 1 (tmp geschrieben und geflusht), vor der Rotation.
      await crashBefore('rotate-bak', 'abc', _b(2, 100));
      expect(file('abc').readAsBytesSync(), _b(1, 100));
      final again = await restart();
      expect(again.read('abc'), _b(1, 100));
      expect(again.readBackup('abc'), isNull);
      expect(file('abc.tmp').existsSync(), isFalse);
    });

    test('the main copy is untouched until the temp file is complete',
        () async {
      await store.write('abc', _b(1, 100));
      Uint8List? onDisk;
      Uint8List? tmpOnDisk;
      store.beforeStep = (s) {
        if (s == 'rotate-bak') {
          onDisk = file('abc').readAsBytesSync();
          tmpOnDisk = file('abc.tmp').readAsBytesSync();
        }
      };
      await store.write('abc', _b(2, 100));
      expect(onDisk, _b(1, 100));
      expect(tmpOnDisk, _b(2, 100)); // vollstaendig vor dem rename
    });

    test('a crash between the two renames leaves only the backup', () async {
      await store.write('abc', _b(1));
      await crashBefore('commit', 'abc', _b(2));
      // Derselbe Speicher sieht den wahren Stand des Mediums.
      expect(store.read('abc'), isNull);
      expect(store.readBackup('abc'), _b(1));
      final again = await restart();
      expect(again.read('abc'), isNull);
      expect(again.readBackup('abc'), _b(1));
      expect(again.contains('abc'), isTrue);
      expect(again.names, ['abc']);
      expect(file('abc.tmp').existsSync(), isFalse);
    });

    test('a write after such a crash keeps the good backup', () async {
      await store.write('abc', _b(1));
      await crashBefore('commit', 'abc', _b(2));
      final again = await restart();
      await again.write('abc', _b(3));
      expect(again.read('abc'), _b(3));
      expect(again.readBackup('abc'), _b(1));
    });

    test('a crash while removing does not bring the removed copy back',
        () async {
      await store.write('abc', _b(1));
      await store.write('abc', _b(2));
      store.beforeStep = (s) {
        if (s == 'remove-main') throw _osError(5);
      };
      await expectLater(
          store.remove('abc'), _storeError(LocalStoreErrorKind.io));
      // Erst .bak, dann Hauptkopie: die Hauptkopie bleibt, keine .bak.
      expect(fileNames(), ['abc']);
      expect(store.read('abc'), _b(2));
      expect(store.readBackup('abc'), isNull);
    });

    test('restoreBackup writes through the temp file', () async {
      await store.write('abc', _b(1));
      await store.write('abc', _b(2));
      store.beforeStep = (s) {
        if (s == 'commit') throw _osError(5);
      };
      await expectLater(
          store.restoreBackup('abc'), _storeError(LocalStoreErrorKind.io));
      expect(file('abc').readAsBytesSync(), _b(2)); // Hauptkopie unberuehrt
      expect(file('abc.bak').readAsBytesSync(), _b(1));
      expect(store.read('abc'), _b(2));
    });

    test('open removes stray .tmp files and ignores foreign files', () async {
      await store.write('abc', _b(1));
      file('abc.tmp').writeAsBytesSync(_b(7));
      file('zzz.tmp').writeAsBytesSync(_b(7));
      file('a.b').writeAsBytesSync(_b(7));
      file('a.b.bak').writeAsBytesSync(_b(7));
      file('notes.txt').writeAsBytesSync(_b(7));
      Directory('${h.dir.path}/sub').createSync();
      final again = await restart();
      expect(again.names, ['abc']);
      expect(file('abc.tmp').existsSync(), isFalse);
      expect(file('zzz.tmp').existsSync(), isFalse);
      expect(file('notes.txt').existsSync(), isTrue);
    });

    test('open creates the directory', () async {
      h.dir.deleteSync(recursive: true);
      final again = await restart();
      expect(h.dir.existsSync(), isTrue);
      expect(again.names, isEmpty);
    });

    test('a short main copy is returned as it is, never replaced', () async {
      await store.write('abc', _b(1, 100));
      await store.write('abc', _b(2, 100));
      file('abc').writeAsBytesSync(_b(9, 10));
      final again = await restart();
      expect(again.read('abc'), _b(9, 10));
      expect(again.readBackup('abc'), _b(1, 100));
      expect(file('abc').readAsBytesSync(), _b(9, 10));
    });

    test('a missing main copy is not replaced by the backup', () async {
      await store.write('abc', _b(1));
      await store.write('abc', _b(2));
      file('abc').deleteSync();
      final again = await restart();
      expect(again.read('abc'), isNull);
      expect(again.readBackup('abc'), _b(1));
      expect(file('abc').existsSync(), isFalse);
    });

    test('disk full codes map to full, anything else to io', () async {
      final full = Platform.isWindows
          ? [112, 39]
          : Platform.isMacOS
              ? [28, 69]
              : [28, 122];
      for (final code in full) {
        store.beforeStep = (_) => throw _osError(code);
        await expectLater(
            store.write('abc', _b(1)), _storeError(LocalStoreErrorKind.full),
            reason: 'code $code');
      }
      for (final code in [5, 13]) {
        store.beforeStep = (_) => throw _osError(code);
        await expectLater(
            store.write('abc', _b(1)), _storeError(LocalStoreErrorKind.io),
            reason: 'code $code');
      }
      store.beforeStep = (_) => throw const FileSystemException('no code');
      await expectLater(
          store.write('abc', _b(1)), _storeError(LocalStoreErrorKind.io));
    });

    test('the messages carry neither path nor OS text', () {
      for (final kind in LocalStoreErrorKind.values) {
        final text = LocalStoreException(kind).toString();
        expect(text, isNot(contains('/')));
        expect(text, isNot(contains('os text')));
      }
    });

    test('open fails with unavailable when the directory cannot be made',
        () async {
      final blocked = File('${h.root.path}/blocked')..writeAsBytesSync(_b(1));
      final broken = IoLocalStore(Directory('${blocked.path}/databases'));
      await expectLater(
          broken.open(), _storeError(LocalStoreErrorKind.unavailable));
    });
  });
}
