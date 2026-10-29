// Dual-HKDF (§3.3): HKDF-Schleife gegen RFC 5869, die Komposition gegen eine
// unabhängige Python-Referenz (hashlib/hmac), dazu Eigenschaften. Läuft auch
// unter WASM (Befehl siehe crypto_kat_test.dart).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:ultracipher_flutter/src/crypto/dual_hkdf.dart';

import 'hex.dart';

void main() {
  group('hkdfExpand gegen RFC 5869 (SHA-256, Schleife inkl. Mehrblock)', () {
    HMac sha256() => HMac(SHA256Digest(), 64);

    test('Testfall 1 (42 B, zwei Blöcke)', () {
      final salt = counting(13);
      final ikm = Uint8List.fromList(List.filled(22, 0x0b));
      final info = counting(10, 0xf0);
      final prk = hmacOnce(sha256(), salt, ikm);
      expect(toHex(prk),
          '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5');
      expect(
          toHex(hkdfExpand(sha256(), prk, info, 42)),
          '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
          '34007208d5b887185865');
    });

    test('Testfall 2 (82 B, drei Blöcke)', () {
      final prk = hmacOnce(sha256(), counting(80, 0x60), counting(80));
      expect(toHex(prk),
          '06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244');
      expect(
          toHex(hkdfExpand(sha256(), prk, counting(80, 0xb0), 82)),
          'b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c'
          '59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71'
          'cc30c58179ec3e87c14c01d5c1f3434f1d87');
    });

    test('Testfall 3 (leeres Salt und Info)', () {
      final ikm = Uint8List.fromList(List.filled(22, 0x0b));
      final prk = hmacOnce(sha256(), Uint8List(0), ikm);
      expect(toHex(prk),
          '19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04');
      expect(
          toHex(hkdfExpand(sha256(), prk, Uint8List(0), 42)),
          '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d'
          '9d201395faa4b61a96c8');
    });

    test('Länge über 255 * Hashlänge ist verboten', () {
      expect(
          () => hkdfExpand(sha256(), Uint8List(32), Uint8List(0), 255 * 32 + 1),
          throwsArgumentError);
    });
  });

  group('Dual-HKDF', () {
    // Referenz: unabhängige Python-Implementierung derselben Definition
    // (hashlib.sha512/sha3_512, hmac), siehe Spezifikation §3.3.
    final salt = counting(32);
    final ikm = counting(64, 100);
    final info = ascii('ultracipher/test/dual');

    test('DualExtract = (HMAC-SHA-512, HMAC-SHA3-512)', () {
      final p = dualExtract(salt, ikm);
      expect(
          toHex(p.p1),
          'db27f8985ebf256e416bb69c5afdbd2f41c7e2a94b3e3ee06b81e56dd8279a8e'
          '7c1c4e9103f5f9bdaa4ff4030ecff8116d3b66a64d7aa0900be2cfb4bb32bf93');
      expect(
          toHex(p.p2),
          '09395a1bcfbde0e478341d271f217a216539abb687dc17ee85393bad122eedf2'
          'd2af133711afd057bc83d86a320f8bf02b1dd67c719d3830ff5ce4bf4a20ef51');
    });

    test('DualExpand für L = 1, 32, 64', () {
      final p = dualExtract(salt, ikm);
      const full64 =
          '900e21e7f02e2f9bc88eb42c761e1c509532bd0252b0457c8e064440c70c1259'
          'f0fbb55ca42b2098a0fe081bc1d30cd4efa50f5ff99b0116a21eb2e0534f4108';
      expect(toHex(dualExpand(p, info, 1)), '90');
      expect(toHex(dualExpand(p, info, 32)), full64.substring(0, 64));
      expect(toHex(dualExpand(p, info, 64)), full64);
    });

    test('Länge nur 1..64', () {
      final p = dualExtract(salt, ikm);
      expect(() => dualExpand(p, info, 0), throwsArgumentError);
      expect(() => dualExpand(p, info, 65), throwsArgumentError);
    });

    test('jede Hälfte wirkt: Änderung nur eines PRK ändert die Ausgabe', () {
      final p = dualExtract(salt, ikm);
      final base = dualExpand(p, info, 64);
      final p1 = Uint8List.fromList(p.p1)..[0] ^= 1;
      final p2 = Uint8List.fromList(p.p2)..[0] ^= 1;
      expect(dualExpand(DualPrk(p1, p.p2), info, 64), isNot(base));
      expect(dualExpand(DualPrk(p.p1, p2), info, 64), isNot(base));
    });

    test('Ausgabe ist das XOR beider Einzel-HKDFs', () {
      final p = dualExtract(salt, ikm);
      final a = hkdfExpand(HMac(SHA512Digest(), 128), p.p1, info, 64);
      final b = hkdfExpand(HMac(SHA3Digest(512), 72), p.p2, info, 64);
      expect(dualExpand(p, info, 64),
          Uint8List.fromList([for (var i = 0; i < 64; i++) a[i] ^ b[i]]));
    });

    test('Info und Salt trennen die Ausgaben', () {
      final p = dualExtract(salt, ikm);
      expect(
          dualExpand(p, ascii('a'), 32), isNot(dualExpand(p, ascii('b'), 32)));
      final q = dualExtract(counting(32, 1), ikm);
      expect(dualExpand(q, info, 32), isNot(dualExpand(p, info, 32)));
    });
  });
}
