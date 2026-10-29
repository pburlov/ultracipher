// Dateischlüssel (§3.4) und Drei-Schichten-Kaskade (§4). Läuft auch unter
// WASM (Befehl siehe crypto_kat_test.dart).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/crypto/cascade.dart';

import 'hex.dart';
import 'reference.dart';

final _root =
    Uint8List.fromList([for (var i = 0; i < 64; i++) (i * 7 + 3) & 255]);
final _salt = Uint8List.fromList([for (var i = 0; i < 32; i++) 255 - i]);
final _hdr12 = hex('554344420001000100010000');

FileKeys _copy(FileKeys k,
        {Uint8List? aesKey,
        Uint8List? aesIv,
        Uint8List? twofishKey,
        Uint8List? twofishIv,
        Uint8List? chachaKey,
        Uint8List? chachaNonce}) =>
    FileKeys(
      aesKey: aesKey ?? k.aesKey,
      aesIv: aesIv ?? k.aesIv,
      twofishKey: twofishKey ?? k.twofishKey,
      twofishIv: twofishIv ?? k.twofishIv,
      chachaKey: chachaKey ?? k.chachaKey,
      chachaNonce: chachaNonce ?? k.chachaNonce,
      hmacSha512Key: k.hmacSha512Key,
      hmacSha3Key: k.hmacSha3Key,
    );

Uint8List _flipBit(Uint8List b, int bit) =>
    (Uint8List.fromList(b))..[bit ~/ 8] ^= 1 << (bit % 8);

/// Erwartete Kaskade aus drei unabhängig gerechneten Schlüsselströmen.
Uint8List _expected(FileKeys k, Uint8List data) => xorAll([
      data,
      aesKeystream(k.aesKey, k.aesIv, data.length),
      twofishKeystream(k.twofishKey, k.twofishIv, data.length),
      chachaKeystream(k.chachaKey, k.chachaNonce, data.length),
    ]);

