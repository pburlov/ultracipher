// Widget-Tests fuer den Sync-Server in der Oberflaeche: Auswahl (SyncChoiceScreen),
// Bildschirm der URL (ServerSettingsScreen), neutrale Texte (Statussymbol,
// Entfernen-Warnung, Export). Das Netz ist der FakeRestServer (MockClient) und
// ein FakeRemoteBackend fuer GitHub; die Sitzung baut ihre Backends ueber die
// Naehte, kein echtes Netz.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/main.dart';
import 'package:ultracipher_flutter/src/backend/rest_backend.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/database_loaded.dart';
import 'package:ultracipher_flutter/src/github_settings.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/progess_screen.dart';
import 'package:ultracipher_flutter/src/server_settings.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/sync_choice.dart';
import 'package:ultracipher_flutter/src/sync_status_button.dart';

import 'fake_remote_backend.dart';
import 'fake_rest_server.dart';
import 'memoized_key_derivation.dart';

const _pass = 'correct horse';
const _url = 'https://sync.example.test/ucdb';

UltracipherApp get _app => UltracipherApp.instance;

late FakeRestServer _server;
late FakeRemoteBackend _github;

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

/// Startet die App und legt eine Datenbank an (offen, ohne Sync-Ort).
Future<void> _openDatabase(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MyApp());
  await tester.pump();
  await tester.runAsync(() => _app.createDatabase(_pass));
  await tester.pumpAndSettle();
  expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
}

Future<void> _openChoice(WidgetTester tester) async {
  await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sync server').last);
  await tester.pumpAndSettle();
  expect(find.byType(SyncChoiceScreen), findsOneWidget);
}

Finder get _urlField => find.byKey(const Key('serverUrlField'));

void _pushServerScreen(WidgetTester tester, {bool setup = false}) {
  Navigator.of(tester.element(find.byType(DatabaseLoadedScreen))).push(
      MaterialPageRoute<bool>(
          builder: (_) => ServerSettingsScreen(
              setup: setup, httpClient: _server.client)));
}

Future<void> _enterUrlAndSave(WidgetTester tester, String url,
    {String button = 'Save'}) async {
  await tester.enterText(_urlField, url);
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, button));
  await tester.pump();
}

