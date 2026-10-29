// Format v1 (§6): seal/open, Header-Allow-List, Grenzen, Manipulationen.
// Läuft auch unter WASM (Befehl siehe crypto_kat_test.dart).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:ultracipher_flutter/src/crypto/cascade.dart';
import 'package:ultracipher_flutter/src/crypto/format_v1.dart';

import 'hex.dart';
import 'reference.dart';

final _root =
    Uint8List.fromList([for (var i = 0; i < 64; i++) (i * 7 + 3) & 255]);
final _salt = Uint8List.fromList([for (var i = 0; i < 32; i++) 255 - i]);

Uint8List _seal(Uint8List plain) => FormatV1.seal(plain, _root, _salt);
Uint8List _open(Uint8List file, [Uint8List? root]) =>
    FormatV1.open(file, root ?? _root);

Uint8List _flip(Uint8List b, int bit) =>
    (Uint8List.fromList(b))..[bit ~/ 8] ^= 1 << (bit % 8);

void _setU16(Uint8List b, int offset, int v) =>
    ByteData.sublistView(b).setUint16(offset, v);

Matcher _formatError(FormatErrorKind kind) => throwsA(
    isA<UltracipherFormatException>().having((e) => e.kind, 'kind', kind));

final _authError = throwsA(isA<UltracipherAuthenticationException>());

