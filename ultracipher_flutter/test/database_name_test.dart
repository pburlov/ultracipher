// Tests for the database name derivation: databaseName(R) (Dual-HKDF branch
// "ultracipher/name", since step 4 of the v1 plan), localPrefsKey and
// localDatabaseNames. The `_key` cache is gone (v1 has none). The pinned
// values live in user_key_hash_golden_test.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/crypto/dual_hkdf.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

Uint8List _bytes(int n, [int start = 0]) =>
    Uint8List.fromList(List.generate(n, (i) => (i + start) % 256));

Future<UltracipherApp> _freshApp(
    [Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  var app = UltracipherApp();
  await app.init();
  return app;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('databaseName', () {
    test('is base64url without padding, 43 chars for a 32 byte digest', () {
      for (var seed = 0; seed < 50; seed++) {
        var name = databaseName(_bytes(64, seed));
        expect(name, hasLength(43));
        expect(name, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(name, isNot(contains('=')));
      }
    });

    test('is deterministic and sensitive to the key', () {
      expect(databaseName(_bytes(64)), equals(databaseName(_bytes(64))));
      expect(databaseName(_bytes(64)), isNot(databaseName(_bytes(64, 1))));
    });

    test('is the Dual-HKDF branch "ultracipher/name" of R, nothing else', () {
      var root = _bytes(64);
      var expected = dualExpand(
          dualExtract(Uint8List.fromList(utf8.encode('ultracipher/name')), root),
          Uint8List.fromList(utf8.encode('ultracipher/name/1')),
          32);
      expect(databaseName(root),
          equals(base64Url.encode(expected).replaceAll('=', '')));
    });

    test('is not the file-key branch: disjoint HKDF info prefixes', () {
      var root = _bytes(64);
      // Same extract salt would still differ by info; here salt AND info of
      // the file branch are used and must not give the name.
      var file = dualExpand(
          dualExtract(Uint8List(32), root),
          Uint8List.fromList(utf8.encode('ultracipher/file/aes-256-ctr/key')),
          32);
      expect(databaseName(root),
          isNot(base64Url.encode(file).replaceAll('=', '')));
    });

    test('accepts only a 64 byte R (a former 32 byte key must not slip '
        'through)', () {
      expect(() => databaseName(_bytes(32)), throwsArgumentError);
      expect(() => databaseName(_bytes(63)), throwsArgumentError);
      expect(() => databaseName(_bytes(65)), throwsArgumentError);
    });
  });

  // Beginn einer v1-Datei: Magic UCDB, Version 0x0001 (nur die Magic zaehlt).
  final v1Text = base64.encode([0x55, 0x43, 0x44, 0x42, 0, 1, 0, 1, 7, 7]);

  group('localPrefsKey / localDatabaseNames', () {
    test('localPrefsKey prefixes the name with ucdb_', () {
      expect(UltracipherApp.localPrefsKey('abc'), 'ucdb_abc');
    });

    test('localDatabaseNames lists only ucdb_ entries, prefix stripped',
        () async {
      var key = _bytes(64);
      var app = await _freshApp({
        UltracipherApp.localPrefsKey('nameA'): v1Text,
        UltracipherApp.localPrefsKey('nameB'): v1Text,
        UltracipherApp.localPrefsKey(databaseName(key)): v1Text,
        // Old entries must not count.
        'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG_database': 'old',
        'abc=_key': 'cache',
        'user': 'alice',
        'github_token_abc': 'blob',
        'github_credentials_abc': 'blob',
        'xucdb_notaprefix': 'no',
        // Bare prefix has no name.
        'ucdb_': 'empty',
      });
      expect(app.localDatabaseNames()..sort(),
          equals(['nameA', 'nameB', databaseName(key)]..sort()));
    });

    test('copies without the v1 magic are legacy, not listed', () async {
      var app = await _freshApp({
        UltracipherApp.localPrefsKey('v1'): v1Text,
        // v2: leading 0x00.
        UltracipherApp.localPrefsKey('v2'):
            base64.encode([0, 1, 2, 3, 4, 5, 6, 7, 8]),
        // Garbage: not base64, too short, wrong magic case.
        UltracipherApp.localPrefsKey('bad'): '!!!!!!!!!!!!',
        UltracipherApp.localPrefsKey('short'): 'VUNE',
        UltracipherApp.localPrefsKey('empty'): '',
        UltracipherApp.localPrefsKey('lower'):
            base64.encode([0x75, 0x63, 0x64, 0x62, 0, 1, 0, 1]),
      });
      expect(app.localDatabaseNames(), equals(['v1']));
      expect(app.hasLegacyLocalData, isTrue);
    });

    test('a non-string value under ucdb_ is legacy and does not throw',
        () async {
      var app = await _freshApp({UltracipherApp.localPrefsKey('n'): 42});
      expect(app.localDatabaseNames(), isEmpty);
      expect(app.hasLegacyLocalData, isTrue);
    });

    test('only v1 copies: no legacy data', () async {
      var app = await _freshApp({UltracipherApp.localPrefsKey('a'): v1Text});
      expect(app.hasLegacyLocalData, isFalse);
    });

    test('eraseLocalData keeps legacy copies, includeLegacy removes them',
        () async {
      var v2 = UltracipherApp.localPrefsKey('v2');
      var app = await _freshApp({
        UltracipherApp.localPrefsKey('v1'): v1Text,
        v2: base64.encode([0, 1, 2, 3, 4, 5, 6, 7, 8]),
      });
      await app.eraseLocalData();
      expect(app.storage!.getKeys(), equals({v2}));
      expect(app.hasLegacyLocalData, isTrue);
      await app.eraseLocalData(includeLegacy: true);
      expect(app.storage!.getKeys(), isEmpty);
      expect(app.hasLegacyLocalData, isFalse);
    });

    test('localDatabaseNames is empty without stored databases', () async {
      var app = await _freshApp({'user': 'alice'});
      expect(app.localDatabaseNames(), isEmpty);
    });
  });
}
