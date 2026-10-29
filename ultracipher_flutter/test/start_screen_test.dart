// Widget-Smoke-Tests fuer den Startscreen und seine Ablaeufe (Plan Schritt 14):
// Startscreen mit und ohne lokale Datenbank, Open (richtig/falsch), New bis zum
// Oeffnen (GitHub uebersprungen), New mit vorhandener Datenbank, Import und
// die E3-Rueckfrage der GitHub-Einstellungen. Echte Verschluesselung (Format
// v1) und echte KDF je Passphrase einmal (memoized_key_derivation.dart); Netz
// nur ueber Fakes.
//
// Die Ableitung laeuft in Worker-Isolates, also in Echtzeit: Warten laeuft
// ueber tester.runAsync (pumpUntil), nie ueber pumpAndSettle (der Spinner
// zeigt eine endlose Animation).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/main.dart';
import 'package:ultracipher_flutter/src/commons.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/database_loaded.dart';
import 'package:ultracipher_flutter/src/github_settings.dart';
import 'package:ultracipher_flutter/src/login.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/progess_screen.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/view_entry.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

const _pass = 'correct horse';

UltracipherApp get _app => UltracipherApp.instance;

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  var watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 30)) {
      fail('condition not reached in time');
    }
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MyApp());
  await tester.pump();
}

/// Legt eine lokale Datenbank fuer [pass] so an, wie ein frueherer Start es
/// getan haette, und schliesst sie wieder. Danach ist nur ein `ucdb_`-Eintrag in
/// den Prefs.
Future<void> _seedLocal(WidgetTester tester, String pass,
    {List<String> labels = const [], GithubSettings? github}) async {
  await tester.runAsync(() async {
    await _app.createDatabase(pass);
    var db = _app.loadedDatabase.value!;
    for (var label in labels) {
      db.addEntry().addNewVersion(Entry(label: label));
    }
    if (github != null) {
      db.setSettings(github: github);
    }
    await _app.saveDatabase();
    _app.closeDatabase();
  });
}

