// KDF-Profil 1 (P-32, §3.1). Der echte P-32-Lauf ist nur in der VM markiert
// (unter WASM ~10 s und bis ~1 GB Heap); Plumbing mit einem billigen Profil
// läuft überall. Referenzwerte stammen aus OpenSSL (Argon2id) und Python
// hashlib (scrypt) plus der Python-Dual-HKDF, nicht aus dieser Bibliothek.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/crypto/kdf_profile.dart';

import 'hex.dart';

KdfProfile _cheap() => KdfProfile(
      id: 1,
      argon2MemoryKiB: 64,
      argon2Iterations: 1,
      argon2Lanes: 1,
      scryptN: 16,
      scryptR: 8,
      scryptP: 1,
      argon2Salt: kdfProfile1.argon2Salt,
      scryptSalt: kdfProfile1.scryptSalt,
      combineSalt: kdfProfile1.combineSalt,
    );

void main() {
  group('Profil-Konstanten (P-32)', () {
    test('Parameter', () {
      final p = kdfProfile1;
      expect(p.id, 1);
      expect(p.argon2MemoryKiB, 32768);
      expect(p.argon2Iterations, 3);
      expect(p.argon2Lanes, 1);
      expect(p.scryptN, 65536);
      expect(p.scryptR, 8);
      expect(p.scryptP, 1);
      expect(kdfOutputLength, 64);
    });

    test('Salts byte-genau (Längen 26, 24)', () {
      expect(kdfProfile1.argon2Salt, ascii('ultracipher/kdf/1/argon2id'));
      expect(kdfProfile1.argon2Salt.length, 26);
      expect(kdfProfile1.scryptSalt, ascii('ultracipher/kdf/1/scrypt'));
      expect(kdfProfile1.scryptSalt.length, 24);
      expect(kdfProfile1.combineSalt, ascii('ultracipher/kdf/1/combine'));
    });

    test('Salts des globalen Profils sind nicht veränderbar', () {
      final copy = kdfProfile1.argon2Salt..[0] ^= 0xff;
      kdfProfile1.scryptSalt[0] ^= 0xff;
      kdfProfile1.combineSalt[0] ^= 0xff;
      expect(copy[0], isNot(kdfProfile1.argon2Salt[0]));
      expect(kdfProfile1.argon2Salt, ascii('ultracipher/kdf/1/argon2id'));
      expect(kdfProfile1.scryptSalt, ascii('ultracipher/kdf/1/scrypt'));
      expect(kdfProfile1.combineSalt, ascii('ultracipher/kdf/1/combine'));
    });

    test('Allow-List der Profile', () {
      expect(kdfProfileById(1), same(kdfProfile1));
      expect(kdfProfileById(0), isNull);
      expect(kdfProfileById(2), isNull);
    });
  });

  group('Passphrase-Bytes', () {
    test('trim, UTF-8, keine Normalisierung', () {
      expect(passphraseBytes('  abc \n'), ascii('abc'));
      expect(toHex(passphraseBytes('ä')), 'c3a4'); // NFC
      expect(toHex(passphraseBytes('ä')), '61cc88'); // NFD bleibt NFD
    });
  });

  group('combineRoot', () {
    test('K_A || K_S -> R gegen Python-Referenz', () {
      expect(
          toHex(combineRoot(counting(64), counting(64, 64), kdfProfile1)),
          '8b8ca4f5a8989ef9dbf225e7da582534949b74d6b1a5fa01f32219cf9fbf31b1'
          '158e559ce940748124401eb84febbdb6857f1d99e049c487f06fdecdd18960b2');
    });

    test('Reihenfolge K_A, K_S ist fest', () {
      expect(combineRoot(counting(64, 64), counting(64), kdfProfile1),
          isNot(combineRoot(counting(64), counting(64, 64), kdfProfile1)));
    });

    test('K_A und K_S müssen je 64 Byte lang sein', () {
      expect(() => combineRoot(counting(63), counting(64), kdfProfile1),
          throwsArgumentError);
      expect(() => combineRoot(counting(64), counting(65), kdfProfile1),
          throwsArgumentError);
      expect(() => combineRoot(Uint8List(0), counting(64), kdfProfile1),
          throwsArgumentError);
    });

    test('beide Ausgaben gehen ein', () {
      final base = combineRoot(counting(64), counting(64, 64), kdfProfile1);
      final a = counting(64)..[0] ^= 1;
      final s = counting(64, 64)..[63] ^= 1;
      expect(combineRoot(a, counting(64, 64), kdfProfile1), isNot(base));
      expect(combineRoot(counting(64), s, kdfProfile1), isNot(base));
    });
  });

  group('deriveRoot mit billigem Profil', () {
    test('deterministisch, trimmt, trennt Passphrasen', () {
      final p = _cheap();
      final r = deriveRoot('geheim', profile: p);
      expect(r.length, 64);
      expect(deriveRoot('geheim', profile: p), r);
      expect(deriveRoot('  geheim\n', profile: p), r);
      expect(deriveRoot('Geheim', profile: p), isNot(r));
    });

    test('billiges Profil gegen OpenSSL/Python-Referenz (VM und WASM)', () {
      // Argon2id m=64 KiB t=1 p=1 aus OpenSSL, scrypt N=16 r=8 p=1 aus
      // Python hashlib, Kombination über die Python-Dual-HKDF.
      final bytes = passphraseBytes('geheim');
      final p = _cheap();
      expect(
          toHex(deriveArgon2idKey(bytes, p)),
          '7dbd323722302fe5cc02e1dfb2c2cce48eb849aa484c802cd882870bdbb620dc'
          '16abd55673cdc837c09ab50197a502db9e46f1afa0a4c2c4f35d33d874b3abc3');
      expect(
          toHex(deriveScryptKey(bytes, p)),
          '45b22b7a549e53987d26b0d0fdeda62ec92f9fb9dce6a2353e0eb93d3c949570'
          '55b75009e798e30196346b16d34e84b76cc32f937a2bcc3844e2d7196d4f4595');
      expect(
          toHex(deriveRoot('geheim', profile: p)),
          '6dcc0c9fac9f3b3f25ef808355a46e4d8ad309eddcdff3bd7b7fbfa74c2b2e7b'
          '4637b13ea9aeee7418691b741d41c6f8f3cf7610f2e162291dee641036271237');
    });

    test('R entsteht aus beiden KDF-Ausgaben', () {
      final p = _cheap();
      final bytes = passphraseBytes('geheim');
      final ka = deriveArgon2idKey(bytes, p);
      final ks = deriveScryptKey(bytes, p);
      expect(ka.length, 64);
      expect(ks.length, 64);
      expect(ka, isNot(ks));
      expect(deriveRoot('geheim', profile: p), combineRoot(ka, ks, p));
    });
  });

  group('echtes P-32', () {
    test('Argon2id, scrypt und R gegen OpenSSL/Python-Referenz', () {
      final bytes = passphraseBytes('correct horse battery staple 42!');
      final ka = deriveArgon2idKey(bytes, kdfProfile1);
      final ks = deriveScryptKey(bytes, kdfProfile1);
      expect(
          toHex(ka),
          'c07b46b2f8c4e390a9e1af62d11213237e60a3451cfd2de74b0c0f8696b50831'
          '71e912363193e2e78cb3590a92e155f95370a64e8f9239d81d69b925e29bb8d9');
      expect(
          toHex(ks),
          'a9e0cb19d1ab72db27d29bc4524ab8fcbb668818dff11eb9166a669e102d183b'
          '281c0609680f7935850027ae2ea18b76b864308b274aca970d12a5b0e4118245');
      expect(
          toHex(deriveRoot('correct horse battery staple 42!')),
          '55d31c3dc9da1496d013e6026044436361a7590153657f11df2c042432fd6c91'
          '924e624d5f25e1dbd4e9267d83e3f926199ade69e5eb3dc4686888fd3d323218');
    }, testOn: 'vm', timeout: const Timeout(Duration(minutes: 2)));
  });
}
