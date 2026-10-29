// Golden-Vector-Test fuer das Namensmodell: `databaseName(R)`
// (user_key_hash.dart), der lokale Prefs-Key `ucdb_<name>`
// (`UltracipherApp.localPrefsKey`) und der GitHub-Pfad `<name>.txt`
// (`GithubBackend.pathForName`).
//
// Die Pins wurden am 2026-10-28 mit Ja des Users (Schritt 4 des Plans
// crypto-v1-format) ersetzt: der Name haengt jetzt an `R` (64 Byte, Dual-HKDF-
// Zweig "ultracipher/name"), nicht mehr an einem Keccak-Hash des alten
// 32-Byte-Schluessels. Die neuen Werte wurden unabhaengig in Python
// nachgerechnet (hashlib/hmac, scratchpad v1ref/names.py), nicht aus
// databaseName abgeleitet.
//
// Diese Werte werden NIEMALS neu erzeugt. Schlaegt der Test fehl, ist das der
// Befund -- nicht etwas, das durch Neuerzeugen der erwarteten Werte
// "repariert" wird. Ein Byte Abweichung gibt jeder Datenbank einen neuen Namen
// und verwaist alle bestehenden Kopien und Dateien.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:ultracipher_flutter/src/backend/github_backend.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'golden_v1_vectors.dart';

Uint8List _hex(String s) => Uint8List.fromList(List.generate(
    s.length ~/ 2, (i) => int.parse(s.substring(2 * i, 2 * i + 2), radix: 16)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('databaseName naming scheme', () {
    // Feste R-Werte (64 Byte), dazu 0x00-/0xFF-Randwerte und die beiden R der
    // eingefrorenen golden_v1-Passphrasen.
    final roots = <String, Uint8List>{
      'ascending64': Uint8List.fromList(List.generate(64, (i) => i)),
      'descending64': Uint8List.fromList(List.generate(64, (i) => 255 - i)),
      'stride64': Uint8List.fromList(List.generate(64, (i) => i * 7 % 256)),
      'zeros64': Uint8List(64),
      'ff64': Uint8List.fromList(List.filled(64, 0xFF)),
      'golden_ascii': _hex(rootAsciiHex),
      'golden_unicode': _hex(rootUnicodeHex),
    };

    final expectedDatabaseName = <String, String>{
      'ascending64': 'HT3-aexXLZhLm0hlzs-uDzp0boqd9I5eXjmRukBffzA',
      'descending64': 'TBpHWJpQdIR2lyUvZmbNEvuFumMb00rZC6-d8DtR04Y',
      'stride64': '-yIe4KaPKTM_EJ5CISkKTzrpA8dd8uVJXiuRjTVV3MA',
      'zeros64': 'iBxQ0cCC8Yro9qNudACwPv5-SYcOf5dvesUul4W5XL8',
      'ff64': 'yYEe79XKoMnJ1V3-6Uhajr-mKTgF29ZRkat9sEaYokI',
      'golden_ascii': 'P5fgCE1zprRXlS6l4vPpgSlsocg_jN76gBHFvBi9Fj0',
      'golden_unicode': 'H0xdMwF6VW8rNUcyfdO_spXaDTHGMFgSw6ceZQ3tCKY',
    };

    test(
        'databaseName, localPrefsKey and the GitHub path reproduce their '
        'pinned outputs\n'
        'If this fails: the name construction drifted, orphaning every local '
        'copy and GitHub file.', () {
      for (final id in roots.keys) {
        final name = databaseName(roots[id]!);
        expect(name, equals(expectedDatabaseName[id]),
            reason: 'databaseName drifted for R=$id');
        expect(UltracipherApp.localPrefsKey(name), equals('ucdb_$name'),
            reason: 'localPrefsKey drifted for R=$id');
        expect(GithubBackend.pathForName(name), equals('$name.txt'),
            reason: 'GitHub path drifted for R=$id');
      }
      // Die Pins selbst muessen vollstaendig und eindeutig sein.
      expect(expectedDatabaseName.keys.toSet(), roots.keys.toSet());
      expect(expectedDatabaseName.values.toSet(), hasLength(roots.length));
    });

    test(
        'databaseName matches an independent HKDF over the name branch '
        '(HMAC with explicit block sizes, no module helpers)\n'
        'If this fails: salt, info or the XOR combination drifted.', () {
      Uint8List hmac(Digest d, int blockLen, List<int> key, List<int> data) {
        final mac = HMac(d, blockLen)..init(KeyParameter(Uint8List.fromList(key)));
        final out = Uint8List(mac.macSize);
        mac.update(Uint8List.fromList(data), 0, data.length);
        mac.doFinal(out, 0);
        return out;
      }

      final salt = utf8.encode('ultracipher/name');
      final info = utf8.encode('ultracipher/name/1');
      final r = roots['ascending64']!;
      // Extract je Hash (SHA3-512: Blocklaenge = Rate 72).
      final prk1 = hmac(SHA512Digest(), 128, salt, r);
      final prk2 = hmac(SHA3Digest(512), 72, salt, r);
      // Expand: 32 Byte < 64 Byte Hash, also genau ein Block, Zaehler 1.
      final t1 = hmac(SHA512Digest(), 128, prk1, [...info, 1]);
      final t2 = hmac(SHA3Digest(512), 72, prk2, [...info, 1]);
      final bytes = Uint8List.fromList(
          List.generate(32, (i) => t1[i] ^ t2[i]));
      final name = base64Url.encode(bytes).replaceAll('=', '');
      expect(name, equals(expectedDatabaseName['ascending64']));
    });
  });
}
