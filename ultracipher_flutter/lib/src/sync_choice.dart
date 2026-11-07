import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ultracipher_flutter/src/core.dart';

import 'commons.dart';
import 'github_settings.dart';
import 'progess_screen.dart';
import 'server_settings.dart';

/// Die Auswahl des Sync-Orts der offenen Datenbank: "None (only this device)",
/// "GitHub" oder "Sync server (REST)". Höchstens einer ist aktiv (ein Wechsel
/// ersetzt den bisherigen). GitHub und Sync server öffnen ihren eigenen
/// Bildschirm; "None" entfernt den Sync nach einer Rückfrage.
///
/// Wird vom Menü der offenen Datenbank ("Sync server") und von "New" (mit
/// [setup]: statt "None" ein "Skip", die Datenbank bleibt dann lokal) benutzt.
/// Das Ergebnis der Route ist `true`, wenn etwas eingerichtet oder entfernt
/// wurde.
class SyncChoiceScreen extends StatefulWidget {
  final bool setup;

  /// Testnaht, an die Bildschirme von GitHub und Sync server durchgereicht.
  final http.Client? httpClient;

  const SyncChoiceScreen({Key? key, this.setup = false, this.httpClient})
      : super(key: key);

  @override
  State<StatefulWidget> createState() => _SyncChoiceScreenState();
}

enum _Current { none, github, server }

class _SyncChoiceScreenState extends State<SyncChoiceScreen> {
  String? _error;

  /// Der aktive Sync-Ort laut Einstellungen (GitHub vor Server, wie im Core).
  _Current get _current {
    var settings = UltracipherApp.instance.loadedDatabase.value?.settings;
    if (settings?.github != null) return _Current.github;
    if (settings?.activeServer != null) return _Current.server;
    return _Current.none;
  }

  @override
  Widget build(BuildContext context) {
    var current = _current;
    Widget option(Key key, _Current kind, String title, String subtitle,
        VoidCallback onTap) {
      var selected = current == kind;
      return Card(
        child: ListTile(
          key: key,
          leading:
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: selected ? Text('Current') : Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('Sync server')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: Text(widget.setup
                        ? 'Where should this database be synced, so that your '
                            'other devices can reach it? Only encrypted data '
                            'is stored there. Or skip this: the database then '
                            'exists on this device only.'
                        : 'Where is this database synced? Choosing another '
                            'place replaces the current one.'),
                  ),
                  if (!widget.setup)
                    option(
                        const Key('choiceNone'),
                        _Current.none,
                        'None (only this device)',
                        'The database is not synced.',
                        _chooseNone),
                  option(
                      const Key('choiceGithub'),
                      _Current.github,
                      'GitHub',
                      'A repository in your GitHub account.',
                      _chooseGithub),
                  option(
                      const Key('choiceServer'),
                      _Current.server,
                      'Sync server (REST)',
                      'Your own server; you enter its address.',
                      _chooseServer),
                  if (_error != null)
                    Padding(
                      padding: EdgeInsets.all(5),
                      child: Text(_error!,
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  if (widget.setup)
                    Padding(
                      padding: EdgeInsets.all(5),
                      child: TextButton(
                        key: const Key('choiceSkip'),
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text('Skip'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(Widget screen) async {
    var navigator = Navigator.of(context);
    var done = await navigator
        .push<bool>(MaterialPageRoute<bool>(builder: (context) => screen));
    if (!mounted) return;
    if (done == true && navigator.mounted) {
      navigator.pop(true);
    } else {
      // Der Sync-Ort kann sich trotz "Cancel" geändert haben (Entfernen).
      setState(() {});
    }
  }

  void _chooseGithub() => _open(
      GithubSettingsScreen(setup: widget.setup, httpClient: widget.httpClient));

  void _chooseServer() => _open(
      ServerSettingsScreen(setup: widget.setup, httpClient: widget.httpClient));

  Future<void> _chooseNone() async {
    var navigator = Navigator.of(context);
    var current = _current;
    if (current == _Current.none) {
      navigator.pop(false);
      return;
    }
    var where = current == _Current.github ? 'GitHub' : 'the sync server';
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop syncing?'),
        content: Text('This database stops syncing with $where and exists on '
            'this device only. The file at $where stays where it is; it is '
            'not deleted. Your other devices learn about the change on their '
            'next sync.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Stop syncing')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _error = null);
    GithubSettingsResult result;
    try {
      result = await runWithProgress(
          context, () => UltracipherApp.instance.removeRemote(),
          title: 'Removing...');
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
      return;
    }
    if (!mounted) return;
    var oldLocationError = result.oldLocationError;
    if (oldLocationError != null) {
      await showMessageDialog(
          context,
          'Other devices not informed',
          'Syncing was removed on this device, but the change could not be '
              'passed on (${describeError(oldLocationError)}). Your other '
              'devices keep syncing until you remove it there too.');
    }
    if (navigator.mounted) navigator.pop(true);
  }
}
