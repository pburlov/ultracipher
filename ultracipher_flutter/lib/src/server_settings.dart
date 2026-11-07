import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ultracipher_flutter/src/core.dart';

import 'commons.dart';
import 'progess_screen.dart';
import 'sync_log_screen.dart';

/// Konfiguration des Sync-Servers (REST) der offenen Datenbank: die URL, mit
/// "Connect"/"Save", optional "Skip" und, wenn schon eingerichtet, "Remove
/// sync server". Das Gegenstück zu `GithubSettingsScreen`, mit denselben
/// Regeln: die Datenbank muss offen sein, `configureServer` und `removeRemote`
/// laufen unter einer Sperre ([runWithProgress]), das Ergebnis der Route ist
/// `true`, wenn etwas eingerichtet oder entfernt wurde.
///
/// Das Feld ist leer, solange kein Server eingerichtet ist: die App kennt
/// keine voreingestellte oder öffentliche Adresse (jeder betreibt seinen
/// eigenen Server).
class ServerSettingsScreen extends StatefulWidget {
  /// Erstkonfiguration nach "New": "Skip" statt "Cancel" (lokal-only).
  final bool setup;

  /// Testnaht: HTTP-Client für das `RestBackend` in `configureServer`.
  final http.Client? httpClient;

  const ServerSettingsScreen({Key? key, this.setup = false, this.httpClient})
      : super(key: key);

  @override
  State<StatefulWidget> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  final TextEditingController _url = TextEditingController();

  String? _error;

  // Dieselbe Regel wie im Core und in der Auswahl: bei beiden gesetzt gilt
  // GitHub, dann gibt es hier keinen Server zu entfernen.
  bool get _hasServer =>
      UltracipherApp.instance.loadedDatabase.value?.settings?.activeServer !=
      null;

