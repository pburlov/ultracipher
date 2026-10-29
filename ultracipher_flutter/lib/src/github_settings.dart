import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ultracipher_flutter/src/core.dart';

import 'backend/github_backend.dart';
import 'backend/remote_backend.dart';
import 'commons.dart';
import 'progess_screen.dart';

/// GitHub-Konfiguration der offenen Datenbank (Plan §3.4): Token, Repository
/// und Branch, mit "Connect"/"Save", optional "Skip" und, wenn GitHub schon
/// eingerichtet ist, "Remove GitHub".
///
/// Wird von "New" (mit [setup], Zurück bedeutet Skip) und später vom Menü der
/// geöffneten Datenbank benutzt. Die Datenbank muss schon offen sein
/// (`configureGithub` arbeitet auf der Sitzung). Während `configureGithub` und
/// `removeGithub` läuft, liegt eine Sperre über der ganzen App
/// ([runWithProgress]): nichts kann bearbeitet werden. Das Ergebnis der Route
/// ist `true`, wenn GitHub eingerichtet oder entfernt wurde.
///
/// Das Token wird nie vorbelegt, angezeigt oder geloggt.
class GithubSettingsScreen extends StatefulWidget {
  /// Erstkonfiguration nach "New": "Skip" statt "Cancel" (lokal-only, E4).
  final bool setup;

  /// Testnaht: HTTP-Client für `GET /user` in `configureGithub`.
  final http.Client? httpClient;

  const GithubSettingsScreen({Key? key, this.setup = false, this.httpClient})
      : super(key: key);

  @override
  State<StatefulWidget> createState() => _GithubSettingsScreenState();
}

class _GithubSettingsScreenState extends State<GithubSettingsScreen> {
  final TextEditingController _token = TextEditingController();
  final TextEditingController _repo = TextEditingController();
  final TextEditingController _branch = TextEditingController();

  String? _error;

  bool get _hasGithub =>
      UltracipherApp.instance.loadedDatabase.value?.settings?.github != null;

  @override
  void initState() {
    super.initState();
    var github = UltracipherApp.instance.loadedDatabase.value?.settings?.github;
    _repo.text = github?.repo ?? GithubBackend.defaultRepo;
    _branch.text = github?.branch ?? '';
    _token.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _token.dispose();
    _repo.dispose();
    _branch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('GitHub')),
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
                        ? 'Sync this database with a GitHub repository, so that '
                            'your other devices can reach it. Only encrypted '
                            'data is stored there. Or skip this: the database '
                            'then exists on this device only.'
                        : _hasGithub
                            ? 'Enter the token again to change the GitHub '
                                'access of this database.'
                            : 'Sync this database with a GitHub repository.'),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: PasswordField(
                      label: 'GitHub token',
                      textController: _token,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: TextField(
                      controller: _repo,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Repository (in your account)',
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: TextField(
                      controller: _branch,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _canSave ? _save() : null,
                      decoration: InputDecoration(
                        labelText: 'Branch',
                        helperText: "Empty: the repository's default branch",
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                  ),
                  if (!_hasGithub)
                    Padding(
                      padding: EdgeInsets.all(5),
                      child: Text(
                        'If the repository has no file for this passphrase '
                        'yet, one is created. If you changed the passphrase on '
                        'another device, use the new passphrase here: creating '
                        'a file for the old one brings the old database back.',
                        style: Theme.of(context).textTheme.bodySmall,
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
                        if (_hasGithub)
                          TextButton(
                            onPressed: _remove,
                            child: Text('Remove GitHub',
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

  bool get _canSave => _token.text.trim().isNotEmpty;

  Future<void> _save({bool confirmCreate = false}) async {
    var navigator = Navigator.of(context);
    var token = _token.text;
    var repo = _repo.text;
    var branch = _branch.text;
    // M-f (Plan §9): GitHub wurde entfernt (nicht: nie eingerichtet). Core
    // zählt das als Erstkonfiguration und legt eine fehlende Datei ohne
    // Rückfrage an; nach einem Passphrase-Wechsel auf einem anderen Gerät
    // brächte das die alte Datenbank zurück. Darum hier vorher fragen.
    var settings = UltracipherApp.instance.loadedDatabase.value?.settings;
    if (!confirmCreate &&
        !widget.setup &&
        settings != null &&
        settings.github == null) {
      var proceed = await _confirmReconnect();
      if (proceed != true || !mounted) return;
    }
    setState(() => _error = null);
    GithubSettingsResult result;
    try {
      result = await runWithProgress(
          context,
          () => UltracipherApp.instance.configureGithub(
              token: token,
              repo: repo,
              branch: branch,
              confirmCreate: confirmCreate,
              httpClient: widget.httpClient),
          title: 'Connecting to GitHub...');
    } on GithubFileMissingException {
      if (!mounted) return;
      var create = await _confirmCreate();
      if (create == true && mounted) {
        await _save(confirmCreate: true);
      }
      return;
    } on RemoteAuthException {
      if (mounted) {
        setState(() => _error = 'GitHub rejected the token. Check it and '
            'that it may read and write the repository contents.');
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
          'GitHub is set up, but the previous location could not be updated '
              '(${describeError(oldLocationError)}). Devices that still use '
              'the previous repository will not notice the change; set it up '
              'there by hand.');
    }
    if (navigator.mounted) navigator.pop(true);
  }

  Future<bool?> _confirmReconnect() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Connect GitHub again?'),
        content: Text('GitHub was removed from this database. If the '
            'repository has no file for it, one is created without further '
            'asking.\n\n'
            'If you changed the passphrase on another device, do not '
            'connect here: cancel, and use "Change passphrase" with the new '
            'passphrase instead. Connecting with the old passphrase brings '
            'the old database back on GitHub.'),
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

  /// E3: am Ziel gibt es keine Datei, obwohl GitHub für diese Datenbank schon
  /// eingerichtet war. Meist heißt das "Passphrase woanders geändert", nicht
  /// "neu anlegen" (Plan §3.3, §9 M-f).
  Future<bool?> _confirmCreate() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('No database file on GitHub'),
        content: Text('There is no file for this database at this location.\n\n'
            'If you changed the passphrase on another device, do not create '
            'a file here: cancel, and use "Change passphrase" with the new '
            'passphrase instead. Creating a file for the old passphrase '
            'brings the old database back on GitHub.\n\n'
            'Otherwise (for example the file was deleted by hand), you can '
            'create it on GitHub now.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Create on GitHub')),
        ],
      ),
    );
  }

  Future<void> _remove() async {
    var navigator = Navigator.of(context);
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove GitHub?'),
        content: Text('This database stops syncing with GitHub. The file on '
            'GitHub stays where it is; it is not deleted. Your other devices '
            'learn about the change on their next sync.'),
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
          context, () => UltracipherApp.instance.removeGithub(),
          title: 'Removing GitHub...');
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
          'GitHub was removed on this device, but the change could not be '
              'passed on (${describeError(oldLocationError)}). Your other '
              'devices keep syncing until you remove GitHub there too.');
    }
    if (navigator.mounted) navigator.pop(true);
  }
}
