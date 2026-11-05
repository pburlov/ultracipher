// Web-Speicher: IndexedDB, Datenbank `ultracipher`, Object-Store `files`.
//
// Layout-Pin (Persistenzformat, NIE aendern, sonst sind alle lokalen DBs der
// Nutzer weg): Datenbank `ultracipher` Version 1, Object-Store `files` (ohne
// keyPath), Schluessel `<name>` (Hauptkopie) und `<name>.bak` (der vorige
// Stand), Wert ein `Uint8Array` mit den rohen v1-Bytes, kein base64. Gepinnt in
// test/local_store_web_test.dart.
//
// Schreiben ist EINE readwrite-Transaktion (Hauptkopie lesen, als .bak
// ablegen, neue Bytes als Hauptkopie): sie wird ganz oder gar nicht
// uebernommen, ein .tmp ist nicht noetig. Jede Anfrage einer Transaktion wird
// synchron aus dem Callback der vorigen gestellt, nie nach einem Dart-`await`:
// dart2js und dart2wasm planen Microtasks verschieden, und eine Transaktion
// ohne offene Anfrage wird vom Browser beendet.
//
// Zwei Tabs: jeder hat seinen eigenen Cache, es gewinnt, wer zuletzt schreibt
// (mit localStorage war es genauso).
// Das Projekt deklariert SDK >=2.12; JSAny.isA gibt es seit Dart 3.4. package:web
// (diese Datei läuft nur im Web-Build) verlangt ohnehin ein neueres SDK, daher
// die zeilenweisen `ignore: sdk_version_since` an den isA-Stellen.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart';

import 'caching_local_store.dart';
import 'local_store.dart';

const String _dbName = 'ultracipher';
const int _dbVersion = 1;
const String _storeName = 'files';

Future<LocalDatabaseStore> createPlatformStore() async => WebLocalStore();

/// Bildet den Namen eines DOM-Fehlers auf eine feste Art ab: nur
/// QuotaExceededError heisst "voll". Eigene Funktion, weil sich ein echter
/// Quota-Fehler im Test nicht ausloesen laesst.
@visibleForTesting
LocalStoreErrorKind webErrorKind(String? domErrorName) =>
    domErrorName == 'QuotaExceededError'
        ? LocalStoreErrorKind.full
        : LocalStoreErrorKind.io;

/// Layout-Pin: IndexedDB `ultracipher`/`files`, Schluessel `<name>[.bak]`,
/// NIE aendern (siehe Kopf der Datei).
class WebLocalStore extends CachingLocalStore {
  /// Testnaht: wird vor jedem Schritt eines Auftrags gerufen (`rotate-bak`,
  /// `commit`, `remove-bak`, `remove-main`) und darf werfen, um einen Fehler
  /// an dieser Stelle zu spielen; die Transaktion wird dann abgebrochen.
  @visibleForTesting
  void Function(String step)? beforeStep;

  void _step(String step) => beforeStep?.call(step);

  @override
  Future<Map<String, StoredCopies>> loadAll() async {
    try {
      late IDBRequest keys;
      late IDBRequest values;
      await _transact(false, (t) {
        keys = t.store.getAllKeys();
        values = t.store.getAll();
      });
      final keyList = (keys.result as JSArray<JSAny?>).toDart;
      final valueList = (values.result as JSArray<JSAny?>).toDart;
      final mains = <String, Uint8List>{};
      final baks = <String, Uint8List>{};
      for (var i = 0; i < keyList.length; i++) {
        final key = keyList[i];
        final value = valueList[i];
        // Fremde Eintraege (anderer Schluessel- oder Werttyp) werden wie
        // fremde Dateien im IO-Speicher ignoriert.
        // ignore: sdk_version_since
        if (!key.isA<JSString>() || !value.isA<JSUint8Array>()) continue;
        final file = (key as JSString).toDart;
        final bytes = (value as JSUint8Array).toDart;
        if (file.endsWith('.bak')) {
          final name = file.substring(0, file.length - 4);
          if (isValidLocalStoreName(name)) baks[name] = bytes;
        } else if (isValidLocalStoreName(file)) {
          mains[file] = bytes;
        }
      }
      return {
        for (final name in {...mains.keys, ...baks.keys})
          name: StoredCopies(mains[name], baks[name]),
      };
    } catch (_) {
      // Jeder Fehler beim ersten Laden heißt "Speicher nicht nutzbar", auch ein
      // io aus _transact (z. B. fehlender Object-Store einer fremden DB).
      throw const LocalStoreException(LocalStoreErrorKind.unavailable);
    }
  }

  @override
  Future<StoredCopies> load(String name) async {
    late IDBRequest main;
    late IDBRequest bak;
    await _transact(false, (t) {
      main = t.store.get(name.toJS);
      bak = t.store.get('$name.bak'.toJS);
    });
    return StoredCopies(_bytesOf(main.result), _bytesOf(bak.result));
  }

  @override
  Future<void> persistWrite(String name, Uint8List bytes) =>
      _transact(true, (t) {
        final old = t.store.get(name.toJS);
        old.onsuccess = t.guard(() {
          _step('rotate-bak');
          final previous = old.result;
          // Ohne Hauptkopie (z. B. nach einem Absturz im IO-Speicher oder
          // nach restore) bleibt die .bak, wie sie ist.
          if (previous != null) {
            t.store.put(previous, '$name.bak'.toJS);
          }
          _step('commit');
          t.store.put(_stored(bytes), name.toJS);
        });
      });

