// Tests der Sync-Engine (lib/src/sync.dart und UltracipherApp.saveDatabase/
// syncNow/requestSync in core.dart) gegen FakeRemoteBackend: kein Netz.
//
// Die Fakes bilden GitHubs Versionspruefung nach (Version = "sha", ein Write
// mit veralteter Version ist ein Konflikt) und lassen Fehler, Konflikte und
// angehaltene Aufrufe einspritzen. Echte Verschluesselung (Format v1); die KDF
// je Passphrase einmal echt, dann gemerkt (memoized_key_derivation.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

const _pass = 'sync passphrase';

UltracipherDatabase _dbWith(List<String> labels) {
  var db = UltracipherDatabase();
  for (var label in labels) {
    db.addEntry().addNewVersion(Entry(label: label));
  }
  return db;
}

List<String> _labels(UltracipherDatabase db) =>
    db.allEntries.map((e) => e.latestEntry!.label).toList()..sort();

class _Env {
  final UltracipherApp app;
  final FakeRemoteBackend remote;
  final Uint8List key;

  _Env(this.app, this.remote, this.key);

  /// Name of the open database (its `ucdb_<name>` prefs entry is the cache).
  String get name => databaseName(key);

  UltracipherDatabase get db => app.loadedDatabase.value!;

  /// The remote state, decrypted.
  UltracipherDatabase remoteDb() =>
      UltracipherApp.decryptDatabase(remote.storedBytes!, key);

  /// The local cache entry, decrypted.
  UltracipherDatabase cachedDb() =>
      UltracipherApp.decryptDatabase(cacheBytes(), key);

  Uint8List cacheBytes() => base64.decode(
      app.storage!.getString(UltracipherApp.localPrefsKey(name))!);

  /// Lands a change by "another device" in the remote: adds [label] to a copy
  /// of the remote state (same entry ids) and stores it with a new version.
  void otherDeviceAdds(String label) {
    var db = remoteDb();
    db.addEntry().addNewVersion(Entry(label: label));
    remote.seed(UltracipherApp.encryptDatabase(db, key));
  }

  /// A local edit, saved locally (saveDatabase) - and with it a sync request.
  Future<void> localAdds(String label) async {
    db.addEntry().addNewVersion(Entry(label: label));
    expect(await app.saveDatabase(), isTrue);
  }
}

/// A fresh app on an empty SharedPreferences with a local database, linked to
/// a remote seeded with [remoteLabels] (an empty list means: no file at the
/// remote) and synced once, so the remote's entries are in the local copy.
Future<_Env> _open({List<String> remoteLabels = const ['base']}) async {
  SharedPreferences.setMockInitialValues({});
  var app = UltracipherApp();
  await app.init();
  var remote = FakeRemoteBackend();
  var key = await app.deriveRoot(_pass);
  await app.createDatabase(_pass);
  app.remoteBackend = remote;
  if (remoteLabels.isNotEmpty) {
    remote.seed(UltracipherApp.encryptDatabase(_dbWith(remoteLabels), key));
    expect((await app.syncNow()).state, SyncState.synced);
  }
  return _Env(app, remote, key);
}