Finder _inDialog(Finder f) =>
    find.descendant(of: find.byType(AlertDialog), matching: f);

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
    _server = FakeRestServer();
    _github = FakeRemoteBackend();
    await _app.init();
    _app.backendForSettings = (s, key) => s == null ? null : _github;
    _app.serverBackendForSettings = (s, key) => RestBackend(
        url: s.url, client: _server.client, log: _app.syncLog);
  });

  tearDown(() {
    progressOnWeb = false;
    _app.closeDatabase();
    _app.backendForSettings = null;
    _app.serverBackendForSettings = null;
  });

  group('sync status texts', () {
    test('name the backend; the sync server is "the sync server" in a '
        'sentence', () {
      expect(syncStatusText(SyncStatus.synced, remoteName: 'GitHub'),
          'Synced with GitHub');
      expect(syncStatusText(SyncStatus.synced, remoteName: 'Sync server'),
          'Synced with the sync server');
      expect(
          syncStatusText(const SyncStatus(SyncState.remoteMissing),
              remoteName: 'Sync server'),
          contains('no longer found on the sync server'));
      expect(
          syncStatusText(const SyncStatus(SyncState.authRequired),
              remoteName: 'GitHub'),
          startsWith('GitHub rejected the access'));
      expect(syncStatusText(SyncStatus.noRemote),
          'Only stored on this device (no sync set up)');
      expect(syncStatusText(SyncStatus.synced), 'Synced with the remote');
    });

    testWidgets('the title bar tooltip names the sync server', (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      await tester.pump();
      var tooltip = tester
          .widget<IconButton>(find.byKey(const Key('syncStatusButton')))
          .tooltip!;
      expect(tooltip, contains('Synced with the sync server'));
    });
  });

  group('choice', () {
    testWidgets('from the menu: None, GitHub, Sync server (REST); the current '
        'one is marked', (tester) async {
      await _openDatabase(tester);
      await _openChoice(tester);
      expect(find.text('None (only this device)'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('choiceNone')),
              matching: find.text('Current')),
          findsOneWidget);
      expect(find.byKey(const Key('choiceSkip')), findsNothing);
    });

    testWidgets('the sync server is marked current after setup',
        (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      await tester.pump();
      await _openChoice(tester);
      expect(
          find.descendant(
              of: find.byKey(const Key('choiceServer')),
              matching: find.text('Current')),
          findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
    });

    testWidgets('None asks, then removes the sync server and ends the screen',
        (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      await tester.pump();
      await _openChoice(tester);

      await tester.tap(find.byKey(const Key('choiceNone')));
      await tester.pumpAndSettle();
      expect(find.text('Stop syncing?'), findsOneWidget);
      expect(find.textContaining('syncing with the sync server and exists'),
          findsOneWidget);
      expect(find.textContaining('stays where it is'), findsOneWidget);
      // Cancel changes nothing.
      await tester.tap(_inDialog(find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
      expect(_app.loadedDatabase.value!.settings!.server, isNotNull);

      await tester.tap(find.byKey(const Key('choiceNone')));
      await tester.pumpAndSettle();
      await tester.tap(
          _inDialog(find.widgetWithText(TextButton, 'Stop syncing')));
      await _pumpUntil(
          tester, () => find.byType(SyncChoiceScreen).evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(_app.loadedDatabase.value!.settings!.server, isNull);
      expect(_app.remoteBackend, isNull);
      expect(_app.syncStatus.value.state, SyncState.noRemote);
      expect(find.byType(DatabaseLoadedScreen), findsOneWidget);
    });

    testWidgets('None without a sync place just closes', (tester) async {
      await _openDatabase(tester);
      await _openChoice(tester);
      await tester.tap(find.byKey(const Key('choiceNone')));
      await tester.pumpAndSettle();
      expect(find.byType(SyncChoiceScreen), findsNothing);
      expect(_app.loadedDatabase.value!.settings, isNull);
    });

    testWidgets('GitHub screen says it replaces a sync server and does not '
        'ask "connect again"', (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      await tester.pump();
      var client = MockClient(
          (_) async => http.Response('{"login":"me"}', 200));
      Navigator.of(tester.element(find.byType(DatabaseLoadedScreen))).push(
          MaterialPageRoute<bool>(
              builder: (_) => GithubSettingsScreen(httpClient: client)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connecting GitHub replaces it'),
          findsOneWidget);
      expect(find.text('Remove GitHub'), findsNothing);

      await tester.enterText(
          find.widgetWithText(TextField, 'GitHub token'), 'tok');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      expect(find.text('Connect GitHub again?'), findsNothing);
      await _pumpUntil(
          tester, () => find.byType(GithubSettingsScreen).evaluate().isEmpty);
      await tester.pumpAndSettle();

      var settings = _app.loadedDatabase.value!.settings!;
      expect(settings.github, isNotNull);
      expect(settings.server, isNull);
      expect(_app.remoteBackend, same(_github));
    });
  });

  group('sync server screen', () {
    testWidgets('empty field without a default, hint, Connect disabled until '
        'there is text', (tester) async {
      await _openDatabase(tester);
      _pushServerScreen(tester, setup: true);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(_urlField).controller!.text, '');
      expect(find.textContaining('Anyone who knows the URL and the database '
          'name can overwrite or delete the server copy'), findsOneWidget);
      expect(find.textContaining('brings the old database back'),
          findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Skip'), findsOneWidget);
      expect(find.text('Remove sync server'), findsNothing);
      var connect = find.widgetWithText(ElevatedButton, 'Connect');
      expect(tester.widget<ElevatedButton>(connect).onPressed, isNull);
      await tester.enterText(_urlField, '  ');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(connect).onPressed, isNull);
      await tester.enterText(_urlField, _url);
      await tester.pump();
      expect(tester.widget<ElevatedButton>(connect).onPressed, isNotNull);
      expect(find.textContaining('content security policy'), findsNothing);
    });

    testWidgets('on the web a note about the content security policy',
        (tester) async {
      progressOnWeb = true;
      await _openDatabase(tester);
      _pushServerScreen(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('content security policy'), findsOneWidget);
    });

    testWidgets('an invalid URL shows the message and changes nothing',
        (tester) async {
      await _openDatabase(tester);
      _pushServerScreen(tester);
      await tester.pumpAndSettle();

      await _enterUrlAndSave(tester, 'http://example.test/ucdb');
      await tester.pumpAndSettle();
      expect(find.textContaining('must start with https://'), findsOneWidget);
      expect(find.byType(ServerSettingsScreen), findsOneWidget);
      expect(_app.loadedDatabase.value!.settings, isNull);
      expect(_server.requests, isEmpty);

      // Tippen raeumt die Meldung weg.
      await tester.enterText(_urlField, _url);
      await tester.pump();
      expect(find.textContaining('must start with https://'), findsNothing);
    });

    testWidgets('a valid URL creates the file, stores the settings and '
        'closes the screen', (tester) async {
      await _openDatabase(tester);
      _pushServerScreen(tester, setup: true);
      await tester.pumpAndSettle();

      await _enterUrlAndSave(tester, '$_url/', button: 'Connect');
      await _pumpUntil(
          tester, () => find.byType(ServerSettingsScreen).evaluate().isEmpty);
      await tester.pumpAndSettle();

      var settings = _app.loadedDatabase.value!.settings!;
      expect(settings.server!.url, _url);
      expect(settings.github, isNull);
      expect(_app.remoteBackend, isA<RestBackend>());
      expect(_app.syncStatus.value.state, SyncState.synced);
      expect(_server.requests.any((r) => r.method == 'PUT'), isTrue);
    });

    testWidgets('a server error is shown and nothing changes', (tester) async {
      await _openDatabase(tester);
      _server.failWith = 500;
      _pushServerScreen(tester);
      await tester.pumpAndSettle();

      await _enterUrlAndSave(tester, _url);
      await _pumpUntil(tester,
          () => find.textContaining('status 500').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(ServerSettingsScreen), findsOneWidget);
      expect(_app.loadedDatabase.value!.settings, isNull);
      expect(_app.remoteBackend, isNull);
    });

    testWidgets('a missing file asks first; Cancel changes nothing, Create '
        'writes it', (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      await tester.pump();
      var name = _server.requests.first.url.pathSegments.last;
      _server.deleteFile(name);
      _server.requests.clear();
      _pushServerScreen(tester);
      await tester.pumpAndSettle();

      // Reconfiguration: current URL shown, removal offered, no first-time hint.
      expect(tester.widget<TextField>(_urlField).controller!.text, _url);
      expect(find.text('Remove sync server'), findsOneWidget);
      expect(find.textContaining('brings the old database back'),
          findsNothing);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      await _pumpUntil(
          tester,
          () => find
              .text('No database file on the sync server')
              .evaluate()
              .isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_inDialog(find.textContaining('Change passphrase')),
          findsOneWidget);
      expect(_server.requests.any((r) => r.method == 'PUT'), isFalse);

      await tester.tap(_inDialog(find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(ServerSettingsScreen), findsOneWidget);
      expect(_server.stored(name), isNull);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      await _pumpUntil(
          tester,
          () => find
              .text('No database file on the sync server')
              .evaluate()
              .isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      await tester
          .tap(find.widgetWithText(TextButton, 'Create on the server'));
      await tester.pump();
      await _pumpUntil(
          tester, () => find.byType(ServerSettingsScreen).evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(_server.stored(name), isNotNull);
    });

    testWidgets('after a removal it asks before connecting again',
        (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() async {
        await _app.configureServer(url: _url, httpClient: _server.client);
        await _app.removeRemote();
      });
      await tester.pump();
      _pushServerScreen(tester);
      await tester.pumpAndSettle();

      await _enterUrlAndSave(tester, _url);
      await tester.pumpAndSettle();
      expect(find.text('Connect a sync server again?'), findsOneWidget);
      expect(_inDialog(find.textContaining('Change passphrase')),
          findsOneWidget);
      var time = _app.loadedDatabase.value!.settings!.time;
      await tester.tap(_inDialog(find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(ServerSettingsScreen), findsOneWidget);
      expect(_app.loadedDatabase.value!.settings!.time, time);
      expect(_app.loadedDatabase.value!.settings!.server, isNull);
    });

    testWidgets('Remove sync server asks and removes it', (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      await tester.pump();
      _pushServerScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Remove sync server'));
      await tester.pumpAndSettle();
      expect(find.text('Remove sync server?'), findsOneWidget);
      await tester.tap(_inDialog(find.widgetWithText(TextButton, 'Remove')));
      await tester.pump();
      await _pumpUntil(
          tester, () => find.byType(ServerSettingsScreen).evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(_app.loadedDatabase.value!.settings!.server, isNull);
      expect(_app.remoteBackend, isNull);
    });

    testWidgets('inconsistent settings (both set): GitHub wins everywhere, '
        'no "Remove sync server", no server address shown', (tester) async {
      await _openDatabase(tester);
      _app.loadedDatabase.value!.setSettings(
          github: GithubSettings(
              token: 't', owner: 'o', repo: 'r', branch: 'main'),
          server: ServerSettings(url: _url));
      _pushServerScreen(tester);
      await tester.pumpAndSettle();
      expect(find.text('Remove sync server'), findsNothing);
      expect(tester.widget<TextField>(_urlField).controller!.text, '');
      Navigator.of(tester.element(find.byType(ServerSettingsScreen))).pop();
      await tester.pumpAndSettle();

      await _openChoice(tester);
      expect(
          find.descendant(
              of: find.byKey(const Key('choiceGithub')),
              matching: find.text('Current')),
          findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
      await tester.tap(find.byKey(const Key('choiceGithub')));
      await tester.pumpAndSettle();
      expect(find.text('Remove GitHub'), findsOneWidget);
      expect(find.textContaining('Connecting GitHub replaces it'),
          findsNothing);
    });

    testWidgets('the sync log is reachable', (tester) async {
      await _openDatabase(tester);
      _pushServerScreen(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('syncLogButton')));
      await tester.pumpAndSettle();
      expect(find.text('Sync log'), findsWidgets);
      expect(find.byType(ServerSettingsScreen), findsNothing,
          reason: 'the log screen is on top');
    });
  });

  group('menu texts', () {
    testWidgets('remove-local warning names the sync server', (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      await tester.pump();
      await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove local database'));
      await _pumpUntil(tester,
          () => find.byType(AlertDialog).evaluate().isNotEmpty);
      expect(_inDialog(find.textContaining('stays on the sync server')),
          findsOneWidget);
      expect(_inDialog(find.textContaining('GitHub')), findsNothing);
    });

    testWidgets('the encrypted export says it holds the server address',
        (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      await tester.pump();
      await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export encrypted (base64)'));
      await _pumpUntil(tester,
          () => find.byType(AlertDialog).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(_inDialog(find.textContaining('address of your sync server')),
          findsOneWidget);
      expect(_inDialog(find.textContaining('access token')), findsNothing);
    });

    testWidgets('the remoteMissing SnackBar offers the sync server settings',
        (tester) async {
      await _openDatabase(tester);
      await tester.runAsync(() => _app.configureServer(
          url: _url, httpClient: _server.client));
      _server.deleteFile(_server.requests.first.url.pathSegments.last);
      await tester.runAsync(() => _app.syncNow());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 1));

      expect(find.textContaining('no longer found on the sync server'),
          findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'Sync server'),
          findsOneWidget);
    });
  });
}