  @override
  void initState() {
    super.initState();
    _url.text = UltracipherApp
            .instance.loadedDatabase.value?.settings?.activeServer?.url ??
        '';
    _url.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var small = Theme.of(context).textTheme.bodySmall;
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
                        ? 'Sync this database with your own sync server, so '
                            'that your other devices can reach it. Only '
                            'encrypted data is stored there. Or skip this: '
                            'the database then exists on this device only.'
                        : _hasServer
                            ? 'Change the address of the sync server of this '
                                'database.'
                            : 'Sync this database with your own sync server.'),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: TextField(
                      key: const Key('serverUrlField'),
                      controller: _url,
                      autofocus: true,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _canSave ? _save() : null,
                      decoration: InputDecoration(
                        labelText: 'Server address (URL)',
                        helperText: 'Starts with https://, for example '
                            'https://example.com/ucdb',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: Text(
                      'Anyone who knows the URL and the database name can '
                      'overwrite or delete the server copy. Your data stays '
                      'encrypted and your local copy is not affected.',
                      style: small,
                    ),
                  ),
                  if (!_hasServer)
                    Padding(
                      padding: EdgeInsets.all(5),
                      child: Text(
                        'If the server has no file for this passphrase yet, '
                        'one is created. If you changed the passphrase on '
                        'another device, use the new passphrase here: '
                        'creating a file for the old one brings the old '
                        'database back.',
                        style: small,
                      ),
                    ),
                  if (progressOnWeb)
                    Padding(
                      padding: EdgeInsets.all(5),
                      child: Text(
                        'In the web app only addresses that the page allows '
                        '(its content security policy) can be reached, '
                        'usually the server the web app itself comes from. '
                        'The apps for phones and computers have no such '
                        'limit.',
                        style: small,
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: EdgeInsets.all(5),
                      child: Text(_error!,
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.center,
                      spacing: 8,
                      children: [
                        ElevatedButton(
                          onPressed: _canSave ? _save : null,
                          child: Text(widget.setup ? 'Connect' : 'Save'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: Text(widget.setup ? 'Skip' : 'Cancel'),
                        ),
                        // Auch ohne Fehler erreichbar (Diagnose eines Syncs).
                        TextButton(
                          key: const Key('syncLogButton'),
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) => const SyncLogScreen())),
                          child: Text('Sync log'),
                        ),
                        if (_hasServer)
                          TextButton(
                            onPressed: _remove,
                            child: Text('Remove sync server',
                                style: TextStyle(color: Colors.redAccent)),
                          ),
                      ],
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

  bool get _canSave => _url.text.trim().isNotEmpty;

  Future<void> _save({bool confirmCreate = false}) async {
    var navigator = Navigator.of(context);
    var url = _url.text;
    // Wie bei GitHub (M-f): der Sync-Ort wurde entfernt (nicht: nie
    // eingerichtet). Core zählt das als Erstkonfiguration und legt eine
    // fehlende Datei ohne Rückfrage an; nach einem Passphrase-Wechsel auf einem
    // anderen Gerät brächte das die alte Datenbank zurück. Darum vorher fragen.
    var settings = UltracipherApp.instance.loadedDatabase.value?.settings;
    if (!confirmCreate &&
        !widget.setup &&
        settings != null &&
        settings.github == null &&
        settings.server == null) {
      var proceed = await _confirmReconnect();
      if (proceed != true || !mounted) return;
    }
    setState(() => _error = null);
    GithubSettingsResult result;
    try {
      result = await runWithProgress(
          context,
          () => UltracipherApp.instance.configureServer(
              url: url,
              confirmCreate: confirmCreate,
              httpClient: widget.httpClient),
          title: 'Connecting to the sync server...');
    } on ServerFileMissingException {
      if (!mounted) return;
      var create = await _confirmCreate();
      if (create == true && mounted) {
        await _save(confirmCreate: true);
      }
      return;
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
          'The sync server is set up, but the previous location could not be '
              'updated (${describeError(oldLocationError)}). Devices that '
              'still use the previous location will not notice the change; '
              'set it up there by hand.');
    }
    if (navigator.mounted) navigator.pop(true);
  }

  Future<bool?> _confirmReconnect() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Connect a sync server again?'),
        content: Text('Syncing was removed from this database. If the server '
            'has no file for it, one is created without further asking.\n\n'
            'If you changed the passphrase on another device, do not '
            'connect here: cancel, and use "Change passphrase" with the new '
            'passphrase instead. Connecting with the old passphrase brings '
            'the old database back on the server.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Connect')),
        ],
      ),
    );
  }

  /// Am Ziel gibt es keine Datei, obwohl der Server für diese Datenbank schon
  /// eingerichtet war. Meist heißt das "Passphrase woanders geändert", nicht
  /// "neu anlegen".
  Future<bool?> _confirmCreate() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('No database file on the sync server'),
        content: Text('There is no file for this database at this location.\n\n'
            'If you changed the passphrase on another device, do not create '
            'a file here: cancel, and use "Change passphrase" with the new '
            'passphrase instead. Creating a file for the old passphrase '
            'brings the old database back on the server.\n\n'
            'Otherwise (for example the file was deleted by hand), you can '
            'create it on the sync server now.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Create on the server')),
        ],
      ),
    );
  }

  Future<void> _remove() async {
    var navigator = Navigator.of(context);
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove sync server?'),
        content: Text('This database stops syncing with the sync server. The '
            'file on the server stays where it is; it is not deleted. Your '
            'other devices learn about the change on their next sync.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Remove')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    GithubSettingsResult result;
    try {
      result = await runWithProgress(
          context, () => UltracipherApp.instance.removeRemote(),
          title: 'Removing the sync server...');
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
          'The sync server was removed on this device, but the change could '
              'not be passed on (${describeError(oldLocationError)}). Your '
              'other devices keep syncing until you remove it there too.');
    }
    if (navigator.mounted) navigator.pop(true);
  }
}
