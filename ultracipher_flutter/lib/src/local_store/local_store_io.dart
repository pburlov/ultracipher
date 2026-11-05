// dart:io-Speicher: eine Datei je DB unter `<ApplicationSupport>/databases/`.
//
// Layout-Pin (Persistenzformat, NIE aendern, sonst sind alle lokalen DBs der
// Nutzer weg): `databases/<name>` (Hauptkopie, rohe v1-Bytes, kein base64) und
// `databases/<name>.bak` (der vorige Stand); `<name>.tmp` ist nur das
// fluechtige Zwischenstueck beim Schreiben. Keine Endung `.ucdb`: das war der
// alte GitHub-Dateiname. Gepinnt in test/local_store_io_test.dart.
//
// Die .bak liegt bewusst neben der Hauptkopie (Backup beibehalten, E2). Das
// Schreiben raeumt die .tmp bei einem Fehler best-effort weg, open() ebenso
// (beides darf nie am Original-Fehler bzw. am Oeffnen etwas aendern).
//
// macOS und Windows sind meist case-insensitiv; zwei 256-Bit-Namen, die sich
// nur in der Schreibung unterscheiden, sind praktisch ausgeschlossen.
//
// Grenzen: Auf Apple ist fsync kein F_FULLFSYNC, und Dart kennt kein fsync auf
// Verzeichnisse. Ein Stromausfall kann also ein rename zuruecknehmen; dann
// liegt der vorige Stand da, kein kaputter. Windows: ob File.rename das Ziel
// atomar ersetzt, ist ungeprueft; schlimmstenfalls fehlt kurz die Hauptkopie,
// und die .bak deckt das ab.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'caching_local_store.dart';
import 'local_store.dart';

/// [supportDirectory] ist nur eine Testnaht: path_provider braucht einen
/// Platform-Channel, den `flutter test` nicht hat.
Future<LocalDatabaseStore> createPlatformStore(
    {@visibleForTesting
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory}) async {
  final Directory support;
  try {
    support = await supportDirectory();
  } catch (_) {
    // Plattformfehler (z. B. fehlender Channel): feste Meldung statt OS-Text.
    throw const LocalStoreException(LocalStoreErrorKind.unavailable);
  }
  return IoLocalStore(
      Directory('${support.path}${Platform.pathSeparator}databases'));
}

/// Layout-Pin: Dateinamen `databases/<name>[.bak]` im App-Support-Verzeichnis,
/// NIE aendern (siehe Kopf der Datei).
class IoLocalStore extends CachingLocalStore {
  final Directory _dir;

  /// Testnaht: wird vor jedem Schritt eines Auftrags gerufen (`write-tmp`,
  /// `rotate-bak`, `commit`, `remove-tmp`, `remove-bak`, `remove-main`) und
  /// darf werfen, um einen Absturz oder Fehler an dieser Stelle zu spielen.
  @visibleForTesting
  void Function(String step)? beforeStep;

  IoLocalStore(this._dir);

  String _path(String name, [String suffix = '']) =>
      '${_dir.path}${Platform.pathSeparator}$name$suffix';

  @override
  Future<Map<String, StoredCopies>> loadAll() async {
    try {
      await _dir.create(recursive: true);
      final mains = <String, Uint8List>{};
      final baks = <String, Uint8List>{};
      await for (final entity in _dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final file = entity.uri.pathSegments.last;
        if (file.endsWith('.tmp')) {
          // Best effort: ein Rest, der sich nicht loeschen laesst, darf das
          // Oeffnen nicht verhindern (er wird nie gelesen).
          try {
            await entity.delete();
          } on FileSystemException {
            // bleibt liegen
          }
        } else if (file.endsWith('.bak')) {
          final name = file.substring(0, file.length - 4);
          if (isValidLocalStoreName(name)) {
            baks[name] = await entity.readAsBytes();
          }
        } else if (isValidLocalStoreName(file)) {
          mains[file] = await entity.readAsBytes();
        }
      }
      return {
        for (final name in {...mains.keys, ...baks.keys})
          name: StoredCopies(mains[name], baks[name]),
      };
    } on FileSystemException {
      throw const LocalStoreException(LocalStoreErrorKind.unavailable);
    }
  }

