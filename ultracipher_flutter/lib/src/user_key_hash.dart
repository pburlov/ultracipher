import 'dart:convert';
import 'dart:typed_data';

import 'crypto/dual_hkdf.dart';
import 'crypto/kdf_profile.dart';

// Datenbankname (Spezifikation §2.1): eigener Dual-HKDF-Zweig von `R`.
// Die Präfixe "ultracipher/name/..." und "ultracipher/file/..." bleiben
// disjunkt, damit Name und Dateischlüssel nie denselben Zweig teilen.
final Uint8List _nameSalt = Uint8List.fromList(ascii.encode('ultracipher/name'));
final Uint8List _nameInfo =
    Uint8List.fromList(ascii.encode('ultracipher/name/1'));

/// Länge der Namens-Rohbytes (base64url ohne Padding ergibt 43 Zeichen).
const int databaseNameBytes = 32;

/// Name einer Datenbank: base64url (ohne `=`) von
/// `DualExpand(DualExtract("ultracipher/name", R), "ultracipher/name/1", 32)`.
///
/// Er benennt die lokale Kopie (`ucdb_<name>`) und die GitHub-Datei
/// (`<name>.txt`). `R` selbst taucht nie auf, und der Name entsteht nur aus
/// `R` (also aus beiden KDF-Ausgaben, §2.4).
///
/// Das Label enthält bewusst keine Formatversion. Diese Konstruktion nicht
/// ändern: ein Byte Abweichung gibt jeder Datenbank einen neuen Namen und
/// verwaist jede lokale Kopie und jede GitHub-Datei.
String databaseName(Uint8List root) {
  if (root.length != kdfOutputLength) {
    throw ArgumentError.value(root.length, 'root.length',
        'R muss $kdfOutputLength Byte lang sein');
  }
  final bytes =
      dualExpand(dualExtract(_nameSalt, root), _nameInfo, databaseNameBytes);
  return base64Url.encode(bytes).replaceAll('=', '');
}
