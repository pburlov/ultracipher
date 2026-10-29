// Verhaltenstests fuer die Verschluesselung: die Gruppen "v1" testen den
// Datenbank-Codec der App (JSON -> BZip2 ohne BZh9 -> Format v1) und die
// echte Ableitung von `R`. Die festen Erwartungswerte stehen in
// golden_v1_test.dart.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/crypto/format_v1.dart';
import 'package:ultracipher_flutter/src/db_codec.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'golden_v1_vectors.dart';
import 'crypto/hex.dart';

final Random _rnd = Random.secure();

Uint8List _randomBytes(int n) =>
    Uint8List.fromList(List.generate(n, (_) => _rnd.nextInt(256)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UltracipherApp app;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    app = UltracipherApp();
    await app.init();
  });

  group('UltracipherApp.deriveRoot (real derivation, no test seam)', () {
    test('is R of the frozen golden_v1 passphrase and names the database',
        () async {
      var root = await app.deriveRoot(passphraseAscii);

      expect(toHex(root), rootAsciiHex);
      expect(databaseName(root), 'P5fgCE1zprRXlS6l4vPpgSlsocg_jN76gBHFvBi9Fj0');
    }, timeout: Timeout(Duration(minutes: 2)));

    test('Unicode passphrase gives the frozen R; surrounding whitespace is '
        'trimmed', () async {
      var root = await app.deriveRoot('  $passphraseUnicode\n');

      expect(toHex(root), rootUnicodeHex);
    }, timeout: Timeout(Duration(minutes: 2)));
  });

  group('v1: encryptDatabase / decryptDatabase', () {
    UltracipherDatabase sample() {
      var db = UltracipherDatabase();
      db.addEntry()
          .addNewVersion(Entry(label: 'l1', tags: 't1', content: 'c1'));
      var multi = db.addEntry();
      multi.addNewVersion(Entry(label: 'l2a', tags: 't2', content: 'c2a'));
      multi.addNewVersion(Entry(label: 'l2b', tags: 't2', content: 'c2b'));
      var deleted = db.addEntry();
      deleted.addNewVersion(Entry(label: 'l3', tags: 't3', content: 'c3'));
      db.deleteEntry(deleted);
      return db;
    }

    Uint8List root() => _randomBytes(64);

    test('round trip preserves entries, versions and the deletion list', () {
      var db = sample();
      var r = root();

      var file = UltracipherApp.encryptDatabase(db, r);
      var decoded = UltracipherApp.decryptDatabase(file, r);

      expect(decoded.toJson(), equals(db.toJson()));
    });

    test('the file is Format v1: UCDB magic, version 1, suite 1, profile 1',
        () {
      var file = UltracipherApp.encryptDatabase(sample(), root());

      expect(toHex(file.sublist(0, 12)), hdr12Hex);
    });

    test('a fresh file_salt per call; the same salt gives the same bytes '
        '(the BZip2 stage is deterministic, no TAR clock)', () {
      var db = sample();
      var r = root();

      var f1 = UltracipherApp.encryptDatabase(db, r);
      var f2 = UltracipherApp.encryptDatabase(db, r);
      expect(f1.sublist(12, 44), isNot(equals(f2.sublist(12, 44))));
      expect(f1, isNot(equals(f2)));

      var salt = _randomBytes(32);
      expect(UltracipherApp.encryptDatabase(db, r, fileSalt: salt),
          equals(UltracipherApp.encryptDatabase(db, r, fileSalt: salt)));
    });

    test('the plaintext under the cipher is BZip2 WITHOUT the constant BZh9 '
        'header, and BZip2 of the JSON (no TAR)', () {
      var db = sample();
      var r = root();

      var file = UltracipherApp.encryptDatabase(db, r);
      var compressed = FormatV1.open(file, r);

      // Block magic (pi) directly, not "BZh9".
      expect(compressed.sublist(0, 6), [0x31, 0x41, 0x59, 0x26, 0x53, 0x59]);
      var json = BZip2Decoder()
          .decodeBytes([...bzip2StreamHeader, ...compressed], verify: true);
      expect(utf8.decode(json), jsonEncode(db.toJson()));
    });

    test('wrong R: authentication error; a file of another format: format '
        'error badMagic', () {
      var db = sample();
      var file = UltracipherApp.encryptDatabase(db, root());
      expect(() => UltracipherApp.decryptDatabase(file, root()),
          throwsA(isA<UltracipherAuthenticationException>()));

      // Ein altes Format (v2) begann mit zufaelligen Bytes, nicht mit "UCDB".
      var other = _randomBytes(200)..[0] = 0;
      expect(
          () => UltracipherApp.decryptDatabase(other, root()),
          throwsA(isA<UltracipherFormatException>()
              .having((e) => e.kind, 'kind', FormatErrorKind.badMagic)));
    });

    test('decompression is capped: more output than the limit is refused',
        () {
      var bomb = compressStripped(Uint8List(100000)); // 100 kB of zeros
      expect(decompressStripped(bomb).length, 100000);
      expect(() => decompressStripped(bomb, limit: 99999),
          throwsA(isA<FormatException>()));
      expect(decompressStripped(bomb, limit: 100000).length, 100000);
    });

    test('a cut or damaged BZip2 stream is a FormatException, not garbage',
        () {
      var good = compressStripped(utf8.encode('x' * 5000));
      expect(() => decompressStripped(good.sublist(0, good.length ~/ 2)),
          throwsA(isA<FormatException>()));
      var damaged = Uint8List.fromList(good)..[good.length ~/ 2] ^= 0x55;
      expect(() => decompressStripped(damaged),
          throwsA(isA<FormatException>()));
    });

    test('base64 text is capped before decoding (89,478,488 chars)', () {
      expect(maxBase64Length, 89478488);
      expect(decodeBase64Bounded('QUJD'), [0x41, 0x42, 0x43]);
      expect(() => decodeBase64Bounded('A' * (maxBase64Length + 1)),
          throwsA(isA<FormatException>()));
      expect(() => decodeBase64Bounded('!!!'), throwsA(isA<FormatException>()));
    });
  });
}
