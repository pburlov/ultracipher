import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/view_entry.dart';

import 'commons.dart';
import 'github_settings.dart';
import 'progess_screen.dart';
import 'sync.dart';
import 'sync_status_button.dart';

/// Web gilt als Desktop, solange die Zielplattform nicht Android/iOS ist.
bool get _isDesktopOrWeb =>
    defaultTargetPlatform != TargetPlatform.android &&
    defaultTargetPlatform != TargetPlatform.iOS;

class DatabaseLoadedScreen extends StatefulWidget {
  final UltracipherDatabase? database;

  /// Wie lange Schließen/Entfernen auf einen Sync warten (Plan §3.3: erst
  /// versuchen zu syncen, wenn in dieser Sitzung noch keiner abgeschlossen
  /// hat). Danach gilt "Sync status unknown"; ein hängender Request darf die
  /// App nicht hinter der Sperre festhalten (Plan §10). Länger als das
  /// Request-Zeitlimit des GithubBackend (30 s), damit ein Lauf mit
  /// Zeitüberschreitung noch sein Ergebnis liefert.
  @visibleForTesting
  static Duration syncAttemptTimeout = const Duration(seconds: 40);

  const DatabaseLoadedScreen({Key? key, this.database}) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _DatabaseLoadedScreenState();
  }
}

/// Ergebnis der Prüfung "sind die Änderungen auf dem Remote" (Plan §3.3).
enum _SyncCheck {
  /// Alles ist auf dem Remote.
  synced,

  /// Kein Remote: die lokale Kopie ist die einzige.
  noRemote,

  /// In dieser Sitzung hat ein Sync gelingen können und danach nicht mehr:
  /// es gibt Änderungen nur auf diesem Gerät.
  unsynced,

  /// In dieser Sitzung ist kein Sync gelungen: ob Änderungen fehlen, ist
  /// unbekannt.
  unknown,
}

enum _MenuAction {
  exportCsv,
  importCsv,
  exportEncrypted,
  changePassphrase,
  githubSettings,
  syncNow,
  removeLocal,
}

