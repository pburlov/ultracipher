// Lokaler Speicher der verschluesselten DB-Kopien (F4, siehe
// .claude/plans/f4-lokale-speicherung.md, Paragraph 3).
//
// Layout-Pin: Die Dateinamen auf dem Medium sind ein Persistenzformat und
// duerfen NIE geaendert werden, sonst "verschwinden" alle Datenbanken der
// Nutzer: dart:io legt `databases/<name>` und `databases/<name>.bak` im
// App-Support-Verzeichnis ab (rohe v1-Bytes, kein base64; `<name>.tmp` ist nur
// ein fluechtiges Zwischenstueck). Gepinnt in test/local_store_io_test.dart.
import 'dart:typed_data';

/// Speicher der verschluesselten DB-Kopien auf dem Geraet, adressiert ueber den
/// DB-Namen (base64url). Lesen ist synchron aus einem Cache, der beim Aufruf
/// von write/remove gilt; das Persistieren laeuft in einer FIFO-Warteschlange.
///
/// Uebergebene und gelieferte Bytes gehoeren dem Speicher: nicht veraendern.
abstract class LocalDatabaseStore {
  /// Laedt alle Haupt- und .bak-Kopien in den Cache und raeumt .tmp-Reste weg.
  /// Genau einmal, vor allem anderen (in UltracipherApp.init).
  Future<void> open();

  /// Namen mit Haupt- oder .bak-Kopie (Cache, synchron).
  Iterable<String> get names;

  /// Haupt- oder .bak-Kopie vorhanden.
  bool contains(String name);

  /// Rohe Hauptkopie aus dem Cache, sonst null; nie Ersatz durch die .bak.
  Uint8List? read(String name);

  /// Die PERSISTIERTE .bak (Cache), sonst null.
  Uint8List? readBackup(String name);

  /// Cache sofort; persistiert atomar, die alte Hauptkopie wird .bak.
  /// Wirft LocalStoreException (Future-Fehler), nie FileSystemException o. A.
  /// Ein ungueltiger Name wirft synchron ArgumentError.
  Future<void> write(String name, Uint8List bytes);

  /// Hauptkopie := .bak, OHNE Rotation (die gute .bak bleibt erhalten).
  /// Cache sofort. Ohne .bak wirft es synchron StateError.
  Future<void> restoreBackup(String name);

  /// Entfernt Haupt-, .bak- und .tmp-Kopie (Cache sofort).
  Future<void> remove(String name);

  /// Entfernt alle Namen (mit .bak und .tmp); fremde Dateien im Speicher
  /// bleiben (Erase).
  Future<void> clear();

  /// Liest die Hauptkopie am Cache vorbei vom Medium, nach allen bis dahin
  /// eingereihten Auftraegen (nur Migration, zum Verifizieren).
  Future<Uint8List?> readPersisted(String name);
}

enum LocalStoreErrorKind { full, unavailable, io }

class LocalStoreException implements Exception {
  final LocalStoreErrorKind kind;

  const LocalStoreException(this.kind);

  // Feste Meldungen, nie Pfad oder OS-Text (der Pfad enthaelt den DB-Namen).
  @override
  String toString() {
    switch (kind) {
      case LocalStoreErrorKind.full:
        return 'Not enough storage on this device; the change was not saved';
      case LocalStoreErrorKind.unavailable:
        return 'The storage of this app is not available';
      case LocalStoreErrorKind.io:
        return 'Saving on this device failed';
    }
  }
}

final RegExp _validName = RegExp(r'^[A-Za-z0-9_-]+$');

/// Der Name wird Dateiname bzw. Schluessel: kein Punkt (waere .bak/.tmp), kein
/// Pfadtrenner.
bool isValidLocalStoreName(String name) => _validName.hasMatch(name);