void main() {
  group('Aufbau', () {
    test('seal gleich unabhängig von Hand gebauter Referenz', () {
      for (final n in [0, 1, 15, 16, 17, 31, 32, 100, 1000]) {
        final plain = counting(n, 11);
        expect(toHex(_seal(plain)), toHex(referenceSeal(plain, _root, _salt)),
            reason: 'n=$n');
      }
    });

    test('Header-Bytes und Gesamtlänge', () {
      final f = _seal(counting(20));
      expect(toHex(f.sublist(0, 12)), '554344420001000100010000');
      expect(f.sublist(12, 44), _salt);
      expect(f.length, 44 + 32 + 64 + 32); // 20 B -> 32 B Padding
      expect(minFileLength, 156);
      expect(_seal(Uint8List(0)).length, minFileLength);
    });

    test('deterministisch bei festem Salt, anders bei anderem Salt', () {
      final plain = counting(50);
      expect(_seal(plain), _seal(plain));
      final other = FormatV1.seal(plain, _root, _flip(_salt, 0));
      expect(
          other.sublist(44, 44 + 64), isNot(_seal(plain).sublist(44, 44 + 64)));
    });

    test('seal prüft Salt-Länge und Größe', () {
      expect(() => FormatV1.seal(Uint8List(1), _root, Uint8List(31)),
          throwsArgumentError);
      expect(() => FormatV1.seal(Uint8List(1), Uint8List(63), _salt),
          throwsArgumentError);
      // Ein Schreiber erzeugt keine Datei, die sein Leser ablehnt.
      expect(() => FormatV1.seal(Uint8List(maxFileLength), _root, _salt),
          throwsArgumentError);
      // Knapp über der Grenze erst durch das Padding: 44 + 67108720 + 96
      // passt noch, mit Padding (67108736) nicht. Prüft die gepaddete Länge.
      expect(() => FormatV1.seal(Uint8List(67108720), _root, _salt),
          throwsArgumentError);
    });

    test('newFileSalt: 32 Byte und nicht konstant', () {
      final a = newFileSalt();
      final b = newFileSalt();
      expect(a.length, 32);
      expect(a, isNot(b));
    });
  });

  group('Round trip und Padding', () {
    test('Längen 0..100 und 4000', () {
      for (final n in [...List.generate(101, (i) => i), 4000]) {
        final plain = counting(n, 3);
        expect(_open(_seal(plain)), plain, reason: 'n=$n');
      }
    });

    test('Randfälle 0, 15, 16, 17 Byte', () {
      for (final c in {0: 16, 15: 16, 16: 32, 17: 32}.entries) {
        final f = _seal(counting(c.key));
        expect(f.length - 140, c.value, reason: 'Länge von C bei ${c.key}');
        expect(_open(f), counting(c.key));
      }
    });

    test('padIso7816: 0x80, dann Nullen, mindestens ein Byte', () {
      expect(toHex(padIso7816(Uint8List(0))), '80${'00' * 15}');
      expect(toHex(padIso7816(counting(15))), '${toHex(counting(15))}80');
      expect(padIso7816(counting(16)).length, 32);
      expect(padIso7816(counting(16))[16], 0x80);
      expect(toHex(padIso7816(counting(17)).sublist(17)), '80${'00' * 14}');
    });

    test('unpadIso7816 verwirft ungültiges Padding', () {
      expect(unpadIso7816(Uint8List(16)), isNull); // nur Nullen
      expect(unpadIso7816(Uint8List(0)), isNull);
      expect(unpadIso7816(hex('0102 0304 0506 0708 090a 0b0c 0d0e 0f10')),
          isNull); // kein 0x80
      expect(unpadIso7816(hex('0102 8001')), isNull); // Byte nach 0x80
      expect(unpadIso7816(hex('0102 8000')), hex('0102'));
      expect(unpadIso7816(hex('80')), Uint8List(0));
      // Nur kanonisch: mehr als 16 Füllbytes (0x80 + 16 Nullen) sind ungültig.
      expect(unpadIso7816(hex('${'01' * 15}80${'00' * 16}')), isNull);
      expect(unpadIso7816(hex('${'01' * 16}80${'00' * 15}')), hex('01' * 16));
      expect(unpadIso7816(hex('${'01' * 16}${'00' * 16}')), isNull);
    });

    test('0x80 und 0x00 im Klartext selbst stören nicht', () {
      for (final tail in [
        [0x80],
        [0x00],
        [0x80, 0x00, 0x00],
        [0x00, 0x80]
      ]) {
        final plain = Uint8List.fromList([1, 2, 3, ...tail]);
        expect(_open(_seal(plain)), plain);
      }
    });
  });

  group('Manipulation: jede Bitänderung scheitert', () {
    final file = _seal(counting(20, 5)); // 172 Byte

    test('jedes Bit des Headers: sauberer Header-Fehler oder Authentifizierung',
        () {
      for (var bit = 0; bit < 44 * 8; bit++) {
        final f = _flip(file, bit);
        final byte = bit ~/ 8;
        final Matcher expected;
        if (byte < 4) {
          expected = _formatError(FormatErrorKind.badMagic);
        } else if (byte < 6) {
          expected = _formatError(FormatErrorKind.unsupportedVersion);
        } else if (byte < 8) {
          expected = _formatError(FormatErrorKind.unsupportedSuite);
        } else if (byte < 10) {
          expected = _formatError(FormatErrorKind.unsupportedKdfProfile);
        } else if (byte < 12) {
          expected = _formatError(FormatErrorKind.unsupportedFlags);
        } else {
          expected = _authError; // file_salt: andere Schlüssel
        }
        expect(() => _open(f), expected, reason: 'Bit $bit');
      }
    });

    test('jedes Bit von C, T1 und T2: generischer Authentifizierungsfehler',
        () {
      for (var bit = 44 * 8; bit < file.length * 8; bit++) {
        expect(() => _open(_flip(file, bit)), _authError, reason: 'Bit $bit');
      }
    });

    test('alle Authentifizierungsfehler sind nicht zu unterscheiden', () {
      final messages = <String>{};
      final types = <Type>{};
      final variants = [
        _flip(file, 50 * 8), // C
        _flip(file, (file.length - 96) * 8), // T1
        _flip(file, (file.length - 1) * 8), // T2
        _flip(file, 12 * 8), // file_salt
        file.sublist(0, file.length - 16), // Länge
        file.sublist(0, 100), // gekürzt
      ];
      for (final v in variants) {
        try {
          _open(v);
          fail('muss scheitern');
        } catch (e) {
          messages.add(e.toString());
          types.add(e.runtimeType);
        }
      }
      try {
        _open(file, _flip(_root, 0));
        fail('falsches R muss scheitern');
      } catch (e) {
        messages.add(e.toString());
        types.add(e.runtimeType);
      }
      expect(types, {UltracipherAuthenticationException});
      expect(messages.length, 1);
      // Weder Schlüssel noch Dateiinhalt in der Meldung.
      expect(messages.single, isNot(contains(toHex(_root.sublist(0, 4)))));
    });

    test('Tags nur über C (ohne Header) gerechnet werden abgelehnt', () {
      final keys = FileKeys.derive(_root, _salt, file.sublist(0, 12));
      final c = file.sublist(44, file.length - 96);
      final t1 = hmacRef(SHA512Digest(), 128, keys.hmacSha512Key, c);
      final t2 = hmacRef(SHA3Digest(256), 136, keys.hmacSha3Key, c);
      final forged = Uint8List.fromList(
          [...file.sublist(0, file.length - 96), ...t1, ...t2]);
      expect(() => _open(forged), _authError);
    });

    test('vertauschte Tags oder halbe Tags werden abgelehnt', () {
      final swapped = Uint8List.fromList(file);
      // T2 in die ersten 32 Bytes von T1 kopieren.
      swapped.setRange(
          file.length - 96, file.length - 64, file.sublist(file.length - 32));
      expect(() => _open(swapped), _authError);
      // nur ein Tag korrekt: T1 gültig, T2 aus Nullen.
      final onlyT1 = Uint8List.fromList(file)
        ..fillRange(file.length - 32, file.length, 0);
      expect(() => _open(onlyT1), _authError);
      final onlyT2 = Uint8List.fromList(file)
        ..fillRange(file.length - 96, file.length - 32, 0);
      expect(() => _open(onlyT2), _authError);
    });

    test('Kürzen: jede Länge 0..n-1', () {
      for (var len = 0; len < file.length; len++) {
        expect(() => _open(file.sublist(0, len)), _authError,
            reason: 'Länge $len');
      }
    });

    test('Verlängern, Block entfernen oder duplizieren', () {
      expect(() => _open(Uint8List.fromList([...file, 0])), _authError);
      expect(() => _open(Uint8List.fromList([...file, ...Uint8List(16)])),
          _authError);
      final noBlock = Uint8List.fromList(
          [...file.sublist(0, 44), ...file.sublist(60)]); // erste C-Block weg
      expect(() => _open(noBlock), _authError);
      final dup = Uint8List.fromList([
        ...file.sublist(0, 60),
        ...file.sublist(44, 60),
        ...file.sublist(60)
      ]);
      expect(() => _open(dup), _authError);
    });

    test('falsches R (jedes einzelne Bit) scheitert', () {
      for (var bit = 0; bit < 512; bit += 31) {
        expect(() => _open(file, _flip(_root, bit)), _authError);
      }
      expect(() => _open(file, Uint8List(64)), _authError);
      expect(() => _open(file, Uint8List(10)), throwsArgumentError);
    });

    test('Datei eines anderen Schreibvorgangs mit fremdem Header', () {
      final other = FormatV1.seal(counting(20, 5), _root, _flip(_salt, 7));
      final mixed =
          Uint8List.fromList([...other.sublist(0, 44), ...file.sublist(44)]);
      expect(() => _open(mixed), _authError);
    });
  });

  group('Grenzen und Allow-Lists', () {
    final file = _seal(counting(20, 5));

    test('Datei über 64 MiB wird vor jeder Krypto abgelehnt', () {
      expect(() => _open(Uint8List(maxFileLength + 1)),
          _formatError(FormatErrorKind.tooLarge));
    });

    test('falsche Magic, auch altes Format mit führender 0x00', () {
      final old = Uint8List.fromList(file)..[0] = 0;
      expect(() => _open(old), _formatError(FormatErrorKind.badMagic));
      final legacy = Uint8List(300); // altes Format beginnt mit 0x00
      expect(() => _open(legacy), _formatError(FormatErrorKind.badMagic));
      expect(() => _open(ascii('XXXX${'a' * 200}')),
          _formatError(FormatErrorKind.badMagic));
    });

    test('Meldung zur Magic nennt den CSV-Weg', () {
      try {
        _open(Uint8List(200));
        fail('muss scheitern');
      } on UltracipherFormatException catch (e) {
        expect(e.message, contains('CSV'));
      }
    });

    test('Version 0, 2 und 0xFFFF', () {
      for (final v in [0, 2, 0xffff]) {
        final f = Uint8List.fromList(file);
        _setU16(f, 4, v);
        expect(
            () => _open(f), _formatError(FormatErrorKind.unsupportedVersion));
      }
    });

    test('unbekannte Suite', () {
      for (final v in [0, 2, 0x8001]) {
        final f = Uint8List.fromList(file);
        _setU16(f, 6, v);
        expect(() => _open(f), _formatError(FormatErrorKind.unsupportedSuite));
      }
    });

    test('Flags ungleich 0', () {
      for (final v in [1, 0x0100, 0x8000, 0xffff]) {
        final f = Uint8List.fromList(file);
        _setU16(f, 10, v);
        expect(() => _open(f), _formatError(FormatErrorKind.unsupportedFlags));
      }
    });

    test('KDF-Profil muss dem von R entsprechen, nie aus der Datei', () {
      final f = Uint8List.fromList(file);
      _setU16(f, 8, 2);
      expect(
          () => _open(f), _formatError(FormatErrorKind.unsupportedKdfProfile));
      // Profil 1 im Header, aber R stammt aus Profil 2 -> Fehler.
      expect(() => FormatV1.open(file, _root, expectedKdfProfile: 2),
          _formatError(FormatErrorKind.unsupportedKdfProfile));
      expect(
          FormatV1.open(file, _root, expectedKdfProfile: 1), counting(20, 5));
    });

    test('neuere Version darf andere Längenstruktur haben (Version zuerst)',
        () {
      final f = Uint8List(40)..setRange(0, 12, file.sublist(0, 12));
      _setU16(f, 4, 2);
      expect(() => _open(f), _formatError(FormatErrorKind.unsupportedVersion));
    });

    test('Länge: kleiner als 156 oder nicht Vielfaches von 16', () {
      expect(() => _open(file.sublist(0, 155)), _authError);
      expect(() => _open(file.sublist(0, 11)), _authError);
      expect(() => _open(Uint8List(0)), _authError);
      expect(() => _open(file.sublist(0, 3)), _authError);
    });

    test('Ausnahme-Meldungen enthalten keine Dateibytes oder Schlüssel', () {
      final f = Uint8List.fromList(file);
      _setU16(f, 4, 0xabcd);
      try {
        _open(f);
        fail('muss scheitern');
      } on UltracipherFormatException catch (e) {
        expect(e.toString().toLowerCase(), isNot(contains('abcd')));
      }
    });
  });
}
