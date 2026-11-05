// Unit-Tests fuer UltracipherApp.eraseLocalData / isKeyCachePrefsKey (Plan
// Schritt 14, "Erase local data") und describeError (commons.dart).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/commons.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/local_store/local_store.dart';
import 'package:ultracipher_flutter/src/model/model.dart';

import 'memoized_key_derivation.dart';
import 'write_limit.dart';

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
      // The copy is in the local store, no longer in the prefs.
      expect(keys.where((k) => k.startsWith('ucdb_')), isEmpty);
      expect(app.localStore!.names, hasLength(1));
      for (var legacy in _legacy.keys) {
        expect(UltracipherApp.isKeyCachePrefsKey(legacy), isFalse,
            reason: legacy);
      }
    });
  });

  group('eraseLocalData', () {
    late UltracipherApp app;
    late String name;

    setUp(() async {
      SharedPreferences.setMockInitialValues({..._legacy, _oldKeyCache: 'x'});
      app = UltracipherApp();
      await app.init();
      await app.createDatabase('some passphrase');
      // A second save, so that a .bak copy exists as well.
      app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
      await app.saveDatabase();
      name = app.localDatabaseNames().single;
      expect(app.localStore!.readBackup(name), isNotNull);
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
      // The store is empty, the .bak copy included.
      expect(app.localStore!.names, isEmpty);
      expect(app.localStore!.read(name), isNull);
      expect(app.localStore!.readBackup(name), isNull);
      expect(app.storage!.getKeys().toSet(), _legacy.keys.toSet());
      expect(app.storage!.getString('github_credentials_work_key'), 'blob');
      expect(app.hasLegacyLocalData, isTrue);
    });

    test('includeLegacy clears everything', () async {
      await app.eraseLocalData();
      await app.eraseLocalData(includeLegacy: true);

      expect(app.storage!.getKeys(), isEmpty);
      expect(app.hasLegacyLocalData, isFalse);
      expect(app.localStore!.names, isEmpty);
    });

    test('includeLegacy alone empties the store, .bak included, and the '
        'preferences', () async {
      await app.eraseLocalData(includeLegacy: true);

      expect(app.localStore!.names, isEmpty);
      expect(app.localStore!.readBackup(name), isNull);
      expect(app.storage!.getKeys(), isEmpty);
    });

    test('first step also removes a v1 copy left in the preferences (failed '
        'migration), but not an old-format one', () async {
      // Format v1 text under ucdb_: what a failed migration leaves behind.
      var v1 = base64.encode([0x55, 0x43, 0x44, 0x42, 0, 1, 0, 1, 7, 7]);
      await app.storage!.setString(UltracipherApp.localPrefsKey('left'), v1);
      await app.storage!.setString(UltracipherApp.localPrefsKey('old'),
          base64.encode([0, 1, 2, 3, 4, 5, 6, 7, 8]));

      await app.eraseLocalData();

      expect(app.storage!.containsKey(UltracipherApp.localPrefsKey('left')),
          isFalse);
      expect(app.storage!.containsKey(UltracipherApp.localPrefsKey('old')),
          isTrue);
      expect(app.localDatabaseNames(), isEmpty);
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
      expect(describeError(DatabaseTooLargeException()), tooLargeMessage);
      expect(describeError(const LocalStoreException(LocalStoreErrorKind.full)),
          'Not enough storage on this device; the change was not saved');
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