class _DatabaseLoadedScreenState extends State<DatabaseLoadedScreen>
    with WidgetsBindingObserver {
  final _searchFieldController = TextEditingController();
  var foundEntries = <VersionedEntry>[];

  /// Fingerabdruck von Liste und Titel zum Zeitpunkt der letzten Anzeige: ein
  /// Sync-Ende baut den Screen nur neu, wenn sich etwas geändert hat.
  List<Object?> _shownSignature = const [];

  /// (Zustand, Fehlertext), für den die SnackBar schon gezeigt wurde. Gleiches
  /// Paar zeigt sie nicht erneut, auch nicht nach einem Lauf (`syncing`)
  /// dazwischen; erst ein Zustand außerhalb der Fehlerzustände (synced,
  /// notSynced, noRemote) setzt es zurück.
  String? _shownProblem;

  ScaffoldMessengerState? _messenger;

  /// Der Settings-Screen ist offen (kein Mehrfachöffnen, keine SnackBar
  /// darüber).
  bool _settingsOpen = false;

  UltracipherDatabase get _database => widget.database!;

  @override
  void initState() {
    super.initState();
    foundEntries = _database.getEntries();
    _shownSignature = _signature(foundEntries);
    _searchFieldController.addListener(_updateEntries);
    WidgetsBinding.instance.addObserver(this);
    var status = UltracipherApp.instance.syncStatus;
    status.addListener(_onSyncStatus);
    // Der erste Sync kann schon vor dem Aufbau des Screens geendet haben.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeShowSyncProblem(status.value);
    });
  }

  @override
  void didUpdateWidget(DatabaseLoadedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Passphrase-Wechsel: main.dart reicht dieselbe State-Instanz an eine
    // neue Datenbank weiter.
    if (!identical(oldWidget.database, widget.database)) {
      _updateEntries();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  @override
  void dispose() {
    // Die SnackBar gehört zu dieser Datenbank: ihre Aktion darf nicht auf
    // dem Startscreen stehen bleiben. Nach dem Abbau des Baums, nicht mitten
    // darin.
    var messenger = _messenger;
    if (messenger != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (messenger.mounted) messenger.clearSnackBars();
      });
    }
    WidgetsBinding.instance.removeObserver(this);
    UltracipherApp.instance.syncStatus.removeListener(_onSyncStatus);
    _searchFieldController.dispose();
    super.dispose();
  }

  /// Resume-Trigger (Plan §3.3). Der Screen existiert nur, solange eine
  /// Datenbank offen ist.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        UltracipherApp.instance.loadedDatabase.value != null) {
      UltracipherApp.instance.requestSync();
    }
  }

  List<Object?> _signature(List<VersionedEntry> entries) => [
        _database.lastChangedTime,
        for (var e in entries) ...[
          identityHashCode(e),
          e.versions.length,
          e.latestEntry?.createTime,
          e.latestEntry?.label,
        ],
      ];

  void _updateEntries() {
    var entries = _database.getEntries(searchTerm: _searchFieldController.text);
    setState(() {
      foundEntries = entries;
      _shownSignature = _signature(entries);
    });
  }

  void _onSyncStatus() {
    var status = UltracipherApp.instance.syncStatus.value;
    // Ein Merge ändert die Datenbank an Ort und Stelle (kein Notifier);
    // sichtbar wird er, wenn ein Sync endet. Nur bei einer Änderung neu
    // bauen: der Zustand wechselt bei jedem Lauf.
    if (status.state != SyncState.syncing && mounted) {
      var entries =
          _database.getEntries(searchTerm: _searchFieldController.text);
      if (!listEquals(_signature(entries), _shownSignature)) {
        setState(() {
          foundEntries = entries;
          _shownSignature = _signature(entries);
        });
      }
    }
    _maybeShowSyncProblem(status);
  }

  /// SnackBar mit "GitHub settings", wenn ein Sync in `authRequired` oder
  /// `remoteMissing` endet (Plan §3.4). Einmal je (Zustand, Fehlertext), bis
  /// der Zustand die Fehlerzustände verlässt; [force] zeigt sie trotzdem
  /// (nach dem Schließen der Einstellungen, die sie weggenommen haben).
  void _maybeShowSyncProblem(SyncStatus status, {bool force = false}) {
    String text;
    switch (status.state) {
      case SyncState.authRequired:
        text = 'GitHub rejected the access token. Enter it again in '
            'GitHub settings.';
        break;
      case SyncState.remoteMissing:
        text = '${syncStatusText(status)} Use "Change passphrase" with the '
            'new passphrase, or open GitHub settings.';
        break;
      case SyncState.syncing:
        // Ein Lauf dazwischen schärft die SnackBar nicht neu.
        return;
      default:
        _shownProblem = null;
        return;
    }
    var key = '${status.state}|${status.error}';
    if (!mounted || _settingsOpen) return;
    if (!force && key == _shownProblem) return;
    _shownProblem = key;
    var messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 12),
      action: SnackBarAction(
          label: 'GitHub settings', onPressed: _openGithubSettings),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.fitWidth,
          child: Text(
              // Kein Name der Datenbank: der Name ist ein Hash.
              'Ultracipher [${DateFormat('dd.MM.yyyy HH:mm:ss').format(_database.lastChangedTime.toLocal())}]'),
        ),
        leading: IconButton(
            icon: Icon(Icons.exit_to_app), onPressed: _closeDatabase),
        actions: [
          SyncStatusButton(onTap: _syncNow),
          PopupMenuButton<_MenuAction>(
            itemBuilder: (context) => const [
              PopupMenuItem(
                  value: _MenuAction.exportCsv, child: Text('Export CSV')),
              PopupMenuItem(
                  value: _MenuAction.importCsv, child: Text('Import CSV')),
              PopupMenuItem(
                  value: _MenuAction.exportEncrypted,
                  child: Text('Export encrypted (base64)')),
              PopupMenuItem(
                  value: _MenuAction.changePassphrase,
                  child: Text('Change passphrase')),
              PopupMenuItem(
                  value: _MenuAction.githubSettings,
                  child: Text('GitHub settings')),
              PopupMenuItem(
                  value: _MenuAction.syncNow, child: Text('Sync now')),
              PopupMenuItem(
                  value: _MenuAction.removeLocal,
                  child: Text('Remove local database')),
            ],
            onSelected: (action) {
              switch (action) {
                case _MenuAction.exportCsv:
                  _exportCsv();
                  break;
                case _MenuAction.importCsv:
                  _importCsv();
                  break;
                case _MenuAction.exportEncrypted:
                  _exportEncryptedText();
                  break;
                case _MenuAction.changePassphrase:
                  _changePassphrase();
                  break;
                case _MenuAction.githubSettings:
                  _openGithubSettings();
                  break;
                case _MenuAction.syncNow:
                  _syncNow();
                  break;
                case _MenuAction.removeLocal:
                  _removeLocalDatabase();
                  break;
              }
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addNewEntry,
        child: Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(5),
            child: TextField(
                controller: _searchFieldController,
                // Fokus beim Oeffnen nur auf Desktop und Web; auf dem Handy
                // wuerde sonst die Bildschirmtastatur die Liste verdecken.
                autofocus: _isDesktopOrWeb,
                decoration: InputDecoration(
                  labelText: 'Search',
                  border: OutlineInputBorder(),
                  filled: true,
                  suffixIcon: GestureDetector(
                    dragStartBehavior: DragStartBehavior.down,
                    onTap: () {
                      setState(() {
                        _searchFieldController.clear();
                      });
                    },
                    child: Icon(Icons.clear),
                  ),
                )),
          ),
          Expanded(
              child: Padding(
            padding: EdgeInsets.all(5),
            child: foundEntries.isNotEmpty
                ? ListView.builder(
                    itemCount: foundEntries.length,
                    itemBuilder: (context, index) {
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          Expanded(
                              child: TextButton(
                                  onPressed: () =>
                                      _showEntry(foundEntries[index]),
                                  child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(foundEntries[index]
                                          .latestEntry!
                                          .label))))
                        ],
                      );
                    },
                  )
                : Center(child: const Text('No items')),
          ))
        ],
      ),
    );
  }

  /// "Sync now" (Menü und Status-Symbol). Ohne Remote sagt eine Meldung, dass
  /// es nichts zu synchronisieren gibt; sonst zeigt das Symbol den Verlauf
  /// und die SnackBar das Ergebnis.
  Future<void> _syncNow() async {
    var messenger = ScaffoldMessenger.of(context);
    var status = await UltracipherApp.instance.syncNow();
    if (!mounted || status.state != SyncState.noRemote) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text('This database is only stored on this device. Set up '
          'GitHub to sync it.'),
      action: SnackBarAction(
          label: 'GitHub settings', onPressed: _openGithubSettings),
    ));
  }

  /// Sind die Änderungen auf dem Remote (Plan §3.3)? Hat in dieser Sitzung
  /// noch kein Sync abgeschlossen, wird erst einer versucht (hinter der
  /// Sperre, mit Zeitlimit); gelingt er nicht, bleibt es bei `unknown`.
  Future<_SyncCheck> _checkSync() async {
    var app = UltracipherApp.instance;
    _SyncCheck classify() {
      switch (app.syncStatus.value.state) {
        case SyncState.synced:
          return _SyncCheck.synced;
        case SyncState.noRemote:
          return _SyncCheck.noRemote;
        default:
          return app.hasSyncedThisSession
              ? _SyncCheck.unsynced
              : _SyncCheck.unknown;
      }
    }

    var check = classify();
    if (check != _SyncCheck.unknown) return check;
    try {
      await runWithProgress(
          context,
          () => app
              .syncNow()
              .timeout(DatabaseLoadedScreen.syncAttemptTimeout),
          title: 'Syncing...');
    } catch (_) {
      // Zeitlimit: der Lauf geht weiter, hier gilt der Stand von jetzt.
    }
    return classify();
  }

  /// Zusatz mit dem Grund des letzten Fehlschlags, ohne Token oder Inhalt.
  String _reasonSuffix() {
    var error = UltracipherApp.instance.syncStatus.value.error;
    return error == null ? '' : '\n\nLast sync problem: ${describeError(error)}';
  }

  Future<void> _closeDatabase() async {
    var check = await _checkSync();
    if (!mounted) return;
    if (check == _SyncCheck.unsynced || check == _SyncCheck.unknown) {
      var confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Close with unsynced changes?'),
          content: Text(
              '${check == _SyncCheck.unknown ? 'Sync status unknown. ' : ''}'
              'Changes stay on this device and sync next time.'
              '${_reasonSuffix()}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Close')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    ScaffoldMessenger.of(context).clearSnackBars();
    UltracipherApp.instance.closeDatabase();
  }

  Future<void> _removeLocalDatabase() async {
    var check = await _checkSync();
    if (!mounted) return;
    String message;
    switch (check) {
      case _SyncCheck.synced:
        message = 'The copy on this device is deleted. The database is '
            'synced, so it stays on GitHub; you can load it again with '
            '"New" (same passphrase and GitHub access).';
        break;
      case _SyncCheck.noRemote:
        message = 'This database exists only on this device (no remote). '
            'Removing it deletes the only copy. Export it first if you '
            'may need it again.';
        break;
      case _SyncCheck.unsynced:
        message = 'This database has unsynced changes that are not on '
            'GitHub yet. Removing the local copy loses them.${_reasonSuffix()}';
        break;
      case _SyncCheck.unknown:
        message = 'Sync status unknown: it could not be checked whether '
            'everything is on GitHub. Removing the local copy may lose '
            'changes.${_reasonSuffix()}';
        break;
    }
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove local database?'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child:
                  Text('Remove', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Der Screen verschwindet mit der Sitzung: Navigator und Context vorher
    // sichern.
    var navigator = Navigator.of(context, rootNavigator: true);
    ScaffoldMessenger.of(context).clearSnackBars();
    try {
      await runWithProgress(
          context, () => UltracipherApp.instance.removeLocalDatabase(),
          title: 'Removing...');
    } catch (e) {
      if (navigator.mounted) {
        // ignore: use_build_context_synchronously
        await showMessageDialog(
            navigator.context, 'Not removed', describeError(e));
      }
    }
  }

  /// GitHub-Einstellungen (modal). Die Datenbank muss offen bleiben; das
  /// Ergebnis ist nur ein Hinweis zum Aktualisieren.
  Future<void> _openGithubSettings() async {
    if (_settingsOpen || !mounted) return;
    _settingsOpen = true;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    try {
      await Navigator.push<bool>(
          context,
          MaterialPageRoute(
              builder: (context) => const GithubSettingsScreen()));
    } finally {
      _settingsOpen = false;
    }
    if (!mounted) return;
    _updateEntries();
    // Die SnackBar wurde beim Öffnen weggenommen: besteht das Problem noch,
    // einmal wieder zeigen.
    _maybeShowSyncProblem(UltracipherApp.instance.syncStatus.value,
        force: true);
  }

  Future<void> _showEntry(VersionedEntry entry) async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (context) {
        return EntryViewScreen(
          entry: entry,
        );
      },
    ));
    _updateEntries();
  }

  Future<void> _addNewEntry() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (context) {
        return EntryViewScreen(
          entry: null,
        );
      },
    ));
    _updateEntries();
  }

  void _changePassphrase() async {
    await showDialog(
      context: context,
      builder: (context) => Dialog(
        // Innenabstand, damit die runden Dialogecken die Felder nicht
        // anschneiden.
        child: Padding(
          padding: EdgeInsets.all(20),
          child: ChangePassphraseWidget(),
        ),
      ),
    );
    // Ein Wechsel mit "mergeLocal" kann Eintraege hinzugebracht haben.
    if (mounted) _updateEntries();
  }

  /// CSV-Export im Klartext. Die Warnung ist Pflicht, weil die Datei nicht
  /// verschlüsselt ist.
  Future<void> _exportCsv() async {
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Export CSV'),
        content: Text(
            'The exported file contains ALL entries UNENCRYPTED, as plain text. Anyone who gets the file can read them.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Export')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var bytes = Uint8List.fromList(
        utf8.encode(UltracipherApp.instance.loadedDatabase.value!.toCSV()));
    try {
      // null heisst Abbruch im Speichern-Dialog: dann passiert still nichts.
      var uri = await FilePicker.saveFile(
          fileName: 'ultracipher-export.csv',
          bytes: bytes,
          mimeType: 'text/csv');
      if (uri == null || !mounted) return;
      _showMessage('CSV exported');
    } catch (_) {
      // Keine Fehlerdetails anzeigen: sie können Dateipfade enthalten.
      if (mounted) _showMessage('Export failed');
    }
  }

  /// CSV-Import: mergt die Einträge der Datei in die Datenbank, gelöscht wird
  /// nichts. Gespeichert wird erst, wenn das CSV gelesen werden konnte (siehe
  /// importCsvText).
  Future<void> _importCsv() async {
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Import CSV'),
        content: Text(
            'The entries from the file are merged into the database. Nothing is deleted.\n\n'
            'Entries that were deleted on another device may stay deleted if '
            'this device has not synced since. To restore them reliably, use '
            '"Sync now" first, then import.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Import')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var picked = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['csv']);
    // Leere Liste heisst Abbruch durch den User.
    if (picked.isEmpty || !mounted) return;
    String csv;
    try {
      csv = utf8.decode(await picked.first.readAsBytes());
    } catch (_) {
      if (mounted) _showMessage('Could not read the file as UTF-8 text');
      return;
    }
    if (!mounted) return;
    var importedCount = 0;
    var future = UltracipherApp.instance
        .importCsvText(csv)
        .then((count) => importedCount = count);
    // FormatException und Speicherfehler zeigt der Progress-Dialog selbst an;
    // dort wurde dann nichts gespeichert.
    var success = await showProgressDialog(context, future, 'Saving...');
    if (!mounted) return;
    _updateEntries();
    if (success ?? false) {
      _showMessage('$importedCount new or changed entries imported');
    }
  }

  /// Verschlüsselter Export als base64-Text: derselbe Text wie in der
  /// GitHub-Datei, zum Kopieren in einem Dialog. Der Text wird weder
  /// geloggt noch in eine Datei geschrieben.
  Future<void> _exportEncryptedText() async {
    Uint8List bytes;
    try {
      bytes = await UltracipherApp.instance.exportEncryptedDatabase();
    } catch (_) {
      // Keine Fehlerdetails anzeigen.
      if (mounted) _showMessage('Export failed');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _EncryptedTextExportDialog(
          text: base64.encode(bytes),
          containsToken:
              UltracipherApp.instance.loadedDatabase.value?.settings?.github !=
                  null),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Zeigt den base64-Text einer verschlüsselten Datenbank schreibgeschützt und
/// auswählbar an, mit Copy (Clipboard) und Close. Der Text bleibt im Dialog.
class _EncryptedTextExportDialog extends StatefulWidget {
  final String text;

  /// Die Datenbank enthält GitHub-Zugangsdaten: der Export trägt sie
  /// (verschlüsselt) mit (Plan §3.2).
  final bool containsToken;

  const _EncryptedTextExportDialog(
      {Key? key, required this.text, this.containsToken = false})
      : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _EncryptedTextExportDialogState();
  }
}

class _EncryptedTextExportDialogState
    extends State<_EncryptedTextExportDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    // Vor dem await holen: der Dialog-Context wird danach nicht mehr benutzt.
    var messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: widget.text));
    messenger.showSnackBar(SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Encrypted text'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.containsToken)
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                    'The text includes the GitHub access token (encrypted). '
                    'Whoever has the text and the passphrase can also write '
                    'to your repository.',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            TextField(
              controller: _controller,
              readOnly: true,
              maxLines: 8,
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                filled: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _copy, child: Text('Copy')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close')),
      ],
    );
  }
}

