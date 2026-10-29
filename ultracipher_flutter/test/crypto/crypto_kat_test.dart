// Primitive-KATs (Spezifikation §9): prüfen pointycastle selbst, in der VM
// und unter WASM. Vektoren stehen inline als Hex (kein dart:io, damit sie im
// Browser laufen). Quellen je Gruppe; Werte zusätzlich mit openssl/python
// (hashlib) gegengerechnet, nie aus der Bibliotheksausgabe übernommen.
//
// VM:    flutter test test/crypto/
// WASM:  flutter test --platform chrome --wasm --dart-define=EXPECT_WASM=true \
//          test/crypto/
//        (Chrome liegt unter /Applications; Flutter findet es von selbst,
//        sonst CHROME_EXECUTABLE setzen. Lange VM-Tests sind mit
//        `testOn: 'vm'` markiert und fehlen im Browser-Lauf bewusst.)
// Der Sentinel-Test unten schlägt fehl, wenn EXPECT_WASM=true gesetzt ist,
// der Code aber nicht von dart2wasm kompiliert wurde (z. B. stiller
// dart2js-Fallback).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'hex.dart';

const _longTimeout = Timeout(Duration(minutes: 3));

Uint8List _hmac(HMac mac, Uint8List key, Uint8List data) {
  mac.init(KeyParameter(key));
  mac.update(data, 0, data.length);
  final out = Uint8List(mac.macSize);
  mac.doFinal(out, 0);
  return out;
}

Uint8List _stream(StreamCipher c, Uint8List data) {
  final out = Uint8List(data.length);
  c.processBytes(data, 0, data.length, out, 0);
  return out;
}

