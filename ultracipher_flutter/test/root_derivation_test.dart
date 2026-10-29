// Wo die App die teure KDF laeuft (Spezifikation §10, Entscheidung E6): nur
// beim Oeffnen, Anlegen, Text-Import, Entfernen mit Passphrase und beim
// Passwortwechsel (je eine fuer das alte und das neue Passwort). Speichern,
// Sync, Export, GitHub einrichten/entfernen und Entfernen der offenen
// Datenbank leiten nur noch billige Dateischluessel aus `R` der Sitzung ab.
// Gezaehlt wird an der Testnaht `rootDerivation` (memoized_key_derivation.dart).
//
// Der Test sieht den Pruefweg, nicht ein privates Feld: haelte die Sitzung
// die Passphrase und leitete bei jedem Schritt neu ab, waeren die Zaehler > 0.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/db_codec.dart' show maxBase64Length;
import 'package:ultracipher_flutter/src/model/model.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

const _pass = 'passphrase A';
const _passB = 'passphrase B';

Future<UltracipherApp> _freshApp() async {
  SharedPreferences.setMockInitialValues({});
  var app = UltracipherApp();
  await app.init();
  return app;
}

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('open, create and import derive once each', () async {
    var app = await _freshApp();
    resetRootDerivationCount();
    await app.createDatabase(_pass);
    expect(rootDerivationCount, 1);

    var text = base64.encode(await app.exportEncryptedDatabase());
    app.closeDatabase();

    resetRootDerivationCount();
    await app.openLocalDatabase(_pass);
    expect(rootDerivationCount, 1);

    app.closeDatabase();
    resetRootDerivationCount();
    await app.importEncryptedText(text, _pass);
    expect(rootDerivationCount, 1);
  });

  test('an import text beyond twice the base64 limit is refused at once, '
      'without stripping, decoding or deriving', () async {
    var app = await _freshApp();
    resetRootDerivationCount();

    var error = await app
        .importEncryptedText('A' * (2 * maxBase64Length + 1), _pass)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, UltracipherApp.importFailedMessage);
    expect(rootDerivationCount, 0);
    expect(app.loadedDatabase.value, isNull);
  });

  test('save, sync, export, GitHub setup and removal derive nothing',
      () async {
    var app = await _freshApp();
    var remote = FakeRemoteBackend();
    app.backendForSettings = (github, key) => github == null ? null : remote;
    await app.createDatabase(_pass);
    resetRootDerivationCount();

    app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
    await app.saveDatabase();
    await app.syncNow();
    await app.exportEncryptedDatabase();
    await app.configureGithub(
        token: 't',
        repo: 'r',
        branch: 'main',
        httpClient: MockClient(
            (_) async => http.Response(jsonEncode({'login': 'o'}), 200)));
    app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'y'));
    await app.saveDatabase();
    await app.syncNow();
    await app.removeGithub();
    await app.removeLocalDatabase();

    expect(rootDerivationCount, 0);
  });

  test('the passphrase change derives exactly twice (old check and new)',
      () async {
    var app = await _freshApp();
    await app.createDatabase(_pass);
    resetRootDerivationCount();

    await app.changeDatabasePassphrase(
        oldPassphrase: _pass, newPassphrase: _passB);

    expect(rootDerivationCount, 2);
    // The session runs under the new R: saving needs no further derivation.
    app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
    await app.saveDatabase();
    expect(rootDerivationCount, 2);
  });

  test('a wrong old passphrase is found by deriving it and comparing with R; '
      'nothing else is derived or changed', () async {
    var app = await _freshApp();
    await app.createDatabase(_pass);
    var before = {for (var k in app.storage!.getKeys()) k: app.storage!.get(k)};
    resetRootDerivationCount();

    expect(
        await app
            .changeDatabasePassphrase(oldPassphrase: 'nope', newPassphrase: _passB)
            .then<Object?>((_) => null, onError: (Object e) => e),
        'Invalid old passphrase');

    expect(rootDerivationCount, 1);
    expect({for (var k in app.storage!.getKeys()) k: app.storage!.get(k)},
        before);
  });

  test('the same passphrase as the new one is refused', () async {
    var app = await _freshApp();
    await app.createDatabase(_pass);

    expect(
        await app
            .changeDatabasePassphrase(
                oldPassphrase: _pass, newPassphrase: ' $_pass ')
            .then<Object?>((_) => null, onError: (Object e) => e),
        'The new passphrase is the same as the old one');
  });

  test('removing with a passphrase derives once', () async {
    var app = await _freshApp();
    await app.createDatabase(_pass);
    app.closeDatabase();
    resetRootDerivationCount();

    expect(await app.removeLocalDatabase(passphrase: _pass), isTrue);

    expect(rootDerivationCount, 1);
  });
}