class ChangePassphraseWidget extends StatefulWidget {
  const ChangePassphraseWidget({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _ChangePassphraseWidgetState();
  }
}

class _ChangePassphraseWidgetState extends State<ChangePassphraseWidget> {
  final TextEditingController _oldPasswordController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _newPasswordConfirmationController =
      TextEditingController();

  bool get _isNewPassphraseValid =>
      _newPasswordController.text == _newPasswordConfirmationController.text;

  @override
  void initState() {
    super.initState();
    _newPasswordController.addListener(() {
      setState(() {});
    });
    _newPasswordConfirmationController.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _newPasswordConfirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      heightFactor: 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
              padding: EdgeInsets.all(5),
              child: PasswordField(
                label: 'Old passphrase',
                textController: _oldPasswordController,
              )),
          Padding(
              padding: EdgeInsets.all(5),
              child: PasswordField(
                label: 'New passphrase',
                textController: _newPasswordController,
              )),
          Padding(
              padding: EdgeInsets.all(5),
              child: PasswordField(
                  label: 'Confirm new passphrase',
                  textController: _newPasswordConfirmationController,
                  fillColor:
                      _isNewPassphraseValid ? null : Colors.amberAccent)),
          Padding(
              padding: EdgeInsets.all(5),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                      onPressed: _newPasswordController.text.isNotEmpty &&
                              _isNewPassphraseValid
                          ? _changePassphrase
                          : null,
                      child: Text('Change')),
                  TextButton(onPressed: _cancelChange, child: Text('Cancel'))
                ],
              ))
        ],
      ),
    );
  }

  /// Wechselt die Passphrase (neuer Name, Plan §3.5). Der ganze Ablauf, auch
  /// der zweite Aufruf nach der Rueckfrage, laeuft hinter einer Sperre ueber
  /// der ganzen App: waehrend des Wechsels kann nichts bearbeitet werden. Ein
  /// Speichern ueber den Namenswechsel hinweg scheitert sonst mit "closed",
  /// obwohl die Version schon unter dem neuen Namen liegt, und
  /// view_entry._commitEdit nimmt sie dann zurueck (Plan §10).
  void _changePassphrase() async {
    var navigator = Navigator.of(context);
    var oldPassphrase = _oldPasswordController.text;
    var newPassphrase = _newPasswordController.text;
    if (hasNonAscii(newPassphrase.trim()) &&
        !await confirmNonAsciiPassphrase(context)) {
      return;
    }
    if (!mounted) return;
    PassphraseChangeResult result;
    try {
      result = await _runChange(oldPassphrase, newPassphrase, false);
    } on LocalDatabaseExistsException {
      if (!mounted) return;
      var merge = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Database already exists'),
          content: Text('A database for the new passphrase already exists on '
              'this device. Merge this database into it? Nothing is '
              'deleted.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Merge')),
          ],
        ),
      );
      if (merge != true || !mounted) return;
      try {
        result = await _runChange(oldPassphrase, newPassphrase, true);
      } catch (e) {
        if (mounted) {
          await showMessageDialog(
              context, 'Passphrase not changed', describeError(e));
        }
        return;
      }
    } catch (e) {
      if (mounted) {
        await showMessageDialog(
            context, 'Passphrase not changed', describeError(e));
      }
      return;
    }
    if (!mounted) return;
    var cleanupError = result.cleanupError;
    if (cleanupError != null) {
      await showMessageDialog(
          context,
          'Passphrase changed',
          'The new passphrase is active, but the old copy could not be '
              'removed (${describeError(cleanupError)}). It stays readable '
              'under the old passphrase, and other devices keep syncing '
              'against it. To finish, open the old passphrase and change it '
              'to the new one again.');
    }
    if (navigator.mounted) navigator.pop();
  }

  Future<PassphraseChangeResult> _runChange(
      String oldPassphrase, String newPassphrase, bool mergeLocal) {
    return runWithProgress(
        context,
        () => UltracipherApp.instance.changeDatabasePassphrase(
            oldPassphrase: oldPassphrase,
            newPassphrase: newPassphrase,
            mergeLocal: mergeLocal),
        title: 'Changing passphrase...',
        hint: derivationHint(derivations: 2));
  }

  void _cancelChange() {
    Navigator.of(context).pop();
  }
}
