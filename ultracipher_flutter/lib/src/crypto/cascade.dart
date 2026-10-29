import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'dual_hkdf.dart';

// Dateischlüssel (§3.4) und Drei-Schichten-Kaskade (§4).
//
// C = P xor KS_AES xor KS_Twofish xor KS_ChaCha. XOR ist kommutativ, die
// Reihenfolge "AES, Twofish, ChaCha20" ist trotzdem fest, damit es nur eine
// Implementierung gibt. Verschlüsseln und Entschlüsseln sind dieselbe
// Operation.

/// Länge von `hdr12`: Magic, Version, Suite, Profil, Flags.
const int headerPrefixLength = 12;

/// Länge des `file_salt` im Header.
const int fileSaltLength = 32;

/// Länge von `R`.
const int rootLength = 64;

/// Alle acht Teilschlüssel eines Schreibvorgangs. Der Konstruktor ist
/// öffentlich, damit Tests einzelne Schlüssel gezielt verändern können.
class FileKeys {
  final Uint8List aesKey; // 32
  final Uint8List aesIv; // 16
  final Uint8List twofishKey; // 32
  final Uint8List twofishIv; // 16
  final Uint8List chachaKey; // 32
  final Uint8List chachaNonce; // 12
  final Uint8List hmacSha512Key; // 64
  final Uint8List hmacSha3Key; // 64

  FileKeys({
    required this.aesKey,
    required this.aesIv,
    required this.twofishKey,
    required this.twofishIv,
    required this.chachaKey,
    required this.chachaNonce,
    required this.hmacSha512Key,
    required this.hmacSha3Key,
  });

  /// `(F1, F2) = DualExtract(file_salt, R)`; jeder Schlüssel mit eigenem Label,
  /// `hdr12` steckt in jedem `info` (andere Suite/Version -> andere Schlüssel).
  factory FileKeys.derive(Uint8List root, Uint8List fileSalt, Uint8List hdr12) {
    if (root.length != rootLength) {
      throw ArgumentError.value(root.length, 'root.length', 'muss 64 sein');
    }
    if (fileSalt.length != fileSaltLength) {
      throw ArgumentError.value(
          fileSalt.length, 'fileSalt.length', 'muss 32 sein');
    }
    if (hdr12.length != headerPrefixLength) {
      throw ArgumentError.value(hdr12.length, 'hdr12.length', 'muss 12 sein');
    }
    final prk = dualExtract(fileSalt, root);
    Uint8List k(String label, int length) =>
        dualExpand(prk, fileKeyInfo(label, hdr12), length);
    return FileKeys(
      aesKey: k('aes-256-ctr/key', 32),
      aesIv: k('aes-256-ctr/iv', 16),
      twofishKey: k('twofish-256-ctr/key', 32),
      twofishIv: k('twofish-256-ctr/iv', 16),
      chachaKey: k('chacha20/key', 32),
      chachaNonce: k('chacha20/nonce', 12),
      hmacSha512Key: k('hmac-sha512/key', 64),
      hmacSha3Key: k('hmac-sha3-256/key', 64),
    );
  }
}

/// `info = ASCII "ultracipher/file/" || label || 0x00 || hdr12`.
Uint8List fileKeyInfo(String label, Uint8List hdr12) {
  final prefix = ascii.encode('ultracipher/file/$label');
  return Uint8List(prefix.length + 1 + hdr12.length)
    ..setRange(0, prefix.length, prefix)
    ..setRange(prefix.length + 1, prefix.length + 1 + hdr12.length, hdr12);
}

Uint8List _run(StreamCipher cipher, Uint8List data) {
  final out = Uint8List(data.length);
  cipher.processBytes(data, 0, data.length, out, 0);
  return out;
}

/// Schickt [data] durch AES-256-CTR, Twofish-256-CTR und ChaCha20 (Zähler
/// ab 0). Für beide Richtungen; die Länge bleibt gleich.
Uint8List applyCascade(FileKeys keys, Uint8List data) {
  final aes = CTRStreamCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(keys.aesKey), keys.aesIv));
  final twofish = CTRStreamCipher(TwofishEngine())
    ..init(
        true, ParametersWithIV(KeyParameter(keys.twofishKey), keys.twofishIv));
  final chacha = ChaCha7539Engine()
    ..init(
        true, ParametersWithIV(KeyParameter(keys.chachaKey), keys.chachaNonce));
  return _run(chacha, _run(twofish, _run(aes, data)));
}
