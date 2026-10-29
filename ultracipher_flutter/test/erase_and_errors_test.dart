// Unit-Tests fuer UltracipherApp.eraseLocalData / isKeyCachePrefsKey (Plan
// Schritt 14, "Erase local data") und describeError (commons.dart).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/commons.dart';
import 'package:ultracipher_flutter/src/core.dart';

import 'memoized_key_derivation.dart';

const _legacy = {
  'user': 'old user',
  'github_token_abc': 'blob',
  'abcdef_database': 'old cache',
  'github_credentials_work_key': 'blob',
  // Looks like a key cache from the outside but is not 44 chars of base64.
  'AAAA_key': 'x',
};

// An old-format `_key` cache entry (44 chars base64 of a 32 byte digest plus
// `_key`). Format v1 no longer writes or reads these; the recognizer stays so
// that "Erase local data" still removes them.
final _oldKeyCache = '${base64.encode(List.filled(32, 7))}_key';

void main() {
  useMemoizedKeyDerivation();

  group('isKeyCachePrefsKey', () {
    test('matches an old key-cache entry, nothing of the old model; the app '
        'writes none any more', () async {
      expect(UltracipherApp.isKeyCachePrefsKey(_oldKeyCache), isTrue);
      SharedPreferences.setMockInitialValues({});
      var app = UltracipherApp();
      await app.init();
      await app.createDatabase('some passphrase');
      var keys = app.storage!.getKeys();
      expect(keys.where(UltracipherApp.isKeyCachePrefsKey), isEmpty);
      expect(keys.where((k) => k.startsWith('ucdb_')), hasLength(1));
      for (var legacy in _legacy.keys) {
        expect(UltracipherApp.isKeyCachePrefsKey(legacy), isFalse,
            reason: legacy);
      }
    });
  });

  group('eraseLocalData', () {
    late UltracipherApp app;

    setUp(() async {
      SharedPreferences.setMockInitialValues({..._legacy, _oldKeyCache: 'x'});
      app = UltracipherApp();
      await app.init();
      await app.createDatabase('some passphrase');
    });

    test('first step removes ucdb_ and key caches, keeps old-model entries',
        () async {
      expect(app.localDatabaseNames(), hasLength(1));
      expect(app.hasLegacyLocalData, isTrue);
      expect(app.storage!.containsKey(_oldKeyCache), isTrue);

      await app.eraseLocalData();

      expect(app.storage!.containsKey(_oldKeyCache), isFalse);

      expect(app.loadedDatabase.value, isNull, reason: 'session ended');
      expect(app.localDatabaseNames(), isEmpty);
      expect(app.storage!.getKeys().toSet(), _legacy.keys.toSet());
      expect(app.storage!.getString('github_credentials_work_key'), 'blob');
      expect(app.hasLegacyLocalData, isTrue);
    });

    test('includeLegacy clears everything', () async {
      await app.eraseLocalData();
      await app.eraseLocalData(includeLegacy: true);

      expect(app.storage!.getKeys(), isEmpty);
      expect(app.hasLegacyLocalData, isFalse);
    });

    test('without old-model entries there is no legacy data', () async {
      await app.eraseLocalData(includeLegacy: true);
      await app.createDatabase('another passphrase');
      expect(app.hasLegacyLocalData, isFalse);
    });
  });

  group('describeError', () {
    test('known safe messages pass', () {
      expect(describeError('plain text'), 'plain text');
      expect(describeError(RemoteBackendException('GitHub rejected')),
          'GitHub rejected');
      expect(describeError(NoLocalDatabaseException()),
          'No database found for this password');
      expect(describeError(LocalDatabaseExistsException()),
          LocalDatabaseExistsException().toString());
      expect(describeError(GithubFileMissingException()),
          GithubFileMissingException().toString());
    });

    test('unknown errors give only the type name', () {
      var text = describeError(Exception('secret-token-123'));
      expect(text, isNot(contains('secret')));
      expect(text, contains('Something went wrong'));
      var format = describeError(const FormatException('passphrase=hunter2'));
      expect(format, isNot(contains('hunter2')));
      expect(format, contains('FormatException'));
      var state = describeError(StateError('leak'));
      expect(state, isNot(contains('leak')));
      expect(state, contains('StateError'));
    });
  });
}
