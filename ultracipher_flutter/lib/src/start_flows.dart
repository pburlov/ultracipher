import 'package:flutter/material.dart';
import 'package:ultracipher_flutter/src/core.dart';

import 'commons.dart';
import 'github_settings.dart';
import 'progess_screen.dart';

// Die Abläufe "New" und "Import" des Startscreens (Plan §3.4). Beide sind
// eigene Routen über dem Startscreen: sobald eine Datenbank offen ist, tauscht
// main.dart den Startscreen gegen die Datenbankansicht aus und entsorgt ihn
// mitten im Ablauf; Routen darüber bleiben stehen und beenden sich selbst.

const String derivingKeyTitle = 'Deriving key...';

/// R2: die lokale Kopie zu [passphrase] ist nicht lesbar. Fragt mit deutlicher
/// Warnung, ob sie entfernt werden soll, und entfernt sie dann. Gibt zurück, ob
/// etwas entfernt wurde.
Future<bool> offerRemoveUnreadableDatabase(
    BuildContext context, String passphrase) async {
  var confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Local copy cannot be read'),
      content: Text('The copy of this database on this device is damaged and '
          'cannot be opened. It was left untouched.\n\n'
          'You can remove it. WARNING: if this database is not on GitHub, the '
          'damaged copy is the only one, and removing it deletes the database '
          'for good. Remove it only if you can restore the data from GitHub '
          'or from an export.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Remove local copy',
                style: TextStyle(color: Colors.redAccent))),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  try {
    return await runWithProgress(context,
        () => UltracipherApp.instance.removeLocalDatabase(passphrase: passphrase),
        title: derivingKeyTitle, hint: derivationHint());
  } catch (e) {
    if (context.mounted) {
      await showMessageDialog(context, 'Not removed', describeError(e));
    }
    return false;
  }
}

/// "New": Passphrase plus Bestätigung, dann (nach dem Anlegen) die
/// GitHub-Konfiguration mit "Skip".
class NewDatabaseScreen extends StatefulWidget {
  const NewDatabaseScreen({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _NewDatabaseScreenState();
}

class _NewDatabaseScreenState extends State<NewDatabaseScreen> {
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _confirmation = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _passphrase.addListener(_changed);
    _confirmation.addListener(_changed);
  }

  void _changed() => setState(() => _error = null);

  @override
  void dispose() {
    _passphrase.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  bool get _matches => _passphrase.text == _confirmation.text;

  bool get _canCreate => _passphrase.text.trim().isNotEmpty && _matches;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('New database')),
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
                    child: Text('The passphrase is the key to the database and '
                        'its only name. It cannot be recovered: if you forget '
                        'it, the data is lost.'),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: PasswordField(
                      textController: _passphrase,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: PasswordField(
                      label: 'Confirm passphrase',
                      textController: _confirmation,
                      fillColor: _matches ? null : Colors.amberAccent,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _canCreate ? _create() : null,
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
                          onPressed: _canCreate ? _create : null,
                          child: Text('Create'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text('Cancel'),
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

  Future<void> _create() async {
    var navigator = Navigator.of(context);
    var passphrase = _passphrase.text;
    if (hasNonAscii(passphrase.trim()) &&
        !await confirmNonAsciiPassphrase(context)) {
      return;
    }
    if (!mounted) return;
    try {
      await runWithProgress(
          context, () => UltracipherApp.instance.createDatabase(passphrase),
          title: derivingKeyTitle, hint: derivationHint());
    } on LocalDatabaseExistsException {
      if (!mounted) return;
      var openExisting = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Database already exists'),
          content: Text('A database for this passphrase already exists on '
              'this device. A new one is never created over it.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Open existing')),
          ],
        ),
      );
      if (openExisting == true && mounted) {
        await _openExisting(passphrase);
      }
      return;
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
      return;
    }
    // Die Datenbank ist offen. GitHub einrichten (oder "Skip"); danach liegt
    // die Datenbankansicht frei, die main.dart schon darunter gebaut hat.
    if (!navigator.mounted) return;
    navigator.pushReplacement(MaterialPageRoute<bool>(
        builder: (context) => const GithubSettingsScreen(setup: true)));
  }

  Future<void> _openExisting(String passphrase) async {
    var navigator = Navigator.of(context);
    try {
      await runWithProgress(
          context, () => UltracipherApp.instance.openLocalDatabase(passphrase),
          title: derivingKeyTitle, hint: derivationHint());
    } on LocalDatabaseUnreadableException {
      if (mounted) {
        await offerRemoveUnreadableDatabase(context, passphrase);
      }
      return;
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
      return;
    }
    if (navigator.mounted) navigator.pop();
  }
}

/// "Import": base64-Text eines verschlüsselten Exports plus Passphrase, dann
/// öffnet `importEncryptedText` die Datenbank (und mergt in eine vorhandene
/// lokale Kopie).
class ImportDatabaseScreen extends StatefulWidget {
  const ImportDatabaseScreen({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _ImportDatabaseScreenState();
}

class _ImportDatabaseScreenState extends State<ImportDatabaseScreen> {
  final TextEditingController _text = TextEditingController();
  final TextEditingController _passphrase = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
    _passphrase.addListener(_changed);
  }

  void _changed() => setState(() => _error = null);

  @override
  void dispose() {
    _text.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  bool get _canImport =>
      _text.text.trim().isNotEmpty && _passphrase.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Import database')),
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
                    child: Text('Paste the encrypted text of an export and '
                        'enter its passphrase. If a database for this '
                        'passphrase already exists on this device, the '
                        'import is merged into it.'),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: TextField(
                      controller: _text,
                      minLines: 4,
                      maxLines: 8,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Encrypted database (base64)',
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(5),
                    child: PasswordField(
                      textController: _passphrase,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _canImport ? _import() : null,
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
                          onPressed: _canImport ? _import : null,
                          child: Text('Import'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text('Cancel'),
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

  Future<void> _import() async {
    var navigator = Navigator.of(context);
    var text = _text.text;
    var passphrase = _passphrase.text;
    try {
      await runWithProgress(
          context,
          () => UltracipherApp.instance.importEncryptedText(text, passphrase),
          title: derivingKeyTitle, hint: derivationHint());
    } on LocalDatabaseUnreadableException {
      if (mounted) {
        var removed = await offerRemoveUnreadableDatabase(context, passphrase);
        if (removed && mounted) {
          setState(() => _error = 'The damaged local copy was removed. '
              'Import again.');
        }
      }
      return;
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
      return;
    }
    // Die Datenbank ist offen (main.dart hat die Ansicht darunter getauscht).
    if (navigator.mounted) navigator.pop();
  }
}