  @override
  Future<StoredCopies> load(String name) => _guard(() async {
        return StoredCopies(await _readOrNull(File(_path(name))),
            await _readOrNull(File(_path(name, '.bak'))));
      });

  @override
  Future<void> persistWrite(String name, Uint8List bytes) =>
      _guard(() => _discardTmpOnError(name, () async {
            await _writeTmp(name, bytes);
            _step('rotate-bak');
            final main = File(_path(name));
            // Ersetzt eine alte .bak. Fehlt die Hauptkopie (Absturz im letzten
            // Lauf), bleibt die .bak, wie sie ist.
            if (await main.exists()) await main.rename(_path(name, '.bak'));
            _step('commit');
            await File(_path(name, '.tmp')).rename(main.path);
          }));

  @override
  Future<void> persistRestore(String name, Uint8List bak) =>
      _guard(() => _discardTmpOnError(name, () async {
            await _writeTmp(name, bak);
            _step('commit');
            await File(_path(name, '.tmp')).rename(_path(name));
          }));

  // Reihenfolge: erst .bak, dann die Hauptkopie. Bricht es dazwischen ab,
  // bleibt die Hauptkopie; umgekehrt kaeme eine entfernte DB ueber die .bak
  // zurueck.
  @override
  Future<void> persistRemove(String name) => _guard(() async {
        _step('remove-tmp');
        await _deleteIfExists(File(_path(name, '.tmp')));
        _step('remove-bak');
        await _deleteIfExists(File(_path(name, '.bak')));
        _step('remove-main');
        await _deleteIfExists(File(_path(name)));
      });

  Future<void> _writeTmp(String name, Uint8List bytes) async {
    _step('write-tmp');
    final file = await File(_path(name, '.tmp')).open(mode: FileMode.write);
    try {
      await file.writeFrom(bytes);
      // fsync: erst danach darf das rename die Kopie sichtbar machen.
      await file.flush();
    } finally {
      await file.close();
    }
  }

  // Nach einem Fehler (z. B. Platte voll) darf kein Ciphertext in der .tmp
  // liegen bleiben: der Name ist dann evtl. unbekannt, und clear() fande ihn
  // nicht. Best effort; der Originalfehler wird nie verdeckt.
  Future<void> _discardTmpOnError(
      String name, Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {
      try {
        await _deleteIfExists(File(_path(name, '.tmp')));
      } catch (_) {}
      rethrow;
    }
  }

  void _step(String step) => beforeStep?.call(step);

  static Future<Uint8List?> _readOrNull(File file) async =>
      await file.exists() ? file.readAsBytes() : null;

  static Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }

  /// Bildet FileSystemException auf feste Fehler ab (nie roh nach oben).
  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on FileSystemException catch (e) {
      throw LocalStoreException(_isDiskFull(e.osError?.errorCode)
          ? LocalStoreErrorKind.full
          : LocalStoreErrorKind.io);
    }
  }

  // Fehlercodes je Plattform (Doku-Wissen; im Test ueber eine injizierte
  // Exception abgedeckt, nicht ueber eine volle Platte): ENOSPC 28, EDQUOT
  // Darwin 69 / Linux 122, Windows ERROR_DISK_FULL 112 und
  // ERROR_HANDLE_DISK_FULL 39 (unter Linux ist 39 ENOTEMPTY).
  static bool _isDiskFull(int? code) {
    if (code == null) return false;
    if (Platform.isWindows) return code == 112 || code == 39;
    if (Platform.isMacOS || Platform.isIOS) return code == 28 || code == 69;
    return code == 28 || code == 122;
  }
}
