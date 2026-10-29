// Golden-Vector-Tests fuer das Ultracipher-Format v1 (Spezifikation §9 a-c, e).
//
// EINGEFROREN: Die Literale in golden_v1_vectors.dart stammen aus dem
// einmaligen Lauf von tool/generate_fixtures_v1.dart (2026-10-28). Sie wurden
// ausserdem unabhaengig nachgerechnet (Python/OpenSSL, eigene Twofish-
// Implementierung). Ein roter Test hier ist der Befund -- eine Drift in
// pointycastle oder im Modul lib/src/crypto. Das Fixture wird
// NICHT neu erzeugt und die Pins werden NICHT angepasst.
//
// Ebene: Format (seal/open) und Schluesselableitung; die App-Nutzlast (JSON ->
// BZip2) und der Datenbankname gehoeren nicht dazu.
//
// VM:    flutter test test/golden_v1_test.dart
// WASM:  flutter test --platform chrome --wasm --dart-define=EXPECT_WASM=true \
//          test/golden_v1_test.dart
// Die Vektoren stehen als Literale in golden_v1_vectors.dart (der Browser kann
// keine Datei lesen); golden_v1_fixture_file_test.dart (VM) gleicht sie mit
// test/fixtures/golden_v1.json ab.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/crypto/cascade.dart';
import 'package:ultracipher_flutter/src/crypto/format_v1.dart';
import 'package:ultracipher_flutter/src/crypto/kdf_profile.dart';

import 'crypto/hex.dart';
import 'golden_v1_vectors.dart';

// Eine volle P-32-Ableitung dauert unter WASM ca. 11 s.
const _kdfTimeout = Timeout(Duration(minutes: 3));

final Uint8List _plain = Uint8List.fromList(utf8.encode(frozenPlaintext));
final Uint8List _fileSalt = hex(fileSaltHex);
final Uint8List _hdr12 = hex(hdr12Hex);
final Uint8List _rootAscii = hex(rootAsciiHex);
final Uint8List _rootUnicode = hex(rootUnicodeHex);
final Uint8List _frozenFile = base64.decode(fileBase64);

Uint8List _flipBit(Uint8List b, int byteIndex, int bit) =>
    Uint8List.fromList(b)..[byteIndex] ^= 1 << bit;

void _setU16(Uint8List b, int offset, int v) =>
    ByteData.sublistView(b).setUint16(offset, v);

Matcher _formatError(FormatErrorKind kind) => throwsA(
    isA<UltracipherFormatException>().having((e) => e.kind, 'kind', kind));

final _authError = throwsA(isA<UltracipherAuthenticationException>());