/// Waits (test only) until [condition] holds.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SingleFlight', () {
    test('five quick calls while one runs coalesce into exactly one follow-up',
        () async {
      var runs = 0;
      var gate = Completer<void>();
      var flight = SingleFlight<int>(() async {
        var n = ++runs;
        if (n == 1) await gate.future;
        return n;
      });

      var first = flight.run();
      expect(flight.isRunning, isTrue);
      expect(flight.hasPending, isFalse);
      var others = [for (var i = 0; i < 4; i++) flight.run()];
      expect(flight.hasPending, isTrue);

      gate.complete();
      expect(await first, equals(1));
      // Every caller that arrived during the run gets the follow-up's result.
      expect(await Future.wait(others), equals([2, 2, 2, 2]));
      expect(runs, equals(2));
      await flight.idle;
      expect(flight.isRunning, isFalse);
      expect(flight.hasPending, isFalse);

      // Idle again: the next call starts a run of its own.
      expect(await flight.run(), equals(3));
    });

    test('a failing run reaches its callers and does not wedge the flight',
        () async {
      var runs = 0;
      var gate = Completer<void>();
      var flight = SingleFlight<int>(() async {
        var n = ++runs;
        if (n == 1) {
          await gate.future;
          throw StateError('first run fails');
        }
        return n;
      });

      Future<Object?> outcome(Future<int> f) =>
          f.then<Object?>((v) => v, onError: (Object e) => e);
      var first = outcome(flight.run());
      var second = outcome(flight.run());
      gate.complete();

      expect(await first, isA<StateError>());
      expect(await second, equals(2));
      await flight.idle;
      expect(await flight.run(), equals(3));
    });

    test('exclusive waits for a running run, and runs requested meanwhile '
        'start only after it (one coalesced follow-up)', () async {
      var log = <String>[];
      var runGate = Completer<void>();
      var runs = 0;
      var flight = SingleFlight<int>(() async {
        var n = ++runs;
        log.add('run $n start');
        if (n == 1) await runGate.future;
        log.add('run $n end');
        return n;
      });
      var first = flight.run();
      var holdGate = Completer<void>();
      var held = flight.exclusive(() async {
        log.add('exclusive start');
        await holdGate.future;
        log.add('exclusive end');
        return 'done';
      });
      await Future<void>.delayed(Duration.zero);
      expect(log, ['run 1 start']);

      runGate.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(log.last, 'exclusive start');
      expect(flight.isHeld, isTrue);
      var during = [flight.run(), flight.run()];
      var idle = flight.idle;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(runs, 1, reason: 'no run may start while the lock is held');

      holdGate.complete();
      expect(await held, 'done');
      expect(await Future.wait(during), [2, 2]);
      await idle;
      expect(log, [
        'run 1 start',
        'run 1 end',
        'exclusive start',
        'exclusive end',
        'run 2 start',
        'run 2 end'
      ]);
      expect(flight.isHeld, isFalse);
    });

    test('reset releases the lock: a new run starts at once, and the end of '
        'the abandoned exclusive does not disturb it', () async {
      var runs = 0;
      var runGate = Completer<void>();
      var flight = SingleFlight<int>(() async {
        var n = ++runs;
        await runGate.future;
        return n;
      });
      var holdGate = Completer<void>();
      var held = flight.exclusive(() => holdGate.future);
      await Future<void>.delayed(Duration.zero);
      expect(flight.isHeld, isTrue);

      flight.reset(-1);
      expect(flight.isHeld, isFalse);
      var first = flight.run();
      expect(runs, 1);

      var next = flight.run();
      expect(flight.hasPending, isTrue);
      // Das Ende der aufgegebenen Sperre fasst den neuen Lauf und seinen
      // Folgelauf nicht an (kein zweiter Lauf daneben).
      holdGate.complete();
      await held;
      expect(flight.isRunning, isTrue);
      expect(flight.hasPending, isTrue);
      expect(runs, 1);
      runGate.complete();
      expect(await first, 1);
      expect(await next, 2);
    });
  });

  group('offline and errors', () {
    test(
        'offline keeps the change locally (cache has it, status notSynced); '
        'a later syncNow catches the remote up', () async {
      var env = await _open();
      env.remote.readFailure = RemoteBackendException('offline');

      await env.localAdds('made offline');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.notSynced);
      expect(status.error, equals('offline'));
      expect(env.app.syncStatus.value.state, SyncState.notSynced);
      expect(_labels(env.cachedDb()), equals(['base', 'made offline']));
      expect(_labels(env.remoteDb()), equals(['base']));
      expect(env.remote.writeCount, equals(0));

      env.remote.readFailure = null;
      status = await env.app.syncNow();
      expect(status.state, SyncState.synced);
      expect(_labels(env.remoteDb()), equals(['base', 'made offline']));
      expect(_labels(env.cachedDb()), equals(['base', 'made offline']));
    });

    test('a write failure keeps the change locally too', () async {
      var env = await _open();
      env.remote.writeFailure = RemoteBackendException('server error',
          statusCode: 500);

      await env.localAdds('edit');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.notSynced);
      expect(_labels(env.cachedDb()), equals(['base', 'edit']));
      expect(_labels(env.remoteDb()), equals(['base']));

      env.remote.writeFailure = null;
      expect((await env.app.syncNow()).state, SyncState.synced);
      expect(_labels(env.remoteDb()), equals(['base', 'edit']));
    });

    test('a non-backend network error is notSynced and leaks no detail',
        () async {
      var env = await _open();
      env.remote.readFailure = http.ClientException(
          'connection failed', Uri.parse('https://secret.example/path'));

      await env.localAdds('edit');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.notSynced);
      expect(status.error, isNot(contains('secret.example')));
      expect(_labels(env.cachedDb()), equals(['base', 'edit']));
    });

    test('a rejected credential is authRequired; local data stays', () async {
      var env = await _open();
      env.remote.readFailure = RemoteAuthException('bad token',
          statusCode: 401);

      await env.localAdds('edit');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.authRequired);
      expect(status.error, equals('bad token'));
      expect(env.remote.writeCount, equals(0));
      expect(_labels(env.cachedDb()), equals(['base', 'edit']));

      // The same from a rejected write.
      env.remote.readFailure = null;
      env.remote.writeFailure = RemoteAuthException('bad token');
      expect((await env.app.syncNow()).state, SyncState.authRequired);
    });

    test(
        'a rate limit is notSynced with retryAfter; automatic triggers wait, '
        'an explicit syncNow does not', () async {
      var env = await _open();
      env.remote.readFailure = RemoteRateLimitException('rate limited',
          statusCode: 429, retryAfter: const Duration(seconds: 90));

      await env.localAdds('edit');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.notSynced);
      expect(status.retryAfter, equals(const Duration(seconds: 90)));
      expect(status.retryAt!.isAfter(DateTime.now()), isTrue);
      expect(_labels(env.cachedDb()), equals(['base', 'edit']));

      // No timer, but the automatic trigger does not hammer a limited API.
      var reads = env.remote.readCount;
      env.app.requestSync();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(env.remote.readCount, equals(reads));
      await env.localAdds('another');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(env.remote.readCount, equals(reads));

      // An explicit "Sync now" always asks.
      env.remote.readFailure = null;
      expect((await env.app.syncNow()).state, SyncState.synced);
      expect(env.remote.readCount, greaterThan(reads));
      expect(_labels(env.remoteDb()), equals(['another', 'base', 'edit']));
    });

    test('a rate limit without Retry-After has no retryAfter', () async {
      var env = await _open();
      env.remote.readFailure = RemoteRateLimitException('rate limited');

      var status = await env.app.syncNow();

      expect(status.state, SyncState.notSynced);
      expect(status.retryAfter, isNull);
      expect(status.retryAt, isNull);
    });

    test('an unreadable remote file is never written over', () async {
      var env = await _open();
      // A valid v1 header (UCDB, version 1, suite 1, profile 1, flags 0) and
      // minimum length, but junk after it: authentication fails.
      var garbage = Uint8List.fromList([
        0x55, 0x43, 0x44, 0x42, 0, 1, 0, 1, 0, 1, 0, 0, //
        ...List.generate(144, (i) => i * 5 + 1),
      ]);
      env.remote.seed(garbage);
      var writes = env.remote.writeCount;

      await env.localAdds('edit');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.notSynced);
      expect(status.error, contains('corrupted'));
      expect(env.remote.writeCount, equals(writes));
      expect(env.remote.storedBytes, equals(garbage));
      // The local data is intact.
      expect(_labels(env.cachedDb()), equals(['base', 'edit']));
      expect(_labels(env.db), equals(['base', 'edit']));
    });

    test('a remote file of another format (old v2) is named as such and never '
        'written over', () async {
      var env = await _open();
      var old = Uint8List.fromList(List.generate(47, (i) => i * 5)); // 0x00 first
      env.remote.seed(old);
      var writes = env.remote.writeCount;

      await env.localAdds('edit');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.notSynced);
      expect(status.error, UltracipherApp.oldFormatMessage);
      expect(env.remote.writeCount, equals(writes));
      expect(env.remote.storedBytes, equals(old));
    });

    test('a missing remote file (404) is remoteMissing, nothing is created',
        () async {
      var env = await _open();
      env.remote.deleteFile();

      await env.localAdds('edit');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.remoteMissing);
      expect(status.error, isNotEmpty);
      expect(env.remote.writeCount, equals(0));
      expect(env.remote.storedBytes, isNull);
      expect(_labels(env.cachedDb()), equals(['base', 'edit']));

      // Again and again: still no auto-create.
      expect((await env.app.syncNow()).state, SyncState.remoteMissing);
      expect(env.remote.writeCount, equals(0));
    });

    test('a database opened on an empty remote does not create it either',
        () async {
      var env = await _open(remoteLabels: const []);

      await env.localAdds('first');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.remoteMissing);
      expect(env.remote.writeCount, equals(0));
      expect(env.remote.storedBytes, isNull);
    });
  });

  group('conflicts', () {
    test(
        'both sides changed: the conflict loop converges, result is the '
        'merge and remote equals local', () async {
      var env = await _open();
      // The first write loses against another device's change.
      env.remote.beforeWrite = (n) {
        if (n == 1) env.otherDeviceAdds('other device');
      };

      await env.localAdds('local');
      var status = await env.app.syncNow();

      expect(status.state, SyncState.synced);
      var expected = ['base', 'local', 'other device'];
      expect(_labels(env.db), equals(expected));
      expect(_labels(env.remoteDb()), equals(expected));
      expect(_labels(env.cachedDb()), equals(expected));
      // Write 1 lost, write 2 landed; nothing is left to push afterwards.
      expect(env.remote.writeCount, equals(2));
      expect(env.remote.committedWrites, equals(1));
      expect(env.remoteDb().hasSameContentAs(env.db), isTrue);
    });

    test('an injected conflict at the first write is retried once', () async {
      var env = await _open();
      env.remote.conflictAtWrite.add(1);

      await env.localAdds('local');
      expect((await env.app.syncNow()).state, SyncState.synced);

      expect(env.remote.writeCount, equals(2));
      expect(env.remote.committedWrites, equals(1));
      expect(_labels(env.remoteDb()), equals(['base', 'local']));
    });

    test('the loop stops after 3 attempts: notSynced, no endless writes',
        () async {
      var env = await _open();
      env.remote.alwaysConflict = true;
      await env.localAdds('local');
      // Settle the run that saveDatabase started (and its follow-up).
      await env.app.syncNow();
      var writes = env.remote.writeCount;
      var reads = env.remote.readCount;

      // One more explicit sync under permanent conflict: exactly 3 attempts.
      var status = await env.app.syncNow();

      expect(status.state, SyncState.notSynced);
      expect(status.error, contains('retry'));
      expect(env.remote.writeCount - writes, equals(3));
      expect(env.remote.readCount - reads, equals(3));
      expect(_labels(env.cachedDb()), equals(['base', 'local']));

      // Nothing keeps writing in the background.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(env.remote.writeCount - writes, equals(3));

      env.remote.alwaysConflict = false;
      expect((await env.app.syncNow()).state, SyncState.synced);
      expect(_labels(env.remoteDb()), equals(['base', 'local']));
    });
  });

  group('coalescing and ordering', () {
    test(
        'five quick saves while a sync is writing: at most two runs, all data '
        'arrives', () async {
      var env = await _open();
      var gate = Completer<void>();
      env.remote.writeGate = gate;
      var reads = env.remote.readCount;
      var commits = env.remote.committedWrites;

      await env.localAdds('e0');
      await _until(() => env.remote.writeCount == 1);
      // The first run is now held inside write(); more changes arrive.
      for (var i = 1; i < 5; i++) {
        await env.localAdds('e$i');
      }
      env.app.requestSync();
      expect(env.app.syncStatus.value.state, SyncState.syncing);

      gate.complete();
      var status = await env.app.syncNow();

      expect(status.state, SyncState.synced);
      expect(env.remote.readCount - reads, equals(2));
      expect(env.remote.committedWrites - commits, equals(2));
      var expected = ['base', 'e0', 'e1', 'e2', 'e3', 'e4'];
      expect(_labels(env.remoteDb()), equals(expected));
      expect(_labels(env.cachedDb()), equals(expected));
    });

    test('saveDatabase returns after the local save, it does not wait for the '
        'network', () async {
      var env = await _open();
      var gate = Completer<void>();
      env.remote.readGate = gate;

      await env.localAdds('edit'); // completes although read() is held
      expect(env.remote.committedWrites, equals(0));
      expect(_labels(env.cachedDb()), equals(['base', 'edit']));
      expect(env.app.syncStatus.value.state, SyncState.syncing);

      gate.complete();
      expect((await env.app.syncNow()).state, SyncState.synced);
      expect(_labels(env.remoteDb()), equals(['base', 'edit']));
    });

    test('the status goes syncing -> synced and notifies', () async {
      var env = await _open();
      var seen = <SyncState>[];
      env.app.syncStatus.addListener(() => seen.add(env.app.syncStatus.value.state));

      await env.localAdds('edit');
      await env.app.syncNow();

      // The local save marks the change as not synced, the run follows.
      expect(seen.first, SyncState.notSynced);
      expect(seen, contains(SyncState.syncing));
      expect(seen.last, SyncState.synced);
    });
  });

  group('push only when there is something to push', () {
    test('no change: reads, but no write', () async {
      var env = await _open();
      var commits = env.remote.committedWrites;

      expect((await env.app.syncNow()).state, SyncState.synced);
      expect((await env.app.syncNow()).state, SyncState.synced);
      // A save without any change is not a change either.
      expect(await env.app.saveDatabase(), isTrue);
      expect((await env.app.syncNow()).state, SyncState.synced);

      expect(env.remote.writeCount, equals(commits));
      expect(env.remote.committedWrites, equals(commits));
    });

    test('a remote-only change is merged locally without any write', () async {
      var env = await _open();
      env.otherDeviceAdds('from elsewhere');
      var commits = env.remote.committedWrites;
      var writes = env.remote.writeCount;

      expect((await env.app.syncNow()).state, SyncState.synced);

      expect(env.remote.writeCount, equals(writes));
      expect(env.remote.committedWrites, equals(commits));
      expect(_labels(env.db), equals(['base', 'from elsewhere']));
      expect(_labels(env.cachedDb()), equals(['base', 'from elsewhere']));
    });

    test('after a push the cache holds exactly the remote bytes', () async {
      var env = await _open();
      await env.localAdds('edit');
      await env.app.syncNow();

      expect(env.cacheBytes(), equals(env.remote.storedBytes));
    });
  });

  group('session counter', () {
    test('a sync returning after closeDatabase changes nothing', () async {
      var env = await _open();
      await env.localAdds('local');
      await env.app.syncNow();
      env.otherDeviceAdds('remote only');
      var gate = Completer<void>();
      env.remote.readGate = gate;
      var reads = env.remote.readCount;
      await env.localAdds('local too');
      await _until(() => env.remote.readCount > reads);
      var cacheKey = UltracipherApp.localPrefsKey(env.name);
      var cacheBefore = env.app.storage!.getString(cacheKey);
      var writes = env.remote.writeCount;
      var remoteBefore = env.remote.storedBytes;

      env.app.closeDatabase();
      expect(env.app.syncStatus.value.state, SyncState.noRemote);
      gate.complete();
      // Waits for the stale run (the follow-up finds nothing open).
      var status = await env.app.syncNow();

      expect(status.state, SyncState.noRemote);
      expect(env.app.syncStatus.value.state, SyncState.noRemote);
      expect(env.app.loadedDatabase.value, isNull);
      expect(env.app.storage!.getString(cacheKey), equals(cacheBefore));
      expect(env.remote.writeCount, equals(writes));
      expect(env.remote.storedBytes, equals(remoteBefore));
    });

    test('a sync returning after another database was opened changes nothing',
        () async {
      var env = await _open();
      env.otherDeviceAdds('remote only');
      var gate = Completer<void>();
      env.remote.readGate = gate;
      var reads = env.remote.readCount;
      await env.localAdds('local');
      await _until(() => env.remote.readCount > reads);
      var cacheKey = UltracipherApp.localPrefsKey(env.name);
      var cacheBefore = env.app.storage!.getString(cacheKey);

      // Another database (imported from text) replaces the open one.
      var otherKey = await env.app.deriveRoot('other passphrase');
      var text = base64.encode(
          UltracipherApp.encryptDatabase(_dbWith(['from text']), otherKey));
      await env.app.importEncryptedText(text, 'other passphrase');
      var opened = env.app.loadedDatabase.value!;
      gate.complete();
      var status = await env.app.syncNow();

      expect(status.state, SyncState.noRemote);
      expect(env.app.loadedDatabase.value, same(opened));
      expect(_labels(opened), equals(['from text']));
      expect(env.app.storage!.getString(cacheKey), equals(cacheBefore));
      expect(env.remote.writeCount, equals(0));
    });
  });

  group('settings merged from the remote', () {
    final github = GithubSettings(
        token: 'tok', owner: 'o', repo: 'moved', branch: 'main');

    /// Puts the settings into the remote with a newer time.
    void remoteSettings(_Env env, GithubSettings? value) {
      var db = env.remoteDb();
      db.setSettings(
          github: value, time: DateTime.now().add(const Duration(minutes: 1)));
      env.remote.seed(UltracipherApp.encryptDatabase(db, env.key));
    }

    test('a merge that changes the GitHub settings rebuilds the backend',
        () async {
      var env = await _open();
      var other = FakeRemoteBackend();
      GithubSettings? builtFor;
      env.app.backendForSettings = (settings, key) {
        builtFor = settings;
        return other;
      };
      remoteSettings(env, github);
      other.seed(env.remote.storedBytes!);
      var reads = env.remote.readCount;

      await env.app.syncNow();
      var status = await env.app.syncNow();

      expect(builtFor, equals(github));
      expect(env.app.remoteBackend, same(other));
      expect(env.db.settings!.github, equals(github));
      expect(env.cachedDb().settings!.github, equals(github));
      // The old location was read once; the new one takes over.
      expect(env.remote.readCount - reads, equals(1));
      expect(other.readCount, greaterThanOrEqualTo(1));
      expect(status.state, SyncState.synced);
    });

    test('unchanged settings do not rebuild or restart anything', () async {
      var env = await _open();
      var builds = 0;
      env.app.backendForSettings = (settings, key) {
        builds++;
        return env.remote;
      };
      remoteSettings(env, github);
      var reads = env.remote.readCount;

      // The rebuilt backend is the current target: no switch, no follow-up.
      expect((await env.app.syncNow()).state, SyncState.synced);
      expect(builds, equals(1));
      expect(env.app.remoteBackend, same(env.remote));
      expect(env.remote.readCount - reads, equals(1));

      // Nothing new: the settings do not differ from the local ones any more.
      expect((await env.app.syncNow()).state, SyncState.synced);
      expect(builds, equals(1));
    });

    test('"GitHub removed" ends the remote link for the session', () async {
      var env = await _open();
      env.app.backendForSettings = (settings, key) =>
          settings == null ? null : env.remote;
      // A session whose backend comes from the settings (as after a reopen).
      env.db.setSettings(
          github: github, time: DateTime.now().subtract(const Duration(days: 1)));
      await env.app.saveDatabase();
      await env.app.syncNow();
      env.app.closeDatabase();
      await env.app.openLocalDatabase(_pass);
      expect(env.app.remoteBackend, same(env.remote));
      remoteSettings(env, null);

      var status = await env.app.syncNow();

      expect(status.state, SyncState.noRemote);
      expect(env.app.remoteBackend, isNull);
      expect(env.db.settings!.github, isNull);
      expect(env.cachedDb().settings!.github, isNull);
    });
  });

  group('reopening a database whose settings name the remote', () {
    final github =
        GithubSettings(token: 'tok', owner: 'o', repo: 'r', branch: 'main');

    /// A synced session whose backend comes from the settings, closed and
    /// reopened from its local copy (backend and first sync via the open).
    Future<_Env> reopened() async {
      var env = await _open();
      env.app.backendForSettings =
          (settings, key) => settings == null ? null : env.remote;
      env.db.setSettings(github: github);
      await env.app.saveDatabase();
      expect((await env.app.syncNow()).state, SyncState.synced);
      env.app.closeDatabase();
      await env.app.openLocalDatabase(_pass);
      expect(env.app.remoteBackend, same(env.remote));
      return env;
    }

    test('offline edit, close, other device edits, reopen: the sync merges '
        'both into the database, the copy and the remote', () async {
      var env = await reopened();
      await env.app.syncNow();
      env.remote.readFailure = RemoteBackendException('offline');
      await env.localAdds('offline');
      expect((await env.app.syncNow()).state, SyncState.notSynced);
      env.app.closeDatabase();

      env.remote.readFailure = null;
      env.otherDeviceAdds('elsewhere');
      await env.app.openLocalDatabase(_pass);
      expect((await env.app.syncNow()).state, SyncState.synced);

      var expected = ['base', 'elsewhere', 'offline'];
      expect(_labels(env.db), equals(expected));
      expect(_labels(env.cachedDb()), equals(expected));
      expect(_labels(env.remoteDb()), equals(expected));
    });

    test('reopening with a remote that is already up to date: synced, no '
        'extra write', () async {
      var env = await reopened();
      expect((await env.app.syncNow()).state, SyncState.synced);
      var commits = env.remote.committedWrites;
      var writes = env.remote.writeCount;
      env.app.closeDatabase();

      await env.app.openLocalDatabase(_pass);
      expect((await env.app.syncNow()).state, SyncState.synced);

      expect(env.remote.committedWrites, equals(commits));
      expect(env.remote.writeCount, equals(writes));
      expect(_labels(env.db), equals(['base']));
      expect(env.cachedDb().hasSameContentAs(env.remoteDb()), isTrue);
    });
  });

  group('an edit on an entry removed by a merged deletion (CEX2)', () {
    test('addVersion re-resolves by id: the edit survives', () async {
      var env = await _open(remoteLabels: ['a', 'b']);
      var e = env.db.allEntries.firstWhere((x) => x.latestEntry!.label == 'a');
      var r = env.remoteDb();
      r.deleteEntry(r.getEntryWhitId(e.id)!);
      env.remote.seed(UltracipherApp.encryptDatabase(r, env.key));
      await env.app.syncNow();
      expect(env.db.getEntryWhitId(e.id), isNull); // e is detached now
      await Future<void>.delayed(const Duration(milliseconds: 5));

      env.db.addVersion(e, Entry(label: 'after'));
      expect(await env.app.saveDatabase(), isTrue);
      await env.app.syncNow();

      expect(_labels(env.cachedDb()), contains('after'));
      expect(_labels(env.remoteDb()), contains('after'));
      expect(_labels(env.remoteDb()), contains('b'));
    });

    test('removeVersion takes back exactly the own version', () async {
      var db = _dbWith(['a']);
      var e = db.allEntries.single;
      var mine = Entry(label: 'mine');
      db.addVersion(e, mine);
      // Another version arrives meanwhile (e.g. from a merge) and sorts first.
      e.addNewVersion(Entry(label: 'merged in'));

      db.removeVersion(e, mine);

      expect(e.versions.map((v) => v.label), equals(['merged in', 'a']));
      // A new entry vanishes with its only version.
      var created = db.addVersion(null, Entry(label: 'fresh'));
      db.removeVersion(created, created.versions.first);
      expect(db.getEntryWhitId(created.id), isNull);
    });
  });

  group('hanging network calls', () {
    test('a hung run of a closed session does not block the next session '
        '(CEX3)', () async {
      var env = await _open();
      env.remote.readGate = Completer<void>(); // never released
      await env.localAdds('x');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      env.app.closeDatabase();
      var second = FakeRemoteBackend();
      second.seed(env.remote.storedBytes!);
      env.app.remoteBackend = second;
      await env.app.openLocalDatabase(_pass);
      env.app.remoteBackend = second;
      await env.app.saveDatabase();
      await _until(() => second.readCount > 0);
      expect((await env.app.syncNow()).state, SyncState.synced);
    });

    test('SingleFlight.reset frees the flight for the next run', () async {
      var gate = Completer<void>();
      var runs = 0;
      var flight = SingleFlight<int>(() async {
        var n = ++runs;
        if (n == 1) await gate.future;
        return n;
      });
      var first = flight.run();
      var pending = flight.run();

      flight.reset(-1);
      expect(await first, equals(-1));
      expect(await pending, equals(-1));
      expect(await flight.run(), equals(2));
      gate.complete(); // the abandoned run ends without touching the flight
      await Future<void>.delayed(Duration.zero);
      expect(flight.isRunning, isFalse);
      expect(await flight.run(), equals(3));
    });

    test('a pending change is never shown as synced', () async {
      var env = await _open();
      expect(env.app.syncStatus.value.state, SyncState.synced);
      var gate = Completer<void>();
      env.remote.readGate = gate;

      env.db.addEntry().addNewVersion(Entry(label: 'pending'));
      await env.app.saveDatabase();

      expect(env.app.syncStatus.value.state, isNot(SyncState.synced));
      gate.complete();
      expect((await env.app.syncNow()).state, SyncState.synced);
    });
  });
}
