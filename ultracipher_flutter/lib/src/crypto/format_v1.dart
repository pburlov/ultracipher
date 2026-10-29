import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'cascade.dart';
import 'constant_time.dart';
import 'dual_hkdf.dart';
import 'kdf_profile.dart';

// Ultracipher-Format v1, byte-genau (Spezifikation §6). Alle Ganzzahlen
// Big-Endian.
//
//   0  4  magic "UCDB"        44  n  C (n >= 16, n % 16 == 0)
//   4  2  format_version = 1  44+n 64 T1 = HMAC-SHA-512(k1, Header || C)
//   6  2  suite_id = 1       108+n 32 T2 = HMAC-SHA3-256(k2, Header || C)
//   8  2  kdf_profile = 1
//  10  2  flags = 0
//  12 32  file_salt
//
// Komprimierung (JSON -> BZip2) gehört nicht hierher: `seal` bekommt die
// schon komprimierten Bytes und `open` liefert sie zurück (App-Schritt).

const int formatVersion1 = 1;
const int suiteId1 = 1;
const int headerLength = 44;
const int tag1Length = 64;
const int tag2Length = 32;
const int _blockSize = 16;

/// Kleinste mögliche Datei: Header + ein Block + beide Tags.
const int minFileLength = headerLength + _blockSize + tag1Length + tag2Length;

/// Grenze für die Dateigröße (decodierte Bytes), geprüft vor jeder Krypto.
const int maxFileLength = 64 * 1024 * 1024;

// "UCDB"; const, damit niemand die Magic zur Laufzeit ändern kann.
const List<int> _magic = [0x55, 0x43, 0x44, 0x42];

/// Grund eines sauberen Formatfehlers (nicht: Authentifizierung).
enum FormatErrorKind {
  badMagic,
  unsupportedVersion,
  unsupportedSuite,
  unsupportedKdfProfile,
  unsupportedFlags,
  tooLarge,
}

/// Kopf ist erkennbar nicht (oder nicht mehr) dieses Format. Die Meldung ist
/// eine feste Zeichenkette ohne Dateiinhalt.
class UltracipherFormatException implements Exception {
  final FormatErrorKind kind;
  final String message;
  UltracipherFormatException(this.kind, this.message);
  @override
  String toString() => 'UltracipherFormatException: $message';
}

/// Einziger Fehler für alles, was nach dem Header schiefgeht (falsches `R`,
/// verfälschte Bytes, falsche Länge, ungültiges Padding). Er nennt nicht, ob
/// ein Tag oder welcher scheiterte: kein Orakel.
class UltracipherAuthenticationException implements Exception {
  @override
  String toString() =>
      'UltracipherAuthenticationException: falsches Passwort oder beschädigt';
}

/// Zufälliger `file_salt` (32 B) aus `Random.secure()`. Der einzige Zufall des
/// Formats; `seal` bekommt ihn als Parameter und hat bewusst keinen
/// Standardwert aus Zeit oder Zähler. Keine austauschbare Zufallsquelle: Tests
/// geben feste Salts direkt an `seal`.
Uint8List newFileSalt() {
  final r = Random.secure();
  return Uint8List.fromList(
      List<int>.generate(fileSaltLength, (_) => r.nextInt(256)));
}

/// Füllbytes bis zum nächsten Vielfachen von 16: `0x80`, dann `0x00`;
/// immer mindestens ein Byte (ISO/IEC 7816-4).
Uint8List padIso7816(Uint8List data) {
  final padded = data.length + _blockSize - (data.length % _blockSize);
  final out = Uint8List(padded)..setRange(0, data.length, data);
  out[data.length] = 0x80;
  return out;
}

/// Gegenstück zu [padIso7816]; `null` bei ungültigem Padding. Nur die
/// kanonische Form (1..16 Füllbytes) gilt. Nur nach
/// erfolgreicher MAC-Prüfung aufrufen (sonst Padding-Orakel).
Uint8List? unpadIso7816(Uint8List data) {
  var i = data.length - 1;
  while (i >= 0 && data[i] == 0x00) {
    i--;
  }
  if (i < 0 || data[i] != 0x80) return null;
  if (data.length - i > _blockSize) return null; // länger als ein Block
  return Uint8List.sublistView(data, 0, i);
}