void _expectDerivation(String passphrase, String utf8Hex, String kaHex,
    String ksHex, String rHex) {
  final bytes = passphraseBytes(passphrase);
  expect(toHex(bytes), utf8Hex);
  final ka = deriveArgon2idKey(bytes, kdfProfile1);
  final ks = deriveScryptKey(bytes, kdfProfile1);
  expect(toHex(ka), kaHex, reason: 'K_A');
  expect(toHex(ks), ksHex, reason: 'K_S');
  expect(toHex(combineRoot(ka, ks, kdfProfile1)), rHex, reason: 'R');
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

  test('Eingaben: Klartext ist kein Vielfaches von 16, Literale konsistent',
      () {
    expect(_plain.length, 84);
    expect(_plain.length % 16, isNot(0));
    expect(toHex(_plain), plaintextUtf8Hex);
    expect(_fileSalt.length, 32);
    expect(_frozenFile.length, 236);
  });

  group('(a) Entschluesseln der eingefrorenen Datei', () {
    test('open ergibt den von Hand ausgeschriebenen Klartext', () {
      final plain = FormatV1.open(_frozenFile, _rootAscii);
      expect(plain, _plain);
      expect(utf8.decode(plain), frozenPlaintext);
    });

    test('falsches R (zweite Passphrase): neutraler Authentifizierungsfehler',
        () {
      expect(() => FormatV1.open(_frozenFile, _rootUnicode), _authError);
    });

    test('Header der Datei: Magic, Version 1, Suite 1, Profil 1, Flags 0', () {
      expect(toHex(_frozenFile.sublist(0, 12)), hdr12Hex);
      expect(_frozenFile.sublist(12, 44), _fileSalt);
    });
  });

  group('(b) Ableitung Passphrase -> K_A, K_S, R', () {
    test('ASCII-Passphrase', () {
      _expectDerivation(passphraseAscii, passphraseAsciiUtf8Hex, kaAsciiHex,
          ksAsciiHex, rootAsciiHex);
    }, timeout: _kdfTimeout);

    test('Nicht-ASCII-Passphrase (UTF-8, ohne Normalisierung)', () {
      _expectDerivation(passphraseUnicode, passphraseUnicodeUtf8Hex,
          kaUnicodeHex, ksUnicodeHex, rootUnicodeHex);
    }, timeout: _kdfTimeout);

    test('die acht Datei-Teilschluessel zu R und file_salt', () {
      final k = FileKeys.derive(_rootAscii, _fileSalt, _hdr12);
      final actual = {
        'aes-256-ctr/key': k.aesKey,
        'aes-256-ctr/iv': k.aesIv,
        'twofish-256-ctr/key': k.twofishKey,
        'twofish-256-ctr/iv': k.twofishIv,
        'chacha20/key': k.chachaKey,
        'chacha20/nonce': k.chachaNonce,
        'hmac-sha512/key': k.hmacSha512Key,
        'hmac-sha3-256/key': k.hmacSha3Key,
      };
      expect(actual.keys.toSet(), fileSubkeysHex.keys.toSet());
      for (final e in fileSubkeysHex.entries) {
        expect(toHex(actual[e.key]!), e.value, reason: e.key);
      }
    });
  });

  group('(c) Schreiben deterministisch (unterhalb des Kompressors)', () {
    test('seal(Klartext, R, file_salt) ergibt exakt die eingefrorenen Bytes',
        () {
      expect(toHex(FormatV1.seal(_plain, _rootAscii, _fileSalt)),
          toHex(_frozenFile));
    });
  });

  group('(e) Negativfaelle auf der eingefrorenen Datei', () {
    Uint8List open(Uint8List f) => FormatV1.open(f, _rootAscii);

    test('Bitkipper in Magic, Version, Suite, Profil, Flags: Formatfehler', () {
      final expected = <int, FormatErrorKind>{
        for (var i = 0; i < 4; i++) i: FormatErrorKind.badMagic,
        4: FormatErrorKind.unsupportedVersion,
        5: FormatErrorKind.unsupportedVersion,
        6: FormatErrorKind.unsupportedSuite,
        7: FormatErrorKind.unsupportedSuite,
        8: FormatErrorKind.unsupportedKdfProfile,
        9: FormatErrorKind.unsupportedKdfProfile,
        10: FormatErrorKind.unsupportedFlags,
        11: FormatErrorKind.unsupportedFlags,
      };
      for (final e in expected.entries) {
        for (var bit = 0; bit < 8; bit++) {
          expect(() => open(_flipBit(_frozenFile, e.key, bit)),
              _formatError(e.value),
              reason: 'Byte ${e.key}, Bit $bit');
        }
      }
    });

    test('jedes Byte ab file_salt (Salt, C, T1, T2) gekippt: Auth-Fehler', () {
      for (var i = 12; i < _frozenFile.length; i++) {
        expect(() => open(_flipBit(_frozenFile, i, i % 8)), _authError,
            reason: 'Byte $i');
      }
    });

    test('gekippte Bits an den Raendern von C, T1 und T2', () {
      const c = 44;
      final t1 = _frozenFile.length - 96;
      final t2 = _frozenFile.length - 32;
      for (final i in [c, t1 - 1, t1, t2 - 1, t2, _frozenFile.length - 1]) {
        for (var bit = 0; bit < 8; bit++) {
          expect(() => open(_flipBit(_frozenFile, i, bit)), _authError,
              reason: 'Byte $i, Bit $bit');
        }
      }
    });

    test('falsche Magic (andere Bytes, Altformat-Anfang 0x00)', () {
      final other = Uint8List.fromList(_frozenFile)
        ..setRange(0, 4, ascii('XCDB'));
      expect(() => open(other), _formatError(FormatErrorKind.badMagic));
      final legacy = Uint8List.fromList(_frozenFile)..[0] = 0;
      expect(() => open(legacy), _formatError(FormatErrorKind.badMagic));
    });

    test('Version 2 (und 0, 256)', () {
      for (final v in [0, 2, 256]) {
        final f = Uint8List.fromList(_frozenFile);
        _setU16(f, 4, v);
        expect(() => open(f), _formatError(FormatErrorKind.unsupportedVersion),
            reason: 'Version $v');
      }
    });

    test('Flags ungleich 0', () {
      for (final v in [1, 0x8000, 0xFFFF]) {
        final f = Uint8List.fromList(_frozenFile);
        _setU16(f, 10, v);
        expect(() => open(f), _formatError(FormatErrorKind.unsupportedFlags),
            reason: 'Flags $v');
      }
    });

    test('Laenge nicht durch 16 teilbar (C um 1..15 Byte verschoben)', () {
      for (var d = 1; d < 16; d++) {
        final longer = Uint8List(_frozenFile.length + d)
          ..setRange(0, _frozenFile.length, _frozenFile);
        expect(() => open(longer), _authError, reason: '+$d');
        final shorter =
            Uint8List.fromList(_frozenFile.sublist(0, _frozenFile.length - d));
        expect(() => open(shorter), _authError, reason: '-$d');
      }
    });

    test('um einen Block gekuerzt oder verlaengert (Laenge ok, MAC falsch)',
        () {
      final cut = Uint8List.fromList([
        ..._frozenFile.sublist(0, 44),
        ..._frozenFile.sublist(44 + 16),
      ]);
      expect(() => open(cut), _authError);
      final grown = Uint8List.fromList([
        ..._frozenFile.sublist(0, 44),
        ...Uint8List(16),
        ..._frozenFile.sublist(44),
      ]);
      expect(() => open(grown), _authError);
    });

    test('zu kurz', () {
      expect(_frozenFile.length, greaterThan(minFileLength));
      for (final n in [0, 1, 3, 4, 11, 12, 43, 44, 60, 155]) {
        expect(() => open(Uint8List.fromList(_frozenFile.sublist(0, n))),
            _authError,
            reason: 'Laenge $n');
      }
    });
  });
}
