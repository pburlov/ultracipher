import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// Dual-HKDF (Spezifikation §3.3): der einzige Kombinierer des Formats, an
// genau dieser Stelle. Kein Standard-HKDF, sondern zwei Standard-HKDFs
// (SHA-512 und SHA3-512) auf derselben Eingabe, per XOR verknüpft.

/// Zwischenschlüssel von [dualExtract]: je ein PRK pro Hashfamilie.
class DualPrk {
  final Uint8List p1; // HMAC-SHA-512
  final Uint8List p2; // HMAC-SHA3-512
  DualPrk(this.p1, this.p2);
}

/// Höchstlänge von [dualExpand]: ein Hash-Block (64 B) beider Familien.
const int dualExpandMaxLength = 64;

// HMAC-Blocklänge ist bei SHA-3 die Rate (r = 200 - 2 * Digest-Bytes), nicht
// die Zustandsgröße: SHA3-512 -> 72, SHA3-256 -> 136. Ein falscher Wert
// liefe still weiter und wäre nur mit Testvektoren zu entdecken.
HMac newHmacSha512() => HMac(SHA512Digest(), 128);
HMac newHmacSha3_512() => HMac(SHA3Digest(512), 72);
HMac newHmacSha3_256() => HMac(SHA3Digest(256), 136);

/// Einmal-HMAC über [data]; auch für die MAC-Tags des Formats.
Uint8List hmacOnce(HMac mac, Uint8List key, Uint8List data) {
  mac.init(KeyParameter(key));
  mac.update(data, 0, data.length);
  final out = Uint8List(mac.macSize);
  mac.doFinal(out, 0);
  return out;
}

/// HKDF-Expand nach RFC 5869 über einen beliebigen HMAC.
///
/// Öffentlich, damit die Schleife (auch der Mehrblock-Fall) gegen die
/// RFC-5869-Vektoren mit SHA-256 geprüft werden kann; die RFC hat keine
/// Vektoren für SHA-512/SHA3.
Uint8List hkdfExpand(HMac mac, Uint8List prk, Uint8List info, int length) {
  final hashLen = mac.macSize;
  if (length < 0 || length > 255 * hashLen) {
    throw ArgumentError.value(length, 'length');
  }
  final out = Uint8List(length);
  var t = Uint8List(0);
  var pos = 0;
  for (var counter = 1; pos < length; counter++) {
    mac.init(KeyParameter(prk));
    mac.update(t, 0, t.length);
    mac.update(info, 0, info.length);
    mac.update(Uint8List.fromList([counter]), 0, 1);
    t = Uint8List(hashLen);
    mac.doFinal(t, 0);
    final n = length - pos < hashLen ? length - pos : hashLen;
    out.setRange(pos, pos + n, t);
    pos += n;
  }
  return out;
}

/// `(HMAC-SHA-512(salt, ikm), HMAC-SHA3-512(salt, ikm))` = HKDF-Extract je Hash.
DualPrk dualExtract(Uint8List salt, Uint8List ikm) => DualPrk(
    hmacOnce(newHmacSha512(), salt, ikm),
    hmacOnce(newHmacSha3_512(), salt, ikm));

/// `HKDF-Expand-SHA-512(p1, info, L) XOR HKDF-Expand-SHA3-512(p2, info, L)`.
///
/// Heuristik, kein Beweis: ist eine der beiden Hälften pseudozufällig, ist es
/// die Summe (siehe Spezifikation §3.3). `length` höchstens 64.
Uint8List dualExpand(DualPrk prk, Uint8List info, int length) {
  if (length < 1 || length > dualExpandMaxLength) {
    throw ArgumentError.value(length, 'length', 'muss 1..64 sein');
  }
  final a = hkdfExpand(newHmacSha512(), prk.p1, info, length);
  final b = hkdfExpand(newHmacSha3_512(), prk.p2, info, length);
  for (var i = 0; i < length; i++) {
    a[i] ^= b[i];
  }
  return a;
}
