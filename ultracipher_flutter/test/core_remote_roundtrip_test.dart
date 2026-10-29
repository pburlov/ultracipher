// App-level round-trip test for core.dart's sync path against any
// RemoteBackend (saveDatabase / syncNow / openLocalDatabase).
//
// Runs against FakeRemoteBackend (test/fake_remote_backend.dart) instead of
// a live remote, so it is offline and always on.
//
// What it proves: pulling a remote file, saving a local change, syncing and
// reopening keeps the entries, and the bytes the sync sent are the bytes the
// local copy holds. Entry-count equality alone would not prove that the write
// landed: the sync re-reads the remote and merges it into the identical local
// copy before encrypting, so a write() that silently did nothing would leave
// the count unchanged. encryptDatabase uses a fresh IV on every call, so
// comparing the raw ciphertext closes that gap.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<UltracipherApp> freshApp() async {
    SharedPreferences.setMockInitialValues({});
    var app = UltracipherApp();
    await app.init();
    return app;
  }

  test(
      'pull -> save -> sync -> reopen round-trips without losing entries, '
      'and the written bytes are the ones the local copy holds\n'
      'If this fails: core.dart\'s wiring on top of RemoteBackend is broken '
      '(or saveDatabase/syncNow silently not writing).', () async {
    var app = await freshApp();
    var remote = FakeRemoteBackend();

    // Seed the remote with a non-empty database under the name of 'test'.
    var key = await app.deriveRoot('test');
    var name = databaseName(key);
    var seeded = UltracipherDatabase();
    seeded.addEntry().addNewVersion(Entry(label: 'seeded'));
    await remote.write(name, UltracipherApp.encryptDatabase(seeded, key));

    await app.createDatabase('test');
    app.remoteBackend = remote;
    expect((await app.syncNow()).state, SyncState.synced);
    var firstLoad = app.loadedDatabase.value;
    expect(firstLoad, isNotNull);
    expect(firstLoad!.allEntries.length, equals(1),
        reason: 'the seeded entry must come back from the remote; zero here '
            'would mean the read was treated as empty');

    // A real local change: the sync only pushes when the merged state differs
    // from the remote (an unchanged save writes nothing, see sync_test.dart).
    firstLoad.addEntry().addNewVersion(Entry(label: 'added locally'));
    var writesBefore = remote.committedWrites;
    expect(await app.saveDatabase(), isTrue);
    // saveDatabase only saves locally and requests a sync; wait for it.
    expect((await app.syncNow()).state, SyncState.synced);
    expect(remote.committedWrites, equals(writesBefore + 1));
    // The local copy holds exactly the bytes handed to write().
    Uint8List localCopy() => base64
        .decode(app.storage!.getString(UltracipherApp.localPrefsKey(name))!);
    var writtenCiphertext = localCopy();
    expect(remote.storedBytes, equals(writtenCiphertext));

    app.closeDatabase();
    await app.openLocalDatabase('test');
    var secondLoad = app.loadedDatabase.value;
    expect(secondLoad, isNotNull);
    expect(secondLoad!.allEntries.length, equals(2));
    // Opening reads the copy without rewriting it.
    expect(localCopy(), equals(writtenCiphertext));
  });

  test(
      'saveDatabase without a session fails with a RemoteBackendException '
      'and leaves the loaded database alone', () async {
    var app = await freshApp();
    expect(app.remoteBackend, isNull);

    app.loadedDatabase.value = UltracipherDatabase()
      ..addEntry().addNewVersion(Entry(label: 'unsaved'));
    await expectLater(app.saveDatabase(),
        throwsA(isA<RemoteBackendException>()));
    // The check runs before cleanUp()/merge, so the open database is left as
    // it was.
    expect(app.loadedDatabase.value!.allEntries.length, equals(1));
  });
}