Uint8List _buildHeader(Uint8List fileSalt, int kdfProfile) {
  final h = Uint8List(headerLength);
  final view = ByteData.sublistView(h);
  h.setRange(0, 4, _magic);
  view.setUint16(4, formatVersion1);
  view.setUint16(6, suiteId1);
  view.setUint16(8, kdfProfile);
  view.setUint16(10, 0); // flags
  h.setRange(12, headerLength, fileSalt);
  return h;
}

Uint8List _mac(
    HMac mac, Uint8List key, Uint8List header, Uint8List ciphertext) {
  // Der MAC deckt Header UND Ciphertext ab (§5); nur so ist die Version
  // selbst authentifiziert.
  mac.init(KeyParameter(key));
  mac.update(header, 0, header.length);
  mac.update(ciphertext, 0, ciphertext.length);
  final out = Uint8List(mac.macSize);
  mac.doFinal(out, 0);
  return out;
}

/// Geprüfte Kopffelder, die der Rest von `open` braucht.
class FormatV1Header {
  final Uint8List fileSalt;
  final Uint8List hdr12;
  FormatV1Header(this.fileSalt, this.hdr12);
}

/// Namensraum für `seal`/`open`/`parseHeader` von Format v1.
class FormatV1 {
  FormatV1._();

  /// Ob [bytes] mit der Magic `UCDB` beginnen. Nur dieser billige Test, keine
  /// Krypto und kein `R`; er trennt v1-Dateien von alten (z. B. v2 mit
  /// führendem 0x00).
  static bool hasMagic(Uint8List bytes) {
    if (bytes.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  /// Verschlüsselt und authentifiziert [plain] (bereits komprimierte Bytes).
  ///
  /// Padding auf 16 B passiert hier. [fileSalt] (32 B) muss bei jedem Schreiben
  /// frisch aus [newFileSalt] kommen; nur Tests geben ihn fest vor.
  static Uint8List seal(Uint8List plain, Uint8List root, Uint8List fileSalt,
      {KdfProfile? profile}) {
    final p = profile ?? kdfProfile1;
    if (fileSalt.length != fileSaltLength) {
      throw ArgumentError.value(
          fileSalt.length, 'fileSalt.length', 'muss 32 sein');
    }
    final paddedLength =
        plain.length + _blockSize - (plain.length % _blockSize);
    // Ein Schreiber darf keine Datei erzeugen, die sein eigener Leser ablehnt.
    if (headerLength + paddedLength + tag1Length + tag2Length > maxFileLength) {
      throw ArgumentError.value(plain.length, 'plain.length', 'zu groß');
    }
    final header = _buildHeader(fileSalt, p.id);
    final keys = FileKeys.derive(
        root, fileSalt, Uint8List.sublistView(header, 0, headerPrefixLength));
    final ciphertext = applyCascade(keys, padIso7816(plain));
    final t1 = _mac(newHmacSha512(), keys.hmacSha512Key, header, ciphertext);
    final t2 = _mac(newHmacSha3_256(), keys.hmacSha3Key, header, ciphertext);
    final tagsAt = headerLength + ciphertext.length;
    return Uint8List(tagsAt + tag1Length + tag2Length)
      ..setRange(0, headerLength, header)
      ..setRange(headerLength, tagsAt, ciphertext)
      ..setRange(tagsAt, tagsAt + tag1Length, t1)
      ..setRange(tagsAt + tag1Length, tagsAt + tag1Length + tag2Length, t2);
  }

  /// Prüft Größe, Magic, Version, Suite, KDF-Profil und Flags als Allow-List,
  /// danach die Längenstruktur. Keine Krypto, kein `R` nötig.
  ///
  /// [expectedKdfProfile] ist das Profil, mit dem `R` entstand; die Datei
  /// darf kein anderes verlangen (KDF-Parameter kommen nie aus der Datei).
  static FormatV1Header parseHeader(Uint8List bytes,
      {int? expectedKdfProfile}) {
    final expected = expectedKdfProfile ?? kdfProfile1.id;
    if (bytes.length > maxFileLength) {
      throw UltracipherFormatException(
          FormatErrorKind.tooLarge, 'Datei ist zu groß');
    }
    if (bytes.length < _magic.length) {
      throw UltracipherAuthenticationException();
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw UltracipherFormatException(FormatErrorKind.badMagic,
            'kein Ultracipher-v1-Format (alte Dateien per CSV übernehmen)');
      }
    }
    if (bytes.length < headerPrefixLength) {
      throw UltracipherAuthenticationException();
    }
    final view = ByteData.sublistView(bytes);
    // Reihenfolge vor der Längenprüfung: eine neuere Version darf eine
    // andere Struktur haben und soll "neuere App nötig" melden.
    if (view.getUint16(4) != formatVersion1) {
      throw UltracipherFormatException(FormatErrorKind.unsupportedVersion,
          'nicht unterstützte Formatversion (neuere App nötig)');
    }
    if (view.getUint16(6) != suiteId1) {
      throw UltracipherFormatException(FormatErrorKind.unsupportedSuite,
          'nicht unterstützte Verschlüsselungs-Suite (neuere App nötig)');
    }
    if (view.getUint16(8) != expected) {
      throw UltracipherFormatException(FormatErrorKind.unsupportedKdfProfile,
          'Datei gehört zu einem anderen KDF-Profil');
    }
    if (view.getUint16(10) != 0) {
      throw UltracipherFormatException(FormatErrorKind.unsupportedFlags,
          'unbekannte Flags (neuere App nötig)');
    }
    if (bytes.length < minFileLength ||
        (bytes.length - headerLength - tag1Length - tag2Length) % _blockSize !=
            0) {
      throw UltracipherAuthenticationException();
    }
    return FormatV1Header(Uint8List.fromList(bytes.sublist(12, headerLength)),
        Uint8List.fromList(bytes.sublist(0, headerPrefixLength)));
  }

  /// Prüft beide Tags und entschlüsselt erst danach; liefert die (komprimierten)
  /// Klartext-Bytes ohne Padding.
  ///
  /// Header-Fehler: [UltracipherFormatException]. Alles andere, auch ein
  /// falsches [root]: [UltracipherAuthenticationException].
  static Uint8List open(Uint8List bytes, Uint8List root,
      {int? expectedKdfProfile}) {
    final header = parseHeader(bytes, expectedKdfProfile: expectedKdfProfile);
    final keys = FileKeys.derive(root, header.fileSalt, header.hdr12);
    final tagsAt = bytes.length - tag1Length - tag2Length;
    final signed = Uint8List.sublistView(bytes, 0, headerLength);
    final ciphertext = Uint8List.sublistView(bytes, headerLength, tagsAt);
    final t1 = _mac(newHmacSha512(), keys.hmacSha512Key, signed, ciphertext);
    final t2 = _mac(newHmacSha3_256(), keys.hmacSha3Key, signed, ciphertext);
    // Beide Tags immer berechnen und vergleichen, Ergebnisse mit `|`
    // verknüpfen (kein `&&`): kein Hinweis, welcher Tag scheiterte.
    final diff = constantTimeDiff(
            t1, Uint8List.sublistView(bytes, tagsAt, tagsAt + tag1Length)) |
        constantTimeDiff(t2, Uint8List.sublistView(bytes, tagsAt + tag1Length));
    if (diff != 0) throw UltracipherAuthenticationException();
    final plain = unpadIso7816(applyCascade(keys, ciphertext));
    // Nach gültigem MAC kann nur ein fehlerhafter Schreiber falsches Padding
    // erzeugen; derselbe neutrale Fehler genügt.
    if (plain == null) throw UltracipherAuthenticationException();
    return plain;
  }
}
