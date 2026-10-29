// Tests für den verschlüsselten Austausch als base64-Text:
// UltracipherApp.exportEncryptedDatabase (Export) und der Rückweg über
// importEncryptedText. Das Import-Verhalten selbst (Whitespace, neutrale
// Fehler, Merge in eine lokale Kopie) prüft session_test.dart.
//
// Der Text sind genau die Bytes, die der Remote-Speicher ablegt
// (encryptDatabase), nur base64-kodiert. Die Tests laufen gegen
// FakeRemoteBackend, ohne Netz und ohne Dateidialog.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/sync.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

const _pass = 'test';

Future<UltracipherApp> _freshApp() async {
  SharedPreferences.setMockInitialValues({});
  var app = UltracipherApp();
  await app.init();
  return app;
}

/// Legt eine Datenbank mit zwei Einträgen an und öffnet sie.
Future<void> _sessionWithTwoEntries(UltracipherApp app) async {
  await app.createDatabase(_pass);
  var db = app.loadedDatabase.value!;
  db.addEntry().addNewVersion(Entry(label: 'alpha'));
  db.addEntry().addNewVersion(Entry(label: 'beta'));
  await app.saveDatabase();
}

/// Simuliert ein frisches Gerät: Sitzung schließen und alle Preferences
/// löschen.
Future<void> _freshDevice(UltracipherApp app) async {
  app.closeDatabase();
  await app.storage!.clear();
}

List<String> _labelsOf(UltracipherDatabase db) =>
    db.allEntries.map((e) => e.latestEntry!.label).toList()..sort();

/// Runs [future] and returns the thrown error (failing if none is thrown).
Future<Object> _captureException(Future future) async {
  try {
    await future;
  } catch (e) {
    return e;
  }
  return fail('expected an exception, but none was thrown');
}

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('export -> base64 -> importEncryptedText round-trips the entries',
      () async {
    var app = await _freshApp();
    await _sessionWithTwoEntries(app);
    var text = base64.encode(await app.exportEncryptedDatabase());
    var originalIds =
        app.loadedDatabase.value!.allEntries.map((e) => e.id).toList();

    await _freshDevice(app);
    await app.importEncryptedText(text, _pass);

    var opened = app.loadedDatabase.value;
    expect(opened, isNotNull);
    expect(_labelsOf(opened!), equals(['alpha', 'beta']));
    expect(opened.allEntries.map((e) => e.id).toList()..sort(),
        equals(originalIds..sort()));
  });

  test('the text the remote stores imports as is (same format as GitHub)',
      () async {
    var app = await _freshApp();
    await _sessionWithTwoEntries(app);
    // An existing (here: empty) remote file, then the sync pushes the entries.
    var remote = FakeRemoteBackend();
    var key = await app.deriveRoot(_pass);
    remote.seed(UltracipherApp.encryptDatabase(UltracipherDatabase(), key));
    app.remoteBackend = remote;
    expect((await app.syncNow()).state, SyncState.synced);
    // Die Bytes, die im Remote-Speicher liegen, nicht der Export.
    var text = base64.encode(remote.storedBytes!);

    await _freshDevice(app);
    await app.importEncryptedText(text, _pass);

    expect(_labelsOf(app.loadedDatabase.value!), equals(['alpha', 'beta']));
  });

  test('a failed import keeps the open database and its passphrase', () async {
    var app = await _freshApp();
    await _sessionWithTwoEntries(app);
    var text = base64.encode(await app.exportEncryptedDatabase());
    var openBefore = app.loadedDatabase.value;

    var error = await _captureException(
        app.importEncryptedText(text, 'wrong passphrase'));
    expect(error, equals(UltracipherApp.importFailedMessage));
    expect(error.toString(), isNot(contains('alpha')));

    expect(app.loadedDatabase.value, same(openBefore));
    // The session's passphrase is unchanged: the export still uses "test".
    var exported = UltracipherApp.decryptDatabase(
        await app.exportEncryptedDatabase(),
        await app.deriveRoot(_pass));
    expect(_labelsOf(exported), equals(['alpha', 'beta']));
  });

  test('garbage bytes (too short to hold a ciphertext) fail neutrally',
      () async {
    var app = await _freshApp();
    var text = base64.encode(Uint8List.fromList([1, 2, 3]));

    var error = await _captureException(app.importEncryptedText(text, _pass));
    expect(error, equals(UltracipherApp.importFailedMessage));
    expect(app.loadedDatabase.value, isNull);
  });

  test('export without an open database fails with a plain message', () async {
    var app = await _freshApp();
    var error = await _captureException(app.exportEncryptedDatabase());
    expect(error, equals('No database open'));
  });
}
