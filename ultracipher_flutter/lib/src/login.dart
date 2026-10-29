import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ultracipher_flutter/src/core.dart';

import 'commons.dart';
import 'progess_screen.dart';
import 'start_flows.dart';

/// Hinweis auf dem Startscreen, wenn nur Altdaten auf dem Geraet liegen.
const String legacyDataHint =
    'This device holds databases from a previous app version. They cannot '
    'be opened here. Export a CSV with the old app version and import it '
    'here. "Erase local data" removes the old copies.';

/// Startscreen (Plan §3.4). Mit lokalen Datenbanken: Passwortfeld und "Open",
/// am unteren Rand "New" und "Import". Ohne: App-Name, ein erklärender Satz,
/// "New" als Hauptaktion, "Import" unten. Eine Passphrase ist eine Datenbank;
/// es gibt keinen Benutzernamen.
///
/// Nutzt nur die Sitzungs-API aus core.dart (`localDatabaseNames`,
/// `openLocalDatabase`, `removeLocalDatabase`). Öffnet sich eine Datenbank,
/// tauscht main.dart diesen Screen aus; nach dem Öffnen wird er nicht mehr
/// angefasst.
class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _LoginScreenState();
  }
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _passphrase = TextEditingController();

  /// Meldung unter dem Passwortfeld (neutral bei falschem Passwort).
  String? _error;

  /// From the native package metadata (which comes from pubspec.yaml at
  /// build time), so the title never hardcodes a version again.
  String _appVersion = '';

  bool get _hasLocalDatabases =>
      UltracipherApp.instance.localDatabaseNames().isNotEmpty;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() {
          _appVersion = info.version;
        });
      }
    });
    _passphrase.addListener(() {
      setState(() {
        _error = null;
      });
    });
  }

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var hasLocal = _hasLocalDatabases;
    return Scaffold(
        appBar: AppBar(
          title: FittedBox(
              fit: BoxFit.contain,
              child: Text(
                  'Ultracipher${_appVersion.isEmpty ? '' : ' $_appVersion'}')),
          actions: [
            PopupMenuButton<int>(
              itemBuilder: (context) => [
                const PopupMenuItem(value: 0, child: Text('Erase local data')),
                const PopupMenuItem(value: 1, child: Text('About')),
              ],
              onSelected: (value) {
                switch (value) {
                  case 0:
                    _eraseLocalData();
                    break;
                  case 1:
                    _showAboutDialog();
                    break;
                }
              },
            ),
          ],
        ),
        body: SafeArea(
            child: Column(
          children: [
            Expanded(
                child: Center(
                    child: SingleChildScrollView(
                        padding: EdgeInsets.all(16),
                        child: SizedBox(
                            width: 320,
                            child: hasLocal
                                ? _buildOpenForm(context)
                                : _buildEmptyState(context))))),
            Padding(
                padding: EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (hasLocal)
                      Padding(
                          padding: EdgeInsets.all(5),
                          child: OutlinedButton(
                              onPressed: _newDatabase, child: Text('New'))),
                    Padding(
                        padding: EdgeInsets.all(5),
                        child: OutlinedButton(
                            onPressed: _import, child: Text('Import'))),
                  ],
                )),
          ],
        )));
  }

  Widget _buildOpenForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
            padding: EdgeInsets.all(5),
            child: PasswordField(
                textController: _passphrase,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _open())),
        if (_error != null)
          Padding(
              padding: EdgeInsets.all(5),
              child:
                  Text(_error!, style: TextStyle(color: Colors.redAccent))),
        Padding(
            padding: EdgeInsets.all(5),
            child: ElevatedButton(
                onPressed: _passphrase.text.trim().isEmpty ? null : _open,
                child: Text('Open'))),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    var theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
            padding: EdgeInsets.all(5),
            child: Text('Ultracipher',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium)),
        Padding(
            padding: EdgeInsets.all(5),
            child: Text(
                'No database on this device yet. Create a new one or import '
                'an exported one.',
                textAlign: TextAlign.center)),
        Padding(
            padding: EdgeInsets.all(15),
            child: ElevatedButton(
                onPressed: _newDatabase, child: Text('New'))),
        Padding(
            padding: EdgeInsets.all(5),
            child: Text(
                'To connect a second device: choose "New" there and enter the '
                'same passphrase and the same GitHub access.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall)),
        // Nur Altdaten auf dem Geraet (z. B. v2-Kopien): sie lassen sich nie
        // oeffnen, der Weg ist CSV aus der alten App-Version.
        if (UltracipherApp.instance.hasLegacyLocalCopies)
          Padding(
              padding: EdgeInsets.all(5),
              child: Text(legacyDataHint,
                  key: const Key('legacyDataHint'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error))),
      ],
    );
  }

  /// Öffnet die lokale Datenbank zur eingegebenen Passphrase. Die Ableitung
  /// des Schlüssels läuft hinter dem Fortschrittsbild (Sekunden, Eingaben
  /// gesperrt). Nach Erfolg gehört der Screen main.dart, nichts mehr anfassen.
  Future<void> _open() async {
    var passphrase = _passphrase.text;
    if (passphrase.trim().isEmpty) return;
    setState(() {
      _error = null;
    });
    try {
      await runWithProgress(
          context, () => UltracipherApp.instance.openLocalDatabase(passphrase),
          title: derivingKeyTitle, hint: derivationHint());
    } on NoLocalDatabaseException catch (e) {
      // Neutral: falsches Passwort und "gibt es nicht" sehen gleich aus.
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    } on LocalDatabaseUnreadableException {
      if (!mounted) return;
      await offerRemoveUnreadableDatabase(context, passphrase);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        await showMessageDialog(context, 'Could not open', describeError(e));
      }
    }
  }

  Future<void> _newDatabase() async {
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const NewDatabaseScreen()));
    if (mounted) setState(() {});
  }

  Future<void> _import() async {
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ImportDatabaseScreen()));
    if (mounted) setState(() {});
  }

  /// Entfernt alle lokalen Datenbanken und Schluessel-Caches
  /// ([UltracipherApp.eraseLocalData]). Reste des alten Modells (alte Caches,
  /// Token-Blobs) bleiben stehen, bis der User sie in einem zweiten Schritt
  /// ausdruecklich ebenfalls entfernen laesst (Plan E5).
  Future<void> _eraseLocalData() async {
    var confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('Erase local data?'),
              content: Text('All databases stored on this device are removed, '
                  'together with their cached keys. Changes that are not '
                  'synced yet, and databases that are not on GitHub, are '
                  'lost for good. Data on GitHub is not touched.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text('Erase')),
              ],
            ));
    if (confirmed != true || !mounted) return;
    var app = UltracipherApp.instance;
    await app.eraseLocalData();
    if (!mounted) return;
    setState(() {});
    // Alles, was noch da ist, stammt aus dem alten Modell (oder gehoert nicht
    // zur App).
    if (!app.hasLegacyLocalData) return;
    var eraseOld = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('Remove data of the older app version too?'),
              content: Text('This device also holds data from the older app '
                  'version (old local copies, stored GitHub tokens). The app '
                  'cannot open it any more. Removing it is permanent; keep it '
                  'if you may still want to export it with an older build.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('Keep')),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text('Remove')),
              ],
            ));
    if (eraseOld != true) return;
    await app.eraseLocalData(includeLegacy: true);
    if (mounted) setState(() {});
  }

  void _showAboutDialog() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;

    String appName = 'Ultracipher';
    String version = packageInfo.version;
    String buildNumber = packageInfo.buildNumber;
    showAboutDialog(
        context: context,
        applicationName: appName,
        applicationVersion: '$version ($buildNumber)');
  }
}