void main() {
  group('FileKeys.derive', () {
    final keys = FileKeys.derive(_root, _salt, _hdr12);

    test('alle acht Schlüssel gegen Python-Referenz (§3.4)', () {
      expect(toHex(keys.aesKey),
          '50c99026bd1db3cb6bc2ae0a8edbc9366e7ebd64ac88aab91a2bc34f6c5da57b');
      expect(toHex(keys.aesIv), '6dcd9f84613c9358c4e76e3b0adbb831');
      expect(toHex(keys.twofishKey),
          'efef7758ac3b2589204bbff1e612b8f68505989b23e22f603a7fae50f0a10fdd');
      expect(toHex(keys.twofishIv), '70342bcaf07f395e7d84597f52ecd934');
      expect(toHex(keys.chachaKey),
          '14636ce334029158aa6e1677edbf12f4674d9166225431dad10fa2fb064bd42b');
      expect(toHex(keys.chachaNonce), '29cf4eb19e0df53bc002d80f');
      expect(
          toHex(keys.hmacSha512Key),
          '6736b307232b6a3f309041a0587030e8103921ec3314b92d669cfed670d90b92'
          '0072d5628da089d735e147292856f4362300c7aabc7097ef77158081d4c77e44');
      expect(
          toHex(keys.hmacSha3Key),
          'e55e8249f0f5a7e6bd4d451cb5226fc4421634fb0651f606a2da0cbe0bbd1af7'
          '380654345642a3e2ec65859029a23e71e41bee877106aeea2cdac929c2e35979');
    });

    test('entspricht der handgebauten Referenz (Labels, hdr12 im info)', () {
      final ref = referenceKeys(_root, _salt, _hdr12);
      expect(keys.aesKey, ref['aes-256-ctr/key']);
      expect(keys.aesIv, ref['aes-256-ctr/iv']);
      expect(keys.twofishKey, ref['twofish-256-ctr/key']);
      expect(keys.twofishIv, ref['twofish-256-ctr/iv']);
      expect(keys.chachaKey, ref['chacha20/key']);
      expect(keys.chachaNonce, ref['chacha20/nonce']);
      expect(keys.hmacSha512Key, ref['hmac-sha512/key']);
      expect(keys.hmacSha3Key, ref['hmac-sha3-256/key']);
    });

    test('fileKeyInfo = "ultracipher/file/" || label || 0x00 || hdr12', () {
      expect(
          toHex(fileKeyInfo('chacha20/key', _hdr12)),
          '${toHex(ascii('ultracipher/file/chacha20/key'))}00'
          '554344420001000100010000');
    });

    test('alle acht Schlüssel sind paarweise verschieden', () {
      final all = [
        keys.aesKey,
        keys.aesIv,
        keys.twofishKey,
        keys.twofishIv,
        keys.chachaKey,
        keys.chachaNonce,
        keys.hmacSha512Key,
        keys.hmacSha3Key,
      ].map(toHex).toList();
      expect(all.toSet().length, 8);
      // Auch gleich lange Schlüssel teilen kein Präfix (kein Wiederverwenden).
      expect(toHex(keys.aesKey), isNot(toHex(keys.twofishKey)));
      expect(toHex(keys.twofishKey), isNot(toHex(keys.chachaKey)));
      expect(toHex(keys.aesIv), isNot(toHex(keys.twofishIv)));
    });

    test('R, file_salt und hdr12 ändern jeden Schlüssel', () {
      List<String> hexes(FileKeys k) => [
            k.aesKey,
            k.aesIv,
            k.twofishKey,
            k.twofishIv,
            k.chachaKey,
            k.chachaNonce,
            k.hmacSha512Key,
            k.hmacSha3Key
          ].map(toHex).toList();
      final base = hexes(keys);
      final others = [
        hexes(FileKeys.derive(_flipBit(_root, 0), _salt, _hdr12)),
        hexes(FileKeys.derive(_root, _flipBit(_salt, 255), _hdr12)),
        // andere Suite (Bytes 6..7) -> andere Schlüssel
        hexes(FileKeys.derive(_root, _salt, hex('554344420001000200010000'))),
      ];
      for (final o in others) {
        for (var i = 0; i < 8; i++) {
          expect(o[i], isNot(base[i]));
        }
      }
    });

    test('Längenprüfung der Eingaben', () {
      expect(() => FileKeys.derive(Uint8List(63), _salt, _hdr12),
          throwsArgumentError);
      expect(() => FileKeys.derive(_root, Uint8List(31), _hdr12),
          throwsArgumentError);
      expect(() => FileKeys.derive(_root, _salt, Uint8List(11)),
          throwsArgumentError);
    });
  });

  group('applyCascade', () {
    final keys = FileKeys.derive(_root, _salt, _hdr12);

    test('Nullklartext = XOR dreier unabhängiger Schlüsselströme', () {
      for (final n in [0, 1, 15, 16, 17, 100, 1000]) {
        expect(applyCascade(keys, Uint8List(n)), _expected(keys, Uint8List(n)),
            reason: 'n=$n');
      }
    });

    test('Verschlüsseln und Entschlüsseln sind dieselbe Operation', () {
      final p = counting(333, 9);
      expect(applyCascade(keys, applyCascade(keys, p)), p);
      expect(applyCascade(keys, p), isNot(p));
    });

    test(
        'jede Schicht läuft: ein Schlüssel- oder IV-Bit ändert genau ihren Strom',
        () {
      final zeros = Uint8List(200);
      final base = applyCascade(keys, zeros);
      final variants = <String, FileKeys>{
        'aes key': _copy(keys, aesKey: _flipBit(keys.aesKey, 5)),
        'aes iv': _copy(keys, aesIv: _flipBit(keys.aesIv, 77)),
        'twofish key': _copy(keys, twofishKey: _flipBit(keys.twofishKey, 130)),
        'twofish iv': _copy(keys, twofishIv: _flipBit(keys.twofishIv, 3)),
        'chacha key': _copy(keys, chachaKey: _flipBit(keys.chachaKey, 200)),
        'chacha nonce':
            _copy(keys, chachaNonce: _flipBit(keys.chachaNonce, 40)),
      };
      variants.forEach((name, k) {
        final out = applyCascade(k, zeros);
        expect(out, isNot(base), reason: '$name wirkt nicht');
        // Nur der veränderte Strom darf sich ändern: die Abweichung ist genau
        // der XOR-Unterschied der beiden Ströme dieser einen Schicht.
        expect(out, _expected(k, zeros), reason: name);
        final delta = xorAll([out, base]);
        final Uint8List layerDelta;
        if (name.startsWith('aes')) {
          layerDelta = xorAll([
            aesKeystream(k.aesKey, k.aesIv, 200),
            aesKeystream(keys.aesKey, keys.aesIv, 200)
          ]);
        } else if (name.startsWith('twofish')) {
          layerDelta = xorAll([
            twofishKeystream(k.twofishKey, k.twofishIv, 200),
            twofishKeystream(keys.twofishKey, keys.twofishIv, 200)
          ]);
        } else {
          layerDelta = xorAll([
            chachaKeystream(k.chachaKey, k.chachaNonce, 200),
            chachaKeystream(keys.chachaKey, keys.chachaNonce, 200)
          ]);
        }
        expect(delta, layerDelta, reason: '$name: fremde Schicht betroffen');
      });
    });

    test('Zähler läuft über Blockgrenzen und über 4 KiB hinweg', () {
      final p = counting(5000, 1);
      expect(applyCascade(keys, p), _expected(keys, p));
    });
  });
}
