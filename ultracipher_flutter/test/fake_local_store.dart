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
import 'dart:typed_data';

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

  FakeLocalStore([FakeLocalDisk? disk]) : disk = disk ?? FakeLocalDisk();

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
