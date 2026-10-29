import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ultracipher_flutter/src/model/extensions.dart';
import 'package:ultracipher_flutter/src/model/model.dart';

import 'crypto/format_v1.dart';

// Codec zwischen Datenbank und den Klartext-Bytes von Format v1
// (Spezifikation §11): JSON -> UTF-8 -> BZip2, ohne TAR, und ohne die
// konstante BZip2-Kennung `BZh9` (4 Byte; der Encoder von `archive` schreibt
// immer Blockgröße 9). Verschlüsseln und Authentifizieren macht [FormatV1].

/// Die vier Bytes `BZh9`, die der Encoder immer voranstellt.
const List<int> bzip2StreamHeader = [0x42, 0x5A, 0x68, 0x39];

/// Grenze für entpackte Bytes (Spezifikation §6, "Präzisierungen"). Sie greift
/// erst nach gültigem MAC und fängt eine BZip2-Bombe aus einer gültig
/// signierten Datei ab.
const int maxDecompressedLength = 512 * 1024 * 1024;

/// Obergrenze für den base64-Text einer Datei, die [maxFileLength] Bytes
/// ergibt (gepolstertes base64). Vor dem Dekodieren zu prüfen: der Text soll
/// nie größer werden als das, was das Format ohnehin ablehnt.
const int maxBase64Length = 4 * ((maxFileLength + 2) ~/ 3);

/// Dekodiert base64-Text mit Längengrenze ([maxBase64Length]) VOR dem
/// Dekodieren. Wirft [FormatException] (ohne Textauszug) bei zu langem oder
/// ungültigem Text.
Uint8List decodeBase64Bounded(String text) {
  if (text.length > maxBase64Length) {
    throw const FormatException('Text is too large');
  }
  try {
    return base64.decode(text);
  } on FormatException {
    // Ohne Details: die Originalmeldung kann Teile des Texts enthalten.
    throw const FormatException('Invalid base64 text');
  }
}

/// Ausgabe-Puffer mit Obergrenze: der Dekoder ruft nur `writeByte`.
class _LimitedOutput extends OutputMemoryStream {
  final int limit;
  _LimitedOutput(this.limit);

  @override
  void writeByte(int value) {
    if (length >= limit) {
      throw const FormatException('Decompressed data is too large');
    }
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    if (this.length + (length ?? bytes.length) > limit) {
      throw const FormatException('Decompressed data is too large');
    }
    super.writeBytes(bytes, length: length);
  }
}

/// BZip2 ohne die 4-Byte-Kennung. Wirft [StateError], wenn der Encoder etwas
/// anderes als `BZh9` schreibt (dann wäre das Abschneiden nicht umkehrbar).
Uint8List compressStripped(List<int> data) {
  final bz2 = BZip2Encoder().encodeBytes(data);
  for (var i = 0; i < bzip2StreamHeader.length; i++) {
    if (bz2.length <= i || bz2[i] != bzip2StreamHeader[i]) {
      throw StateError('Unexpected BZip2 stream header');
    }
  }
  return Uint8List.sublistView(bz2, bzip2StreamHeader.length);
}

/// Gegenstück zu [compressStripped]: stellt `BZh9` voran und entpackt mit der
/// Grenze [limit]. Wirft [FormatException] bei beschädigtem Strom oder
/// überschrittener Grenze.
Uint8List decompressStripped(Uint8List stripped,
    {int limit = maxDecompressedLength}) {
  final withHeader =
      Uint8List(bzip2StreamHeader.length + stripped.length)
        ..setRange(0, bzip2StreamHeader.length, bzip2StreamHeader)
        ..setRange(bzip2StreamHeader.length,
            bzip2StreamHeader.length + stripped.length, stripped);
  final out = _LimitedOutput(limit);
  bool ok;
  try {
    ok = BZip2Decoder()
        .decodeStream(InputMemoryStream(withHeader), out, verify: true);
  } on FormatException {
    rethrow;
  } catch (_) {
    // z. B. RangeError bei abgeschnittenem Strom; ohne Details.
    throw const FormatException('Invalid compressed data');
  }
  if (!ok) throw const FormatException('Invalid compressed data');
  return out.getBytes();
}

/// Datenbank -> Datei v1 (frischer `file_salt`, außer in Tests).
Uint8List encryptDatabaseV1(UltracipherDatabase database, Uint8List root,
    {Uint8List? fileSalt}) {
  final json = utf8.encode(jsonEncode(database.toJson()));
  return FormatV1.seal(compressStripped(json), root, fileSalt ?? newFileSalt());
}

/// Datei v1 -> Datenbank. Formatfehler im Kopf werfen
/// [UltracipherFormatException], falsches `R` oder beschädigte Bytes
/// [UltracipherAuthenticationException], alles danach [FormatException].
UltracipherDatabase decryptDatabaseV1(Uint8List bytes, Uint8List root) {
  final compressed = FormatV1.open(bytes, root);
  final plain = decompressStripped(compressed);
  final text = utf8.decode(plain);
  plain.fillWith(randomIntegers(0xFFFFFFFF));
  return UltracipherDatabase.fromJson(jsonDecode(text));
}