final Finder _menuButton = find.byWidgetPredicate((w) => w is PopupMenuButton);

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  useMemoizedKeyDerivation();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: 'Ultracipher',
        packageName: 'test',
        version: '1.2.3',
        buildNumber: '4',
        buildSignature: '');
    await _app.init();
  });

  tearDown(() {
    progressOnWeb = false;
    _app.closeDatabase();
    _app.backendForSettings = null;
  });

  group('start screen', () {
    testWidgets('without a local database: sentence, New, Import, no field',
        (tester) async {
      await _pumpApp(tester);

      expect(
          find.text('No database on this device yet. Create a new one or '
              'import an exported one.'),
          findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'New'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Import'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('To connect a second device'),
          findsOneWidget);
    });

    testWidgets('with a local database: focused passphrase field, Open, '
        'New and Import', (tester) async {
      await _seedLocal(tester, _pass);
      await _pumpApp(tester);

      expect(find.widgetWithText(ElevatedButton, 'Open'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'New'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Import'), findsOneWidget);
      var field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autofocus, isTrue);
      expect(field.obscureText, isTrue);
      // No user name field any more.
      expect(find.text('User'), findsNothing);
    });

    testWidgets('menu has About and Erase local data', (tester) async {
      await _pumpApp(tester);
      await tester.tap(_menuButton);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('About'), findsOneWidget);
      expect(find.text('Erase local data'), findsOneWidget);
    });

    testWidgets('Open with the right passphrase opens the database',
        (tester) async {
      await _seedLocal(tester, _pass, labels: ['bank']);
      await _pumpApp(tester);

      await tester.enterText(find.byType(TextField), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Open'));
      await tester.pump();
      // The derivation runs behind the progress screen.
      expect(find.text('Deriving key...'), findsOneWidget);
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
      expect(find.text('bank'), findsOneWidget);
      expect(find.text('Deriving key...'), findsNothing);
    });

    testWidgets('a wrong passphrase gives the neutral message and leaves no '
        'trace in the prefs', (tester) async {
      await _seedLocal(tester, _pass);
      var keysBefore = _app.storage!.getKeys();
      await _pumpApp(tester);

      await tester.enterText(find.byType(TextField), 'wrong passphrase');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Open'));
      await tester.pump();
      await _pumpUntil(tester,
          () => find.text('No database found for this password').evaluate().isNotEmpty);

      expect(_app.loadedDatabase.value, isNull);
      expect(find.text('Deriving key...'), findsNothing);
      expect(_app.storage!.getKeys(), keysBefore);
    });

    testWidgets('Erase local data removes databases and key caches',
        (tester) async {
      await _seedLocal(tester, _pass);
      expect(_app.localDatabaseNames(), hasLength(1));
      await _pumpApp(tester);

      await tester.tap(_menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Erase local data'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Erase'));
      await tester.pumpAndSettle();

      expect(_app.storage!.getKeys(), isEmpty);
      // Back to the variant without a local database.
      expect(find.textContaining('No database on this device yet'),
          findsOneWidget);
    });
  });

  group('Erase local data, old-model entries', () {
    const legacy = {
      'user': 'old user',
      'github_token_abc': 'blob',
      'abcdef_database': 'old cache',
      'github_credentials_x_key': 'blob',
    };

    Future<void> eraseUntilSecondDialog(WidgetTester tester) async {
      await _seedLocal(tester, _pass);
      for (var e in legacy.entries) {
        await _app.storage!.setString(e.key, e.value);
      }
      await _pumpApp(tester);
      await tester.tap(_menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Erase local data'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not synced yet'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Erase'));
      await tester.pumpAndSettle();
      // The first step took only the current version's entries.
      expect(_app.localDatabaseNames(), isEmpty);
      expect(_app.storage!.getKeys().toSet(), legacy.keys.toSet());
      expect(find.text('Remove data of the older app version too?'),
          findsOneWidget);
    }

    testWidgets('Keep leaves them', (tester) async {
      await eraseUntilSecondDialog(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Keep'));
      await tester.pumpAndSettle();

      expect(_app.storage!.getKeys().toSet(), legacy.keys.toSet());
    });

    testWidgets('Remove clears them', (tester) async {
      await eraseUntilSecondDialog(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(_app.storage!.getKeys(), isEmpty);
    });
  });

  group('New', () {
    testWidgets('creates a database, skips GitHub and opens it',
        (tester) async {
      await _pumpApp(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'New'));
      await tester.pumpAndSettle();
      expect(find.text('New database'), findsOneWidget);

      // Create stays disabled until both fields match.
      var create = find.widgetWithText(ElevatedButton, 'Create');
      expect(tester.widget<ElevatedButton>(create).onPressed, isNull);
      await tester.enterText(_field('Passphrase'), _pass);
      await tester.enterText(_field('Confirm passphrase'), 'something else');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(create).onPressed, isNull);
      await tester.enterText(_field('Confirm passphrase'), _pass);
      await tester.pump();
      expect(tester.widget<ElevatedButton>(create).onPressed, isNotNull);

      await tester.tap(create);
      await tester.pump();
      expect(find.text('Deriving key...'), findsOneWidget);
      await _pumpUntil(
          tester, () => find.text('GitHub token').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));

      // The database is already open under the settings screen.
      expect(_app.loadedDatabase.value, isNotNull);
      expect(_app.localDatabaseNames(), hasLength(1));
      expect(find.byType(GithubSettingsScreen), findsOneWidget);
      var token = tester.widget<TextField>(_field('GitHub token'));
      expect(token.obscureText, isTrue);
      expect(tester.widget<TextField>(_field('Repository (in your account)'))
              .controller!
              .text,
          'ultracipher-data');
      expect(tester.widget<TextField>(_field('Branch')).controller!.text,
          'main');

      await tester.tap(find.widgetWithText(TextButton, 'Skip'));
      await tester.pumpAndSettle();

      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
      expect(find.byType(GithubSettingsScreen), findsNothing);
      expect(_app.syncStatus.value.state, SyncState.noRemote);
      expect(_app.loadedDatabase.value!.settings?.github, isNull);
    });

    testWidgets('an existing database is never overwritten: Open existing',
        (tester) async {
      await _seedLocal(tester, _pass, labels: ['kept']);
      await _pumpApp(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'New'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Passphrase'), _pass);
      await tester.enterText(_field('Confirm passphrase'), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pump();
      await _pumpUntil(tester,
          () => find.text('Database already exists').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));

      expect(_app.loadedDatabase.value, isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Open existing'));
      await tester.pump();
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();

      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
      expect(find.text('kept'), findsOneWidget);
      expect(find.text('New database'), findsNothing);
    });

    testWidgets('Cancel on the warning stays on the New screen',
        (tester) async {
      await _seedLocal(tester, _pass);
      await _pumpApp(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'New'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Passphrase'), _pass);
      await tester.enterText(_field('Confirm passphrase'), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pump();
      await _pumpUntil(tester,
          () => find.text('Database already exists').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();

      expect(find.text('New database'), findsOneWidget);
      expect(_app.loadedDatabase.value, isNull);
    });
  });

  group('Import', () {
    /// Encrypted export text of a database for [_pass] with one entry; the
    /// device is empty again afterwards (as on a second device).
    Future<String> exportText(WidgetTester tester) async {
      late String text;
      await tester.runAsync(() async {
        await _app.createDatabase(_pass);
        _app.loadedDatabase.value!
            .addEntry()
            .addNewVersion(Entry(label: 'imported entry'));
        await _app.saveDatabase();
        text = base64.encode(await _app.exportEncryptedDatabase());
        await _app.removeLocalDatabase();
      });
      expect(_app.storage!.getKeys(), isEmpty);
      return text;
    }

    testWidgets('imports an export and opens it', (tester) async {
      var text = await exportText(tester);
      await _pumpApp(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Import'));
      await tester.pumpAndSettle();
      expect(find.text('Import database'), findsOneWidget);
      var importButton = find.widgetWithText(ElevatedButton, 'Import');
      expect(tester.widget<ElevatedButton>(importButton).onPressed, isNull);
      await tester.enterText(_field('Encrypted database (base64)'), text);
      await tester.enterText(_field('Passphrase'), _pass);
      await tester.pump();
      await tester.tap(importButton);
      await tester.pump();
      expect(find.text('Deriving key...'), findsOneWidget);
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();

      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
      expect(find.text('imported entry'), findsOneWidget);
      expect(_app.localDatabaseNames(), hasLength(1));
      expect(find.text('Import database'), findsNothing);
    });

    testWidgets('a wrong passphrase gives the neutral import message',
        (tester) async {
      var text = await exportText(tester);
      await _pumpApp(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Import'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Encrypted database (base64)'), text);
      await tester.enterText(_field('Passphrase'), 'wrong passphrase');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Import'));
      await tester.pump();
      await _pumpUntil(
          tester,
          () => find
              .text(UltracipherApp.importFailedMessage)
              .evaluate()
              .isNotEmpty);

      expect(_app.loadedDatabase.value, isNull);
      expect(_app.storage!.getKeys(), isEmpty);
      expect(find.text('Import database'), findsOneWidget);
    });
  });

  group('Change passphrase (open database)', () {
    Future<void> openFromStart(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Open'));
      await tester.pump();
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();
    }

    Future<void> fillChangeDialog(WidgetTester tester, String next) async {
      await tester.tap(_menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change passphrase'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Old passphrase'), _pass);
      await tester.enterText(_field('New passphrase'), next);
      await tester.enterText(_field('Confirm new passphrase'), next);
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Change'));
      await tester.pump();
    }

    testWidgets('moves the database to the new passphrase behind a modal',
        (tester) async {
      await _seedLocal(tester, _pass, labels: ['bank']);
      var oldNames = _app.localDatabaseNames();
      await _pumpApp(tester);
      await openFromStart(tester);

      await fillChangeDialog(tester, 'new passphrase');
      // The whole app is blocked while the change runs.
      expect(find.text('Changing passphrase...'), findsOneWidget);
      await _pumpUntil(tester,
          () => find.text('Changing passphrase...').evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('bank'), findsOneWidget);
      expect(_app.localDatabaseNames(), hasLength(1));
      expect(_app.localDatabaseNames(), isNot(oldNames));
    });

    testWidgets('the whole app is blocked while the change runs',
        (tester) async {
      await _seedLocal(tester, _pass, labels: ['bank']);
      await _pumpApp(tester);
      await openFromStart(tester);

      await fillChangeDialog(tester, 'new passphrase');
      // No real-async progress happens between here and the taps below, so the
      // change is still running.
      expect(find.text('Changing passphrase...'), findsOneWidget);

      // Taps reach the barrier, not the FAB or the exit button.
      await tester.tap(find.byType(FloatingActionButton),
          warnIfMissed: false);
      await tester.tap(find.byIcon(Icons.exit_to_app), warnIfMissed: false);
      await tester.pump();
      expect(find.byType(EntryViewScreen), findsNothing);
      expect(_app.loadedDatabase.value, isNotNull);
      // The back button does not dismiss the modal either.
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Changing passphrase...'), findsOneWidget);

      await _pumpUntil(tester,
          () => find.text('Changing passphrase...').evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
      expect(_app.loadedDatabase.value, isNotNull);
    });

    testWidgets('an existing database for the new passphrase asks, then merges',
        (tester) async {
      await _seedLocal(tester, _pass, labels: ['mine']);
      await _seedLocal(tester, 'other passphrase', labels: ['theirs']);
      await _pumpApp(tester);
      await openFromStart(tester);

      await fillChangeDialog(tester, 'other passphrase');
      await _pumpUntil(tester,
          () => find.text('Database already exists').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(_app.localDatabaseNames(), hasLength(2));

      await tester.tap(find.widgetWithText(TextButton, 'Merge'));
      await tester.pump();
      await _pumpUntil(tester,
          () => find.text('Changing passphrase...').evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(_app.localDatabaseNames(), hasLength(1));
      expect(find.text('mine'), findsOneWidget);
      expect(find.text('theirs'), findsOneWidget);
    });
  });

  group('GitHub settings', () {
    final github = GithubSettings(
        token: 'old-token', owner: 'me', repo: 'ultracipher-data', branch: 'main');

    testWidgets('a missing file asks first (E3); Create on GitHub writes it',
        (tester) async {
      var remote = FakeRemoteBackend();
      _app.backendForSettings = (settings, key) => settings == null ? null : remote;
      await _seedLocal(tester, _pass, github: github);
      await _pumpApp(tester);
      await tester.enterText(find.byType(TextField), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Open'));
      await tester.pump();
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await _pumpUntil(tester,
          () => _app.syncStatus.value.state == SyncState.remoteMissing);
      await tester.pump(const Duration(milliseconds: 300));

      var client = MockClient((request) async {
        expect(request.url.path, '/user');
        return http.Response('{"login":"me"}', 200);
      });
      Navigator.of(tester.element(find.byType(DatabaseLoadedScreen))).push(
          MaterialPageRoute<bool>(
              builder: (_) => GithubSettingsScreen(httpClient: client)));
      await tester.pumpAndSettle();
      // Reconfiguration: the screen shows the existing repository and offers
      // removal; the first-time hint is gone.
      expect(find.text('Remove GitHub'), findsOneWidget);
      expect(find.textContaining('brings the old database back'),
          findsNothing);

      await tester.enterText(_field('GitHub token'), 'new-token');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      await _pumpUntil(tester,
          () => find.text('No database file on GitHub').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      // Both ways out are named.
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('Change passphrase')),
          findsOneWidget);
      expect(find.textContaining('brings the old database back'),
          findsOneWidget);
      expect(remote.committedWrites, 0);

      // Cancel changes nothing and keeps the screen.
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(GithubSettingsScreen), findsOneWidget);
      expect(remote.committedWrites, 0);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      await _pumpUntil(tester,
          () => find.text('No database file on GitHub').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(TextButton, 'Create on GitHub'));
      await tester.pump();
      await _pumpUntil(
          tester, () => find.byType(GithubSettingsScreen).evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(remote.committedWrites, greaterThan(0));
      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
    });
  });

  group('old local copies (not v1)', () {
    // A v2 copy starts with 0x00 instead of the v1 magic "UCDB".
    final v2Copy = base64.encode([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    final legacyKey = UltracipherApp.localPrefsKey('oldname');

    testWidgets('only old copies: no-database variant plus hint, no Open',
        (tester) async {
      await _app.storage!.setString(legacyKey, v2Copy);
      await _pumpApp(tester);

      expect(find.textContaining('No database on this device yet'),
          findsOneWidget);
      expect(find.byKey(const Key('legacyDataHint')), findsOneWidget);
      expect(find.text(legacyDataHint), findsOneWidget);
      expect(find.textContaining('Export a CSV'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Open'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'New'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Import'), findsOneWidget);
    });

    testWidgets('without any old copy there is no hint', (tester) async {
      await _pumpApp(tester);
      expect(find.byKey(const Key('legacyDataHint')), findsNothing);
    });

    testWidgets('other leftovers (user, token blobs) get no hint, but Erase '
        'still offers them', (tester) async {
      await _app.storage!.setString('user', 'old user');
      await _app.storage!.setString('github_token_abc', 'blob');
      await _pumpApp(tester);

      expect(find.textContaining('No database on this device yet'),
          findsOneWidget);
      expect(find.byKey(const Key('legacyDataHint')), findsNothing);
      expect(_app.hasLegacyLocalData, isTrue);
      expect(_app.hasLegacyLocalCopies, isFalse);
    });

    testWidgets('a v1 database next to an old copy: Open form, old copy '
        'ignored', (tester) async {
      await _seedLocal(tester, _pass);
      await _app.storage!.setString(legacyKey, v2Copy);
      await _pumpApp(tester);

      expect(find.widgetWithText(ElevatedButton, 'Open'), findsOneWidget);
      expect(find.byKey(const Key('legacyDataHint')), findsNothing);
      expect(_app.localDatabaseNames(), hasLength(1));
    });

    testWidgets('Erase local data offers the old copies and removes them',
        (tester) async {
      await _seedLocal(tester, _pass);
      await _app.storage!.setString(legacyKey, v2Copy);
      await _pumpApp(tester);

      await tester.tap(_menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Erase local data'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Erase'));
      await tester.pumpAndSettle();

      // The v1 database is gone, the old copy is still there and offered.
      expect(_app.localDatabaseNames(), isEmpty);
      expect(_app.storage!.getKeys(), {legacyKey});
      expect(find.text('Remove data of the older app version too?'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(_app.storage!.getKeys(), isEmpty);
      expect(find.byKey(const Key('legacyDataHint')), findsNothing);
    });
  });

  group('web hint on the key-derivation progress screen', () {
    Future<void> startOpen(WidgetTester tester) async {
      await _seedLocal(tester, _pass);
      await _pumpApp(tester);
      await tester.enterText(find.byType(TextField), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Open'));
      await tester.pump();
      expect(find.text('Deriving key...'), findsOneWidget);
    }

    testWidgets('on the web it names the wait and the frozen page',
        (tester) async {
      progressOnWeb = true;
      await startOpen(tester);
      expect(find.textContaining('10-20 seconds'), findsOneWidget);
      expect(find.textContaining('may not respond'), findsOneWidget);
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();
    });

    testWidgets('natively there is no hint', (tester) async {
      progressOnWeb = false;
      await startOpen(tester);
      expect(find.textContaining('seconds'), findsNothing);
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();
    });

    // Every derivation site passes the hint: create, open existing, import,
    // change passphrase.
    testWidgets('create and open-existing show the hint', (tester) async {
      progressOnWeb = true;
      await _seedLocal(tester, _pass);
      await _pumpApp(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'New'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Passphrase'), _pass);
      await tester.enterText(_field('Confirm passphrase'), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pump();
      expect(find.text('Deriving key...'), findsOneWidget);
      expect(find.textContaining('10-20 seconds'), findsOneWidget);
      await _pumpUntil(tester,
          () => find.text('Database already exists').evaluate().isNotEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Open existing'));
      await tester.pump();
      expect(find.text('Deriving key...'), findsOneWidget);
      expect(find.textContaining('10-20 seconds'), findsOneWidget);
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();
    });

    testWidgets('import shows the hint', (tester) async {
      late String text;
      await tester.runAsync(() async {
        await _app.createDatabase(_pass);
        text = base64.encode(await _app.exportEncryptedDatabase());
        await _app.removeLocalDatabase();
      });
      progressOnWeb = true;
      await _pumpApp(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Import'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Encrypted database (base64)'), text);
      await tester.enterText(_field('Passphrase'), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Import'));
      await tester.pump();
      expect(find.text('Deriving key...'), findsOneWidget);
      expect(find.textContaining('10-20 seconds'), findsOneWidget);
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();
    });

    testWidgets('change passphrase shows the doubled hint', (tester) async {
      await _seedLocal(tester, _pass);
      await _pumpApp(tester);
      await tester.enterText(find.byType(TextField), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Open'));
      await tester.pump();
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();
      progressOnWeb = true;
      await tester.tap(_menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change passphrase'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Old passphrase'), _pass);
      await tester.enterText(_field('New passphrase'), 'new passphrase');
      await tester.enterText(_field('Confirm new passphrase'), 'new passphrase');
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Change'));
      await tester.pump();
      expect(find.text('Changing passphrase...'), findsOneWidget);
      expect(find.textContaining('20-40 seconds'), findsOneWidget);
      await _pumpUntil(tester,
          () => find.text('Changing passphrase...').evaluate().isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('on the web the operation starts only after the progress '
        'screen was drawn (the derivation blocks the page)', (tester) async {
      progressOnWeb = true;
      var started = false;
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
          home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })));
      var done = runWithProgress<void>(context, () async {
        started = true;
      }, title: 'Deriving key...', hint: derivationHint());
      // Route pushed, but not drawn yet: nothing may have started.
      expect(started, isFalse);
      await tester.pump();
      expect(find.text('Deriving key...'), findsOneWidget);
      expect(find.textContaining('10-20 seconds'), findsOneWidget);
      expect(started, isFalse, reason: 'still waiting for the browser paint');
      await tester.pump(const Duration(milliseconds: 100));
      await done;
      expect(started, isTrue);
      await tester.pump();
      expect(find.text('Deriving key...'), findsNothing);
    });

    testWidgets('natively the operation starts at once', (tester) async {
      progressOnWeb = false;
      var started = false;
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
          home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })));
      var done = runWithProgress<void>(context, () async {
        started = true;
      });
      expect(started, isTrue);
      await done;
    });

    test('derivationHint scales with the number of derivations', () {
      progressOnWeb = false;
      expect(derivationHint(), isNull);
      progressOnWeb = true;
      expect(derivationHint(), contains('10-20 seconds'));
      expect(derivationHint(derivations: 2), contains('20-40 seconds'));
    });
  });

  group('non-ASCII passphrase warning', () {
    const umlaut = 'gr\u00fc\u00dfe dich';
    final Finder dialog = find.byType(AlertDialog);
    final Finder warning = find.text('Non-ASCII characters in the passphrase');

    Future<void> fillNew(WidgetTester tester, String pass) async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'New'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Passphrase'), pass);
      await tester.enterText(_field('Confirm passphrase'), pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();
    }

    testWidgets('New: Cancel creates nothing and stays on the screen',
        (tester) async {
      await _pumpApp(tester);
      await fillNew(tester, umlaut);

      expect(warning, findsOneWidget);
      expect(find.textContaining('Unicode normalisation'), findsOneWidget);
      await tester.tap(
          find.descendant(of: dialog, matching: find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(warning, findsNothing);
      expect(find.text('New database'), findsOneWidget);
      expect(_app.loadedDatabase.value, isNull);
      expect(_app.storage!.getKeys(), isEmpty);
    });

    testWidgets('New: Continue creates the database', (tester) async {
      await _pumpApp(tester);
      await fillNew(tester, umlaut);

      expect(warning, findsOneWidget);
      await tester.tap(
          find.descendant(of: dialog, matching: find.text('Continue')));
      await tester.pump();
      await _pumpUntil(
          tester, () => find.text('GitHub token').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));

      expect(_app.loadedDatabase.value, isNotNull);
      expect(_app.localDatabaseNames(), hasLength(1));
    });

    testWidgets('New: an ASCII passphrase asks nothing', (tester) async {
      await _pumpApp(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'New'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Passphrase'), _pass);
      await tester.enterText(_field('Confirm passphrase'), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pump();

      expect(warning, findsNothing);
      expect(find.text('Deriving key...'), findsOneWidget);
      await _pumpUntil(
          tester, () => find.text('GitHub token').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
    });

    Future<void> changeTo(WidgetTester tester, String next) async {
      await _seedLocal(tester, _pass, labels: ['bank']);
      await _pumpApp(tester);
      await tester.enterText(find.byType(TextField), _pass);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Open'));
      await tester.pump();
      await _pumpUntil(tester, () => _app.loadedDatabase.value != null);
      await tester.pumpAndSettle();
      await tester.tap(_menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change passphrase'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Old passphrase'), _pass);
      await tester.enterText(_field('New passphrase'), next);
      await tester.enterText(_field('Confirm new passphrase'), next);
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Change'));
      await tester.pumpAndSettle();
    }

    testWidgets('Change passphrase: Cancel keeps the old passphrase',
        (tester) async {
      await changeTo(tester, umlaut);

      expect(warning, findsOneWidget);
      var oldNames = _app.localDatabaseNames();
      await tester.tap(
          find.descendant(of: dialog, matching: find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(warning, findsNothing);
      expect(_app.localDatabaseNames(), oldNames);
      // The change dialog is still open for another try.
      expect(_field('New passphrase'), findsOneWidget);
    });

    testWidgets('Change passphrase: Continue changes it', (tester) async {
      await changeTo(tester, umlaut);
      var oldNames = _app.localDatabaseNames();

      expect(warning, findsOneWidget);
      await tester.tap(
          find.descendant(of: dialog, matching: find.text('Continue')));
      await tester.pump();
      await _pumpUntil(
          tester,
          () =>
              !_app.localDatabaseNames().contains(oldNames.single) &&
              find.text('Changing passphrase...').evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(_app.localDatabaseNames(), hasLength(1));
      expect(_app.localDatabaseNames(), isNot(oldNames));
      expect(find.text('bank'), findsOneWidget);
    });

    test('hasNonAscii', () {
      expect(hasNonAscii('plain ASCII 123 !~'), isFalse);
      expect(hasNonAscii(umlaut), isTrue);
      expect(hasNonAscii('caf\u00e9'), isTrue);
      expect(hasNonAscii(''), isFalse);
    });
  });
}