  @override
  Future<void> persistRestore(String name, Uint8List bak) =>
      _transact(true, (t) {
        _step('commit');
        t.store.put(_stored(bak), name.toJS);
      });

  // Eine Transaktion: Haupt- und .bak-Kopie verschwinden zusammen.
  @override
  Future<void> persistRemove(String name) => _transact(true, (t) {
        _step('remove-bak');
        t.store.delete('$name.bak'.toJS);
        _step('remove-main');
        t.store.delete(name.toJS);
      });

  static Uint8List? _bytesOf(JSAny? value) =>
      // ignore: sdk_version_since
      value.isA<JSUint8Array>() ? (value as JSUint8Array).toDart : null;

  // Der Structured Clone nimmt bei einer Sicht auf einen groesseren Puffer den
  // ganzen Puffer mit; abgelegt werden aber genau die Bytes.
  static JSUint8Array _stored(Uint8List bytes) {
    final exact = bytes.offsetInBytes == 0 &&
        bytes.lengthInBytes == bytes.buffer.lengthInBytes;
    return (exact ? bytes : Uint8List.fromList(bytes)).toJS;
  }

  /// Oeffnet die Datenbank je Auftrag und schliesst sie danach: keine
  /// dauerhafte Verbindung, die einen Versionswechsel oder ein Loeschen
  /// blockieren koennte. Nichts anderes als LocalStoreException verlaesst
  /// diese Methode.
  Future<void> _transact(bool write, void Function(_Tx t) start) async {
    IDBDatabase? db;
    try {
      db = await _openDatabase();
      final t = _Tx(db, write);
      try {
        start(t);
      } catch (e) {
        t.fail(e);
      }
      await t.done.future;
    } on LocalStoreException {
      rethrow;
    } catch (_) {
      throw const LocalStoreException(LocalStoreErrorKind.io);
    } finally {
      try {
        db?.close();
      } catch (_) {}
    }
  }

  static Future<IDBDatabase> _openDatabase() {
    final done = Completer<IDBDatabase>();
    void fail() {
      if (!done.isCompleted) {
        done.completeError(
            const LocalStoreException(LocalStoreErrorKind.unavailable));
      }
    }

    try {
      final request = window.indexedDB.open(_dbName, _dbVersion);
      request.onupgradeneeded = ((Event _) {
        try {
          (request.result as IDBDatabase).createObjectStore(_storeName);
        } catch (_) {
          fail();
        }
      }).toJS;
      request.onsuccess = ((Event _) {
        if (done.isCompleted) {
          // onupgradeneeded ist gescheitert, die Verbindung kommt trotzdem:
          // schließen, sonst blockiert sie später deleteDatabase.
          try {
            (request.result as IDBDatabase).close();
          } catch (_) {}
          return;
        }
        done.complete(request.result as IDBDatabase);
      }).toJS;
      request.onerror = ((Event _) => fail()).toJS;
    } catch (_) {
      // Kein indexedDB (z. B. Datenschutzmodus) oder open wirft.
      fail();
    }
    return done.future;
  }
}

/// Eine Transaktion auf dem Object-Store; [done] endet mit `complete` oder
/// `abort`.
class _Tx {
  final IDBTransaction tx;
  final Completer<void> done = Completer<void>();
  LocalStoreException? _failure;

  _Tx(IDBDatabase db, bool write)
      : tx = db.transaction(
          _storeName.toJS,
          write ? 'readwrite' : 'readonly',
          // 'strict': "complete" erst nach dem Flush auf das Medium. Ein
          // Hinweis, Browser ohne Unterstuetzung ignorieren ihn.
          IDBTransactionOptions(durability: 'strict'),
        ) {
    tx.oncomplete = ((Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    tx.onabort = ((Event _) {
      if (done.isCompleted) return;
      // Nach einem eigenen abort() ist tx.error null (dann gilt _failure).
      // Die Verdrahtung tx.error?.name -> webErrorKind ist nicht durch einen
      // Test belegt: ein Quota-Fehler lässt sich im Browser nicht auslösen.
      done.completeError(
          _failure ?? LocalStoreException(webErrorKind(_domErrorName())));
    }).toJS;
  }

  IDBObjectStore get store => tx.objectStore(_storeName);

  String? _domErrorName() {
    try {
      return tx.error?.name;
    } catch (_) {
      return null;
    }
  }

  /// Callback fuer eine Anfrage: ein Fehler darin bricht die Transaktion ab,
  /// statt als JS-Fehler aus dem Callback zu entweichen (dart2js und
  /// dart2wasm verhalten sich dabei verschieden).
  JSFunction guard(void Function() body) => ((Event _) {
        try {
          body();
        } catch (e) {
          fail(e);
        }
      }).toJS;

  /// Bricht ab; die Transaktion wird dann gar nicht uebernommen.
  void fail(Object error) {
    _failure ??= error is LocalStoreException
        ? error
        : const LocalStoreException(LocalStoreErrorKind.io);
    try {
      tx.abort();
    } catch (_) {
      // Schon beendet: complete oder abort kommt von selbst.
    }
  }
}
