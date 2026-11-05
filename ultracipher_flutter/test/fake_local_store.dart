// In-Memory-LocalDatabaseStore fuer Tests (kein dart:io: die Datei laeuft auch
// in den Browser-Laeufen). Cache, FIFO und Ruecksprung kommen aus
// CachingLocalStore wie beim echten Speicher; hier ist nur das Medium simuliert.
//
// Die [FakeLocalDisk] ist das "Medium": ein neuer [FakeLocalStore] ueber
// derselben Disk sieht genau das Persistierte, nicht den Cache des alten
// (= Neustart). Fehler: [failWrites] (write, restoreBackup) und [failRemoves]
// (remove) lassen jedes Persistieren mit dieser Art scheitern; die Disk bleibt
// dann unveraendert.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/local_store/caching_local_store.dart';
import 'package:ultracipher_flutter/src/local_store/local_store.dart';

class FakeLocalDisk {
  final Map<String, Uint8List> main = {};
  final Map<String, Uint8List> bak = {};
}

class FakeLocalStore extends CachingLocalStore {
  final FakeLocalDisk disk;

  /// Solange gesetzt, wartet jedes Persistieren darauf (haelt einen Auftrag
  /// "in flight"). [maxConcurrent] ist die groesste Zahl gleichzeitig
  /// laufender Auftraege; die FIFO-Warteschlange haelt sie bei 1.
  Completer<void>? persistGate;
  int maxConcurrent = 0;
  int _running = 0;

  LocalStoreErrorKind? failWrites;
  LocalStoreErrorKind? failRemoves;

  /// Lässt [open] scheitern (Speicher nicht benutzbar).
  LocalStoreErrorKind? failOpen;

  FakeLocalStore([FakeLocalDisk? disk]) : disk = disk ?? FakeLocalDisk();

  @override
  Future<void> open() async {
    final fail = failOpen;
    if (fail != null) throw LocalStoreException(fail);
    await super.open();
  }

  @override
  Future<Map<String, StoredCopies>> loadAll() async => {
        for (final name in {...disk.main.keys, ...disk.bak.keys})
          name: StoredCopies(disk.main[name], disk.bak[name]),
      };

  @override
  Future<StoredCopies> load(String name) async =>
      StoredCopies(disk.main[name], disk.bak[name]);

  Future<void> _op(Future<void> Function() body) async {
    _running++;
    if (_running > maxConcurrent) maxConcurrent = _running;
    try {
      await persistGate?.future;
      await body();
    } finally {
      _running--;
    }
  }

  @override
  Future<void> persistWrite(String name, Uint8List bytes) => _op(() async {
        final fail = failWrites;
        if (fail != null) throw LocalStoreException(fail);
        final old = disk.main[name];
        if (old != null) disk.bak[name] = old;
        disk.main[name] = bytes;
      });

  @override
  Future<void> persistRestore(String name, Uint8List bak) => _op(() async {
        final fail = failWrites;
        if (fail != null) throw LocalStoreException(fail);
        disk.main[name] = bak;
      });

  @override
  Future<void> persistRemove(String name) => _op(() async {
        final fail = failRemoves;
        if (fail != null) throw LocalStoreException(fail);
        disk.main.remove(name);
        disk.bak.remove(name);
      });
}

// Helfer für die Tests des Kerns: die lokalen Kopien einer [UltracipherApp]
// (früher SharedPreferences `ucdb_<name>`). Die Namen sind frei wählbar, aber
// nach dem Schema des Speichers (siehe isValidLocalStoreName).

/// Die rohen Bytes der Hauptkopie unter [name] (Fehler, wenn es keine gibt).
Uint8List localBytes(UltracipherApp app, String name) =>
    app.localStore!.read(name)!;

/// Legt [bytes] als Hauptkopie unter [name] ab (wie eine frühere Sitzung).
Future<void> seedLocal(UltracipherApp app, String name, Uint8List bytes) =>
    app.localStore!.write(name, bytes);

/// Alles, was die App lokal hält: Prefs plus Haupt- und .bak-Kopien des
/// Speichers (als base64), für "es wurde nichts geschrieben"-Vergleiche.
Map<String, Object?> localSnapshot(UltracipherApp app) {
  final store = app.localStore!;
  return {
    for (final k in app.storage!.getKeys()) 'prefs:$k': app.storage!.get(k),
    for (final name in store.names) ...{
      if (store.read(name) != null)
        'main:$name': base64.encode(store.read(name)!),
      if (store.readBackup(name) != null)
        'bak:$name': base64.encode(store.readBackup(name)!),
    },
  };
}

/// Bytes, die keine Datenbank sind (kein `UCDB`, kein MAC): eine beschädigte
/// Kopie zum Seeden.
Uint8List junkBytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Lässt jedes folgende `UltracipherApp.init()` einen [FakeLocalStore] über
/// [disk] bauen (= Neustart über denselben persistierten Stand); [configure]
/// stellt Fehlerschalter ein. Danach gilt wieder der Standard aus
/// flutter_test_config.dart.
void useLocalDisk(FakeLocalDisk disk,
    {void Function(FakeLocalStore store)? configure}) {
  final before = UltracipherApp.localStoreFactory;
  UltracipherApp.localStoreFactory = () async {
    final store = FakeLocalStore(disk);
    configure?.call(store);
    return store;
  };
  addTearDown(() => UltracipherApp.localStoreFactory = before);
}
