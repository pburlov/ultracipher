// Widget-Tests fuer die UI der geoeffneten Datenbank (Plan Schritt 15):
// Status-Symbol je SyncState, Menue, "Sync now", Entfernen und Schliessen mit
// den Hinweisen aus §3.3, SnackBar bei authRequired/remoteMissing,
// Aktualisierung der Liste nach einem Merge, Resume-Trigger, M-f-Rueckfrage
// der GitHub-Einstellungen, kein Netzdialog beim Speichern.
//
// Netz nur ueber FakeRemoteBackend (backendForSettings). Die Ableitung laeuft
// in Worker-Isolates (Echtzeit): Warten ueber tester.runAsync (_pumpUntil),
// nie pumpAndSettle bei laufendem Fortschrittsdialog.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/main.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/database_loaded.dart';
import 'package:ultracipher_flutter/src/github_settings.dart';
import 'package:ultracipher_flutter/src/login.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/sync_status_button.dart';
import 'package:ultracipher_flutter/src/view_entry.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

const _pass = 'correct horse';

final _github = GithubSettings(
    token: 'tok', owner: 'me', repo: 'ultracipher-data', branch: 'main');

UltracipherApp get _app => UltracipherApp.instance;

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  var watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 30)) {
      fail('condition not reached in time');
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
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

/// Legt die Datenbank zu [_pass] lokal an (mit [labels] und, wenn [remote]
/// gesetzt ist, GitHub-Einstellungen; der Remote hat dann schon den Stand),
/// schliesst sie und gibt den Zustand fuer einen frischen Start frei.
Future<void> _seed(WidgetTester tester,
    {List<String> labels = const [],
    FakeRemoteBackend? remote,
    bool seedRemote = true}) async {
  await tester.runAsync(() async {
    await _app.createDatabase(_pass);
    var db = _app.loadedDatabase.value!;
    for (var label in labels) {
      db.addEntry().addNewVersion(Entry(label: label));
    }
    if (remote != null) {
      db.setSettings(github: _github);
    }
    await _app.saveDatabase();
    if (remote != null && seedRemote) {
      var key = await _app.deriveRoot(_pass);
      remote.seed(UltracipherApp.encryptDatabase(db, key));
    }
    _app.closeDatabase();
  });
}

/// App starten und die Datenbank oeffnen (Screen steht vor dem ersten Sync).
Future<void> _open(WidgetTester tester) async {
  await _pumpApp(tester);
  await tester.runAsync(() => _app.openLocalDatabase(_pass));
  await tester.pump();
  expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
}

Future<void> _openAndSync(WidgetTester tester) async {
  await _open(tester);
  await _pumpUntil(tester, () => _app.syncStatus.value.state == SyncState.synced);
}

/// SharedPreferences, deren Schreiben auf Wunsch scheitert.
class _FailingPrefs extends Fake implements SharedPreferences {
  final SharedPreferences inner;
  bool failWrites = false;

  _FailingPrefs(this.inner);

  @override
  String? getString(String key) => inner.getString(key);

  @override
  Future<bool> setString(String key, String value) => failWrites
      ? Future<bool>.error(StateError('disk full'))
      : inner.setString(key, value);

  @override
  bool containsKey(String key) => inner.containsKey(key);

  @override
  Set<String> getKeys() => inner.getKeys();

  @override
  Object? get(String key) => inner.get(key);

  @override
  Future<bool> remove(String key) => inner.remove(key);
}

final Finder _menuButton = find.byWidgetPredicate((w) => w is PopupMenuButton);
final Finder _syncButton = find.byKey(const Key('syncStatusButton'));

Future<void> _menu(WidgetTester tester, String item) async {
  await tester.tap(_menuButton);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pump();
}

Finder _inDialog(Finder f) =>
    find.descendant(of: find.byType(AlertDialog), matching: f);

void main() {
  useMemoizedKeyDerivation();

  late FakeRemoteBackend remote;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: 'Ultracipher',
        packageName: 'test',
        version: '1.2.3',
        buildNumber: '4',
        buildSignature: '');
    await _app.init();
    remote = FakeRemoteBackend();
    _app.backendForSettings = (s, key) => s == null ? null : remote;
    DatabaseLoadedScreen.syncAttemptTimeout = const Duration(seconds: 40);
  });

  tearDown(() {
    _app.closeDatabase();
    _app.backendForSettings = null;
  });

  group('sync status icon', () {
    testWidgets('one distinct icon per state', (tester) async {
      await _seed(tester);
      await _open(tester);

      var icons = <IconData>{};
      for (var state in SyncState.values) {
        _app.syncStatus.value = SyncStatus(state);
        await tester.pump();
        var icon = tester.widget<Icon>(
            find.descendant(of: _syncButton, matching: find.byType(Icon)));
        expect(icon.icon, syncStateIcon(state), reason: '$state');
        icons.add(icon.icon!);
      }
      expect(icons, hasLength(SyncState.values.length));
    });

    testWidgets('tooltip carries the state text, error and retry time',
        (tester) async {
      await _seed(tester);
      await _open(tester);

      String tooltip() => tester.widget<IconButton>(_syncButton).tooltip!;

      _app.syncStatus.value = SyncStatus.noRemote;
      await tester.pump();
      expect(tooltip(), contains('Only stored on this device'));
      expect(tooltip(), contains('Tap to sync now'));

      _app.syncStatus.value = SyncStatus(SyncState.notSynced,
          error: 'Rate limit reached', retryAfter: const Duration(seconds: 90));
      await tester.pump();
      expect(tooltip(), contains('Rate limit reached'));
      expect(tooltip(), contains('90 s'));

      // Core promises that SyncStatus.error never carries a token or URL; the
      // UI shows it as given.
      _app.syncStatus.value = SyncStatus(SyncState.notSynced, error: 'Boom');
      await tester.pump();
      expect(tooltip(), contains('Not synced: Boom'));
    });

    testWidgets('tapping syncs in every state', (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      var reads = remote.readCount;

      await tester.tap(_syncButton);
      await tester.pump();
      await _pumpUntil(tester, () => remote.readCount > reads);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.synced);

      // Also from a failure state: "Sync now" always asks.
      remote.readFailure = RemoteBackendException('down');
      reads = remote.readCount;
      await tester.tap(_syncButton);
      await tester.pump();
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.notSynced);
      expect(remote.readCount, greaterThan(reads));
      remote.readFailure = null;
      reads = remote.readCount;
      await tester.tap(_syncButton);
      await tester.pump();
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.synced);
      expect(remote.readCount, greaterThan(reads));
    });

    testWidgets('tapping without a remote says so', (tester) async {
      await _seed(tester);
      await _open(tester);
      expect(_app.syncStatus.value.state, SyncState.noRemote);

      await tester.tap(_syncButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('only stored on this device'),
          findsOneWidget);
    });
  });

  group('focus and dialog spacing', () {
    // Das Suchfeld ist das einzige Feld "Search" im Hauptfenster.
    final searchField = find.widgetWithText(TextField, 'Search');

    /// Das TextField, dessen Editor gerade den Fokus hat (oder null).
    TextField? focusedTextField() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<TextField>();

    testWidgets('desktop: the search field has focus after opening',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await _seed(tester, labels: ['bank']);
        await _open(tester);
        await tester.pump();

        expect(focusedTextField(), isNotNull);
        expect(focusedTextField()!.controller,
            tester.widget<TextField>(searchField).controller);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('android: the search field does not take the focus',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await _seed(tester, labels: ['bank']);
        await _open(tester);
        await tester.pump();

        expect(focusedTextField(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'Change passphrase: the top field keeps its distance from '
        'the dialog edge', (tester) async {
      await _seed(tester);
      await _open(tester);
      await _menu(tester, 'Change passphrase');
      await tester.pumpAndSettle();

      // Das Dialog-Widget selbst fuellt den Bildschirm; der sichtbare Rand
      // (mit den runden Ecken) ist sein Material.
      var dialog = tester.getRect(find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first);
      var oldField =
          tester.getRect(find.widgetWithText(TextField, 'Old passphrase'));
      var confirm = tester
          .getRect(find.widgetWithText(TextField, 'Confirm new passphrase'));
      var button =
          tester.getRect(find.widgetWithText(OutlinedButton, 'Change'));
      expect(oldField.top - dialog.top, greaterThanOrEqualTo(16));
      expect(oldField.left - dialog.left, greaterThanOrEqualTo(16));
      expect(dialog.right - oldField.right, greaterThanOrEqualTo(16));
      expect(dialog.bottom - button.bottom, greaterThanOrEqualTo(16));
      expect(confirm.top, greaterThan(oldField.bottom));
    });
  });

  group('entry edit focus', () {
    /// Das TextField (nach Beschriftung), dessen Editor gerade den Fokus hat.
    String? focusedLabel() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<TextField>()
        ?.decoration
        ?.labelText;

    testWidgets('Edit button puts the cursor into Label', (tester) async {
      await _seed(tester, labels: ['bank']);
      await _open(tester);
      await tester.tap(find.text('bank'));
      await tester.pumpAndSettle();
      expect(focusedLabel(), isNull);

      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();
      expect(focusedLabel(), 'Label');
    });

    testWidgets('a new entry starts with the cursor in Label (also on mobile)',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await _seed(tester);
        await _open(tester);
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        expect(find.byType(EntryViewScreen), findsOneWidget);
        expect(focusedLabel(), 'Label');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('menu', () {
    testWidgets('has all entries of the plan', (tester) async {
      await _seed(tester);
      await _open(tester);
      await tester.tap(_menuButton);
      await tester.pumpAndSettle();

      for (var item in [
        'Export CSV',
        'Import CSV',
        'Export encrypted (base64)',
        'Change passphrase',
        'GitHub settings',
        'Sync now',
        'Remove local database',
      ]) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
    });

    testWidgets('Sync now syncs', (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      var reads = remote.readCount;
      await _menu(tester, 'Sync now');
      await _pumpUntil(tester, () => remote.readCount > reads);
    });

    testWidgets('GitHub settings opens the settings screen', (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      await _menu(tester, 'GitHub settings');
      await tester.pumpAndSettle();
      expect(find.byType(GithubSettingsScreen), findsOneWidget);
      expect(find.text('Remove GitHub'), findsOneWidget);
    });

    testWidgets('Import CSV warns about deletions made elsewhere (S2)',
        (tester) async {
      await _seed(tester);
      await _open(tester);
      await _menu(tester, 'Import CSV');
      await tester.pumpAndSettle();
      expect(_inDialog(find.textContaining('may stay deleted')),
          findsOneWidget);
      expect(_inDialog(find.textContaining('"Sync now" first')),
          findsOneWidget);
    });

    testWidgets('the encrypted export warns about the included token',
        (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      await _menu(tester, 'Export encrypted (base64)');
      await _pumpUntil(
          tester, () => find.text('Encrypted text').evaluate().isNotEmpty);
      expect(find.textContaining('includes the GitHub access token'),
          findsOneWidget);
    });
  });

  group('Remove local database', () {
    testWidgets('synced: says it stays on GitHub; Remove deletes the copy',
        (tester) async {
      await _seed(tester, remote: remote, labels: ['bank']);
      await _openAndSync(tester);
      await _menu(tester, 'Remove local database');
      await tester.pumpAndSettle();
      expect(_inDialog(find.textContaining('stays on GitHub')),
          findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pump();
      // The screen is replaced as soon as the session ends; the prefs are
      // cleaned right after.
      await _pumpUntil(
          tester,
          () =>
              find.byType(LoginScreen).evaluate().isNotEmpty &&
              _app.localDatabaseNames().isEmpty);
      expect(_app.loadedDatabase.value, isNull);
      // The remote file is untouched.
      expect(remote.storedBytes, isNotNull);
    });

    testWidgets('Cancel keeps the database', (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      await _menu(tester, 'Remove local database');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(_app.loadedDatabase.value, isNotNull);
      expect(_app.localDatabaseNames(), hasLength(1));
    });

    testWidgets('no remote: only copy', (tester) async {
      await _seed(tester);
      await _open(tester);
      await _menu(tester, 'Remove local database');
      await tester.pumpAndSettle();
      expect(_inDialog(find.textContaining('only copy')), findsOneWidget);
      expect(_inDialog(find.textContaining('only on this device')),
          findsOneWidget);
    });

    testWidgets('unsynced changes after a sync: says so', (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      remote.readFailure = RemoteBackendException('down');
      _app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
      await tester.runAsync(() => _app.saveDatabase());
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.notSynced &&
              _app.syncStatus.value.error != null);
      var reads = remote.readCount;

      await _menu(tester, 'Remove local database');
      await tester.pumpAndSettle();
      // A sync already completed in this session: no new attempt first.
      expect(remote.readCount, reads);
      expect(_inDialog(find.textContaining('unsynced changes')),
          findsOneWidget);
      expect(_inDialog(find.textContaining('down')), findsOneWidget);
    });

    testWidgets('GitHub configured from inside counts as synced before',
        (tester) async {
      await _seed(tester);
      await _open(tester);
      var client = MockClient(
          (_) async => http.Response('{"login":"me"}', 200));
      await tester.runAsync(() => _app.configureGithub(
          token: 'tok', repo: 'ultracipher-data', httpClient: client));
      expect(_app.syncStatus.value.state, SyncState.synced);

      remote.readFailure = RemoteBackendException('down');
      _app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
      await tester.runAsync(() => _app.saveDatabase());
      await _pumpUntil(
          tester, () => _app.syncStatus.value.error != null);
      var reads = remote.readCount;

      await _menu(tester, 'Remove local database');
      await tester.pumpAndSettle();
      expect(remote.readCount, reads);
      expect(_inDialog(find.textContaining('unsynced changes')),
          findsOneWidget);
    });

    testWidgets('no sync completed yet: tries one, then says status unknown',
        (tester) async {
      await _seed(tester, remote: remote);
      remote.readFailure = RemoteBackendException('down');
      await _open(tester);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.notSynced);
      expect(_app.hasSyncedThisSession, isFalse);
      var reads = remote.readCount;

      await _menu(tester, 'Remove local database');
      await _pumpUntil(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(remote.readCount, greaterThan(reads));
      expect(_inDialog(find.textContaining('Sync status unknown')),
          findsOneWidget);
    });

    testWidgets('no sync completed yet: a successful try shows "synced"',
        (tester) async {
      await _seed(tester, remote: remote);
      var gate = Completer<void>();
      remote.readGate = gate;
      await _open(tester);
      // The first sync hangs at the read.
      await tester.pump();
      expect(_app.hasSyncedThisSession, isFalse);

      await _menu(tester, 'Remove local database');
      await tester.pump();
      expect(find.text('Syncing...'), findsWidgets);
      gate.complete();
      await _pumpUntil(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(_inDialog(find.textContaining('stays on GitHub')),
          findsOneWidget);
    });

    testWidgets('a hanging sync attempt ends at the timeout', (tester) async {
      await _seed(tester, remote: remote);
      DatabaseLoadedScreen.syncAttemptTimeout =
          const Duration(milliseconds: 300);
      remote.readGate = Completer<void>();
      await _open(tester);

      await _menu(tester, 'Remove local database');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(_inDialog(find.textContaining('Sync status unknown')),
          findsOneWidget);
    });
  });

  group('close', () {
    Future<void> tapClose(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.exit_to_app));
      await tester.pump();
    }

    testWidgets('synced: closes without asking', (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      await tapClose(tester);
      await tester.pumpAndSettle();
      expect(_app.loadedDatabase.value, isNull);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('no remote: closes without asking', (tester) async {
      await _seed(tester);
      await _open(tester);
      await tapClose(tester);
      await tester.pumpAndSettle();
      expect(_app.loadedDatabase.value, isNull);
    });

    testWidgets('unsynced changes: asks; Cancel stays, Close closes',
        (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      remote.readFailure = RemoteBackendException('down');
      _app.loadedDatabase.value!.addEntry().addNewVersion(Entry(label: 'x'));
      await tester.runAsync(() => _app.saveDatabase());
      await _pumpUntil(
          tester, () => _app.syncStatus.value.error != null);

      await tapClose(tester);
      await tester.pumpAndSettle();
      expect(
          _inDialog(find.textContaining(
              'Changes stay on this device and sync next time.')),
          findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(_app.loadedDatabase.value, isNotNull);

      await tapClose(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(_app.loadedDatabase.value, isNull);
      // The change is kept locally.
      expect(_app.localDatabaseNames(), hasLength(1));
    });

    testWidgets('no sync completed yet: a successful try closes without asking',
        (tester) async {
      await _seed(tester, remote: remote);
      var gate = Completer<void>();
      remote.readGate = gate;
      await _open(tester);
      await tester.pump();
      expect(_app.hasSyncedThisSession, isFalse);

      await tapClose(tester);
      expect(find.text('Syncing...'), findsWidgets);
      gate.complete();
      await _pumpUntil(tester, () => _app.loadedDatabase.value == null);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('no sync completed yet and it fails: status unknown',
        (tester) async {
      await _seed(tester, remote: remote);
      remote.readFailure = RemoteBackendException('down');
      await _open(tester);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.notSynced);

      await tapClose(tester);
      await _pumpUntil(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(_inDialog(find.textContaining('Sync status unknown')),
          findsOneWidget);
      expect(_inDialog(find.textContaining('sync next time')),
          findsOneWidget);
    });
  });

  group('SnackBar on sync problems', () {
    testWidgets('authRequired: names GitHub settings and opens them',
        (tester) async {
      await _seed(tester, remote: remote);
      remote.readFailure = RemoteAuthException('bad token', statusCode: 401);
      await _open(tester);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.authRequired);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('rejected the access token'),
          findsOneWidget);
      // Let the SnackBar slide in before tapping its action.
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.widgetWithText(SnackBarAction, 'GitHub settings'));
      await tester.pumpAndSettle();
      expect(find.byType(GithubSettingsScreen), findsOneWidget);
    });

    testWidgets('remoteMissing: also names Change passphrase',
        (tester) async {
      await _seed(tester, remote: remote, seedRemote: false);
      await _open(tester);
      await _pumpUntil(tester,
          () => _app.syncStatus.value.state == SyncState.remoteMissing);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('no longer found on GitHub'),
          findsOneWidget);
      expect(find.textContaining('Change passphrase'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'GitHub settings'),
          findsOneWidget);
    });

    testWidgets('shown once per problem, not again after each sync run',
        (tester) async {
      await _seed(tester, remote: remote);
      remote.readFailure = RemoteAuthException('bad token', statusCode: 401);
      await _open(tester);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.authRequired);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnackBar), findsOneWidget);

      // The user dismisses it; the next sync fails the same way (through
      // `syncing` in between): it stays away.
      ScaffoldMessenger.of(tester.element(find.byType(DatabaseLoadedScreen)))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      var reads = remote.readCount;
      await tester.tap(_syncButton);
      await tester.pump();
      await _pumpUntil(tester, () => remote.readCount > reads);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.authRequired);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsNothing);

      // A different problem is shown, and so is the same one after the state
      // left the error states.
      remote.readFailure = null;
      await tester.tap(_syncButton);
      await tester.pump();
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.synced);
      remote.readFailure = RemoteAuthException('bad token', statusCode: 401);
      await tester.tap(_syncButton);
      await tester.pump();
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.authRequired);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('closing the database takes the SnackBar away',
        (tester) async {
      await _seed(tester, remote: remote);
      remote.readFailure = RemoteAuthException('bad token', statusCode: 401);
      await _open(tester);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.authRequired);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnackBar), findsOneWidget);

      await tester.tap(find.byIcon(Icons.exit_to_app));
      await tester.pump();
      await _pumpUntil(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('removing the database takes the SnackBar away',
        (tester) async {
      await _seed(tester, remote: remote);
      remote.readFailure = RemoteAuthException('bad token', statusCode: 401);
      await _open(tester);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.authRequired);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnackBar), findsOneWidget);

      await _menu(tester, 'Remove local database');
      await _pumpUntil(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pump();
      await _pumpUntil(
          tester,
          () =>
              find.byType(LoginScreen).evaluate().isNotEmpty &&
              _app.localDatabaseNames().isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('after the settings screen closes, a standing problem is '
        'shown again', (tester) async {
      await _seed(tester, remote: remote);
      remote.readFailure = RemoteAuthException('bad token', statusCode: 401);
      await _open(tester);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.authRequired);
      // Without a key derivation in front the first sync can end before the
      // screen exists: the SnackBar is then shown by the post-frame callback
      // and needs a further frame before it animates in.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.widgetWithText(SnackBarAction, 'GitHub settings'));
      await tester.pumpAndSettle();
      expect(find.byType(GithubSettingsScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(GithubSettingsScreen), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('a plain network error shows no SnackBar', (tester) async {
      await _seed(tester, remote: remote);
      remote.readFailure = RemoteBackendException('down');
      await _open(tester);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.notSynced);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('refresh and triggers', () {
    testWidgets('the list shows entries merged in by a sync', (tester) async {
      await _seed(tester, remote: remote, labels: ['mine']);
      await _openAndSync(tester);
      expect(find.text('mine'), findsOneWidget);
      expect(find.text('theirs'), findsNothing);

      // Another device adds an entry.
      await tester.runAsync(() async {
        var other = UltracipherDatabase.fromJson(
            _app.loadedDatabase.value!.toJson());
        other.addEntry().addNewVersion(Entry(label: 'theirs'));
        var key = await _app.deriveRoot(_pass);
        remote.seed(UltracipherApp.encryptDatabase(other, key));
      });
      await tester.tap(_syncButton);
      await tester.pump();
      await _pumpUntil(tester, () => find.text('theirs').evaluate().isNotEmpty);
      expect(find.text('mine'), findsOneWidget);
    });

    testWidgets('a sync without changes does not rebuild the list',
        (tester) async {
      await _seed(tester, remote: remote, labels: ['mine']);
      await _openAndSync(tester);
      // The row's Text widget instance is replaced on every rebuild of the
      // list.
      var before = tester.widget<Text>(find.text('mine'));
      await tester.tap(_syncButton);
      await tester.pump();
      await _pumpUntil(tester, () => remote.readCount >= 2);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.synced);
      await tester.pump();
      var after = tester.widget<Text>(find.text('mine'));
      // Same widget instance: no setState happened in the screen.
      expect(identical(before, after), isTrue, reason: 'the list was rebuilt');
    });

    testWidgets('resuming the app triggers a sync', (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      var reads = remote.readCount;

      for (var state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      await _pumpUntil(tester, () => remote.readCount > reads);
    });

    testWidgets('resuming does nothing once the database is closed',
        (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      _app.closeDatabase();
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
      var reads = remote.readCount;

      for (var state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      expect(remote.readCount, reads);
    });
  });

  group('dispose', () {
    testWidgets('a closed screen leaves no listener and no resume observer',
        (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      // The screen and the status button listen while a database is open.
      // ignore: invalid_use_of_protected_member
      expect(_app.syncStatus.hasListeners, isTrue);

      _app.closeDatabase();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      // ignore: invalid_use_of_protected_member
      expect(_app.syncStatus.hasListeners, isFalse);

      // Open again: a leaked observer of the first screen would sync twice
      // on resume (the second call coalesces into a follow-up run).
      await tester.runAsync(() => _app.openLocalDatabase(_pass));
      await tester.pump();
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.synced);
      var reads = remote.readCount;
      for (var state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.synced);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      expect(remote.readCount, reads + 1);
    });
  });

  group('saving an entry', () {
    testWidgets('a network error shows no dialog and keeps the entry',
        (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      remote.readFailure = RemoteBackendException('down');

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Label'), 'bank');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.check_circle));
      await tester.pump();
      await _pumpUntil(tester,
          () => find.text('Saving...').evaluate().isEmpty &&
              _app.loadedDatabase.value!.getEntries().isNotEmpty);
      await _pumpUntil(
          tester, () => _app.syncStatus.value.state == SyncState.notSynced &&
              _app.syncStatus.value.error != null);
      await tester.pumpAndSettle();

      // No error dialog; the entry is saved locally and still there.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byIcon(Icons.edit), findsOneWidget);
      expect(_app.loadedDatabase.value!.getEntries(), hasLength(1));
      var stored = await tester.runAsync(() async {
        var key = await _app.deriveRoot(_pass);
        var text = _app.storage!
            .getString(UltracipherApp.localPrefsKey(_app.localDatabaseNames().single));
        return UltracipherApp.decryptDatabase(base64.decode(text!), key);
      });
      expect(stored!.getEntries().single.latestEntry!.label, 'bank');
    });
  });

  group('deleting an entry', () {
    testWidgets('a failed local save puts the entry back', (tester) async {
      await _seed(tester, labels: ['bank']);
      await _open(tester);
      var prefs = _FailingPrefs(_app.storage!);
      _app.storage = prefs;
      addTearDown(() => _app.storage = prefs.inner);
      var database = _app.loadedDatabase.value!;
      var id = database.getEntries().single.id;

      await tester.tap(find.text('bank'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_forever));
      await tester.pumpAndSettle();
      prefs.failWrites = true;
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pump();
      await _pumpUntil(
          tester, () => find.byIcon(Icons.check_circle).evaluate().isNotEmpty);
      await tester.tap(find.byIcon(Icons.check_circle));
      await tester.pumpAndSettle();

      // Nothing was saved, so the deletion is undone in memory too.
      expect(database.getEntries(), hasLength(1));
      expect(database.deletions.containsKey(id), isFalse);
      expect(find.byType(EntryViewScreen), findsOneWidget);
    });

    testWidgets('a successful delete stays deleted, without build errors',
        (tester) async {
      await _seed(tester, labels: ['bank']);
      await _open(tester);
      var database = _app.loadedDatabase.value!;
      var id = database.getEntries().single.id;

      await tester.tap(find.text('bank'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_forever));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pump();
      // The progress dialog closes itself after the frame in which the save
      // finished (a pop inside the builder reports "setState() during build").
      await _pumpUntil(
          tester, () => find.byType(EntryViewScreen).evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(database.getEntries(), isEmpty);
      expect(database.deletions.containsKey(id), isTrue);
      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
      expect(find.text('No items'), findsOneWidget);
    });
  });

  group('GitHub settings after removal (M-f)', () {
    testWidgets('asks before connecting again; Cancel changes nothing',
        (tester) async {
      await _seed(tester, remote: remote);
      await _openAndSync(tester);
      await tester.runAsync(() => _app.removeGithub());
      expect(_app.loadedDatabase.value!.settings!.github, isNull);

      await _menu(tester, 'GitHub settings');
      await tester.pumpAndSettle();
      expect(find.text('Remove GitHub'), findsNothing);
      await tester.enterText(
          find.widgetWithText(TextField, 'GitHub token'), 'new-token');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Connect GitHub again?'), findsOneWidget);
      expect(find.textContaining('Change passphrase'), findsOneWidget);

      var settingsTime = _app.loadedDatabase.value!.settings!.time;
      await tester.tap(_inDialog(find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(GithubSettingsScreen), findsOneWidget);
      expect(_app.loadedDatabase.value!.settings!.github, isNull);
      expect(_app.loadedDatabase.value!.settings!.time, settingsTime);
    });

    testWidgets('never configured: no extra question', (tester) async {
      await _seed(tester);
      await _open(tester);
      expect(_app.loadedDatabase.value!.settings, isNull);
      var client = MockClient(
          (_) async => http.Response('{"login":"me"}', 200));
      Navigator.of(tester.element(find.byType(DatabaseLoadedScreen))).push(
          MaterialPageRoute<bool>(
              builder: (_) => GithubSettingsScreen(httpClient: client)));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'GitHub token'), 'new-token');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      expect(find.text('Connect GitHub again?'), findsNothing);
      await _pumpUntil(
          tester, () => find.byType(GithubSettingsScreen).evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(_app.loadedDatabase.value!.settings!.github, isNotNull);
    });
  });
}
