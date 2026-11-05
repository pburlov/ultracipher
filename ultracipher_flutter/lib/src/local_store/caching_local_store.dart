// Gemeinsamer Cache- und Warteschlangen-Kern des lokalen Speichers (Vertrag in
// Paragraph 3.2 des Entwurfs), damit der Fake und jede Plattform denselben
// Code fuer "Cache sofort", FIFO und Ruecksprung bei Fehlern haben. Die
// Unterklasse liefert nur das Medium (persist*/load*) und wirft dabei
// LocalStoreException.
import 'dart:typed_data';

import 'local_store.dart';

/// Haupt- und .bak-Kopie eines Namens, so wie sie auf dem Medium liegen.
class StoredCopies {
  final Uint8List? main;
  final Uint8List? bak;

  const StoredCopies(this.main, this.bak);
}

abstract class CachingLocalStore implements LocalDatabaseStore {
  // Sichtbarer Stand (Cache). Die .bak hier ist die persistierte.
  final Map<String, Uint8List> _main = {};
  final Map<String, Uint8List> _bak = {};

  // Letzter bekannter Stand auf dem Medium; Grundlage fuer die Rotation und
  // den Ruecksprung des Caches nach einem Fehler.
  final Map<String, Uint8List> _diskMain = {};
  final Map<String, Uint8List> _diskBak = {};

  // Eingereihte, noch nicht fertige Auftraege je Name.
  final Map<String, int> _pending = {};
  Future<void> _tail = Future<void>.value();

  /// Alle Namen mit Kopien auf dem Medium; raeumt Reste weg.
  Future<Map<String, StoredCopies>> loadAll();

  /// Die Kopien eines Namens vom Medium.
  Future<StoredCopies> load(String name);

  /// Schreibt [bytes] atomar als Hauptkopie; eine vorhandene Hauptkopie wird
  /// zur .bak.
  Future<void> persistWrite(String name, Uint8List bytes);

  /// Hauptkopie := [bak], die .bak auf dem Medium bleibt.
  Future<void> persistRestore(String name, Uint8List bak);

  /// Entfernt alle Kopien des Namens.
  Future<void> persistRemove(String name);

  @override
  Future<void> open() async {
    final all = await loadAll();
    for (final entry in all.entries) {
      final main = entry.value.main;
      final bak = entry.value.bak;
      if (main != null) _main[entry.key] = _diskMain[entry.key] = main;
      if (bak != null) _bak[entry.key] = _diskBak[entry.key] = bak;
    }
  }

  @override
  Iterable<String> get names => {..._main.keys, ..._bak.keys};

  @override
  bool contains(String name) {
    _check(name);
    return _main.containsKey(name) || _bak.containsKey(name);
  }

  @override
  Uint8List? read(String name) {
    _check(name);
    return _main[name];
  }

  @override
  Uint8List? readBackup(String name) {
    _check(name);
    return _bak[name];
  }

  @override
  Future<void> write(String name, Uint8List bytes) {
    _check(name);
    _main[name] = bytes;
    return _enqueue(name, () async {
      await persistWrite(name, bytes);
      final old = _diskMain[name];
      if (old != null) _diskBak[name] = old;
      _diskMain[name] = bytes;
    });
  }

  @override
  Future<void> restoreBackup(String name) {
    _check(name);
    final bak = _bak[name];
    if (bak == null) throw StateError('No backup copy to restore');
    _main[name] = bak;
    return _enqueue(name, () async {
      await persistRestore(name, bak);
      _diskMain[name] = bak;
    });
  }

  @override
  Future<void> remove(String name) {
    _check(name);
    _main.remove(name);
    _bak.remove(name);
    return _enqueue(name, () async {
      await persistRemove(name);
      _diskMain.remove(name);
      _diskBak.remove(name);
    });
  }

  @override
  Future<void> clear() async {
    await Future.wait(names.toList().map(remove));
  }

  @override
  Future<Uint8List?> readPersisted(String name) async {
    _check(name);
    await _tail;
    return (await load(name)).main;
  }

  void _check(String name) {
    if (!isValidLocalStoreName(name)) {
      throw ArgumentError.value(name, 'name', 'invalid database name');
    }
  }

  Future<void> _enqueue(String name, Future<void> Function() job) {
    _pending[name] = (_pending[name] ?? 0) + 1;
    final done = _tail.then((_) => _run(name, job));
    // Ein Fehler darf die Warteschlange nicht anhalten.
    _tail = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<void> _run(String name, Future<void> Function() job) async {
    var failed = false;
    try {
      await job();
    } catch (_) {
      failed = true;
      await _reloadDisk(name);
      rethrow;
    } finally {
      final left = _pending[name]! - 1;
      if (left == 0) {
        _pending.remove(name);
        // Nur der letzte Auftrag eines Namens stellt den Cache ein: ein
        // spaeterer, noch anstehender Auftrag bestimmt den Stand. Die .bak
        // zieht erst jetzt nach (sie darf nie nur im Cache existieren).
        if (failed) _put(_main, name, _diskMain[name]);
        _put(_bak, name, _diskBak[name]);
      } else {
        _pending[name] = left;
      }
    }
  }

  // Nach einem Fehler kann das Medium halb fortgeschritten sein (Hauptkopie
  // schon zur .bak umbenannt): den wahren Stand nachlesen.
  Future<void> _reloadDisk(String name) async {
    try {
      final copies = await load(name);
      _put(_diskMain, name, copies.main);
      _put(_diskBak, name, copies.bak);
    } on LocalStoreException {
      // Medium nicht lesbar: beim letzten bekannten Stand bleiben.
    }
  }

  static void _put(Map<String, Uint8List> map, String name, Uint8List? bytes) {
    if (bytes == null) {
      map.remove(name);
    } else {
      map[name] = bytes;
    }
  }
}