void main() {
  test('Sentinel: Laufzeit ist dart2wasm, wenn EXPECT_WASM=true', () {
    const expectWasm = bool.fromEnvironment('EXPECT_WASM');
    const isWasm = bool.fromEnvironment('dart.tool.dart2wasm');
    if (expectWasm) {
      expect(isWasm, isTrue,
          reason: 'EXPECT_WASM=true, aber nicht mit dart2wasm kompiliert');
    }
  });

  group('AES-256-CTR (NIST SP 800-38A F.5.5)', () {
    final key = hex(
        '603deb1015ca71be2b73aef0857d7781 1f352c073b6108d72d9810a30914dff4');
    final iv = hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
    final plain = hex('''
      6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51
      30c81c46a35ce411e5fbc1191a0a52ef f69f2445df4f9b17ad2b417be66c3710''');
    final cipher = hex('''
      601ec313775789a5b7a7f504bbf3d228 f443e3ca4d62b59aca84e990cacaf5c5
      2b0930daa23de94ce87017ba2d84988d dfc9c58db67aada613c2dd08457941a6''');

    test('Verschlüsseln und Entschlüsseln (4 Blöcke)', () {
      for (final dir in [true, false]) {
        final c = CTRStreamCipher(AESEngine())
          ..init(dir, ParametersWithIV(KeyParameter(key), iv));
        expect(_stream(c, dir ? plain : cipher), dir ? cipher : plain);
      }
    });
  });

  group('Twofish (Schneier twofish-kat.zip: ECB_IVAL und ECB_TBL)', () {
    Uint8List ecb(Uint8List key, Uint8List block) {
      final e = TwofishEngine()..init(true, KeyParameter(key));
      final out = Uint8List(16);
      e.processBlock(block, 0, out, 0);
      return out;
    }

    // Herkunft: Schneiers offizielles twofish-kat.zip. Nullschlüssel 128/256:
    // ECB_IVAL I=1. Nullschlüssel 192: ECB_TBL, KEYSIZE=192, I=1,
    // CT=EFA71F78...9101 (gegen die Originaldatei bestätigt).
    // Nicht-Null-Schlüssel 0123456789ABCDEFFEDCBA9876543210 0011...EEFF
    // (192/256 Bit, Klartext Null): ECB_IVAL.TXT, CT=CFD1D2E5...2248 bzw.
    // CT=37527BE0...FA20 (gegen die Originaldatei bestätigt).
    test('Nicht-Null-Schlüssel, Nullblock: 192/256 Bit (ECB_IVAL)', () {
      const k = '0123456789abcdeffedcba98765432100011223344556677'
          '8899aabbccddeeff';
      expect(toHex(ecb(hex(k.substring(0, 48)), Uint8List(16))),
          'cfd1d2e5a9be9cdf501f13b892bd2248');
      expect(toHex(ecb(hex(k), Uint8List(16))),
          '37527be0052334b89f0cfccae87cfa20');
    });

    test('Nullschlüssel, Nullblock: 128/192/256 Bit', () {
      expect(toHex(ecb(Uint8List(16), Uint8List(16))),
          '9f589f5cf6122c32b6bfec2f2ae8c35a');
      expect(toHex(ecb(Uint8List(24), Uint8List(16))),
          'efa71f788965bd4453f860178fc19101');
      expect(toHex(ecb(Uint8List(32), Uint8List(16))),
          '57ff739d4dc92c1bd7fc01700cc8216f');
    });

    test('ecb_ival I=2 (128 Bit)', () {
      expect(toHex(ecb(Uint8List(16), hex('9f589f5cf6122c32b6bfec2f2ae8c35a'))),
          'd491db16e7b1c39e86cb086b789f5419');
    });

    test('CTR-Lauf stimmt mit ECB-Zähler-Handrechnung überein', () {
      // Unabhängig von der SIC-Klasse: Zählerblöcke von Hand (128 Bit,
      // Big-Endian, Übertrag über Byte 15 -> 14) durch ECB schicken.
      final key = counting(32, 0x40);
      final iv =
          hex('000102030405060708090a0b0c0d0eff'); // Übertrag nach 1 Block
      final data = counting(50, 7);
      final expected = Uint8List(50);
      final counter = Uint8List.fromList(iv);
      for (var off = 0; off < 50; off += 16) {
        final ks = ecb(key, counter);
        for (var i = 0; i < 16 && off + i < 50; i++) {
          expected[off + i] = data[off + i] ^ ks[i];
        }
        for (var j = 15; j >= 0; j--) {
          counter[j] = (counter[j] + 1) & 255;
          if (counter[j] != 0) break;
        }
      }
      final c = CTRStreamCipher(TwofishEngine())
        ..init(true, ParametersWithIV(KeyParameter(key), iv));
      expect(_stream(c, data), expected);
    });
  });

  group('ChaCha20 (RFC 8439)', () {
    test('Anhang A.1 #1: Nullschlüssel, Zähler 0, Schlüsselstrom', () {
      final c = ChaCha7539Engine()
        ..init(
            true, ParametersWithIV(KeyParameter(Uint8List(32)), Uint8List(12)));
      expect(
          toHex(_stream(c, Uint8List(64))),
          '76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7'
          'da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586');
    });

    test('§2.4.2: Sonnencreme-Text mit Zähler 1', () {
      // pointycastle zählt ab 0; Zähler 1 = erste 64 Bytes überspringen.
      final plain = ascii('Ladies and Gentlemen of the class of \'99: If I '
          'could offer you only one tip for the future, sunscreen would be '
          'it.');
      final c = ChaCha7539Engine()
        ..init(
            true,
            ParametersWithIV(
                KeyParameter(counting(32)), hex('000000000000004a00000000')));
      _stream(c, Uint8List(64));
      expect(
          toHex(_stream(c, plain)),
          '6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b'
          'f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8'
          '07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365'
          'af90bbf74a35be6b40b8eedf2785e42874d');
    });
  });

  group('HMAC-SHA-512 (RFC 4231)', () {
    HMac mac() => HMac(SHA512Digest(), 128);
    test('Testfall 1', () {
      expect(
          toHex(_hmac(mac(), Uint8List.fromList(List.filled(20, 0x0b)),
              ascii('Hi There'))),
          '87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde'
          'daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854');
    });
    test('Testfall 2', () {
      expect(
          toHex(_hmac(
              mac(), ascii('Jefe'), ascii('what do ya want for nothing?'))),
          '164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554'
          '9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737');
    });
    test('Testfall 6 (Schlüssel länger als Block)', () {
      expect(
          toHex(_hmac(mac(), Uint8List.fromList(List.filled(131, 0xaa)),
              ascii('Test Using Larger Than Block-Size Key - Hash Key First'))),
          '80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f352'
          '6b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598');
    });
    test('Testfall 7 (langer Schlüssel, lange Daten)', () {
      expect(
          toHex(_hmac(
              mac(),
              Uint8List.fromList(List.filled(131, 0xaa)),
              ascii('This is a test using a larger than block-size key and a '
                  'larger than block-size data. The key needs to be hashed '
                  'before being used by the HMAC algorithm.'))),
          'e37b6a775dc87dbaa4dfa9f96e5e3ffddebd71f8867289865df5a32d20cdc944'
          'b6022cac3c4982b10d5eeb55c3e4de15134676fb6de0446065c97440fa8c6a58');
    });
  });

  group('HMAC-SHA3-256 (NIST-Beispiele, Block 136)', () {
    HMac mac() => HMac(SHA3Digest(256), 136);
    test('Schlüssel kürzer als Block (32 B)', () {
      expect(
          toHex(_hmac(mac(), counting(32),
              ascii('Sample message for keylen<blocklen'))),
          '4fe8e202c4f058e8dddc23d8c34e467343e23555e24fc2f025d598f558f67205');
    });
    test('Schlüssel gleich Block (136 B)', () {
      expect(
          toHex(_hmac(mac(), counting(136),
              ascii('Sample message for keylen=blocklen'))),
          '68b94e2e538a9be4103bebb5aa016d47961d4d1aa906061313b557f8af2c3faa');
    });
    test('Schlüssel länger als Block (168 B)', () {
      expect(
          toHex(_hmac(mac(), counting(168),
              ascii('Sample message for keylen>blocklen'))),
          '9bcf2c238e235c3ce88404e813bd2f3a97185ac6f238c63d6229a00b07974258');
    });
  });

  group('HMAC-SHA3-512 (NIST-Beispiele, Block 72)', () {
    HMac mac() => HMac(SHA3Digest(512), 72);
    test('Schlüssel kürzer als Block (64 B)', () {
      expect(
          toHex(_hmac(mac(), counting(64),
              ascii('Sample message for keylen<blocklen'))),
          '4efd629d6c71bf86162658f29943b1c308ce27cdfa6db0d9c3ce81763f9cbce5'
          'f7ebe9868031db1a8f8eb7b6b95e5c5e3f657a8996c86a2f6527e307f0213196');
    });
    test('Schlüssel gleich Block (72 B)', () {
      expect(
          toHex(_hmac(mac(), counting(72),
              ascii('Sample message for keylen=blocklen'))),
          '544e257ea2a3e5ea19a590e6a24b724ce6327757723fe2751b75bf007d80f6b3'
          '60744bf1b7a88ea585f9765b47911976d3191cf83c039f5ffab0d29cc9d9b6da');
    });
    test('Schlüssel länger als Block (136 B)', () {
      expect(
          toHex(_hmac(mac(), counting(136),
              ascii('Sample message for keylen>blocklen'))),
          '5f464f5e5b7848e3885e49b2c385f0694985d0e38966242dc4a5fe3fea4b37d4'
          '6b65ceced5dcf59438dd840bab22269f0ba7febdb9fcf74602a35666b2a32915');
    });
  });

  group('Argon2id (RFC 9106 §5.3)', () {
    test('Vektor mit secret und ad (m=32 KiB, t=3, p=4)', () {
      // Prüft in der VM die Native-Int- und unter WASM die Register64-Variante.
      final gen = Argon2BytesGenerator()
        ..init(Argon2Parameters(
          Argon2Parameters.ARGON2_id,
          Uint8List.fromList(List.filled(16, 2)),
          desiredKeyLength: 32,
          iterations: 3,
          memory: 32,
          lanes: 4,
          secret: Uint8List.fromList(List.filled(8, 3)),
          additional: Uint8List.fromList(List.filled(12, 4)),
          version: Argon2Parameters.ARGON2_VERSION_13,
        ));
      expect(toHex(gen.process(Uint8List.fromList(List.filled(32, 1)))),
          '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659');
    }, timeout: _longTimeout);
  });

  group('scrypt (RFC 7914 §12)', () {
    Uint8List scrypt(String pw, String salt, int n, int r, int p) =>
        (Scrypt()..init(ScryptParameters(n, r, p, 64, ascii(salt))))
            .process(ascii(pw));

    test('leere Eingaben, N=16', () {
      expect(
          toHex(scrypt('', '', 16, 1, 1)),
          '77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442'
          'fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906');
    });
    test('password/NaCl, N=1024, r=8, p=16', () {
      expect(
          toHex(scrypt('password', 'NaCl', 1024, 8, 16)),
          'fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162'
          '2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640');
    }, timeout: _longTimeout);
    test('pleaseletmein/SodiumChloride, N=16384', () {
      expect(
          toHex(scrypt('pleaseletmein', 'SodiumChloride', 16384, 8, 1)),
          '7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2'
          'd5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887');
    }, timeout: _longTimeout);
  });
}
